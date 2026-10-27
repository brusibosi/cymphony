defmodule CymphonyElixir.AgentRunnerBlockedTodoTest do
  use CymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-blocked-todo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    command = Path.join(root, "fake-claude")
    trace = Path.join(root, "turns")
    hooks = Path.join(root, "hooks")
    workspace_root = Path.join(root, "workspaces")

    File.write!(command, """
    #!/bin/sh
    printf 'RUN\\n' >> '#{trace}'
    echo '{"type":"result","is_error":false,"session_id":"blocked-todo","result":"done"}'
    """)

    File.chmod!(command, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "printf retained > retained.txt",
      hook_after_run: "printf 'after_run\\n' >> '#{hooks}'",
      claude_command: command,
      tracker_active_states: ["Todo", "In Progress", "Repairing"],
      tracker_terminal_states: ["Done", "Released"],
      max_turns: 3
    )

    issue = %Issue{id: "blocked-todo", identifier: "ALE-1435", title: "Wait on prerequisite", state: "In Progress"}

    %{issue: issue, trace: trace, hooks: hooks, workspace_root: workspace_root}
  end

  test "fresh blocked Todo stops after one real runner turn and preserves its workspace", ctx do
    issue = ctx.issue
    blocked = %{issue | state: "Todo", blocked_by: [%{id: "prerequisite", state: "In Progress"}]}

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: fn [_] -> {:ok, [blocked]} end)
    assert_turns_and_cleanup(ctx, 1)
  end

  test "ready Todo and independent active phases continue with configured terminal names", ctx do
    for {state, blockers} <- [
          {"Todo", []},
          {" tOdO ", [%{state: " DONE "}, %{state: " released "}]},
          {"In Progress", [%{state: "Backlog"}]},
          {"Repairing", [%{state: nil}]}
        ] do
      reset_trace(ctx)
      refreshed = %{ctx.issue | state: state, blocked_by: blockers}
      assert :ok = AgentRunner.run(ctx.issue, nil, config: Config.settings!(), issue_state_fetcher: fn [_] -> {:ok, [refreshed]} end)
      assert_turns_and_cleanup(ctx, 3)
    end
  end

  test "unknown blockers and terminal or excluded workflow outcomes stop without another call", ctx do
    for {state, blockers} <- [
          {"Todo", [%{state: nil}]},
          {"Todo", [%{}]},
          {"Todo", [%{state: ""}]},
          {"Todo", [%{state: "Unrecognized"}]},
          {"Released", []},
          {"In Review", []},
          {nil, []}
        ] do
      reset_trace(ctx)
      refreshed = %{ctx.issue | state: state, blocked_by: blockers}
      assert :ok = AgentRunner.run(ctx.issue, nil, issue_state_fetcher: fn [_] -> {:ok, [refreshed]} end)
      assert_turns_and_cleanup(ctx, 1)
    end
  end

  test "missing and failed tracker reads stop the current session without inventing completion", ctx do
    assert :ok = AgentRunner.run(ctx.issue, nil, issue_state_fetcher: fn [_] -> {:ok, []} end)
    assert_turns_and_cleanup(ctx, 1)
    reset_trace(ctx)

    assert_raise RuntimeError, ~r/issue_state_refresh_failed.*tracker_unavailable/, fn ->
      AgentRunner.run(ctx.issue, nil, issue_state_fetcher: fn [_] -> {:error, :tracker_unavailable} end)
    end

    assert_turns_and_cleanup(ctx, 1)
  end

  test "missing normalized issue state cannot be treated as blocked Todo" do
    refute Issue.todo_blocked_by_non_terminal?(%Issue{state: nil}, MapSet.new(["done"]))
  end

  defp reset_trace(ctx) do
    File.write!(ctx.trace, "")
    File.write!(ctx.hooks, "")
  end

  defp assert_turns_and_cleanup(ctx, count) do
    assert File.read!(ctx.trace) == String.duplicate("RUN\n", count)
    assert File.read!(ctx.hooks) == "after_run\n"
    assert File.read!(Path.join([ctx.workspace_root, "ALE-1435", "retained.txt"])) == "retained"
  end
end
