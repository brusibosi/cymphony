defmodule CymphonyElixir.PresenterFanoutTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias CymphonyElixirWeb.Presenter

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule SnapshotServer do
    use GenServer

    def start_link({name, owner, snapshot, hold?}) do
      GenServer.start_link(__MODULE__, {name, owner, snapshot, hold?})
    end

    def init({name, owner, snapshot, hold?}) do
      {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, nil)
      {:ok, {name, owner, snapshot, hold?}}
    end

    def handle_call(:snapshot, {worker, _call_ref}, {name, owner, snapshot, hold?} = state) do
      send(owner, {:snapshot_started, name, self()})
      send(owner, {:snapshot_worker_started, name, worker})

      if hold? do
        receive do
          :release_snapshot -> :ok
        end
      end

      {:reply, snapshot, state}
    end
  end

  test "a stalled project does not delay later fast projects past one deadline" do
    start_project("01-slow", true)
    start_project("02-fast", false)

    started = System.monotonic_time(:millisecond)
    payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 200)
    elapsed = System.monotonic_time(:millisecond) - started

    assert Enum.map(payload.projects, & &1.name) == ["02-fast"]
    assert elapsed < 1_000
  end

  test "fan-out caps active snapshot calls at four and preserves registry order" do
    for index <- 1..5 do
      start_project("#{index}", true)
    end

    registered_names = CymphonyElixir.ProjectSupervisor.list_orchestrators() |> Enum.map(&elem(&1, 0))
    fifth_name = Enum.at(registered_names, 4)

    caller = self()

    task =
      Task.async(fn ->
        payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 3_000)
        send(caller, {:payload_result, payload})
      end)

    first_four = for _ <- 1..4, do: assert_receive({:snapshot_started, _, _}, 1_000)
    assert Enum.sort(Enum.map(first_four, &elem(&1, 1))) == Enum.sort(Enum.take(registered_names, 4))
    refute_receive {:snapshot_started, ^fifth_name, _}, 30

    for {:snapshot_started, _, pid} <- first_four, do: send(pid, :release_snapshot)
    assert_receive {:snapshot_started, ^fifth_name, fifth}, 1_000
    send(fifth, :release_snapshot)

    assert_receive {:payload_result, payload}, 1_000
    assert Enum.map(payload.projects, & &1.name) == registered_names
    Task.await(task)
  end

  test "registered projects whose snapshots all fail remain unavailable" do
    start_project("broken", false, :unavailable)

    payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 30)
    assert payload.error.code == "snapshot_unavailable"
  end

  test "projects API distinguishes failed registered snapshots from an empty fleet" do
    start_endpoint()
    start_project("broken", false, :unavailable)

    response = get(build_conn(), "/api/v1/projects")

    assert json_response(response, 503) == %{
             "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
           }
  end

  test "projects API returns an empty list for a genuinely empty fleet" do
    start_endpoint()
    assert json_response(get(build_conn(), "/api/v1/projects"), 200) == %{"projects" => []}
  end

  test "observation works while the global task supervisor is unavailable" do
    start_project("answering", false)
    assert :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, CymphonyElixir.TaskSupervisor)

    try do
      payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 500)
      assert Enum.map(payload.projects, & &1.name) == ["answering"]
      assert Presenter.projects_payload() == [%{name: "answering", running: 0, retrying: 0}]
    after
      assert {:ok, _pid} = Supervisor.restart_child(CymphonyElixir.Supervisor, CymphonyElixir.TaskSupervisor)
    end
  end

  test "many stalled projects consume one shared deadline, not one timeout each" do
    for index <- 1..8, do: start_project("slow-#{index}", true)

    started = System.monotonic_time(:millisecond)
    payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 400)
    elapsed = System.monotonic_time(:millisecond) - started

    assert payload.error.code == "snapshot_unavailable"
    assert elapsed < 1_500
  end

  test "a blocked snapshot worker dies when its aggregation caller dies" do
    start_project("blocked", true)
    {caller, caller_ref} = spawn_monitor(fn -> Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 5_000) end)

    assert_receive {:snapshot_worker_started, "blocked", worker}, 1_000
    worker_ref = Process.monitor(worker)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 1_000
  end

  test "a completed snapshot reaps its owner guardian" do
    server = start_project("normal", true)
    task = Task.async(fn -> Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 5_000) end)

    assert_receive {:snapshot_worker_started, "normal", worker}, 1_000
    guardian = wait_for_guardian(worker, task.pid)
    assert is_pid(guardian)
    guardian_ref = Process.monitor(guardian)

    send(server, :release_snapshot)
    assert %{projects: [%{name: "normal"}]} = Task.await(task, 1_000)
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 1_000
  end

  test "projects payload fans out rather than waiting for a stalled earlier project" do
    start_project("01-slow", true)
    start_project("02-fast", false)
    registered_names = CymphonyElixir.ProjectSupervisor.list_orchestrators() |> Enum.map(&elem(&1, 0))

    caller = self()
    task = Task.async(fn -> send(caller, {:projects_result, Presenter.projects_payload()}) end)

    assert_receive {:snapshot_started, "01-slow", slow}, 1_000
    assert_receive {:snapshot_started, "02-fast", _}, 1_000
    send(slow, :release_snapshot)
    assert_receive {:projects_result, projects}, 1_000
    assert Enum.map(projects, & &1.name) == registered_names
    Task.await(task)
  end

  defp start_project(name, hold?, snapshot \\ nil) do
    snapshot =
      snapshot ||
        %{
          running: [],
          retrying: [],
          waiting: [],
          recent_completed: [],
          token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          rate_limits: nil,
          polling: %{paused: false}
        }

    start_supervised!({SnapshotServer, {name, self(), snapshot, hold?}}, id: name)
  end

  defp start_endpoint do
    old = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])
    on_exit(fn -> Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, old) end)

    Application.put_env(
      :cymphony_elixir,
      CymphonyElixirWeb.Endpoint,
      Keyword.merge(old, server: false, secret_key_base: String.duplicate("s", 64))
    )

    start_supervised!({CymphonyElixirWeb.Endpoint, []})
  end

  defp wait_for_guardian(worker, owner, attempts \\ 100)

  defp wait_for_guardian(_worker, _owner, 0), do: nil

  defp wait_for_guardian(worker, owner, attempts) do
    guardian =
      case Process.info(worker, :monitored_by) do
        {:monitored_by, pids} -> Enum.find(pids, &(&1 != owner))
        nil -> nil
      end

    if guardian do
      guardian
    else
      Process.sleep(10)
      wait_for_guardian(worker, owner, attempts - 1)
    end
  end
end
