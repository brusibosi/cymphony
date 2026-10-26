defmodule CymphonyElixir.Agent.RunnerProviderFailureTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Agent.ProviderFailure

  setup do
    test_root = Path.join(System.tmp_dir!(), "cymphony-provider-failure-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1391")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(test_root) end)

    issue = %Issue{id: "provider-1391", identifier: "MT-1391", title: "Provider fixture", state: "In Progress", labels: []}
    {:ok, test_root: test_root, workspace_root: workspace_root, workspace: workspace, issue: issue}
  end

  test "real runner preserves Claude auth failure on a nonzero CLI exit", ctx do
    configure_cli(ctx, claude_auth_lines(), 1)
    assert {:error, %{__struct__: ProviderFailure, kind: :authentication, retry_at: nil}} = Runner.run(ctx.workspace, "fixture", ctx.issue)
  end

  test "exit zero with a semantic authentication failure is not successful work", ctx do
    configure_cli(ctx, claude_auth_lines(), 0)
    assert {:error, %{__struct__: ProviderFailure, kind: :authentication}} = Runner.run(ctx.workspace, "fixture", ctx.issue)
  end

  test "real AGY quota result retains its known reset rather than a text excerpt", ctx do
    lines = [~s({"event":"result","result":{"conversation_id":"id","status":"ERROR","error":"Individual quota reached. Resets in 48h53m16s."}})]
    configure_cli(ctx, lines, 0, "antigravity")
    before_ms = System.system_time(:millisecond)
    assert {:error, %{kind: :quota, retry_at: retry_at}} = Runner.run(ctx.workspace, "fixture", ctx.issue)
    after_ms = System.system_time(:millisecond)
    assert retry_at >= before_ms + 175_996_000
    assert retry_at <= after_ms + 175_996_000
  end

  test "AgentRunner task exits with the typed authentication exception after cleanup", ctx do
    configure_cli(ctx, claude_auth_lines(), 1)
    {pid, ref} = spawn_monitor(fn -> AgentRunner.run(ctx.issue, nil, max_turns: 1) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, {exception, stacktrace}}, 5_000
    assert %{__struct__: ProviderFailure, kind: :authentication} = exception
    assert is_list(stacktrace)
  end

  test "ordinary nonzero failure and quoted auth test output stay normal agent errors", ctx do
    lines = [
      ~s({"type":"user","message":{"content":[{"type":"tool_result","content":"authentication_failed RESOURCE_EXHAUSTED"}]}}),
      "test authentication_failed passed"
    ]

    configure_cli(ctx, lines, 2)
    assert {:error, {:agent_exit, 2, message}} = Runner.run(ctx.workspace, "fixture", ctx.issue)
    assert message =~ "test authentication_failed passed"
  end

  test "a refusal survives bounded transcript eviction without retaining raw error payloads", ctx do
    lines = List.duplicate("startup noise", 6) ++ claude_auth_lines() ++ List.duplicate("shutdown noise", 80)
    configure_cli(ctx, lines, 1)
    assert {:error, %{__struct__: ProviderFailure, kind: :authentication}} = Runner.run(ctx.workspace, "fixture", ctx.issue)
  end

  defp claude_auth_lines do
    [
      ~s({"type":"assistant","isApiErrorMessage":true,"error":"authentication_failed","message":{"content":[{"type":"text","text":"Not logged in"}]}}),
      ~s({"type":"result","is_error":true,"result":"Not logged in"})
    ]
  end

  defp configure_cli(ctx, lines, status, kind \\ "claude") do
    binary = Path.join(ctx.test_root, "fake-agent")

    File.write!(binary, """
    #!/bin/sh
    cat <<'CYMPHONY_PROVIDER_FIXTURE'
    #{Enum.join(lines, "\n")}
    CYMPHONY_PROVIDER_FIXTURE
    exit #{status}
    """)

    File.chmod!(binary, 0o755)

    workflow_opts = [
      workspace_root: ctx.workspace_root,
      agent_kind: kind,
      claude_command: binary,
      claude_output_format: "stream-json",
      antigravity_command: binary
    ]

    write_workflow_file!(Workflow.workflow_file_path(), workflow_opts)
  end
end
