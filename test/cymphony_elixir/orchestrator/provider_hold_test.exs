defmodule CymphonyElixir.Orchestrator.ProviderHoldTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Agent.ProviderFailure
  alias CymphonyElixir.Orchestrator.State

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "provider-hold-cli")
    File.write!(cli, "#!/bin/sh\nexec /bin/sleep 60\n")
    File.chmod!(cli, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      claude_command: cli,
      claude_provider: "fixture-provider",
      agent_model: "fixture-model",
      poll_interval_ms: 60_000
    )

    tasks = start_supervised!({Task.Supervisor, []})
    ports = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, tasks: tasks, ports: ports, cli: cli, root: root}
  end

  test "fresh nonactive workflow handoffs release tool holds without counting or deleting the workspace", ctx do
    for state_name <- ["Awaiting live proof", "In Review", "Backlog", "Custom excluded state"] do
      {state, issue} = running_state(ctx)
      workspace = Path.join(state.config.workspace.root, issue.identifier)
      File.mkdir_p!(workspace)
      evidence = Path.join(workspace, "handoff-evidence.txt")
      File.write!(evidence, "retained")
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: state_name, state_type: "started"}])
      released = provider_down(state, issue, :tool_permission)
      assert released.retry_attempts == %{}
      assert released.provider_holds == %{}
      refute MapSet.member?(released.claimed, issue.id)
      assert snapshot(released).completed_count == 0
      assert File.read!(evidence) == "retained"
      todo = %{issue | state: "Todo"}
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [todo])
      assert Orchestrator.should_dispatch_issue_for_test(todo, released)
    end
  end

  test "configured workflow route matrix is consistent for fresh failures, manual retries and periodic refresh", ctx do
    cases = [
      {"Todo", "started", ["Todo", "In Progress"], ["Done", "Canceled"], :held, 0},
      {"In Progress", "started", ["Todo", "In Progress"], ["Done", "Canceled"], :held, 0},
      {"Awaiting live proof", "started", ["Todo", "In Progress"], ["Done", "Canceled"], :handoff, 0},
      {"In Review", "started", ["Todo", "In Progress"], ["Done", "Canceled"], :handoff, 0},
      {"Backlog", "unstarted", ["Todo", "In Progress"], ["Done", "Canceled"], :handoff, 0},
      {"Custom excluded state", "started", ["Todo", "In Progress"], ["Done", "Canceled"], :handoff, 0},
      {"In Review", "completed", ["Todo", "In Progress"], ["Done", "Canceled"], :handoff, 0},
      {"Awaiting live proof", "started", ["Todo", "Awaiting live proof"], ["Done", "Canceled"], :held, 0},
      {"Done", "completed", ["Todo", "In Progress"], ["Done", "Canceled"], :terminal, 1},
      {"Canceled", "canceled", ["Todo", "In Progress"], ["Done", "Canceled"], :terminal, 0},
      {"Done", "canceled", ["Todo", "In Progress"], ["Done", "Canceled"], :terminal, 0},
      {"Custom resolved", "completed", ["Todo"], ["Custom resolved"], :terminal, 1},
      {"Done", "completed", ["Todo", "In Progress"], ["Closed"], :handoff, 0},
      {"Todo", "started", ["Working"], ["Closed"], :handoff, 0},
      {nil, "completed", ["Todo", "In Progress"], ["Done", "Canceled"], :held, 0},
      {"", "completed", ["Todo", "In Progress"], ["Done", "Canceled"], :held, 0},
      {"   ", "completed", ["Todo", "In Progress"], ["Done", "Canceled"], :held, 0}
    ]

    calls = configure_handoff_cli(ctx)

    for paused <- [false, true], phase <- [:initial, :manual, :periodic], scenario <- cases do
      {name, type, active, terminal, expected, completed_count} = scenario
      File.rm(calls)
      configure_workflow(ctx, active, terminal)
      {state, issue} = running_state(ctx)
      issue = %{issue | state: hd(active)}
      entry = %{state.running[issue.id] | issue: issue}
      state = %{state | running: %{issue.id => entry}, pending_completed_issue_ids: MapSet.new([issue.id]), paused: paused}
      workspace = Path.join(state.config.workspace.root, issue.identifier)
      File.mkdir_p!(workspace)
      evidence = Path.join(workspace, "workflow-handoff.txt")
      File.write!(evidence, "retained")
      fresh = %{issue | state: name, state_type: type}
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])

      result =
        case phase do
          :initial ->
            Application.put_env(:cymphony_elixir, :memory_tracker_issues, [fresh])
            provider_down(state, issue, :tool_permission)

          later ->
            held = provider_down(state, issue, :tool_permission)
            Application.put_env(:cymphony_elixir, :memory_tracker_issues, [fresh])

            if later == :periodic do
              poll_once(held)
            else
              {:reply, :ok, retried} = apply_call({:retry_issue_now, issue.id}, held)
              if Map.has_key?(retried.running, issue.id), do: await_permission_worker(retried, issue), else: retried
            end
        end

      label = inspect({paused, phase, name, active, terminal})
      assert result.paused == paused, label
      assert snapshot(result).completed_count == completed_count, label
      assert result.running == %{}, label

      if expected == :held do
        assert %{held: true, hold_reason: :tool_permission} = result.retry_attempts[issue.id]
        assert MapSet.member?(result.claimed, issue.id), label
        assert map_size(result.provider_holds) == 1, label
        assert File.read!(evidence) == "retained", label
      else
        assert result.retry_attempts == %{}, label
        assert result.provider_holds == %{}, label
        refute MapSet.member?(result.claimed, issue.id), label
        refute MapSet.member?(result.pending_completed_issue_ids, issue.id), label

        if expected == :terminal do
          refute File.exists?(workspace), label
        else
          assert File.read!(evidence) == "retained", label
          ready = %{issue | state_type: "started"}
          Application.put_env(:cymphony_elixir, :memory_tracker_issues, [ready])
          assert Orchestrator.should_dispatch_issue_for_test(ready, %{result | paused: false}), label
        end
      end

      expected_calls = if phase == :manual and name in active, do: "call\n", else: ""
      actual_calls = if File.exists?(calls), do: File.read!(calls), else: ""
      assert actual_calls == expected_calls, label
    end
  end

  test "real ALE-580 style refusal hands off to Awaiting then permits later Todo without another model call", ctx do
    calls = configure_handoff_cli(ctx)
    {state, original} = running_state(ctx)
    issue = %{original | id: "fixture-ALE-580", identifier: "ALE-580"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])
    {:reply, :ok, dispatched} = apply_call({:dispatch_issue_for_test, issue}, %{state | running: %{}, claimed: MapSet.new()})
    %{ref: ref, pid: pid} = dispatched.running[issue.id]
    assert_receive {:DOWN, ^ref, :process, ^pid, {%ProviderFailure{kind: :tool_permission}, _}} = message, 5_000
    workspace = Path.join(state.config.workspace.root, issue.identifier)
    evidence = Path.join(workspace, "installation-packet.txt")
    File.write!(evidence, "prepared for another owner")
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Awaiting live proof", state_type: "started"}])
    released = apply_info(message, dispatched)
    assert released.retry_attempts == %{}
    assert released.provider_holds == %{}
    refute MapSet.member?(released.claimed, issue.id)
    assert snapshot(released).completed_count == 0
    assert File.read!(evidence) == "prepared for another owner"
    todo = %{issue | state: "Todo"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [todo])
    assert Orchestrator.should_dispatch_issue_for_test(todo, released)
    assert File.read!(calls) == "call\n"
  end

  test "an inactive handoff releases only its own tool holds and leaves other real holds intact", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :tool_permission)
    [{:tool_permission, _, scope}] = Map.keys(held.provider_holds)

    others = %{
      scope => %{kind: :authentication, retry_at: nil, message: "provider login needed"},
      {:tool_permission, "other-held-issue", scope} => %{kind: :tool_permission, retry_at: nil, message: "another issue's refusal"}
    }

    held = %{held | provider_holds: Map.merge(held.provider_holds, others)}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Awaiting live proof"}])
    released = poll_once(held)
    assert released.retry_attempts == %{}
    assert released.provider_holds == others
    assert snapshot(released).completed_count == 0
  end

  test "fresh tracker Done retires a recovered final tool denial and counts completion once", ctx do
    {state, issue} = running_state(ctx)
    completed = %{issue | state: "Done", state_type: "completed"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [completed])
    entry = state.running[issue.id]

    failure =
      ProviderFailure.classify(
        [
          ~s({"type":"result","is_error":false,"result":"Work finished after recovering from an earlier tool denial","permission_denials":[{"tool_name":"Write","tool_use_id":"toolu_earlier","tool_input":{"file_path":"/private/audit.py","content":"fixture"}}]})
        ],
        System.system_time(:millisecond)
      )

    message = {:DOWN, entry.ref, :process, entry.pid, {failure, []}}
    reconciled = apply_info(message, state)
    assert snapshot(reconciled).completed_count == 1
    assert reconciled.retry_attempts == %{}
    assert reconciled.provider_holds == %{}
    assert reconciled.running == %{}
    assert snapshot(apply_info(message, reconciled)).completed_count == 1
  end

  test "an active issue tool denial leaves the same provider available to unrelated issues", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :tool_permission)
    sibling = %{issue | id: "same-assignment-other-issue", identifier: "MT-TOOL-SIBLING"}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue, sibling])
    assert %{hold_reason: :tool_permission, held: true, failures: 0} = held.retry_attempts[issue.id]
    assert [{:tool_permission, id, _scope}] = Map.keys(held.provider_holds)
    assert id == issue.id
    refute Orchestrator.should_dispatch_issue_for_test(issue, held)
    assert Orchestrator.should_dispatch_issue_for_test(sibling, held)
    {:reply, :ok, dispatched} = apply_call({:dispatch_issue_for_test, sibling}, held)
    assert is_pid(dispatched.running[sibling.id].pid)
    assert snapshot(dispatched).completed_count == 0
  end

  test "the failure path awaits fresh terminal state before establishing a permission hold", ctx do
    {state, issue} = running_state(ctx)
    config = %{state.config | tracker: %{state.config.tracker | kind: "linear", endpoint: blocked_terminal_tracker(issue)}}
    entry = state.running[issue.id]
    failure = %ProviderFailure{kind: :tool_permission, message: "earlier tool refusal"}
    {:noreply, checking} = Orchestrator.handle_info({:DOWN, entry.ref, :process, entry.pid, {failure, []}}, %{state | config: config})
    assert_receive {:tool_state_waiting, request}, 2_000
    assert checking.provider_holds == %{}
    assert checking.retry_attempts == %{}
    assert MapSet.member?(checking.claimed, issue.id)
    send(request, :return_tool_done)
    reconciled = await_io(checking)
    assert snapshot(reconciled).completed_count == 1
    assert reconciled.provider_holds == %{}
    assert reconciled.retry_attempts == %{}
  end

  test "a timed-out initial tracker check parks only its issue and retains ownership", ctx do
    {state, issue} = running_state(ctx)
    config = %{state.config | tracker: %{state.config.tracker | kind: "linear", endpoint: blocked_terminal_tracker(issue)}}
    entry = state.running[issue.id]
    failure = %ProviderFailure{kind: :tool_permission, message: "earlier tool refusal"}
    {:noreply, checking} = Orchestrator.handle_info({:DOWN, entry.ref, :process, entry.pid, {failure, []}}, %{state | config: config})
    assert_receive {:tool_state_waiting, request}, 2_000
    {ref, _job} = Enum.find(checking.work.io_jobs, fn {_ref, job} -> job.key == {:effect, {:tool_permission, issue.id}} end)
    {:noreply, timed_out} = Orchestrator.handle_info({:io_timeout, ref}, checking)
    send(request, :return_tool_done)
    held = await_io(timed_out)
    assert %{held: true, hold_reason: :tool_permission, failures: 0, timer_ref: nil} = held.retry_attempts[issue.id]
    assert MapSet.member?(held.claimed, issue.id)
    assert snapshot(held).completed_count == 0
    assert held.work.tool_permission_checks == %{}
  end

  test "real runner cumulative Bash and Write denials reconcile fresh Done after one CLI invocation", ctx do
    calls = Path.join(ctx.root, "completed-tool-calls")

    File.write!(ctx.cli, """
    #!/bin/sh
    printf 'call\\n' >> '#{calls}'
    cat <<'RECOVERED_TOOL_RESULT'
    {"type":"result","subtype":"success","is_error":false,"session_id":"recovered-718-1400","num_turns":47,"result":"Recovered and finished assigned work","permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_earlier_rm","tool_input":{"command":"rm -f $D/*.log"}},{"tool_name":"Write","tool_use_id":"toolu_earlier_write","tool_input":{"file_path":"/private/audits/probe.py","content":"fixture"}}]}
    RECOVERED_TOOL_RESULT
    """)

    {state, issue} = running_state(ctx)
    {:reply, :ok, dispatched} = apply_call({:dispatch_issue_for_test, issue}, %{state | running: %{}, claimed: MapSet.new()})
    %{ref: ref, pid: pid} = dispatched.running[issue.id]
    assert_receive {:DOWN, ^ref, :process, ^pid, {%ProviderFailure{kind: :tool_permission}, _}} = message, 5_000
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    reconciled = apply_info(message, dispatched)
    assert File.read!(calls) == "call\n"
    assert snapshot(reconciled).completed_count == 1
    assert reconciled.retry_attempts == %{}
    assert reconciled.provider_holds == %{}
    assert length(reconciled.recent_completed) == 1
    assert apply_info(message, reconciled).recent_completed == reconciled.recent_completed
    assert File.read!(calls) == "call\n"
  end

  test "genuine provider permission refusals still hold the shared assignment", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :permission)
    sibling = %{issue | id: "provider-permission-sibling", identifier: "MT-API-PERMISSION"}
    refute Orchestrator.should_dispatch_issue_for_test(sibling, held)
    assert held.retry_attempts[issue.id].hold_reason == :permission
    assert [{"claude", "fixture-provider", "fixture-model", _fingerprint}] = Map.keys(held.provider_holds)
  end

  test "a held issue later Done is retired by ordinary periodic reconciliation even while paused", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :tool_permission)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    reconciled = poll_once(%{held | paused: true})
    assert reconciled.paused
    assert snapshot(reconciled).completed_count == 1
    assert reconciled.retry_attempts == %{}
    assert reconciled.provider_holds == %{}
    assert reconciled.running == %{}
    assert snapshot(poll_once(reconciled)).completed_count == 1
  end

  test "manual terminal revalidation retires the issue hold and counts Done without an agent probe", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :tool_permission)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    {:reply, :ok, reconciled} = apply_call({:retry_issue_now, issue.id}, %{held | paused: true})
    assert snapshot(reconciled).completed_count == 1
    assert reconciled.retry_attempts == %{}
    assert reconciled.provider_holds == %{}
    assert reconciled.running == %{}
  end

  test "other terminal states retire tool holds without being counted as Done", ctx do
    for {state_name, type} <- [{"Canceled", "canceled"}, {"Duplicate", "canceled"}, {"Done", "canceled"}] do
      {state, issue} = running_state(ctx)
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: state_name, state_type: type}])
      reconciled = provider_down(state, issue, :tool_permission)
      assert snapshot(reconciled).completed_count == 0
      assert reconciled.retry_attempts == %{}
      assert reconciled.provider_holds == %{}
    end
  end

  test "missing tracker visibility cannot be mistaken for completion or clear a tool hold", ctx do
    {state, issue} = running_state(ctx)
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [])
    held = provider_down(state, issue, :tool_permission)
    assert held.retry_attempts[issue.id].held
    assert snapshot(held).completed_count == 0
    assert map_size(held.provider_holds) == 1
    assert poll_once(held).retry_attempts[issue.id].held

    {:reply, :ok, retried} = apply_call({:retry_issue_now, issue.id}, held)
    assert %{held: true, hold_reason: :tool_permission, failures: 0, timer_ref: nil} = retried.retry_attempts[issue.id]
    assert retried.provider_holds == held.provider_holds
    assert MapSet.member?(retried.claimed, issue.id)
  end

  test "tracker failure preserves a real issue hold without fabricating completion", ctx do
    {state, issue} = running_state(ctx)
    parent = self()

    plug = fn conn, _opts ->
      send(parent, :tool_permission_tracker_read)
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(%{"errors" => [%{"message" => "fixture tracker unavailable"}]}))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    config = %{state.config | tracker: %{state.config.tracker | kind: "linear", endpoint: "http://127.0.0.1:#{port}/graphql"}}
    held = provider_down(%{state | config: config}, issue, :tool_permission)
    assert_receive :tool_permission_tracker_read
    assert snapshot(held).completed_count == 0
    assert %{held: true, hold_reason: :tool_permission, failures: 0} = held.retry_attempts[issue.id]
    assert map_size(held.provider_holds) == 1
    assert held.running == %{}

    {:reply, :ok, retried} = apply_call({:retry_issue_now, issue.id}, held)
    assert %{held: true, hold_reason: :tool_permission, failures: 0, timer_ref: nil} = retried.retry_attempts[issue.id]
    assert snapshot(retried).completed_count == 0
    assert retried.provider_holds == held.provider_holds
  end

  test "a prior-run tool denial cannot inflate a restarted run count", ctx do
    {state, issue} = running_state(ctx)
    entry = Map.put(state.running[issue.id], :completion_run_id, make_ref())
    state = %{state | running: %{issue.id => entry}, work: Map.put(state.work, :completion_run_id, make_ref())}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [%{issue | state: "Done", state_type: "completed"}])
    reconciled = provider_down(state, issue, :tool_permission)
    assert snapshot(reconciled).completed_count == 0
    assert reconciled.retry_attempts == %{}
    assert reconciled.provider_holds == %{}
  end

  test "a real permission refusal stays parked and each config change or deliberate retry permits just one probe", ctx do
    calls = Path.join(ctx.root, "permission-calls")

    File.write!(ctx.cli, """
    #!/bin/sh
    printf 'call\\n' >> '#{calls}'
    cat <<'CYMPHONY_PERMISSION_FIXTURE'
    {"type":"result","subtype":"success","is_error":false,"session_id":"permission-session","num_turns":1,"result":"Permission required","permission_denials":[{"tool_name":"mcp__linear__get_issue","tool_use_id":"toolu_denied","tool_input":{"id":"ALE-1406","api_key":"lin_api_PRIVATE"}}]}
    CYMPHONY_PERMISSION_FIXTURE
    """)

    {state, issue} = running_state(ctx)
    state = %{state | running: %{}, claimed: MapSet.new()}
    {:reply, :ok, dispatched} = apply_call({:dispatch_issue_for_test, issue}, state)
    held = await_permission_worker(dispatched, issue)

    assert %{held: true, hold_reason: :tool_permission, failures: 0, timer_ref: nil} = held.retry_attempts[issue.id]
    assert File.read!(calls) == "call\n"
    refute inspect(snapshot(held)) =~ "PRIVATE"

    stable = repeat_provider_wait(held, issue)
    unrelated_config = %{stable.config | codex: %{stable.config.codex | extra_args: ["--full-auto"]}}
    unchanged = apply_info(:watchdog, %{stable | config: unrelated_config})
    assert unchanged.retry_attempts[issue.id] == stable.retry_attempts[issue.id]
    assert unchanged.running == %{}
    assert File.read!(calls) == "call\n"

    claude = %{unchanged.config.claude | extra_args: ["--allowedTools", "mcp__linear__*"]}
    changed = apply_info(:watchdog, %{unchanged | config: %{unchanged.config | claude: claude}})
    retry = changed.retry_attempts[issue.id]
    refute retry.held
    refute retry.retry_token == unchanged.retry_attempts[issue.id].retry_token
    revalidated = apply_info({:retry_issue, issue.id, retry.retry_token}, changed)
    held_again = revalidated |> await_permission_worker(issue) |> repeat_provider_wait(issue)
    assert File.read!(calls) == "call\ncall\n"
    assert held_again.retry_attempts[issue.id].failures == 0

    {:reply, :ok, probed} = apply_call({:retry_issue_now, issue.id}, %{held_again | paused: true})
    assert probed.running[issue.id].provider_probe
    manually_held = probed |> await_permission_worker(issue) |> repeat_provider_wait(issue)
    assert manually_held.paused
    assert manually_held.retry_attempts[issue.id].hold_reason == :tool_permission
    assert manually_held.retry_attempts[issue.id].failures == 0
    assert File.read!(calls) == "call\ncall\ncall\n"
  end

  test "Claude permission configuration changes leave another native agent scope held", ctx do
    {state, issue} = running_state(ctx)
    other = %{issue | id: "codex-provider-held", identifier: "MT-CODEX-HOLD", labels: ["agent:codex"]}

    other_entry =
      state.running[issue.id]
      |> Map.merge(%{issue: other, identifier: other.identifier, ref: make_ref(), pid: spawn(fn -> :ok end), agent_kind: "codex", provider: nil})

    state = %{state | running: Map.put(state.running, other.id, other_entry)}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue, other])
    held = state |> provider_down(issue, :tool_permission) |> provider_down(other, :authentication)
    assert map_size(held.provider_holds) == 2
    other_retry = held.retry_attempts[other.id]
    claude = %{held.config.claude | permission_mode: "bypassPermissions"}
    changed = apply_info(:watchdog, %{held | config: %{held.config | claude: claude}})

    refute changed.retry_attempts[issue.id].held
    assert changed.retry_attempts[other.id] == other_retry
    assert changed.running == %{}
  end

  test "authentication refusal parks native retries without consuming coding failures", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :authentication)

    assert %{held: true, hold_reason: :authentication, failures: 0, timer_ref: nil} = held.retry_attempts[issue.id]
    assert map_size(Map.get(held, :provider_holds, %{})) == 1
    assert held.running == %{}

    stable =
      Enum.reduce(1..8, held, fn _, acc ->
        entry = acc.retry_attempts[issue.id]
        apply_info({:retry_issue, issue.id, entry.retry_token}, acc)
      end)

    assert stable.retry_attempts[issue.id].failures == 0
    assert stable.retry_attempts[issue.id].timer_ref == nil
    assert stable.running == %{}
    assert stable.work.io_jobs == %{}
    assert snapshot(stable).retrying |> hd() |> Map.fetch!(:wait_reason) == :authentication
  end

  test "unknown quota remains held across resume and watchdog until manual recovery", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :quota)
    assert %{held: true, hold_reason: :quota, timer_ref: nil, failures: 0} = held.retry_attempts[issue.id]

    {:reply, :ok, resumed} = Orchestrator.handle_call(:resume, {self(), make_ref()}, %{held | paused: true})
    watched = apply_info(:watchdog, resumed)
    assert watched.retry_attempts[issue.id].timer_ref == nil
    assert watched.retry_attempts[issue.id].failures == 0
    assert watched.running == %{}
    assert watched.work.io_jobs == %{}
  end

  test "known quota deadline wakes through watchdog only after reset and while unpaused", ctx do
    {state, issue} = running_state(ctx)
    deadline = System.system_time(:millisecond) + 60_000
    held = provider_down(state, issue, :quota, deadline)
    assert %{hold_reason: :quota, failures: 0, provider_hold_key: key} = held.retry_attempts[issue.id]
    assert key != nil
    original = held.retry_attempts[issue.id]
    assert apply_info(:watchdog, held).running == %{}

    holds = Map.update!(Map.fetch!(held, :provider_holds), key, &Map.put(&1, :retry_at, 0))
    entry = Map.put(original, :due_at_ms, System.monotonic_time(:millisecond) - 1)
    expired = held |> Map.put(:provider_holds, holds) |> Map.put(:retry_attempts, %{issue.id => entry})

    paused = apply_info(:watchdog, %{expired | paused: true})
    assert paused.running == %{}
    assert paused.retry_attempts[issue.id].retry_token == original.retry_token

    recovered = apply_info(:watchdog, %{expired | paused: false})
    next_retry = Map.get(recovered.retry_attempts, issue.id)
    assert next_retry != nil or Map.has_key?(recovered.running, issue.id)
    assert next_retry == nil or next_retry.retry_token != original.retry_token
  end

  test "manual retry may probe a provider while paused but cannot bypass shared Linear cooldown", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :authentication)
    assert held.retry_attempts[issue.id][:hold_reason] == :authentication

    tracker = %{held.config.tracker | kind: "linear", endpoint: "http://127.0.0.1:1/graphql", api_key: "fixture-hold-#{make_ref() |> inspect()}"}
    config = %{held.config | tracker: tracker}
    rate_limit = CymphonyElixir.Linear.RateLimit

    headers = [{"authorization", tracker.api_key}]
    response = %{status: 429, headers: [{"retry-after", "60"}]}
    assert {:error, {:linear_rate_limited, _}} = rate_limit.observe(tracker.endpoint, headers, response, [])

    {:reply, :ok, result} = apply_call({:retry_issue_now, issue.id}, %{held | config: config, paused: true})
    assert result.running == %{}
    assert result.work.io_jobs == %{}
    assert result.retry_attempts[issue.id].failures == 0
    assert rate_limit.remaining(config) > 0
  end

  test "manual retry permits one local provider probe while the project remains paused", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :authentication)
    assert held.retry_attempts[issue.id][:hold_reason] == :authentication
    {:reply, :ok, result} = apply_call({:retry_issue_now, issue.id}, %{held | paused: true})
    assert %{pid: pid, failure_count: 0} = result.running[issue.id]
    assert is_pid(pid)
    assert result.running[issue.id].provider_probe
    assert result.paused
    refute Map.has_key?(result.retry_attempts, issue.id)
  end

  test "a sibling already running before quota refusal cannot clear the scoped hold", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :quota)
    [key] = Map.keys(held.provider_holds)
    sibling = %{issue | id: "in-flight-sibling", identifier: "MT-SIBLING"}
    entry = state.running[issue.id] |> Map.put(:issue, sibling) |> Map.put(:identifier, sibling.identifier) |> Map.put(:provider_scope, key)
    state = %{held | running: %{sibling.id => entry}}

    after_sibling = apply_info({:DOWN, entry.ref, :process, entry.pid, :normal}, state)
    assert after_sibling.provider_holds == held.provider_holds
    assert after_sibling.retry_attempts[issue.id].hold_reason == :quota
    assert after_sibling.retry_attempts[issue.id].timer_ref == nil
  end

  test "manual retry at capacity after an initial provider refusal preserves a valid wait", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :authentication)
    busy = %{held | max_concurrent_agents: 0, paused: true}

    {:reply, :ok, waiting} = apply_call({:retry_issue_now, issue.id}, busy)
    assert waiting.running == %{}
    assert waiting.retry_attempts[issue.id].attempt >= 1
    assert waiting.retry_attempts[issue.id].failures == 0
    assert waiting.retry_attempts[issue.id].wait_reason == :capacity
  end

  test "a provider hold blocks the matching assignment while another model can dispatch", ctx do
    {state, issue} = running_state(ctx)
    held = provider_down(state, issue, :authentication)
    assert map_size(Map.get(held, :provider_holds, %{})) == 1
    same = %{issue | id: "same-provider", identifier: "MT-SAME"}
    other = %{issue | id: "other-model", identifier: "MT-OTHER", labels: ["model:available-model"]}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [same, other])

    refute Orchestrator.should_dispatch_issue_for_test(same, held)
    assert Orchestrator.should_dispatch_issue_for_test(other, held)
    {:reply, :ok, dispatched} = apply_call({:dispatch_issue_for_test, other}, held)
    assert %{model: "available-model", pid: pid} = dispatched.running[other.id]
    assert is_pid(pid)
  end

  test "provider hold snapshot exposes actionable reason without credentials", ctx do
    {state, issue} = running_state(ctx)
    secret = "lin_api_provider_hold_private_fixture"
    config = %{state.config | tracker: %{state.config.tracker | api_key: secret}}
    held = provider_down(%{state | config: config}, issue, :authentication)
    assert held.retry_attempts[issue.id][:hold_reason] == :authentication
    public = snapshot(held)
    assert [%{wait_reason: :authentication, held: true}] = public.retrying
    refute inspect(public) =~ secret
    refute inspect(Map.get(held, :provider_holds)) =~ secret
  end

  defp running_state(ctx) do
    issue = %Issue{id: "provider-held", identifier: "MT-HOLD", title: "Provider hold", state: "In Progress", labels: [], blocked_by: []}
    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue])
    config = Config.settings!()

    entry = %{
      issue: issue,
      identifier: issue.identifier,
      ref: make_ref(),
      pid: spawn(fn -> :ok end),
      started_at: DateTime.utc_now(),
      retry_attempt: 0,
      failure_count: 0,
      agent_kind: "claude",
      provider: "fixture-provider",
      model: "fixture-model",
      effort: nil,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0
    }

    state = %State{
      config: config,
      prompt_template: "Local fixture",
      max_concurrent_agents: 2,
      task_supervisor: ctx.tasks,
      port_supervisor: ctx.ports,
      providers: ["fixture-provider"],
      claimed: MapSet.new([issue.id]),
      running: %{issue.id => entry},
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      poll_interval_ms: 60_000
    }

    {state, issue}
  end

  defp configure_workflow(ctx, active, terminal) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: active,
      tracker_terminal_states: terminal,
      workspace_root: Path.join(ctx.root, "workspaces"),
      claude_command: ctx.cli,
      claude_provider: "fixture-provider",
      agent_model: "fixture-model",
      poll_interval_ms: 60_000
    )
  end

  defp configure_handoff_cli(ctx) do
    calls = Path.join(ctx.root, "workflow-model-calls")

    File.write!(ctx.cli, """
    #!/bin/sh
    printf 'call\\n' >> '#{calls}'
    cat <<'HANDOFF_TOOL_RESULT'
    {"type":"result","subtype":"success","is_error":false,"session_id":"handoff-session","num_turns":12,"result":"Published source and prepared the next owner's installation packet","permission_denials":[{"tool_name":"Write","tool_use_id":"toolu_packet","tool_input":{"file_path":"/private/audits/installation-packet.md","content":"fixture"}}]}
    HANDOFF_TOOL_RESULT
    """)

    calls
  end

  defp provider_down(state, issue, kind, retry_at \\ nil) do
    entry = state.running[issue.id]
    failure = %ProviderFailure{kind: kind, retry_at: retry_at, message: "Provider unavailable; operator action required."}
    apply_info({:DOWN, entry.ref, :process, entry.pid, {failure, []}}, state)
  end

  defp await_permission_worker(state, issue) do
    %{ref: ref, pid: pid} = state.running[issue.id]
    assert_receive {:DOWN, ^ref, :process, ^pid, {%ProviderFailure{kind: :tool_permission}, _stack}} = message, 5_000
    apply_info(message, state)
  end

  defp repeat_provider_wait(state, issue) do
    Enum.reduce(1..4, state, fn _, acc ->
      retry = acc.retry_attempts[issue.id]
      acc = apply_info({:retry_issue, issue.id, retry.retry_token}, acc)
      apply_info(:watchdog, acc)
    end)
  end

  defp poll_once(state) do
    state = apply_info(:tick, state)
    apply_info(:run_poll_cycle, state)
  end

  defp blocked_terminal_tracker(issue) do
    parent = self()

    plug = fn conn, _opts ->
      send(parent, {:tool_state_waiting, self()})
      receive do: (:return_tool_done -> :ok)

      node = %{
        "id" => issue.id,
        "identifier" => issue.identifier,
        "title" => issue.title,
        "state" => %{"name" => "Done", "type" => "completed"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => %{"issues" => %{"nodes" => [node]}}}))
    end

    server = start_supervised!({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}, startup_log: false})
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/graphql"
  end

  defp snapshot(state) do
    {:reply, value, _state} = Orchestrator.handle_call(:snapshot, {self(), make_ref()}, state)
    value
  end

  defp apply_info(message, state) do
    {:noreply, next} = Orchestrator.handle_info(message, state)
    await_io(next)
  end

  defp apply_call(message, state) do
    {:reply, reply, next} = Orchestrator.handle_call(message, {self(), make_ref()}, state)
    {:reply, reply, await_io(next)}
  end

  defp await_io(%{work: %{io_jobs: jobs}} = state) when map_size(jobs) == 0, do: state

  defp await_io(state) do
    receive do
      {ref, _result} = message when is_map_key(state.work.io_jobs, ref) ->
        {:noreply, next} = Orchestrator.handle_info(message, state)
        await_io(next)

      {:DOWN, ref, :process, _pid, _reason} = message when is_map_key(state.work.io_jobs, ref) ->
        {:noreply, next} = Orchestrator.handle_info(message, state)
        await_io(next)
    after
      2_000 -> flunk("native provider-hold I/O did not finish")
    end
  end
end
