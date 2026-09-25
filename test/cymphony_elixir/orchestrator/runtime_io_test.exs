defmodule CymphonyElixir.Orchestrator.RuntimeIOTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.{LegacySupervisor, ProjectSupervisor}

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "project crash tears down the old agent before replacement dispatch", %{root: root} do
    {name, orchestrator, worker} = running_project(root)
    Process.exit(orchestrator, :kill)

    replacement =
      eventually(fn ->
        pid = ProjectSupervisor.lookup(name, :orchestrator)
        if is_pid(pid) and pid != orchestrator, do: pid
      end)

    refute Process.alive?(worker)
    assert is_map(Orchestrator.snapshot(replacement, 200))
  end

  test "project removal terminates its running agent", %{root: root} do
    {name, _orchestrator, worker} = running_project(root)
    assert :ok = ProjectSupervisor.stop_project(name)
    refute Process.alive?(worker)
  end

  test "task-supervisor crash resets runtime and kills the old agent", %{root: root} do
    {name, orchestrator, worker} = running_project(root)
    task_supervisor = ProjectSupervisor.lookup(name, :task_supervisor)
    Process.exit(task_supervisor, :kill)

    replacement =
      eventually(fn ->
        pid = ProjectSupervisor.lookup(name, :orchestrator)
        if is_pid(pid) and pid != orchestrator, do: pid
      end)

    refute Process.alive?(worker)
    assert is_map(Orchestrator.snapshot(replacement, 200))
  end

  test "legacy crash terminates old agent and restarts a coherent runtime", %{root: root} do
    memory_workflow(root)
    assert :ok = LegacySupervisor.start()

    on_exit(fn ->
      if pid = Process.whereis(LegacySupervisor),
        do: DynamicSupervisor.terminate_child(CymphonyElixir.ProjectDynamicSupervisor, pid)
    end)

    orchestrator = Process.whereis(Orchestrator)
    worker = running_worker(orchestrator)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    Process.exit(orchestrator, :kill)

    replacement =
      eventually(fn ->
        pid = Process.whereis(Orchestrator)
        if is_pid(pid) and pid != orchestrator, do: pid
      end)

    refute Process.alive?(worker)
    assert is_map(Orchestrator.snapshot(replacement, 200))
  end

  test "direct public start owns agent lifetime without a project supervisor", %{root: root} do
    memory_workflow(root)
    {:ok, orchestrator} = CymphonyElixir.start_link(name: nil)
    Process.unlink(orchestrator)
    worker = running_worker(orchestrator)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    Process.exit(orchestrator, :kill)
    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "normal direct stop terminates its owned agent", %{root: root} do
    memory_workflow(root)
    {:ok, orchestrator} = CymphonyElixir.start_link(name: nil)
    worker = running_worker(orchestrator)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    GenServer.stop(orchestrator)
    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "orchestrator shutdown stops the actual CLI OS process", %{root: root} do
    memory_workflow(root)
    parent_dir = Path.dirname(root)
    cli = Path.join(parent_dir, "fake-claude")
    pidfile = Path.join(parent_dir, "fake-claude.pid")
    File.write!(cli, "#!/bin/sh\nprintf '%s' $$ > '#{pidfile}'\nexec /bin/sleep 60\n")
    File.chmod!(cli, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      claude_command: cli,
      poll_interval_ms: 60_000
    )

    {:ok, orchestrator} = CymphonyElixir.start_link(name: nil)
    worker = running_worker(orchestrator)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    os_pid =
      eventually(fn ->
        case File.read(pidfile) do
          {:ok, pid} when byte_size(pid) > 0 -> pid
          _ -> nil
        end
      end)

    on_exit(fn -> System.cmd("/bin/kill", ["-KILL", os_pid], stderr_to_stdout: true) end)
    GenServer.stop(orchestrator)
    assert eventually(fn -> elem(System.cmd("/bin/kill", ["-0", os_pid], stderr_to_stdout: true), 1) != 0 end)
  end

  test "blocked candidate poll leaves snapshot and controls responsive and coalesces refreshes", %{root: root} do
    {endpoint, _server} = endpoint(:poll)
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, request}, 2_000

    assert is_map(Orchestrator.snapshot(orchestrator, 100))
    assert :ok = GenServer.call(orchestrator, :pause, 100)
    assert :ok = GenServer.call(orchestrator, {:set_concurrency, 2}, 100)
    assert :ok = GenServer.call(orchestrator, {:set_providers, ["isolated"]}, 100)
    for _ <- 1..12, do: GenServer.call(orchestrator, :request_refresh, 100)
    refute_receive {:request, :poll, _}, 80
    send(request, {:release, []})
    assert_receive {:request, :poll, followup}, 2_000
    refute_receive {:request, :poll, _}, 80
    send(followup, {:release, []})
    assert eventually(fn -> Orchestrator.snapshot(orchestrator, 100).polling.checking? == false end)
    assert Orchestrator.snapshot(orchestrator, 100).polling.paused
    assert Orchestrator.snapshot(orchestrator, 100).polling.max_concurrent_agents == 2
    refute_receive {:request, :poll, _}, 80
  end

  test "dispatch revalidation does not block pause and cannot dispatch after pause", %{root: root} do
    {endpoint, _server} = endpoint(:by_id, [issue()])
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :by_id, request}, 2_000
    assert :ok = GenServer.call(orchestrator, :pause, 100)
    assert is_map(Orchestrator.snapshot(orchestrator, 100))
    send(request, {:release, [issue()]})
    Process.sleep(50)
    assert Orchestrator.snapshot(orchestrator, 100).running == []
  end

  test "a late candidate result cannot resurrect a session killed during that poll", %{root: root} do
    {endpoint, _server} = endpoint(:poll, [issue()])
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, initial}, 2_000
    send(initial, {:release, [issue()]})
    running_worker(orchestrator)
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    Orchestrator.request_refresh(orchestrator)
    assert_receive {:request, :poll, request}, 2_000
    assert :ok = GenServer.call(orchestrator, {:kill_issue, "owned-1"}, 100)
    send(request, {:release, [issue()]})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    assert Orchestrator.snapshot(orchestrator, 100).running == []
    assert Orchestrator.snapshot(orchestrator, 100).retrying == []
  end

  test "late worker events are fenced from a replacement session", %{root: root} do
    {_name, orchestrator, _worker} = running_project(root)
    old_token = :sys.get_state(orchestrator).running["owned-1"][:run_token]
    assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "owned-1", %{})
    new_token = eventually(fn -> get_in(:sys.get_state(orchestrator).running, ["owned-1", :run_token]) end)
    assert is_reference(new_token)
    refute new_token == old_token
    send(orchestrator, {:worker_runtime_info, "owned-1", new_token, %{workspace_path: "/current"}})
    send(orchestrator, {:worker_runtime_info, "owned-1", old_token, %{workspace_path: "/obsolete"}})
    send(orchestrator, {:worker_runtime_info, "owned-1", %{workspace_path: "/legacy-obsolete"}})
    assert :sys.get_state(orchestrator).running["owned-1"].workspace_path == "/current"
  end

  test "operator restart waits for the previous process guard without blocking controls", %{root: root} do
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue()])
    directory = Path.dirname(root)
    pidfile = Path.join(directory, "restart-pids")
    overlap = Path.join(directory, "overlap")
    cli = Path.join(directory, "restart-cli")

    File.write!(
      cli,
      "#!/bin/sh\nif [ -f '#{pidfile}' ]; then read old < '#{pidfile}'; if kill -0 \"$old\" 2>/dev/null; then touch '#{overlap}'; fi; fi\necho $$ >> '#{pidfile}'\nexec /bin/sleep 60\n"
    )

    File.chmod!(cli, 0o755)

    {name, orchestrator} =
      start_project(root, tracker_kind: "memory", hook_before_run: nil, claude_command: cli)

    running_worker(orchestrator)
    eventually(fn -> File.exists?(pidfile) end)
    ports = ProjectSupervisor.lookup(name, :port_supervisor)
    [{_, guard, _, _}] = DynamicSupervisor.which_children(ports)
    :sys.suspend(guard)

    try do
      assert :ok = Orchestrator.set_issue_run_spec(orchestrator, "owned-1", %{})
      assert :ok = GenServer.call(orchestrator, :pause, 100)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
      assert eventually(fn -> Orchestrator.snapshot(orchestrator, 100).polling.cleanup_error end, 200)
      assert :ok = GenServer.call(orchestrator, :pause, 100)
      assert Orchestrator.snapshot(orchestrator, 100).running == []
    after
      if Process.alive?(guard), do: :sys.resume(guard)
    end

    # Explicit restart is a manual override, even though pause was pressed while reaping.
    eventually(fn -> Map.has_key?(:sys.get_state(orchestrator).running, "owned-1") end, 300)
    eventually(fn -> length(String.split(File.read!(pidfile), "\n", trim: true)) == 2 end)
    refute File.exists?(overlap)
  end

  test "poll deadline clears checking and a fresh refresh works after cancellation", %{root: root} do
    {endpoint, _server} = endpoint(:poll)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: endpoint,
      workspace_root: root,
      claude_command: "/usr/bin/false",
      poll_interval_ms: 60_000
    )

    orchestrator = start_supervised!({Orchestrator, name: nil, io_timeout_ms: 100})
    assert_receive {:request, :poll, abandoned}, 2_000
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    assert Orchestrator.snapshot(orchestrator, 100).running == []
    Orchestrator.request_refresh(orchestrator)
    assert_receive {:request, :poll, fresh}, 2_000
    send(abandoned, {:release, [issue()]})
    send(fresh, {:release, []})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    assert Orchestrator.snapshot(orchestrator, 100).running == []
  end

  test "poll worker crash releases single-flight slot and does not apply its late response", %{root: root} do
    {endpoint, _server} = endpoint(:poll)
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, abandoned}, 2_000
    state = :sys.get_state(orchestrator)
    job = state.work.io_jobs[state.work.poll_job]
    Process.exit(job.pid, :kill)
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    Orchestrator.request_refresh(orchestrator)
    assert_receive {:request, :poll, fresh}, 2_000
    send(abandoned, {:release, [issue()]})
    send(fresh, {:release, []})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    assert Orchestrator.snapshot(orchestrator, 100).running == []
  end

  test "config edited during candidate I/O invalidates the old dispatch data", %{root: root} do
    {endpoint, _server} = endpoint(:poll, [issue()])
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, old}, 2_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: endpoint,
      workspace_root: root,
      claude_command: "/usr/bin/false",
      prompt: "New workflow",
      poll_interval_ms: 60_000
    )

    send(old, {:release, [issue()]})
    assert_receive {:request, :poll, fresh}, 2_000
    assert Orchestrator.snapshot(orchestrator, 100).running == []
    assert :sys.get_state(orchestrator).prompt_template == "New workflow"
    send(fresh, {:release, []})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
  end

  test "watchdog still reclaims a silent session while tracker polling is blocked", %{root: root} do
    {endpoint, _server} = endpoint(:poll, [issue()])
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, initial}, 2_000
    send(initial, {:release, [issue()]})
    worker = running_worker(orchestrator)
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    Orchestrator.request_refresh(orchestrator)
    assert_receive {:request, :poll, blocked}, 2_000

    :sys.replace_state(orchestrator, fn state ->
      old = DateTime.add(DateTime.utc_now(), -10, :second)
      entry = %{state.running["owned-1"] | last_agent_timestamp: old}

      %{
        state
        | running: Map.put(state.running, "owned-1", entry),
          config: %{state.config | agent: %{state.config.agent | stall_timeout_ms: 1}}
      }
    end)

    send(orchestrator, :watchdog)
    assert eventually(fn -> not Process.alive?(worker) end)
    assert [%{issue_id: "owned-1", attempt: 1}] = Orchestrator.snapshot(orchestrator, 100).retrying
    send(blocked, {:release, []})
    # Current config changed, so the obsolete result must request one fresh poll.
    assert_receive {:request, :poll, fresh}, 2_000
    send(fresh, {:release, []})
  end

  test "a recovered workflow invalidates tracker data fetched with last-good settings", %{root: root} do
    {endpoint, _server} = endpoint(:poll, [issue()])
    path = Workflow.workflow_file_path()

    write_workflow_file!(path,
      tracker_endpoint: endpoint,
      workspace_root: root,
      hook_before_run: "sleep 60",
      claude_command: "/usr/bin/false",
      poll_interval_ms: 60_000,
      prompt: "Old"
    )

    orchestrator = start_supervised!({Orchestrator, name: nil})
    assert_receive {:request, :poll, initial}, 2_000
    send(initial, {:release, []})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    File.rm!(path)
    Orchestrator.request_refresh(orchestrator)
    assert_receive {:request, :poll, old}, 2_000

    write_workflow_file!(path,
      tracker_endpoint: endpoint,
      workspace_root: root,
      hook_before_run: "sleep 60",
      claude_command: "/usr/bin/false",
      poll_interval_ms: 60_000,
      prompt: "Recovered"
    )

    send(old, {:release, [issue()]})
    assert_receive {:request, :poll, fresh}, 2_000
    assert :sys.get_state(orchestrator).prompt_template == "Recovered"
    assert Orchestrator.snapshot(orchestrator, 100).running == []
    send(fresh, {:release, []})
  end

  test "bounded intent workers fill configured concurrency above four in the same poll", %{root: root} do
    issues = for number <- 1..7, do: %{issue() | id: "fill-#{number}", identifier: "FILL-#{number}"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, issues)
    {_name, orchestrator} = start_project(root, tracker_kind: "memory", max_concurrent_agents: 6)
    assert eventually(fn -> length(Orchestrator.snapshot(orchestrator, 100).running) == 6 end)
    assert length(Orchestrator.snapshot(orchestrator, 100).waiting) == 1
  end

  test "each poll attempts an issue once while refilling the four-intent pool", %{root: root} do
    issues = for number <- 1..7, do: %{issue() | id: "attempt-#{number}", identifier: "ATTEMPT-#{number}"}
    {endpoint, _server} = endpoint(:by_id, issues)
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint, max_concurrent_agents: 6)

    first =
      for _ <- 1..4 do
        assert_receive {:request, :by_id, request}, 2_000
        request
      end

    refute_receive {:request, :by_id, _}, 80

    next =
      for request <- Enum.take(first, 3) do
        send(request, {:release, {:error, "tracker outage"}})
        assert_receive {:request, :by_id, following}, 2_000
        following
      end

    for request <- Enum.drop(first, 3) ++ next, do: send(request, {:release, {:error, "tracker outage"}})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    assert length(Orchestrator.snapshot(orchestrator, 100).waiting) == 7
    assert Orchestrator.snapshot(orchestrator, 100).running == []
    refute_receive {:request, :by_id, _}, 80
    Orchestrator.request_refresh(orchestrator)

    second =
      for _ <- 1..4 do
        assert_receive {:request, :by_id, request}, 2_000
        request
      end

    assert :ok = Orchestrator.pause(orchestrator)
    for request <- second, do: send(request, {:release, {:error, "tracker outage"}})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
  end

  test "manual retry tracker lookup is responsive and remains owned during lookup", %{root: root} do
    {endpoint, _server} = endpoint(:poll)
    {_name, orchestrator} = start_project(root, tracker_endpoint: endpoint)
    assert_receive {:request, :poll, initial}, 2_000
    send(initial, {:release, []})
    eventually(fn -> not Orchestrator.snapshot(orchestrator, 100).polling.checking? end)
    token = make_ref()

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | paused: true,
          claimed: MapSet.new(["owned-1"]),
          retry_attempts: %{
            "owned-1" => %{
              attempt: 2,
              failures: 1,
              identifier: "OWN-1",
              timer_ref: nil,
              retry_token: token,
              due_at_ms: System.monotonic_time(:millisecond),
              held: true
            }
          }
      }
    end)

    assert :ok = GenServer.call(orchestrator, {:retry_issue_now, "owned-1"}, 100)
    assert_receive {:request, :poll, request}, 2_000
    assert [%{issue_id: "owned-1", attempt: 2}] = Orchestrator.snapshot(orchestrator, 100).retrying
    assert :ok = GenServer.call(orchestrator, :resume, 100)
    send(request, {:release, []})
    assert eventually(fn -> Orchestrator.snapshot(orchestrator, 100).retrying == [] end)
  end

  defp running_project(root) do
    memory_workflow(root)
    name = "owned-#{System.unique_integer([:positive])}"
    assert :ok = ProjectSupervisor.start_project(name, Workflow.workflow_file_path())
    on_exit(fn -> ProjectSupervisor.stop_project(name) end)
    orchestrator = ProjectSupervisor.lookup(name, :orchestrator)
    worker = running_worker(orchestrator)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
    {name, orchestrator, worker}
  end

  defp memory_workflow(root) do
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue()])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      hook_before_run: "sleep 60",
      claude_command: "/usr/bin/false",
      poll_interval_ms: 60_000
    )
  end

  defp running_worker(orchestrator) do
    eventually(fn ->
      case :sys.get_state(orchestrator).running["owned-1"] do
        %{pid: pid} -> pid
        _ -> nil
      end
    end)
  end

  defp start_project(root, opts) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: root,
          hook_before_run: "sleep 60",
          claude_command: "/usr/bin/false",
          poll_interval_ms: 60_000
        ],
        opts
      )
    )

    name = "io-#{System.unique_integer([:positive])}"
    assert :ok = ProjectSupervisor.start_project(name, Workflow.workflow_file_path())
    on_exit(fn -> ProjectSupervisor.stop_project(name) end)
    {name, ProjectSupervisor.lookup(name, :orchestrator)}
  end

  defp issue,
    do: %Issue{
      id: "owned-1",
      identifier: "OWN-1",
      title: "owned",
      state: "In Progress",
      labels: [],
      blocked_by: []
    }

  defp endpoint(block, issues \\ []) do
    parent = self()

    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      query = payload["query"]

      kind =
        cond do
          String.contains?(query, "CymphonyLinearIssuesById") ->
            :by_id

          String.contains?(query, "CymphonyLinearPoll") and
              "In Progress" in payload["variables"]["stateNames"] ->
            :poll

          true ->
            :other
        end

      values = request_values(kind, block, issues, parent)

      response = linear_response(values)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}/graphql", server}
  end

  defp linear_response({:error, message}), do: %{"errors" => [%{"message" => message}]}

  defp linear_response(values) do
    nodes =
      Enum.map(values, fn issue ->
        %{
          "id" => issue.id,
          "identifier" => issue.identifier,
          "title" => issue.title,
          "state" => %{"name" => issue.state},
          "labels" => %{"nodes" => []},
          "inverseRelations" => %{"nodes" => []}
        }
      end)

    %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}
  end

  defp request_values(kind, kind, _issues, parent) do
    send(parent, {:request, kind, self()})

    receive do
      {:release, values} -> values
    after
      5_000 -> []
    end
  end

  defp request_values(kind, _block, issues, _parent) when kind in [:poll, :by_id], do: issues
  defp request_values(_kind, _block, _issues, _parent), do: []

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: flunk("condition never became true: #{inspect(fun.())}")

  defp eventually(fun, attempts) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
