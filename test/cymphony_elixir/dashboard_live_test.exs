unless Code.ensure_loaded?(CymphonyElixir.HarnessStream) do
  defmodule CymphonyElixir.HarnessStream do
    @moduledoc false

    def snapshot(issue_id) when is_binary(issue_id) do
      %{issue_id: issue_id, last_seq: 0, lines: [], dropped: 0}
    end
  end
end

defmodule CymphonyElixir.DashboardLiveTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixir.WorkflowStore
  alias CymphonyElixirWeb.Presenter

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts) do
      if project_name = Keyword.get(opts, :project_name) do
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {project_name, :orchestrator}, nil)
      end

      {:ok, opts}
    end

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(call, _from, state) do
      case Keyword.get(state, :recipient) do
        pid when is_pid(pid) -> send(pid, {:orchestrator_call, call})
        _ -> :ok
      end

      {:reply, :ok, state}
    end
  end

  setup do
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "known_kinds options render in the project picker, restart form, metrics, and settings" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    for kind <- Agent.known_kinds() do
      assert html =~ ~s(data-kind="#{kind}")
      assert html =~ "/icons/"
      assert html =~ kind
    end

    assert html =~ ~s(class="metric-pill metric-pill--states section--states advanced-only")
    assert html =~ ~s(class="metric-pill metric-pill--kinds section--kinds advanced-only")
    assert html =~ "States"
    assert html =~ "Kinds"
    assert html =~ "In Progress 1"
    assert html =~ "unknown 1"
    assert html =~ ~s(data-pref-section="states")
    assert html =~ ~s(data-pref-section="kinds")
    assert html =~ ~s(data-pref-section="board")

    expanded =
      view
      |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

    assert expanded =~ ~s(name="agent_kind")
    assert expanded =~ ~s(data-value="")
    assert expanded =~ "keep"
    assert expanded =~ "Restart kills the session and redispatches with these overrides."
    assert expanded =~ ~s(id="harness-tail-MT-HTTP")
    assert expanded =~ ~s(phx-hook="HarnessTail")
    assert expanded =~ "Following"

    for kind <- Agent.known_kinds() do
      assert expanded =~ ~s(data-kind="#{kind}")
    end
  end

  test "set_issue_run_spec includes agent_kind when a known kind is selected" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    render_submit(view, "set_issue_run_spec", %{
      "issue" => "MT-HTTP",
      "agent_kind" => "antigravity",
      "provider" => "cv2",
      "model" => "opus",
      "effort" => ""
    })

    assert_receive {:orchestrator_call, {:set_issue_run_spec, "issue-http", overrides}}, 1_000
    assert overrides.agent_kind == "antigravity"
    assert overrides.provider == "cv2"
    assert overrides.model == "opus"
    refute Map.has_key?(overrides, :effort)
  end

  test "toggle_logs expand puts a harness_tails entry and collapse removes it" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    assert view_assigns(view).harness_tails == %{}

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    tails = view_assigns(view).harness_tails
    assert Map.has_key?(tails, "MT-HTTP")
    assert tails["MT-HTTP"].issue_id == "issue-http"
    assert tails["MT-HTTP"].follow == true
    assert is_list(tails["MT-HTTP"].lines)
    assert tails["MT-HTTP"].last_seq == 0 or is_integer(tails["MT-HTTP"].last_seq)

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert view_assigns(view).harness_tails == %{}
  end

  test "harness_stream handle_info appends by seq, caps, and does not touch payload" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    payload_before = view_payload(view)
    refresh_before = view_assigns(view).last_payload_refresh

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 2,
      lines: [
        %{seq: 1, at: DateTime.utc_now(), text: "first line"},
        %{seq: 2, at: DateTime.utc_now(), text: "second line"}
      ],
      dropped: 0
    })

    html = render(view)
    assert html =~ "first line"
    assert html =~ "second line"
    assert html =~ ~s(data-seq="1")
    assert html =~ ~s(data-seq="2")

    assigns = view_assigns(view)
    assert view_payload(view) == payload_before
    assert assigns.last_payload_refresh == refresh_before
    assert assigns.harness_tails["MT-HTTP"].last_seq == 2
    assert length(assigns.harness_tails["MT-HTTP"].lines) == 2

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 2,
      lines: [%{seq: 2, at: DateTime.utc_now(), text: "duplicate"}],
      dropped: 0
    })

    html = render(view)
    refute html =~ "duplicate"
    assert length(view_assigns(view).harness_tails["MT-HTTP"].lines) == 2

    send(view.pid, %{
      event: :harness_stream,
      issue_id: "issue-http",
      last_seq: 3,
      lines: [%{seq: 3, at: DateTime.utc_now(), text: "third line"}],
      dropped: 0
    })

    html = render(view)
    assert html =~ "third line"
    assert length(view_assigns(view).harness_tails["MT-HTTP"].lines) == 3

    send(view.pid, %{event: :harness_stream, issue_id: "missing-issue", last_seq: 1, lines: []})
    send(view.pid, %{event: :other_map, issue_id: "issue-http"})
    assert render(view) =~ "third line"
  end

  test "preview_project_agent accepts antigravity and ignores unknown kinds" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "antigravity"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)
    refute has_element?(view, "#effort-default")
    drafts = view_assigns(view).agent_setting_drafts
    assert drafts["default"].kind == "antigravity"

    project_name = hd(view_assigns(view).projects).name

    render_change(view, "preview_project_agent", %{
      "project" => project_name,
      "agent_kind" => "gemini"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)
    assert view_assigns(view).agent_setting_drafts["default"].kind == "antigravity"

    html = render_click(view, "toggle_harness_follow", %{"issue" => "MT-HTTP"})
    refute html =~ ~s(id="harness-tail-MT-HTTP")
  end

  test "session tokens show one-decimal t/s and harness follow can pause" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running

    # Tokens and the derived rate move together, as they do on a real load: a
    # rate that drifts on its own is ignored by the change-only section split.
    entry =
      entry
      |> Map.put(:tokens, %{entry.tokens | total_tokens: 37})
      |> Map.put(:tokens_per_second, 12.34)

    patched = %{
      payload
      | running: [entry | rest],
        projects: patch_running(payload.projects, entry)
    }

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, patched))

    html = render(view)
    assert html =~ "12.3 t/s"
    assert html =~ ~s(class="tps")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert render(view) =~ "Following"

    view
    |> element(~s|button[phx-click="toggle_harness_follow"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    html = render(view)
    assert html =~ "Paused"
    assert html =~ ~s(data-follow="false")
    refute view_assigns(view).harness_tails["MT-HTTP"].follow
  end

  test "settings drawer connects Linear and never echoes the API key" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Disconnected"
    assert html =~ "Connect Linear to add a project"
    refute has_element?(view, "#add-project-form")
    assert has_element?(view, "#linear-connect-form")
    assert has_element?(view, "#linear-api-key")

    view
    |> form("#linear-connect-form", %{api_key: ""})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "API key cannot be empty")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(fn _payload, _headers ->
      {:ok, %{status: 401, body: %{}}}
    end)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "Linear rejected that API key")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(fn _payload, _headers ->
      {:ok, %{status: 200, body: %{"data" => %{}}}}
    end)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    assert has_element?(view, "p.settings-error", "Linear rejected that API key")
    refute render(view) =~ "lin_api_fake"

    stub_linear_graphql(&linear_success_request/2)

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    html = render(view)
    assert html =~ "Connected"
    assert has_element?(view, "span.linear-key-mask", "••••fake")
    assert html =~ "Linear connected · ••••fake"
    refute html =~ "lin_api_fake"
    refute html =~ "••••••••"

    assert_eventually(fn ->
      render(view) =~ "ailogic-ced4159f70c4"
    end)

    assert has_element?(view, "#add-project-form")
    assert render(view) =~ ~s(value="ailogic-ced4159f70c4")
  end

  test "add_project duplicate error and success after a stubbed start" do
    start_dashboard()
    stub_linear_graphql(&linear_success_request/2)
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form("#linear-connect-form", %{api_key: "lin_api_fake"})
    |> render_submit()

    send(
      view.pid,
      {:linear_projects_loaded,
       [
         %{id: "proj-1", name: "Agent Farm", slug_id: "ailogic-ced4159f70c4"},
         %{id: "proj-2", name: "Other Farm", slug_id: "other-slug-aaaaaaaa"}
       ]}
    )

    render(view)

    {:ok, config} = CymphonyConfig.load()

    seeded =
      Map.put(config, "projects", [
        %{
          "name" => "Farm",
          "linear_project_slug" => "ailogic-ced4159f70c4",
          "linear_api_key" => "lin_api_fake"
        }
      ])

    assert :ok = CymphonyConfig.save(seeded)

    render_submit(view, "add_project", %{
      "name" => "Farm",
      "linear_project_slug" => "ailogic-ced4159f70c4"
    })

    assert has_element?(view, "p.settings-error", "A project with that name already exists")
    assert render(view) =~ "A project with that name already exists"

    render_submit(view, "add_project", %{
      "name" => "Different",
      "linear_project_slug" => "ailogic-ced4159f70c4"
    })

    assert render(view) =~ "A project with that Linear slug already exists"

    farm_orch = Module.concat(__MODULE__, :"Farm#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: {:added_farm_orch, farm_orch},
      start:
        {StaticOrchestrator, :start_link,
         [
           [
             name: farm_orch,
             project_name: "AddedFarm",
             snapshot:
               static_snapshot()
               |> Map.put(:project_name, "AddedFarm")
               |> Map.put(:running, [])
               |> Map.put(:retrying, [])
           ]
         ]}
    })

    test_pid = self()

    dummy_supervisor =
      spawn(fn ->
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {"AddedFarm", :supervisor}, nil)
        send(test_pid, :added_farm_supervisor_registered)
        Process.sleep(:infinity)
      end)

    assert_receive :added_farm_supervisor_registered, 1_000

    on_exit(fn ->
      if Process.alive?(dummy_supervisor), do: Process.exit(dummy_supervisor, :kill)
    end)

    render_submit(view, "add_project", %{
      "name" => "AddedFarm",
      "linear_project_slug" => "other-slug-aaaaaaaa"
    })

    html = render(view)
    assert html =~ "AddedFarm added and started"
    assert html =~ "AddedFarm"
    assert has_element?(view, ".project-section-name", "AddedFarm")
    refute html =~ "lin_api_fake"
  end

  test "project controls report applied but unpersisted changes without crashing" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")
    config_path = Path.join(CymphonyConfig.config_dir(), "config.json")
    File.rm!(config_path)

    html = render_submit(view, "set_concurrency", %{"value" => "4"})
    assert html =~ "Concurrency was applied, but could not be saved"
    refute html =~ "Concurrency set to 4; persisted"
    assert_receive {:orchestrator_call, {:set_concurrency, 4}}

    html = render_submit(view, "set_project_concurrency", %{"project" => "default", "value" => "3"})
    assert html =~ "Concurrency was applied, but could not be saved"
    assert_receive {:orchestrator_call, {:set_concurrency, 3}}

    html = render_submit(view, "set_project_providers", %{"project" => "default", "value" => "cv1,cz2"})
    assert html =~ "Providers were applied, but could not be saved"
    assert_receive {:orchestrator_call, {:set_providers, ["cv1", "cz2"]}}

    html = render_submit(view, "set_project_agent", %{"project" => "default", "agent_kind" => "codex"})
    assert html =~ "Agent settings were applied, but could not be fully saved"
    assert_receive {:orchestrator_call, {:set_agent_settings, %{"agent" => "codex"}}}
  end

  test "project providers reject unsafe aliases without dispatch" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")

    html = render_submit(view, "set_project_providers", %{"project" => "default", "value" => "cv1; echo bad"})
    assert html =~ "Providers must be valid shell aliases"
    refute_receive {:orchestrator_call, {:set_providers, _}}, 50
  end

  test "Linear connect reports a saved key with a failed workflow rewrite without leaking it" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")
    tmp = CymphonyConfig.config_dir()
    project = %{"name" => "default", "linear_project_slug" => "default-slug", "linear_api_key" => "lin_test"}
    assert :ok = CymphonyConfig.save(%{"projects" => [project]})
    workflow_dir = Path.join(tmp, "workflow")
    File.mkdir_p!(workflow_dir)
    workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
    File.write!(workflow_path, WorkflowGenerator.generate(project))

    store_opts = [name: ProjectSupervisor.via_tuple("default", :workflow_store), workflow_path: workflow_path]

    start_supervised!(%{
      id: {:dashboard_failed_rewrite_store, "default"},
      start: {WorkflowStore, :start_link, [store_opts]}
    })

    owner = self()

    orch =
      spawn(fn ->
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {"default", :orchestrator}, nil)
        send(owner, :orch_registered)
        Process.sleep(:infinity)
      end)

    assert_receive :orch_registered
    on_exit(fn -> Process.exit(orch, :kill) end)
    File.rm_rf!(workflow_dir)
    stub_linear_graphql(&linear_success_request/2)

    html = render_submit(view, "connect_linear", %{"api_key" => "lin_api_topsecret"})
    assert html =~ "Linear key was saved, but a project workflow could not be updated"
    assert view_assigns(view).linear_status.connected
    refute html =~ "lin_api_topsecret"
  end

  test "add project reports generated workflow failure instead of crashing" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")
    {:ok, config} = CymphonyConfig.load()
    assert :ok = CymphonyConfig.save(Map.put(config, "linear_api_key", "lin_test"))
    Application.put_env(:cymphony_elixir, :workflow_temp_dir, Path.join(CymphonyConfig.config_dir(), "missing"))
    on_exit(fn -> Application.delete_env(:cymphony_elixir, :workflow_temp_dir) end)

    html = render_submit(view, "add_project", %{"name" => "Farm", "linear_project_slug" => "farm-slug"})
    assert html =~ "Project was saved but its workflow could not be generated"
    refute html =~ "Farm added and started"
  end

  test "header agent select id is stable and survives stale payload refresh" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="agent-default")
    assert html =~ ~s(id="effort-default")
    refute html =~ ~s(id="agent-default-claude")
    refute html =~ ~s(id="effort-default-claude")
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "codex"
    })

    assert has_element?(view, ~s|#agent-default|)
    refute has_element?(view, ~s|#agent-default-codex|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    assert render(view) =~ ~s(id="agent-default")
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)

    preview_assigns = view_assigns(view)
    preview_payload = view_payload(view)
    [preview_project | preview_rest] = preview_payload.projects
    assert preview_project.agent_kind == "claude"

    send(
      view.pid,
      test_payload_loaded(view, preview_assigns.payload_seq, %{preview_payload | projects: [Map.put(preview_project, :agent_kind, "claude") | preview_rest]})
    )

    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)
    assert view_assigns(view).agent_setting_drafts[preview_project.name].kind == "codex"

    seq_before = view_assigns(view).payload_seq

    render_submit(view, "set_project_agent", %{
      "project" => preview_project.name,
      "agent_kind" => "codex",
      "model" => "gpt-5.2-codex",
      "effort" => "high"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    seq_after = view_assigns(view).payload_seq
    assert seq_after > seq_before

    payload = view_payload(view)
    [project | rest] = payload.projects
    assert project.agent_kind == "claude"

    send(view.pid, test_payload_loaded(view, seq_after, payload))
    render(view)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    stale_project =
      project
      |> Map.put(:agent_kind, nil)
      |> Map.put(:agent_model, nil)
      |> Map.put(:agent_effort, nil)

    send(view.pid, test_payload_loaded(view, seq_before, %{payload | projects: [stale_project | rest]}))
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    assert has_element?(view, ~s|#agent-default|)

    matching_project =
      project
      |> Map.put(:agent_kind, "codex")
      |> Map.put(:agent_model, "gpt-5.2-codex")
      |> Map.put(:agent_effort, "high")

    send(view.pid, test_payload_loaded(view, seq_after, %{payload | projects: [matching_project | rest]}))
    render(view)

    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)
    refute Map.has_key?(view_assigns(view).agent_setting_drafts, project.name)
  end

  test "header model lives under spec-switcher without datalist" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, ~s|form.project-agent-form.advanced-only[phx-change="preview_project_agent"][phx-submit="set_project_agent"]|)
    assert has_element?(view, "#spec-switcher-agent-default")
    assert has_element?(view, ~s|#model-default[name="model"]|)
    assert has_element?(view, "#agent-default-trigger")
    assert has_element?(view, "#model-default-input")
    assert has_element?(view, ~s|#model-suggestions-default[role="listbox"]|)
    assert has_element?(view, "#spec-switcher-agent-default .spec-switcher-panel")
    assert has_element?(view, "#spec-switcher-agent-default .spec-switcher-search")
    assert has_element?(view, ~s|#spec-switcher-agent-default li[role="option"][data-value="sonnet"]|)
    assert has_element?(view, ~s|#spec-switcher-agent-default .spec-switcher-agent[data-kind="claude"]|)
    assert has_element?(view, "#agent-default")
    assert has_element?(view, "#effort-default")
    refute html =~ "<datalist"
    refute html =~ ~s(list="model-suggestions)
    refute html =~ ~s(id="agent-default-claude")
    refute html =~ "Reset to default"
  end

  test "preview_project_agent hides providers for non-claude kinds and restores them for claude" do
    start_dashboard(recipient: self())
    {:ok, view, _html} = live(build_conn(), "/")

    {:ok, config} = CymphonyConfig.load()
    projects = Enum.map(config["projects"], &Map.put(&1, "provider", "cv1"))
    assert :ok = CymphonyConfig.save(Map.put(config, "projects", projects))

    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "codex"
    })

    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "antigravity"
    })

    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="antigravity"]|)

    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "claude"
    })

    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)
    assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="claude"]|)

    refute_received {:orchestrator_call, {:set_providers, _}}
    {:ok, persisted} = CymphonyConfig.load()
    assert Enum.any?(persisted["projects"], &(&1["provider"] == "cv1"))
  end

  test "header providers stay hidden for empty and unknown agent kinds" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [project | rest] = payload.projects

    send(
      view.pid,
      test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | projects: [Map.put(project, :agent_kind, nil) | rest]})
    )

    render(view)
    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)

    send(
      view.pid,
      test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | projects: [Map.put(project, :agent_kind, "gemini") | rest]})
    )

    render(view)
    refute has_element?(view, "#providers-default")
    refute has_element?(view, ~s|form[phx-submit="set_project_providers"]|)
  end

  test "restart form shows provider only for claude and hides it for codex" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    assert has_element?(view, ~s|form.restart-form[phx-change="preview_issue_run_spec"][phx-submit="set_issue_run_spec"]|)
    assert has_element?(view, "#spec-switcher-restart-agent-MT-HTTP")
    assert has_element?(view, "#restart-agent-MT-HTTP")
    assert has_element?(view, "#restart-agent-MT-HTTP-trigger")
    assert has_element?(view, ~s|#restart-model-MT-HTTP[name="model"]|)
    assert has_element?(view, "#restart-model-MT-HTTP-input")
    assert has_element?(view, "#model-suggestions-session-MT-HTTP")
    assert has_element?(view, "#restart-effort-MT-HTTP")
    assert has_element?(view, ~s|#harness-tail-MT-HTTP[phx-hook="HarnessTail"]|)
    refute render(view) =~ ">Provider<"

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "claude"})

    assert has_element?(view, ~s|#restart-provider-MT-HTTP[name="provider"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "codex"})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    refute has_element?(view, ~s|form.restart-form input[name="provider"]|)
    assert has_element?(view, ~s|form[phx-submit="set_issue_run_spec"] input[name="agent_kind"][value="codex"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "antigravity"})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    refute has_element?(view, ~s|form.restart-form input[name="provider"]|)
    assert has_element?(view, "#restart-agent-MT-HTTP")
    assert has_element?(view, ~s|form[phx-submit="set_issue_run_spec"] input[name="agent_kind"][value="antigravity"]|)

    render_change(view, "preview_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => ""})

    refute has_element?(view, "#restart-provider-MT-HTTP")
    refute render(view) =~ ">Provider<"
  end

  test "session provider chip and Provider stat stay hidden" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    entry = entry |> Map.put(:provider, "cz2") |> Map.put(:agent_kind, "codex")

    patched = %{
      payload
      | running: [entry | rest],
        projects: patch_running(payload.projects, entry)
    }

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, patched))

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    html = render(view)
    refute html =~ ~s(class="chip chip--accent advanced-only")
    refute html =~ ">Provider<"
    refute html =~ ~s(<span class="session-stat-value">cz2</span>)
    assert html =~ ~s(class="chip chip--agent chip--icon advanced-only")
    assert html =~ "codex"
    assert has_element?(view, ~s|form[phx-submit="set_project_providers"] #providers-default|)
  end

  test "preview_add_project shows provider only for claude" do
    start_dashboard()
    {:ok, config} = CymphonyConfig.load()
    assert :ok = CymphonyConfig.save(Map.put(config, "linear_api_key", "lin_api_fake"))

    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, "#add-project-form")
    assert has_element?(view, "#add-project-slug")
    assert has_element?(view, "#add-project-slug-input")
    assert has_element?(view, "#linear-project-slugs")
    assert has_element?(view, "#add-project-model")
    assert has_element?(view, "#add-project-model-input")
    assert has_element?(view, "#spec-switcher-add-project-agent #add-project-model")
    assert has_element?(view, ~s|#add-project-effort[name="effort"]|)
    refute has_element?(view, ~s|#add-project-effort[type="text"]|)
    refute has_element?(view, "#add-project-provider")
    assert view_assigns(view).add_project_kind == ""

    render_change(view, "preview_add_project", %{"agent" => "claude"})

    assert view_assigns(view).add_project_kind == "claude"
    assert has_element?(view, "#add-project-provider")

    render_change(view, "preview_add_project", %{"agent" => "codex"})

    assert view_assigns(view).add_project_kind == "codex"
    refute has_element?(view, "#add-project-provider")

    render_change(view, "preview_add_project", %{"agent" => "antigravity"})

    assert view_assigns(view).add_project_kind == "antigravity"
    refute has_element?(view, "#add-project-provider")
    refute has_element?(view, "#add-project-effort")

    render_change(view, "preview_add_project", %{"agent" => ""})

    assert view_assigns(view).add_project_kind == ""
    refute has_element?(view, "#add-project-provider")
  end

  test "refresh interval defaults to 3 and set_refresh_interval updates assign and config.json" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(id="drawer-refresh-interval")
    assert has_element?(view, ~s|#drawer-refresh-interval[type="number"][min="1"][name="value"]|)
    assert has_element?(view, ~s|#drawer-refresh-interval.settings-field|)
    assert has_element?(view, ~s|#linear-api-key.settings-field|)
    assert has_element?(view, ~s|#drawer-global-concurrency.settings-field|)
    assert has_element?(view, ~s|form.settings-form[phx-submit="set_refresh_interval"]|)
    assert has_element?(view, ~s|form.settings-form[phx-submit="set_concurrency"]|)
    assert view_assigns(view).payload_refresh_seconds == 3
    assert view_assigns(view).payload_refresh_ms == 3_000
    assert has_element?(view, ~s|#drawer-refresh-interval[value="3"]|)

    {:ok, initial_config} = CymphonyConfig.load()
    refute Map.get(initial_config, "dashboard_refresh_seconds")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "7"})
    |> render_submit()

    assert view_assigns(view).payload_refresh_seconds == 7
    assert view_assigns(view).payload_refresh_ms == 7_000
    assert render(view) =~ "Dashboard refresh set to 7s"

    {:ok, updated} = CymphonyConfig.load()
    assert updated["dashboard_refresh_seconds"] == 7
    assert is_list(updated["projects"])

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "0"})
    |> render_submit()

    assert view_assigns(view).payload_refresh_seconds == 7
    assert render(view) =~ "Refresh interval must be a positive integer"
  end

  test "the global concurrency field prefills the fleet value and never renders blank" do
    snapshot = put_in(static_snapshot(), [:polling, :max_concurrent_agents], 4)
    start_dashboard(snapshot: snapshot)

    {:ok, view, _html} = live(build_conn(), "/")

    # Every project agrees: show the number, like the refresh field does.
    assert has_element?(view, ~s|#drawer-global-concurrency[value="4"][placeholder="4"]|)

    payload = view_payload(view)
    [project | _rest] = payload.projects
    other = %{project | name: "Other", max_concurrent_agents: 9}

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | projects: [project, other]}))
    render(view)

    # Projects disagree: prefilling either number would flatten the other on Set.
    assert has_element?(view, ~s|#drawer-global-concurrency[value=""][placeholder="mixed"]|)
  end

  test "the global concurrency field falls back to the documented default when no project reports one" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # An empty box beside Set looked unfinished; name the schema default instead.
    assert has_element?(view, ~s|#drawer-global-concurrency[value=""][placeholder="10"]|)
  end

  test "the shell renders a nav rail, a main column, project anchors, and the session grid head" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, ~s|#dashboard-root.dashboard-shell[phx-hook="OverlayDismiss"]|)
    assert has_element?(view, ~s|nav.side-rail a.side-rail-brand[href="#dashboard-top"]|)
    assert has_element?(view, "#dashboard-top.main-col")
    assert has_element?(view, "#project-default.project-section")

    # The band moved out of <header> and keeps the class tokens the
    # section-visibility prefs key off.
    assert html =~ ~s(class="instrument-band command-bar-row--metrics section--metrics")

    # Head cells reuse the body column classes, so `data-hidden-cols` hides the
    # header and its column together with no extra CSS.
    assert has_element?(view, ".session-row-list .session-grid-head.advanced-only .sg-id", "Issue")
    assert has_element?(view, ".session-grid-head .session-row-title", "Title")
    assert has_element?(view, ".session-grid-head .session-row-runtime", "Time")
    assert has_element?(view, ".session-grid-head .session-row-tokens", "Tokens")

    # The disclosure chevron is CSS geometry now; the server renders no glyph.
    disclosure = view |> element(~s|button.session-row-disclosure[phx-value-issue="MT-HTTP"]|) |> render()
    refute disclosure =~ "▸"
    refute disclosure =~ "▾"

    # Always in the DOM; only painted while the socket is in `phx-error`.
    assert has_element?(view, ~s|div.reconnect-note[role="status"]|)
  end

  test "flashes render in the fixed toast stack instead of shifting the board" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, ~s|div.toast-stack[aria-live="polite"]|)
    refute html =~ "alert-banner alert-info"

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "7"})
    |> render_submit()

    assert has_element?(view, ".toast-stack .alert-banner.alert-info", "Dashboard refresh set to 7s")
  end

  test "the rail renders vitals, fleet links with state LEDs, and the foot controls" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    # Vitals read the same section assigns the band does — never a clock.
    assert has_element?(view, ".side-rail .rail-vitals .rail-vitals-num", "1")
    assert has_element?(view, ".side-rail .rail-vitals-copy", "Automatic work is on.")

    # Fleet nav: an Overview anchor plus one anchor per project, pointing at the
    # section ids Part A added.
    assert has_element?(view, ~s|#rail-nav[phx-hook="RailNav"]|)
    assert has_element?(view, ~s|.rail-group .rail-link[href="#dashboard-top"] .rail-link-name|, "Overview")
    assert has_element?(view, ~s|.rail-link[href="#project-default"][title="default"] .rail-link-name|, "default")

    # The fixture has one running and one retrying issue: retrying outranks
    # running so the rail says "this project is not simply working".
    assert has_element?(view, ~s|.rail-link[href="#project-default"] .rail-led.rail-led--retry|)

    # Completions are empty in the fixture, so that anchor is absent.
    refute has_element?(view, ~s|.rail-link[href="#completions-section"]|)

    # Foot: mode + theme moved here; console and refresh sit beside them.
    assert has_element?(view, ~s|.rail-foot #mode-switch-rail[phx-update="ignore"]|)
    assert has_element?(view, ~s|.rail-foot .theme-toggle [data-theme-set="system"]|)
    assert has_element?(view, ~s|.rail-foot button.rail-action[data-drawer-toggle][aria-label="Settings"]|)
    assert has_element?(view, ~s|.rail-foot button.rail-action--refresh[phx-click="refresh_now"]|)
  end

  test "a paused project shows the amber rail LED" do
    snapshot = static_snapshot()
    paused = %{snapshot | running: [], retrying: [], polling: %{snapshot.polling | paused: true}}
    start_dashboard(snapshot: paused)
    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, ~s|.rail-link[href="#project-default"] .rail-led.rail-led--paused|)
    assert has_element?(view, ".rail-vitals-copy", "Automatic work is paused.")
  end

  test "an idle project shows the neutral rail LED" do
    start_dashboard(snapshot: %{static_snapshot() | running: [], retrying: []})
    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, ~s|.rail-link[href="#project-default"] .rail-led.rail-led--idle|)
  end

  test "the narrow top strip keeps duplicate mode/theme controls and a jump menu" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, ".command-bar #mode-switch-top.mode-switch.topbar-only-narrow")
    assert has_element?(view, ".command-bar .theme-toggle.topbar-only-narrow")
    assert has_element?(view, ~s|.command-bar details.jump-menu.topbar-only-narrow .jump-menu-summary|, "Jump to")
    assert has_element?(view, ~s|.jump-menu-panel .jump-menu-link[href="#project-default"]|, "default")

    # `open` is browser-owned and never server-rendered, so morphdom strips it on
    # every patch. Below 900px this is the only section-jump control, so it needs
    # a hook to carry the flag across the morph — the rail's anchors are gone.
    assert has_element?(view, ~s|details#jump-menu.jump-menu[phx-hook="JumpMenu"]|)
  end

  test "fleet-empty replaces the board only once a connected payload has no projects" do
    start_dashboard()

    # The dead render also has `projects: []`; it has not earned the claim.
    dead = html_response(get(build_conn(), "/"), 200)
    refute dead =~ "fleet-empty"

    {:ok, view, html} = live(build_conn(), "/")
    refute html =~ "fleet-empty"

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{projects: []}))

    assert has_element?(view, "section.section-card.fleet-empty .fleet-empty-label", "No projects")
    assert has_element?(view, ".fleet-empty-copy", "Connect Linear and add your first project.")
    assert has_element?(view, ".fleet-empty-action[data-drawer-toggle]", "Open settings")
  end

  test "the settings console explains refresh interval against Linear polling" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    # Operator complaint: "refresh" was read as the Linear poll cadence.
    assert has_element?(
             view,
             ".settings-drawer .settings-control-row .settings-help",
             "Refresh (s): how often this dashboard re-reads orchestrator state — not Linear polling."
           )

    assert has_element?(view, ".settings-drawer .settings-control-row form[phx-submit=\"set_refresh_interval\"]")
    assert has_element?(view, ".settings-drawer .settings-help", "How many agent sessions may run at once, across every project.")
    assert has_element?(view, ".settings-drawer .settings-help", "Running sessions finish.")

    # Primary actions carry the accent; the destructive/quiet ones do not.
    assert has_element?(view, ~s|#linear-connect-form button.subtle-button--accent|, "Connect")
    assert has_element?(view, ~s|.settings-drawer button.settings-submit[phx-click="pause_dispatch"]|, "Pause all")
    refute has_element?(view, ~s|.settings-drawer button.subtle-button--accent[phx-click="pause_dispatch"]|)
  end

  test "queue board is hidden when waiting is empty" do
    start_dashboard()
    {:ok, view, html} = live(build_conn(), "/")

    assert view_assigns(view).queue_edit_ids == MapSet.new()
    assert view_assigns(view).queue_run_spec_drafts == %{}
    refute has_element?(view, "section.queue-board")
    refute has_element?(view, ".queue-board-list")
    refute html =~ ~s(id="queue-board-default")
    assert has_element?(view, ~s|[data-pref-section="board"]|)
    assert html =~ ~s(class="metric-pill metric-pill--queue section--queue advanced-only")
  end

  test "queue board shows title, identifier, and Edit when waiting is present" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "Pin the queue"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Later card", priority: 4})
        ])
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, "section.queue-board.section--board")
    assert has_element?(view, "#queue-board-default.queue-board-list")
    assert has_element?(view, ~s|#queue-card-default-LLM-51[data-issue="LLM-51"][data-rank="0"]|)
    # `data-rank` stays 0-based (the drag hook owns it); the printed rank is a
    # separate 1-based label the CSS renders as a decorative numeral.
    assert has_element?(view, ~s|#queue-card-default-LLM-51[data-rank-label="01"]|)
    assert has_element?(view, ~s|#queue-card-default-LLM-12[data-rank-label="02"]|)
    assert has_element?(view, ~s|#queue-card-default-LLM-51.queue-card--next|)
    assert has_element?(view, "#queue-card-default-LLM-51 .queue-next-badge", "Next")
    refute has_element?(view, ~s|#queue-card-default-LLM-12.queue-card--next|)
    assert has_element?(view, ~s|a.session-row-link.queue-card-link|, "LLM-51")
    assert html =~ "Pin the queue"
    assert has_element?(view, "button.queue-card-edit-toggle", "Edit")
    assert html =~ "queued"
    assert html =~ "Leftmost starts next"

    card = view |> element("#queue-card-default-LLM-51") |> render()
    refute card =~ "chip"
    refute card =~ "Urgent"
    refute card =~ "High"
    refute card =~ "Todo"
    refute card =~ "In Progress"
  end

  test "only one queue edit sheet is open and dismiss_overlays closes it" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "First"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Second"})
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, "#queue-edit-default-LLM-51")
    refute has_element?(view, "#queue-edit-default-LLM-12")

    # The sheet is a viewport-positioned popover: `QueueEditPanel` places it off
    # the card's rect, and `phx-click-away` is the no-JS half of the same
    # dismiss. Both must stay on the element — the hook has nothing to anchor to
    # without the id, and the id alone does not open a popover.
    assert has_element?(
             view,
             ~s|div.queue-card-edit#queue-edit-default-LLM-51[phx-hook="QueueEditPanel"][phx-click-away="dismiss_overlays"]|
           )

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-12"]|)
    |> render_click()

    refute has_element?(view, "#queue-edit-default-LLM-51")
    assert has_element?(view, "#queue-edit-default-LLM-12")

    render_click(view, "dismiss_overlays", %{})
    refute has_element?(view, "#queue-edit-default-LLM-12")
    assert view_assigns(view).queue_edit_ids == MapSet.new()
  end

  test "empty-state is absent when waiting is nonempty" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:running, [])
        |> Map.put(:retrying, [])
        |> Map.put(:waiting, [waiting_snapshot_entry(%{identifier: "LLM-51", title: "Ready next"})])
    )

    {:ok, view, html} = live(build_conn(), "/")

    assert has_element?(view, "section.queue-board.section--board")
    assert html =~ "Ready next"
    refute html =~ "No active sessions."
    refute html =~ "Nothing is running right now."
    refute has_element?(view, "p.empty-state")
  end

  test "queue edit preselects project header spec when the card has no pin" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:agent_kind, "antigravity")
        |> Map.put(:agent_model, "gpt-5.6-luna")
        |> Map.put(:agent_effort, "max")
        |> Map.put(:waiting, [waiting_snapshot_entry(%{identifier: "LLM-51", title: "Ready next"})])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="antigravity"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="model"][value="gpt-5.6-luna"]|)
    refute has_element?(view, ~s|form.queue-edit-form input[name="effort"]|)

    form = view |> element("form.queue-edit-form") |> render()
    refute form =~ ~s(data-value="")
    refute form =~ ">keep<"
  end

  test "queue edit preselects a card pin over the project header" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:agent_kind, "antigravity")
        |> Map.put(:agent_model, "gpt-5.6-luna")
        |> Map.put(:agent_effort, "max")
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{
            identifier: "LLM-51",
            title: "Pinned card",
            agent_kind: "codex",
            model: "gpt-5.2-codex",
            effort: "high"
          })
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    assert has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="codex"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="model"][value="gpt-5.2-codex"]|)
    assert has_element?(view, ~s|form.queue-edit-form input[name="effort"][value="high"]|)
    refute has_element?(view, ~s|form.queue-edit-form input[name="agent_kind"][value="antigravity"]|)
  end

  test "preview_queue_run_spec drafts kind and clears model and effort when kind changes" do
    start_dashboard(
      snapshot:
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{
            identifier: "LLM-51",
            title: "Ready next",
            agent_kind: "claude",
            model: "sonnet",
            effort: "high"
          })
        ])
    )

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
    |> render_click()

    render_change(view, "preview_queue_run_spec", %{
      "project" => "default",
      "issue" => "LLM-51",
      "agent_kind" => "codex",
      "model" => "sonnet",
      "effort" => "high"
    })

    draft = view_assigns(view).queue_run_spec_drafts[{"default", "LLM-51"}]
    assert draft.kind == "codex"
    assert draft.model == ""
    assert draft.effort == ""
    refute has_element?(view, ~s|form.queue-edit-form input[name="provider"]|)
  end

  test "empty-state is shown when running, retrying, and waiting are empty" do
    start_dashboard(snapshot: static_snapshot() |> Map.put(:running, []) |> Map.put(:retrying, []) |> Map.put(:waiting, []))

    {:ok, view, html} = live(build_conn(), "/")

    refute has_element?(view, "section.queue-board")
    assert html =~ "No active sessions."
    assert has_element?(view, "p.empty-state")
  end

  test "idle States/Kinds cells show a muted placeholder instead of a blank value" do
    start_dashboard(snapshot: static_snapshot() |> Map.put(:running, []) |> Map.put(:retrying, []) |> Map.put(:waiting, []))

    {:ok, view, _html} = live(build_conn(), "/")

    # Label-only compartments read as broken chrome on a first-run board.
    assert has_element?(view, ".metric-pill--states .metric-pill-value.metric-pill-placeholder", "—")
    assert has_element?(view, ".metric-pill--kinds .metric-pill-value.metric-pill-placeholder", "—")
  end

  test "a fresh board's Tput cell shows a flat baseline instead of an empty sparkline" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # Under two token samples there is no rate to draw, and an empty string left
    # the cell reading as a bare "0" — the same broken-chrome impression the
    # States/Kinds em dash exists to avoid.
    assert has_element?(
             view,
             ".metric-pill--throughput .metric-pill-spark.metric-pill-placeholder",
             "▁▁▁▁▁▁▁▁▁▁▁▁"
           )
  end

  test "the simple band names the running count once and calls retries retries" do
    start_dashboard()

    {:ok, _view, html} = live(build_conn(), "/")

    # The rail already counts `running · queued`. A band that said "Working" put
    # two words on one count, and its "Waiting" meant *retrying* while the rail's
    # meant *queued*. Counts are unchanged; only the words are.
    assert html =~ ~s(<span class="metric-pill-label simple-only">Running</span>)
    assert html =~ ~s(<span class="metric-pill-label simple-only">To retry</span>)
    refute html =~ ~s(<span class="metric-pill-label simple-only">Working</span>)
    refute html =~ ~s(<span class="metric-pill-label simple-only">Waiting</span>)
  end

  test "populated States/Kinds cells keep the breakdown text and no placeholder class" do
    start_dashboard()

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "In Progress 1"
    refute has_element?(view, ".metric-pill--states .metric-pill-placeholder")
    refute has_element?(view, ".metric-pill--kinds .metric-pill-placeholder")
  end

  test "a held retry gets a tag, not a bare muted sentence, and mutes the row's retry edge" do
    snapshot = static_snapshot()
    retrying = Enum.map(snapshot.retrying, &Map.put(&1, :held, true))

    start_dashboard(snapshot: %{snapshot | retrying: retrying})

    {:ok, view, _html} = live(build_conn(), "/")

    # Held is a state, and every other state on this board is a tag. Its
    # neighbour is `.chip.chip--warn` "Attempt N"; held is suppression rather
    # than failure, so `.chip--held` is neutral and `.retry-row--held` drops the
    # row's amber inset edge — a fully paused board is parked, not alarming.
    assert has_element?(view, "article.retry-row.retry-row--held span.chip.chip--held", "Held")
    refute render(view) =~ "held while paused"

    # No due countdown while held: the presenter withholds `due_at` entirely.
    refute has_element?(view, ~s|.retry-row--held span[data-clock="due"]|)
  end

  test "retrying rows carry project_name so Retry now can find the orchestrator" do
    start_dashboard()
    {:ok, view, _html} = live(build_conn(), "/")

    [retry | _] = view_assigns(view).retrying
    assert retry.project_name == "default"
    assert retry.issue_id == "issue-retry"
    assert retry.issue_identifier == "MT-RETRY"
  end

  test "an armed retry row carries neither the held tag nor the held modifier" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, "article.retry-row")
    refute has_element?(view, "article.retry-row.retry-row--held")
    refute has_element?(view, "span.chip--held")
  end

  test "time-derived values carry LiveClock anchors instead of absolute wall times" do
    start_dashboard()

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ ~s(<div id="live-clock" phx-hook="LiveClock">)

    # Poll countdown anchors on remaining milliseconds and matches the server text.
    assert html =~ ~s(<span data-clock="countdown" data-remaining-ms="5000">5s</span>)

    # Global runtime, per-session runtime and retry due-in all anchor on amounts.
    assert has_element?(view, ~s|span.metric-pill-value[data-clock="elapsed"][data-base-seconds][data-rate="1"]|)
    assert has_element?(view, ~s|.session-row-runtime span[data-clock="elapsed"][data-base-seconds]|)
    assert has_element?(view, ~s|span[data-clock="due"][data-remaining-ms]|)
  end

  test "the stalled banner anchors on elapsed seconds" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    stalled_at = DateTime.add(DateTime.utc_now(), -125, :second)

    stalled =
      entry
      |> Map.put(:stalled, true)
      |> Map.put(:last_event_at, DateTime.to_iso8601(stalled_at))

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | running: [stalled | rest]}))

    html = render(view)

    # The anchor is the elapsed amount as of the render, and the visible text is
    # that same amount formatted the way the LiveClock hook formats it.
    seconds = DateTime.diff(view_assigns(view).now, stalled_at, :second)
    assert seconds >= 125

    assert html =~
             ~s(<span data-clock="elapsed" data-base-seconds="#{seconds}">#{div(seconds, 60)}m #{rem(seconds, 60)}s</span>)
  end

  test "clock spans drop their anchor when the amount is unknown, keeping the server text" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [entry | rest] = payload.running
    stalled = entry |> Map.put(:stalled, true) |> Map.put(:last_event_at, "not-a-timestamp")

    # `due_at` alone is a volatile key the change comparison ignores, so bump
    # `attempt` too: a real reschedule always moves a non-volatile field with it,
    # and without one the section legitimately keeps its previous value.
    projects =
      Enum.map(payload.projects, fn project ->
        retrying =
          Enum.map(project.retrying, fn retry ->
            retry |> Map.put(:due_at, "not-a-timestamp") |> Map.put(:attempt, retry.attempt + 1)
          end)

        %{project | retrying: retrying}
      end)

    unclocked = %{
      payload
      | running: [stalled | rest],
        projects: projects,
        polling: %{payload.polling | next_poll_in_ms: nil}
    }

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, unclocked))

    html = render(view)

    # No anchor attribute at all, so the hook skips the span and the
    # server-rendered text is what a JS-off (or bad-data) browser keeps showing.
    assert html =~ ~s(<span data-clock="elapsed">unknown</span>)
    assert html =~ ~s(<span data-clock="due">n/a</span>)
    assert html =~ ~s(<span data-clock="countdown">n/a</span>)
  end

  test "the runtime tile anchors on completed seconds and advances once per running session" do
    start_dashboard(snapshot: Map.put(static_snapshot(), :running, []))

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ ~s(data-base-seconds="42.5")
    assert html =~ ~s(data-rate="0")
  end

  # A minutes-only counter ("260m 44s") is a raw-counter tell in the band's
  # largest numeral. The LiveClock `formatElapsed` in layouts.ex mirrors this
  # exact string (pinned in extensions_test.exs).
  test "elapsed times roll into hours past 60 minutes" do
    started_at = DateTime.add(DateTime.utc_now(), -15_644, :second)

    snapshot =
      Map.update!(static_snapshot(), :running, fn [entry | rest] ->
        [%{entry | started_at: started_at} | rest]
      end)

    start_dashboard(snapshot: snapshot)

    {:ok, view, _html} = live(build_conn(), "/")

    seconds = DateTime.diff(view_assigns(view).now, started_at, :second)
    hours = div(seconds, 3_600)
    minutes = div(rem(seconds, 3_600), 60)

    assert hours == 4

    assert has_element?(
             view,
             ~s|.session-row-runtime span[data-clock="elapsed"]|,
             "#{hours}h #{minutes}m #{rem(seconds, 60)}s"
           )

    # Under the hour the format is unchanged (the stalled-banner test pins the
    # `Mm Ss` shape directly).
    refute render(view) =~ "0h "
  end

  test "runtime_tick no longer re-renders time strings" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    html_before = render(view)
    assigns_before = view_assigns(view)
    payload_before = view_payload(view)

    send(view.pid, :runtime_tick)

    assert render(view) == html_before

    assigns_after = view_assigns(view)
    assert assigns_after.now == assigns_before.now
    assert view_payload(view) == payload_before
    assert assigns_after.last_payload_refresh == assigns_before.last_payload_refresh

    # Identical HTML alone is weak: the second-resolution strings only move once
    # a second. The real acceptance is that *no* assign moved, because LiveView
    # only ships a diff for assigns it marked as changed — so the tick costs zero
    # websocket traffic, not merely zero visible change.
    assert changed_assign_keys(assigns_before, assigns_after) == []
  end

  test "runtime_tick still drives the periodic payload refresh once the payload is dirty" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "1"})
    |> render_submit()

    assigns_before = view_assigns(view)

    # The tick is the only thing that loads a payload on a cadence, but it now
    # waits for a dirty flag: an orchestrator broadcast marks the payload dirty
    # and the next due tick coalesces it into exactly one load.
    send(view.pid, :observability_updated)

    assert wait_until(fn ->
             assigns = view_assigns(view)

             assigns.last_payload_refresh > assigns_before.last_payload_refresh and
               assigns.payload_seq > assigns_before.payload_seq
           end)

    assert view_assigns(view).payload_dirty == false
  end

  test "an orchestrator pubsub update marks the payload dirty and does not reload" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    assigns_before = view_assigns(view)

    send(view.pid, :observability_updated)
    render(view)

    assigns = view_assigns(view)

    # The orchestrator broadcasts twice per Linear poll (default 5s) plus once
    # per agent event. Reloading here — and re-stamping `:last_payload_refresh`
    # while doing it — made the poll interval the refresh interval and disabled
    # the configured gate outright.
    assert assigns.payload_dirty == true
    assert assigns.payload_seq == assigns_before.payload_seq
    assert assigns.last_payload_refresh == assigns_before.last_payload_refresh
    assert changed_assign_keys(assigns_before, assigns) == [:payload_dirty]
  end

  test "a burst of pubsub updates costs one payload load per configured interval" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "1"})
    |> render_submit()

    # Put the window already past due so the very first tick is eligible.
    backdate_payload_refresh(view, 5_000)
    seq_before = view_assigns(view).payload_seq

    for _ <- 1..20 do
      send(view.pid, :observability_updated)
      send(view.pid, :runtime_tick)
    end

    render(view)

    # 20 broadcasts inside one window, exactly one load. Before the coalescing
    # each broadcast spawned its own `Orchestrator.snapshot/2` task per open tab,
    # into the hottest GenServer in the system.
    assert view_assigns(view).payload_seq - seq_before == 1
  end

  test "a pubsub update never shortens the configured interval" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "30"})
    |> render_submit()

    seq_before = view_assigns(view).payload_seq

    send(view.pid, :observability_updated)

    for _ <- 1..5 do
      send(view.pid, :runtime_tick)
    end

    render(view)

    # "I set refresh to 20s and it still refreshes every 5s": the poll broadcast
    # must not pull the reload forward.
    assert view_assigns(view).payload_seq == seq_before
    assert view_assigns(view).payload_dirty == true
  end

  test "an idle board still resyncs when nothing broadcasts" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # The dirty gate cannot be the only trigger: a dropped broadcast, or a field
    # nothing broadcasts about (`last_agent_timestamp`, the poll countdown),
    # would otherwise freeze the board forever. Backdate the window past the
    # 30s idle-resync safety net.
    seq_before = view_assigns(view).payload_seq
    backdate_payload_refresh(view, 60_000)

    send(view.pid, :runtime_tick)
    render(view)

    assert view_assigns(view).payload_seq > seq_before
  end

  test "a payload load re-anchors :now only when a clock-bearing section moved" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    now_before = view_assigns(view).now

    # Nothing moved. `:now` is read inside the per-project comprehension (session
    # runtime, retry due-in), and a HEEx comprehension is one change-tracked
    # slot: re-anchoring here would re-evaluate and re-serialize every project
    # header, queue card, session row and restart form — the exact re-render the
    # section split exists to skip.
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, payload))
    render(view)

    assert view_assigns(view).now == now_before

    # A real move: the sections re-render anyway, so the clocks they carry have
    # to be anchored as of *this* render, not as of the last one.
    [entry | rest] = payload.running
    moved = %{entry | tokens: %{entry.tokens | total_tokens: entry.tokens.total_tokens + 1}}
    patched = %{payload | running: [moved | rest], projects: patch_running(payload.projects, moved)}

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, patched))
    render(view)

    assert DateTime.compare(view_assigns(view).now, now_before) == :gt
  end

  test "the payload is split into one assign per section, with no monolithic payload assign" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    assigns = view_assigns(view)

    refute Map.has_key?(assigns, :payload)

    assert assigns.counts.running == 1
    assert assigns.counts.retrying == 1
    assert assigns.token_totals.total_tokens == 12
    assert assigns.rate_limits == %{"primary" => %{"remaining" => 11}}
    assert assigns.polling.next_poll_in_ms == 5_000
    assert [%{name: "default"}] = assigns.projects
    assert [%{issue_identifier: "MT-HTTP"}] = assigns.running
    assert [%{issue_identifier: "MT-RETRY"}] = assigns.retrying
    assert assigns.completions == []
    assert assigns.payload_error == nil
  end

  test "re-delivering an identical payload leaves every section assign and the render untouched" do
    # With sessions RUNNING and a retry queued — the operator-facing acceptance.
    # Every wall-clock-derived value in the render is either a `data-clock`
    # anchor derived from `:now` (which does not move on a load that changed
    # nothing) or one of the volatile entry keys the signature ignores.
    orchestrator = start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # The throughput sparkline is seeded from the mount token sample and grows a
    # column on the first load, so take the baseline after one payload load.
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, Presenter.state_payload(orchestrator, 1_000)))
    render(view)

    assigns_before = view_assigns(view)
    payload_before = view_payload(view)
    html_before = render(view)

    # Rebuilt from the orchestrator rather than echoed back out of the view's own
    # assigns, so the sections have to come out equal on their own — echoing the
    # assigns would make the assertions below true by construction. The poll
    # countdown is advanced on top of it because a live orchestrator re-derives
    # it from the wall clock on every snapshot: "identical payload" in production
    # never includes an identical countdown, and the fixture freezes it.
    reloaded = Presenter.state_payload(orchestrator, 1_000)
    reloaded = %{reloaded | polling: %{reloaded.polling | next_poll_in_ms: 1_842}}
    send(view.pid, test_payload_loaded(view, assigns_before.payload_seq, reloaded))

    assert render(view) == html_before
    assert view_payload(view) == payload_before

    # Internal samples and the refresh timestamp move; no rendered section may. Not
    # one payload section, and not `:now` either — the per-project comprehension
    # reads `:now`, so re-anchoring it would re-serialize every project subtree
    # and put the whole board back on the wire for a poll that changed nothing.
    assert changed_assign_keys(assigns_before, view_assigns(view)) -- [:token_samples, :last_payload_refresh] == []
  end

  test "a poll whose only movement is generated_at leaves every section assign untouched" do
    # This is the shape of a real idle poll: the orchestrator snapshot is
    # re-read every few seconds and comes back with a fresh `generated_at` and
    # otherwise identical sections. Under the old monolithic `@payload` assign
    # that alone re-rendered the whole template. Sessions are running here too.
    orchestrator = start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, Presenter.state_payload(orchestrator, 1_000)))
    render(view)

    assigns_before = view_assigns(view)
    html_before = render(view)

    payload = Map.put(Presenter.state_payload(orchestrator, 1_000), :generated_at, "2026-08-16T00:00:00.000000Z")
    send(view.pid, test_payload_loaded(view, assigns_before.payload_seq, payload))

    assert render(view) == html_before
    assert changed_assign_keys(assigns_before, view_assigns(view)) -- [:token_samples, :last_payload_refresh] == []
  end

  test "a poll that only moves the countdown reassigns nothing at all" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # The throughput sparkline is seeded from the mount token sample and grows
    # its first column on the first load, so take the baseline after one load.
    payload = view_payload(view)
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, payload))
    render(view)

    assigns_before = view_assigns(view)

    # The poll countdown is the one thing that moves on every real orchestrator
    # snapshot: it is re-derived as `max(0, next_poll_due_at_ms - now_ms)`. It is
    # a `data-clock="countdown"` anchor the browser advances on its own, so an
    # integer-to-integer tick must not reassign `:polling` — reassigning it meant
    # no production payload load could ever ship an empty diff.
    ticked = %{payload | polling: %{payload.polling | next_poll_in_ms: 4_000}}

    send(view.pid, test_payload_loaded(view, assigns_before.payload_seq, ticked))
    render(view)

    assigns = view_assigns(view)

    assert assigns.polling == assigns_before.polling
    assert assigns.now == assigns_before.now
    assert assigns.projects == assigns_before.projects
    assert changed_assign_keys(assigns_before, assigns) -- [:token_samples, :last_payload_refresh] == []
  end

  test "a poll that stops scheduling, or starts checking, still reassigns :polling" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, payload))
    render(view)

    # `nil` is not countdown drift: it means no poll is scheduled, which drops
    # the anchor attribute and renders `n/a`. That has to land.
    unscheduled = %{payload | polling: %{payload.polling | next_poll_in_ms: nil}}
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, unscheduled))
    render(view)

    assert view_assigns(view).polling.next_poll_in_ms == nil

    # `checking?` flips true on every tick and false again when the cycle ends,
    # and it is in the signature — which is what lands the refreshed countdown
    # twice per poll despite the drift being ignored.
    checking = %{payload | polling: %{payload.polling | checking?: true, next_poll_in_ms: nil}}
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, checking))
    render(view)

    assert view_assigns(view).polling.checking? == true

    resumed = %{payload | polling: %{payload.polling | checking?: false, next_poll_in_ms: 29_000}}
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, resumed))
    render(view)

    assert view_assigns(view).polling.next_poll_in_ms == 29_000
  end

  test "a payload that only moves one section leaves the other section assigns alone" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    counts = %{payload.counts | running: 41}

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | counts: counts}))

    render(view)
    assigns = view_assigns(view)

    assert assigns.counts.running == 41
    assert assigns.projects == payload.projects
    assert assigns.running == payload.running
    assert assigns.retrying == payload.retrying
    assert assigns.polling == payload.polling
    assert assigns.rate_limits == payload.rate_limits
    assert assigns.token_totals == payload.token_totals
  end

  # Every one of these is re-derived from a wall clock (or poked by a
  # timestamp-only heartbeat) on every single load, so comparing it would make
  # `:running` / `:retrying` / `:projects` differ on every refresh while an agent
  # runs — precisely when the dashboard is busiest — and re-serialize every
  # Combobox in the project section.
  @volatile_running_moves [
    {:tokens_per_second, 99.5},
    {:last_event_at, "2026-08-16T00:00:00Z"}
  ]

  for {key, value} <- @volatile_running_moves do
    test "a poll where only a running entry's #{key} moved leaves the entry sections alone" do
      start_dashboard()

      {:ok, view, _html} = live(build_conn(), "/")

      payload = view_payload(view)
      send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, payload))
      render(view)

      [entry | rest] = payload.running
      moved = Map.put(entry, unquote(key), unquote(value))
      refute moved == entry

      assigns_before = view_assigns(view)
      patched = %{payload | running: [moved | rest], projects: patch_running(payload.projects, moved)}

      send(view.pid, test_payload_loaded(view, assigns_before.payload_seq, patched))

      render(view)
      assigns = view_assigns(view)

      assert assigns.running == assigns_before.running
      assert assigns.projects == assigns_before.projects
      assert assigns.now == assigns_before.now

      # The frozen value is the deliberate trade-off: the row keeps the `t/s`
      # chip and the expanded `@ <timestamp>` from the last load that moved a
      # real field rather than re-rendering the whole board for a number the
      # server re-derived from nothing but the clock.
      assert changed_assign_keys(assigns_before, assigns) -- [:token_samples, :last_payload_refresh] == []
    end
  end

  test "a retry payload whose only movement is due_at leaves :retrying and :projects alone" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, payload))
    render(view)

    # `due_at` is an absolute time the presenter re-derives as `utc_now +
    # due_in_ms`, so it jitters by the snapshot round-trip. Holding the previous
    # value is lossless: every real reschedule also moves `attempt`, `held`, or
    # `error`. Move it in both the top-level section and the nested project copy
    # — the nested one pins `Map.replace_lazy(:retrying, …)` in the signature.
    [retry | rest] = payload.retrying
    moved = Map.put(retry, :due_at, "2026-08-16T00:00:09Z")
    refute moved == retry

    projects = Enum.map(payload.projects, fn project -> %{project | retrying: [moved | rest]} end)

    assigns_before = view_assigns(view)

    send(
      view.pid,
      test_payload_loaded(view, assigns_before.payload_seq, %{payload | retrying: [moved | rest], projects: projects})
    )

    render(view)
    assigns = view_assigns(view)

    assert assigns.retrying == assigns_before.retrying
    assert assigns.projects == assigns_before.projects
    assert changed_assign_keys(assigns_before, assigns) -- [:token_samples, :last_payload_refresh] == []
  end

  test "a retry reschedule still lands because attempt moves with due_at" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    [retry | rest] = payload.retrying
    rescheduled = retry |> Map.put(:attempt, retry.attempt + 1) |> Map.put(:due_at, "2026-08-16T00:00:09Z")

    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | retrying: [rescheduled | rest]}))

    render(view)

    assert [%{attempt: attempt, due_at: "2026-08-16T00:00:09Z"}] = view_assigns(view).retrying
    assert attempt == retry.attempt + 1
  end

  test "an error payload resets every section to its default" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    send(
      view.pid,
      test_payload_loaded(view, view_assigns(view).payload_seq, %{
        generated_at: "2026-08-16T00:00:00Z",
        error: %{code: "snapshot_timeout", message: "Snapshot timed out"}
      })
    )

    html = render(view)
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_timeout"
    assert has_element?(view, ".status-badge-payload.status-badge-offline", "Unavailable")

    assigns = view_assigns(view)
    assert assigns.payload_error == %{code: "snapshot_timeout", message: "Snapshot timed out"}
    assert assigns.counts == %{running: 0, retrying: 0, waiting: 0, completed: 0, by_state: %{}, by_kind: %{}}
    assert assigns.token_totals == %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    assert assigns.rate_limits == nil
    assert assigns.polling == nil
    assert assigns.projects == []
    assert assigns.running == []
    assert assigns.retrying == []
    assert assigns.completions == []
  end

  test "a stale payload load cannot overwrite the split section assigns" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    payload = view_payload(view)
    stale_seq = view_assigns(view).payload_seq - 1

    send(view.pid, test_payload_loaded(view, stale_seq, %{payload | counts: %{payload.counts | running: 99}}))

    render(view)
    assert view_assigns(view).counts == payload.counts
  end

  # morphdom rewrites `fromEl.value = toEl.value` on every `<input>` it walks and
  # only spares the *focused*, non-hidden one, so any control whose rendered
  # value can differ from the last payload while the operator edits it has to
  # render from a draft assign. `field` names the draft slot; `value` is what was
  # typed.
  @field_draft_cases [
    {"project concurrency", ~s|form[phx-submit="set_project_concurrency"]|, "concurrency:default", "7"},
    {"project providers", ~s|form[phx-submit="set_project_providers"]|, "providers:default", "cz9,ck9"},
    {"global concurrency", ~s|form[phx-submit="set_concurrency"]|, "global-concurrency", "5"},
    {"refresh interval", ~s|form[phx-submit="set_refresh_interval"]|, "refresh-interval", "20"}
  ]

  for {label, _selector, key, typed} <- @field_draft_cases do
    test "an in-progress #{label} edit survives a payload reload" do
      start_dashboard()

      {:ok, view, _html} = live(build_conn(), "/")

      render_change(view, "preview_field", %{"field" => unquote(key), "value" => unquote(typed)})

      # A payload load lands mid-edit — this is the ~10/s case while an agent
      # runs. The typed value must still be what the input renders.
      payload = view_payload(view)
      counts = %{payload.counts | running: payload.counts.running + 1}
      send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | counts: counts}))

      html = render(view)

      assert view_assigns(view).field_drafts[unquote(key)] == unquote(typed)
      assert html =~ ~s(value="#{unquote(typed)}")
    end
  end

  test "a successful submit clears the field draft so the payload value renders again" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    render_change(view, "preview_field", %{"field" => "refresh-interval", "value" => "20"})
    assert view_assigns(view).field_drafts["refresh-interval"] == "20"

    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "20"})
    |> render_submit()

    # Holding the draft forever would freeze the control against
    # `POST /api/v1/refresh-interval` and against another tab.
    refute Map.has_key?(view_assigns(view).field_drafts, "refresh-interval")
    assert view_assigns(view).payload_refresh_seconds == 20
    assert render(view) =~ ~s(id="drawer-refresh-interval")
  end

  test "an in-progress add-project edit survives a payload reload" do
    start_dashboard()
    {:ok, config} = CymphonyConfig.load()
    assert :ok = CymphonyConfig.save(Map.put(config, "linear_api_key", "lin_api_fake"))

    {:ok, view, _html} = live(build_conn(), "/")

    render_change(view, "preview_add_project", %{
      "linear_project_slug" => "ailogic-ced4159f70c4",
      "name" => "Agent Farm",
      "github_repo_url" => "https://github.com/acme/farm",
      "agent" => "codex",
      "model" => "",
      "effort" => "",
      "provider" => ""
    })

    payload = view_payload(view)
    counts = %{payload.counts | running: payload.counts.running + 1}
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | counts: counts}))

    html = render(view)
    assigns = view_assigns(view)

    assert assigns.add_project_slug == "ailogic-ced4159f70c4"
    assert assigns.add_project_name == "Agent Farm"
    assert assigns.add_project_github == "https://github.com/acme/farm"
    assert html =~ ~s(value="Agent Farm")
    assert html =~ ~s(value="https://github.com/acme/farm")
    assert html =~ ~s(value="ailogic-ced4159f70c4")
  end

  test "preview_project_agent records a model draft when the project has no persisted kind" do
    snapshot = static_snapshot() |> Map.put(:agent_kind, nil) |> Map.put(:agent_model, nil)
    start_dashboard(snapshot: snapshot, recipient: self())

    {:ok, view, _html} = live(build_conn(), "/")

    seq_before = view_assigns(view).payload_seq

    # A project with no persisted `agent_kind` renders `kind: ""`, so choosing a
    # *model* posts `agent_kind=""`. Dropping that preview reverted the model on
    # the next patch.
    render_change(view, "preview_project_agent", %{
      "project" => "default",
      "agent_kind" => "",
      "model" => "gpt-5.2-codex",
      "effort" => ""
    })

    assert view_assigns(view).agent_setting_drafts["default"] == %{
             kind: "",
             model: "gpt-5.2-codex",
             effort: ""
           }

    # An empty kind is nothing to persist, and a reload here would throw the
    # draft away.
    refute_receive {:orchestrator_call, {:set_agent_settings, _}}, 100
    assert view_assigns(view).payload_seq == seq_before
  end

  test "client-owned controls are frozen with phx-update=ignore" do
    start_dashboard()

    {:ok, view, _html} = live(build_conn(), "/")

    # The Linear key must never reach assigns, so the server has no correct value
    # to render; density/section/column prefs and the mode switch are pure
    # localStorage state. Freezing the subtree beats repairing it after every
    # patch (morphdom re-applies `checked`/`aria-pressed`/`selected` on each one).
    for id <- ~w(linear-connect-form settings-display settings-experience mode-switch-top) do
      assert has_element?(view, ~s|##{id}[phx-update="ignore"]|)
    end

    # Freezing the form must not disarm its submit.
    assert has_element?(view, ~s|#linear-connect-form[phx-submit="connect_linear"]|)
    assert has_element?(view, "#linear-api-key")
  end

  @immediate_reload_events [
    {"kill_issue", ~s|button[phx-click="kill_issue"][phx-value-issue="MT-HTTP"]|},
    {"retry_issue", ~s|button[phx-click="retry_issue"][phx-value-issue="MT-RETRY"]|},
    # Two Refresh buttons exist now: the rail foot owns it at wide widths and the
    # top strip keeps its own copy. Scope to the top strip one.
    {"refresh_now", ~s|.command-bar-meta button[phx-click="refresh_now"]|}
  ]

  for {event, selector} <- @immediate_reload_events do
    test "#{event} reloads the payload immediately" do
      start_dashboard(recipient: self())

      {:ok, view, _html} = live(build_conn(), "/")

      seq_before = view_assigns(view).payload_seq

      view |> element(unquote(selector)) |> render_click()

      # The repaint used to come for free from the orchestrator's broadcast. Now
      # that a broadcast only marks the payload dirty, the command's own task has
      # to ask for the reload — after the call, so it cannot race ahead of it.
      assert_eventually(fn -> view_assigns(view).payload_seq > seq_before end)
    end
  end

  test "set_issue_run_spec reloads the payload immediately" do
    start_dashboard(recipient: self())

    {:ok, view, _html} = live(build_conn(), "/")

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    seq_before = view_assigns(view).payload_seq

    render_submit(view, "set_issue_run_spec", %{"issue" => "MT-HTTP", "agent_kind" => "codex"})

    assert_receive {:orchestrator_call, {:set_issue_run_spec, "issue-http", _overrides}}, 1_000
    assert_eventually(fn -> view_assigns(view).payload_seq > seq_before end)
  end

  test "a payload load with no real change ships no diff, and a harness line does not re-render the board" do
    start_dashboard()

    {:ok, view, full_html} = live(build_conn(), "/")

    # Park the periodic reload far away so nothing but the measured event can
    # produce a diff.
    view |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "600"}) |> render_submit()
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, view_payload(view)))
    render(view)

    :erlang.trace(view.pid, true, [:send])

    idle_bytes =
      measure_diff_bytes(view, fn ->
        # "No real change" has to mean what it means against a live orchestrator,
        # where the poll countdown is re-derived from the wall clock on every
        # snapshot. Echoing a frozen fixture back would prove nothing: it would
        # pass even if the countdown reassigned `:polling` on every load, which
        # is exactly the leak this pins shut.
        payload = view_payload(view)
        ticked = %{payload | polling: %{payload.polling | next_poll_in_ms: 3_137}}

        send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, ticked))
      end)

    # An unchanged load must produce an *empty* diff — LiveView skips the morph
    # entirely for `%{}`, and a morph is what resets every non-focused input and
    # closes every open Combobox panel.
    assert idle_bytes == 0

    heartbeat_bytes =
      measure_diff_bytes(view, fn ->
        payload = view_payload(view)
        [entry | rest] = payload.running
        moved = Map.put(entry, :last_event_at, "2026-08-16T00:00:00Z")
        patched = %{payload | running: [moved | rest], projects: patch_running(payload.projects, moved)}

        send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, patched))
      end)

    assert heartbeat_bytes == 0

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    render(view)

    harness_diff =
      capture_diff_text(view, fn ->
        send(view.pid, %{
          event: :harness_stream,
          issue_id: "issue-http",
          last_seq: 3,
          lines: [%{seq: 3, at: DateTime.utc_now(), text: "hello world line"}],
          dropped: 0
        })
      end)

    # A streaming harness line patches up to ~12×/s, so what goes on the wire has
    # to be the pane and only the pane. It used to be the whole project section:
    # the pane hung off a `<% tail = … %>` binding inside the per-project
    # comprehension, and one template-local variable disables change tracking for
    # every dynamic after it, so the section's Comboboxes rode along. The row is
    # now a `<.session_row>` function component whose attrs are tracked one by
    # one — only `tail` moved — and the comprehensions are `:key`ed.
    assert harness_diff =~ "hello world line"
    refute harness_diff =~ "combobox"
    refute harness_diff =~ "spec-switcher"
    refute harness_diff =~ "queue-card"
    refute harness_diff =~ "session-row-summary"

    # Re-serializing one project section's Comboboxes alone was ~2.5 KB; the pane
    # (a `data-follow` attribute, the Follow/Paused label, one line, and the
    # one-time static for `.harness-tail-line`) is an order of magnitude under it.
    assert byte_size(harness_diff) < 1_024
    assert byte_size(harness_diff) < div(byte_size(full_html), 50)

    :erlang.trace(view.pid, false, [:send])
  end

  @tag queue_diff: true
  test "a queue title update does not repaint session controls or clocks for concurrent volatile drift" do
    start_dashboard(snapshot: Map.put(static_snapshot(), :waiting, [waiting_snapshot_entry(%{identifier: "DIFF-1"})]))
    {:ok, view, _html} = live(build_conn(), "/")
    view |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "600"}) |> render_submit()
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, view_payload(view)))
    render(view)

    view
    |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
    |> render_click()

    payload = view_payload(view)
    now_before = view_assigns(view).now
    [running] = payload.running
    [retrying] = payload.retrying
    running = Map.merge(running, %{last_event_at: "2026-09-25T00:00:00Z", tokens_per_second: 987.0})
    retrying = Map.put(retrying, :due_at, "2026-09-25T00:00:01Z")

    projects =
      payload.projects
      |> patch_waiting_title("DIFF-1", "Only this title changed")
      |> patch_running(running)
      |> Enum.map(&%{&1 | retrying: [retrying]})

    drifted = %{
      payload
      | projects: projects,
        running: [running],
        retrying: [retrying],
        polling: %{payload.polling | next_poll_in_ms: 3_137}
    }

    :erlang.trace(view.pid, true, [:send])

    diff =
      capture_diff_text(view, fn ->
        send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, drifted))
      end)

    assert diff =~ "Only this title changed"
    refute diff =~ "spec-switcher"
    refute diff =~ "data-base-seconds"
    refute diff =~ "data-remaining-ms"
    refute diff =~ "session-row"
    assert byte_size(diff) < 512
    assert view_assigns(view).now == now_before
    assert has_element?(view, "#queue-card-default-DIFF-1 .queue-card-title", "Only this title changed")
    :erlang.trace(view.pid, false, [:send])

    # A real retry update still lands, including its fresh clock anchor.
    retrying = %{retrying | attempt: 3, failed_attempts: 3}
    projects = Enum.map(projects, &%{&1 | retrying: [retrying]})
    changed = %{drifted | projects: projects, retrying: [retrying]}
    send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, changed))
    render(view)
    assert DateTime.compare(view_assigns(view).now, now_before) == :gt
    assert has_element?(view, ".retry-row .chip--warn", "Failed starts 3")
  end

  for queue_size <- [3, 100] do
    @tag queue_diff: true
    test "a #{queue_size}-card queue patches one title and preserves its keyed editor on reorder" do
      waiting =
        for rank <- 1..unquote(queue_size) do
          waiting_snapshot_entry(%{
            identifier: "DIFF-#{rank}",
            title: "Unchanged queue title #{rank}",
            agent_kind: "codex",
            model: "gpt-5.2-codex",
            effort: "high"
          })
        end

      start_dashboard(snapshot: Map.put(static_snapshot(), :waiting, waiting))
      {:ok, view, _html} = live(build_conn(), "/")
      view |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "600"}) |> render_submit()
      send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, view_payload(view)))
      render(view)

      view
      |> element(~s|button.queue-card-edit-toggle[phx-value-issue="DIFF-2"]|)
      |> render_click()

      render_change(view, "preview_queue_run_spec", %{
        "project" => "default",
        "issue" => "DIFF-2",
        "agent_kind" => "codex",
        "model" => "unsaved-model",
        "effort" => "low"
      })

      editor = "#queue-edit-default-DIFF-2"
      editor_before = view |> element(editor) |> render()
      draft_before = view_assigns(view).queue_run_spec_drafts
      assert has_element?(view, ~s|#{editor} #queue-model-DIFF-2[value="unsaved-model"]|)
      assert has_element?(view, ~s|#{editor} #spec-switcher-queue-agent-DIFF-2[phx-hook="SpecSwitcher"]|)

      :erlang.trace(view.pid, true, [:send])

      # Cover both a sibling card changing and the card owning the open editor.
      # Queue size must not affect the patch: serializing unchanged rows or the
      # editor would reset client-owned switcher state during observation loads.
      for identifier <- ["DIFF-1", "DIFF-2"] do
        title = "Changed title #{identifier}"

        diff =
          capture_diff_text(view, fn ->
            payload = view_payload(view)

            projects = patch_waiting_title(payload.projects, identifier, title)

            send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | projects: projects}))
          end)

        assert diff =~ title
        refute diff =~ "Unchanged queue title"
        refute diff =~ "queue-card"
        refute diff =~ "queue-edit"
        refute diff =~ "spec-switcher"
        refute diff =~ "combobox"
        refute diff =~ "unsaved-model"
        refute diff =~ "session-row"
        assert byte_size(diff) < 512

        assert has_element?(view, "#queue-card-default-#{identifier} .queue-card-title", title)
        assert view |> element(editor) |> render() == editor_before
        assert view_assigns(view).queue_run_spec_drafts == draft_before
        assert view_assigns(view).queue_edit_ids == MapSet.new([{"default", "DIFF-2"}])
      end

      # Move the edited card into the Next position. Stable keys must move its
      # existing edit subtree, not serialize a replacement switcher or lose the
      # unsaved draft. This also exercises the rank badge's template boundary.
      reordered =
        capture_diff_text(view, fn ->
          payload = view_payload(view)

          projects =
            Enum.map(payload.projects, fn project ->
              [first | rest] = project.waiting
              %{project | waiting: rest ++ [first]}
            end)

          send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, %{payload | projects: projects}))
        end)

      refute reordered =~ "Unchanged queue title"
      refute reordered =~ "Changed title"
      refute reordered =~ "spec-switcher"
      refute reordered =~ "unsaved-model"
      assert view |> element(editor) |> render() == editor_before
      assert view_assigns(view).queue_run_spec_drafts == draft_before
      assert view_assigns(view).queue_edit_ids == MapSet.new([{"default", "DIFF-2"}])
      assert has_element?(view, ~s|#queue-card-default-DIFF-2[data-rank="0"] .queue-next-badge|)
      refute has_element?(view, ~s|#queue-card-default-DIFF-2 .queue-next-badge[style*="display: none"]|)
      assert has_element?(view, ~s|#queue-card-default-DIFF-1 .queue-next-badge[style="display: none"]|)

      order =
        view
        |> element("#queue-board-default")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find(".queue-card")
        |> Floki.attribute("data-issue")

      assert order == Enum.map(2..unquote(queue_size), &"DIFF-#{&1}") ++ ["DIFF-1"]

      assert measure_diff_bytes(view, fn ->
               send(view.pid, test_payload_loaded(view, view_assigns(view).payload_seq, view_payload(view)))
             end) == 0

      :erlang.trace(view.pid, false, [:send])
    end
  end

  # Assign keys whose value moved between two snapshots of the socket. LiveView
  # only re-evaluates (and only ships a diff for) assigns it marked as changed,
  # so an empty list is the server-side proxy for "no websocket traffic".
  defp changed_assign_keys(before_assigns, after_assigns) do
    before_assigns
    |> Map.merge(after_assigns)
    |> Map.keys()
    |> Enum.reject(&(Map.fetch(before_assigns, &1) == Map.fetch(after_assigns, &1)))
    |> Enum.sort()
  end

  defp wait_until(fun), do: wait_until(fun, System.monotonic_time(:millisecond) + 3_000)

  defp wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        :timer.sleep(25)
        wait_until(fun, deadline)
    end
  end

  defp start_dashboard(opts \\ []) do
    isolate_cymphony_home()
    stub_linear_graphql(fn _payload, _headers -> {:error, :stub_unused} end)

    previous_fetcher = Application.fetch_env(:cymphony_elixir, :codex_catalog_fetcher)
    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> {:ok, ~s({"models": []})} end)
    CymphonyElixir.AgentCatalog.clear_cache()

    on_exit(fn ->
      case previous_fetcher do
        {:ok, fetcher} -> Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fetcher)
        :error -> Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
      end

      CymphonyElixir.AgentCatalog.clear_cache()
    end)

    orchestrator_name = Module.concat(__MODULE__, :"Orch#{System.unique_integer([:positive])}")

    snapshot = Keyword.get(opts, :snapshot, static_snapshot())

    start_supervised!({StaticOrchestrator, [name: orchestrator_name, snapshot: snapshot, recipient: Keyword.get(opts, :recipient)]})

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    ensure_harness_stream_started()
    orchestrator_name
  end

  defp isolate_cymphony_home do
    tmp = Path.join(System.tmp_dir!(), "cymphony-dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "config.json"), ~s({"projects":[{"name":"default"}]}))

    previous_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)

      if is_nil(previous_dir) do
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      else
        Application.put_env(:cymphony_elixir, :config_dir_override, previous_dir)
      end

      if is_nil(previous_opts) do
        Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
      else
        Application.put_env(:cymphony_elixir, :linear_graphql_opts, previous_opts)
      end

      File.rm_rf!(tmp)
    end)
  end

  defp stub_linear_graphql(fun) when is_function(fun, 2) do
    Application.put_env(:cymphony_elixir, :linear_graphql_opts, request_fun: fun)
  end

  defp linear_success_request(payload, _headers) do
    query = payload["query"] || ""

    cond do
      String.contains?(query, "CymphonyLinearViewer") ->
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "usr_test"}}}}}

      String.contains?(query, "CymphonyLinearProjects") ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{"id" => "proj-1", "name" => "Agent Farm", "slugId" => "ailogic-ced4159f70c4"}
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}

      true ->
        {:ok, %{status: 200, body: %{"data" => %{}}}}
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, _attempts) do
    flunk("condition was not met in time")
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :cymphony_elixir
      |> Application.get_env(CymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({CymphonyElixirWeb.Endpoint, []})
  end

  defp ensure_harness_stream_started do
    mod = CymphonyElixir.HarnessStream

    cond do
      Process.whereis(mod) ->
        :ok

      Code.ensure_loaded?(mod) and function_exported?(mod, :start_link, 1) ->
        start_supervised!({mod, []})
        :ok

      true ->
        :ok
    end
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          agent_os_pid: nil,
          last_agent_message: "rendered",
          last_agent_timestamp: nil,
          last_agent_event: :notification,
          input_tokens: 4,
          output_tokens: 8,
          total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      waiting: [],
      token_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      agent_kind: "claude",
      agent_model: nil,
      agent_effort: nil,
      polling: %{
        next_poll_in_ms: 5_000,
        poll_interval_ms: 30_000,
        paused: false,
        checking?: false
      }
    }
  end

  defp view_assigns(view) do
    case :sys.get_state(view.pid) do
      %{socket: %{assigns: assigns}} -> assigns
      %{assigns: assigns} -> assigns
    end
  end

  # The bytes LiveView actually pushed to the client for one event. Every other
  # test here asserts on *assigns*, which is why a 12.5 Hz harness re-render of
  # every Combobox on the board went unnoticed for so long: the assigns were
  # right, the wire was not. Requires `:erlang.trace(view.pid, true, [:send])`.
  defp measure_diff_bytes(view, fun), do: byte_size(capture_diff_text(view, fun))

  # JSON-encoded diff bytes (never inspect/1, which truncates large payloads),
  # so a test can assert on *what* was resent and not only on
  # how much. `byte_size(a) + byte_size(b) == byte_size(a <> b)`, so this is the
  # same number `measure_diff_bytes/2` always reported.
  defp capture_diff_text(view, fun) do
    drain_diff_text("")
    fun.()
    render(view)
    drain_diff_text("")
  end

  defp drain_diff_text(acc) do
    receive do
      {:trace, _pid, :send, %Phoenix.Socket.Message{event: "diff", payload: payload}, _to} ->
        drain_diff_text(acc <> Jason.encode!(payload))

      {:trace, _pid, :send, _msg, _to} ->
        drain_diff_text(acc)
    after
      120 -> acc
    end
  end

  # Move the refresh window into the past so the next `:runtime_tick` is due,
  # instead of sleeping for the real interval (the idle resync is 30s).
  # `:last_payload_refresh` is never rendered, so writing it behind change
  # tracking's back costs nothing.
  defp backdate_payload_refresh(view, ms) do
    :sys.replace_state(view.pid, fn %{socket: socket} = state ->
      assigns = Map.update!(socket.assigns, :last_payload_refresh, &(&1 - ms))
      %{state | socket: %{socket | assigns: assigns}}
    end)

    :ok
  end

  # Deliver through the real task-result handler with a matching active job.
  # A stale sequence gets an unknown ref and cannot replace the current view.
  defp test_payload_loaded(view, seq, payload) do
    assigns = view_assigns(view)
    ref = make_ref()

    if seq == assigns.payload_seq do
      :sys.replace_state(view.pid, fn %{socket: socket} = state ->
        job = %{
          ref: ref,
          pid: nil,
          task: nil,
          generation: socket.assigns.payload_generation,
          timer_ref: make_ref()
        }

        %{state | socket: %{socket | assigns: Map.put(socket.assigns, :payload_job, job)}}
      end)
    end

    {ref, payload}
  end

  # The LiveView keeps one assign per payload section instead of a single
  # `:payload` map, so rebuild the payload shape used by test snapshots.
  defp view_payload(view) do
    assigns = view_assigns(view)

    %{
      counts: assigns.counts,
      running: assigns.running,
      retrying: assigns.retrying,
      token_totals: assigns.token_totals,
      rate_limits: assigns.rate_limits,
      polling: assigns.polling,
      projects: assigns.projects,
      recent_completed: assigns.completions
    }
  end

  defp patch_waiting_title(projects, identifier, title) do
    Enum.map(projects, fn project ->
      %{project | waiting: patch_waiting_entries(project.waiting, identifier, title)}
    end)
  end

  defp patch_waiting_entries(waiting, identifier, title) do
    Enum.map(waiting, fn entry ->
      if entry.issue_identifier == identifier, do: %{entry | issue_title: title}, else: entry
    end)
  end

  defp patch_running(projects, entry) do
    Enum.map(projects, fn project ->
      %{project | running: patch_running_entries(project.running, entry)}
    end)
  end

  defp patch_running_entries(running, entry) do
    Enum.map(running, fn current ->
      if current.issue_identifier == entry.issue_identifier, do: entry, else: current
    end)
  end

  defp waiting_snapshot_entry(overrides) do
    identifier = Map.get(overrides, :identifier, "LLM-51")
    title = Map.get(overrides, :title, "Queue card title")
    priority = Map.get(overrides, :priority, 2)
    created_at = Map.get(overrides, :created_at, ~U[2026-03-01 12:00:00Z])

    %{
      issue_id: Map.get(overrides, :issue_id, "issue-#{identifier}"),
      identifier: identifier,
      issue: %{
        title: title,
        url: Map.get(overrides, :url, "https://linear.app/test/issue/#{identifier}"),
        priority: priority,
        created_at: created_at
      },
      priority: priority,
      state: Map.get(overrides, :state, "Todo"),
      created_at: created_at,
      agent_kind: Map.get(overrides, :agent_kind),
      model: Map.get(overrides, :model),
      effort: Map.get(overrides, :effort)
    }
  end
end
