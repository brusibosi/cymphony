defmodule CymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias CymphonyElixir.{Config, Orchestrator, ProjectSupervisor, StatusDashboard}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {project_count, project_snapshots} = aggregate_project_snapshots(snapshot_timeout_ms)

    case project_snapshots do
      [] when project_count == 0 ->
        legacy_payload(orchestrator, snapshot_timeout_ms, generated_at)

      [] ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}

      snapshots ->
        merged = merge_project_snapshots(snapshots)

        projects =
          Enum.map(snapshots, fn %{project_name: name, snapshot: snap} ->
            project_from_snapshot(name, snap)
          end)

        flat_running = Enum.flat_map(projects, & &1.running)
        flat_retrying = Enum.flat_map(projects, & &1.retrying)
        flat_waiting = Enum.flat_map(projects, & &1.waiting)

        %{
          generated_at: generated_at,
          counts: payload_counts(flat_running, flat_retrying, flat_waiting),
          running: flat_running,
          retrying: flat_retrying,
          recent_completed: Enum.map(merged.recent_completed, &completed_entry_payload/1),
          token_totals: normalize_token_totals(merged.token_totals),
          rate_limits: merged.rate_limits,
          polling: merged.polling,
          projects: projects
        }
    end
  end

  @spec count_breakdowns([map()]) :: %{
          by_state: %{String.t() => non_neg_integer()},
          by_kind: %{String.t() => non_neg_integer()}
        }
  def count_breakdowns(running) when is_list(running) do
    Enum.reduce(running, %{by_state: %{}, by_kind: %{}}, fn
      entry, acc when is_map(entry) ->
        %{
          acc
          | by_state: increment_count(acc.by_state, breakdown_state(entry)),
            by_kind: increment_count(acc.by_kind, breakdown_kind(entry))
        }

      _entry, acc ->
        acc
    end)
  end

  @spec session_tokens_per_second(number() | nil, number() | nil) :: float()
  def session_tokens_per_second(total_tokens, seconds) do
    total = numeric_or_zero(total_tokens)
    elapsed = numeric_or_zero(seconds)

    if total == 0 do
      0.0
    else
      total / max(elapsed, 1)
    end
  end

  @spec completed_entry_payload(map()) :: map()
  def completed_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      project_name: Map.get(entry, :project_name),
      ended_at: iso8601(Map.get(entry, :ended_at)),
      started_at: iso8601(Map.get(entry, :started_at)),
      runtime_seconds: Map.get(entry, :runtime_seconds),
      input_tokens: Map.get(entry, :input_tokens, 0),
      output_tokens: Map.get(entry, :output_tokens, 0),
      total_tokens: Map.get(entry, :total_tokens, 0),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      agent_kind: Map.get(entry, :agent_kind),
      model: Map.get(entry, :model)
    }
  end

  @spec projects_payload() :: [map()]
  def projects_payload do
    {_count, snapshots} = aggregate_project_snapshots(5_000)

    Enum.map(snapshots, fn %{project_name: project_name, snapshot: snapshot} ->
      %{
        name: project_name,
        running: length(snapshot.running),
        retrying: length(snapshot.retrying)
      }
    end)
  end

  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, project_name \\ nil)

  @spec issue_payload(String.t(), GenServer.name(), timeout(), String.t() | nil) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, _orchestrator, snapshot_timeout_ms, project_name)
      when is_binary(issue_identifier) and is_binary(project_name) do
    case ProjectSupervisor.lookup(project_name, :orchestrator) do
      nil ->
        {:error, :issue_not_found}

      pid ->
        pid
        |> Orchestrator.snapshot(snapshot_timeout_ms)
        |> maybe_issue_payload_from_snapshot(issue_identifier) || {:error, :issue_not_found}
    end
  end

  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, nil)
      when is_binary(issue_identifier) do
    # Search primary orchestrator first (legacy single-project mode)
    primary_result =
      orchestrator
      |> Orchestrator.snapshot(snapshot_timeout_ms)
      |> maybe_issue_payload_from_snapshot(issue_identifier)

    # If found in primary, return immediately
    if primary_result do
      primary_result
    else
      # Multi-project fallback: search across all project orchestrators
      find_issue_in_projects(issue_identifier, snapshot_timeout_ms)
    end
  end

  defp find_issue_in_projects(issue_identifier, snapshot_timeout_ms) do
    ProjectSupervisor.list_orchestrators()
    |> Enum.find_value(fn {_project_name, pid} ->
      try do
        pid
        |> Orchestrator.snapshot(snapshot_timeout_ms)
        |> maybe_issue_payload_from_snapshot(issue_identifier)
      catch
        :exit, _ -> nil
      end
    end) ||
      {:error, :issue_not_found}
  end

  defp maybe_issue_payload_from_snapshot(%{} = snapshot, issue_identifier) do
    running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
    issue_payload_from_entries(issue_identifier, running, retry, snapshot)
  end

  defp maybe_issue_payload_from_snapshot(_snapshot, _issue_identifier), do: nil

  defp issue_payload_from_entries(_issue_identifier, nil, nil, _snapshot), do: nil

  defp issue_payload_from_entries(issue_identifier, running, retry, snapshot) do
    {:ok, issue_payload_body(issue_identifier, running, retry, snapshot)}
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec format_rate_limits_for_web(map() | nil) :: map() | nil
  def format_rate_limits_for_web(nil), do: nil

  def format_rate_limits_for_web(rate_limits) when is_map(rate_limits) do
    limit_id =
      map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) ||
        "unknown"

    %{
      limit_id: limit_id,
      primary: format_rate_limit_bucket_web(map_value(rate_limits, ["primary", :primary])),
      secondary: format_rate_limit_bucket_web(map_value(rate_limits, ["secondary", :secondary])),
      credits: format_rate_limit_credits_web(map_value(rate_limits, ["credits", :credits]))
    }
  end

  def format_rate_limits_for_web(_), do: nil

  defp format_rate_limit_bucket_web(nil), do: nil

  defp format_rate_limit_bucket_web(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    %{
      remaining: remaining,
      limit: limit,
      reset_in_seconds: reset_value,
      summary:
        cond do
          is_integer(remaining) and is_integer(limit) ->
            "#{remaining}/#{limit}"

          is_integer(remaining) ->
            "remaining #{remaining}"

          is_integer(limit) ->
            "limit #{limit}"

          true ->
            "n/a"
        end
    }
  end

  defp format_rate_limit_credits_web(nil), do: nil

  defp format_rate_limit_credits_web(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited -> %{status: "unlimited", summary: "unlimited"}
      has_credits and is_number(balance) -> %{status: "available", summary: "#{balance}"}
      has_credits -> %{status: "available", summary: "available"}
      true -> %{status: "none", summary: "none"}
    end
  end

  defp format_rate_limit_credits_web(_), do: nil

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_value(_map, _keys), do: nil

  defp issue_payload_body(issue_identifier, running, retry, snapshot) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, snapshot),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        claude_session_logs: (running && Enum.map(Map.get(running, :log_events, []), &log_event_payload/1)) || []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry, stall_timeout_ms) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_title: issue_field(entry, :title),
      issue_url: issue_field(entry, :url),
      priority: issue_field(entry, :priority),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      provider: Map.get(entry, :provider),
      agent_kind: Map.get(entry, :agent_kind),
      model: Map.get(entry, :model),
      effort: Map.get(entry, :effort),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_agent_event,
      last_message: summarize_message(entry.last_agent_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_agent_timestamp),
      stalled: stalled?(entry.last_agent_timestamp, stall_timeout_ms),
      log_events: Enum.take(Map.get(entry, :log_events, []), 20),
      project_name: Map.get(entry, :project_name),
      tokens: %{
        input_tokens: entry.input_tokens,
        output_tokens: entry.output_tokens,
        total_tokens: entry.total_tokens
      },
      tokens_per_second:
        session_tokens_per_second(
          entry.total_tokens,
          runtime_seconds_from_started_at(entry.started_at)
        )
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      project_name: Map.get(entry, :project_name),
      issue_title: issue_field(entry, :title),
      issue_url: issue_field(entry, :url),
      priority: issue_field(entry, :priority),
      attempt: entry.attempt,
      held: held?(entry),
      due_at: due_at_iso8601(entry),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      turn_count: 0,
      session_id: nil,
      started_at: nil,
      last_event: nil,
      last_message: nil,
      log_events: []
    }
  end

  defp waiting_entry_payload(entry) when is_map(entry) do
    %{
      issue_id: first_present([Map.get(entry, :issue_id), issue_field(entry, :id), Map.get(entry, :id)]),
      issue_identifier:
        first_present([
          Map.get(entry, :identifier),
          Map.get(entry, :issue_identifier),
          issue_field(entry, :identifier)
        ]),
      issue_title: first_present([issue_field(entry, :title), Map.get(entry, :issue_title), Map.get(entry, :title)]),
      issue_url: first_present([issue_field(entry, :url), Map.get(entry, :issue_url), Map.get(entry, :url)]),
      priority: first_present([issue_field(entry, :priority), Map.get(entry, :priority)]),
      state: first_present([Map.get(entry, :state), issue_field(entry, :state)]),
      created_at: waiting_created_at(first_present([issue_field(entry, :created_at), Map.get(entry, :created_at)])),
      agent_kind: Map.get(entry, :agent_kind),
      model: Map.get(entry, :model),
      effort: Map.get(entry, :effort)
    }
  end

  defp waiting_created_at(%DateTime{} = datetime), do: iso8601(datetime)
  defp waiting_created_at(value) when is_binary(value), do: value
  defp waiting_created_at(_value), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, &(not is_nil(&1)))
  end

  defp project_from_snapshot(project_name, snapshot) do
    polling = Map.get(snapshot, :polling) || %{}

    running =
      snapshot.running
      |> Enum.map(&Map.put(&1, :project_name, project_name))
      |> Enum.map(&running_entry_payload(&1, Map.get(snapshot, :stall_timeout_ms)))

    retrying =
      snapshot.retrying
      |> Enum.map(&Map.put(&1, :project_name, project_name))
      |> Enum.map(&retry_entry_payload/1)

    waiting =
      case Map.get(snapshot, :waiting, []) do
        list when is_list(list) -> Enum.map(list, &waiting_entry_payload/1)
        _ -> []
      end

    %{
      name: project_name,
      running: running,
      retrying: retrying,
      waiting: waiting,
      running_count: length(running),
      retrying_count: length(retrying),
      waiting_count: length(waiting),
      providers: Map.get(snapshot, :providers, []),
      agent_kind: Map.get(snapshot, :agent_kind),
      agent_model: Map.get(snapshot, :agent_model),
      agent_effort: Map.get(snapshot, :agent_effort),
      paused: Map.get(polling, :paused, false),
      max_concurrent_agents: Map.get(polling, :max_concurrent_agents)
    }
  end

  defp issue_field(entry, key) do
    case Map.get(entry, :issue) do
      %{} = issue -> Map.get(issue, key)
      _ -> nil
    end
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_agent_event,
      last_message: summarize_message(running.last_agent_message),
      last_event_at: iso8601(running.last_agent_timestamp),
      log_events: Enum.map(Map.get(running, :log_events, []), &log_event_payload/1),
      tokens: %{
        input_tokens: running.input_tokens,
        output_tokens: running.output_tokens,
        total_tokens: running.total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      held: held?(retry),
      due_at: due_at_iso8601(retry),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry, snapshot) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Map.get(snapshot, :workspace_root) || Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_agent_timestamp),
        event: running.last_agent_event,
        message: summarize_message(running.last_agent_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp log_event_payload(event) do
    %{
      at: iso8601(event.at),
      event: to_string(event.event),
      message: summarize_message(event.message)
    }
  end

  defp stalled?(%DateTime{} = last_event_at, configured_timeout_ms) do
    timeout_ms = configured_timeout_ms || Config.settings!().agent.stall_timeout_ms
    elapsed_ms = DateTime.diff(DateTime.utc_now(), last_event_at, :millisecond)
    timeout_ms > 0 and elapsed_ms > timeout_ms
  rescue
    _ -> false
  end

  defp stalled?(_, _), do: false

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_agent_message(message)

  # Add the offset in milliseconds and truncate once, so the result is
  # `floor(due_at)`. Truncating the clock first and adding whole seconds
  # afterwards made the answer flip between two adjacent seconds depending on the
  # sub-second part of `utc_now/0`, which made an unchanged retry queue look
  # changed to the dashboard on roughly every other refresh. This form only
  # jitters by the snapshot round-trip (`due_in_ms` is measured against the
  # orchestrator's monotonic clock, `utc_now/0` is sampled here), so it is a large
  # reduction in flip rate rather than an absolute guarantee.
  # A held entry has no due time at all: dispatch is paused, its timer is
  # disarmed, and its `due_in_ms` is clamped to 0 forever. Deriving `due_at`
  # from `now + 0` would hand the dashboard a value that advances one second
  # per second, so a paused board with a single held retry re-rendered every
  # project section on every payload load. `held` carries the state instead.
  defp due_at_iso8601(%{held: true}), do: nil

  defp due_at_iso8601(%{due_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(due_in_ms, :millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_entry), do: nil

  defp held?(entry), do: Map.get(entry, :held) == true

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  # Legacy single-orchestrator fallback: nothing is registered in the project
  # registry, so ask the configured orchestrator name directly.
  defp legacy_payload(orchestrator, snapshot_timeout_ms, generated_at) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        legacy_snapshot_payload(snapshot, generated_at)

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        unavailable_payload(orchestrator, generated_at)
    end
  end

  defp legacy_snapshot_payload(snapshot, generated_at) do
    project_name = Map.get(snapshot, :project_name) || "default"
    project = project_from_snapshot(project_name, snapshot)
    running = project.running
    retrying = project.retrying

    %{
      generated_at: generated_at,
      counts: payload_counts(running, retrying, project.waiting),
      running: running,
      retrying: retrying,
      recent_completed:
        snapshot
        |> Map.get(:recent_completed, [])
        |> Enum.map(&completed_entry_payload/1),
      token_totals: normalize_token_totals(snapshot.token_totals),
      rate_limits: snapshot.rate_limits,
      polling: Map.get(snapshot, :polling),
      projects: [project]
    }
  end

  defp unavailable_payload(orchestrator, generated_at) do
    if empty_fleet?(orchestrator) do
      empty_fleet_payload(generated_at)
    else
      %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  # A daemon with no orchestrator anywhere is not a failed snapshot — it is a
  # fleet with nothing in it, which is exactly what the dashboard's "No projects
  # / connect Linear and add your first project" card is for. `Orchestrator.
  # snapshot/2` cannot tell the two apart (a call to an unregistered name and a
  # call to a process that dies mid-call both exit and both come back
  # `:unavailable`), so ask the registry and the process table instead. A
  # registry with projects in it whose snapshots all failed keeps reporting
  # `snapshot_unavailable`: something is wrong there, and saying "no projects"
  # would hide it.
  defp empty_fleet?(orchestrator) do
    ProjectSupervisor.list_orchestrators() == [] and is_nil(GenServer.whereis(orchestrator))
  end

  defp empty_fleet_payload(generated_at) do
    %{
      generated_at: generated_at,
      counts: payload_counts([], [], []),
      running: [],
      retrying: [],
      recent_completed: [],
      token_totals: normalize_token_totals(nil),
      rate_limits: nil,
      polling: nil,
      projects: []
    }
  end

  defp aggregate_project_snapshots(snapshot_timeout_ms) do
    projects = ProjectSupervisor.list_orchestrators()
    deadline = System.monotonic_time(:millisecond) + snapshot_timeout_ms

    snapshots =
      projects
      |> Enum.with_index()
      |> collect_project_snapshots(%{}, [], deadline)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    {length(projects), snapshots}
  end

  defp collect_project_snapshots(queued, active, results, deadline) do
    {queued, active} = start_snapshot_tasks(queued, active, deadline)
    remaining = deadline - System.monotonic_time(:millisecond)

    if map_size(active) == 0 or remaining <= 0 do
      Enum.each(active, fn {_ref, {task, _index, _name}} -> Task.shutdown(task, :brutal_kill) end)
      results
    else
      receive do
        {ref, snapshot} when is_map_key(active, ref) ->
          {_task, index, name} = Map.fetch!(active, ref)
          Process.demonitor(ref, [:flush])

          results =
            if is_map(snapshot),
              do: [{index, %{project_name: name, snapshot: snapshot}} | results],
              else: results

          collect_project_snapshots(queued, Map.delete(active, ref), results, deadline)

        {:DOWN, ref, :process, _pid, _reason} when is_map_key(active, ref) ->
          collect_project_snapshots(queued, Map.delete(active, ref), results, deadline)
      after
        remaining ->
          Enum.each(active, fn {_ref, {task, _index, _name}} -> Task.shutdown(task, :brutal_kill) end)
          results
      end
    end
  end

  defp start_snapshot_tasks([{{name, pid}, index} | rest], active, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if map_size(active) < 4 and remaining > 0 do
      task =
        Task.Supervisor.async_nolink(CymphonyElixir.TaskSupervisor, fn ->
          Orchestrator.snapshot(pid, remaining)
        end)

      start_snapshot_tasks(rest, Map.put(active, task.ref, {task, index, name}), deadline)
    else
      {[{{name, pid}, index} | rest], active}
    end
  end

  defp start_snapshot_tasks(queued, active, _deadline), do: {queued, active}

  defp merge_project_snapshots(snapshots) do
    all_running =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.running, &Map.put(&1, :project_name, project_name))
      end)

    all_retrying =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        Enum.map(snap.retrying, &Map.put(&1, :project_name, project_name))
      end)

    all_completed =
      snapshots
      |> Enum.flat_map(fn %{project_name: project_name, snapshot: snap} ->
        snap
        |> Map.get(:recent_completed, [])
        |> Enum.map(&Map.put(&1, :project_name, project_name))
      end)
      |> Enum.sort_by(fn entry -> entry[:ended_at] end, {:desc, DateTime})
      |> Enum.take(100)

    merged_totals =
      Enum.reduce(snapshots, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}, fn %{snapshot: snap}, acc ->
        totals = Map.get(snap, :token_totals, %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0})

        %{
          input_tokens: acc.input_tokens + Map.get(totals, :input_tokens, 0),
          output_tokens: acc.output_tokens + Map.get(totals, :output_tokens, 0),
          total_tokens: acc.total_tokens + Map.get(totals, :total_tokens, 0),
          seconds_running: acc.seconds_running + Map.get(totals, :seconds_running, 0)
        }
      end)

    first_snap = hd(snapshots).snapshot

    %{
      running: all_running,
      retrying: all_retrying,
      recent_completed: all_completed,
      token_totals: merged_totals,
      rate_limits: Map.get(first_snap, :rate_limits),
      polling: Map.get(first_snap, :polling)
    }
  end

  defp payload_counts(running, retrying, waiting) do
    breakdowns = count_breakdowns(running)

    %{
      running: length(running),
      retrying: length(retrying),
      waiting: length(waiting),
      by_state: breakdowns.by_state,
      by_kind: breakdowns.by_kind
    }
  end

  defp increment_count(map, key) do
    Map.update(map, key, 1, &(&1 + 1))
  end

  defp breakdown_state(entry) do
    case fetch_entry_value(entry, :state) do
      nil -> ""
      state when is_binary(state) -> state
      state -> to_string(state)
    end
  end

  defp breakdown_kind(entry) do
    case fetch_entry_value(entry, :agent_kind) do
      nil -> "unknown"
      "" -> "unknown"
      kind when is_binary(kind) -> kind
      kind -> to_string(kind)
    end
  end

  defp fetch_entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp numeric_or_zero(value) when is_number(value), do: value
  defp numeric_or_zero(_value), do: 0

  defp runtime_seconds_from_started_at(%DateTime{} = started_at) do
    max(0, DateTime.diff(DateTime.utc_now(), started_at, :second))
  end

  defp runtime_seconds_from_started_at(started_at) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at), do: 0

  defp normalize_token_totals(nil) do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0, tokens_per_second: 0.0}
  end

  defp normalize_token_totals(totals) when is_map(totals) do
    input_tokens = Map.get(totals, :input_tokens, 0)
    output_tokens = Map.get(totals, :output_tokens, 0)
    total_tokens = Map.get(totals, :total_tokens, 0)
    seconds_running = Map.get(totals, :seconds_running, 0)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      seconds_running: seconds_running,
      tokens_per_second: session_tokens_per_second(total_tokens, seconds_running)
    }
  end
end
