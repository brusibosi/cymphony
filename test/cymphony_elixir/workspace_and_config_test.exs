defmodule CymphonyElixir.WorkspaceAndConfigTest do
  use CymphonyElixir.TestSupport
  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Linear.Client
  alias Ecto.Changeset

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create hooks for separate workspaces serialize across tasks" do
    root = Path.join(System.tmp_dir!(), "cymphony-after-create-lock-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    critical = Path.join(root, "critical")

    try do
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "mkdir '#{critical}'; sleep 0.05; rmdir '#{critical}'; echo ready > README.md"
      )

      results =
        1..8
        |> Task.async_stream(fn n -> Workspace.create_for_issue("LOCK-#{n}") end,
          max_concurrency: 8,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert Enum.all?(results, fn
               {:ok, {:ok, path}} -> File.read!(Path.join(path, "README.md")) == "ready\n"
               _ -> false
             end)
    after
      File.rm_rf(root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "empty leftover workspace re-runs after_create so a failed clone can recover" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-rebootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo cloned > README.md"
      )

      leftover = Path.join(workspace_root, "MT-EMPTY")
      File.mkdir_p!(Path.join(leftover, ".cymphony"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-EMPTY")
      assert Path.basename(workspace) == "MT-EMPTY"
      assert File.read!(Path.join(workspace, "README.md")) == "cloned\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = CymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = CymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = CymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               CymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               CymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = CymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "CymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.Dispatch.sort_for_dispatch([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "human review is a waiting state while in progress is the re-entry dispatch trigger" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Canceled"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    review_issue = %Issue{
      id: "review-1",
      identifier: "MT-1008",
      title: "Waiting on human review",
      state: "Human Review"
    }

    refute Orchestrator.should_dispatch_issue_for_test(review_issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{review_issue | state: "In Progress"}, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:cymphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:cymphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:cymphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:cymphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      turn_timeout_ms: nil,
      stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "cymphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.claude.command == "claude"

    assert config.agent.turn_timeout_ms == 3_600_000
    assert config.agent.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "claude --model gpt-5.3-claude")
    assert Config.settings!().claude.command == "claude --model gpt-5.3-claude"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "claude")
    assert Config.settings!().claude.command == "claude"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "cymphony-workspace-root")
    api_key = "resolved-secret"
    claude_bin = Path.join(["~", "bin", "claude"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      claude_command: "#{claude_bin} -p"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.claude.command == "#{claude_bin} -p"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "cymphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover state limit validation" do
    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse resolves env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "cymphony_workspaces")

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "cymphony_workspaces")
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             CymphonyElixir.PathSafety.canonicalize(path)
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as claude instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "cymphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.cymphony-remote-workspaces"
      workspace_path = "/remote/home/.cymphony-remote-workspaces/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      IFS= read -r __cymphony_guard_ready || exit 1
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/cymphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__CYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__CYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__CYMPHONY_WORKSPACE__"
      assert trace =~ "~/.cymphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  describe "clean_stale/2" do
    # macOS File.touch with integer seconds is unreliable on directories;
    # shell out to /usr/bin/touch -t which works portably.
    defp backdate(path, days_ago) do
      stamp =
        DateTime.utc_now()
        |> DateTime.add(-days_ago * 86_400, :second)
        |> Calendar.strftime("%Y%m%d%H%M")

      {_, 0} = System.cmd("touch", ["-t", stamp, path])
      :ok
    end

    test "removes workspaces older than the cutoff and keeps fresh ones" do
      root = Path.join(System.tmp_dir!(), "cymphony-clean-stale-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      try do
        old_path = Path.join(root, "ABC-OLD")
        fresh_path = Path.join(root, "ABC-FRESH")
        File.mkdir_p!(old_path)
        File.mkdir_p!(fresh_path)
        backdate(old_path, 10)

        assert {:ok, removed} = Workspace.clean_stale(root, days: 7)
        assert removed == [old_path]
        refute File.exists?(old_path)
        assert File.exists?(fresh_path)
      after
        File.rm_rf(root)
      end
    end

    test "dry_run returns candidates without deleting" do
      root = Path.join(System.tmp_dir!(), "cymphony-clean-dry-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      try do
        old_path = Path.join(root, "ABC-OLD")
        File.mkdir_p!(old_path)
        backdate(old_path, 10)

        assert {:dry_run, [^old_path]} = Workspace.clean_stale(root, days: 7, dry_run: true)
        assert File.exists?(old_path)
      after
        File.rm_rf(root)
      end
    end

    test "skips paths in exclude_paths even when stale" do
      root = Path.join(System.tmp_dir!(), "cymphony-clean-exclude-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)

      try do
        running = Path.join(root, "RUNNING-OLD")
        idle = Path.join(root, "IDLE-OLD")
        File.mkdir_p!(running)
        File.mkdir_p!(idle)
        backdate(running, 10)
        backdate(idle, 10)

        assert {:ok, [^idle]} = Workspace.clean_stale(root, days: 7, exclude_paths: [running])
        assert File.exists?(running)
        refute File.exists?(idle)
      after
        File.rm_rf(root)
      end
    end

    test "missing root returns empty result" do
      missing = Path.join(System.tmp_dir!(), "cymphony-clean-missing-#{System.unique_integer([:positive])}")
      assert {:ok, []} = Workspace.clean_stale(missing, days: 7)
      assert {:dry_run, []} = Workspace.clean_stale(missing, days: 7, dry_run: true)
    end
  end
end
