defmodule CymphonyElixir.DashboardPayloadSingleFlightTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule SnapshotServer do
    use GenServer

    def start_link({name, owner}), do: GenServer.start_link(__MODULE__, owner, name: name)
    def init(owner), do: {:ok, {owner, 0}}

    def handle_call(:snapshot, _from, {owner, count}) do
      count = count + 1
      send(owner, {:snapshot_started, count, self()})

      if count in [2, 3] do
        receive do
          {:release_snapshot, ^count} -> :ok
        end
      end

      snapshot = %{
        running: [],
        retrying: [],
        waiting: [],
        recent_completed: [],
        token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil,
        polling: %{paused: count == 2, checking?: false, next_poll_in_ms: 5_000, poll_interval_ms: 30_000}
      }

      {:reply, snapshot, {owner, count}}
    end
  end

  setup do
    old = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, old) end)

    old_config_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    config_dir = Path.join(System.tmp_dir!(), "cymphony-single-flight-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config_dir)
    File.write!(Path.join(config_dir, "config.json"), ~s({"projects":[]}))
    Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)

    on_exit(fn ->
      if old_config_dir,
        do: Application.put_env(:cymphony_elixir, :config_dir_override, old_config_dir),
        else: Application.delete_env(:cymphony_elixir, :config_dir_override)

      File.rm_rf!(config_dir)
    end)

    name = Module.concat(__MODULE__, :"Orch#{System.unique_integer([:positive])}")
    server = start_supervised!({SnapshotServer, {name, self()}}, id: name)

    config =
      old
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(orchestrator: name, snapshot_timeout_ms: 10_000)

    Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, config)
    start_supervised!({CymphonyElixirWeb.Endpoint, []})

    {:ok, server: server}
  end

  test "a burst queues one refresh and an action invalidates the older result", %{server: server} do
    {:ok, view, _} = live(build_conn(), "/")
    assert_receive {:snapshot_started, 1, _}, 1_000

    due_tick(view)
    assert_receive {:snapshot_started, 2, _}, 1_000

    for _ <- 1..3 do
      due_tick(view)
    end

    send(view.pid, :reload_payload_now)
    render(view)
    assert view_assigns(view).payload_pending? == true
    refute_receive {:snapshot_started, 3, _}, 40

    send(server, {:release_snapshot, 2})
    assert_receive {:snapshot_started, 3, _}, 300
    assert view_assigns(view).projects |> hd() |> Map.fetch!(:paused) == false

    send(server, {:release_snapshot, 3})
    assert eventually(fn -> view_assigns(view).payload_job == nil end)
    assert view_assigns(view).projects |> hd() |> Map.fetch!(:paused) == false
  end

  test "a crashed load releases the slot so the queued refresh can run", %{server: server} do
    {:ok, view, _} = live(build_conn(), "/")
    assert_receive {:snapshot_started, 1, _}, 1_000

    due_tick(view)
    assert_receive {:snapshot_started, 2, _}, 1_000
    due_tick(view)
    assert view_assigns(view).payload_pending? == true

    Process.exit(view_assigns(view).payload_job.pid, :kill)
    send(server, {:release_snapshot, 2})
    assert_receive {:snapshot_started, 3, _}, 300
    send(server, {:release_snapshot, 3})
    assert eventually(fn -> view_assigns(view).payload_job == nil end)
  end

  test "an abruptly terminated LiveView also terminates its in-flight load" do
    {:ok, view, _} = live(build_conn(), "/")
    assert_receive {:snapshot_started, 1, _}, 1_000

    due_tick(view)
    assert_receive {:snapshot_started, 2, _}, 1_000
    worker = view_assigns(view).payload_job.pid
    ref = Process.monitor(worker)

    old_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_trap_exit) end)
    Process.exit(view.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 500
  end

  test "a timed-out load is cancelled and its queued refresh takes the slot", %{server: server} do
    {:ok, view, _} = live(build_conn(), "/")
    assert_receive {:snapshot_started, 1, _}, 1_000

    due_tick(view)
    assert_receive {:snapshot_started, 2, _}, 1_000
    due_tick(view)
    job = view_assigns(view).payload_job
    ref = Process.monitor(job.pid)

    send(view.pid, {:payload_timeout, job.ref, job.generation})
    assert_receive {:DOWN, ^ref, :process, _, _}, 500
    send(server, {:release_snapshot, 2})
    assert_receive {:snapshot_started, 3, _}, 500
    send(server, {:release_snapshot, 3})
    assert eventually(fn -> view_assigns(view).payload_job == nil end)
  end

  test "a failed post-action load cannot admit a stale pre-action payload" do
    {:ok, view, _} = live(build_conn(), "/")
    assert_receive {:snapshot_started, 1, _}, 1_000
    stale_seq = view_assigns(view).payload_seq
    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, CymphonyElixir.TaskSupervisor)

    try do
      send(view.pid, :reload_payload_now)
      render(view)
      assert view_assigns(view).payload_generation == 1
      assert view_assigns(view).payload_job == nil

      counts = view_assigns(view).counts
      send(view.pid, {:payload_loaded, stale_seq, %{counts: %{counts | running: 99}}})
      render(view)
      assert view_assigns(view).counts.running == 0
    after
      assert {:ok, _pid} = Supervisor.restart_child(CymphonyElixir.Supervisor, CymphonyElixir.TaskSupervisor)
    end
  end

  defp due_tick(view) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      assigns = Map.update!(socket.assigns, :last_payload_refresh, &(&1 - 10_000))
      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :observability_updated)
    send(view.pid, :runtime_tick)
    render(view)
  end

  defp view_assigns(view) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
    assigns
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
