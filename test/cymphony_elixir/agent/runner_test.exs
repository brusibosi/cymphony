defmodule CymphonyElixir.Agent.RunnerTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               Runner.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               Runner.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               Runner.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server runs claude -p and parses json output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-json-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2000")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-output.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":"done","session_id":"sess-abc123","usage":{"input_tokens":100,"output_tokens":50}}' >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-abc123","usage":{"input_tokens":100,"output_tokens":50}}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-json-output",
        identifier: "MT-2000",
        title: "JSON output parsing",
        description: "Ensure app server parses claude json output",
        state: "In Progress",
        url: "https://example.org/issues/MT-2000",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-abc123", result: %{result: "done"}}} =
               Runner.run(workspace, "do the thing", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server handles non-zero exit as error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-exit-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2001")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":null}'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-exit-error",
        identifier: "MT-2001",
        title: "Exit error handling",
        description: "Ensure app server handles claude exit errors",
        state: "In Progress",
        url: "https://example.org/issues/MT-2001",
        labels: ["backend"]
      }

      assert {:error, {:agent_exit, 1, remaining}} =
               Runner.run(workspace, "do the thing", issue)

      assert remaining =~ ~s({"result":null})
    after
      File.rm_rf(test_root)
    end
  end

  test "non-zero exit keeps the completed error line the CLI printed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-exit-tail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2002")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"type":"error","message":"invalid model selection: sonnet-9"}'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-exit-tail",
        identifier: "MT-2002",
        title: "Exit error tail",
        description: "The CLI error line must survive into the retry queue",
        state: "In Progress",
        url: "https://example.org/issues/MT-2002",
        labels: ["backend"]
      }

      assert {:error, {:agent_exit, 1, remaining}} =
               Runner.run(workspace, "do the thing", issue)

      assert remaining =~ "invalid model selection: sonnet-9"
    after
      File.rm_rf(test_root)
    end
  end

  test "non-zero exit output is redacted before it leaves the runner" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-exit-redact-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2004")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      # A CLI that dies mid-request routinely dumps its own environment. The
      # tail is stored on the retry entry, served by /api/v1/state, rendered by
      # the dashboard, and posted to the tracker as the abandonment comment, so
      # it is redacted at the single choke point that feeds all four.
      File.write!(claude_binary, """
      #!/bin/sh
      echo 'LINEAR_API_KEY=lin_api_abcdefghij0123456789'
      echo 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig'
      echo 'ANTHROPIC_API_KEY=sk-ant-api03-AAAABBBBCCCCDDDD'
      echo '{"type":"error","message":"invalid model selection: sonnet-9"}'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-exit-redact",
        identifier: "MT-2004",
        title: "Exit error redaction",
        description: "Secrets in the failure tail never reach a status surface",
        state: "In Progress",
        url: "https://example.org/issues/MT-2004",
        labels: ["backend"]
      }

      assert {:error, {:agent_exit, 1, remaining}} =
               Runner.run(workspace, "do the thing", issue)

      refute remaining =~ "lin_api_"
      refute remaining =~ "sk-ant"
      refute remaining =~ "eyJhbGciOiJIUzI1NiJ9"
      assert remaining =~ "LINEAR_API_KEY=[REDACTED]"
      assert remaining =~ "ANTHROPIC_API_KEY=[REDACTED]"
      assert remaining =~ "Authorization: Bearer [REDACTED]"

      # Redaction is part of the same lazy sanitize pass, so ordering and the
      # real diagnostic are unchanged.
      assert String.starts_with?(remaining, ~s({"type":"error","message":"invalid model selection: sonnet-9"}))
    after
      File.rm_rf(test_root)
    end
  end

  test "non-zero exit output is bounded and sanitized" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-exit-bound-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2003")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      i=1
      while [ $i -le 40 ]; do
        printf 'noise-%03d %s\\n' "$i" '#{String.duplicate("x", 200)}'
        i=$((i+1))
      done
      printf '\\033[31m{"error":"unknown provider for model"}\\033[0m\\n'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-exit-bound",
        identifier: "MT-2003",
        title: "Exit error bound",
        description: "The retained tail is capped and stripped of control bytes",
        state: "In Progress",
        url: "https://example.org/issues/MT-2003",
        labels: ["backend"]
      }

      assert {:error, {:agent_exit, 1, remaining}} =
               Runner.run(workspace, "do the thing", issue)

      assert remaining =~ ~s({"error":"unknown provider for model"})
      assert byte_size(remaining) <= 2048
      refute remaining =~ "noise-001"
      refute remaining =~ "\e["
      assert String.valid?(remaining)

      # The tail is front-loaded: the CLI's last line comes first, so it
      # survives the fixed prefix plus the dashboard retry row's 120-character
      # cut. Chronological order pushed it past every status surface.
      assert String.starts_with?(remaining, ~s({"error":"unknown provider for model"}))

      retry_row_error =
        "agent exited: Agent run failed: #{inspect({:agent_exit, 1, remaining})} (issue_id=issue-exit-bound issue_identifier=MT-2003)"

      assert String.slice(retry_row_error, 0, 120) =~ "unknown provider"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes bare mode and permission flags" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-flags-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2002")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-flags.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo "$@" >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-flags"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary,
        claude_permission_mode: "plan",
        claude_allowed_tools: "Bash,Read",
        agent_model: "claude-sonnet-4-6",
        claude_bare_mode: true,
        claude_output_format: "json"
      )

      issue = %Issue{
        id: "issue-flags",
        identifier: "MT-2002",
        title: "Flag passing",
        description: "Ensure app server passes claude flags correctly",
        state: "In Progress",
        url: "https://example.org/issues/MT-2002",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-flags"}} =
               Runner.run(workspace, "do the thing", issue)

      flags = File.read!(trace_file)
      assert flags =~ "--bare"
      assert flags =~ "--output-format"
      assert flags =~ "--permission-mode"
      assert flags =~ "plan"
      assert flags =~ "--allowedTools"
      assert flags =~ "Bash,Read"
      assert flags =~ "--model"
      assert flags =~ "claude-sonnet-4-6"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server exposes Linear and GitHub auth env to local Claude process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-local-env-#{System.unique_integer([:positive])}"
      )

    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2004")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-env.trace")

      File.mkdir_p!(workspace)
      System.put_env("GH_TOKEN", "gh-test-token")
      System.put_env("GITHUB_TOKEN", "github-test-token")

      File.write!(claude_binary, """
      #!/bin/sh
      {
        printf 'LINEAR_API_KEY=%s\\n' "$LINEAR_API_KEY"
        printf 'GH_TOKEN=%s\\n' "$GH_TOKEN"
        printf 'GITHUB_TOKEN=%s\\n' "$GITHUB_TOKEN"
      } > "#{trace_file}"
      echo '{"result":"done","session_id":"sess-env"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-config-token",
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-env",
        identifier: "MT-2004",
        title: "Environment passing",
        description: "Ensure app server passes auth env",
        state: "In Progress",
        url: "https://example.org/issues/MT-2004",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-env"}} =
               Runner.run(workspace, "do the thing", issue)

      trace = File.read!(trace_file)
      assert trace =~ "LINEAR_API_KEY=linear-config-token"
      assert trace =~ "GH_TOKEN=gh-test-token"
      assert trace =~ "GITHUB_TOKEN=github-test-token"
    after
      File.rm_rf(test_root)
    end
  end

  test "config provider env wins over shell provider and filters other agent secrets" do
    root = Path.join(System.tmp_dir!(), "cymphony-provider-map-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "MT-CONFIG-PROVIDER")
    binary = Path.join(root, "fake-claude")
    trace = Path.join(root, "env.trace")
    previous_config_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    previous_shell_cmd = Application.get_env(:cymphony_elixir, :shell_provider_cmd)
    previous_openai_api_key = System.get_env("OPENAI_API_KEY")

    try do
      # The child inherits host environment. Isolate this variable so the
      # assertion checks only that the other agent's config key was filtered.
      System.delete_env("OPENAI_API_KEY")
      File.mkdir_p!(workspace)
      Application.put_env(:cymphony_elixir, :config_dir_override, root)

      Application.put_env(:cymphony_elixir, :shell_provider_cmd, fn _, _, _ ->
        flunk("config provider must not invoke shell fallback")
      end)

      :ok =
        CymphonyConfig.save(%{
          "projects" => [],
          "providers" => %{
            "cz" => %{
              "ANTHROPIC_API_KEY" => "from-config",
              "OPENAI_API_KEY" => "wrong-agent"
            }
          }
        })

      File.write!(
        binary,
        "#!/bin/sh\nprintf 'ANTHROPIC_API_KEY=%s\\nOPENAI_API_KEY=%s\\n' \"$ANTHROPIC_API_KEY\" \"$OPENAI_API_KEY\" > '#{trace}'\necho '{\"result\":\"done\",\"session_id\":\"configured\"}'\n"
      )

      File.chmod!(binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: binary,
        claude_provider: "cz"
      )

      issue = %Issue{
        id: "provider-map",
        identifier: "MT-CONFIG-PROVIDER",
        title: "Auth",
        description: "",
        state: "In Progress",
        url: "https://example.test/issue",
        labels: []
      }

      assert {:ok, %{session_id: "configured"}} = Runner.run(workspace, "go", issue)
      assert File.read!(trace) == "ANTHROPIC_API_KEY=from-config\nOPENAI_API_KEY=\n"
    after
      if previous_config_dir do
        Application.put_env(:cymphony_elixir, :config_dir_override, previous_config_dir)
      else
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      end

      if previous_shell_cmd do
        Application.put_env(:cymphony_elixir, :shell_provider_cmd, previous_shell_cmd)
      else
        Application.delete_env(:cymphony_elixir, :shell_provider_cmd)
      end

      restore_env("OPENAI_API_KEY", previous_openai_api_key)
      File.rm_rf(root)
    end
  end

  test "app server exports Linear and GitHub auth env to ssh Claude process" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-remote-env-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("ANTHROPIC_API_KEY", previous_anthropic_api_key)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = "/remote/workspaces/MT-2005"
      fake_ssh = Path.join(test_root, "ssh")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "ssh-env.trace")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("GH_TOKEN", "gh-test-token")
      System.put_env("GITHUB_TOKEN", "github-test-token")

      File.write!(fake_ssh, """
      #!/bin/sh
      IFS= read -r _guard_ready || exit 1
      printf '%s\\n' "$@" > "#{trace_file}"
      echo '{"result":"done","session_id":"sess-remote-env"}'
      """)

      File.write!(claude_binary, """
      #!/bin/sh
      echo '{"result":"done","session_id":"unused"}'
      """)

      File.chmod!(fake_ssh, 0o755)
      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "linear-config-token",
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-remote-env",
        identifier: "MT-2005",
        title: "Remote environment passing",
        description: "Ensure app server exports auth env for SSH workers",
        state: "In Progress",
        url: "https://example.org/issues/MT-2005",
        labels: ["backend"]
      }

      assert {:ok, %{session_id: "sess-remote-env"}} =
               Runner.run(workspace, "do the thing", issue, worker_host: "worker.example")

      trace = File.read!(trace_file)
      assert trace =~ "export LINEAR_API_KEY="
      assert trace =~ "linear-config-token"
      assert trace =~ "export GH_TOKEN="
      assert trace =~ "gh-test-token"
      assert trace =~ "export GITHUB_TOKEN="
      assert trace =~ "github-test-token"
      refute trace =~ "export PATH="
      refute trace =~ "export HOME="
    after
      File.rm_rf(test_root)
    end
  end

  test "app server resumes session with --resume flag" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-app-server-resume-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2003")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude-resume.trace")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo "$@" >> "#{trace_file}"
      echo '{"result":"done","session_id":"sess-resume-123"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-resume",
        identifier: "MT-2003",
        title: "Session resume",
        description: "Ensure app server passes --resume for continuation",
        state: "In Progress",
        url: "https://example.org/issues/MT-2003",
        labels: ["backend"]
      }

      {:ok, session} = Runner.start_session(workspace)

      # First turn
      assert {:ok, %{session_id: first_session_id}} =
               Runner.run_turn(session, "first turn", issue)

      # Second turn should resume
      session = %{session | session_id: first_session_id}

      assert {:ok, %{session_id: ^first_session_id}} =
               Runner.run_turn(session, "second turn", issue)

      flags = File.read!(trace_file)
      assert flags =~ "--resume #{first_session_id}"
    after
      File.rm_rf(test_root)
    end
  end

  test "runner drives a codex-kind session through the codex adapter" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-runner-codex-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-3001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")

      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      echo "$@" > "#{trace_file}"
      echo '{"type":"thread.started","thread_id":"t-e2e"}'
      echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"done"}}'
      echo '{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":2}}'
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "codex",
        agent_model: "gpt-5.2-codex",
        agent_effort: "high",
        codex_command: codex_binary
      )

      issue = %Issue{
        id: "issue-codex-e2e",
        identifier: "MT-3001",
        title: "Codex path",
        description: "drive codex adapter",
        state: "In Progress",
        url: "https://example.org/issues/MT-3001"
      }

      assert {:ok, %{session_id: "t-e2e", result: %{result: "done", usage: usage}}} =
               Runner.run(workspace, "do it", issue)

      assert usage["total_tokens"] == 10

      args = File.read!(trace_file)
      assert args =~ "exec"
      assert args =~ "--json"
      assert args =~ "-m gpt-5.2-codex"
      assert args =~ "model_reasoning_effort"
    after
      File.rm_rf(test_root)
    end
  end

  test "emits harness_stdout for each completed line before parse_output and turn_completed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-harness-stdout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-5000")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo 'first-harness-line'
      echo '{"result":"done","session_id":"sess-harness","usage":{"input_tokens":1,"output_tokens":1}}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-harness-stdout",
        identifier: "MT-5000",
        title: "Harness stdout",
        description: "Emit incremental harness_stdout before parse_output",
        state: "In Progress",
        url: "https://example.org/issues/MT-5000",
        labels: ["backend"]
      }

      {:ok, collector} = Agent.start_link(fn -> [] end)

      on_message = fn message ->
        Agent.update(collector, fn messages -> messages ++ [message] end)
      end

      assert {:ok, %{session_id: "sess-harness"}} =
               Runner.run(workspace, "do the thing", issue, on_message: on_message)

      messages = Agent.get(collector, & &1)
      events = Enum.map(messages, & &1.event)
      harness = Enum.filter(messages, &(&1.event == :harness_stdout))

      assert length(harness) == 2
      assert Enum.at(harness, 0).raw =~ "first-harness-line"
      assert Enum.at(harness, 1).raw =~ "sess-harness"
      assert match?(%DateTime{}, Enum.at(harness, 0).timestamp)
      assert match?(%DateTime{}, Enum.at(harness, 1).timestamp)

      first_harness = Enum.find_index(events, &(&1 == :harness_stdout))
      last_harness = length(events) - 1 - Enum.find_index(Enum.reverse(events), &(&1 == :harness_stdout))
      completed = Enum.find_index(events, &(&1 == :turn_completed))
      stream_event = Enum.find_index(events, &(&1 == :stream_event))

      assert first_harness < completed
      assert last_harness < completed
      refute :stream_event in Enum.take(events, last_harness + 1)

      if stream_event do
        assert last_harness < stream_event
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "emits harness_stdout for a leftover buffer on exit 0" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-harness-leftover-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-5001")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      printf 'first-harness-line\\n'
      printf '{"result":"done","session_id":"sess-leftover"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-harness-leftover",
        identifier: "MT-5001",
        title: "Harness leftover",
        description: "Leftover buffer on exit 0 is emitted as harness_stdout",
        state: "In Progress",
        url: "https://example.org/issues/MT-5001",
        labels: ["backend"]
      }

      {:ok, collector} = Agent.start_link(fn -> [] end)

      on_message = fn message ->
        Agent.update(collector, fn messages -> messages ++ [message] end)
      end

      assert {:ok, %{session_id: "sess-leftover"}} =
               Runner.run(workspace, "do the thing", issue, on_message: on_message)

      messages = Agent.get(collector, & &1)
      harness = Enum.filter(messages, &(&1.event == :harness_stdout))
      events = Enum.map(messages, & &1.event)

      assert length(harness) == 2
      assert Enum.at(harness, 0).raw =~ "first-harness-line"
      assert Enum.at(harness, 1).raw =~ "sess-leftover"
      assert Enum.find_index(events, &(&1 == :harness_stdout)) < Enum.find_index(events, &(&1 == :turn_completed))
    after
      File.rm_rf(test_root)
    end
  end

  test "slices harness_stdout raw to 2048 characters" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-harness-slice-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-5002")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      awk 'BEGIN{for(i=0;i<3000;i++) printf "x"; print ""}'
      echo '{"result":"done","session_id":"sess-slice"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-harness-slice",
        identifier: "MT-5002",
        title: "Harness slice",
        description: "Long harness lines are sliced to 2048",
        state: "In Progress",
        url: "https://example.org/issues/MT-5002",
        labels: ["backend"]
      }

      {:ok, collector} = Agent.start_link(fn -> [] end)

      on_message = fn message ->
        Agent.update(collector, fn messages -> messages ++ [message] end)
      end

      assert {:ok, %{session_id: "sess-slice"}} =
               Runner.run(workspace, "do the thing", issue, on_message: on_message)

      harness = collector |> Agent.get(& &1) |> Enum.filter(&(&1.event == :harness_stdout))
      long_line = Enum.find(harness, &String.starts_with?(&1.raw, "x"))

      assert long_line
      assert String.length(long_line.raw) == 2048
    after
      File.rm_rf(test_root)
    end
  end

  test "emits harness_stdout for completed lines even when the process later exits nonzero" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-harness-exit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-5003")
      claude_binary = Path.join(test_root, "fake-claude")

      File.mkdir_p!(workspace)

      File.write!(claude_binary, """
      #!/bin/sh
      echo 'before-fail'
      printf 'leftover-not-emitted'
      exit 1
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: claude_binary
      )

      issue = %Issue{
        id: "issue-harness-exit",
        identifier: "MT-5003",
        title: "Harness nonzero exit",
        description: "eol lines emit; leftover on nonzero does not; no parse_output",
        state: "In Progress",
        url: "https://example.org/issues/MT-5003",
        labels: ["backend"]
      }

      {:ok, collector} = Agent.start_link(fn -> [] end)

      on_message = fn message ->
        Agent.update(collector, fn messages -> messages ++ [message] end)
      end

      assert {:error, {:agent_exit, 1, remaining}} =
               Runner.run(workspace, "do the thing", issue, on_message: on_message)

      assert remaining =~ "leftover-not-emitted"

      messages = Agent.get(collector, & &1)
      events = Enum.map(messages, & &1.event)
      harness = Enum.filter(messages, &(&1.event == :harness_stdout))

      assert length(harness) == 1
      assert Enum.at(harness, 0).raw =~ "before-fail"
      refute Enum.any?(harness, &(&1.raw =~ "leftover-not-emitted"))
      assert :turn_ended_with_error in events
      refute :turn_completed in events
      refute :stream_event in events
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session routes antigravity kind to the antigravity settings section" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-antigravity-section-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-4000")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "/bin/false-claude",
        claude_provider: "claude-only"
      )

      stub_settings = %{
        agent: %{kind: "claude", model: nil, effort: nil},
        claude: %{command: "/bin/false-claude", provider: "claude-only"},
        antigravity: %{
          command: "agy-from-section",
          output_format: "stream-json",
          skip_permissions: true,
          sandbox: false,
          print_timeout: nil,
          extra_args: nil,
          provider: "agy-provider",
          providers: []
        },
        workspace: %{root: workspace_root},
        tracker: %{kind: "linear", api_key: "token"}
      }

      assert {:ok, session} =
               Runner.start_session(workspace, config: stub_settings, agent_kind: "antigravity")

      assert session.run_spec.kind == "antigravity"
      assert session.run_spec.settings.command == "agy-from-section"
      assert session.run_spec.settings.provider == "agy-provider"
      assert session.run_spec.provider == "agy-provider"
      assert session.agent_module == CymphonyElixir.Agent.Antigravity
      refute session.run_spec.settings.command == stub_settings.claude.command
    after
      File.rm_rf(test_root)
    end
  end

  test "start_session uses schema antigravity defaults when kind is antigravity" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-antigravity-schema-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-4001")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "/bin/false-claude",
        claude_provider: "claude-only"
      )

      settings = Config.settings!()

      assert {:ok, session} =
               Runner.start_session(workspace, config: settings, agent_kind: "antigravity")

      assert session.run_spec.kind == "antigravity"
      assert session.run_spec.settings.command == "agy"
      assert session.run_spec.settings.output_format == "stream-json"
      assert session.run_spec.settings.skip_permissions == true
      assert session.run_spec.settings.new_project == true
      refute session.run_spec.settings.command == settings.claude.command

      # The adapter learns the workspace from the run_spec the runner built, so
      # agy's own log lands beside the session instead of in ~/.gemini.
      assert {:ok, command} =
               session.agent_module.build_command(%{session.run_spec | prompt: "go"})

      assert command =~ "--new-project"

      # Beside the workspace, not inside it: the workspace is the cloned repo.
      log_path = Path.join(Path.dirname(session.workspace), ".agy-#{Path.basename(session.workspace)}.log")
      assert command =~ "--log-file '#{log_path}'"
      refute command =~ "'#{session.workspace}/"
    after
      File.rm_rf(test_root)
    end
  end
end
