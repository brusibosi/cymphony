defmodule CymphonyElixir.Orchestrator.RunCompletionCounterTest do
  use CymphonyElixir.TestSupport
  alias CymphonyElixir.Orchestrator.State

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(root, "workspaces"))
    tasks = start_supervised!({Task.Supervisor, []})
    ports = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, tasks: tasks, ports: ports}
  end

  test "1001 distinct terminal confirmations are counted beyond retained history", ctx do
    issues = for n <- 1..1001, do: issue("counter-#{n}", "Done", "completed")
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, issues)
    state = state(ctx, issues)
    result = Enum.reduce(issues, state, &confirm/2)
    assert snapshot(result).completed_count == 1001
    assert MapSet.size(result.completed_issue_ids) == 1001
    first = hd(issues)
    original = state.retry_attempts[first.id]
    duplicate = apply_info({:retry_issue, first.id, original.retry_token}, result)
    assert snapshot(duplicate).completed_count == 1001
    {:reply, :ok, restarted} = Orchestrator.handle_call(:resume, {self(), make_ref()}, %{result | paused: true})
    assert snapshot(restarted).completed_count == 0
    {:reply, :ok, same_run} = Orchestrator.handle_call(:resume, {self(), make_ref()}, result)
    assert snapshot(same_run).completed_count == 1001
  end

  test "canceled, duplicate and inactive issues are never counted as completed", ctx do
    issues = [issue("canceled", "Canceled", "canceled"), issue("duplicate", "Duplicate", "canceled"), issue("review", "In Review", "started")]
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, issues)
    result = Enum.reduce(issues, state(ctx, issues), &confirm/2)
    assert snapshot(result).completed_count == 0
    assert result.pending_completed_issue_ids == MapSet.new()
  end

  test "a nonterminal workflow handoff cannot count inherited pending completion from its state type", ctx do
    handoff = issue("configured-handoff", "In Review", "completed")
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [handoff])
    result = confirm(handoff, state(ctx, [handoff]))
    assert snapshot(result).completed_count == 0
    assert result.pending_completed_issue_ids == MapSet.new()
    assert result.retry_attempts == %{}
    refute MapSet.member?(result.claimed, handoff.id)
  end

  test "a normal worker turn is pending until tracker completion is independently confirmed", ctx do
    issue = issue("pending", "In Progress", "started")
    state = state(ctx, [])

    entry = %{
      pid: spawn(fn -> :ok end),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now(),
      worker_host: nil,
      retry_attempt: nil,
      failure_count: 0,
      completion_run_id: state.work.completion_run_id
    }

    state = %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    result = apply_info({:DOWN, entry.ref, :process, entry.pid, :normal}, state)
    assert snapshot(result).completed_count == 0
    assert MapSet.member?(result.pending_completed_issue_ids, issue.id)
    retry = result.retry_attempts[issue.id]
    Process.cancel_timer(retry.timer_ref)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    assert snapshot(confirm(issue, result)).completed_count == 1
  end

  test "a prior-run worker cannot inflate the new run after pause and resume", ctx do
    issue = issue("old-run", "In Progress", "started")
    state = state(ctx, [])
    old_run = state.work.completion_run_id
    {:reply, :ok, restarted} = Orchestrator.handle_call(:resume, {self(), make_ref()}, %{state | paused: true})

    entry = %{
      pid: spawn(fn -> :ok end),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      started_at: DateTime.utc_now(),
      worker_host: nil,
      retry_attempt: nil,
      failure_count: 0,
      completion_run_id: old_run
    }

    result = apply_info({:DOWN, entry.ref, :process, entry.pid, :normal}, %{restarted | running: %{issue.id => entry}})
    refute MapSet.member?(result.pending_completed_issue_ids, issue.id)
    retry = result.retry_attempts[issue.id]
    Process.cancel_timer(retry.timer_ref)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    assert snapshot(confirm(issue, result)).completed_count == 0
  end

  defp issue(id, status, type), do: %Issue{id: id, identifier: "MT-#{id}", title: id, state: status, state_type: type, labels: [], blocked_by: []}

  defp state(ctx, issues) do
    retries =
      Map.new(issues, fn issue -> {issue.id, %{attempt: 1, failures: 0, identifier: issue.identifier, timer_ref: nil, retry_token: make_ref(), due_at_ms: System.monotonic_time(:millisecond)}} end)

    %State{
      config: Config.settings!(),
      task_supervisor: ctx.tasks,
      port_supervisor: ctx.ports,
      max_concurrent_agents: 1,
      providers: [],
      work: Map.put(%State{}.work, :completion_run_id, make_ref()),
      pending_completed_issue_ids: MapSet.new(Enum.map(issues, & &1.id)),
      retry_attempts: retries,
      claimed: MapSet.new(Map.keys(retries)),
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp confirm(issue, state) do
    retry = state.retry_attempts[issue.id]
    apply_info({:retry_issue, issue.id, retry.retry_token}, state)
  end

  defp snapshot(state) do
    {:reply, snapshot, _} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    snapshot
  end

  defp apply_info(message, state) do
    {:noreply, next} = Orchestrator.handle_info(message, state)
    await_io(next)
  end

  defp await_io(%{work: %{io_jobs: jobs}} = state) when map_size(jobs) == 0, do: state

  defp await_io(state) do
    receive do
      {ref, _result} = message when is_map_key(state.work.io_jobs, ref) -> apply_info(message, state)
      {:DOWN, ref, :process, _pid, _reason} = message when is_map_key(state.work.io_jobs, ref) -> apply_info(message, state)
    after
      2000 -> flunk("counter IO did not finish")
    end
  end
end
