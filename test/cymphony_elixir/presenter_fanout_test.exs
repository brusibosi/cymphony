defmodule CymphonyElixir.PresenterFanoutTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixirWeb.Presenter

  defmodule SnapshotServer do
    use GenServer

    def start_link({name, owner, snapshot, hold?}) do
      GenServer.start_link(__MODULE__, {name, owner, snapshot, hold?})
    end

    def init({name, owner, snapshot, hold?}) do
      {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, nil)
      {:ok, {name, owner, snapshot, hold?}}
    end

    def handle_call(:snapshot, _from, {name, owner, snapshot, hold?} = state) do
      send(owner, {:snapshot_started, name, self()})

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

  test "many stalled projects consume one shared deadline, not one timeout each" do
    for index <- 1..8, do: start_project("slow-#{index}", true)

    started = System.monotonic_time(:millisecond)
    payload = Presenter.state_payload(Module.concat(__MODULE__, :NoLegacy), 400)
    elapsed = System.monotonic_time(:millisecond) - started

    assert payload.error.code == "snapshot_unavailable"
    assert elapsed < 1_500
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
end
