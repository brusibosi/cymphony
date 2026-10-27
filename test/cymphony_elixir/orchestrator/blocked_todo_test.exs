defmodule CymphonyElixir.Orchestrator.BlockedTodoTest do
  use CymphonyElixir.TestSupport

  test "a completed turn handed to blocked Todo releases resources without completion or another model call" do
    {server, issue, paths} = runtime(:finish)
    File.write!(Path.join(paths.workspace, "evidence.txt"), "retained")
    blocked = %{issue | state: "Todo", blocked_by: [%{id: "required-install", state: "In Progress"}]}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [blocked])
    File.write!(paths.release, "finish")

    eventually(fn ->
      state = :sys.get_state(server)

      not Map.has_key?(state.running, issue.id) and not Map.has_key?(state.retry_attempts, issue.id) and
        not MapSet.member?(state.claimed, issue.id) and state.work.retiring == %{}
    end)

    assert length(cli_pids(paths.pids)) == 1
    assert File.read!(paths.hooks) == "after_run\n"
    assert_retained_handoff(server, issue, paths)
  end

  test "periodic blocked Todo retires its actual process and later eligible Todo dispatches" do
    {server, issue, paths} = runtime(:sleep)
    worker = :sys.get_state(server).running[issue.id].pid
    old_pid = hd(cli_pids(paths.pids))
    File.write!(Path.join(paths.workspace, "evidence.txt"), "retained")
    blocked = %{issue | state: "Todo", blocked_by: [%{id: "required-install", state: "In Progress"}]}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [blocked])
    assert :ok = Orchestrator.run_poll_cycle_for_test(server)

    eventually(fn ->
      state = :sys.get_state(server)
      not Process.alive?(worker) and not alive?(old_pid) and state.work.retiring == %{}
    end)

    assert_retained_handoff(server, issue, paths)
    assert :ok = Orchestrator.run_poll_cycle_for_test(server)
    assert length(cli_pids(paths.pids)) == 1

    ready = %{blocked | blocked_by: [%{id: "required-install", state: "Done"}]}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [ready])
    assert :ok = Orchestrator.run_poll_cycle_for_test(server)
    eventually(fn -> length(cli_pids(paths.pids)) == 2 end)
    assert Orchestrator.snapshot(server, 1000).completed_count == 0
    assert File.read!(Path.join(paths.workspace, "evidence.txt")) == "retained"
  end

  for {label, state, blockers} <- [
        {"ready Todo", "Todo", []},
        {"custom-terminal blockers", " tOdO ", [%{state: " RELEASED "}]},
        {"independent in-progress phase", "In Progress", [%{state: "Backlog"}]}
      ] do
    test "periodic reconciliation preserves #{label}" do
      {server, issue, paths} = runtime(:sleep)
      worker = :sys.get_state(server).running[issue.id].pid
      old_pid = hd(cli_pids(paths.pids))
      refreshed = %{issue | state: unquote(state), blocked_by: unquote(Macro.escape(blockers))}
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [refreshed])
      assert :ok = Orchestrator.run_poll_cycle_for_test(server)
      eventually(fn -> :sys.get_state(server).running[issue.id].issue == refreshed end)

      assert Process.alive?(worker)
      assert alive?(old_pid)
      assert length(cli_pids(paths.pids)) == 1
      assert Orchestrator.snapshot(server, 1000).completed_count == 0
      assert :sys.get_state(server).provider_holds == %{}
    end
  end

  for {state, count, cleanup} <- [{"Done", 1, true}, {"Canceled", 0, true}, {"In Review", 0, false}] do
    test "periodic #{state} retains existing completion and workspace semantics" do
      {server, issue, paths} = runtime(:sleep)
      worker = :sys.get_state(server).running[issue.id].pid
      old_pid = hd(cli_pids(paths.pids))
      File.write!(Path.join(paths.workspace, "evidence.txt"), "retained")
      refreshed = %{issue | state: unquote(state), blocked_by: [%{state: "Backlog"}]}
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [refreshed])
      assert :ok = Orchestrator.run_poll_cycle_for_test(server)
      eventually(fn -> not Process.alive?(worker) and not alive?(old_pid) and :sys.get_state(server).work.retiring == %{} end)

      assert Orchestrator.snapshot(server, 1000).completed_count == unquote(count)
      assert File.exists?(paths.workspace) == not unquote(cleanup)
      assert length(cli_pids(paths.pids)) == 1
      state = :sys.get_state(server)
      refute Map.has_key?(state.retry_attempts, issue.id)
      refute MapSet.member?(state.claimed, issue.id)
      assert state.provider_holds == %{}
      assert :ok = Orchestrator.run_poll_cycle_for_test(server)
      assert Orchestrator.snapshot(server, 1000).completed_count == unquote(count)
    end
  end

  test "missing running issue retires its process without completion or workspace cleanup" do
    {server, issue, paths} = runtime(:sleep)
    worker = :sys.get_state(server).running[issue.id].pid
    old_pid = hd(cli_pids(paths.pids))
    File.write!(Path.join(paths.workspace, "evidence.txt"), "retained")
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [])
    assert :ok = Orchestrator.run_poll_cycle_for_test(server)
    eventually(fn -> not Process.alive?(worker) and not alive?(old_pid) and :sys.get_state(server).work.retiring == %{} end)
    assert_retained_handoff(server, issue, paths)
    assert length(cli_pids(paths.pids)) == 1
  end

  test "failed authoritative refresh retains the current owner and never starts another process" do
    {server, issue, paths} = runtime(:sleep)
    worker = :sys.get_state(server).running[issue.id].pid
    old_pid = hd(cli_pids(paths.pids))
    parent = self()

    plug = fn conn, _opts ->
      send(parent, :tracker_read_failed)
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, ~s({"errors":[{"message":"tracker unavailable"}]}))
    end

    tracker = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(tracker)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "http://127.0.0.1:#{port}/graphql",
      workspace_root: Path.dirname(paths.workspace),
      claude_command: Path.join(Path.dirname(paths.pids), "fake-claude"),
      poll_interval_ms: 60_000
    )

    assert :ok = Orchestrator.run_poll_cycle_for_test(server)
    assert_receive :tracker_read_failed, 2000
    eventually(fn -> :sys.get_state(server).work.io_jobs == %{} end)

    assert Process.alive?(worker)
    assert alive?(old_pid)
    assert length(cli_pids(paths.pids)) == 1
    state = :sys.get_state(server)
    assert MapSet.member?(state.claimed, issue.id)
    assert state.provider_holds == %{}
    assert Orchestrator.snapshot(server, 1000).completed_count == 0
  end

  defp assert_retained_handoff(server, issue, paths) do
    state = :sys.get_state(server)
    refute Map.has_key?(state.running, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
    refute MapSet.member?(state.pending_completed_issue_ids, issue.id)
    assert state.provider_holds == %{}
    assert Orchestrator.snapshot(server, 1000).completed_count == 0
    assert File.read!(Path.join(paths.workspace, "evidence.txt")) == "retained"
  end

  defp runtime(mode) do
    root = Path.dirname(Workflow.workflow_file_path())
    command = Path.join(root, "fake-claude")
    pids = Path.join(root, "cli.pids")
    hooks = Path.join(root, "hooks")
    release = Path.join(root, "release")

    tail =
      case mode do
        :sleep -> "exec /bin/sleep 60"
        :finish -> "while [ ! -f '#{release}' ]; do sleep 0.01; done\necho '{\"type\":\"result\",\"is_error\":false,\"session_id\":\"handoff\",\"result\":\"done\"}'"
      end

    File.write!(command, "#!/bin/sh\necho $$ >> '#{pids}'\n#{tail}\n")
    File.chmod!(command, 0o755)
    issue = %Issue{id: "blocked-todo", identifier: "ALE-1435", title: "Await required install", state: "In Progress"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      claude_command: command,
      hook_after_run: "printf 'after_run\\n' >> '#{hooks}'",
      max_concurrent_agents: 1,
      max_turns: 3,
      tracker_terminal_states: ["Done", "Canceled", "Released"],
      poll_interval_ms: 60_000
    )

    server = start_supervised!({Orchestrator, name: nil})
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    eventually(fn -> length(cli_pids(pids)) == 1 end)
    paths = %{pids: pids, hooks: hooks, release: release, workspace: Path.join([root, "workspaces", issue.identifier])}
    {server, issue, paths}
  end

  defp cli_pids(path) do
    case File.read(path) do
      {:ok, data} -> String.split(data, "\n", trim: true)
      _ -> []
    end
  end

  defp alive?(pid), do: elem(System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true), 1) == 0

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
