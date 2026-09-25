defmodule CymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured coding
  agent.
  """

  require Logger
  alias CymphonyElixir.Agent.Runner
  alias CymphonyElixir.{Config, HarnessStream, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @harness_heartbeat_interval_ms 2_000

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, agent_update_recipient \\ nil, opts \\ []) do
    config = Keyword.get(opts, :config)

    agent_update_recipient =
      case Keyword.get(opts, :run_token) do
        token when is_reference(token) -> {agent_update_recipient, token}
        _ -> agent_update_recipient
      end

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_hosts = if config, do: config.worker.ssh_hosts, else: Config.settings!().worker.ssh_hosts
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), worker_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        # Reason first: this message becomes the retry-queue error text, which
        # the dashboard truncates, and the issue context is already in the log
        # line above.
        raise RuntimeError, "Agent run failed: #{inspect(reason)} (#{issue_context(issue)})"
    end
  end

  defp run_on_worker_host(issue, agent_update_recipient, opts, worker_host) do
    provider_override = Keyword.get(opts, :provider_override)
    workspace_opts = Keyword.take(opts, [:config, :port_supervisor])

    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} provider=#{provider_override || "default"}")

    case Workspace.create_for_issue(issue, worker_host, workspace_opts) do
      {:ok, workspace} ->
        send_worker_runtime_info(agent_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host, workspace_opts) do
            run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host, workspace_opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and (is_pid(recipient) or is_tuple(recipient)) do
    if is_map(message) and message[:event] == :harness_stdout do
      # EP-STREAM: live CLI stdout is ring-buffered; do not forward :harness_stdout to the orchestrator.
      HarnessStream.append(issue_id, to_string(message[:raw] || ""))
      maybe_send_harness_heartbeat(recipient, issue_id, message)
    else
      send_to_recipient(recipient, {:agent_worker_update, issue_id, message})
    end

    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp maybe_send_harness_heartbeat(recipient, issue_id, message) do
    now_ms = System.monotonic_time(:millisecond)
    key = {:harness_heartbeat, issue_id}

    case Process.get(key) do
      last_ms when is_integer(last_ms) and now_ms - last_ms < @harness_heartbeat_interval_ms ->
        :ok

      _ ->
        Process.put(key, now_ms)
        timestamp = message[:timestamp] || DateTime.utc_now()

        send_to_recipient(
          recipient,
          {:agent_worker_update, issue_id, %{event: :harness_heartbeat, timestamp: timestamp}}
        )

        :ok
    end
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and (is_pid(recipient) or is_tuple(recipient)) and is_binary(workspace) do
    send_to_recipient(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_to_recipient({recipient, token}, {tag, issue_id, message}) do
    send(recipient, {tag, issue_id, token, message})
  end

  defp send_to_recipient(recipient, message), do: send(recipient, message)

  defp run_agent_turns(workspace, issue, agent_update_recipient, opts, worker_host) do
    config = Keyword.get(opts, :config)

    max_turns =
      Keyword.get(opts, :max_turns) ||
        if config, do: config.agent.max_turns, else: Config.settings!().agent.max_turns

    issue_state_fetcher =
      Keyword.get(opts, :issue_state_fetcher) ||
        if config,
          do: &Tracker.fetch_issue_states_by_ids(&1, config),
          else: &Tracker.fetch_issue_states_by_ids/1

    session_opts =
      [worker_host: worker_host, config: config] ++
        Keyword.take(opts, [:agent_kind, :model, :effort, :provider_override, :port_supervisor])

    with {:ok, session} <- Runner.start_session(workspace, session_opts) do
      try do
        ctx = %{
          workspace: workspace,
          recipient: agent_update_recipient,
          opts: opts,
          issue_state_fetcher: issue_state_fetcher,
          max_turns: max_turns,
          config: config
        }

        do_run_agent_turns(session, issue, 1, ctx)
      after
        Runner.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(agent_session, issue, turn_number, ctx) do
    %{
      workspace: workspace,
      recipient: agent_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      config: config
    } = ctx

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, config)

    with {:ok, turn_result} <-
           Runner.run_turn(
             agent_session,
             prompt,
             issue,
             on_message: agent_message_handler(agent_update_recipient, issue),
             config: config
           ) do
      session_id = turn_result[:session_id]

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher, config) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          # Resume the agent session for the next turn
          agent_session = %{agent_session | session_id: session_id}
          do_run_agent_turns(agent_session, refreshed_issue, turn_number + 1, ctx)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, config) do
    opts =
      if config do
        Keyword.put(opts, :config, config)
      else
        opts
      end

    PromptBuilder.build_prompt(issue, opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _config) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, config)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state, config) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _config), do: {:done, issue}

  defp active_issue_state?(state_name, config) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    active_states =
      if config, do: config.tracker.active_states, else: Config.settings!().tracker.active_states

    active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _config), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
