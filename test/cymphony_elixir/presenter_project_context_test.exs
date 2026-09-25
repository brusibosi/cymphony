defmodule CymphonyElixir.PresenterProjectContextTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixirWeb.Presenter

  defmodule SnapshotServer do
    use GenServer

    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}
    def handle_call(:snapshot, _from, snapshot), do: {:reply, snapshot, snapshot}
  end

  test "issue fallback path and stall status follow each snapshot's project settings" do
    root = Path.join(System.tmp_dir!(), "cymphony-presenter-default-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    old = DateTime.add(DateTime.utc_now(), -2, :second)

    for {project, workspace_root, stall_timeout, stalled?} <- [
          {"Alpha", "/alpha/workspaces", 500, true},
          {"Beta", "/beta/workspaces", 60_000, false}
        ] do
      entry = %{
        issue_id: "issue-#{project}",
        identifier: "CTX-3",
        state: "In Progress",
        session_id: "s",
        started_at: old,
        last_agent_timestamp: old,
        last_agent_event: :tick,
        last_agent_message: nil,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        turn_count: 1,
        log_events: [],
        workspace_path: nil
      }

      snapshot = %{
        project_name: project,
        workspace_root: workspace_root,
        stall_timeout_ms: stall_timeout,
        running: [entry],
        retrying: [],
        waiting: [],
        recent_completed: [],
        token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 2},
        rate_limits: nil,
        polling: %{next_poll_in_ms: 1000, poll_interval_ms: 30_000, paused: false}
      }

      {:ok, server} = start_supervised({SnapshotServer, snapshot}, id: project)
      assert {:ok, issue} = Presenter.issue_payload("CTX-3", server, 1000)
      assert issue.workspace.path == Path.join(workspace_root, "CTX-3")
      payload = Presenter.state_payload(server, 1000)
      assert hd(payload.running).stalled == stalled?
    end
  end
end
