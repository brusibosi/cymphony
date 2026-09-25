defmodule CymphonyElixir.Orchestrator.WorkflowHotReloadTest do
  # async: false — registers a project and redirects the process-wide config store.
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.ProjectSupervisor

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-hot-reload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_config_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    Application.put_env(:cymphony_elixir, :config_dir_override, root)

    project_name = "hot-reload-#{System.unique_integer([:positive])}"

    File.write!(
      Path.join(root, "config.json"),
      Jason.encode!(%{"projects" => [%{"name" => project_name, "dispatch_paused" => true}]})
    )

    workflow_path = Path.join(root, "WORKFLOW.md")

    on_exit(fn ->
      if previous_config_dir do
        Application.put_env(:cymphony_elixir, :config_dir_override, previous_config_dir)
      else
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      end

      File.rm_rf!(root)
    end)

    %{project_name: project_name, workflow_path: workflow_path}
  end

  test "workflow prompt and untouched typed defaults reload together", ctx do
    {orchestrator, store} =
      start_project!(ctx,
        prompt: "First prompt",
        max_concurrent_agents: 2,
        claude_providers: ["first"],
        agent_kind: "claude",
        poll_interval_ms: 40_000
      )

    assert %{prompt_template: "First prompt", max_concurrent_agents: 2, providers: ["first"]} =
             :sys.get_state(orchestrator)

    rewrite!(ctx, store,
      prompt: "Second prompt",
      max_concurrent_agents: 4,
      claude_providers: ["second"],
      agent_kind: "codex",
      agent_model: "gpt-new",
      agent_effort: "high",
      poll_interval_ms: 50_000
    )

    snapshot = Orchestrator.snapshot(orchestrator, 15_000)
    state = :sys.get_state(orchestrator)

    assert state.prompt_template == "Second prompt"
    assert state.poll_interval_ms == 50_000
    assert snapshot.polling.max_concurrent_agents == 4
    assert snapshot.providers == []
    assert snapshot.agent_kind == "codex"
    assert snapshot.agent_model == "gpt-new"
    assert snapshot.agent_effort == "high"
    assert snapshot.polling.paused
  end

  test "file provider list reloads for the active kind when no operator control changed it", ctx do
    {orchestrator, store} = start_project!(ctx, claude_providers: ["first"])

    rewrite!(ctx, store, claude_providers: ["second", "third"])

    assert Orchestrator.snapshot(orchestrator, 15_000).providers == ["second", "third"]
  end

  test "explicit runtime controls survive later file reloads without freezing other fields", ctx do
    {orchestrator, store} =
      start_project!(ctx,
        max_concurrent_agents: 2,
        claude_providers: ["first"],
        agent_kind: "claude",
        poll_interval_ms: 40_000
      )

    assert :ok = Orchestrator.set_concurrency(orchestrator, 7)
    assert :ok = Orchestrator.set_providers(orchestrator, ["operator"])
    assert :ok = Orchestrator.set_agent_settings(orchestrator, %{"agent" => "claude", "model" => "operator-model"})

    rewrite!(ctx, store,
      prompt: "Reloaded prompt",
      max_concurrent_agents: 4,
      claude_providers: ["file-new"],
      agent_kind: "codex",
      agent_model: "file-model",
      poll_interval_ms: 50_000
    )

    snapshot = Orchestrator.snapshot(orchestrator, 15_000)
    state = :sys.get_state(orchestrator)

    assert state.prompt_template == "Reloaded prompt"
    assert snapshot.polling.poll_interval_ms == 50_000
    assert snapshot.polling.max_concurrent_agents == 7
    assert snapshot.providers == ["operator"]
    assert snapshot.agent_kind == "claude"
    assert snapshot.agent_model == "operator-model"
  end

  test "an explicit model control does not freeze unrelated agent defaults", ctx do
    {orchestrator, store} =
      start_project!(ctx,
        agent_kind: "claude",
        agent_model: "initial-model",
        agent_effort: "low"
      )

    assert :ok = Orchestrator.set_agent_settings(orchestrator, %{"model" => "operator-model"})

    rewrite!(ctx, store,
      agent_kind: "codex",
      agent_model: "file-model",
      agent_effort: "high"
    )

    snapshot = Orchestrator.snapshot(orchestrator, 15_000)

    assert snapshot.agent_kind == "codex"
    assert snapshot.agent_model == "operator-model"
    assert snapshot.agent_effort == "high"
  end

  test "a malformed workflow keeps the last good prompt and configuration", ctx do
    {orchestrator, store} =
      start_project!(ctx,
        prompt: "Good prompt",
        max_concurrent_agents: 3,
        claude_providers: ["good"]
      )

    File.write!(ctx.workflow_path, "---\ntracker: [\n---\nBad prompt\n")
    assert {:error, _} = WorkflowStore.force_reload(store)

    snapshot = Orchestrator.snapshot(orchestrator, 15_000)
    state = :sys.get_state(orchestrator)

    assert state.prompt_template == "Good prompt"
    assert snapshot.polling.max_concurrent_agents == 3
    assert snapshot.providers == ["good"]
    assert snapshot.polling.paused
  end

  test "an in-flight run keeps its dispatched agent and provider after a workflow reload", ctx do
    {orchestrator, store} =
      start_project!(ctx,
        agent_kind: "claude",
        agent_model: "old-model",
        claude_providers: ["old-provider"]
      )

    issue = %Issue{
      id: "issue-in-flight",
      identifier: "HOT-1",
      title: "In-flight run",
      state: "In Progress",
      url: "https://example.test/HOT-1",
      labels: [],
      blocked_by: []
    }

    :sys.replace_state(orchestrator, fn state ->
      entry = %{
        identifier: issue.identifier,
        issue: issue,
        agent_kind: "claude",
        provider: "old-provider",
        model: "old-model",
        effort: nil,
        started_at: DateTime.utc_now()
      }

      %{state | running: Map.put(state.running, issue.id, entry)}
    end)

    rewrite!(ctx, store,
      agent_kind: "codex",
      agent_model: "new-model",
      claude_providers: ["new-provider"]
    )

    snapshot = Orchestrator.snapshot(orchestrator, 15_000)

    assert snapshot.agent_kind == "codex"

    assert [%{issue_id: "issue-in-flight", agent_kind: "claude", provider: "old-provider", model: "old-model"}] =
             snapshot.running
  end

  defp start_project!(ctx, overrides) do
    write_workflow_file!(ctx.workflow_path, Keyword.merge([tracker_kind: "memory"], overrides))

    {:ok, _supervisor} =
      start_supervised({ProjectSupervisor, project_name: ctx.project_name, workflow_path: ctx.workflow_path})

    orchestrator = ProjectSupervisor.lookup(ctx.project_name, :orchestrator)
    store = ProjectSupervisor.lookup(ctx.project_name, :workflow_store)
    assert is_pid(orchestrator)
    assert is_pid(store)
    {orchestrator, store}
  end

  defp rewrite!(ctx, store, overrides) do
    write_workflow_file!(ctx.workflow_path, Keyword.merge([tracker_kind: "memory"], overrides))
    assert :ok = WorkflowStore.force_reload(store)
  end
end
