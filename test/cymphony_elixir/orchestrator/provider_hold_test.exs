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

    assert %{held: true, hold_reason: :permission, failures: 0, timer_ref: nil} = held.retry_attempts[issue.id]
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
    assert manually_held.retry_attempts[issue.id].hold_reason == :permission
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
    held = state |> provider_down(issue, :permission) |> provider_down(other, :authentication)
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

  defp provider_down(state, issue, kind, retry_at \\ nil) do
    entry = state.running[issue.id]
    failure = %ProviderFailure{kind: kind, retry_at: retry_at, message: "Provider unavailable; operator action required."}
    apply_info({:DOWN, entry.ref, :process, entry.pid, {failure, []}}, state)
  end

  defp await_permission_worker(state, issue) do
    %{ref: ref, pid: pid} = state.running[issue.id]
    assert_receive {:DOWN, ^ref, :process, ^pid, {%ProviderFailure{kind: :permission}, _stack}} = message, 5_000
    apply_info(message, state)
  end

  defp repeat_provider_wait(state, issue) do
    Enum.reduce(1..4, state, fn _, acc ->
      retry = acc.retry_attempts[issue.id]
      acc = apply_info({:retry_issue, issue.id, retry.retry_token}, acc)
      apply_info(:watchdog, acc)
    end)
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
