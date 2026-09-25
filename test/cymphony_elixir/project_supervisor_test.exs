defmodule CymphonyElixir.ProjectSupervisorTest do
  # async: false — registers keys on the global ProjectRegistry.
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixir.WorkflowStore

  test "via_tuple/2 builds a ProjectRegistry via tuple" do
    assert ProjectSupervisor.via_tuple("Farm", :orchestrator) ==
             {:via, Registry, {CymphonyElixir.ProjectRegistry, {"Farm", :orchestrator}}}
  end

  test "lookup/2 returns the registered pid or nil" do
    name = "lookup-#{System.unique_integer([:positive])}"
    assert ProjectSupervisor.lookup(name, :orchestrator) == nil

    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, :meta)
    assert ProjectSupervisor.lookup(name, :orchestrator) == self()
  end

  test "list_project_names/0 and list_orchestrators/0 filter registry entries" do
    name = "listed-#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :supervisor}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :workflow_store}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, nil)
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {:not_binary, :orchestrator}, nil)

    assert name in ProjectSupervisor.list_project_names()
    assert {name, self()} in ProjectSupervisor.list_orchestrators()
    refute Enum.any?(ProjectSupervisor.list_orchestrators(), fn {project, _} -> project == :not_binary end)
  end

  test "list_project_names/0 rescues when a registry key is not a {name, role} tuple" do
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, :not_a_tuple, nil)
    assert ProjectSupervisor.list_project_names() == []
  end

  test "list_project_names/1 and list_orchestrators/1 return [] when the registry is missing" do
    missing = :"missing_registry_#{System.unique_integer([:positive])}"
    assert ProjectSupervisor.list_project_names(missing) == []
    assert ProjectSupervisor.list_orchestrators(missing) == []
  end

  test "init/1 builds a one_for_all runtime with store, task supervisor and orchestrator" do
    assert {:ok, {flags, children}} =
             ProjectSupervisor.init(project_name: "Farm", workflow_path: "/tmp/WORKFLOW.md")

    assert flags.strategy == :one_for_all
    assert length(children) == 4
  end

  test "start_link/1 fails when the workflow file is missing" do
    name = "missing-wf-#{System.unique_integer([:positive])}"
    missing = Path.join(System.tmp_dir!(), "cymphony-ps-missing-#{System.unique_integer([:positive])}.md")

    assert {:error, reason} =
             start_supervised({ProjectSupervisor, [project_name: name, workflow_path: missing]})

    assert inspect(reason) =~ "missing_workflow_file"
    assert inspect(reason) =~ missing
    assert ProjectSupervisor.lookup(name, :supervisor) == nil
  end

  test "start_link/1 starts the workflow store and orchestrator under the registry" do
    name = "started-#{System.unique_integer([:positive])}"
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory", poll_interval_ms: 60_000)

    pid = start_supervised!({ProjectSupervisor, [project_name: name, workflow_path: path]})
    assert Process.alive?(pid)

    store = ProjectSupervisor.lookup(name, :workflow_store)
    orch = ProjectSupervisor.lookup(name, :orchestrator)

    assert is_pid(store)
    assert is_pid(orch)
    assert name in ProjectSupervisor.list_project_names()
    assert {name, orch} in ProjectSupervisor.list_orchestrators()
    assert {:ok, %{prompt: _}} = CymphonyElixir.WorkflowStore.current(store)
  end

  test "start_project/2 starts the workflow store and orchestrator from a fixture" do
    name = "hot-start-#{System.unique_integer([:positive])}"

    workspace = Path.join(System.tmp_dir!(), "cymphony-ws-#{System.unique_integer([:positive])}")

    {:ok, path} =
      WorkflowGenerator.write_temp(%{
        "name" => name,
        "linear_project_slug" => "hot-slug",
        "linear_api_key" => "lin_test",
        "polling_interval_ms" => 60_000,
        "workspace_root" => workspace,
        "agent" => "claude"
      })

    write_workflow_file!(path, tracker_kind: "memory", poll_interval_ms: 60_000)

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      File.rm(path)
    end)

    assert :ok = ProjectSupervisor.start_project(name, path)

    store = ProjectSupervisor.lookup(name, :workflow_store)
    orch = ProjectSupervisor.lookup(name, :orchestrator)

    assert is_pid(store)
    assert is_pid(orch)
    assert Process.alive?(store)
    assert Process.alive?(orch)
    assert WorkflowStore.path(store) == path
    assert {:ok, %{prompt: _}} = WorkflowStore.current(store)
    assert name in ProjectSupervisor.list_project_names()
    assert {name, orch} in ProjectSupervisor.list_orchestrators()
  end

  test "start_project/2 returns :ok when the project is already started" do
    name = "already-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!()

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      File.rm(path)
    end)

    assert :ok = ProjectSupervisor.start_project(name, path)
    pid = ProjectSupervisor.lookup(name, :supervisor)
    assert is_pid(pid)
    assert :ok = ProjectSupervisor.start_project(name, path)
    assert ProjectSupervisor.lookup(name, :supervisor) == pid
  end

  test "start_project/2 returns the start error when the workflow file is missing" do
    name = "missing-hot-#{System.unique_integer([:positive])}"
    missing = Path.join(System.tmp_dir!(), "cymphony-ps-hot-missing-#{System.unique_integer([:positive])}.md")

    assert {:error, reason} = ProjectSupervisor.start_project(name, missing)
    assert inspect(reason) =~ "missing_workflow_file"
    assert inspect(reason) =~ missing
    assert ProjectSupervisor.lookup(name, :supervisor) == nil
  end

  test "stop_project/1 terminates the project and unregisters it" do
    name = "hot-stop-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!()

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      File.rm(path)
    end)

    assert :ok = ProjectSupervisor.start_project(name, path)
    assert is_pid(ProjectSupervisor.lookup(name, :supervisor))
    assert :ok = ProjectSupervisor.stop_project(name)

    assert ProjectSupervisor.lookup(name, :supervisor) == nil
    assert ProjectSupervisor.lookup(name, :workflow_store) == nil
    assert ProjectSupervisor.lookup(name, :orchestrator) == nil
    refute name in ProjectSupervisor.list_project_names()
  end

  test "stop_project/1 returns :not_found when the project is not registered" do
    assert {:error, :not_found} =
             ProjectSupervisor.stop_project("ghost-#{System.unique_integer([:positive])}")
  end

  test "stop_project/1 returns :not_found when the supervisor is not a DynamicSupervisor child" do
    name = "exunit-child-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!()

    on_exit(fn -> File.rm(path) end)

    start_supervised!({ProjectSupervisor, [project_name: name, workflow_path: path]})
    assert is_pid(ProjectSupervisor.lookup(name, :supervisor))
    assert {:error, :not_found} = ProjectSupervisor.stop_project(name)
  end

  test "rewrite_workflow/1 updates agent.kind in WorkflowStore.current after Config.update_agent_settings" do
    tmp = Path.join(System.tmp_dir!(), "cymphony-rewrite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    name = "rewrite-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!(agent_kind: "claude")

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm(path)
      File.rm_rf!(tmp)
    end)

    project = %{
      "name" => name,
      "linear_project_slug" => "rewrite-slug",
      "linear_api_key" => "lin_test",
      "workspace_root" => Path.join(tmp, "workspaces"),
      "polling_interval_ms" => 60_000,
      "agent" => "claude"
    }

    :ok = CymphonyConfig.save(%{"projects" => [project]})

    assert :ok = ProjectSupervisor.start_project(name, path)
    store = ProjectSupervisor.lookup(name, :workflow_store)
    assert WorkflowStore.path(store) == path

    assert {:ok, %{config: before}} = WorkflowStore.current(store)
    assert before["agent"]["kind"] == "claude"

    # A file generated by an older build (or by a hand-authored fixture) carries
    # umask permissions; the rewrite must tighten it, since it gains the
    # plaintext Linear key.
    File.chmod!(path, 0o644)

    assert :ok = CymphonyConfig.update_agent_settings(name, %{"agent" => "codex"})
    assert :ok = ProjectSupervisor.rewrite_workflow(name)

    assert {:ok, %{config: rewritten}} = WorkflowStore.current(store)
    assert rewritten["agent"]["kind"] == "codex"
    assert rewritten["tracker"]["api_key"] == "lin_test"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "rewrite_workflow/1 returns :not_found when the store is not running" do
    assert {:error, :not_found} =
             ProjectSupervisor.rewrite_workflow("ghost-#{System.unique_integer([:positive])}")
  end

  test "rewrite_workflow/1 returns a load error when config.json is missing" do
    tmp = Path.join(System.tmp_dir!(), "cymphony-rewrite-missing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    name = "rewrite-noconfig-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!()

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm(path)
      File.rm_rf!(tmp)
    end)

    assert :ok = ProjectSupervisor.start_project(name, path)
    assert {:error, reason} = ProjectSupervisor.rewrite_workflow(name)
    assert is_binary(reason)
    assert reason =~ "Failed to read"
  end

  test "rewrite_workflow/1 returns :project_not_found when the project is absent from config.json" do
    tmp = Path.join(System.tmp_dir!(), "cymphony-rewrite-absent-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    name = "rewrite-absent-#{System.unique_integer([:positive])}"
    path = memory_workflow_path!()

    on_exit(fn ->
      _ = ProjectSupervisor.stop_project(name)
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      File.rm(path)
      File.rm_rf!(tmp)
    end)

    :ok = CymphonyConfig.save(%{"projects" => [%{"name" => "other", "linear_api_key" => "lin_test"}]})

    assert :ok = ProjectSupervisor.start_project(name, path)
    assert {:error, :project_not_found} = ProjectSupervisor.rewrite_workflow(name)
  end

  test "await_unregistered/2 gives up once its budget is spent" do
    name = "lingering-#{System.unique_integer([:positive])}"

    # The test process holds the name for the whole test, so the only way out of
    # the wait is exhausting the budget.
    {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {name, :orchestrator}, nil)

    started = System.monotonic_time(:millisecond)
    assert :ok = ProjectSupervisor.await_unregistered(name, 20)
    assert System.monotonic_time(:millisecond) - started >= 20
  end

  test "await_unregistered/2 returns immediately when nothing is registered" do
    assert :ok =
             ProjectSupervisor.await_unregistered("free-#{System.unique_integer([:positive])}", 20)
  end

  defp memory_workflow_path!(overrides \\ []) do
    path = Path.join(System.tmp_dir!(), "cymphony-ps-#{System.unique_integer([:positive])}.md")

    write_workflow_file!(
      path,
      Keyword.merge([tracker_kind: "memory", poll_interval_ms: 60_000], overrides)
    )

    path
  end
end
