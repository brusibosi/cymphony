defmodule CymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Claude-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias CymphonyElixir.{
    Agent,
    AgentRunner,
    CompletionStore,
    Config,
    HarnessStream,
    ProjectSupervisor,
    RunSpecResolver,
    StatusDashboard,
    Tracker,
    WorkflowStore,
    Workspace
  }

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Orchestrator.{Dispatch, Queue, Stall, Tokens}
  alias CymphonyElixirWeb.ObservabilityPubSub

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_token_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :config,
      :project_name,
      :prompt_template,
      :poll_interval_ms,
      :max_concurrent_agents,
      :providers,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :runtime_agent,
      paused: false,
      running: %{},
      waiting: [],
      queue_order: nil,
      queue_pins: %{},
      queue_priority_seen: %{},
      recent_completed: [],
      claimed: MapSet.new(),
      retry_attempts: %{},
      token_totals: nil,
      rate_limits: nil
    ]
  end

  @max_recent_completed 100

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    project_name = Keyword.get(opts, :project_name)
    {config, prompt_template} = load_project_config_from_store(project_name)
    {queue_order, queue_pins, queue_priority_seen} = load_project_queue(project_name)

    state = %State{
      config: config,
      project_name: project_name,
      prompt_template: prompt_template,
      paused: load_project_dispatch_paused(project_name),
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      providers: extract_providers(config),
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      waiting: [],
      queue_order: queue_order,
      queue_pins: queue_pins,
      queue_priority_seen: queue_priority_seen,
      recent_completed: load_recent_completed(project_name),
      token_totals: @empty_token_totals,
      rate_limits: nil
    }

    run_terminal_workspace_cleanup(state)
    state = schedule_tick(state, 0)
    schedule_workspace_sweep(state.config)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id, running_entry)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)
              failures = running_entry_failure_count(running_entry) + 1

              maybe_retry_or_abandon(state, issue_id, next_attempt, failures, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{format_exit_reason(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                failures: failures
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
          |> append_log_event(
            :worker_ready,
            "workspace=#{runtime_info[:workspace_path]} host=#{runtime_info[:worker_host] || "local"}"
          )

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: :harness_heartbeat} = update},
        %{running: running} = state
      )
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        timestamp = Map.get(update, :timestamp) || DateTime.utc_now()
        updated_entry = Map.put(running_entry, :last_agent_timestamp, timestamp)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_entry)}}
    end
  end

  def handle_info(
        {:agent_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_agent_update(running_entry, update)

        state =
          state
          |> apply_agent_token_delta(token_delta)
          |> apply_rate_limits(update)

        notify_dashboard()
        ObservabilityPubSub.broadcast_issue_update(issue_id)
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:agent_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, %State{paused: true} = state) do
    state = hold_retry_attempt(state, issue_id, retry_token)
    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(:workspace_sweep, state) do
    run_workspace_sweep(state)
    schedule_workspace_sweep(state.config)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(state.config),
         {:ok, issues} <- Tracker.fetch_candidate_issues(state.config) do
      state = attach_waiting(state, issues)
      if state.paused, do: state, else: dispatch_waiting_list(state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids, state.config) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(state),
            terminal_state_set(state)
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(state), terminal_state_set(state))
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(state), terminal_state_set(state))
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec resolve_run_spec_for_test(Issue.t(), term()) :: RunSpecResolver.resolved()
  def resolve_run_spec_for_test(issue, config), do: RunSpecResolver.resolve(issue, config)

  @doc false
  @spec dispatch_issue_for_test(GenServer.server(), Issue.t()) :: :ok
  def dispatch_issue_for_test(server, %Issue{} = issue) do
    GenServer.call(server, {:dispatch_issue_for_test, issue})
  end

  @doc false
  @spec run_poll_cycle_for_test(GenServer.server()) :: :ok
  def run_poll_cycle_for_test(server) do
    GenServer.call(server, :run_poll_cycle_for_test, 15_000)
  end

  @doc false
  @spec kill_issue_for_test(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def kill_issue_for_test(server, issue_id) when is_binary(issue_id) do
    GenServer.call(server, {:kill_issue, issue_id})
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    drop_harness_stream(issue_id)

    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host, state_config(state))
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    do_reconcile_stalled(state, state_config(state).agent.stall_timeout_ms)
  end

  defp do_reconcile_stalled(state, timeout_ms) do
    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Stall.stalled?(running_entry, now, timeout_ms) do
      elapsed_ms = Stall.elapsed_ms(running_entry, now)
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)
      failures = running_entry_failure_count(running_entry) + 1

      state
      |> terminate_running_issue(issue_id, false)
      |> maybe_retry_or_abandon(issue_id, next_attempt, failures, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without agent activity",
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        failures: failures
      })
    else
      state
    end
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(CymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp attach_waiting(%State{} = state, issues) when is_list(issues) do
    eligible = filter_waiting_eligible(issues, state)
    saved_order = state.queue_order
    prev_seen = state.queue_priority_seen || %{}
    {ordered, seen} = Queue.reconcile(eligible, saved_order, prev_seen)
    order_keys = waiting_order_keys(ordered)

    state = %{
      state
      | waiting: ordered,
        queue_order: assign_queue_order(saved_order, order_keys),
        queue_priority_seen: seen
    }

    maybe_persist_queue_order(state, saved_order, prev_seen)
  end

  defp filter_waiting_eligible(issues, %State{} = state) do
    active_states = active_state_set(state)
    terminal_states = terminal_state_set(state)

    Enum.filter(issues, &waiting_eligible?(&1, state, active_states, terminal_states))
  end

  defp waiting_eligible?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(state.claimed, issue.id) and
      !Map.has_key?(state.running, issue.id) and
      !Map.has_key?(state.retry_attempts, issue.id)
  end

  defp waiting_eligible?(_issue, _state, _active_states, _terminal_states), do: false

  defp assign_queue_order(nil, []), do: nil
  defp assign_queue_order(nil, keys) when is_list(keys), do: keys
  defp assign_queue_order(_saved, keys) when is_list(keys), do: keys

  defp waiting_order_keys(issues) when is_list(issues) do
    issues
    |> Enum.map(&Queue.issue_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp dispatch_waiting_list(%State{waiting: waiting} = state) do
    walk_waiting_dispatch(state, waiting)
  end

  defp walk_waiting_dispatch(%State{} = state, []), do: state

  defp walk_waiting_dispatch(%State{} = state, [issue | rest]) do
    cond do
      available_slots(state) == 0 ->
        state

      not waiting_capacity_available?(issue, state) ->
        walk_waiting_dispatch(state, rest)

      should_dispatch_issue?(issue, state, active_state_set(state), terminal_state_set(state)) ->
        state
        |> spawn_waiting_issue(issue)
        |> walk_waiting_dispatch(rest)

      true ->
        walk_waiting_dispatch(state, rest)
    end
  end

  defp waiting_capacity_available?(%Issue{} = issue, %State{} = state) do
    state_slots_available?(issue, state.running, state) and worker_slots_available?(state)
  end

  defp spawn_waiting_issue(%State{} = state, %Issue{} = issue) do
    new_state = dispatch_issue(state, issue, nil, nil, from_waiting: true)

    if waiting_issue_consumed?(new_state, issue) do
      %{new_state | waiting: Enum.reject(new_state.waiting, &(&1.id == issue.id))}
    else
      new_state
    end
  end

  defp waiting_issue_consumed?(%State{} = state, %Issue{id: issue_id}) do
    Map.has_key?(state.running, issue_id) or
      Map.has_key?(state.retry_attempts, issue_id) or
      MapSet.member?(state.claimed, issue_id)
  end

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running, state) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running, %State{} = state) when is_map(running) do
    config = state_config(state)
    limit = Map.get(config.agent.max_concurrent_agents_by_state, normalize_issue_state(issue_state), config.agent.max_concurrent_agents)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running, _state), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  # Implements the dispatch rule from openai/symphony SPEC §8.2:
  # > "If state is `Todo`, do not dispatch when any blocker is non-terminal."
  #
  # A blocker is considered non-terminal when its state name (case-insensitive,
  # normalized via `normalize_issue_state/1`) is not in `terminal_states`. The
  # rule applies only when the issue itself is in the Todo state — issues
  # already in progress are allowed to run even when blockers remain open, so
  # an in-flight worker can finish what it started.
  #
  # Returns `true` when the issue should NOT be dispatched, `false` otherwise.
  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set(%State{} = state) do
    state_config(state).tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp terminal_state_set do
    load_config().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set(%State{} = state) do
    state_config(state).tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    load_config().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp transition_to_in_progress(%Issue{} = issue, %State{config: nil}) do
    transition_to_in_progress(issue)
  end

  defp transition_to_in_progress(%Issue{} = issue, %State{config: config}) do
    if normalize_issue_state(issue.state || "") == "todo" do
      case Tracker.update_issue_state(issue.id, "In Progress", config) do
        :ok ->
          Logger.info("Transitioned issue to In Progress: #{issue_context(issue)}")

        {:error, reason} ->
          Logger.warning("Failed to transition issue to In Progress: #{issue_context(issue)} reason=#{inspect(reason)}")
      end
    end
  end

  defp transition_to_in_progress(%Issue{} = issue) do
    if normalize_issue_state(issue.state || "") == "todo" do
      case Tracker.update_issue_state(issue.id, "In Progress") do
        :ok ->
          Logger.info("Transitioned issue to In Progress: #{issue_context(issue)}")

        {:error, reason} ->
          Logger.warning("Failed to transition issue to In Progress: #{issue_context(issue)} reason=#{inspect(reason)}")
      end
    end
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, opts \\ []) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids(&1, state.config), terminal_state_set(state)) do
      {:ok, %Issue{} = refreshed_issue} ->
        transition_to_in_progress(refreshed_issue, state)
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, opts)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, opts) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, opts)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, opts) do
    spec = dispatch_run_spec(state, issue, opts)

    case start_issue_agent_task(state, issue, attempt, recipient, worker_host, spec) do
      {:ok, pid} ->
        track_spawned_issue(state, issue, attempt, worker_host, spec, pid, opts)

      {:error, reason} ->
        handle_spawn_failure(state, issue, attempt, worker_host, reason, opts)
    end
  end

  defp dispatch_run_spec(%State{} = state, issue, opts) do
    resolved = RunSpecResolver.resolve(issue, state_config(state))
    pin = queue_pin_for(state, issue)
    from_waiting? = Keyword.get(opts, :from_waiting, false)
    pin_kind = pin_field(pin, :agent_kind)
    pin_model = pin_field(pin, :model)
    pin_effort = pin_field(pin, :effort)

    agent_kind =
      pick_run_spec_field(
        from_waiting?,
        pin_kind,
        Keyword.get(opts, :agent_kind_override),
        resolved.agent_kind
      )

    model =
      pick_run_spec_field(
        from_waiting?,
        pin_model,
        Keyword.get(opts, :model_override),
        resolved.model
      )

    effort =
      pick_run_spec_field(
        from_waiting?,
        pin_effort,
        Keyword.get(opts, :effort_override),
        resolved.effort
      )

    source =
      if pin_applied?(pin_kind, pin_model, pin_effort, agent_kind, model, effort) do
        :pin
      else
        resolved.source
      end

    %{
      resolved: resolved,
      source: source,
      agent_kind: agent_kind,
      provider:
        Keyword.get(opts, :provider_override) || resolved.provider ||
          select_provider_for_kind(state, agent_kind),
      model: model,
      effort: effort
    }
  end

  defp pick_run_spec_field(true, pin, _override, _fallback) when not is_nil(pin), do: pin
  defp pick_run_spec_field(true, _pin, override, _fallback) when not is_nil(override), do: override
  defp pick_run_spec_field(true, _pin, _override, fallback), do: fallback
  defp pick_run_spec_field(false, _pin, override, _fallback) when not is_nil(override), do: override
  defp pick_run_spec_field(false, pin, _override, _fallback) when not is_nil(pin), do: pin
  defp pick_run_spec_field(false, _pin, _override, fallback), do: fallback

  defp pin_applied?(pin_kind, pin_model, pin_effort, agent_kind, model, effort) do
    (is_binary(pin_kind) and pin_kind == agent_kind) or
      (is_binary(pin_model) and pin_model == model) or
      (is_binary(pin_effort) and pin_effort == effort)
  end

  defp start_issue_agent_task(state, issue, attempt, recipient, worker_host, spec) do
    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      AgentRunner.run(issue, recipient,
        attempt: attempt,
        worker_host: worker_host,
        config: state.config,
        prompt_template: state.prompt_template,
        provider_override: spec.provider,
        agent_kind: spec.agent_kind,
        model: spec.model,
        effort: spec.effort
      )
    end)
  end

  defp track_spawned_issue(state, issue, attempt, worker_host, spec, pid, opts) do
    ref = Process.monitor(pid)

    Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

    running =
      Map.put(
        state.running,
        issue.id,
        append_log_event(
          initial_running_entry(issue, attempt, worker_host, spec, pid, ref, opts),
          :agent_dispatched,
          spawned_issue_log_detail(worker_host, spec, attempt)
        )
      )

    %{
      state
      | running: running,
        claimed: MapSet.put(state.claimed, issue.id),
        retry_attempts: Map.delete(state.retry_attempts, issue.id)
    }
  end

  defp initial_running_entry(issue, attempt, worker_host, spec, pid, ref, opts) do
    %{
      pid: pid,
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      provider: spec.provider,
      agent_kind: spec.agent_kind,
      model: spec.model,
      effort: spec.effort,
      workspace_path: nil,
      session_id: nil,
      last_agent_message: nil,
      last_agent_timestamp: nil,
      last_agent_event: nil,
      agent_os_pid: nil,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      last_reported_input_tokens: 0,
      last_reported_output_tokens: 0,
      last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: normalize_retry_attempt(attempt),
      failure_count: Keyword.get(opts, :failures, 0),
      started_at: DateTime.utc_now(),
      log_events: []
    }
  end

  defp spawned_issue_log_detail(worker_host, spec, attempt) do
    source = Map.get(spec, :source) || spec.resolved.source

    "worker_host=#{worker_host || "local"} provider=#{spec.provider || "default"} agent=#{spec.agent_kind} model=#{spec.model || "default"} effort=#{spec.effort || "default"} source=#{source} attempt=#{inspect(attempt)}"
  end

  defp handle_spawn_failure(state, issue, attempt, worker_host, reason, opts) do
    Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
    next_attempt = if is_integer(attempt), do: attempt + 1, else: nil
    failures = Keyword.get(opts, :failures, 0) + 1

    maybe_retry_or_abandon(state, issue.id, next_attempt, failures, %{
      identifier: issue.identifier,
      error: "failed to spawn agent: #{inspect(reason)}",
      worker_host: worker_host,
      failures: failures
    })
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id, running_entry) do
    record = build_completed_record(issue_id, running_entry, state.project_name)
    _ = persist_completed_record(record)
    recent = [record | state.recent_completed] |> Enum.take(@max_recent_completed)

    %{
      state
      | recent_completed: recent,
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp persist_completed_record(record) do
    CompletionStore.put_async(record)
  rescue
    exception ->
      Logger.warning("event=\"completion_store.write\" status=error reason=#{inspect(exception)}")

      :ok
  end

  defp load_recent_completed(project_name) when is_binary(project_name) do
    CompletionStore.recent(project_name, @max_recent_completed)
  rescue
    _ -> []
  end

  defp load_recent_completed(_project_name), do: []

  defp build_completed_record(issue_id, running_entry, project_name) do
    started = Map.get(running_entry, :started_at)
    ended = DateTime.utc_now()
    runtime = if is_struct(started, DateTime), do: DateTime.diff(ended, started, :second), else: nil

    %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier),
      project_name: project_name,
      ended_at: ended,
      started_at: started,
      runtime_seconds: runtime,
      input_tokens: Map.get(running_entry, :input_tokens, 0),
      output_tokens: Map.get(running_entry, :output_tokens, 0),
      total_tokens: Map.get(running_entry, :total_tokens, 0),
      last_event: Map.get(running_entry, :last_agent_event),
      last_message: Map.get(running_entry, :last_agent_message),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      agent_kind: Map.get(running_entry, :agent_kind),
      model: Map.get(running_entry, :model)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    metadata_with_backoff = Map.put_new(metadata, :max_retry_backoff_ms, state.config.agent.max_retry_backoff_ms)
    delay_ms = retry_delay(next_attempt, metadata_with_backoff)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    failures = metadata[:failures] || Map.get(previous_retry, :failures, 0)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            failures: failures
          })
    }
  end

  # A retry timer that fires while dispatch is paused must not consume its
  # attempt: launching is forbidden, and rescheduling would inflate `attempt`
  # (and therefore the backoff) once per cycle for the whole pause. The entry
  # is instead held in place — same `attempt`, same `failures`, no armed timer
  # — and stays in the retry queue reading as due now until `resume`.
  defp hold_retry_attempt(%State{} = state, issue_id, retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{retry_token: ^retry_token} = retry_entry ->
        held = Map.merge(retry_entry, %{timer_ref: nil, held: true})
        %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, held)}

      _ ->
        state
    end
  end

  # Resume re-arms every held entry immediately (0ms) with a fresh token,
  # keeping `attempt` untouched so the backoff schedule picks up where it left
  # off rather than restarting or skipping ahead.
  defp release_held_retries(%State{} = state) do
    %{state | retry_attempts: Map.new(state.retry_attempts, &release_held_retry/1)}
  end

  defp release_held_retry({issue_id, %{held: true} = retry_entry}) do
    retry_token = make_ref()
    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, 0)

    Logger.info("Releasing held retry for issue_id=#{issue_id} issue_identifier=#{retry_entry[:identifier] || issue_id} (attempt #{retry_entry.attempt})")

    released =
      retry_entry
      |> Map.merge(%{
        timer_ref: timer_ref,
        retry_token: retry_token,
        due_at_ms: System.monotonic_time(:millisecond)
      })
      |> Map.delete(:held)

    {issue_id, released}
  end

  defp release_held_retry({issue_id, retry_entry}), do: {issue_id, retry_entry}

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          failures: Map.get(retry_entry, :failures, 0)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues(state.config) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set(state)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host], state_config(state))
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, active_state_set(state), terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host, config) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host, config: config)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host, _config), do: :ok

  defp run_terminal_workspace_cleanup(%State{} = state) do
    config = state_config(state)
    do_terminal_workspace_cleanup(config.tracker.terminal_states, config)
  end

  # Sweep stale workspaces every 6 hours when `workspace.retention_days` is set.
  @workspace_sweep_interval_ms 6 * 60 * 60 * 1_000

  defp schedule_workspace_sweep(config) do
    if is_integer(config.workspace.retention_days) do
      Process.send_after(self(), :workspace_sweep, @workspace_sweep_interval_ms)
    end

    :ok
  end

  defp run_workspace_sweep(%State{} = state) do
    config = state_config(state)
    days = config.workspace.retention_days

    if is_integer(days) do
      root = config.workspace.root
      exclude = running_workspace_paths(state)

      case Workspace.clean_stale(root, days: days, exclude_paths: exclude, config: config) do
        {:ok, []} ->
          :ok

        {:ok, removed} ->
          Logger.info("Workspace sweep removed #{length(removed)} stale workspace(s)")

        {:error, reason} ->
          Logger.warning("Workspace sweep failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp running_workspace_paths(%State{running: running}) do
    running
    |> Enum.flat_map(fn {_id, metadata} ->
      case Map.get(metadata, :workspace_path) do
        path when is_binary(path) -> [path]
        _ -> []
      end
    end)
  end

  defp do_terminal_workspace_cleanup(terminal_states, config) do
    case Tracker.fetch_issues_by_states(terminal_states, config) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier, nil, config)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(%State{} = state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, active_state_set(state), terminal_state_set(state)) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], failures: metadata[:failures] || 0)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp running_entry_failure_count(running_entry) do
    Map.get(running_entry, :failure_count, 0)
  end

  defp state_config(%State{config: nil}), do: load_config()
  defp state_config(%State{config: config}), do: config

  defp agent_command(%{agent: %{kind: kind}} = config) do
    case Agent.section(config, kind) do
      %{command: command} -> command
      _ -> nil
    end
  end

  defp agent_command(_config), do: nil

  defp maybe_override(opts, _key, nil), do: opts
  defp maybe_override(opts, _key, ""), do: opts
  defp maybe_override(opts, key, value) when is_binary(value), do: Keyword.put(opts, key, value)

  # "agent" must stay a valid kind; absent/invalid keeps the current value.
  defp normalized_kind_setting(settings, current) do
    value = Map.get(settings, "agent")

    if Agent.known_kind?(value) do
      value
    else
      current
    end
  end

  # model/effort: absent keeps current; "" clears to nil (agent default).
  defp cleared_setting(settings, key, current) do
    case Map.fetch(settings, key) do
      {:ok, ""} -> nil
      {:ok, value} when is_binary(value) -> value
      _ -> current
    end
  end

  defp max_retry_attempts(%State{} = state), do: state_config(state).agent.max_retry_attempts

  # Reschedule a failed issue, or abandon it once it has failed
  # `max_retry_attempts` times in a row without making progress. Only genuine
  # agent failures (crash, spawn failure, stall) increment `failures`;
  # backpressure ("no slots") and transient poll failures preserve it, so a
  # healthy-but-slot-starved issue is never abandoned.
  # A crashed agent task exits with {exception, stacktrace}. The exception
  # message already carries the agent CLI's own failure text; inspecting the
  # whole tuple buries it behind the struct and the stacktrace, past the
  # truncation the dashboard retry row applies.
  defp format_exit_reason({%{__exception__: true} = exception, stacktrace}) when is_list(stacktrace) do
    Exception.message(exception)
  end

  defp format_exit_reason(reason), do: inspect(reason)

  defp maybe_retry_or_abandon(%State{} = state, issue_id, attempt, failures, metadata)
       when is_integer(failures) do
    if failures > max_retry_attempts(state) do
      abandon_issue(state, issue_id, failures, metadata)
    else
      schedule_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp abandon_issue(%State{} = state, issue_id, failures, metadata) do
    identifier = metadata[:identifier] || issue_id

    Logger.error("Abandoning issue_id=#{issue_id} issue_identifier=#{identifier} after #{failures} consecutive failed attempts; last error=#{inspect(metadata[:error])}")

    post_abandon_comment(state, issue_id, identifier, failures, metadata[:error])
    move_to_failure_state(state, issue_id, identifier)
    cleanup_issue_workspace(identifier, metadata[:worker_host], state_config(state))

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp post_abandon_comment(state, issue_id, identifier, failures, error) do
    body =
      "🛑 Cymphony abandoned this issue after #{failures} consecutive failed agent attempts. " <>
        "Last error: #{inspect(error)}. Move it back to an active state to retry."

    safe_tracker_call(identifier, "comment", fn ->
      Tracker.create_comment(issue_id, body, state_config(state))
    end)
  end

  defp move_to_failure_state(state, issue_id, identifier) do
    case state_config(state).agent.failure_state do
      failure_state when is_binary(failure_state) and failure_state != "" ->
        safe_tracker_call(identifier, "failure-state move", fn ->
          Tracker.update_issue_state(issue_id, failure_state, state_config(state))
        end)

      _ ->
        :ok
    end
  end

  # Best-effort tracker side effect during abandonment: never let a tracker
  # error (or raise) crash the orchestrator, but log it rather than swallow it.
  defp safe_tracker_call(identifier, label, fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Abandon #{label} failed for #{identifier}: #{inspect(reason)}")
    end
  rescue
    exception -> Logger.warning("Abandon #{label} raised for #{identifier}: #{inspect(exception)}")
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt, Map.get(metadata, :max_retry_backoff_ms, 300_000))
    end
  end

  defp failure_retry_delay(attempt, max_retry_backoff_ms) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    worker = state_config(state).worker

    Dispatch.select_worker_host(
      state.running,
      worker.ssh_hosts,
      worker.max_concurrent_agents_per_host,
      preferred_worker_host
    )
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || state_config(state).agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  defp extract_providers(%{agent: %{kind: kind}} = config) do
    case Agent.section(config, kind) do
      %{providers: [_ | _] = providers} -> providers
      %{provider: provider} when is_binary(provider) and provider != "" -> [provider]
      _ -> []
    end
  end

  defp extract_providers(_config), do: []

  # When the issue's resolved kind matches the project's configured kind, use
  # the rotating provider list; when a label switches kinds, fall back to that
  # kind's configured provider (rotation lists are per-kind config).
  defp select_provider_for_kind(%State{config: config} = state, kind) do
    if is_map(config) and config.agent.kind == kind do
      select_provider(state)
    else
      case config do
        %{} -> Agent.section(config, kind).provider
        _ -> select_provider(state)
      end
    end
  end

  defp select_provider(%State{providers: [_ | _] = providers}) do
    Enum.random(providers)
  end

  defp select_provider(%State{config: config}) when is_map(config) do
    case extract_providers(config) do
      [provider | _] -> provider
      [] -> nil
    end
  end

  defp select_provider(_state), do: nil

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    GenServer.call(server, :request_refresh)
  catch
    :exit, _ -> :unavailable
  end

  @spec pause(GenServer.server()) :: :ok | :unavailable
  def pause(server) do
    GenServer.call(server, :pause)
  catch
    :exit, _ -> :unavailable
  end

  @spec resume(GenServer.server()) :: :ok | :unavailable
  def resume(server) do
    GenServer.call(server, :resume)
  catch
    :exit, _ -> :unavailable
  end

  @spec set_concurrency(GenServer.server(), pos_integer()) ::
          :ok | {:error, :invalid_concurrency} | :unavailable
  def set_concurrency(server, n) when is_integer(n) and n > 0 do
    GenServer.call(server, {:set_concurrency, n})
  catch
    :exit, _ -> :unavailable
  end

  def set_concurrency(_server, _n), do: {:error, :invalid_concurrency}

  @spec set_providers(GenServer.server(), [String.t()]) ::
          :ok | {:error, :invalid_providers} | :unavailable
  def set_providers(server, providers) when is_list(providers) and providers != [] do
    GenServer.call(server, {:set_providers, providers})
  catch
    :exit, _ -> :unavailable
  end

  def set_providers(_server, _providers), do: {:error, :invalid_providers}

  @doc """
  Update the runtime agent defaults (`"agent"` kind, `"model"`, `"effort"`)
  for subsequent dispatches. Empty-string model/effort clear to nil (agent
  default); an invalid kind keeps the current one. Providers are re-extracted
  because switching kinds switches the rotation source section.
  """
  @spec set_agent_settings(GenServer.server(), map()) :: :ok | :unavailable
  def set_agent_settings(server, settings) when is_map(settings) do
    GenServer.call(server, {:set_agent_settings, settings})
  catch
    :exit, _ -> :unavailable
  end

  @doc """
  Kill a running session and immediately re-dispatch it with pinned run-spec
  overrides (`:provider`, `:model`, `:effort`, `:agent_kind` — all optional,
  empty/absent keys keep label/config-resolved values).
  """
  @spec set_issue_run_spec(GenServer.server(), String.t(), map()) ::
          :ok | {:error, :not_running} | :unavailable
  def set_issue_run_spec(server, issue_id, overrides)
      when is_binary(issue_id) and is_map(overrides) do
    GenServer.call(server, {:set_issue_run_spec, issue_id, overrides})
  catch
    :exit, _ -> :unavailable
  end

  @spec reorder_queue(GenServer.server(), [String.t()]) ::
          :ok | {:error, :invalid_queue_order} | :unavailable
  def reorder_queue(server, order) when is_list(order) do
    GenServer.call(server, {:reorder_queue, order})
  catch
    :exit, _ -> :unavailable
  end

  def reorder_queue(_server, _order), do: {:error, :invalid_queue_order}

  @spec set_queue_run_spec(GenServer.server(), String.t(), map()) ::
          :ok | {:error, :invalid_queue_pin} | :unavailable
  def set_queue_run_spec(server, issue_key, pin)
      when is_binary(issue_key) and is_map(pin) do
    GenServer.call(server, {:set_queue_run_spec, issue_key, pin})
  catch
    :exit, _ -> :unavailable
  end

  def set_queue_run_spec(_server, _issue_key, _pin), do: {:error, :invalid_queue_pin}

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    GenServer.call(server, :snapshot, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, _ -> :unavailable
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue: Map.get(metadata, :issue),
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          provider: Map.get(metadata, :provider),
          agent_kind: Map.get(metadata, :agent_kind),
          model: Map.get(metadata, :model),
          effort: Map.get(metadata, :effort),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          agent_os_pid: Map.get(metadata, :agent_os_pid),
          input_tokens: Map.get(metadata, :input_tokens, 0),
          output_tokens: Map.get(metadata, :output_tokens, 0),
          total_tokens: Map.get(metadata, :total_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_agent_timestamp: Map.get(metadata, :last_agent_timestamp),
          last_agent_message: Map.get(metadata, :last_agent_message),
          last_agent_event: Map.get(metadata, :last_agent_event),
          log_events: Map.get(metadata, :log_events, []),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          # A held entry keeps its original (now past) `due_at_ms`, so this
          # clamps to 0 and reads as "due now" forever. `held` is what tells
          # the status surfaces apart: parked until resume, versus due this
          # instant. Without it a paused board also churns, because a
          # presenter deriving `due_at` from `now + 0` moves every load.
          held: Map.get(retry, :held) == true,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    waiting = snapshot_waiting_rows(state)

    {:reply,
     %{
       project_name: state.project_name,
       workspace_root: state.config.workspace.root,
       stall_timeout_ms: state.config.agent.stall_timeout_ms,
       running: running,
       waiting: waiting,
       retrying: retrying,
       recent_completed: state.recent_completed,
       token_totals: state.token_totals,
       rate_limits: Map.get(state, :rate_limits),
       providers: state.providers || [],
       agent_kind: state.config.agent.kind,
       agent_model: state.config.agent.model,
       agent_effort: state.config.agent.effort,
       agent_command: agent_command(state.config),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms,
         paused: state.paused,
         max_concurrent_agents: state.max_concurrent_agents || state.config.agent.max_concurrent_agents
       }
     }, state}
  end

  def handle_call(:pause, _from, state) do
    state = %{state | paused: true}
    notify_dashboard()
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    state = release_held_retries(%{state | paused: false})
    notify_dashboard()
    {:reply, :ok, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  def handle_call({:kill_issue, issue_id}, _from, state) do
    if Map.has_key?(state.running, issue_id) do
      state = terminate_running_issue(state, issue_id, false)
      notify_dashboard()
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  def handle_call({:dispatch_issue_for_test, issue}, _from, state) do
    {:reply, :ok, do_dispatch_issue(state, issue, nil, nil, [])}
  end

  def handle_call(:run_poll_cycle_for_test, _from, state) do
    state = refresh_runtime_config(state)
    {:reply, :ok, maybe_dispatch(state)}
  end

  def handle_call({:retry_issue_now, issue_id}, _from, state) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        {:reply, {:error, :not_retrying}, state}

      %{attempt: attempt, timer_ref: timer_ref} = retry_entry ->
        if is_reference(timer_ref) do
          Process.cancel_timer(timer_ref)
        end

        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          failures: Map.get(retry_entry, :failures, 0)
        }

        state = %{
          state
          | retry_attempts: Map.delete(state.retry_attempts, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id)
        }

        {:noreply, new_state} = handle_retry_issue(state, issue_id, attempt, metadata)
        notify_dashboard()
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:set_concurrency, n}, _from, state) when is_integer(n) and n > 0 do
    Logger.info("Concurrency updated: max_concurrent_agents=#{n}")
    notify_dashboard()
    {:reply, :ok, %{state | max_concurrent_agents: n}}
  end

  def handle_call({:set_concurrency, _n}, _from, state) do
    {:reply, {:error, :invalid_concurrency}, state}
  end

  def handle_call({:set_providers, providers}, _from, state)
      when is_list(providers) and providers != [] do
    Logger.info("Providers updated: providers=#{Enum.join(providers, ",")}")

    new_config =
      case state.config do
        nil ->
          state.config

        config ->
          kind = config.agent.kind
          section = Agent.section(config, kind)
          Agent.put_section(config, kind, %{section | provider: hd(providers), providers: providers})
      end

    notify_dashboard()
    {:reply, :ok, %{state | providers: providers, config: new_config}}
  end

  def handle_call({:set_providers, _providers}, _from, state) do
    {:reply, {:error, :invalid_providers}, state}
  end

  def handle_call({:set_agent_settings, settings}, _from, state) do
    new_config =
      case state.config do
        nil ->
          state.config

        config ->
          agent = config.agent

          agent = %{
            agent
            | kind: normalized_kind_setting(settings, agent.kind),
              model: cleared_setting(settings, "model", agent.model),
              effort: cleared_setting(settings, "effort", agent.effort)
          }

          %{config | agent: agent}
      end

    runtime_agent =
      case new_config do
        %{agent: agent} -> %{kind: agent.kind, model: agent.model, effort: agent.effort}
        _ -> nil
      end

    Logger.info("Agent settings updated: #{inspect(Map.take(settings, ["agent", "model", "effort"]))}")
    notify_dashboard()
    {:reply, :ok, %{state | config: new_config, providers: extract_providers(new_config), runtime_agent: runtime_agent}}
  end

  def handle_call({:set_issue_run_spec, issue_id, overrides}, _from, state) do
    case Map.get(state.running, issue_id) do
      nil ->
        {:reply, {:error, :not_running}, state}

      running_entry ->
        issue = running_entry.issue
        worker_host = Map.get(running_entry, :worker_host)

        state = terminate_running_issue(state, issue_id, false)

        Logger.info("Run-spec override for #{issue_context(issue)}: #{inspect(Map.take(overrides, [:provider, :model, :effort, :agent_kind]))}")

        dispatch_opts =
          []
          |> maybe_override(:provider_override, overrides[:provider])
          |> maybe_override(:model_override, overrides[:model])
          |> maybe_override(:effort_override, overrides[:effort])
          |> maybe_override(:agent_kind_override, overrides[:agent_kind])

        new_state = do_dispatch_issue(state, issue, nil, worker_host, dispatch_opts)
        notify_dashboard()
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:reorder_queue, order}, _from, state) when is_list(order) do
    if valid_queue_order?(order) do
      waiting = Queue.apply_drag(state.waiting || [], order)
      persist_project_queue(state.project_name, %{"queue_order" => order})
      notify_dashboard()
      {:reply, :ok, %{state | waiting: waiting, queue_order: order}}
    else
      {:reply, {:error, :invalid_queue_order}, state}
    end
  end

  def handle_call({:reorder_queue, _order}, _from, state) do
    {:reply, {:error, :invalid_queue_order}, state}
  end

  def handle_call({:set_queue_pin, issue_key, pin}, from, state) do
    handle_call({:set_queue_run_spec, issue_key, pin}, from, state)
  end

  def handle_call({:set_queue_run_spec, issue_key, pin}, _from, state)
      when is_binary(issue_key) and issue_key != "" and is_map(pin) do
    queue_pins =
      case CymphonyConfig.update_project_queue_pin(state.project_name, issue_key, pin) do
        {:ok, persisted_pins} ->
          parse_loaded_queue_pins(%{"queue_pins" => persisted_pins})

        {:error, reason} ->
          Logger.warning("event=\"queue.persist\" status=error reason=#{inspect(reason)}")
          apply_queue_pin(state.queue_pins, issue_key, pin)
      end

    notify_dashboard()
    {:reply, :ok, %{state | queue_pins: queue_pins}}
  end

  def handle_call({:set_queue_run_spec, _issue_key, _pin}, _from, state) do
    {:reply, {:error, :invalid_queue_pin}, state}
  end

  defp integrate_agent_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = Tokens.extract_token_delta(running_entry, update)
    input_tokens = Map.get(running_entry, :input_tokens, 0)
    output_tokens = Map.get(running_entry, :output_tokens, 0)
    total_tokens = Map.get(running_entry, :total_tokens, 0)
    agent_os_pid = Map.get(running_entry, :agent_os_pid)
    last_reported_input = Map.get(running_entry, :last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    updated_entry =
      Map.merge(running_entry, %{
        last_agent_timestamp: timestamp,
        last_agent_message: summarize_agent_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_agent_event: event,
        agent_os_pid: agent_os_pid_for_update(agent_os_pid, update),
        input_tokens: input_tokens + token_delta.input_tokens,
        output_tokens: output_tokens + token_delta.output_tokens,
        total_tokens: total_tokens + token_delta.total_tokens,
        last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      })

    updated_entry =
      append_log_event(
        updated_entry,
        event,
        update[:payload] || update[:raw]
      )

    {updated_entry, token_delta}
  end

  defp agent_os_pid_for_update(_existing, %{agent_os_pid: pid})
       when is_binary(pid),
       do: pid

  defp agent_os_pid_for_update(_existing, %{agent_os_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp agent_os_pid_for_update(_existing, %{agent_os_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp agent_os_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_agent_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    drop_harness_stream(issue_id)
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  # EP-STREAM-DROP
  defp drop_harness_stream(issue_id) when is_binary(issue_id) do
    HarnessStream.drop(issue_id)
  rescue
    UndefinedFunctionError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp drop_harness_stream(_issue_id), do: :ok

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    token_totals =
      Tokens.apply_token_delta(
        state.token_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | token_totals: token_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  # Loads config and prompt_template from the project-specific WorkflowStore.
  # Returns {config, prompt_template}.
  # Falls back to global Config.settings!() for legacy single-project mode
  # or when the project store is not yet registered.
  defp load_project_config_from_store(nil) do
    {Config.settings!(), Config.workflow_prompt()}
  end

  defp load_project_config_from_store(project_name) when is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :workflow_store) do
      nil ->
        Logger.warning("Project workflow store not found for '#{project_name}', falling back to global config")
        {Config.settings!(), Config.workflow_prompt()}

      store_pid ->
        parse_project_workflow_store(project_name, WorkflowStore.current(store_pid))
    end
  end

  defp parse_project_workflow_store(
         project_name,
         {:ok, %{config: raw_config, prompt_template: prompt_template}}
       )
       when is_map(raw_config) do
    parse_project_workflow_config(project_name, raw_config, prompt_template)
  end

  defp parse_project_workflow_store(project_name, {:error, reason}) do
    Logger.warning("Workflow store returned error for project '#{project_name}': #{inspect(reason)}; falling back to global config")

    {Config.settings!(), Config.workflow_prompt()}
  end

  defp parse_project_workflow_config(project_name, raw_config, prompt_template) do
    case Config.Schema.parse(raw_config) do
      {:ok, settings} ->
        {settings, prompt_template}

      {:error, reason} ->
        Logger.warning("Failed to parse config for project '#{project_name}': #{inspect(reason)}; falling back to global config")

        {Config.settings!(), Config.workflow_prompt()}
    end
  end

  # Loads config from the project's WorkflowStore, using project_name from state.
  defp load_project_config(%State{project_name: project_name}) do
    case ProjectSupervisor.lookup(project_name, :workflow_store) do
      nil ->
        Config.settings()

      store_pid ->
        case WorkflowStore.current(store_pid) do
          {:ok, %{config: raw_config}} when is_map(raw_config) ->
            Config.Schema.parse(raw_config)

          _ ->
            Config.settings()
        end
    end
  end

  # Fallback: loads config from the global store.
  # Used by zero-arity helpers (terminal_state_set/0, active_state_set/0)
  # which are called from test helpers that don't carry state.
  defp load_config do
    Config.settings!()
  end

  defp refresh_runtime_config(%State{config: nil} = state) do
    case load_project_config(state) do
      {:ok, config} ->
        config =
          config
          |> apply_config_json_overrides(state.project_name)
          |> apply_runtime_agent_overrides(state.runtime_agent)
          |> then(&apply_runtime_provider_overrides(nil, &1, state.providers))

        %{
          state
          | config: config,
            poll_interval_ms: config.polling.interval_ms,
            max_concurrent_agents: state.max_concurrent_agents || config.agent.max_concurrent_agents,
            providers: preserve_providers(state.providers, config)
        }

      {:error, _} ->
        state
    end
  end

  defp refresh_runtime_config(%State{} = state) do
    config =
      case load_project_config(state) do
        {:ok, new_config} ->
          new_config
          |> apply_config_json_overrides(state.project_name)
          |> apply_runtime_agent_overrides(state.runtime_agent)
          |> then(&apply_runtime_provider_overrides(state.config, &1, state.providers))

        {:error, _} ->
          state.config
      end

    %{
      state
      | config: config,
        poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: state.max_concurrent_agents || config.agent.max_concurrent_agents,
        providers: preserve_providers(state.providers, config)
    }
  end

  defp preserve_providers([_ | _] = providers, _config), do: providers
  defp preserve_providers(_, config), do: extract_providers(config)

  # Overlay ~/.cymphony/config.json so snapshot follows persisted agent/key
  # even when the temp WORKFLOW.md is stale. load/find failure is a no-op.
  defp apply_config_json_overrides(config, project_name)
       when is_map(config) and is_binary(project_name) do
    with {:ok, file_config} <- CymphonyConfig.load(),
         {:ok, project} <- CymphonyConfig.find_project(file_config, project_name) do
      overlay_config_json_project(config, project)
    else
      _ -> config
    end
  end

  defp apply_config_json_overrides(config, _project_name), do: config

  defp overlay_config_json_project(config, project) when is_map(project) do
    agent = config.agent

    agent =
      if Agent.known_kind?(project["agent"]) do
        %{agent | kind: project["agent"]}
      else
        agent
      end

    agent =
      case Map.fetch(project, "model") do
        {:ok, model} when is_binary(model) ->
          %{agent | model: empty_to_nil(model)}

        _ ->
          agent
      end

    agent =
      case Map.fetch(project, "effort") do
        {:ok, effort} when is_binary(effort) ->
          %{agent | effort: empty_to_nil(effort)}

        _ ->
          agent
      end

    tracker =
      case project["linear_api_key"] do
        key when is_binary(key) and key != "" ->
          %{config.tracker | api_key: key}

        _ ->
          config.tracker
      end

    %{config | agent: agent, tracker: tracker}
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp apply_runtime_agent_overrides(config, %{kind: kind, model: model, effort: effort}) when is_map(config) do
    %{config | agent: %{config.agent | kind: kind, model: model, effort: effort}}
  end

  defp apply_runtime_agent_overrides(config, _runtime_agent), do: config

  # Runtime set_providers updates live in State.providers and the active kind
  # section. A WORKFLOW.md reload must not wipe those overrides, including
  # provider lists previously written onto now-inactive kind sections.
  defp apply_runtime_provider_overrides(old_config, new_config, runtime_providers) when is_map(new_config) do
    active_kind = new_config.agent.kind

    Enum.reduce(Agent.known_kinds(), new_config, fn kind, acc ->
      old_sec = if is_map(old_config), do: Agent.section(old_config, kind), else: %{}
      new_sec = Agent.section(acc, kind)

      cond do
        kind == active_kind and match?([_ | _], runtime_providers) ->
          put_section_providers(acc, kind, new_sec, hd(runtime_providers), runtime_providers)

        runtime_provider_fields?(old_sec) ->
          put_section_providers(acc, kind, new_sec, Map.get(old_sec, :provider), Map.get(old_sec, :providers, []))

        true ->
          acc
      end
    end)
  end

  defp runtime_provider_fields?(%{providers: [_ | _]}), do: true
  defp runtime_provider_fields?(%{provider: provider}) when is_binary(provider) and provider != "", do: true
  defp runtime_provider_fields?(_section), do: false

  defp put_section_providers(config, kind, section, provider, providers) do
    Agent.put_section(config, kind, %{section | provider: provider, providers: providers})
  end

  defp retry_candidate_issue?(%Issue{} = issue, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running, state)
  end

  defp apply_agent_token_delta(
         %{token_totals: token_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | token_totals: Tokens.apply_token_delta(token_totals, token_delta)}
  end

  defp apply_agent_token_delta(state, _token_delta), do: state

  defp apply_rate_limits(%State{} = state, update) when is_map(update) do
    case Tokens.extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_rate_limits(state, _update), do: state

  defp append_log_event(running_entry, event, _message)
       when event in [:harness_heartbeat, :harness_stdout],
       do: running_entry

  defp append_log_event(running_entry, event, message) when is_map(running_entry) do
    log_events = [
      %{at: DateTime.utc_now(), event: event, message: message}
      | Map.get(running_entry, :log_events, [])
    ]

    Map.put(running_entry, :log_events, Enum.take(log_events, 50))
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp snapshot_waiting_rows(%State{} = state) do
    waiting = state.waiting || []

    Enum.flat_map(waiting, fn
      %Issue{} = issue ->
        pin = queue_pin_for(state, issue)

        [
          %{
            issue_id: issue.id,
            identifier: issue.identifier,
            issue: issue,
            priority: issue.priority,
            state: issue.state,
            created_at: issue.created_at,
            agent_kind: pin_field(pin, :agent_kind),
            model: pin_field(pin, :model),
            effort: pin_field(pin, :effort)
          }
        ]

      _ ->
        []
    end)
  end

  # Seeded in `init/1` so the very first `maybe_dispatch/1` — scheduled with a
  # 0ms tick before any `handle_call` can be delivered — already sees the
  # operator's persisted pause instead of dispatching once and pausing after.
  defp load_project_dispatch_paused(project_name) do
    case CymphonyConfig.load() do
      {:ok, config} ->
        CymphonyConfig.dispatch_paused?(config, project_name)

      {:error, reason} ->
        warn_unreadable_pause_seed(project_name, reason)
        false
    end
  end

  # No config.json at all is the normal legacy WORKFLOW.md setup: there is no
  # persisted pause to lose, so it boots unpaused without comment. A config
  # that exists but cannot be read or parsed is different — the seed silently
  # discards an operator's stop-work order and the project starts dispatching
  # agents on the very first tick — so that case is always logged, since the
  # only other evidence is the sessions that appear.
  defp warn_unreadable_pause_seed(project_name, reason) do
    if CymphonyConfig.exists?() do
      Logger.warning("Could not read the persisted dispatch-pause flag for project=#{project_name || "default"} (#{inspect(reason)}); starting unpaused")
    end

    :ok
  end

  defp load_project_queue(project_name) do
    case CymphonyConfig.load() do
      {:ok, config} ->
        case project_for_queue(config, project_name) do
          {:ok, project} -> parse_project_queue(project)
          _ -> empty_queue_fields()
        end

      _ ->
        empty_queue_fields()
    end
  end

  defp empty_queue_fields, do: {nil, %{}, %{}}

  defp project_for_queue(config, project_name) when is_binary(project_name) do
    CymphonyConfig.find_project(config, project_name)
  end

  defp project_for_queue(config, _project_name) do
    case CymphonyConfig.projects(config) do
      [project] when is_map(project) -> {:ok, project}
      _ -> {:error, :project_not_found}
    end
  end

  defp parse_project_queue(project) do
    {
      parse_loaded_queue_order(project),
      parse_loaded_queue_pins(project),
      parse_loaded_priority_seen(project)
    }
  end

  defp parse_loaded_queue_order(project) do
    case Map.fetch(project, "queue_order") do
      {:ok, order} when is_list(order) -> Enum.filter(order, &is_binary/1)
      _ -> nil
    end
  end

  defp parse_loaded_queue_pins(project) do
    case Map.get(project, "queue_pins") do
      pins when is_map(pins) ->
        Enum.reduce(pins, %{}, &put_loaded_queue_pin/2)

      _ ->
        %{}
    end
  end

  defp put_loaded_queue_pin({key, pin}, acc) when is_binary(key) and is_map(pin) do
    case normalize_pin_map(pin) do
      parsed when map_size(parsed) == 0 -> acc
      parsed -> Map.put(acc, key, parsed)
    end
  end

  defp put_loaded_queue_pin(_entry, acc), do: acc

  defp parse_loaded_priority_seen(project) do
    case Map.get(project, "queue_priority_seen") do
      seen when is_map(seen) ->
        Enum.reduce(seen, %{}, fn
          {key, value}, acc when is_binary(key) and (is_integer(value) or is_nil(value)) ->
            Map.put(acc, key, value)

          _, acc ->
            acc
        end)

      _ ->
        %{}
    end
  end

  defp maybe_persist_queue_order(%State{} = state, prev_order, prev_seen) do
    if persist_queue_order?(state, prev_order, prev_seen) do
      persist_project_queue(state.project_name, %{
        "queue_order" => state.queue_order || [],
        "queue_priority_seen" => state.queue_priority_seen
      })
    end

    state
  end

  defp persist_queue_order?(%State{} = state, prev_order, prev_seen) do
    changed? = state.queue_order != prev_order or state.queue_priority_seen != prev_seen
    changed? and not (is_nil(prev_order) and state.queue_order in [nil, []])
  end

  defp persist_project_queue(project_name, attrs) when is_map(attrs) and map_size(attrs) > 0 do
    case CymphonyConfig.update_project_queue(project_name, attrs) do
      {:ok, _config} ->
        :ok

      {:error, reason} ->
        Logger.warning("event=\"queue.persist\" status=error reason=#{inspect(reason)}")
        :ok
    end
  end

  defp persist_project_queue(_project_name, _attrs), do: :ok

  defp valid_queue_order?(order) when is_list(order) do
    Enum.all?(order, fn key -> is_binary(key) and key != "" end)
  end

  defp valid_queue_order?(_order), do: false

  defp queue_pin_for(%State{queue_pins: pins}, %Issue{} = issue) when is_map(pins) do
    Map.get(pins, Queue.issue_key(issue)) || Map.get(pins, issue.id) || %{}
  end

  defp queue_pin_for(_state, _issue), do: %{}

  defp pin_field(pin, :agent_kind) when is_map(pin) do
    value = pin_raw(pin, :agent_kind) || pin_raw(pin, "agent_kind") || pin_raw(pin, "kind")

    if Agent.known_kind?(value), do: value, else: nil
  end

  defp pin_field(pin, key) when is_map(pin) and is_atom(key) do
    value = pin_raw(pin, key) || pin_raw(pin, Atom.to_string(key))
    if skip_pin_value?(value), do: nil, else: value
  end

  defp pin_field(_pin, _key), do: nil

  defp pin_raw(pin, key) do
    case Map.get(pin, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp skip_pin_value?(value) when value in [nil, "", "keep"], do: true
  defp skip_pin_value?(value) when is_binary(value), do: false
  defp skip_pin_value?(_value), do: true

  defp merge_queue_pin(existing, incoming) when is_map(existing) and is_map(incoming) do
    existing
    |> normalize_pin_map()
    |> put_pin_field(:agent_kind, incoming_pin_value(incoming, :agent_kind))
    |> put_pin_field(:model, incoming_pin_value(incoming, :model))
    |> put_pin_field(:effort, incoming_pin_value(incoming, :effort))
  end

  defp merge_queue_pin(_existing, incoming) when is_map(incoming) do
    merge_queue_pin(%{}, incoming)
  end

  defp incoming_pin_value(incoming, :agent_kind) do
    value =
      pin_raw(incoming, :agent_kind) || pin_raw(incoming, "agent_kind") ||
        pin_raw(incoming, "kind") || pin_raw(incoming, :kind)

    cond do
      skip_pin_value?(value) -> :skip
      Agent.known_kind?(value) -> value
      true -> :skip
    end
  end

  defp incoming_pin_value(incoming, key) do
    value = pin_raw(incoming, key) || pin_raw(incoming, Atom.to_string(key))
    if skip_pin_value?(value), do: :skip, else: value
  end

  defp put_pin_field(pin, _key, :skip), do: pin
  defp put_pin_field(pin, key, value), do: Map.put(pin, key, value)

  defp normalize_pin_map(pin) do
    %{}
    |> put_normalized_pin(:agent_kind, pin_field(pin, :agent_kind))
    |> put_normalized_pin(:model, pin_field(pin, :model))
    |> put_normalized_pin(:effort, pin_field(pin, :effort))
  end

  defp put_normalized_pin(pin, _key, nil), do: pin
  defp put_normalized_pin(pin, key, value), do: Map.put(pin, key, value)

  defp apply_queue_pin(pins, issue_key, pin) when is_map(pins) and is_map(pin) do
    if pin == %{} do
      Map.delete(pins, issue_key)
    else
      merged = merge_queue_pin(Map.get(pins, issue_key, %{}), pin)

      if map_size(merged) == 0 do
        Map.delete(pins, issue_key)
      else
        Map.put(pins, issue_key, merged)
      end
    end
  end
end
