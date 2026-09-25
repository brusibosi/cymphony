defmodule CymphonyElixir.ProjectContextHardeningTest do
  use CymphonyElixir.TestSupport

  test "issue cleanup uses the given project's root and hooks, not the default project" do
    base = Path.join(System.tmp_dir!(), "cymphony-context-#{System.unique_integer([:positive])}")
    default_root = Path.join(base, "default")
    project_root = Path.join(base, "project")
    File.mkdir_p!(Path.join(default_root, "CTX-1"))
    File.mkdir_p!(Path.join(project_root, "CTX-1"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: default_root)
    config = %{Config.settings!() | workspace: %{Config.settings!().workspace | root: project_root}}

    try do
      assert :ok = Workspace.remove_issue_workspaces("CTX-1", nil, config: config)
      refute File.exists?(Path.join(project_root, "CTX-1"))
      assert File.dir?(Path.join(default_root, "CTX-1"))
    after
      File.rm_rf(base)
    end
  end

  test "remote workspace rejects a symlink escape before create, hook, launch, or deletion" do
    base = Path.join(System.tmp_dir!(), "cymphony-remote-guard-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspaces")
    outside = Path.join(base, "outside")
    workspace = Path.join(root, "CTX-2")
    fake_ssh = Path.join(base, "ssh")
    old_path = System.get_env("PATH")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "safe")
    File.ln_s!(outside, workspace)
    File.write!(fake_ssh, "#!/bin/sh\nfor arg do command=$arg; done\nexec sh -c \"$command\"\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", base <> ":" <> (old_path || ""))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    config = Config.settings!()

    try do
      assert {:error, _} = Workspace.create_for_issue("CTX-2", "worker.example", config: config)
      assert {:error, _} = Runner.start_session(workspace, worker_host: "worker.example", config: config)
      assert {:error, _, _} = Workspace.remove(workspace, "worker.example", config: config)
      assert {:error, _, _} = Workspace.remove(root, "worker.example", config: config)
      assert File.read!(Path.join(outside, "sentinel")) == "safe"
      assert File.dir?(outside)
      assert File.dir?(root)
    after
      restore_env("PATH", old_path)
      File.rm_rf(base)
    end
  end

  test "remote operations preserve a configured root containing spaces and quotes" do
    base = Path.join(System.tmp_dir!(), "cymphony-remote-escape-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspace root's")
    fake_ssh = Path.join(base, "ssh")
    old_path = System.get_env("PATH")
    File.mkdir_p!(root)
    File.write!(fake_ssh, "#!/bin/sh\nfor arg do command=$arg; done\nexec sh -c \"$command\"\n")
    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", base <> ":" <> (old_path || ""))
    default = Config.settings!()

    config = %{
      default
      | workspace: %{default.workspace | root: root},
        hooks: %{default.hooks | after_create: "touch hook-ran"}
    }

    try do
      assert {:ok, workspace} = Workspace.create_for_issue("CTX-5", "worker.example", config: config)
      assert File.exists?(Path.join(workspace, "hook-ran"))
      assert {:ok, []} = Workspace.remove(workspace, "worker.example", config: config)
      refute File.exists?(workspace)
      File.write!(Path.join(root, "CTX-5"), "stale file")
      assert {:ok, ^workspace} = Workspace.create_for_issue("CTX-5", "worker.example", config: config)
      assert File.dir?(workspace)
      assert File.dir?(root)
    after
      restore_env("PATH", old_path)
      File.rm_rf(base)
    end
  end

  test "Linear assignee me resolves viewer using the current project's API key" do
    parent = self()

    plug = fn conn, _opts ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:linear_request, Plug.Conn.get_req_header(conn, "authorization"), body})

      response =
        if String.contains?(body, "CymphonyLinearViewer") do
          %{"data" => %{"viewer" => %{"id" => "project-user"}}}
        else
          %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}/graphql"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: endpoint,
      tracker_api_token: "default-token",
      tracker_assignee: "me"
    )

    default = Config.settings!()
    assert default.tracker.assignee == "me"
    project = %{default | tracker: %{default.tracker | api_key: "project-token"}}

    assert {:ok, []} = Client.fetch_candidate_issues(project)
    assert_receive {:linear_request, viewer_headers, viewer_body}
    assert viewer_body =~ "CymphonyLinearViewer"
    assert viewer_headers == ["project-token"]
    assert_receive {:linear_request, ["project-token"], poll_body}
    assert poll_body =~ "CymphonyLinearPoll"
  end

  test "remote launch rechecks containment after a workspace is replaced by a symlink" do
    base = Path.join(System.tmp_dir!(), "cymphony-remote-launch-#{System.unique_integer([:positive])}")
    root = Path.join(base, "workspaces")
    workspace = Path.join(root, "CTX-4")
    outside = Path.join(base, "outside")
    fake_agent = Path.join(base, "claude")
    fake_ssh = Path.join(base, "ssh")
    old_path = System.get_env("PATH")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.write!(fake_ssh, "#!/bin/sh\nfor arg do command=$arg; done\nexec sh -c \"$command\"\n")
    File.write!(fake_agent, "#!/bin/sh\npwd > #{Path.join(base, "launched")}\necho '{\"result\":\"done\"}'\n")
    File.chmod!(fake_ssh, 0o755)
    File.chmod!(fake_agent, 0o755)
    System.put_env("PATH", base <> ":" <> (old_path || ""))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, claude_command: fake_agent)

    try do
      assert {:ok, session} = Runner.start_session(workspace, worker_host: "worker.example")
      File.rm_rf!(workspace)
      File.ln_s!(outside, workspace)
      issue = %Issue{id: "ctx-4", identifier: "CTX-4", title: "guard", state: "In Progress"}
      assert {:error, _} = Runner.run_turn(session, "guard", issue)
      refute File.exists?(Path.join(base, "launched"))
    after
      restore_env("PATH", old_path)
      File.rm_rf(base)
    end
  end

  test "orchestrator snapshot publishes the project workspace root and stall timeout" do
    root = Path.join(System.tmp_dir!(), "cymphony-snapshot-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      stall_timeout_ms: 12_345
    )

    {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, SnapshotOrchestrator))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    snapshot = Orchestrator.snapshot(pid, 1000)
    assert snapshot.workspace_root == root
    assert snapshot.stall_timeout_ms == 12_345
  end
end
