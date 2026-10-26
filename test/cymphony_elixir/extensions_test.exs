unless Code.ensure_loaded?(CymphonyElixir.HarnessStream) do
  defmodule CymphonyElixir.HarnessStream do
    @moduledoc false

    def snapshot(issue_id) when is_binary(issue_id) do
      %{issue_id: issue_id, last_seq: 0, lines: [], dropped: 0}
    end
  end
end

defmodule CymphonyElixir.ExtensionsTest do
  use CymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CymphonyElixir.Linear.Adapter
  alias CymphonyElixir.Tracker.Memory

  @endpoint CymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end

    def graphql_opts_for_config(_config), do: []

    def graphql(query, variables, _opts), do: graphql(query, variables)
  end

  # A *reachable* orchestrator that cannot answer. This is what
  # `snapshot_unavailable` is for, and it is now distinct from a daemon with no
  # orchestrator at all — which is an empty fleet, not a failure, and comes back
  # as a normal payload with `projects: []`.
  defmodule DownOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state), do: {:reply, :unavailable, state}
    def handle_call(:request_refresh, _from, state), do: {:reply, :unavailable, state}
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts) do
      if project_name = Keyword.get(opts, :project_name) do
        {:ok, _} = Registry.register(CymphonyElixir.ProjectRegistry, {project_name, :orchestrator}, nil)
      end

      {:ok, opts}
    end

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:reorder_queue, order} = call, _from, state) when is_list(order) do
      if recipient = Keyword.get(state, :recipient), do: send(recipient, {:orchestrator_call, call})

      state =
        if Keyword.get(state, :reorder_snapshot?) do
          snapshot = Keyword.fetch!(state, :snapshot)
          waiting = snapshot.waiting
          by_identifier = Map.new(waiting, &{&1.identifier, &1})
          reordered = Enum.flat_map(order, &List.wrap(Map.get(by_identifier, &1)))
          leftover = Enum.reject(waiting, &(&1.identifier in order))
          Keyword.put(state, :snapshot, %{snapshot | waiting: reordered ++ leftover})
        else
          state
        end

      {:reply, :ok, state}
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
    linear_client_module = Application.get_env(:cymphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:cymphony_elixir, :linear_client_module)
      else
        Application.put_env(:cymphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end

    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    ensure_workflow_store_running()

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert CymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = CymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = CymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = CymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = CymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = CymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:cymphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert CymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:cymphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "linear adapter create_comment/3 and update_issue_state/3 thread config and validate responses" do
    Application.put_env(:cymphony_elixir, :linear_client_module, FakeLinearClient)
    config = %CymphonyElixir.Config.Schema{}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-9", "hi", config)
    assert_receive {:graphql_called, comment_query, %{body: "hi", issueId: "issue-9"}}
    assert comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-9", "no", config)

    Process.put({FakeLinearClient, :graphql_result}, {:error, :down})
    assert {:error, :down} = Adapter.create_comment("issue-9", "err", config)

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "s1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-9", "Done", config)
    assert_receive {:graphql_called, _lookup_query, %{issueId: "issue-9", stateName: "Done"}}
    assert_receive {:graphql_called, update_query, %{issueId: "issue-9", stateId: "s1"}}
    assert update_query =~ "issueUpdate"
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "counts" => %{
               "running" => 1,
               "retrying" => 1,
               "waiting" => 0,
               "completed" => 0,
               "by_state" => %{"In Progress" => 1},
               "by_kind" => %{"unknown" => 1}
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "issue_title" => nil,
                 "issue_url" => nil,
                 "priority" => nil,
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "provider" => nil,
                 "agent_kind" => nil,
                 "model" => nil,
                 "effort" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "stalled" => false,
                 "log_events" => [],
                 "project_name" => "default",
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12},
                 "tokens_per_second" => state_payload["running"] |> List.first() |> Map.fetch!("tokens_per_second")
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "project_name" => "default",
                 "issue_title" => nil,
                 "issue_url" => nil,
                 "priority" => nil,
                 "attempt" => 2,
                 "failed_attempts" => 2,
                 "wait_reason" => nil,
                 "hold_reason" => nil,
                 "held" => false,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "tokens" => %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0},
                 "turn_count" => 0,
                 "session_id" => nil,
                 "started_at" => nil,
                 "last_event" => nil,
                 "last_message" => nil,
                 "log_events" => []
               }
             ],
             "token_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5,
               "tokens_per_second" => 12 / 42.5
             },
             "polling" => %{
               "next_poll_in_ms" => 5_000,
               "poll_interval_ms" => 30_000,
               "paused" => false,
               "checking?" => false
             },
             "projects" => state_payload["projects"],
             "rate_limits" => %{"primary" => %{"remaining" => 11}},
             "recent_completed" => []
           }

    assert [project] = state_payload["projects"]
    assert project["name"] == "default"
    assert project["running_count"] == 1
    assert project["retrying_count"] == 1
    assert project["waiting_count"] == 0
    assert project["waiting"] == []
    assert project["paused"] == false
    assert project["providers"] == []
    assert is_list(project["running"])
    assert is_list(project["retrying"])

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "log_events" => [],
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"claude_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    {:ok, _pid} = DownOrchestrator.start_link(name: unavailable_orchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh-interval"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "a fleet with no orchestrator at all is an empty payload, not an error" do
    # The registry is empty and the legacy name is not registered: nothing is
    # broken, there is simply nothing to run. Reporting `snapshot_unavailable`
    # here left the dashboard's "No projects / connect Linear" card unreachable
    # in production — the only payload a zero-project daemon could produce took
    # the error branch instead.
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :NoOrchestratorAtAll),
      snapshot_timeout_ms: 5
    )

    payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    refute Map.has_key?(payload, "error")
    assert payload["projects"] == []
    assert payload["running"] == []
    assert payload["retrying"] == []
    assert payload["recent_completed"] == []
    assert payload["polling"] == nil
    assert payload["rate_limits"] == nil
    assert payload["counts"]["running"] == 0
    assert payload["counts"]["retrying"] == 0
    assert payload["counts"]["waiting"] == 0
    assert payload["token_totals"]["total_tokens"] == 0
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-transport"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-payload"

    claude_icon = get(build_conn(), "/icons/claude.png")
    assert claude_icon.status == 200
    assert Plug.Conn.get_resp_header(claude_icon, "content-type") == ["image/png"]
    assert byte_size(claude_icon.resp_body) > 100

    assert get(build_conn(), "/icons/codex.png").status == 200
    assert get(build_conn(), "/icons/agy.png").status == 200
    assert get(build_conn(), "/icons/missing.png").status == 404

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "CYMPHONY"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    refute html =~ "Unavailable"
    # Per-project section shows the project header and inline controls.
    assert html =~ "set_project_concurrency"
    assert html =~ "set_project_providers"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-transport"
    assert html =~ "status-badge-payload"

    # Expand the session row → "Copy ID" and "Workspace" labels become visible.
    expanded =
      view
      |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

    assert expanded =~ "Copy ID"
    assert expanded =~ "Workspace"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_agent_event: :notification,
          last_agent_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "claude/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_agent_timestamp: DateTime.utc_now(),
          input_tokens: 10,
          output_tokens: 12,
          total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    # A pubsub broadcast no longer reloads on the spot — it marks the payload
    # dirty and the next due runtime tick coalesces it into one load, so the
    # orchestrator's 2-broadcasts-per-poll cadence can no longer override
    # `dashboard_refresh_seconds`. Shorten the interval so the tick is due.
    view
    |> form(~s|form[phx-submit="set_refresh_interval"]|, %{value: "1"})
    |> render_submit()

    StatusDashboard.notify_update()

    assert_eventually(
      fn ->
        render(view) =~ "agent message content streaming: structured update"
      end,
      120
    )
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    orchestrator_name = Module.concat(__MODULE__, :BrokenDashboardOrchestrator)
    {:ok, _pid} = DownOrchestrator.start_link(name: orchestrator_name)
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 5)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
    assert has_element?(view, ".status-badge-payload.status-badge-offline", "Unavailable")
    refute has_element?(view, ".status-badge-payload.status-badge-live")
    refute html =~ "fleet-empty"
  end

  test "dashboard liveview shows the fleet-empty card when no orchestrator is running" do
    # The production shape of a zero-project fleet, end to end: empty registry,
    # no legacy orchestrator, real `Presenter.state_payload/2`. It must reach the
    # "No projects" card, not the red error card.
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, view, html} = live(build_conn(), "/")

    refute html =~ "snapshot_unavailable"
    assert has_element?(view, "section.section-card.fleet-empty .fleet-empty-label", "No projects")
    assert has_element?(view, ".fleet-empty-action[data-drawer-toggle]", "Open settings")
    assert has_element?(view, ".status-badge-payload.status-badge-live")
  end

  describe "recent completions" do
    test "GET /api/v1/completed returns the ring buffer; ?limit=N truncates" do
      unless Process.whereis(CymphonyElixir.CompletionStore) do
        start_supervised!(CymphonyElixir.CompletionStore)
      end

      # Default GET reads the orchestrator snapshot. `?limit=` reads the
      # durable CompletionStore. Seed both so the two paths cannot flake
      # on an empty store or leftover rows from a sibling test.
      stamp = System.unique_integer([:positive])
      now = DateTime.utc_now()

      records =
        for n <- 1..3 do
          %{
            issue_id: "issue-#{stamp}-#{n}",
            identifier: "MT-#{stamp}-#{n}",
            project_name: "default",
            ended_at: DateTime.add(now, 31_536_000 - n, :second),
            started_at: DateTime.add(now, -60 * n, :second),
            runtime_seconds: 60,
            input_tokens: 10,
            output_tokens: 20,
            total_tokens: 30,
            last_event: nil,
            last_message: nil,
            worker_host: nil,
            workspace_path: nil
          }
        end

      orchestrator_name = Module.concat(__MODULE__, :CompletedOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          project_name: "default",
          snapshot: Map.put(static_snapshot(), :recent_completed, records)
        )

      Enum.each(records, &CymphonyElixir.CompletionStore.put_async/1)
      _ = CymphonyElixir.CompletionStore.count(:all)

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 200)

      conn = get(build_conn(), "/api/v1/completed")
      payload = json_response(conn, 200)

      assert length(payload["recent_completed"]) == 3
      assert hd(payload["recent_completed"])["issue_identifier"] == "MT-#{stamp}-1"

      conn = get(build_conn(), "/api/v1/completed?limit=2")
      payload = json_response(conn, 200)
      assert length(payload["recent_completed"]) == 2

      assert Enum.map(payload["recent_completed"], & &1["issue_identifier"]) == [
               "MT-#{stamp}-1",
               "MT-#{stamp}-2"
             ]
    end
  end

  describe "pause / resume" do
    test "POST /api/v1/pause sets paused flag and POST /api/v1/resume clears it" do
      tmp = isolate_config_dir!()
      orchestrator_name = Module.concat(__MODULE__, :PauseOrchestrator)
      {:ok, pid} = CymphonyElixir.Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert %{status: 202, resp_body: pause_body} = post(build_conn(), "/api/v1/pause", %{})
      assert pause_body =~ ~s("paused":true)

      snapshot = CymphonyElixir.Orchestrator.snapshot(orchestrator_name, 1_000)
      assert snapshot.polling.paused == true
      assert stored_dispatch_paused(tmp) == [true]

      assert %{status: 202, resp_body: resume_body} = post(build_conn(), "/api/v1/resume", %{})
      assert resume_body =~ ~s("paused":false)

      snapshot = CymphonyElixir.Orchestrator.snapshot(orchestrator_name, 1_000)
      assert snapshot.polling.paused == false
      assert stored_dispatch_paused(tmp) == [false]
    end

    test "POST /api/v1/pause still answers 202 with ?project= and persists" do
      tmp = isolate_config_dir!()
      orchestrator_name = Module.concat(__MODULE__, :PauseScopedOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert %{status: 202, resp_body: body} = post(build_conn(), "/api/v1/pause?project=alpha", %{})
      assert body =~ ~s("paused":true)
      assert body =~ ~s("project":"alpha")
      assert_receive {:orchestrator_call, :pause}, 1_000
      assert stored_dispatch_paused(tmp) == [true]
    end

    test "a project persisted as paused starts paused and does not dispatch on the first tick" do
      tmp = isolate_config_dir!(~s({"projects": [{"name": "alpha", "dispatch_paused": true}]}))
      assert File.exists?(Path.join(tmp, "config.json"))

      {:ok, pid} =
        CymphonyElixir.Orchestrator.start_link(
          name: Module.concat(__MODULE__, :PausedBootOrchestrator),
          project_name: "alpha"
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert CymphonyElixir.Orchestrator.snapshot(pid, 1_000).polling.paused == true
    end
  end

  describe "dashboard liveview writable surface" do
    test "kill_issue sends the UUID issue_id to the orchestrator (regression for identifier mix-up)" do
      orchestrator_name = Module.concat(__MODULE__, :KillOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element(~s|button[phx-click="kill_issue"][phx-value-issue="MT-HTTP"]|)
      |> render_click()

      assert_receive {:orchestrator_call, {:kill_issue, "issue-http"}}, 1_000
    end

    test "retry_issue sends the UUID issue_id to the orchestrator" do
      orchestrator_name = Module.concat(__MODULE__, :RetryOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> element(~s|button[phx-click="retry_issue"][phx-value-issue="MT-RETRY"]|)
      |> render_click()

      assert_receive {:orchestrator_call, {:retry_issue_now, "issue-retry"}}, 1_000
    end

    test "set_issue_run_spec submits the UUID issue_id and pinned overrides to the orchestrator" do
      orchestrator_name = Module.concat(__MODULE__, :SetRunSpecOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      # Expand the row first so the restart-with-overrides form is rendered.
      expanded =
        view
        |> element(~s|button[phx-click="toggle_logs"][phx-value-issue="MT-HTTP"]|)
        |> render_click()

      assert expanded =~ ~s(phx-submit="set_issue_run_spec")
      # Agent kind is intentionally not offered per running session.
      refute expanded =~ ~s(name="agent_kind" form="set_issue_run_spec")

      render_submit(view, "set_issue_run_spec", %{
        "issue" => "MT-HTTP",
        "provider" => "cv2",
        "model" => "opus",
        "effort" => ""
      })

      assert_receive {:orchestrator_call, {:set_issue_run_spec, "issue-http", %{provider: "cv2", model: "opus"} = overrides}},
                     1_000

      refute Map.has_key?(overrides, :effort)
    end

    test "toggle_queue_edit reveals the pin form; set_queue_run_spec does not kill" do
      orchestrator_name = Module.concat(__MODULE__, :QueuePinOrchestrator)

      snapshot =
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "First waiting"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Second waiting", priority: 4})
        ])

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: snapshot,
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "LLM-51"
      assert html =~ "First waiting"
      refute has_element?(view, "form.queue-edit-form")

      view
      |> element(~s|button.queue-card-edit-toggle[phx-value-issue="LLM-51"]|)
      |> render_click()

      assert has_element?(view, "form.queue-edit-form")
      assert has_element?(view, "article.project-section.is-queue-edit-open")
      assert has_element?(view, "article.queue-card.is-editing")
      assert has_element?(view, "#queue-agent-LLM-51")
      assert has_element?(view, "#queue-model-LLM-51")
      assert has_element?(view, "#queue-effort-LLM-51")
      refute has_element?(view, ~s|form.queue-edit-form input[name="provider"]|)

      # The sheet is fixed to the viewport and can be flipped above its card, so
      # it names the issue it pins instead of relying on the card behind it.
      pin_form = view |> element("form.queue-edit-form") |> render()
      assert pin_form =~ "Pin next run"
      assert pin_form =~ ~s(<span class="mono">LLM-51</span>)

      render_submit(view, "set_queue_run_spec", %{
        "project" => "default",
        "issue" => "LLM-51",
        "agent_kind" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high"
      })

      refute_received {:orchestrator_call, {:kill_issue, _}}
      refute_received {:orchestrator_call, {:set_issue_run_spec, _, _}}
      assert_queue_orchestrator_call(:set_queue_pin)
    end

    test "reorder_queue notifies the orchestrator and does not kill" do
      orchestrator_name = Module.concat(__MODULE__, :QueueReorderOrchestrator)

      snapshot =
        static_snapshot()
        |> Map.put(:waiting, [
          waiting_snapshot_entry(%{identifier: "LLM-51", title: "First waiting"}),
          waiting_snapshot_entry(%{identifier: "LLM-12", title: "Second waiting", priority: 4})
        ])

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: snapshot,
          recipient: self(),
          reorder_snapshot?: true
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")
      assert queue_card_order(view) == ["LLM-51", "LLM-12"]

      render_click(view, "reorder_queue", %{
        "project" => "default",
        "order" => ["LLM-12", "LLM-51"]
      })

      refute_received {:orchestrator_call, {:kill_issue, _}}
      assert_queue_orchestrator_call(:reorder_queue)

      config_dir = Application.fetch_env!(:cymphony_elixir, :config_dir_override)
      config = config_dir |> Path.join("config.json") |> File.read!() |> Jason.decode!()
      assert get_in(config, ["projects", Access.at(0), "queue_order"]) == ["LLM-12", "LLM-51"]

      assert_eventually(fn -> queue_card_order(view) == ["LLM-12", "LLM-51"] end)

      rendered = render(view)
      seq_before = :sys.get_state(view.pid).socket.assigns.payload_seq
      send(view.pid, :reload_payload_now)

      assert_eventually(fn ->
        state = :sys.get_state(view.pid)

        state.socket.assigns.payload_seq > seq_before and
          state.socket.assigns.payload_job == nil and
          queue_card_order(view) == ["LLM-12", "LLM-51"]
      end)

      assert render(view) == rendered
    end

    test "settings drawer renders orchestrator controls and display pref hooks" do
      orchestrator_name = Module.concat(__MODULE__, :DrawerOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/")

      # Drawer shell + toggle in the top bar.
      assert html =~ ~s(class="settings-drawer")
      assert html =~ "data-drawer-toggle"

      # Simple is the approachable default; Advanced preserves expert controls.
      # The rail foot owns the switch at wide widths, the top strip keeps a
      # narrow-only duplicate, and the console keeps its own copy.
      assert has_element?(view, ~s|nav.side-rail #mode-switch-rail.mode-switch|)
      assert has_element?(view, "#mode-switch-top.mode-switch.topbar-only-narrow")
      assert has_element?(view, ".settings-drawer .mode-switch.settings-mode-switch")
      assert html =~ ~s(data-mode-set="simple")
      assert html =~ ~s(data-mode-set="advanced")
      assert html =~ ~s(aria-label="Dashboard mode")
      assert html =~ "Automatic work is on"
      assert html =~ "simple-only"
      assert html =~ "advanced-only"
      assert html =~ ~s(phx-click="pause_dispatch")
      assert html =~ ~s(phx-click="kill_issue")
      assert html =~ ~s(phx-click="retry_issue")
      assert has_element?(view, ~s|form[phx-submit="set_project_concurrency"] button[type="submit"]|, "Save")
      assert has_element?(view, ~s|form[phx-submit="set_project_providers"] button[type="submit"]|, "Save")

      # Orchestrator controls moved into the drawer.
      assert html =~ ~s(id="drawer-global-concurrency")
      assert html =~ ~s(phx-click="pause_dispatch")

      # Display pref hooks the layout JS binds to.
      for hook <- [
            ~s(data-pref="density"),
            "data-pref-section",
            "data-pref-col",
            ~s(data-pref="completions-limit")
          ] do
        assert html =~ hook
      end

      # Metrics strip absorbed the ops row: section markers present, old row gone.
      assert html =~ "section--metrics"
      assert html =~ "section--polling"
      assert html =~ ~s(data-pref-section="board")
      refute html =~ "command-bar-row--ops"
    end

    test "simple mode reports partial autonomy across mixed project pause states" do
      suffix = System.unique_integer([:positive])
      active_name = "active-#{suffix}"
      paused_name = "paused-#{suffix}"
      active_orchestrator = Module.concat(__MODULE__, :MixedActiveOrchestrator)
      paused_orchestrator = Module.concat(__MODULE__, :MixedPausedOrchestrator)

      {:ok, _active_pid} =
        StaticOrchestrator.start_link(
          name: active_orchestrator,
          project_name: active_name,
          snapshot: empty_snapshot(false)
        )

      {:ok, _paused_pid} =
        StaticOrchestrator.start_link(
          name: paused_orchestrator,
          project_name: paused_name,
          snapshot: empty_snapshot(true)
        )

      start_test_endpoint(orchestrator: active_orchestrator, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Automatic work is on for 1 of 2 projects"
      assert html =~ "Some projects are paused. Active projects will keep picking up ready issues."
      assert html =~ "1 / 2 active"
      refute html =~ "Automatic work is paused"
    end

    test "simple mode gives a truthful empty state for a paused project" do
      orchestrator_name = Module.concat(__MODULE__, :PausedEmptyOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: empty_snapshot(true)
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Automatic work is paused"
      assert html =~ "This project is paused. Resume it when you want Cymphony to start ready issues again."
      refute html =~ "will start the next ready issue automatically"
    end

    test "root layout carries the prefs bootstrap and wiring scripts" do
      orchestrator_name = Module.concat(__MODULE__, :PrefsLayoutOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      html = html_response(get(build_conn(), "/"), 200)

      assert html =~ "Checking automatic work…"
      refute html =~ "Automatic work is on"
      assert html =~ "status-badge-transport"
      assert html =~ "Connecting"
      assert html =~ "cymphony-prefs"
      assert html =~ "data-ui-mode"
      assert html =~ "prefs.uiMode"
      assert html =~ "applyMode"
      assert html =~ "expandedSections"
      assert html =~ "legacyExpandedCompletions"
      assert html =~ "sectionIsCollapsed"
      assert html =~ "data-hidden-sections"
      assert html =~ "data-collapse-toggle"
      assert html =~ "syncPrefControls"
      assert html =~ "LiveClock"
      assert html =~ "[data-clock]"

      # Client-side clock formatting must stay byte-identical to the Elixir
      # formatters in dashboard_live.ex; changing either side must break here.
      # Elapsed rolls into hours past 60 minutes on both sides.
      assert html =~ ~s|if (hours > 0) return hours + 'h ' + mins + 'm ' + secs + 's';|
      assert html =~ ~s|return mins + 'm ' + secs + 's';|
      assert html =~ ~s|return seconds + 's';|
      assert html =~ ~s|if (!(seconds > 0)) seconds = 0;|
      assert html =~ ~s|if (!(ms > 0)) return 'now';|

      # Every LiveView patch morphs the clock container and rewrites the spans
      # back to the text of the last payload load, so the hook has to repaint on
      # `updated` as well as on its own interval or the clocks rewind per patch.
      [_before, live_clock] = String.split(html, "LiveClock: {", parts: 2)
      [live_clock, combobox] = String.split(live_clock, "Combobox: {", parts: 2)
      assert live_clock =~ "updated() {"
      assert live_clock =~ "this.tick();"

      # A patch re-applies the panel's server-rendered `hidden`, strips
      # `combobox--open`, rewrites the search value and the option flags, and
      # blurs the search box by hiding its ancestor. The hook has to snapshot
      # that state before the morph and put it back after, or an open dropdown
      # vanishes mid-selection with the typed filter gone.
      [combobox, spec_switcher] = String.split(combobox, "SpecSwitcher: {", parts: 2)
      assert combobox =~ "beforeUpdate() {"
      assert combobox =~ "this.setOpen(true);"
      assert combobox =~ "this.filter(r.query);"
      assert combobox =~ "this.search.setSelectionRange("
      # The old `updated()` inferred "still open" from document.activeElement —
      # already false by then — and fell through to close(), which clears the
      # typed filter.
      refute combobox =~ "else this.close();"

      [spec_switcher, _rest] = String.split(spec_switcher, "QueueBoard: {", parts: 2)
      assert spec_switcher =~ "beforeUpdate() {"
      assert spec_switcher =~ "this.setOpen(true);"
      assert spec_switcher =~ "this.setSubmenu(r.submenu);"
      assert spec_switcher =~ "this.filter(r.query);"
      assert spec_switcher =~ "if (this.hasEffortMenu()) {"
      assert spec_switcher =~ "this._openAfterPatch = 'effort';"
      assert spec_switcher =~ "this.setSubmenu('effort');"
      assert spec_switcher =~ "submenu: this._openAfterPatch || this.submenu,"
      assert spec_switcher =~ "if (this._closeAfterPatch) {"
      assert spec_switcher =~ "this._closeAfterPatch = true;"
      assert spec_switcher =~ "if (value === 'antigravity') {"
      refute spec_switcher =~ "Reset to default"

      dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
      assert dashboard_css =~ ~s(html[data-ui-mode="simple"] .advanced-only)
      assert dashboard_css =~ ~s(.mode-switch-button[data-mode-set="simple"])

      assert dashboard_css =~
               ~s|html[data-ui-mode="simple"]:not([data-expanded-sections~="completions"]) .section--completions .session-row-list|

      # The collapse chevron rotates off the same `<html>` pref attributes that
      # hide the section body, never off the button's server-rendered
      # `aria-expanded`: that attribute lives inside the LiveView container, so
      # morphdom resets it to the template value ("false") on every patch and the
      # chevron would point right at an expanded Completions section until the
      # next `syncPrefControls()` run. `<html>` is outside the patched container.
      assert dashboard_css =~
               ~s|html[data-ui-mode="simple"]:not([data-expanded-sections~="completions"]) [data-collapse-toggle="completions"]::before|

      assert dashboard_css =~
               ~s|html[data-collapsed-sections~="completions"] [data-collapse-toggle="completions"]::before|

      refute dashboard_css =~ ~s|[data-collapse-toggle][aria-expanded="false"]::before|

      # `aria-expanded` is still written for screen readers, and the observer now
      # watches it so a patch-reset name is repaired; the guarded writes keep that
      # from re-triggering the sync from its own mutation.
      assert html =~ ~s|attributeFilter: ['aria-pressed', 'aria-expanded']|
      assert html =~ ~s|if (el.getAttribute('aria-expanded') !== expanded) el.setAttribute('aria-expanded', expanded);|

      assert dashboard_css =~ ".project-section > .project-section-header"
      assert dashboard_css =~ ".project-section.is-combobox-open"
      assert dashboard_css =~ ".combobox.combobox--open"
      assert dashboard_css =~ ".spec-switcher-trigger"
      assert dashboard_css =~ ".spec-switcher-panel"
      assert dashboard_css =~ ".spec-switcher-flyout"
      assert dashboard_css =~ "--z-combobox: 80"
      assert dashboard_css =~ "z-index: var(--z-combobox)"

      # v3 shell: rail + main column, the instrument band, and the toast stack
      # that keeps a flash out of the document flow.
      assert dashboard_css =~ ".dashboard-shell {"
      assert dashboard_css =~ ".side-rail {"
      assert dashboard_css =~ ".instrument-band {"
      assert dashboard_css =~ ".toast-stack {"

      # Band cells grow: with rate limits present the band wraps at 1600px, and
      # without growth the second row was a left-packed stub under a full row —
      # ~60% empty panel, with the 160px accent rule underlining one cell like a
      # tab indicator. The ops cell drops its max-width for the same reason and
      # must reset the base cell's `center` (that centering is vertical on the
      # column axis; `--ops` flips the main axis to a row, where it centered
      # every wrapped detail line off the label's left edge).
      assert dashboard_css =~ "  flex: 1 0 auto;\n  min-width: 96px;"
      refute dashboard_css =~ "max-width: 360px;"

      assert dashboard_css =~ """
             .metric-pill--ops {
               display: flex;
               flex-flow: row wrap;
               align-items: baseline;
               align-content: center;
               justify-content: flex-start;
             """

      # `.chip` is inline-flex and `text-overflow` never applies to a flex
      # container, so the cap alone clipped "gemini-3.7-flash-high" to a
      # plausible-looking "gemini-3.7-flash-" with no ellipsis.
      assert dashboard_css =~ """
             .chip--truncate {
               display: inline-block;
               max-width: 120px;
             """

      # Basis 0, not auto: with an auto basis the title's own text is the basis,
      # so shrink landed proportionally on the tag cluster and a row carrying a
      # worker host orphaned one tag onto a second line while it still had room.
      assert dashboard_css =~ """
             .session-row-title {
               flex: 1 1 0;
               min-width: 200px;
             """

      # "Follow the OS" is a monitor (hairline screen + stand), not the old
      # arrow polygon, which read as upload/eject beside a sun and a moon.
      assert dashboard_css =~ ~s|.theme-toggle-button[data-theme-set="system"]::after|
      refute dashboard_css =~ "clip-path: polygon(50% 0, 100% 38%"

      # Light theme ships two ways: an explicit choice and — new in v3 — the OS
      # preference when no choice was made. The `:not([data-theme])` guard keeps
      # an explicit dark choice winning on a light OS.
      assert dashboard_css =~ ~s|:root[data-theme="light"] {|
      assert dashboard_css =~ "@media (prefers-color-scheme: light) {"
      assert dashboard_css =~ ":root:not([data-theme]) {"

      # The rail is furniture, not a floating panel: it has its own surface token
      # so light can sit it *below* the page while dark keeps --surface. Both
      # light blocks (attribute + media duplicate) must carry the value.
      assert dashboard_css =~ "background: var(--rail-surface);"
      assert length(String.split(dashboard_css, "--rail-surface: #efefec;")) == 3

      # The console scrim is a real element box (`body::after`), so it actually
      # intercepts clicks; a box-shadow scrim would let them through.
      assert dashboard_css =~ ~s|html[data-drawer="open"] body::after|
      assert dashboard_css =~ "z-index: var(--z-scrim)"

      # Esc closes the console; the listener is delegated, not a hook, because
      # the open flag is an attribute on <html> outside the LiveView container.
      # It yields to an inner overlay that already consumed the key — the
      # Combobox's own Escape handler calls preventDefault(), and without this
      # guard one Escape dismissed both the dropdown and the whole console.
      assert html =~ "if (e.key === 'Escape' &&"
      assert html =~ ~s|document.documentElement.getAttribute('data-drawer') === 'open'|
      assert html =~ "if (e.defaultPrevented) return;"

      # The rail's scroll-spy is additive: every anchor works without it.
      assert html =~ "RailNav: {"
      assert html =~ ~s|link.setAttribute('aria-current', 'true')|

      # The narrow-viewport jump menu is a native <details>; its `open` attribute
      # is browser-owned and the server never renders it, so morphdom strips it
      # on every patch. JumpMenu snapshots it before the morph and restores it.
      assert html =~ "JumpMenu: {"
      assert html =~ "this._open = this.el.open;"
      assert html =~ "if (this._open && !this.el.open) this.el.open = true;"

      # The queue-card edit sheet is a popover, not an inline block: the hook
      # pins it to the viewport off the card's rect (and flips it above the card
      # when it would overflow the bottom), so it cannot be clipped by the
      # board's own scroll box. It re-places on `updated` because a patch resets
      # the inline styles morphdom does not own.
      assert html =~ "QueueEditPanel: {"
      assert html =~ "var card = this.el.closest('.queue-card');"
      assert html =~ "this.el.style.position = 'fixed';"
      assert html =~ "updated() { this.place(); },"

      # Its outside-click dismiss must exempt the toggle that opened it (else the
      # click that closes one sheet also swallows the open of the next) and the
      # Combobox panels, which render outside the sheet's own subtree.
      assert html =~ "if (t.closest('.queue-card-edit-toggle')) return;"
      assert html =~ "if (t.closest('.combobox-list') || t.closest('.combobox-panel')) return;"
      assert html =~ "if (t.closest('.spec-switcher')) return;"

      # Rail content + Part B surfaces.
      assert dashboard_css =~ ".rail-vitals {"
      assert dashboard_css =~ ".rail-led--paused {"
      assert dashboard_css =~ ".rail-foot {"
      assert dashboard_css =~ ".fleet-empty {"
      assert dashboard_css =~ ".jump-menu-panel {"
      assert dashboard_css =~ ".topbar-only-narrow { display: none; }"

      # The layout script still rewrites this button's textContent to a glyph, so
      # the glyph is hidden and the chevron is CSS geometry. Its rotation is
      # asserted above, off `<html>` rather than off `aria-expanded`.
      assert dashboard_css =~ "[data-collapse-toggle] {"

      # Custom-property NAMES the QueueBoard hook resolves at runtime through
      # getComputedStyle. Values are free to change; a rename breaks drag.
      for token <- [
            "--dur-flip:",
            "--dur-mid:",
            "--dur-fast:",
            "--ease:",
            "--ease-spring:",
            "--z-drag:",
            "--shadow-drag:",
            "--accent-soft:"
          ] do
        assert dashboard_css =~ token
      end
    end

    test "pause_dispatch sends :pause to the orchestrator" do
      isolate_config_dir!()
      orchestrator_name = Module.concat(__MODULE__, :PauseLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view |> element(~s|button[phx-click="pause_dispatch"]|) |> render_click()
      assert_receive {:orchestrator_call, :pause}, 1_000
    end

    test "set_project_concurrency event sends :set_concurrency with parsed integer to orchestrator" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-concurrency-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{\"projects\": []}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :ConcurrencyLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> form(~s|form[phx-submit="set_project_concurrency"]|, %{value: "5"})
      |> render_submit()

      assert_receive {:orchestrator_call, {:set_concurrency, 5}}, 1_000
    end

    test "set_project_agent event sends :set_agent_settings to orchestrator and persists" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-agent-live-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{\"projects\": [{\"name\": \"default\"}]}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      # Stub the codex catalog so rendering codex model suggestions never
      # shells out to a possibly-missing `codex` binary (e.g. on CI).
      previous_fetcher = Application.fetch_env(:cymphony_elixir, :codex_catalog_fetcher)
      Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> {:ok, ~s({"models": []})} end)
      CymphonyElixir.AgentCatalog.clear_cache()

      on_exit(fn ->
        case previous_fetcher do
          {:ok, fetcher} -> Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fetcher)
          :error -> Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
        end

        CymphonyElixir.AgentCatalog.clear_cache()
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :AgentLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/")

      # Header controls render with the providers input relabeled.
      assert html =~ ~s(name="agent_kind")
      assert html =~ ~s(id="agent-default")
      refute html =~ ~s(id="agent-default-claude")
      assert html =~ "model-suggestions-"
      assert html =~ ">providers</label>"
      refute html =~ "claude command"

      render_submit(view, "set_project_agent", %{
        "project" => "default",
        "agent_kind" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high"
      })

      assert_receive {:orchestrator_call, {:set_agent_settings, %{"agent" => "codex", "model" => "gpt-5.2-codex", "effort" => "high"}}},
                     1_000

      # The immediate re-render must already show the submitted kind, not the
      # previous one (confirmed-draft until the payload catches up).
      assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="agent_kind"][value="codex"]|)

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      [project | _] = persisted["projects"]
      assert project["agent"] == "codex"
      assert project["model"] == "gpt-5.2-codex"
      assert project["effort"] == "high"
    end

    test "agent picker previews model and effort choices for the selected agent" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-agent-preview-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{\"projects\": [{\"name\": \"default\"}]}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      previous_fetcher = Application.fetch_env(:cymphony_elixir, :codex_catalog_fetcher)

      catalog =
        Jason.encode!(%{
          "models" => [
            %{
              "slug" => "gpt-5.6-terra",
              "description" => "Test Codex model",
              "visibility" => "list",
              "priority" => 1,
              "supported_reasoning_levels" => [
                %{"effort" => "minimal"},
                %{"effort" => "high"}
              ]
            }
          ]
        })

      Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> {:ok, catalog} end)
      CymphonyElixir.AgentCatalog.clear_cache()

      on_exit(fn ->
        case previous_fetcher do
          {:ok, fetcher} -> Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fetcher)
          :error -> Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
        end

        CymphonyElixir.AgentCatalog.clear_cache()
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :AgentPreviewOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot:
            static_snapshot()
            |> Map.put(:agent_kind, "claude")
            |> Map.put(:agent_model, "sonnet")
            |> Map.put(:agent_effort, "max")
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, html} = live(build_conn(), "/")

      assert html =~ ~s(phx-change="preview_project_agent")

      render_change(view, "preview_project_agent", %{
        "project" => "default",
        "agent_kind" => "codex",
        "model" => "sonnet",
        "effort" => "max"
      })

      codex_form = view |> element(~s|form[phx-submit="set_project_agent"]|) |> render()
      assert codex_form =~ ~s(value="gpt-5.6-terra")
      assert codex_form =~ ~s(value="minimal")
      assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="model"][value=""]|)
      refute codex_form =~ ~s(value="sonnet")
      refute codex_form =~ ~s(value="max")

      render_change(view, "preview_project_agent", %{
        "project" => "default",
        "agent_kind" => "codex",
        "model" => "gpt-5.6-terra",
        "effort" => "minimal"
      })

      assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="model"][value="gpt-5.6-terra"]|)
      assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="effort"][value="minimal"]|)

      render_change(view, "preview_project_agent", %{
        "project" => "default",
        "agent_kind" => "claude",
        "model" => "gpt-5.6-terra",
        "effort" => "minimal"
      })

      claude_form = view |> element(~s|form[phx-submit="set_project_agent"]|) |> render()
      assert claude_form =~ ~s(value="sonnet")
      assert claude_form =~ ~s(value="max")
      assert has_element?(view, ~s|form[phx-submit="set_project_agent"] input[name="model"][value=""]|)
      refute claude_form =~ ~s(value="gpt-5.6-terra")
      refute claude_form =~ ~s(value="minimal")
    end

    test "set_project_providers event sends :set_providers list to orchestrator" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-providers-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{\"projects\": [{\"name\": \"default\"}]}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :ProvidersLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view
      |> form(~s|form[phx-submit="set_project_providers"]|, %{value: "cv1, cz2 ,ck1"})
      |> render_submit()

      assert_receive {:orchestrator_call, {:set_providers, ["cv1", "cz2", "ck1"]}}, 1_000

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      [project | _] = persisted["projects"]
      assert project["provider"] == "cv1"
      assert project["providers"] == ["cv1", "cz2", "ck1"]
    end

    test "POST /api/v1/providers calls orchestrator and persists value" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-providers-api-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :ProvidersApiOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = post(build_conn(), "/api/v1/providers", %{"value" => "cv1,cz2"})
      assert %{status: 202, resp_body: body} = conn
      assert body =~ ~s("providers":["cv1","cz2"])

      assert_receive {:orchestrator_call, {:set_providers, ["cv1", "cz2"]}}, 1_000

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      [project | _] = persisted["projects"]
      assert project["provider"] == "cv1"
      assert project["providers"] == ["cv1", "cz2"]
    end

    test "POST /api/v1/agent updates settings, persists, and validates kind" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-agent-api-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :AgentApiOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = post(build_conn(), "/api/v1/agent", %{"kind" => "codex", "effort" => "high"})
      assert %{status: 202} = conn
      assert %{"agent" => "codex", "effort" => "high"} = Jason.decode!(conn.resp_body)

      assert_receive {:orchestrator_call, {:set_agent_settings, %{"agent" => "codex", "effort" => "high"}}},
                     1_000

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      [project | _] = persisted["projects"]
      assert project["agent"] == "codex"
      assert project["effort"] == "high"

      conn = post(build_conn(), "/api/v1/agent", %{"kind" => "antigravity"})
      assert %{status: 202} = conn
      assert %{"agent" => "antigravity"} = Jason.decode!(conn.resp_body)

      assert_receive {:orchestrator_call, {:set_agent_settings, %{"agent" => "antigravity"}}}, 1_000

      assert json_response(post(build_conn(), "/api/v1/agent", %{"kind" => "gemini"}), 422) ==
               %{
                 "error" => %{
                   "code" => "invalid_agent_settings",
                   "message" => "body must include at least one of kind/model/effort; kind must be one of: claude, codex, antigravity"
                 }
               }
    end

    test "GET /api/v1/:issue_identifier/harness returns last_seq/lines for a running issue" do
      orchestrator_name = Module.concat(__MODULE__, :HarnessApiOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
      ensure_harness_stream_started()

      payload = json_response(get(build_conn(), "/api/v1/MT-HTTP/harness"), 200)
      assert Map.has_key?(payload, "last_seq")
      assert Map.has_key?(payload, "lines")
      assert payload["issue_identifier"] == "MT-HTTP"

      assert json_response(get(build_conn(), "/api/v1/MT-MISSING/harness"), 404) ==
               %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}

      assert json_response(get(build_conn(), "/api/v1/MT-RETRY/harness"), 404) ==
               %{"error" => %{"code" => "issue_not_found", "message" => "Issue not found"}}
    end

    test "POST /api/v1/providers rejects empty value with 422" do
      orchestrator_name = Module.concat(__MODULE__, :ProvidersApiInvalidOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert json_response(post(build_conn(), "/api/v1/providers", %{"value" => "  ,, "}), 422) ==
               %{
                 "error" => %{
                   "code" => "invalid_providers",
                   "message" => "providers 'value' must be a non-empty comma-separated list"
                 }
               }
    end

    test "POST /api/v1/concurrency calls orchestrator and persists value" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-concurrency-api-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), "{}")
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :ConcurrencyApiOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = post(build_conn(), "/api/v1/concurrency", %{"value" => 4})
      assert %{status: 202, resp_body: body} = conn
      assert body =~ ~s("max_concurrent_agents":4)

      assert_receive {:orchestrator_call, {:set_concurrency, 4}}, 1_000

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      [project | _] = persisted["projects"]
      assert project["max_concurrent_agents"] == 4
    end

    test "POST /api/v1/refresh-interval persists dashboard_refresh_seconds" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-refresh-api-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), ~s({"projects":[{"name":"default"}]}))
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :RefreshIntervalApiOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = post(build_conn(), "/api/v1/refresh-interval", %{"value" => 8})
      assert %{status: 202} = conn
      assert Jason.decode!(conn.resp_body) == %{"dashboard_refresh_seconds" => 8}

      refute_receive {:orchestrator_call, _}, 100

      {:ok, persisted} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
      assert persisted["dashboard_refresh_seconds"] == 8
      assert persisted["projects"] == [%{"name" => "default"}]
      refute Enum.any?(persisted["projects"], &Map.has_key?(&1, "dashboard_refresh_seconds"))
      refute Map.has_key?(persisted, "polling_interval_ms")
    end

    test "POST /api/v1/refresh-interval rejects invalid values with 422" do
      orchestrator_name = Module.concat(__MODULE__, :RefreshIntervalInvalidOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert json_response(post(build_conn(), "/api/v1/refresh-interval", %{"value" => 0}), 422) ==
               %{
                 "error" => %{
                   "code" => "invalid_refresh_interval",
                   "message" => "refresh interval 'value' must be a positive integer"
                 }
               }

      assert json_response(post(build_conn(), "/api/v1/refresh-interval", %{"value" => "nope"}), 422) ==
               %{
                 "error" => %{
                   "code" => "invalid_refresh_interval",
                   "message" => "refresh interval 'value' must be a positive integer"
                 }
               }
    end

    test "POST /api/v1/refresh-interval reports a persist failure instead of claiming success" do
      tmp = Path.join(System.tmp_dir!(), "cymphony-refresh-api-fail-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf!(tmp)
      end)

      orchestrator_name = Module.concat(__MODULE__, :RefreshIntervalPersistFailOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      # No `config.json` to read-modify-write. An interval that was not written
      # reverts on the next restart, so 202 was a lie — `/api/v1/pause` already
      # answers `dispatch_pause_not_persisted` in the same situation.
      assert %{"error" => %{"code" => "refresh_interval_not_persisted", "message" => message}} =
               json_response(post(build_conn(), "/api/v1/refresh-interval", %{"value" => 8}), 422)

      assert is_binary(message)
    end

    test "GET /api/v1/refresh-interval is 405 not issue_not_found" do
      orchestrator_name = Module.concat(__MODULE__, :RefreshIntervalMethodOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert json_response(get(build_conn(), "/api/v1/refresh-interval"), 405) ==
               %{
                 "error" => %{
                   "code" => "method_not_allowed",
                   "message" => "Method not allowed"
                 }
               }
    end

    test "presenter surfaces issue title, url, and priority from entry.issue" do
      orchestrator_name = Module.concat(__MODULE__, :IssueDataOrchestrator)

      snapshot =
        put_in(static_snapshot(), [:running], [
          %{
            issue_id: "issue-http",
            identifier: "MT-HTTP",
            issue: %CymphonyElixir.Linear.Issue{
              id: "issue-http",
              identifier: "MT-HTTP",
              title: "Implement feature",
              url: "https://linear.app/test/issue/MT-HTTP",
              priority: 2
            },
            state: "In Progress",
            session_id: "thread-http",
            turn_count: 3,
            agent_os_pid: nil,
            last_agent_message: nil,
            last_agent_timestamp: nil,
            last_agent_event: nil,
            input_tokens: 1,
            output_tokens: 2,
            total_tokens: 3,
            started_at: DateTime.utc_now()
          }
        ])

      {:ok, _pid} = StaticOrchestrator.start_link(name: orchestrator_name, snapshot: snapshot)

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      payload = json_response(get(build_conn(), "/api/v1/state"), 200)
      [running | _] = payload["running"]

      assert running["issue_title"] == "Implement feature"
      assert running["issue_url"] == "https://linear.app/test/issue/MT-HTTP"
      assert running["priority"] == 2
      assert running["turn_count"] == 3
    end

    test "toggle_project_pause pauses and persists through Control, not the orchestrator directly" do
      tmp = isolate_config_dir!(~s({"projects": [{"name": "default"}]}))
      orchestrator_name = Module.concat(__MODULE__, :TogglePauseLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view |> element(~s|button[phx-click="toggle_project_pause"][phx-value-project="default"]|) |> render_click()

      assert_receive {:orchestrator_call, :pause}, 1_000
      assert stored_dispatch_paused(tmp) == [true]
    end

    test "toggle_project_pause resumes an already-paused project" do
      tmp = isolate_config_dir!(~s({"projects": [{"name": "default", "dispatch_paused": true}]}))
      orchestrator_name = Module.concat(__MODULE__, :ToggleResumeLiveOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: put_in(static_snapshot(), [:polling, :paused], true),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view |> element(~s|button[phx-click="toggle_project_pause"][phx-value-project="default"]|) |> render_click()

      assert_receive {:orchestrator_call, :resume}, 1_000
      assert stored_dispatch_paused(tmp) == [false]
    end

    test "toggle_project_pause flashes when the pause state cannot be persisted" do
      # An unparseable config store, not a missing one: with no config store at
      # all there is no durable pause to lose, and pause/resume report success.
      tmp = isolate_config_dir!()
      File.write!(Path.join(tmp, "config.json"), "{not json")
      orchestrator_name = Module.concat(__MODULE__, :TogglePauseErrorOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      html =
        view |> element(~s|button[phx-click="toggle_project_pause"][phx-value-project="default"]|) |> render_click()

      assert html =~ "Pause state for default applied, but could not be saved"
      # The orchestrator half did happen, so the board still reloads.
      assert_receive {:orchestrator_call, :pause}, 1_000
    end

    test "pause_dispatch flashes an error when the pause cannot be persisted" do
      tmp = isolate_config_dir!()
      File.write!(Path.join(tmp, "config.json"), "{not json")
      orchestrator_name = Module.concat(__MODULE__, :PauseAllErrorOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: static_snapshot(),
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      html = view |> element(~s|button[phx-click="pause_dispatch"]|) |> render_click()

      assert html =~ "could not be saved to ~/.cymphony/config.json"
      assert_receive {:orchestrator_call, :pause}, 1_000
    end

    test "resume_dispatch sends :resume to the orchestrator" do
      isolate_config_dir!()
      orchestrator_name = Module.concat(__MODULE__, :ResumeLiveOrchestrator)

      paused_snapshot = put_in(static_snapshot(), [:polling, :paused], true)

      {:ok, _pid} =
        StaticOrchestrator.start_link(
          name: orchestrator_name,
          snapshot: paused_snapshot,
          recipient: self()
        )

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      {:ok, view, _html} = live(build_conn(), "/")

      view |> element(~s|button[phx-click="resume_dispatch"]|) |> render_click()
      assert_receive {:orchestrator_call, :resume}, 1_000
    end
  end

  describe "api auth (CYMPHONY_API_TOKEN)" do
    setup do
      original = System.get_env("CYMPHONY_API_TOKEN")

      on_exit(fn ->
        if is_nil(original) do
          System.delete_env("CYMPHONY_API_TOKEN")
        else
          System.put_env("CYMPHONY_API_TOKEN", original)
        end
      end)

      :ok
    end

    test "without env var, all routes are public (passthrough)" do
      System.delete_env("CYMPHONY_API_TOKEN")

      orchestrator_name = Module.concat(__MODULE__, :AuthPassthroughOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert %{status: 200} = get(build_conn(), "/api/v1/state")
    end

    test "with env var set, missing token gets 401 on api and dashboard" do
      System.put_env("CYMPHONY_API_TOKEN", "secret123")

      orchestrator_name = Module.concat(__MODULE__, :AuthGatedOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      assert %{status: 401} = get(build_conn(), "/api/v1/state")
      assert %{status: 401} = get(build_conn(), "/")
    end

    test "with env var set, wrong token gets 401" do
      System.put_env("CYMPHONY_API_TOKEN", "secret123")

      orchestrator_name = Module.concat(__MODULE__, :AuthWrongOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer wrong")
      assert %{status: 401} = get(conn, "/api/v1/state")
    end

    test "with env var set, correct Bearer token allows access" do
      System.put_env("CYMPHONY_API_TOKEN", "secret123")

      orchestrator_name = Module.concat(__MODULE__, :AuthOkOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = build_conn() |> Plug.Conn.put_req_header("authorization", "Bearer secret123")
      assert %{status: 200} = get(conn, "/api/v1/state")
    end

    test "with env var set, ?token=<correct> redirects and sets session for browser" do
      System.put_env("CYMPHONY_API_TOKEN", "secret123")

      orchestrator_name = Module.concat(__MODULE__, :AuthQueryOrchestrator)

      {:ok, _pid} =
        StaticOrchestrator.start_link(name: orchestrator_name, snapshot: static_snapshot())

      start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

      conn = get(build_conn(), "/?token=secret123")
      assert conn.status == 302
    end
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "running" => 1,
             "retrying" => 1,
             "waiting" => 0,
             "completed" => 0,
             "by_state" => %{"In Progress" => 1},
             "by_kind" => %{"unknown" => 1}
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
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

  defp start_test_endpoint(overrides) do
    isolate_linear_env()

    endpoint_config =
      :cymphony_elixir
      |> Application.get_env(CymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({CymphonyElixirWeb.Endpoint, []})
  end

  defp stored_dispatch_paused(tmp) do
    {:ok, cfg} = Jason.decode(File.read!(Path.join(tmp, "config.json")))
    Enum.map(cfg["projects"], &Map.get(&1, "dispatch_paused"))
  end

  # pause/resume persist `dispatch_paused`; anything exercising them needs a
  # throwaway config dir or it rewrites the developer's ~/.cymphony/config.json.
  defp isolate_config_dir!(json \\ ~s({"projects": [{"name": "alpha"}]})) do
    tmp = Path.join(System.tmp_dir!(), "cymphony-ext-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "config.json"), json)
    previous = Application.get_env(:cymphony_elixir, :config_dir_override)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      if is_binary(previous) do
        Application.put_env(:cymphony_elixir, :config_dir_override, previous)
      else
        Application.delete_env(:cymphony_elixir, :config_dir_override)
      end

      File.rm_rf!(tmp)
    end)

    tmp
  end

  defp isolate_linear_env do
    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    previous_opts = Application.get_env(:cymphony_elixir, :linear_graphql_opts)
    Application.delete_env(:cymphony_elixir, :linear_graphql_opts)

    unless is_binary(Application.get_env(:cymphony_elixir, :config_dir_override)) do
      tmp = Path.join(System.tmp_dir!(), "cymphony-ext-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "config.json"), ~s({"projects":[{"name":"default"}]}))
      Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

      on_exit(fn ->
        Application.delete_env(:cymphony_elixir, :config_dir_override)
        File.rm_rf(tmp)
      end)
    end

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_key)

      if is_nil(previous_opts) do
        Application.delete_env(:cymphony_elixir, :linear_graphql_opts)
      else
        Application.put_env(:cymphony_elixir, :linear_graphql_opts, previous_opts)
      end
    end)
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

  defp empty_snapshot(paused) do
    static_snapshot()
    |> Map.put(:running, [])
    |> Map.put(:retrying, [])
    |> put_in([:polling, :paused], paused)
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

  defp assert_queue_orchestrator_call(expected) do
    receive do
      {:orchestrator_call, {:kill_issue, _}} ->
        flunk("kill_issue sent for queue event")

      {:orchestrator_call, {:reorder_queue, _order}} ->
        assert expected == :reorder_queue

      {:orchestrator_call, {:set_queue_order, _order}} ->
        assert expected == :reorder_queue

      {:orchestrator_call, {:set_queue_pin, _issue, _pin}} ->
        assert expected == :set_queue_pin

      {:orchestrator_call, other} ->
        flunk("unexpected orchestrator call: #{inspect(other)}")
    after
      1_000 ->
        if queue_control_exported?(expected) do
          :ok
        else
          flunk("did not receive #{expected} orchestrator call")
        end
    end
  end

  defp queue_card_order(view) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("#queue-board-default > article.queue-card")
    |> Enum.map(fn card -> card |> Floki.attribute("data-issue") |> List.first() end)
  end

  defp queue_control_exported?(:reorder_queue),
    do: function_exported?(CymphonyElixirWeb.Control, :set_queue_order, 2)

  defp queue_control_exported?(:set_queue_pin),
    do: function_exported?(CymphonyElixirWeb.Control, :set_queue_pin, 3)

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
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

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case WorkflowStore.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
