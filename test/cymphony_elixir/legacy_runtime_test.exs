defmodule CymphonyElixir.LegacyRuntimeTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.LegacySupervisor

  setup do
    on_exit(fn ->
      case Process.whereis(LegacySupervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(CymphonyElixir.ProjectDynamicSupervisor, pid)
      end
    end)

    :ok
  end

  test "legacy CLI starts a supervised store and orchestrator when the application is already running" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory")
    assert Process.whereis(CymphonyElixir.Supervisor)

    assert :ok = CLI.evaluate([path])

    supervisor = Process.whereis(LegacySupervisor)
    store = Process.whereis(WorkflowStore)
    orchestrator = Process.whereis(Orchestrator)
    assert is_pid(supervisor)
    assert is_pid(store)
    assert is_pid(orchestrator)
    assert {:ok, %{prompt: "You are an agent for this repository."}} = WorkflowStore.current()
    assert Enum.any?(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == store end)
    assert Enum.any?(Supervisor.which_children(supervisor), fn {_, pid, _, _} -> pid == orchestrator end)

    assert Enum.any?(DynamicSupervisor.which_children(CymphonyElixir.ProjectDynamicSupervisor), fn
             {_, pid, _, _} -> pid == supervisor
           end)
  end

  test "repeated legacy CLI startup keeps the same supervised runtime" do
    path = Workflow.workflow_file_path()
    write_workflow_file!(path, tracker_kind: "memory")

    assert :ok = CLI.evaluate([path])
    first = {Process.whereis(LegacySupervisor), Process.whereis(WorkflowStore), Process.whereis(Orchestrator)}
    assert :ok = CLI.evaluate([path])
    assert first == {Process.whereis(LegacySupervisor), Process.whereis(WorkflowStore), Process.whereis(Orchestrator)}
  end

  test "a second legacy startup rejects a different workflow without changing the running one" do
    first_path = Workflow.workflow_file_path()
    write_workflow_file!(first_path, tracker_kind: "memory", prompt: "First workflow")
    assert :ok = CLI.evaluate([first_path])
    first_runtime = {Process.whereis(LegacySupervisor), Process.whereis(WorkflowStore), Process.whereis(Orchestrator)}

    second_path = Path.join(Path.dirname(first_path), "BROKEN_WORKFLOW.md")
    File.write!(second_path, "---\ntracker: [\n---\n")

    assert {:error, message} = CLI.evaluate([second_path])
    assert message =~ "already running with workflow"
    assert message =~ first_path
    assert Workflow.workflow_file_path() == first_path
    assert WorkflowStore.path(Process.whereis(WorkflowStore)) == first_path
    assert {:ok, %{prompt: "First workflow"}} = WorkflowStore.current()

    assert first_runtime ==
             {Process.whereis(LegacySupervisor), Process.whereis(WorkflowStore), Process.whereis(Orchestrator)}
  end

  test "malformed legacy workflow returns a startup error without a runtime" do
    path = Workflow.workflow_file_path()
    File.write!(path, "---\ntracker: [\n---\n")

    assert {:error, message} = CLI.evaluate([path])
    assert message =~ "Failed to start Cymphony with workflow"
    assert Process.whereis(LegacySupervisor) == nil
    assert Process.whereis(WorkflowStore) == nil
    assert Process.whereis(Orchestrator) == nil
  end

  test "invalid legacy workflow config returns a startup error without a runtime" do
    path = Workflow.workflow_file_path()
    File.write!(path, "---\nagent:\n  max_concurrent_agents: banana\n---\nPrompt\n")

    assert {:error, message} = CLI.evaluate([path])
    assert message =~ "Failed to start Cymphony with workflow"
    assert Process.whereis(LegacySupervisor) == nil
    assert Process.whereis(WorkflowStore) == nil
    assert Process.whereis(Orchestrator) == nil
  end

  test "multi-project CLI starts only its named project runtime" do
    config_dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "config")
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, "config.json"),
      Jason.encode!(%{
        "projects" => [
          %{
            "name" => "LegacyIsolation",
            "github_repo_url" => "git@github.com:example/repo.git",
            "linear_project_slug" => "team-abc",
            "linear_api_key" => "lin_test",
            "workspace_root" => Path.join(config_dir, "workspaces"),
            "polling_interval_ms" => 30_000
          }
        ]
      })
    )

    previous = Application.get_env(:cymphony_elixir, :config_dir_override)
    Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)

    on_exit(fn ->
      CymphonyElixir.ProjectSupervisor.stop_project("LegacyIsolation")

      if previous do
        Application.put_env(:cymphony_elixir, :config_dir_override, previous)
      else
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      end
    end)

    assert :ok = CLI.evaluate(["--project", "LegacyIsolation"])
    assert is_pid(CymphonyElixir.ProjectSupervisor.lookup("LegacyIsolation", :workflow_store))
    assert is_pid(CymphonyElixir.ProjectSupervisor.lookup("LegacyIsolation", :orchestrator))
    assert Process.whereis(LegacySupervisor) == nil
    assert Process.whereis(WorkflowStore) == nil
    assert Process.whereis(Orchestrator) == nil
  end
end
