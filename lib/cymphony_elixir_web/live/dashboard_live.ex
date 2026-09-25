defmodule CymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Cymphony.
  """

  use Phoenix.LiveView, layout: {CymphonyElixirWeb.Layouts, :app}

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixirWeb.{Control, Endpoint, ObservabilityPubSub, Presenter}

  @version Mix.Project.config()[:version]
  @runtime_tick_ms 1_000
  # Safety net for the dirty-gated reload below: a dropped broadcast, or a field
  # nothing broadcasts about (`last_agent_timestamp`, the poll countdown), must
  # not freeze the board forever.
  @idle_resync_ms 30_000
  @harness_tail_cap 400
  # Stand-in for an instrument-band breakdown with nothing to report; a blank
  # value cell reads as a broken tile (see `format_count_breakdown/1`).
  @count_breakdown_placeholder "—"
  # `Config.Schema` default for `agent.max_concurrent_agents`; shown as the
  # drawer placeholder when no project has reported its own limit.
  @default_concurrency_label "10"
  # Section defaults for the disconnected render and for payloads that omit a
  # section. `waiting: []` has no assign of its own (waiting rows live inside each
  # project entry) but stays here because SPEC §13.3 pins it on the default payload.
  @default_payload %{
    counts: %{running: 0, retrying: 0, waiting: 0, by_state: %{}, by_kind: %{}},
    running: [],
    retrying: [],
    waiting: [],
    token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    rate_limits: nil,
    polling: nil,
    projects: [],
    recent_completed: [],
    error: nil
  }

  # Each payload section gets its own assign so LiveView change tracking can skip
  # the sections that did not move. Nested `@payload.x` reads mark the whole
  # template dirty on every refresh, which is the churn this splits apart.
  # `:generated_at` is deliberately absent: it changes on every load and is
  # rendered nowhere.
  @payload_sections [
    counts: :counts,
    token_totals: :token_totals,
    rate_limits: :rate_limits,
    polling: :polling,
    projects: :projects,
    running: :running,
    retrying: :retrying,
    completions: :recent_completed,
    payload_error: :error
  ]

  # The sections whose rendering reads `:now`: the global runtime tile
  # (`@token_totals` + `@running`), the stall banner (`@running`) and the
  # per-project comprehension (`@projects`, for session runtime and retry
  # due-in). Keep this in step with the `@now` reads in `render/1` — a clock
  # hung off a section that is not listed here would render a stale amount.
  @clock_sections [:token_totals, :running, :projects]

  @impl true
  def mount(_params, _session, socket) do
    connected? = connected?(socket)
    initial_payload = if connected?, do: load_payload(), else: @default_payload

    last_refresh =
      if connected?, do: System.monotonic_time(:millisecond), else: nil

    refresh_seconds = CymphonyConfig.dashboard_refresh_seconds()

    socket =
      socket
      |> assign_payload_sections(initial_payload)
      # `assign_payload_sections/2` re-anchors `:now` only when a clock-bearing
      # section moved. At mount every section is absent so it always fires, but
      # pin the assign here as well: `:now` has to exist for the first render
      # whatever `@clock_sections` ends up listing.
      |> assign(:now, DateTime.utc_now())
      |> assign(:stalled_alert_dismissed, false)
      |> assign(:expanded_issue_ids, MapSet.new())
      |> assign(:harness_tails, %{})
      |> assign(:agent_setting_drafts, %{})
      |> assign(:issue_run_spec_drafts, %{})
      |> assign(:queue_edit_ids, MapSet.new())
      |> assign(:queue_run_spec_drafts, %{})
      |> assign(:field_drafts, %{})
      |> assign_token_throughput(update_token_samples([], initial_payload))
      |> assign(:version, @version)
      # Assigned once and never again: the dead render also has `projects: []`,
      # and "no projects yet" is a statement about the fleet that a disconnected
      # render has not earned. Without this the fleet-empty card flashes on every
      # first paint of a board that does have projects.
      |> assign(:live_connected, connected?)
      |> assign(:last_payload_refresh, last_refresh)
      |> assign(:payload_dirty, false)
      |> assign(:payload_refresh_seconds, refresh_seconds)
      |> assign(:payload_refresh_ms, refresh_seconds * 1000)
      |> assign(:linear_status, Control.linear_status())
      |> assign(:linear_projects, [])
      |> assign(:linear_error, nil)
      |> assign(:add_project_error, nil)
      |> assign(:add_project_kind, "")
      |> assign(:add_project_model, "")
      |> assign(:add_project_effort, "")
      |> assign(:add_project_provider, "")
      |> assign(:add_project_slug, "")
      |> assign(:add_project_name, "")
      |> assign(:add_project_github, "")
      |> assign(:payload_seq, 0)

    if connected? do
      schedule_runtime_tick()
      ObservabilityPubSub.subscribe()

      if socket.assigns.linear_status.connected do
        enqueue_linear_projects_load()
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_logs", %{"issue" => issue_identifier}, socket) do
    expanded = socket.assigns.expanded_issue_ids

    if MapSet.member?(expanded, issue_identifier) do
      {:noreply,
       socket
       |> assign(:expanded_issue_ids, MapSet.delete(expanded, issue_identifier))
       |> collapse_harness_tail(issue_identifier)}
    else
      {:noreply,
       socket
       |> assign(:expanded_issue_ids, MapSet.put(expanded, issue_identifier))
       |> expand_harness_tail(issue_identifier)}
    end
  end

  @impl true
  def handle_event("toggle_harness_follow", %{"issue" => issue_identifier}, socket) do
    case Map.get(socket.assigns.harness_tails, issue_identifier) do
      nil ->
        {:noreply, socket}

      tail ->
        follow? = Map.get(tail, :follow, true)
        tails = Map.put(socket.assigns.harness_tails, issue_identifier, Map.put(tail, :follow, !follow?))
        {:noreply, assign(socket, :harness_tails, tails)}
    end
  end

  @impl true
  def handle_event("dismiss_stalled_alert", _params, socket) do
    {:noreply, assign(socket, :stalled_alert_dismissed, true)}
  end

  @impl true
  def handle_event("kill_issue", %{"issue" => issue_identifier}, socket) do
    {:noreply, send_issue_command(socket, issue_identifier, :kill_issue)}
  end

  @impl true
  def handle_event("retry_issue", %{"issue" => issue_identifier}, socket) do
    {:noreply, send_issue_command(socket, issue_identifier, :retry_issue_now)}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    pid = self()

    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      _ = CymphonyElixir.Orchestrator.request_refresh(orchestrator())
      send(pid, :reload_payload_now)
    end)

    Process.send_after(self(), :clear_flash, 3_000)
    {:noreply, put_flash(socket, :info, "Refresh requested — checking Linear now...")}
  end

  # Any control whose rendered value can differ from the last payload while the
  # operator is mid-edit renders from `:field_drafts` instead of the payload.
  # Without it, morphdom rewrites `input.value` from the server value on every
  # patch (it only spares the *focused*, non-hidden input), so a number typed
  # into concurrency/providers/refresh vanished on the next refresh — and a
  # patch landing between the blur and the click submitted the old value.
  @impl true
  def handle_event("preview_field", %{"field" => key, "value" => value}, socket)
      when is_binary(key) and is_binary(value) do
    {:noreply, update(socket, :field_drafts, &Map.put(&1, key, value))}
  end

  @impl true
  def handle_event("preview_field", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pause_dispatch", _params, socket) do
    {:noreply,
     flash_dispatch_result(
       socket,
       Control.pause(:all),
       "Dispatch paused — running sessions will complete normally"
     )}
  end

  @impl true
  def handle_event("resume_dispatch", _params, socket) do
    {:noreply, flash_dispatch_result(socket, Control.resume(:all), "Dispatch resumed")}
  end

  @impl true
  def handle_event("set_concurrency", %{"value" => raw_value}, socket) do
    case Control.parse_concurrency(raw_value) do
      {:ok, n} ->
        case Control.set_concurrency(:all, n) do
          :ok ->
            socket =
              socket
              |> clear_field_draft("global-concurrency")
              |> put_flash(:info, "Concurrency set to #{n}; persisted to ~/.cymphony/config.json")

            {:noreply, reload_payload_now(socket)}

          {:error, _reason} ->
            {:noreply, reload_payload_now(put_flash(socket, :error, "Concurrency was applied, but could not be saved to config.json"))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a positive integer")}
    end
  end

  @impl true
  def handle_event("set_refresh_interval", %{"value" => raw_value}, socket) do
    case Control.parse_concurrency(raw_value) do
      {:ok, n} ->
        case Control.set_dashboard_refresh_seconds(n) do
          :ok ->
            {:noreply,
             socket
             |> assign(:payload_refresh_seconds, n)
             |> assign(:payload_refresh_ms, n * 1000)
             |> clear_field_draft("refresh-interval")
             |> put_flash(:info, "Dashboard refresh set to #{n}s; persisted to ~/.cymphony/config.json")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not persist dashboard refresh interval")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Refresh interval must be a positive integer")}
    end
  end

  @impl true
  def handle_event(
        "set_project_concurrency",
        %{"project" => project_name, "value" => raw_value},
        socket
      ) do
    case Control.parse_concurrency(raw_value) do
      {:ok, n} ->
        case Control.set_concurrency({:project, project_name}, n) do
          :ok ->
            socket =
              socket
              |> clear_field_draft("concurrency:#{project_name}")
              |> put_flash(:info, "#{project_name}: concurrency set to #{n}")

            {:noreply, reload_payload_now(socket)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}

          {:error, _reason} ->
            {:noreply, reload_payload_now(put_flash(socket, :error, "Concurrency was applied, but could not be saved to config.json"))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Concurrency must be a positive integer")}
    end
  end

  @impl true
  def handle_event(
        "set_project_providers",
        %{"project" => project_name, "value" => raw_value},
        socket
      ) do
    case CymphonyConfig.parse_providers_csv(raw_value) do
      {:ok, list} ->
        case Control.set_providers({:project, project_name}, list) do
          :ok ->
            socket =
              socket
              |> clear_field_draft("providers:#{project_name}")
              |> put_flash(:info, "#{project_name}: providers set to #{Enum.join(list, ", ")}")

            {:noreply, reload_payload_now(socket)}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}

          {:error, _reason} ->
            {:noreply, reload_payload_now(put_flash(socket, :error, "Providers were applied, but could not be saved to config.json"))}
        end

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "Providers must be a non-empty comma-separated list")}

      {:error, :invalid} ->
        {:noreply, put_flash(socket, :error, "Providers must be valid shell aliases")}
    end
  end

  # An empty kind still has to record a draft (`preview_issue_run_spec` and
  # `put_queue_run_spec_draft` already do). A project with no persisted
  # `agent_kind` renders `kind: ""`, so picking a *model* posted `agent_kind=""`
  # and the whole preview was dropped — the next patch then reverted the model
  # the operator had just chosen. Persisting stays gated on a known kind.
  @impl true
  def handle_event("preview_project_agent", %{"project" => project_name} = params, socket) do
    case params["value"] || params["agent_kind"] do
      kind when is_binary(kind) ->
        if kind == "" or Agent.known_kind?(kind) do
          {:noreply, preview_project_agent(socket, project_name, kind, params)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_project_agent", %{"project" => project_name} = params, socket) do
    parse_params =
      params
      |> Map.take(["model", "effort"])
      |> Map.put("kind", params["agent_kind"])

    case Control.parse_agent_settings(parse_params) do
      {:ok, settings} ->
        case Control.set_agent_settings({:project, project_name}, settings) do
          :ok ->
            confirmed = confirmed_agent_draft(settings)

            socket =
              update(socket, :agent_setting_drafts, &apply_confirmed_draft(&1, project_name, confirmed))

            {:noreply, reload_payload_now(put_flash(socket, :info, "#{project_name}: agent settings updated"))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}

          {:error, _reason} ->
            confirmed = confirmed_agent_draft(settings)

            socket =
              update(socket, :agent_setting_drafts, &apply_confirmed_draft(&1, project_name, confirmed))

            {:noreply, reload_payload_now(put_flash(socket, :error, "Agent settings were applied, but could not be fully saved"))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Agent must be one of: #{Enum.join(Agent.known_kinds(), ", ")}")}
    end
  end

  @impl true
  def handle_event("connect_linear", params, socket) do
    case Control.connect_linear(params["api_key"] || "") do
      {:ok, status} ->
        enqueue_linear_projects_load()

        {:noreply,
         socket
         |> assign(:linear_status, status)
         |> assign(:linear_error, nil)
         |> assign(:payload_seq, next_payload_seq(socket))
         |> put_flash(:info, "Linear connected · #{status.masked_key}")}

      {:error, {:workflow_rewrite_failed, _project, _reason} = reason} ->
        enqueue_linear_projects_load()
        message = linear_connect_error_message(reason)

        {:noreply,
         socket
         |> assign(:linear_status, Control.linear_status())
         |> assign(:linear_error, message)
         |> assign(:payload_seq, next_payload_seq(socket))
         |> put_flash(:error, message)}

      {:error, reason} ->
        message = linear_connect_error_message(reason)

        {:noreply,
         socket
         |> assign(:linear_error, message)
         |> put_flash(:error, message)}
    end
  end

  @impl true
  def handle_event("add_project", params, socket) do
    case Control.add_project(add_project_attrs(params)) do
      {:ok, project} ->
        name = project_attr(project, "name") || project_attr(params, "name") || "Project"

        {:noreply,
         socket
         |> assign(:add_project_error, nil)
         |> reset_add_project_draft()
         |> put_flash(:info, "#{name} added and started")
         |> reload_payload_now()}

      {:error, reason} ->
        message = add_project_error_message(reason)

        {:noreply,
         socket
         |> assign(:add_project_error, message)
         |> put_flash(:error, message)}
    end
  end

  @impl true
  def handle_event("preview_add_project", params, socket) do
    kind = draft_add_project_field(params, "agent", socket, :add_project_kind)

    {:noreply,
     socket
     |> assign(:add_project_kind, kind)
     |> assign(:add_project_model, draft_add_project_field(params, "model", socket, :add_project_model))
     |> assign(:add_project_effort, draft_add_project_field(params, "effort", socket, :add_project_effort))
     |> assign(:add_project_provider, draft_add_project_field(params, "provider", socket, :add_project_provider))
     |> assign(
       :add_project_slug,
       draft_add_project_field(params, "linear_project_slug", socket, :add_project_slug)
     )
     |> assign(:add_project_name, draft_add_project_field(params, "name", socket, :add_project_name))
     |> assign(
       :add_project_github,
       draft_add_project_field(params, "github_repo_url", socket, :add_project_github)
     )}
  end

  @impl true
  def handle_event("toggle_project_pause", %{"project" => project_name}, socket) do
    case toggle_project_pause(socket.assigns.projects, project_name) do
      :ok ->
        {:noreply, reload_payload_now(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project orchestrator not found: #{project_name}")}

      {:error, _reason} ->
        # The orchestrator already flipped — only the durable half failed — so
        # the board still has to be reloaded or the header pill keeps showing
        # the old state.
        {:noreply, reload_payload_now(put_flash(socket, :error, "Pause state for #{project_name} applied, but could not be saved to ~/.cymphony/config.json"))}
    end
  end

  @impl true
  def handle_event("preview_issue_run_spec", %{"issue" => issue_identifier} = params, socket) do
    case params["value"] || params["agent_kind"] do
      kind when is_binary(kind) ->
        preview_issue_run_spec(socket, issue_identifier, kind, params)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_issue_run_spec", %{"issue" => issue_identifier} = params, socket) do
    entry =
      Enum.find(socket.assigns.running, &(&1.issue_identifier == issue_identifier)) || %{}

    issue_id = Map.get(entry, :issue_id)

    overrides =
      %{}
      |> maybe_override_param(:provider, params["provider"])
      |> maybe_override_param(:model, params["model"])
      |> maybe_override_param(:effort, params["effort"])
      |> maybe_override_agent_kind(params["agent_kind"])

    if is_binary(issue_id) and map_size(overrides) > 0 do
      send_issue_run_spec(socket, entry, issue_id, overrides)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("reorder_queue", params, socket) do
    project_name = params["project"]
    socket = optimistic_reorder_queue(socket, project_name, params["order"])

    case persist_queue_order(project_name, params["order"]) do
      :ok ->
        {:noreply, reload_payload_now(socket)}

      {:error, :invalid_scope} ->
        {:noreply, put_flash(socket, :error, "Queue reorder requires a project")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Project not found: #{project_name}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not persist queue order")}

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid queue order")}
    end
  end

  @impl true
  def handle_event("toggle_queue_edit", %{"project" => project_name, "issue" => issue}, socket) do
    key = {project_name, issue}
    ids = socket.assigns.queue_edit_ids

    ids =
      if MapSet.member?(ids, key) do
        MapSet.new()
      else
        MapSet.new([key])
      end

    {:noreply, assign(socket, :queue_edit_ids, ids)}
  end

  @impl true
  def handle_event("dismiss_overlays", _params, socket) do
    {:noreply, assign(socket, :queue_edit_ids, MapSet.new())}
  end

  @impl true
  def handle_event("preview_queue_run_spec", %{"project" => project_name, "issue" => issue} = params, socket) do
    case params["value"] || params["agent_kind"] do
      kind when is_binary(kind) ->
        {:noreply, put_queue_run_spec_draft(socket, project_name, issue, kind, params)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_queue_run_spec", %{"project" => project_name, "issue" => issue} = params, socket) do
    pin = queue_pin_from_params(params)

    cond do
      not is_binary(issue) or String.trim(issue) == "" ->
        {:noreply, put_flash(socket, :error, "Queue pin needs an issue")}

      map_size(pin) == 0 ->
        {:noreply, put_flash(socket, :error, "Queue pin needs at least one of agent, model, or effort")}

      true ->
        {:noreply, apply_queue_pin(socket, project_name, issue, pin)}
    end
  end

  defp apply_queue_pin(socket, project_name, issue, pin) do
    case persist_queue_pin(project_name, String.trim(issue), pin) do
      :ok ->
        reload_payload_now(put_flash(socket, :info, "#{issue}: queue pin saved"))

      {:error, :invalid_scope} ->
        put_flash(socket, :error, "Queue pin requires a project")

      {:error, :not_found} ->
        put_flash(socket, :error, "Project not found: #{project_name}")

      {:error, _reason} ->
        put_flash(socket, :error, "Could not persist queue pin")

      :error ->
        put_flash(socket, :error, "Invalid queue pin")
    end
  end

  # An orchestrator broadcast only marks the payload dirty; the next runtime tick
  # loads it, never more often than `dashboard_refresh_seconds`. Reloading here
  # made the *poll* interval the refresh interval — the orchestrator broadcasts
  # twice per Linear poll (default 5s) plus once per agent event — and
  # re-stamping `:last_payload_refresh` on every broadcast disabled the
  # configured gate entirely, which is why "refresh 20s" still repainted at 5s.
  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload_dirty, true)}
  end

  @impl true
  def handle_info(:reload_payload_now, socket) do
    {:noreply, reload_payload_now(socket)}
  end

  @impl true
  def handle_info(:clear_flash, socket) do
    {:noreply, clear_flash(socket)}
  end

  # The tick only schedules the periodic payload refresh. It deliberately does not
  # touch `:now`: re-assigning it every second re-rendered every time-derived string
  # in the template. The LiveClock hook advances those spans in the browser instead,
  # and `:now` is re-anchored by a payload load that moved a clock-bearing section
  # (see `maybe_reanchor_clocks/2`).
  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    now = System.monotonic_time(:millisecond)
    last = socket.assigns[:last_payload_refresh] || 0
    refresh_ms = socket.assigns[:payload_refresh_ms] || 3_000
    elapsed = now - last

    socket =
      if elapsed >= refresh_ms and
           (socket.assigns[:payload_dirty] == true or elapsed >= @idle_resync_ms) do
        socket
        |> spawn_payload_load()
        |> assign(:payload_dirty, false)
        |> assign(:last_payload_refresh, now)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:payload_loaded, seq, payload}, socket) when is_integer(seq) do
    if seq != socket.assigns.payload_seq do
      {:noreply, socket}
    else
      token_samples = update_token_samples(socket.assigns.token_samples, payload)

      {:noreply,
       socket
       |> assign_payload_sections(payload)
       |> assign_token_throughput(token_samples)
       |> update(:agent_setting_drafts, &prune_agent_drafts(&1, payload))}
    end
  end

  @impl true
  def handle_info({:linear_projects_loaded, {:error, _reason}}, socket) do
    {:noreply, assign(socket, :linear_error, "Could not reach Linear")}
  end

  @impl true
  def handle_info({:linear_projects_loaded, projects}, socket) when is_list(projects) do
    {:noreply, assign(socket, linear_projects: projects, linear_error: nil)}
  end

  @impl true
  def handle_info(%{event: :harness_stream, issue_id: id} = msg, socket) when is_binary(id) do
    seq = Map.get(msg, :last_seq) || 0
    new_lines = Map.get(msg, :lines) || []
    dropped = Map.get(msg, :dropped) || 0

    tails =
      Enum.reduce(socket.assigns.harness_tails, socket.assigns.harness_tails, fn {identifier, tail}, acc ->
        merge_harness_tail(acc, identifier, tail, id, seq, new_lines, dropped)
      end)

    {:noreply, assign(socket, :harness_tails, tails)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <%!-- LiveView allows a single phx-hook per element and #dashboard-root already
    runs OverlayDismiss, so the one client-side clock ticker lives on this wrapper.
    It is a plain block box inside .app-shell, so it changes no layout. --%>
    <div id="live-clock" phx-hook="LiveClock">
    <section id="dashboard-root" class="dashboard-shell" phx-hook="OverlayDismiss">
      <%!-- The rail is chrome, not a section: it reads only per-section assigns
      (`@version`, `@counts`, `@projects`, `@completions`, `@polling`) and never
      `@now`, so a clock re-anchor never re-renders it. --%>
      <nav class="side-rail" aria-label="Dashboard">
        <a class="side-rail-brand" href="#dashboard-top">
          <span class="brand-mark" aria-hidden="true"></span>
          <span class="brand-wordmark">CYMPHONY</span>
          <span class="version-badge">v<%= @version %></span>
        </a>

        <%= unless @payload_error do %>
          <div class="rail-vitals">
            <p class="rail-vitals-line">
              <span class="rail-vitals-num numeric"><%= @counts.running %></span>
              <span class="rail-vitals-word">running</span>
              <span class="rail-vitals-num numeric"><%= Map.get(@counts, :waiting, 0) %></span>
              <span class="rail-vitals-word">queued</span>
            </p>
            <p class="rail-vitals-copy">
              <%= case autonomy_state(@projects, @polling) do %>
                <% :unknown -> %>
                  Checking status…
                <% :paused -> %>
                  Automatic work is paused.
                <% {:partial, active_count, project_count} -> %>
                  On for <%= active_count %> of <%= project_count %> projects.
                <% :on -> %>
                  Automatic work is on.
              <% end %>
            </p>
          </div>
        <% end %>

        <%!-- `RailNav` only paints `aria-current`; every anchor works without it. --%>
        <div class="rail-group" id="rail-nav" phx-hook="RailNav" aria-label="Fleet">
          <p class="rail-group-label">Fleet</p>
          <a class="rail-link" href="#dashboard-top" title="Overview">
            <span class="rail-led rail-led--idle" aria-hidden="true"></span>
            <span class="rail-link-name">Overview</span>
          </a>
          <%= for project <- @projects do %>
            <a class="rail-link" href={"#project-" <> project_dom_id(project.name)} title={project.name}>
              <span class={"rail-led rail-led--" <> rail_state(project)} aria-hidden="true"></span>
              <span class="rail-link-name"><%= project.name %></span>
              <span class="rail-link-meta numeric advanced-only"><%= Map.get(project, :running_count, length(project.running)) %>·<%= project_waiting_count(project) %></span>
            </a>
          <% end %>
          <%= if @completions != [] do %>
            <a class="rail-link" href="#completions-section" title="Completions">
              <span class="rail-led rail-led--done" aria-hidden="true"></span>
              <span class="rail-link-name">Completions</span>
              <span class="rail-link-meta numeric advanced-only"><%= length(@completions) %></span>
            </a>
          <% end %>
        </div>

        <div class="rail-foot">
          <%!-- Same client-owned `aria-pressed` as the topbar copy: freeze it. --%>
          <div id="mode-switch-rail" class="mode-switch settings-mode-switch" role="group" aria-label="Dashboard mode" phx-update="ignore">
            <button type="button" class="mode-switch-button" data-mode-set="simple" aria-pressed="true">
              Simple
            </button>
            <button type="button" class="mode-switch-button" data-mode-set="advanced" aria-pressed="false">
              Advanced
            </button>
          </div>

          <div class="rail-foot-actions">
            <div class="theme-toggle" role="group" aria-label="Theme">
              <button type="button" class="theme-toggle-button" data-theme-set="light" title="Light theme" aria-label="Light theme"></button>
              <button type="button" class="theme-toggle-button" data-theme-set="dark" title="Dark theme" aria-label="Dark theme"></button>
              <button type="button" class="theme-toggle-button" data-theme-set="system" title="Follow system" aria-label="Follow system"></button>
            </div>
            <button type="button" class="subtle-button rail-action" data-drawer-toggle aria-label="Settings" title="Settings"></button>
            <button type="button" class="subtle-button rail-action rail-action--refresh" phx-click="refresh_now" title="Refresh">
              <span class="rail-action-label">Refresh</span>
            </button>
          </div>
        </div>
      </nav>

      <div class="main-col" id="dashboard-top">
        <header class="command-bar">
          <div class="command-bar-row command-bar-row--brand">
            <div class="command-bar-brand">
              <span class="brand-mark" aria-hidden="true"></span>
              <span class="brand-wordmark">CYMPHONY</span>
              <span class="brand-tagline simple-only">Work status</span>
              <span class="brand-tagline advanced-only">Operations</span>
            </div>
            <%!-- Below 900px the rail is gone, so the same anchors come back as a
            native disclosure — no server state. The `open` attribute is set by
            the browser and the server never renders it, so morphdom strips it on
            every patch: `JumpMenu` snapshots it before the morph and puts it
            back, the way `Combobox` does for its panel. Without JS the menu still
            opens and closes; it just cannot survive a patch. --%>
            <details class="jump-menu topbar-only-narrow" id="jump-menu" phx-hook="JumpMenu">
              <summary class="jump-menu-summary">Jump to</summary>
              <nav class="jump-menu-panel" aria-label="Jump to section">
                <a class="jump-menu-link" href="#dashboard-top">Overview</a>
                <%= for project <- @projects do %>
                  <a class="jump-menu-link" href={"#project-" <> project_dom_id(project.name)}><%= project.name %></a>
                <% end %>
                <%= if @completions != [] do %>
                  <a class="jump-menu-link" href="#completions-section">Completions</a>
                <% end %>
              </nav>
            </details>
            <div class="command-bar-meta">
              <span class="status-badge status-badge-offline status-badge-transport">
                <span class="status-badge-dot"></span>
                Connecting
              </span>
              <%= if @payload_error do %>
                <span class="status-badge status-badge-offline status-badge-payload">
                  <span class="status-badge-dot"></span>
                  Unavailable
                </span>
              <% else %>
                <span class="status-badge status-badge-live status-badge-payload">
                  <span class="status-badge-dot"></span>
                  Live
                </span>
              <% end %>
              <span class="version-badge">v<%= @version %></span>

              <%!-- `aria-pressed` is pure client state (localStorage `cymphony-prefs`).
              The server has no correct value to render, and morphdom reset it on
              every patch, so freeze the subtree instead of repairing it after the
              fact. --%>
              <div id="mode-switch-top" class="mode-switch topbar-only-narrow" role="group" aria-label="Dashboard mode" phx-update="ignore">
                <button type="button" class="mode-switch-button" data-mode-set="simple" aria-pressed="true">
                  Simple
                </button>
                <button type="button" class="mode-switch-button" data-mode-set="advanced" aria-pressed="false">
                  Advanced
                </button>
              </div>

              <%!-- The rail owns mode + theme at wide widths; these duplicates are
              painted only below 900px, where the rail is hidden. The delegated
              layout script syncs every instance, so both stay in step. --%>
              <div class="theme-toggle topbar-only-narrow" role="group" aria-label="Theme">
                <button type="button" class="theme-toggle-button" data-theme-set="light" title="Light theme" aria-label="Light theme"></button>
                <button type="button" class="theme-toggle-button" data-theme-set="dark" title="Dark theme" aria-label="Dark theme"></button>
                <button type="button" class="theme-toggle-button" data-theme-set="system" title="Follow system" aria-label="Follow system"></button>
              </div>

              <button type="button" class="subtle-button" data-drawer-toggle aria-label="Settings" title="Settings"></button>
              <button type="button" class="subtle-button" phx-click="refresh_now">Refresh</button>
            </div>
          </div>

          <%= unless @payload_error do %>
            <div class="command-bar-row simple-mode-summary simple-only" aria-live="polite">
              <%= case autonomy_state(@projects, @polling) do %>
                <% :unknown -> %>
                  <span class="autonomy-indicator autonomy-indicator--unknown">
                    <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                    Checking automatic work…
                  </span>
                  <span class="simple-mode-summary-copy">Cymphony is connecting to live orchestrator status.</span>
                <% :paused -> %>
                  <span class="autonomy-indicator autonomy-indicator--paused">
                    <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                    Automatic work is paused
                  </span>
                  <span class="simple-mode-summary-copy">Running tasks can finish, but Cymphony will not start new ones.</span>
                <% {:partial, active_count, project_count} -> %>
                  <span class="autonomy-indicator autonomy-indicator--partial">
                    <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                    Automatic work is on for <%= active_count %> of <%= project_count %> projects
                  </span>
                  <span class="simple-mode-summary-copy">Some projects are paused. Active projects will keep picking up ready issues.</span>
                <% :on -> %>
                  <span class="autonomy-indicator">
                    <span class="autonomy-indicator-dot" aria-hidden="true"></span>
                    Automatic work is on
                  </span>
                  <span class="simple-mode-summary-copy">Cymphony watches Linear and starts ready issues for you.</span>
              <% end %>
            </div>
          <% end %>
        </header>

        <%!-- Always in the DOM, painted only while the socket is in `phx-error`:
        a reconnect note must not wait for a server render to appear. --%>
        <div class="reconnect-note" role="status">Connection lost — reconnecting…</div>

        <%= unless @payload_error do %>
          <%!-- The band left <header> to become its own instrument panel; the
          pinned `command-bar-row--metrics section--metrics` tokens stay because
          the section-visibility pref CSS keys off them. --%>
          <div class="instrument-band command-bar-row--metrics section--metrics">
            <div class="metric-pill">
              <%!-- Simple mode used to say "Working" here and "Waiting" below,
              which put three wait-words on one screen: the rail counts
              "RUNNING · QUEUED", this cell counts retries, and the section
              underneath is "Waiting to try again". One word per concept —
              "Running" matches the rail, "To retry" says what the count is.
              The count mapping (running / retrying) is unchanged. --%>
              <span class="metric-pill-label simple-only">Running</span>
              <span class="metric-pill-label advanced-only">Run</span>
              <span class="metric-pill-value numeric"><%= @counts.running %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">To retry</span>
              <span class="metric-pill-label advanced-only">Retry</span>
              <span class="metric-pill-value numeric"><%= @counts.retrying %></span>
            </div>
            <div class="metric-pill metric-pill--queue section--queue advanced-only">
              <span class="metric-pill-label">Queue</span>
              <span class="metric-pill-value numeric"><%= Map.get(@counts, :waiting, 0) %></span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Usage</span>
              <span class="metric-pill-label advanced-only">Tokens</span>
              <span class="metric-pill-value numeric"><%= format_int(@token_totals.total_tokens) %></span>
              <span class="metric-pill-detail numeric advanced-only" title="input / output">
                in <%= format_int(@token_totals.input_tokens) %> · out <%= format_int(@token_totals.output_tokens) %>
              </span>
            </div>
            <div class="metric-pill">
              <span class="metric-pill-label simple-only">Time active</span>
              <span class="metric-pill-label advanced-only">Runtime</span>
              <%!-- Both the anchor and the text recompute the amount inline. A template
              variable would taint these dynamics and make them render unconditionally,
              which is exactly the per-render churn the clock anchors exist to avoid. --%>
              <span
                class="metric-pill-value numeric"
                data-clock="elapsed"
                data-base-seconds={total_runtime_seconds(@token_totals, @running, @now)}
                data-rate={length(@running)}
              ><%= format_runtime_seconds(total_runtime_seconds(@token_totals, @running, @now)) %></span>
            </div>
            <div class="metric-pill metric-pill--throughput advanced-only">
              <span class="metric-pill-label">Tput</span>
              <%!-- Derived strings, not `@token_samples`: the sample list grows on
              every payload load, so reading it here marked the template dirty on
              every load and an idle board shipped a diff per poll. --%>
              <span class="metric-pill-value numeric"><%= @throughput_tps %></span>
              <%!-- A freshly mounted board has fewer than two token samples, so
              the sparkline string is empty and the tile read as a bare "0" with
              nothing beside it — broken chrome on first impression. Show a flat
              baseline in `--ink-faint` instead, the same quiet treatment the
              States / Kinds cells give an empty breakdown. The placeholder is a
              literal, so it costs no per-load churn. --%>
              <%= if @throughput_spark == "" do %>
                <span class="metric-pill-spark metric-pill-placeholder numeric">▁▁▁▁▁▁▁▁▁▁▁▁</span>
              <% else %>
                <span class="metric-pill-spark numeric"><%= @throughput_spark %></span>
              <% end %>
            </div>
            <div class="metric-pill metric-pill--states section--states advanced-only">
              <span class="metric-pill-label">States</span>
              <span class={count_breakdown_class(Map.get(@counts, :by_state, %{}))}><%= format_count_breakdown(Map.get(@counts, :by_state, %{})) %></span>
            </div>
            <div class="metric-pill metric-pill--kinds section--kinds advanced-only">
              <span class="metric-pill-label">Kinds</span>
              <span class={count_breakdown_class(Map.get(@counts, :by_kind, %{}))}><%= format_count_breakdown(Map.get(@counts, :by_kind, %{})) %></span>
            </div>

            <%= if @polling do %>
              <div class="metric-pill metric-pill--ops section--polling">
                <span class="metric-pill-label simple-only">Automation</span>
                <span class="metric-pill-label advanced-only">Polling</span>
                <span class="metric-pill-value simple-only">
                  <%= case autonomy_state(@projects, @polling) do %>
                    <% :unknown -> %>
                      unavailable
                    <% :paused -> %>
                      <span class="ops-pulse">Paused</span>
                    <% {:partial, active_count, project_count} -> %>
                      <%= active_count %> / <%= project_count %> active
                    <% :on -> %>
                      <%= if @polling.checking? do %>
                        <span class="ops-pulse">Checking…</span>
                      <% else %>
                        next <span data-clock="countdown" data-remaining-ms={poll_remaining_ms(@polling.next_poll_in_ms)}><%= format_poll_countdown(@polling.next_poll_in_ms) %></span>
                      <% end %>
                  <% end %>
                </span>
                <span class="metric-pill-value advanced-only">
                  <%= cond do %>
                    <% Map.get(@polling, :paused, false) -> %>
                      <span class="ops-pulse">Paused</span>
                    <% @polling.checking? -> %>
                      <span class="ops-pulse">Checking…</span>
                    <% true -> %>
                      next <span data-clock="countdown" data-remaining-ms={poll_remaining_ms(@polling.next_poll_in_ms)}><%= format_poll_countdown(@polling.next_poll_in_ms) %></span>
                  <% end %>
                </span>
                <%= if @polling.poll_interval_ms do %>
                  <span class="metric-pill-detail numeric advanced-only">every <%= div(@polling.poll_interval_ms, 1_000) %>s</span>
                <% end %>
              </div>
            <% end %>

            <%= if @rate_limits do %>
              <%= case Presenter.format_rate_limits_for_web(@rate_limits) do %>
                <% nil -> %>
                <% formatted -> %>
                  <div class="metric-pill metric-pill--ops section--ratelimits advanced-only">
                    <span class="metric-pill-label">Limits</span>
                    <%= if formatted.primary do %>
                      <span class="metric-pill-detail">primary <%= formatted.primary.summary %></span>
                      <%= if formatted.primary.reset_in_seconds do %>
                        <span class="metric-pill-detail muted">resets <%= formatted.primary.reset_in_seconds %>s</span>
                      <% end %>
                    <% end %>
                    <%= if formatted.secondary do %>
                      <span class="metric-pill-detail">secondary <%= formatted.secondary.summary %></span>
                    <% end %>
                    <%= if formatted.credits do %>
                      <span class="metric-pill-detail">credits <%= formatted.credits.summary %></span>
                    <% end %>
                  </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <%= if @payload_error do %>
          <section class="error-card">
            <h2 class="error-title">Snapshot unavailable</h2>
            <p class="error-copy">
              <strong><%= @payload_error.code %>:</strong> <%= @payload_error.message %>
            </p>
          </section>
        <% else %>

          <%!-- A `<% x = … %>` binding here would taint every dynamic that
          follows it in this template — the whole project comprehension included
          — so the alert is a component and takes its list as an attr. --%>
          <.stalled_alert
            entries={stalled_running_entries(@running)}
            dismissed={@stalled_alert_dismissed}
            now={@now}
          />

          <%= if @live_connected and @projects == [] do %>
            <section class="section-card fleet-empty">
              <p class="fleet-empty-label">No projects</p>
              <p class="fleet-empty-copy">Connect Linear and add your first project.</p>
              <button type="button" class="subtle-button subtle-button--accent fleet-empty-action" data-drawer-toggle>
                Open settings
              </button>
            </section>
          <% end %>

          <%!-- `:key` makes LiveView diff per project rather than resending the
          whole comprehension when one project's numbers move. --%>
          <article
            :for={project <- @projects}
            :key={project.name}
            class={project_section_class(project, @queue_edit_ids)}
            id={"project-" <> project_dom_id(project.name)}
          >
            <header class="project-section-header">
              <div class="project-section-title-block">
                <h2 class="project-section-name">
                  <%= project.name %>
                  <%= if Map.get(project, :paused, false) do %>
                    <span class="chip chip--warn">Paused</span>
                  <% end %>
                </h2>
                <p class="project-section-counts">
                  <span class="numeric"><%= Map.get(project, :running_count, length(project.running)) %></span>
                  <%= if max = Map.get(project, :max_concurrent_agents) do %>
                    <span class="muted">/<%= max %></span>
                  <% end %>
                  <span class="muted">running</span>
                  · <span class="numeric"><%= project_waiting_count(project) %></span>
                  <span class="muted">queued</span>
                  · <span class="numeric"><%= Map.get(project, :retrying_count, length(project.retrying)) %></span>
                  <span class="muted">retrying</span>
                </p>
              </div>

              <div class="project-section-controls">
                <form
                  phx-change="preview_field"
                  phx-submit="set_project_concurrency"
                  class="inline-form project-concurrency-control"
                >
                  <input type="hidden" name="project" value={project.name} />
                  <input type="hidden" name="field" value={"concurrency:#{project.name}"} />
                  <label class="inline-label" for={"concurrency-#{project.name}"}>
                    <span class="simple-only">tasks at once</span>
                    <span class="advanced-only">concurrency</span>
                  </label>
                  <input
                    id={"concurrency-#{project.name}"}
                    type="number"
                    name="value"
                    min="1"
                    value={field_value(@field_drafts, "concurrency:#{project.name}", Map.get(project, :max_concurrent_agents) || "")}
                    phx-debounce="400"
                    class="inline-input inline-input--narrow"
                    title="Max concurrent agents (cli alias: cr)"
                  />
                  <button type="submit" class="subtle-button">Save</button>
                </form>

                <.project_agent_controls
                  project_name={project.name}
                  settings={project_agent_settings(@agent_setting_drafts, project)}
                  providers_value={
                    field_value(
                      @field_drafts,
                      "providers:#{project.name}",
                      Enum.join(Map.get(project, :providers, []), ",")
                    )
                  }
                />

                <button
                  type="button"
                  class="subtle-button"
                  phx-click="toggle_project_pause"
                  phx-value-project={project.name}
                >
                  <%= if Map.get(project, :paused, false), do: "Resume", else: "Pause" %>
                </button>
              </div>
            </header>

            <%= if project.running == [] and project.retrying == [] and project_waiting(project) == [] do %>
              <%= if Map.get(project, :paused, false) do %>
                <p class="empty-state simple-only">
                  This project is paused. Resume it when you want Cymphony to start ready issues again.
                </p>
              <% else %>
                <p class="empty-state simple-only">
                  Nothing is running right now. Cymphony is watching Linear and will start the next ready issue automatically.
                </p>
              <% end %>
              <p class="empty-state advanced-only">No active sessions.</p>
            <% end %>

            <%= if project_waiting(project) != [] do %>
              <section class="queue-board section--board">
                <header class="queue-board-header">
                  <span class="queue-board-label simple-only">Up next</span>
                  <span class="queue-board-label advanced-only">Queue</span>
                  <span class="queue-board-count numeric"><%= project_waiting_count(project) %></span>
                  <span class="queue-board-hint">Leftmost starts next</span>
                </header>
                <div
                  id={"queue-board-#{project.name}"}
                  class="queue-board-list"
                  phx-hook="QueueBoard"
                  data-project={project.name}
                  data-order={queue_order_attr(project_waiting(project))}
                >
                  <.queue_card
                    :for={{entry, rank} <- Enum.with_index(project_waiting(project))}
                    :key={entry.issue_identifier}
                    project_name={project.name}
                    entry={entry}
                    rank={rank}
                    editing?={MapSet.member?(@queue_edit_ids, {project.name, entry.issue_identifier})}
                    spec={queue_run_spec_settings(@queue_run_spec_drafts, project, entry)}
                  />
                </div>
              </section>
            <% end %>

            <%= if project.running != [] do %>
              <div class="session-row-list">
                <%!-- The head cells reuse the body column classes, so the
                `html[data-hidden-cols~=…]` prefs hide header and cell together
                with no extra selectors. --%>
                <div class="session-grid-head advanced-only" aria-hidden="true">
                  <span class="sg-caret"></span>
                  <span class="sg-id">Issue</span>
                  <span class="session-row-title">Title</span>
                  <span class="session-row-chips">Tags</span>
                  <span class="session-row-runtime">Time</span>
                  <span class="session-row-tokens">Tokens</span>
                  <span class="sg-act"></span>
                </div>
                <.session_row
                  :for={entry <- project.running}
                  :key={entry.issue_identifier}
                  entry={entry}
                  expanded?={MapSet.member?(@expanded_issue_ids, entry.issue_identifier)}
                  spec={session_run_spec_settings(@issue_run_spec_drafts, entry)}
                  tail={harness_tail(@harness_tails, entry)}
                  now={@now}
                />
              </div>
            <% end %>

            <%= if project.retrying != [] do %>
              <div class="retry-row-list">
                <p class="subsection-label simple-only">Waiting to try again</p>
                <p class="subsection-label advanced-only">Retry queue</p>
                <article :for={entry <- project.retrying} :key={entry.issue_identifier} class={retry_row_class(entry)}>
                  <div class="retry-row-id">
                    <%= if entry.issue_url do %>
                      <a href={entry.issue_url} target="_blank" rel="noopener" class="session-row-link"><%= entry.issue_identifier %></a>
                    <% else %>
                      <%= entry.issue_identifier %>
                    <% end %>
                  </div>
                  <div class="retry-row-attempt">
                    <span class="chip chip--warn">Attempt <%= entry.attempt %></span>
                    <%= if entry.due_at do %>
                      <span class="muted">due <span data-clock="due" data-remaining-ms={retry_remaining_ms(entry.due_at, @now)}><%= format_retry_countdown(entry.due_at, @now) %></span></span>
                    <% end %>
                    <%!-- Held is suppression, not failure: it gets the same tag
                    grammar as its "Attempt N" neighbour but no amber, and it
                    mutes the row's retry edge (see `.retry-row--held`). --%>
                    <%= if Map.get(entry, :held) do %>
                      <span class="chip chip--held" title="Dispatch is paused; this retry is not counting down">Held</span>
                    <% end %>
                  </div>
                  <div class="retry-row-error advanced-only">
                    <%= if entry.error do %>
                      <span class="muted small mono"><%= String.slice(to_string(entry.error), 0, 120) %></span>
                    <% end %>
                  </div>
                  <span class="retry-row-guidance simple-only">Cymphony will retry automatically.</span>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="retry_issue"
                    phx-value-issue={entry.issue_identifier}
                  >
                    Retry now
                  </button>
                </article>
              </div>
            <% end %>
          </article>

          <%= if @completions != [] do %>
            <section class="section-card section--completions" id="completions-section">
              <div class="section-header">
                <div>
                  <h2 class="section-title">Recent completions</h2>
                  <p class="section-copy simple-only"><%= length(@completions) %> recently finished tasks.</p>
                  <p class="section-copy advanced-only">Last <%= length(@completions) %> agent runs. Cleared on daemon restart.</p>
                </div>
                <button
                  type="button"
                  class="subtle-button"
                  data-collapse-toggle="completions"
                  aria-label="Expand section"
                  aria-expanded="false"
                >▸</button>
              </div>

              <div class="session-row-list">
                <%= for entry <- @completions do %>
                  <article class="session-row session-row--completed">
                    <div class="session-row-summary">
                      <span class="session-row-disclosure" aria-hidden="true">✓</span>
                      <div class="session-row-id"><%= entry.issue_identifier %></div>
                      <div class="session-row-title muted small">
                        <%= if Map.get(entry, :project_name), do: entry.project_name, else: "" %>
                      </div>
                      <div class="session-row-chips">
                        <span class="chip chip--ok">Done</span>
                        <%= if Map.get(entry, :agent_kind) do %>
                          <span class="chip chip--agent chip--icon advanced-only" title={entry.agent_kind}>
                            <.agent_icon kind={entry.agent_kind} />
                          </span>
                        <% end %>
                        <%= if Map.get(entry, :model) do %>
                          <span class="chip chip--muted chip--truncate advanced-only" title={entry.model}><%= entry.model %></span>
                        <% end %>
                        <span class="chip chip--muted advanced-only"><%= entry.worker_host || "local" %></span>
                      </div>
                      <div class="session-row-runtime numeric">
                        <%= format_runtime_seconds(entry.runtime_seconds || 0) %>
                      </div>
                      <div class="session-row-tokens numeric">
                        <%= format_int(entry.total_tokens) %>
                      </div>
                      <span class="muted small mono">
                        <%= if entry.ended_at, do: entry.ended_at, else: "" %>
                      </span>
                    </div>
                  </article>
                <% end %>
              </div>
            </section>
          <% end %>
        <% end %>
      </div>

      <aside class="settings-drawer" aria-label="Dashboard settings">
        <div class="settings-drawer-header">
          <h2 class="settings-drawer-title">Settings</h2>
          <button type="button" class="subtle-button" data-drawer-toggle aria-label="Close settings">Close</button>
        </div>

        <section id="settings-experience" class="settings-group settings-group--mode" data-prefs phx-update="ignore">
          <h3 class="settings-group-title">Experience</h3>
          <div class="mode-switch settings-mode-switch" role="group" aria-label="Choose dashboard mode">
            <button type="button" class="mode-switch-button" data-mode-set="simple" aria-pressed="true">Simple</button>
            <button type="button" class="mode-switch-button" data-mode-set="advanced" aria-pressed="false">Advanced</button>
          </div>
          <p class="settings-help">Simple hides operator detail. Advanced shows every tag, column and control.</p>
        </section>

        <section class="settings-group settings-group--linear">
          <h3 class="settings-group-title">
            Linear
            <span class={"linear-status " <> if(@linear_status.connected, do: "linear-status--connected", else: "linear-status--disconnected")}>
              <%= if @linear_status.connected, do: "Connected", else: "Disconnected" %>
            </span>
            <%= if @linear_status.connected && @linear_status.masked_key do %>
              <span class="linear-key-mask"><%= @linear_status.masked_key %></span>
            <% end %>
          </h3>
          <%!-- `phx-update="ignore"`, not a draft assign: the value is a secret
          that must never reach assigns, flashes or logs, so the server has no
          correct value to render and morphdom wiped whatever was typed on the
          next patch. The markup is fully static, so freezing it loses nothing. --%>
          <form id="linear-connect-form" phx-submit="connect_linear" class="settings-inline" phx-update="ignore">
            <input
              type="password"
              name="api_key"
              id="linear-api-key"
              autocomplete="off"
              class="settings-field"
              placeholder="lin_api_…"
              value=""
            />
            <button type="submit" class="subtle-button subtle-button--accent">Connect</button>
          </form>
          <p class="settings-help">The key is stored in ~/.cymphony/config.json and never shown again — only its last four characters.</p>
          <%= if @linear_error do %>
            <p class="settings-error"><%= @linear_error %></p>
          <% end %>
        </section>

        <section class="settings-group settings-group--projects">
          <h3 class="settings-group-title">Projects</h3>
          <%= if @linear_status.connected do %>
            <form
              id="add-project-form"
              phx-change="preview_add_project"
              phx-submit="add_project"
              class="settings-stack"
            >
              <label class="settings-field-row" for="add-project-slug-trigger">
                <span class="inline-label">Linear project</span>
                <.model_combobox
                  id="add-project-slug"
                  name="linear_project_slug"
                  value={@add_project_slug}
                  list_id="linear-project-slugs"
                  options={Enum.map(@linear_projects, &linear_project_option/1)}
                  placeholder="slug or ailogic-ced4159f70c4"
                  class="settings-field"
                  allow_custom={true}
                />
              </label>
              <div class="settings-field-grid">
                <label class="settings-field-row" for="add-project-name">
                  <span class="inline-label">name</span>
                  <input id="add-project-name" type="text" name="name" value={@add_project_name} phx-debounce="400" class="settings-field" />
                </label>
                <label class="settings-field-row" for="add-project-github">
                  <span class="inline-label">github</span>
                  <input id="add-project-github" type="text" name="github_repo_url" value={@add_project_github} phx-debounce="400" class="settings-field" />
                </label>
              </div>
              <div class="advanced-only add-project-advanced">
                <div class="settings-field-row">
                  <.spec_switcher
                    id="add-project-agent"
                    kind_name="agent"
                    model_id="add-project-model"
                    effort_id="add-project-effort"
                    list_id="model-suggestions-add-project"
                    kind={@add_project_kind}
                    model={@add_project_model}
                    effort={@add_project_effort}
                    placeholder="default"
                    blank={:default}
                    class="settings-field"
                  />
                </div>
                <%= if @add_project_kind == "claude" do %>
                  <label class="settings-field-row" for="add-project-provider">
                    <span class="inline-label">provider</span>
                    <input id="add-project-provider" type="text" name="provider" value={@add_project_provider} phx-debounce="400" class="settings-field" />
                  </label>
                <% end %>
              </div>
              <button type="submit" class="subtle-button subtle-button--accent settings-submit">Add project</button>
            </form>
            <p class="settings-help">The project starts immediately — no daemon restart.</p>
            <%= if @add_project_error do %>
              <p class="settings-error"><%= @add_project_error %></p>
            <% end %>
          <% else %>
            <p class="settings-help">Connect Linear to add a project</p>
          <% end %>
        </section>

        <section class="settings-group">
          <h3 class="settings-group-title simple-only">Automation</h3>
          <h3 class="settings-group-title advanced-only">Orchestrator</h3>

          <%= if @polling do %>
            <div class="settings-control-row">
              <%= if autonomy_state(@projects, @polling) == :paused do %>
                <button type="button" class="subtle-button subtle-button--accent settings-submit" phx-click="resume_dispatch">Resume all</button>
              <% else %>
                <button type="button" class="subtle-button settings-submit" phx-click="pause_dispatch">Pause all</button>
              <% end %>
              <p class="settings-help">Pausing stops new dispatches for every project and is remembered across restarts. Running sessions finish.</p>
            </div>
          <% end %>

          <div class="settings-control-row">
            <form phx-change="preview_field" phx-submit="set_concurrency" class="settings-inline settings-form">
              <input type="hidden" name="field" value="global-concurrency" />
              <label class="inline-label" for="drawer-global-concurrency">
                <span class="simple-only">tasks</span>
                <span class="advanced-only">concurrency</span>
              </label>
              <%!-- A blank box next to Set looked unfinished beside the prefilled
              refresh field. The fleet value is only a single number when every
              project agrees; when they disagree the field stays empty (submitting
              it would flatten the per-project values) and says so in its
              placeholder. --%>
              <input
                id="drawer-global-concurrency"
                type="number"
                name="value"
                min="1"
                value={field_value(@field_drafts, "global-concurrency", fleet_concurrency(@projects) || "")}
                placeholder={fleet_concurrency_placeholder(@projects)}
                phx-debounce="400"
                class="settings-field"
              />
              <button type="submit" class="subtle-button">Set</button>
            </form>
            <p class="settings-help">How many agent sessions may run at once, across every project.</p>
          </div>

          <div class="settings-control-row">
            <form phx-change="preview_field" phx-submit="set_refresh_interval" class="settings-inline settings-form">
              <input type="hidden" name="field" value="refresh-interval" />
              <label class="inline-label" for="drawer-refresh-interval">refresh (s)</label>
              <input
                id="drawer-refresh-interval"
                type="number"
                name="value"
                min="1"
                value={field_value(@field_drafts, "refresh-interval", @payload_refresh_seconds)}
                phx-debounce="400"
                class="settings-field"
              />
              <button type="submit" class="subtle-button">Set</button>
            </form>
            <p class="settings-help">Refresh (s): how often this dashboard re-reads orchestrator state — not Linear polling.</p>
          </div>
        </section>

        <%!-- Density, section/column visibility and the completions limit are pure
        localStorage state; the server always renders the same defaults, so every
        patch reset the radios/checkboxes/select and `syncPrefControls` repaired
        them asynchronously (a visible flicker). Freeze the subtree instead. --%>
        <section id="settings-display" class="settings-group advanced-only" data-prefs phx-update="ignore">
          <h3 class="settings-group-title">Display</h3>

          <div class="settings-row">
            <span class="inline-label">density</span>
            <label><input type="radio" name="pref-density" data-pref="density" value="comfortable" checked /> comfortable</label>
            <label><input type="radio" name="pref-density" data-pref="density" value="compact" /> compact</label>
          </div>

          <div class="settings-row">
            <span class="inline-label">sections</span>
            <%= for {label, key} <- [{"Metrics", "metrics"}, {"Polling", "polling"}, {"Rate limits", "ratelimits"}, {"Completions", "completions"}, {"States", "states"}, {"Kinds", "kinds"}, {"Board", "board"}] do %>
              <label><input type="checkbox" data-pref-section={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">columns</span>
            <%= for {label, key} <- [{"Title", "title"}, {"Chips", "chips"}, {"Runtime", "runtime"}, {"Tokens", "tokens"}] do %>
              <label><input type="checkbox" data-pref-col={key} checked /> <%= label %></label>
            <% end %>
          </div>

          <div class="settings-row">
            <span class="inline-label">completions shown</span>
            <select data-pref="completions-limit" class="inline-input inline-input--narrow">
              <option value="25">25</option>
              <option value="50">50</option>
              <option value="100" selected>100</option>
            </select>
          </div>

          <p class="settings-help">Display preferences live in this browser only — they never reach the orchestrator.</p>
        </section>
      </aside>

      <%!-- Flashes render in a fixed stack so an arriving toast never shifts
      the board; the stalled alert stays in flow because it is state, not a
      notification. --%>
      <div class="toast-stack" aria-live="polite">
        <%= if info = @flash["info"] do %>
          <div class="alert-banner alert-info"><%= info %></div>
        <% end %>
        <%= if err = @flash["error"] do %>
          <div class="alert-banner alert-error"><%= err %></div>
        <% end %>
      </div>
    </section>
    </div>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp spawn_payload_load(socket) do
    seq = next_payload_seq(socket)
    pid = self()

    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      send(pid, {:payload_loaded, seq, load_payload()})
    end)

    assign(socket, :payload_seq, seq)
  end

  # Use after a state-changing operation so the next render already shows the
  # updated value, not the previous one. Async refresh is fine for periodic
  # ticks but causes a one-frame flash of stale data on form submits.
  defp reload_payload_now(socket) do
    seq = next_payload_seq(socket)
    payload = load_payload()
    token_samples = update_token_samples(socket.assigns.token_samples, payload)

    socket
    |> assign(:payload_seq, seq)
    |> assign_payload_sections(payload)
    |> assign_token_throughput(token_samples)
    |> assign(:payload_dirty, false)
    |> assign(:last_payload_refresh, System.monotonic_time(:millisecond))
    |> update(:agent_setting_drafts, &prune_agent_drafts(&1, payload))
  end

  defp next_payload_seq(socket), do: (socket.assigns[:payload_seq] || 0) + 1

  # `:token_samples` must stay off the render path. It gains an entry on every
  # single payload load, so a dynamic reading it marks the template dirty on
  # every load — an idle board then shipped a diff per poll even though nothing
  # moved. Only the two derived *strings* are assigned; `assign/3` already skips
  # an identical value, so an idle load reassigns neither and the diff is empty.
  # The raw list stays in an assign nothing reads, which costs no diff at all.
  defp assign_token_throughput(socket, samples) do
    socket
    |> assign(:token_samples, samples)
    |> assign(:throughput_tps, format_tps(current_tps(samples)))
    |> assign(:throughput_spark, tps_sparkline(samples))
  end

  defp clear_field_draft(socket, key) do
    update(socket, :field_drafts, &Map.delete(&1, key))
  end

  # Draft once touched, payload while untouched: clearing the draft on a
  # successful submit is what lets an external `POST /api/v1/concurrency` (or
  # another tab) become visible in this control again.
  defp field_value(drafts, key, fallback) when is_map(drafts) do
    Map.get(drafts, key, fallback)
  end

  # The fleet-wide concurrency the drawer field can honestly prefill: one number
  # only while every project agrees on it.
  defp fleet_concurrency(projects) do
    case fleet_concurrency_values(projects) do
      [value] -> value
      _values -> nil
    end
  end

  defp fleet_concurrency_placeholder(projects) do
    case fleet_concurrency_values(projects) do
      [value] -> Integer.to_string(value)
      # No project reported a limit (disconnected render, older snapshot): name
      # the schema default rather than leave the box mute.
      [] -> @default_concurrency_label
      _values -> "mixed"
    end
  end

  defp fleet_concurrency_values(projects) when is_list(projects) do
    projects
    |> Enum.map(&Map.get(&1, :max_concurrent_agents))
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp fleet_concurrency_values(_projects), do: []

  defp reset_add_project_draft(socket) do
    socket
    |> assign(:add_project_slug, "")
    |> assign(:add_project_name, "")
    |> assign(:add_project_github, "")
    |> assign(:add_project_kind, "")
    |> assign(:add_project_model, "")
    |> assign(:add_project_effort, "")
    |> assign(:add_project_provider, "")
  end

  # Fan a freshly loaded payload out into one assign per section, skipping the
  # sections whose value did not change. Sections missing from the payload (error
  # snapshots, older orchestrator shapes) fall back to `@default_payload`.
  defp assign_payload_sections(socket, payload) do
    updated =
      Enum.reduce(@payload_sections, socket, fn {assign_key, payload_key}, acc ->
        assign_changed_section(acc, assign_key, payload_section(payload, payload_key))
      end)

    maybe_reanchor_clocks(updated, socket)
  end

  # `:now` is the anchor every server-rendered clock is derived from, and it is
  # read inside the per-project comprehension. A HEEx comprehension is a single
  # change-tracked slot: touching `:now` re-evaluates and re-serializes every
  # project header, queue card, session row and restart form, which is exactly
  # the work the section split exists to skip. So `:now` moves only when a
  # section a clock actually reads moved — never on a load that changed nothing
  # (or that only moved the poll countdown, which carries its own remaining-ms
  # anchor and needs no wall clock).
  defp maybe_reanchor_clocks(socket, previous) do
    if Enum.any?(@clock_sections, &section_moved?(previous, socket, &1)),
      do: assign(socket, :now, DateTime.utc_now()),
      else: socket
  end

  defp section_moved?(previous, socket, key) do
    Map.get(previous.assigns, key, :__absent__) != Map.fetch!(socket.assigns, key)
  end

  defp assign_changed_section(socket, key, value) do
    case socket.assigns do
      %{^key => current} ->
        if section_signature(key, current) == section_signature(key, value),
          do: socket,
          else: assign(socket, key, value)

      _assigns ->
        assign(socket, key, value)
    end
  end

  # A running entry's `tokens_per_second` is re-derived from the wall clock on
  # every load (tokens divided by seconds-since-start), so it drifts on its own
  # between two otherwise identical snapshots. Comparing it would make
  # `:running` and `:projects` differ on every single refresh and the skip above
  # would never fire while an agent is running — which is precisely when the
  # dashboard is busiest. Compare without it; the moment any real field moves the
  # whole fresh section lands in the assign, drifted rate included.
  #
  # The trade-off is visible: because a match keeps the *previous* section value,
  # the rendered `t/s` chip holds the rate from the last load that moved a real
  # field, so it does not decay while an agent sits in a long tool call. That is
  # deliberate — re-rendering the whole board to animate a number the server
  # derives from nothing but the clock is the churn this exists to remove.
  #
  # `:last_event_at` is the same class of noise: the harness heartbeat is a
  # timestamp-only stall poke (SPEC §10) fired every 2s while the CLI prints
  # anything, and it carries no operator-visible news — `last_event`,
  # `last_message`, `log_events` and `tokens` all stay in the signature and land
  # the fresh section wholesale the moment one of them moves. Without this, a
  # streaming agent reassigned `:running` and `:projects` every 2s, re-anchored
  # `:now`, and re-serialized every combobox in the project section.
  #
  # `:due_at` is an absolute time the presenter re-derives as `utc_now +
  # due_in_ms`, so it jitters by the snapshot round-trip; holding the previous
  # value is lossless because every real reschedule also moves `attempt`,
  # `held`, or `error`. The trade-off mirrors `t/s`: the expanded row's
  # `@ <timestamp>` holds the value from the last load that moved a real field.
  @volatile_entry_keys [:tokens_per_second, :last_event_at, :due_at]

  # `polling.next_poll_in_ms` is the same class of noise one level up. Unlike the
  # keys above it lives on a *section* map rather than on a list entry, so
  # `@volatile_entry_keys` never reaches it: the orchestrator re-derives it as
  # `max(0, next_poll_due_at_ms - now_ms)` from a per-call monotonic reading, so
  # it moves on literally every snapshot. Comparing it verbatim reassigned
  # `:polling` on every single payload load, which meant no load could ever ship
  # an empty diff — the acceptance this whole split exists for — and every
  # `dashboard_refresh_seconds` cost a full `#dashboard-root` morph.
  #
  # Holding the previous value is lossless. The countdown is rendered inside a
  # `data-clock="countdown"` span whose anchor is a remaining amount, and the
  # LiveClock hook advances it in the browser (clamping at `0s` once it runs past
  # the end). Every poll cycle flips `checking?` true on the tick and false again
  # when the cycle ends, and `checking?` *is* in the signature, so the fresh
  # section — refreshed countdown included — lands twice per poll.
  #
  # Only integer-to-integer drift is collapsed: `nil` means no poll is scheduled
  # at all, which drops the anchor and renders `n/a`, so it stays news.
  defp section_signature(:polling, %{} = polling),
    do: Map.replace_lazy(polling, :next_poll_in_ms, &countdown_signature/1)

  defp section_signature(_key, section), do: section_signature(section)

  defp section_signature(entries) when is_list(entries), do: Enum.map(entries, &entry_signature/1)

  defp section_signature(section), do: section

  defp countdown_signature(ms) when is_integer(ms), do: :counting
  defp countdown_signature(ms), do: ms

  defp entry_signature(%{} = entry) do
    entry
    |> Map.drop(@volatile_entry_keys)
    |> Map.replace_lazy(:running, &section_signature/1)
    |> Map.replace_lazy(:retrying, &section_signature/1)
  end

  defp payload_section(payload, key) do
    Map.get(payload, key, Map.fetch!(@default_payload, key))
  end

  # A successful submit keeps a confirmed draft so the immediate render shows
  # the submitted values; once the payload reflects them the draft is redundant
  # and must go, or it would shadow later server-side changes.
  defp confirmed_agent_draft(settings) do
    case Map.get(settings, "agent") do
      kind when is_binary(kind) and kind != "" ->
        %{kind: kind, model: Map.get(settings, "model", ""), effort: Map.get(settings, "effort", "")}

      _ ->
        nil
    end
  end

  defp prune_agent_drafts(drafts, payload) do
    Enum.reduce(Map.get(payload, :projects) || [], drafts, &prune_one_draft/2)
  end

  defp prune_one_draft(project, drafts) do
    case Map.get(drafts, Map.get(project, :name)) do
      %{} = draft -> maybe_prune_draft(drafts, project, draft)
      _ -> drafts
    end
  end

  defp maybe_prune_draft(drafts, project, draft) do
    kind = Map.get(project, :agent_kind)

    if Agent.known_kind?(kind) do
      persisted = project_agent_settings(%{}, project)

      if draft.kind == persisted.kind and draft.model == persisted.model and
           draft.effort == persisted.effort do
        Map.delete(drafts, Map.get(project, :name))
      else
        drafts
      end
    else
      drafts
    end
  end

  defp apply_confirmed_draft(drafts, project_name, nil), do: Map.delete(drafts, project_name)

  defp apply_confirmed_draft(drafts, project_name, confirmed),
    do: Map.put(drafts, project_name, confirmed)

  # Suggestions only — values are pass-through free text. Codex entries come
  # from the live `codex debug models` catalog (cached, PATH + ~/.local/bin);
  # claude from its stable alias vocabulary.
  defp model_suggestions(kind) do
    CymphonyElixir.AgentCatalog.models(kind)
  catch
    :exit, _reason -> []
  end

  defp effort_levels(kind) do
    CymphonyElixir.AgentCatalog.efforts(kind, nil)
  catch
    :exit, _reason -> []
  end

  # agy / CLI Proxy: reasoning is in the model slug. The control would only
  # persist a flag the adapter refuses to send.
  defp effort_visible?("antigravity"), do: false
  defp effort_visible?(_kind), do: true

  defp kind_strip_options(false), do: Agent.known_kinds()

  defp kind_strip_options(blank) when blank in [true, :keep, :default],
    do: ["" | Agent.known_kinds()]

  defp kind_strip_key(""), do: "blank"
  defp kind_strip_key(kind), do: kind

  defp spec_catalog_kind(kind, suggestion) do
    cond do
      Agent.known_kind?(kind) -> kind
      Agent.known_kind?(suggestion) -> suggestion
      true -> "claude"
    end
  end

  defp spec_icon_kind(kind, catalog_kind) do
    cond do
      Agent.known_kind?(kind) -> kind
      Agent.known_kind?(catalog_kind) -> catalog_kind
      true -> ""
    end
  end

  defp spec_model_label(_kind, model, placeholder) when model in [nil, ""], do: placeholder

  defp spec_model_label(kind, model, _placeholder) do
    case Enum.find(model_suggestions(kind), &(combobox_option_value(&1) == model)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> model
    end
  end

  defp spec_effort_row_value(effort, blank) when effort in [nil, ""] do
    cond do
      blank == :keep -> "keep"
      blank in [true, :default] -> "default"
      true -> "—"
    end
  end

  defp spec_effort_row_value(effort, _blank), do: effort_display(effort)

  defp effort_display("xhigh"), do: "Extra High"

  defp effort_display(value) when is_binary(value) and value != "" do
    value
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp effort_display(_), do: ""

  defp effort_option_label(option) do
    value = combobox_option_value(option)

    if value == "" do
      combobox_option_label(option)
    else
      effort_display(value)
    end
  end

  defp agent_icon_src("claude"), do: "/icons/claude.png"
  defp agent_icon_src("codex"), do: "/icons/codex.png"
  defp agent_icon_src("antigravity"), do: "/icons/agy.png"
  defp agent_icon_src(_kind), do: nil

  defp agent_kind_label("claude"), do: "Claude"
  defp agent_kind_label("codex"), do: "Codex"
  defp agent_kind_label("antigravity"), do: "Antigravity"
  defp agent_kind_label(kind) when is_binary(kind) and kind != "", do: kind
  defp agent_kind_label(_), do: "Agent"

  defp agent_strip_label("", :keep), do: "Keep current harness"
  defp agent_strip_label("", _), do: "Default agent"
  defp agent_strip_label(kind, _), do: agent_kind_label(kind)

  defp effort_menu_options(kind, false), do: Enum.map(effort_levels(kind), &%{value: &1, label: &1})

  defp effort_menu_options(kind, blank) when blank in [true, :keep, :default] do
    label = if blank == :default, do: "default", else: "keep"
    [%{value: "", label: label} | effort_menu_options(kind, false)]
  end

  # ---------------------------------------------------------------------------
  # Row components.
  #
  # These exist for change tracking, not for reuse. A `<% x = … %>` binding in a
  # HEEx template makes the compiler give up on every dynamic that follows it, so
  # one harness stdout line used to re-serialize the whole project section it sat
  # in — Comboboxes included — at up to ~12 patches/sec. A function component's
  # attrs are tracked individually: `tail` moving re-renders the harness pane and
  # nothing else, because `spec`/`expanded?` did not move. Keep them binding-free.
  # ---------------------------------------------------------------------------

  defp stalled_alert(assigns) do
    ~H"""
    <%= if @entries != [] and not @dismissed do %>
      <div class="alert-banner">
        <div class="alert-content">
          <strong>Stalled agents detected:</strong>
          <%= @entries |> Enum.map(& &1.issue_identifier) |> Enum.join(", ") %>
          <%= if length(@entries) == 1 do %>
            has been stalled for <span data-clock="elapsed" data-base-seconds={stall_seconds(hd(@entries).last_event_at, @now)}><%= format_stall_duration(hd(@entries).last_event_at, @now) %></span>.
          <% else %>
            have been stalled.
          <% end %>
        </div>
        <button type="button" class="subtle-button" phx-click="dismiss_stalled_alert">Dismiss</button>
      </div>
    <% end %>
    """
  end

  # Agent form + the Claude-only providers form. They are one component because
  # both read the resolved agent settings, and the providers form's visibility is
  # `settings.kind`; the Pause button stays a sibling after this, so it remains
  # the last child of `.project-section-controls`.
  defp project_agent_controls(assigns) do
    ~H"""
    <form
      phx-change="preview_project_agent"
      phx-submit="set_project_agent"
      class="project-agent-form advanced-only"
    >
      <input type="hidden" name="project" value={@project_name} />
      <.spec_switcher
        id={"agent-#{@project_name}"}
        model_id={"model-#{@project_name}"}
        effort_id={"effort-#{@project_name}"}
        list_id={"model-suggestions-#{@project_name}"}
        kind={@settings.kind}
        model={@settings.model}
        effort={@settings.effort}
        placeholder="default"
        title="Agent, model, and reasoning effort"
      />

      <button type="submit" class="subtle-button">Set</button>
    </form>

    <%= if @settings.kind == "claude" do %>
      <form
        phx-change="preview_field"
        phx-submit="set_project_providers"
        class="inline-form inline-form--wide advanced-only"
      >
        <input type="hidden" name="project" value={@project_name} />
        <input type="hidden" name="field" value={"providers:#{@project_name}"} />
        <label class="inline-label" for={"providers-#{@project_name}"}>providers</label>
        <input
          id={"providers-#{@project_name}"}
          type="text"
          name="value"
          value={@providers_value}
          placeholder="cv1,cz2,ck1"
          phx-debounce="400"
          class="inline-input"
          title="Comma-separated provider aliases (cli alias: c)"
        />
        <button type="submit" class="subtle-button">Save</button>
      </form>
    <% end %>
    """
  end

  defp queue_card(assigns) do
    ~H"""
    <article
      id={"queue-card-#{@project_name}-#{@entry.issue_identifier}"}
      class={queue_card_class(@rank, @editing?)}
      data-issue={@entry.issue_identifier}
      data-issue-id={@entry.issue_id}
      data-rank={@rank}
      data-rank-label={String.pad_leading(to_string(@rank + 1), 2, "0")}
      tabindex="0"
    >
      <div class="queue-card-body">
        <div class="queue-card-id">
          <%= if @rank == 0 do %>
            <span class="queue-next-badge" title="Starts when a slot opens">Next</span>
          <% end %>
          <%= if @entry.issue_url do %>
            <a href={@entry.issue_url} target="_blank" rel="noopener" class="session-row-link queue-card-link"><%= @entry.issue_identifier %></a>
          <% else %>
            <%= @entry.issue_identifier %>
          <% end %>
        </div>
        <div class="queue-card-title"><%= @entry.issue_title %></div>
        <button
          type="button"
          class="queue-card-edit-toggle"
          phx-click="toggle_queue_edit"
          phx-value-project={@project_name}
          phx-value-issue={@entry.issue_identifier}
        >
          Edit
        </button>
      </div>
      <%= if @editing? do %>
        <div
          class="queue-card-edit"
          id={"queue-edit-#{@project_name}-#{@entry.issue_identifier}"}
          phx-hook="QueueEditPanel"
          phx-click-away="dismiss_overlays"
        >
          <form
            class="queue-edit-form"
            phx-change="preview_queue_run_spec"
            phx-submit="set_queue_run_spec"
          >
            <input type="hidden" name="project" value={@project_name} />
            <input type="hidden" name="issue" value={@entry.issue_identifier} />
            <%!-- The panel is fixed-positioned and only the highlighted card
            behind it says which issue is being pinned. Name it inside the
            popover so the edit stays legible if QueueEditPanel flips the panel
            above the card or the operator scrolls mid-edit. --%>
            <span class="menu-field-label">Pin next run · <span class="mono"><%= @entry.issue_identifier %></span></span>
            <.spec_switcher
              id={"queue-agent-#{@entry.issue_identifier}"}
              model_id={"queue-model-#{@entry.issue_identifier}"}
              effort_id={"queue-effort-#{@entry.issue_identifier}"}
              list_id={"model-suggestions-queue-#{@entry.issue_identifier}"}
              kind={@spec.kind}
              model={@spec.model}
              effort={@spec.effort}
              suggestion_kind={@spec.suggestion_kind}
              placeholder="model"
            />
            <button type="submit" class="subtle-button subtle-button--accent queue-edit-pin">Pin</button>
          </form>
        </div>
      <% end %>
    </article>
    """
  end

  defp session_row(assigns) do
    ~H"""
    <article class={session_row_class(@expanded?)}>
      <div class="session-row-summary">
        <button
          type="button"
          class="session-row-disclosure"
          phx-click="toggle_logs"
          phx-value-issue={@entry.issue_identifier}
          aria-label={if @expanded?, do: "Collapse", else: "Expand"}
        ><%!-- The chevron is drawn in CSS and rotated by
          `.session-row--expanded`; a server-rendered glyph would
          be one more string every payload load rewrites. --%></button>

        <div class="session-row-id">
          <%= if @entry.issue_url do %>
            <a href={@entry.issue_url} target="_blank" rel="noopener" class="session-row-link"><%= @entry.issue_identifier %></a>
          <% else %>
            <%= @entry.issue_identifier %>
          <% end %>
        </div>

        <div class="session-row-title" title={@entry.issue_title || @entry.last_message || ""}>
          <%= @entry.issue_title || @entry.last_message || "" %>
        </div>

        <div class="session-row-chips">
          <span class={chip_state_class(@entry.state)}><%= @entry.state %></span>
          <%= if @entry.stalled do %>
            <span class="chip chip--danger">Stalled</span>
          <% end %>
          <%= if priority_label = priority_label(@entry.priority) do %>
            <span class={chip_priority_class(@entry.priority)}><%= priority_label %></span>
          <% end %>
          <%= if Map.get(@entry, :agent_kind) do %>
            <span class="chip chip--agent chip--icon advanced-only" title={@entry.agent_kind}>
              <.agent_icon kind={@entry.agent_kind} />
            </span>
          <% end %>
          <%= if Map.get(@entry, :model) do %>
            <span class="chip chip--muted chip--truncate advanced-only" title={@entry.model}><%= @entry.model %></span>
          <% end %>
          <%= if Map.get(@entry, :effort) do %>
            <span class="chip chip--muted advanced-only"><%= @entry.effort %></span>
          <% end %>
          <span class="chip chip--muted advanced-only"><%= @entry.worker_host || "local" %></span>
        </div>

        <div class="session-row-runtime numeric">
          <span data-clock="elapsed" data-base-seconds={runtime_seconds_from_started_at(@entry.started_at, @now)}><%= format_runtime_seconds(runtime_seconds_from_started_at(@entry.started_at, @now)) %></span>
        </div>

        <div class="session-row-tokens numeric" title={"In #{format_int(@entry.tokens.input_tokens)} / Out #{format_int(@entry.tokens.output_tokens)}"}>
          <%= format_int(@entry.tokens.total_tokens) %><%= if tps = format_session_tps(@entry) do %><span class="tps"> · <%= tps %> t/s</span><% end %>
        </div>

        <button
          type="button"
          class="subtle-button danger"
          phx-click="kill_issue"
          phx-value-issue={@entry.issue_identifier}
        >
          <span class="simple-only">Stop</span>
          <span class="advanced-only">Kill</span>
        </button>
      </div>

      <%= if @expanded? do %>
        <div class="session-row-detail">
          <p class="autonomy-note simple-only">
            Cymphony is continuing this task on its own. You can open the Linear issue for context or stop this run at any time.
          </p>
          <div class="session-row-detail-grid">
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Agent</span>
              <span class="session-stat-value" title={Map.get(@entry, :agent_kind) || "claude"}>
                <.agent_icon kind={Map.get(@entry, :agent_kind) || "claude"} />
              </span>
            </div>
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Model</span>
              <span class="session-stat-value"><%= Map.get(@entry, :model) || "default" %></span>
            </div>
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Effort</span>
              <span class="session-stat-value"><%= Map.get(@entry, :effort) || "default" %></span>
            </div>
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Tokens</span>
              <span class="session-stat-value numeric">
                <%= format_int(@entry.tokens.total_tokens) %>
                <span class="muted small">(in <%= format_int(@entry.tokens.input_tokens) %> / out <%= format_int(@entry.tokens.output_tokens) %>)</span>
              </span>
            </div>
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Turn</span>
              <span class="session-stat-value numeric"><%= @entry.turn_count %></span>
            </div>
            <div class="session-stat advanced-only">
              <span class="session-stat-label">Session</span>
              <span class="session-stat-value">
                <%= if @entry.session_id do %>
                  <button
                    type="button"
                    class="subtle-button"
                    data-label="Copy ID"
                    data-copy={@entry.session_id}
                    onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                  >Copy ID</button>
                <% else %>
                  <span class="muted">n/a</span>
                <% end %>
              </span>
            </div>
            <div class="session-stat session-stat--wide advanced-only">
              <span class="session-stat-label">Workspace</span>
              <span class="session-stat-value">
                <%= if @entry.workspace_path do %>
                  <span class="mono workspace-path"><%= @entry.workspace_path %></span>
                  <button
                    type="button"
                    class="subtle-button"
                    data-label="Copy"
                    data-copy={@entry.workspace_path}
                    onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                  >Copy</button>
                <% else %>
                  <span class="muted">n/a</span>
                <% end %>
              </span>
            </div>
            <div class="session-stat session-stat--wide restart-with advanced-only">
              <span class="session-stat-label">Restart with</span>
              <form
                phx-change="preview_issue_run_spec"
                phx-submit="set_issue_run_spec"
                class="restart-form"
              >
                <input type="hidden" name="issue" value={@entry.issue_identifier} />
                <.spec_switcher
                  id={"restart-agent-#{@entry.issue_identifier}"}
                  model_id={"restart-model-#{@entry.issue_identifier}"}
                  effort_id={"restart-effort-#{@entry.issue_identifier}"}
                  list_id={"model-suggestions-session-#{@entry.issue_identifier}"}
                  kind={@spec.kind}
                  model={@spec.model}
                  effort={@spec.effort}
                  suggestion_kind={@spec.suggestion_kind}
                  placeholder="keep"
                  blank={:keep}
                  title="Harness, model, and reasoning effort"
                />
                <%= if @spec.suggestion_kind == "claude" do %>
                  <div class="provider-switcher">
                    <label class="inline-label" for={"restart-provider-#{@entry.issue_identifier}"}>
                      Provider
                    </label>
                    <input
                      id={"restart-provider-#{@entry.issue_identifier}"}
                      type="text"
                      name="provider"
                      value={@spec.provider}
                      placeholder="provider"
                      phx-debounce="400"
                      class="inline-input inline-input--model"
                      title="Provider auth alias (empty = keep resolved)"
                    />
                  </div>
                <% end %>
                <button type="submit" class="subtle-button" title="Kill this session and restart it immediately with these overrides">Restart</button>
              </form>
              <span class="muted small">Restart kills the session and redispatches with these overrides.</span>
            </div>
          </div>

          <%= if @entry.last_event do %>
            <div class="session-row-activity">
              <span class="session-stat-label simple-only">Latest update</span>
              <span class={log_event_badge_class(@entry.last_event) <> " advanced-only"}><%= @entry.last_event %></span>
              <span class="session-activity-message"><%= @entry.last_message || "n/a" %></span>
              <%= if @entry.last_event_at do %>
                <span class="mono numeric muted small advanced-only">@ <%= @entry.last_event_at %></span>
              <% end %>
            </div>
          <% end %>

          <%= if @entry.log_events == [] do %>
            <p class="empty-state advanced-only">No log events yet.</p>
          <% else %>
            <ul class="log-list advanced-only">
              <li :for={log <- @entry.log_events} class="log-event">
                <span class="log-event-at"><%= format_log_at(log.at) %></span>
                <span class={log_event_badge_class(log.event)}><%= log.event %></span>
                <span class="log-event-message"><%= format_log_message(log.message) %></span>
              </li>
            </ul>
          <% end %>

          <%!-- `@tail` is the only attr a harness stdout line moves, so this pane
          is the only dynamic re-serialized for it. --%>
          <section
            id={"harness-tail-" <> @entry.issue_identifier}
            class="harness-tail advanced-only"
            phx-hook="HarnessTail"
            data-follow={if Map.get(@tail, :follow, true), do: "true", else: "false"}
          >
            <header class="harness-tail-header">
              <span class="harness-tail-title">Harness</span>
              <button type="button" class="subtle-button" phx-click="toggle_harness_follow" phx-value-issue={@entry.issue_identifier}>
                <%= if Map.get(@tail, :follow, true), do: "Following", else: "Paused" %>
              </button>
            </header>
            <pre class="harness-tail-body"><%= for line <- Map.get(@tail, :lines, []) do %><div class="harness-tail-line" data-seq={line_seq(line)}><%= line_text(line) %></div><% end %></pre>
          </section>
        </div>
      <% end %>
    </article>
    """
  end

  defp spec_switcher(assigns) do
    assigns =
      assigns
      |> assign_new(:kind, fn -> "" end)
      |> assign_new(:model, fn -> "" end)
      |> assign_new(:effort, fn -> "" end)
      |> assign_new(:kind_name, fn -> "agent_kind" end)
      |> assign_new(:model_name, fn -> "model" end)
      |> assign_new(:effort_name, fn -> "effort" end)
      |> assign_new(:blank, fn -> false end)
      |> assign_new(:allow_custom, fn -> true end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:title, fn -> nil end)
      |> assign_new(:placeholder, fn -> "model" end)
      |> assign_new(:suggestion_kind, fn -> nil end)
      |> assign_new(:list_id, fn -> "model-suggestions-#{assigns.id}" end)
      |> assign_new(:effort_list_id, fn -> "effort-options-#{assigns.id}" end)

    catalog_kind = spec_catalog_kind(assigns.kind, assigns.suggestion_kind)

    assigns =
      assigns
      |> assign(:catalog_kind, catalog_kind)
      |> assign(:models, model_suggestions(catalog_kind))
      |> assign(:efforts, effort_menu_options(catalog_kind, assigns.blank))
      |> assign(:show_effort?, effort_visible?(catalog_kind))
      |> assign(:kinds, kind_strip_options(assigns.blank))
      |> assign(:model_label, spec_model_label(catalog_kind, assigns.model, assigns.placeholder))
      |> assign(:effort_label, spec_effort_row_value(assigns.effort, assigns.blank))
      |> assign(:icon_kind, spec_icon_kind(assigns.kind, catalog_kind))
      |> assign(:empty_model?, assigns.model in [nil, ""])

    ~H"""
    <div
      id={"spec-switcher-#{@id}"}
      class={["spec-switcher", @class]}
      phx-hook="SpecSwitcher"
      data-allow-custom={to_string(@allow_custom)}
    >
      <button
        type="button"
        id={"#{@id}-trigger"}
        class={["spec-switcher-trigger", @empty_model? && "spec-switcher-trigger--empty"]}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-panel"}
        title={@title}
      >
        <.agent_icon kind={@icon_kind} />
        <span class="spec-switcher-trigger-text">
          <span class="spec-switcher-model"><%= @model_label %></span>
          <%= if @show_effort? and @effort_label not in [nil, ""] and not @empty_model? do %>
            <span class="spec-switcher-effort"><%= @effort_label %></span>
          <% end %>
        </span>
      </button>
      <input type="hidden" name={@kind_name} id={@id} value={@kind} data-spec="kind" />
      <input type="hidden" name={@model_name} id={@model_id} value={@model} data-spec="model" />
      <%= if @show_effort? do %>
        <input type="hidden" name={@effort_name} id={@effort_id} value={@effort} data-spec="effort" />
      <% end %>
      <div id={"#{@id}-panel"} class="spec-switcher-panel" role="menu" hidden>
        <div class="spec-switcher-agents" role="group" aria-label="Agent">
          <button
            :for={kind <- @kinds}
            :key={kind_strip_key(kind)}
            type="button"
            class={["spec-switcher-agent", @kind == kind && "is-selected"]}
            data-kind={kind}
            aria-pressed={to_string(@kind == kind)}
            aria-label={agent_strip_label(kind, @blank)}
            title={agent_strip_label(kind, @blank)}
          >
            <.agent_icon kind={kind} />
          </button>
        </div>
        <div class="spec-switcher-divider" role="separator"></div>
        <button type="button" class="spec-switcher-row" data-menu="model" role="menuitem">
          <span class="spec-switcher-row-label">Model</span>
          <span class="spec-switcher-row-value"><%= @model_label %></span>
          <span class="spec-switcher-row-chevron" aria-hidden="true"></span>
        </button>
        <%= if @show_effort? do %>
          <button type="button" class="spec-switcher-row" data-menu="effort" role="menuitem">
            <span class="spec-switcher-row-label">Effort</span>
            <span class="spec-switcher-row-value"><%= @effort_label %></span>
            <span class="spec-switcher-row-chevron" aria-hidden="true"></span>
          </button>
        <% end %>
        <div class="spec-switcher-flyout" data-menu="model" hidden>
          <input
            id={"#{@model_id}-input"}
            type="text"
            class="spec-switcher-search"
            autocomplete="off"
            placeholder="Filter"
          />
          <ul id={@list_id} class="spec-switcher-list" role="listbox">
            <li
              :for={option <- @models}
              :key={combobox_option_value(option)}
              id={combobox_option_dom_id(@list_id, combobox_option_value(option))}
              role="option"
              data-value={combobox_option_value(option)}
              data-label={combobox_option_label(option)}
              aria-selected="false"
              aria-checked={to_string(combobox_option_value(option) == @model)}
            >
              <span class="spec-switcher-option-label"><%= combobox_option_label(option) %></span>
              <span class="spec-switcher-check" aria-hidden="true"></span>
            </li>
          </ul>
        </div>
        <%= if @show_effort? do %>
          <div class="spec-switcher-flyout" data-menu="effort" hidden>
            <ul id={@effort_list_id} class="spec-switcher-list" role="listbox">
              <li
                :for={option <- @efforts}
                :key={combobox_option_value(option)}
                id={combobox_option_dom_id(@effort_list_id, combobox_option_value(option))}
                role="option"
                data-value={combobox_option_value(option)}
                data-label={combobox_option_label(option)}
                aria-selected="false"
                aria-checked={to_string(combobox_option_value(option) == @effort)}
              >
                <span class="spec-switcher-option-label"><%= effort_option_label(option) %></span>
                <span class="spec-switcher-check" aria-hidden="true"></span>
              </li>
            </ul>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp agent_icon(assigns) do
    assigns = assign_new(assigns, :kind, fn -> "" end)

    ~H"""
    <%= if agent_icon_src(@kind) do %>
      <img
        class={["agent-icon", "agent-icon--" <> @kind]}
        src={agent_icon_src(@kind)}
        alt={@kind}
        width="16"
        height="16"
        draggable="false"
      />
    <% else %>
      <span class="agent-icon agent-icon--empty" aria-hidden="true"></span>
    <% end %>
    """
  end

  defp model_combobox(assigns) do
    assigns =
      assigns
      |> assign_new(:value, fn -> "" end)
      |> assign_new(:placeholder, fn -> "" end)
      |> assign_new(:title, fn -> nil end)
      |> assign_new(:class, fn -> nil end)
      |> assign_new(:options, fn -> [] end)
      |> assign_new(:allow_custom, fn -> false end)

    trigger = combobox_trigger_label(assigns.value, assigns.options, assigns.placeholder)

    assigns = assign(assigns, :trigger_label, trigger)

    ~H"""
    <div
      id={"combobox-#{@id}"}
      class="combobox combobox--menu"
      phx-hook="Combobox"
      data-allow-custom={to_string(@allow_custom)}
      data-placeholder={@placeholder}
    >
      <button
        type="button"
        id={"#{@id}-trigger"}
        class={["combobox-trigger", @class, @value in [nil, ""] && "combobox-trigger--empty"]}
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={@list_id}
        title={@title}
      >
        <span class="combobox-trigger-label"><%= @trigger_label %></span>
      </button>
      <input type="hidden" name={@name} id={@id} value={@value} />
      <div class="combobox-panel" hidden>
        <input
          id={"#{@id}-input"}
          type="text"
          class="combobox-search"
          role="combobox"
          aria-autocomplete="list"
          aria-expanded="false"
          aria-controls={@list_id}
          aria-activedescendant=""
          autocomplete="off"
          placeholder="Filter"
        />
        <ul id={@list_id} class="combobox-list" role="listbox">
          <%!-- Binding-free like every other row here: `<% value = … %>` would
          disable change tracking for the option attributes that follow it. --%>
          <li
            :for={option <- @options}
            :key={combobox_option_value(option)}
            id={combobox_option_dom_id(@list_id, combobox_option_value(option))}
            role="option"
            data-value={combobox_option_value(option)}
            data-label={combobox_option_label(option)}
          >
            <%= combobox_option_label(option) %>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp combobox_trigger_label(value, _options, placeholder) when value in [nil, ""], do: placeholder

  defp combobox_trigger_label(value, options, _placeholder) do
    case Enum.find(options, &(combobox_option_value(&1) == value)) do
      nil -> value
      option -> combobox_option_label(option)
    end
  end

  defp combobox_option_value(%{value: value}) when is_binary(value), do: value
  defp combobox_option_value(%{slug_id: slug}) when is_binary(slug), do: slug
  defp combobox_option_value(%{"slug_id" => slug}) when is_binary(slug), do: slug
  defp combobox_option_value(%{"value" => value}) when is_binary(value), do: value
  defp combobox_option_value(value) when is_binary(value), do: value
  defp combobox_option_value(value), do: to_string(value)

  defp combobox_option_label(%{label: label}) when is_binary(label) and label != "", do: label

  defp combobox_option_label(%{name: name} = option) when is_binary(name) and name != "" do
    case combobox_option_value(option) do
      "" -> name
      slug -> "#{name} (#{slug})"
    end
  end

  defp combobox_option_label(%{"name" => name} = option) when is_binary(name) and name != "" do
    case combobox_option_value(option) do
      "" -> name
      slug -> "#{name} (#{slug})"
    end
  end

  defp combobox_option_label(option), do: combobox_option_value(option)

  defp combobox_option_dom_id(list_id, value) do
    slug =
      value
      |> to_string()
      |> String.replace(non_id_char_regex(), "-")
      |> String.trim("-")

    slug = if slug == "", do: "empty", else: slug
    "#{list_id}-#{slug}"
  end

  defp non_id_char_regex, do: Regex.compile!("[^A-Za-z0-9_-]+")

  # Anchor target for a project section and for the rail link that jumps to it.
  # Case is preserved so two projects differing only by case keep distinct ids;
  # only characters an HTML id cannot carry are folded.
  defp project_dom_id(name) do
    name
    |> to_string()
    |> String.replace(non_id_char_regex(), "-")
  end

  # LED colour for a rail link. Paused outranks retrying outranks running so the
  # rail answers "is this project working?" in one glance; it reads the same
  # `@projects` section the board does and never a clock.
  defp rail_state(project) do
    cond do
      Map.get(project, :paused, false) -> "paused"
      Map.get(project, :retrying, []) != [] -> "retry"
      Map.get(project, :running, []) != [] -> "run"
      true -> "idle"
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
  end

  # Routed through `Control` (not `Orchestrator` directly) so the header toggle
  # persists `dispatch_paused` exactly like the global Pause/Resume buttons and
  # `POST /api/v1/pause`.
  # `Control.pause/1` and `resume/1` apply to the orchestrators first and then
  # persist `dispatch_paused`, so an error means "in effect now, but gone after
  # the next daemon restart". Reporting that as plain success is how a paused
  # fleet silently comes back dispatching; the board is reloaded either way
  # because the orchestrator half did happen.
  defp flash_dispatch_result(socket, :ok, message) do
    reload_payload_now(put_flash(socket, :info, message))
  end

  defp flash_dispatch_result(socket, {:error, _reason}, message) do
    reload_payload_now(put_flash(socket, :error, "#{message}, but the change could not be saved to ~/.cymphony/config.json"))
  end

  defp toggle_project_pause(projects, project_name) do
    project = Enum.find(projects, &(&1.name == project_name))
    scope = {:project, project_name}

    if Map.get(project || %{}, :paused, false) == true do
      Control.resume(scope)
    else
      Control.pause(scope)
    end
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(token_totals) do
    Map.get(token_totals, :seconds_running) || 0
  end

  defp autonomy_state([_project | _rest] = projects, _polling) do
    project_count = length(projects)
    paused_count = Enum.count(projects, &Map.get(&1, :paused, false))

    cond do
      paused_count == 0 -> :on
      paused_count == project_count -> :paused
      true -> {:partial, project_count - paused_count, project_count}
    end
  end

  defp autonomy_state(_projects, %{paused: true}), do: :paused
  defp autonomy_state(_projects, %{}), do: :on
  defp autonomy_state(_projects, _polling), do: :unknown

  defp session_run_spec_settings(drafts, entry) do
    default_kind = Map.get(entry, :agent_kind) || ""

    default = %{
      kind: default_kind,
      model: Map.get(entry, :model) || "",
      effort: Map.get(entry, :effort) || "",
      provider: Map.get(entry, :provider) || "",
      suggestion_kind: suggestion_kind(default_kind, entry)
    }

    case Map.get(drafts, entry.issue_identifier) do
      nil ->
        default

      draft ->
        kind = Map.get(draft, :kind, default_kind)

        %{
          kind: kind,
          model: Map.get(draft, :model, default.model),
          effort: Map.get(draft, :effort, default.effort),
          provider: Map.get(draft, :provider, default.provider),
          suggestion_kind: suggestion_kind(kind, entry)
        }
    end
  end

  defp suggestion_kind(kind, entry) do
    if Agent.known_kind?(kind) do
      kind
    else
      Map.get(entry, :agent_kind)
    end
  end

  defp preview_issue_run_spec(socket, issue_identifier, kind, params) do
    if kind == "" or Agent.known_kind?(kind) do
      {:noreply, put_issue_run_spec_draft(socket, issue_identifier, kind, params)}
    else
      {:noreply, socket}
    end
  end

  defp put_issue_run_spec_draft(socket, issue_identifier, kind, params) do
    entry = find_running_entry(socket.assigns.running, issue_identifier)
    current = session_run_spec_settings(socket.assigns.issue_run_spec_drafts, entry)
    agent_changed? = current.kind != kind

    draft = %{
      kind: kind,
      model: if(agent_changed?, do: "", else: Map.get(params, "model", "")),
      effort: if(agent_changed?, do: "", else: Map.get(params, "effort", "")),
      provider: Map.get(params, "provider", current.provider)
    }

    assign(socket, :issue_run_spec_drafts, Map.put(socket.assigns.issue_run_spec_drafts, issue_identifier, draft))
  end

  defp project_waiting(project) when is_map(project) do
    case Map.get(project, :waiting, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp project_waiting(_project), do: []

  defp project_waiting_count(project) do
    case Map.fetch(project, :waiting_count) do
      {:ok, count} when is_integer(count) -> count
      _ -> length(project_waiting(project))
    end
  end

  defp project_section_class(project, queue_edit_ids) do
    paused? = Map.get(project, :paused, false)
    edit_open? = queue_edit_open?(queue_edit_ids, Map.get(project, :name))

    ["project-section", paused? && "project-section--paused", edit_open? && "is-queue-edit-open"]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp queue_card_class(rank, editing?) do
    ["queue-card", rank == 0 && "queue-card--next", editing? && "is-editing"]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp session_row_class(true), do: "session-row session-row--expanded"
  defp session_row_class(_expanded?), do: "session-row"

  defp harness_tail(tails, entry) do
    Map.get(tails, entry.issue_identifier, %{
      issue_id: Map.get(entry, :issue_id),
      last_seq: 0,
      lines: [],
      follow: true
    })
  end

  # A held entry is not counting down and not failing — it is parked because
  # dispatch is paused. `.retry-row--held` mutes the amber retry edge so a paused
  # board does not read as a wall of warnings.
  defp retry_row_class(entry) do
    if Map.get(entry, :held), do: "retry-row retry-row--held", else: "retry-row"
  end

  defp queue_edit_open?(ids, project_name) do
    Enum.any?(ids, fn
      {^project_name, _issue} -> true
      _ -> false
    end)
  end

  defp queue_order_attr(waiting) do
    waiting
    |> Enum.map(& &1.issue_identifier)
    |> Jason.encode!()
  end

  defp queue_run_spec_settings(drafts, project, entry) when is_map(project) do
    inherited = inherited_queue_run_spec(project, entry)

    case Map.get(drafts, {Map.get(project, :name), entry.issue_identifier}) do
      nil ->
        inherited

      draft ->
        kind = Map.get(draft, :kind, inherited.kind)

        %{
          kind: kind,
          model: Map.get(draft, :model, inherited.model),
          effort: Map.get(draft, :effort, inherited.effort),
          suggestion_kind: suggestion_kind(kind, entry)
        }
    end
  end

  defp inherited_queue_run_spec(project, entry) do
    project_settings = project_agent_settings(%{}, project)
    kind = present_run_spec(Map.get(entry, :agent_kind)) || project_settings.kind

    %{
      kind: kind,
      model: present_run_spec(Map.get(entry, :model)) || project_settings.model,
      effort: present_run_spec(Map.get(entry, :effort)) || project_settings.effort,
      suggestion_kind: suggestion_kind(kind, entry)
    }
  end

  defp present_run_spec(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_run_spec(_value), do: nil

  defp put_queue_run_spec_draft(socket, project_name, issue, kind, params) do
    if kind == "" or Agent.known_kind?(kind) do
      project =
        Enum.find(socket.assigns.projects, &(&1.name == project_name)) ||
          %{name: project_name}

      entry = find_waiting_entry(socket.assigns.projects, project_name, issue)
      current = queue_run_spec_settings(socket.assigns.queue_run_spec_drafts, project, entry)
      inherited = inherited_queue_run_spec(project, entry)
      agent_changed? = current.kind != kind

      {model, effort} =
        cond do
          not agent_changed? ->
            {Map.get(params, "model", current.model), Map.get(params, "effort", current.effort)}

          kind != "" and kind == inherited.kind ->
            {inherited.model, inherited.effort}

          true ->
            {"", ""}
        end

      draft = %{
        kind: kind,
        model: model,
        effort: effort
      }

      assign(
        socket,
        :queue_run_spec_drafts,
        Map.put(socket.assigns.queue_run_spec_drafts, {project_name, issue}, draft)
      )
    else
      socket
    end
  end

  defp find_waiting_entry(projects, project_name, identifier) do
    project = Enum.find(projects, &(&1.name == project_name)) || %{}

    Enum.find(project_waiting(project), &(&1.issue_identifier == identifier)) ||
      %{issue_identifier: identifier}
  end

  defp queue_pin_from_params(params) do
    %{}
    |> maybe_override_agent_kind(params["agent_kind"] || params["kind"])
    |> maybe_skip_keep(:model, params["model"])
    |> maybe_skip_keep(:effort, params["effort"])
  end

  defp maybe_skip_keep(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      "keep" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp maybe_skip_keep(map, _key, _value), do: map

  defp persist_queue_order(project_name, raw_order) do
    if blank_project_scope?(project_name) do
      {:error, :invalid_scope}
    else
      with {:ok, order} <- parse_queue_order_param(raw_order) do
        orch_result = call_project_orchestrator(project_name, {:reorder_queue, order})
        control_or_orch(Control, :set_queue_order, [{:project, project_name}, order], orch_result)
      end
    end
  end

  defp persist_queue_pin(project_name, issue_key, pin) do
    if blank_project_scope?(project_name) do
      {:error, :invalid_scope}
    else
      orch_result = call_project_orchestrator(project_name, {:set_queue_pin, issue_key, pin})
      control_or_orch(Control, :set_queue_pin, [{:project, project_name}, issue_key, pin], orch_result)
    end
  end

  defp blank_project_scope?(project_name) do
    not is_binary(project_name) or String.trim(project_name) == ""
  end

  defp parse_queue_order_param(raw) do
    case normalize_queue_order(raw) do
      :error -> :error
      order -> Control.parse_queue_order(order)
    end
  end

  defp control_or_orch(module, fun, args, orch_result) do
    if function_exported?(module, fun, length(args)) do
      try do
        case apply(module, fun, args) do
          :ok -> :ok
          _other -> orch_result
        end
      rescue
        UndefinedFunctionError -> orch_result
      end
    else
      orch_result
    end
  end

  defp normalize_queue_order(order) when is_list(order) do
    Enum.reduce_while(order, [], fn
      id, acc when is_binary(id) ->
        case String.trim(id) do
          "" -> {:halt, :error}
          trimmed -> {:cont, acc ++ [trimmed]}
        end

      _, _acc ->
        {:halt, :error}
    end)
  end

  defp normalize_queue_order(order) when is_map(order) do
    order
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(to_string(key)) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> Enum.map(fn {_key, value} -> value end)
    |> normalize_queue_order()
  end

  defp normalize_queue_order(order) when is_binary(order) do
    case Jason.decode(order) do
      {:ok, decoded} ->
        normalize_queue_order(decoded)

      _ ->
        order
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> normalize_queue_order()
    end
  end

  defp normalize_queue_order(_order), do: :error

  defp optimistic_reorder_queue(socket, project_name, raw_order) do
    order =
      case normalize_queue_order(raw_order) do
        :error -> []
        list -> list
      end

    projects =
      Enum.map(socket.assigns.projects, fn project ->
        if project.name == project_name,
          do: reorder_project_waiting(project, order),
          else: project
      end)

    assign(socket, :projects, projects)
  end

  defp reorder_project_waiting(project, order) do
    waiting = project_waiting(project)
    by_id = Map.new(waiting, &{&1.issue_identifier, &1})
    reordered = Enum.flat_map(order, &List.wrap(Map.get(by_id, &1)))
    leftover = Enum.reject(waiting, &(&1.issue_identifier in order))
    Map.put(project, :waiting, reordered ++ leftover)
  end

  defp call_project_orchestrator(project_name, message) do
    pid = lookup_orchestrator(project_name)

    if orchestrator_addressable?(pid) do
      try do
        GenServer.call(pid, message, 10_000)
      catch
        :exit, _ -> {:error, :unavailable}
      end
    else
      {:error, :not_found}
    end
  end

  defp project_agent_settings(drafts, project) do
    kind = Map.get(project, :agent_kind)

    default = %{
      kind: if(Agent.known_kind?(kind), do: kind, else: ""),
      model: Map.get(project, :agent_model) || "",
      effort: Map.get(project, :agent_effort) || ""
    }

    Map.get(drafts, project.name, default)
  end

  defp preview_project_agent(socket, project_name, kind, params) do
    project =
      Enum.find(socket.assigns.projects, &(&1.name == project_name)) ||
        %{name: project_name}

    current = project_agent_settings(socket.assigns.agent_setting_drafts, project)
    agent_changed? = current.kind != kind

    draft = %{
      kind: kind,
      model: if(agent_changed?, do: "", else: Map.get(params, "model", "")),
      effort: if(agent_changed?, do: "", else: Map.get(params, "effort", ""))
    }

    socket =
      assign(socket, :agent_setting_drafts, Map.put(socket.assigns.agent_setting_drafts, project_name, draft))

    # An empty kind drafts model/effort without persisting or reloading: there is
    # no kind to write, and a reload here would throw the draft away.
    if agent_changed? and Agent.known_kind?(kind) do
      persist_preview_agent_kind(socket, project_name, kind)
    else
      socket
    end
  end

  defp persist_preview_agent_kind(socket, project_name, kind) do
    case Control.set_agent_settings({:project, project_name}, %{"agent" => kind}) do
      :ok ->
        reload_payload_now(socket)

      {:error, reason} ->
        put_flash(socket, :error, preview_agent_persist_error(project_name, reason))
    end
  end

  defp preview_agent_persist_error(project_name, :not_found), do: "Project not found: #{project_name}"
  defp preview_agent_persist_error(_project_name, _reason), do: "Could not persist agent settings"

  defp total_runtime_seconds(token_totals, running, now) do
    completed_runtime_seconds(token_totals) +
      Enum.reduce(running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  # Past the hour a minutes-only counter ("260m 44s") reads as a raw tick count,
  # and it is the band's largest numeral. Roll it into hours. The LiveClock
  # `formatElapsed` in layouts.ex mirrors this branch byte for byte (pinned by
  # extensions_test.exs) — the two sides must move in the same commit or a clock
  # rewrites itself the first time the hook paints over the server text.
  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    hours = div(whole_seconds, 3_600)
    mins = div(rem(whole_seconds, 3_600), 60)
    secs = rem(whole_seconds, 60)

    if hours > 0 do
      "#{hours}h #{mins}m #{secs}s"
    else
      "#{mins}m #{secs}s"
    end
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(Regex.compile!(".{3}(?=.)", "s"), "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp priority_label(1), do: "Urgent"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Medium"
  defp priority_label(4), do: "Low"
  defp priority_label(_), do: nil

  defp chip_priority_class(1), do: "chip chip--danger"
  defp chip_priority_class(2), do: "chip chip--warn"
  defp chip_priority_class(3), do: "chip chip--accent"
  defp chip_priority_class(4), do: "chip chip--muted"
  defp chip_priority_class(_), do: "chip"

  defp chip_state_class(state) do
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "chip chip--ok"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "chip chip--danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "chip chip--warn"
      true -> "chip"
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp format_log_at(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_log_at(at) when is_binary(at), do: at
  defp format_log_at(_), do: "n/a"

  defp format_log_message(nil), do: ""

  defp format_log_message(message) when is_binary(message) do
    if String.length(message) > 200 do
      String.slice(message, 0, 200) <> "…"
    else
      message
    end
  end

  defp format_log_message(message) do
    inspect(message, pretty: true, limit: 80)
  end

  defp log_event_badge_class(event) when is_binary(event) or is_atom(event) do
    base = "log-event-name"
    normalized = event |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["error", "failed", "exit"]) -> "#{base} log-event-danger"
      String.contains?(normalized, ["started", "ready", "dispatched"]) -> "#{base} log-event-success"
      String.contains?(normalized, ["completed", "ended"]) -> "#{base} log-event-accent"
      true -> base
    end
  end

  # `next_poll_in_ms` is already a remaining amount, so this needs no wall clock:
  # reading `@now` here would only add a false dependency on an assign that has
  # nothing to do with the countdown.
  defp format_poll_countdown(ms) when is_integer(ms) do
    seconds = max(div(ms, 1_000), 0)
    "#{seconds}s"
  end

  defp format_poll_countdown(_ms), do: "n/a"

  # Anchor for the LiveClock hook: milliseconds left, never an absolute time.
  # nil drops the attribute so the hook leaves the server-rendered text alone.
  defp poll_remaining_ms(ms) when is_integer(ms), do: max(ms, 0)
  defp poll_remaining_ms(_ms), do: nil

  defp stalled_running_entries(running) do
    Enum.filter(running, & &1.stalled)
  end

  defp stall_seconds(%DateTime{} = last_event_at, %DateTime{} = now) do
    DateTime.diff(now, last_event_at, :second)
  end

  defp stall_seconds(last_event_at, %DateTime{} = now) when is_binary(last_event_at) do
    case DateTime.from_iso8601(last_event_at) do
      {:ok, parsed, _offset} -> stall_seconds(parsed, now)
      _ -> nil
    end
  end

  defp stall_seconds(_last_event_at, _now), do: nil

  defp format_stall_duration(last_event_at, now) do
    case stall_seconds(last_event_at, now) do
      nil -> "unknown"
      seconds -> format_runtime_seconds(seconds)
    end
  end

  defp retry_remaining_ms(due_at, %DateTime{} = now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, parsed, _offset} -> DateTime.diff(parsed, now, :second) * 1_000
      _ -> nil
    end
  end

  defp retry_remaining_ms(_due_at, _now), do: nil

  defp format_retry_countdown(due_at, now) do
    case retry_remaining_ms(due_at, now) do
      nil -> "n/a"
      ms when ms > 0 -> format_runtime_seconds(div(ms, 1_000))
      _ms -> "now"
    end
  end

  defp update_token_samples(samples, payload) do
    now_ms = System.monotonic_time(:millisecond)
    total_tokens = get_in(payload, [:token_totals, :total_tokens]) || 0

    samples =
      [{now_ms, total_tokens} | samples]
      |> Enum.filter(fn {ts, _} -> now_ms - ts <= 600_000 end)
      |> Enum.take(200)

    samples
  end

  defp current_tps([]), do: 0.0
  defp current_tps([_]), do: 0.0

  defp current_tps(samples) do
    {start_ms, start_tokens} = List.last(samples)
    {end_ms, end_tokens} = List.first(samples)
    elapsed_ms = end_ms - start_ms
    delta_tokens = max(0, end_tokens - start_tokens)

    if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
  end

  defp format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  defp group_thousands(value) when is_binary(value) do
    value
    |> String.reverse()
    |> String.replace(Regex.compile!("(\\d{3})(?=\\d)"), "\\1,")
    |> String.reverse()
  end

  @sparkline_blocks ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
  @sparkline_columns 24
  @sparkline_window_ms 600_000

  defp tps_sparkline([]), do: ""
  defp tps_sparkline([_]), do: ""

  defp tps_sparkline(samples) do
    now_ms = System.monotonic_time(:millisecond)
    bucket_ms = div(@sparkline_window_ms, @sparkline_columns)
    active_bucket_start = div(now_ms, bucket_ms) * bucket_ms
    graph_window_start = active_bucket_start - (@sparkline_columns - 1) * bucket_ms
    rates = interval_rates(samples)

    bucketed_tps =
      Enum.map(0..(@sparkline_columns - 1), fn bucket_idx ->
        bucket_start = graph_window_start + bucket_idx * bucket_ms
        bucket_end = bucket_start + bucket_ms
        last_bucket? = bucket_idx == @sparkline_columns - 1
        bucket_average_tps(rates, bucket_start, bucket_end, last_bucket?)
      end)

    render_sparkline(bucketed_tps)
  end

  # @token_samples is newest-first; sort oldest→newest so each interval has
  # positive elapsed_ms (newer - older) instead of a flat zero-rate sparkline.
  defp interval_rates(samples) do
    samples
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&interval_rate/1)
  end

  defp interval_rate([{start_ms, start_tokens}, {end_ms, end_tokens}]) do
    elapsed_ms = end_ms - start_ms
    delta_tokens = max(0, end_tokens - start_tokens)
    tps = if elapsed_ms <= 0, do: 0.0, else: delta_tokens / (elapsed_ms / 1000.0)
    {end_ms, tps}
  end

  defp bucket_average_tps(rates, bucket_start, bucket_end, last_bucket?) do
    values =
      rates
      |> Enum.filter(fn {timestamp, _tps} ->
        in_sparkline_bucket?(timestamp, bucket_start, bucket_end, last_bucket?)
      end)
      |> Enum.map(fn {_timestamp, tps} -> tps end)

    if values == [] do
      0.0
    else
      Enum.sum(values) / length(values)
    end
  end

  defp in_sparkline_bucket?(timestamp, bucket_start, bucket_end, true),
    do: timestamp >= bucket_start and timestamp <= bucket_end

  defp in_sparkline_bucket?(timestamp, bucket_start, bucket_end, false),
    do: timestamp >= bucket_start and timestamp < bucket_end

  defp render_sparkline(bucketed_tps) do
    max_tps = Enum.max(bucketed_tps, fn -> 0.0 end)

    Enum.map_join(bucketed_tps, fn value ->
      Enum.at(@sparkline_blocks, sparkline_index(value, max_tps), "▁")
    end)
  end

  defp sparkline_index(_value, max_tps) when max_tps <= 0, do: 0

  defp sparkline_index(value, max_tps) do
    round(value / max_tps * (length(@sparkline_blocks) - 1))
  end

  defp send_issue_command(socket, issue_identifier, command) do
    entry =
      Enum.find(socket.assigns.running, &(&1.issue_identifier == issue_identifier)) ||
        Enum.find(socket.assigns.retrying, &(&1.issue_identifier == issue_identifier)) ||
        %{}

    issue_id = Map.get(entry, :issue_id)
    project_name = Map.get(entry, :project_name)
    orchestrator_pid = lookup_orchestrator(project_name)
    pid = self()

    if is_binary(issue_id) and orchestrator_addressable?(orchestrator_pid) do
      Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
        try do
          GenServer.call(orchestrator_pid, {command, issue_id}, 10_000)
        catch
          :exit, _ -> {:error, :unavailable}
        end

        # The repaint used to come for free from the orchestrator's own
        # broadcast; now that a broadcast only marks the payload dirty, the
        # operator-initiated command has to ask for the reload itself — and
        # after the call, so the reload cannot race ahead of the state change.
        send(pid, :reload_payload_now)
      end)
    end

    socket
  end

  defp orchestrator_addressable?(pid) when is_pid(pid), do: true
  defp orchestrator_addressable?(name) when is_atom(name) and not is_nil(name), do: true
  defp orchestrator_addressable?({:via, _, _}), do: true
  defp orchestrator_addressable?({:global, _}), do: true
  defp orchestrator_addressable?(_), do: false

  defp lookup_orchestrator(project_name) when is_binary(project_name) do
    case CymphonyElixir.ProjectSupervisor.lookup(project_name, :orchestrator) do
      pid when is_pid(pid) -> pid
      _ -> orchestrator()
    end
  end

  defp lookup_orchestrator(_), do: orchestrator()

  defp maybe_override_param(map, _key, nil), do: map

  defp maybe_override_param(map, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> map
      trimmed -> Map.put(map, key, trimmed)
    end
  end

  defp maybe_override_agent_kind(map, value) when is_binary(value) do
    trimmed = String.trim(value)

    if Agent.known_kind?(trimmed) do
      Map.put(map, :agent_kind, trimmed)
    else
      map
    end
  end

  defp maybe_override_agent_kind(map, _value), do: map

  defp expand_harness_tail(socket, identifier) do
    entry = find_running_entry(socket.assigns.running, identifier)
    issue_id = Map.get(entry, :issue_id)

    if is_binary(issue_id) and issue_id != "" do
      # EP-STREAM
      _ = ObservabilityPubSub.subscribe_harness(issue_id)
      snapshot = CymphonyElixir.HarnessStream.snapshot(issue_id)

      tail = %{
        issue_id: Map.get(snapshot, :issue_id, issue_id),
        last_seq: Map.get(snapshot, :last_seq, 0),
        lines: Map.get(snapshot, :lines, []),
        follow: true,
        dropped: Map.get(snapshot, :dropped, 0)
      }

      assign(socket, :harness_tails, Map.put(socket.assigns.harness_tails, identifier, tail))
    else
      socket
    end
  end

  defp collapse_harness_tail(socket, identifier) do
    case Map.get(socket.assigns.harness_tails, identifier) do
      %{issue_id: issue_id} when is_binary(issue_id) ->
        # EP-STREAM
        _ = ObservabilityPubSub.unsubscribe_harness(issue_id)

      _ ->
        :ok
    end

    assign(socket, :harness_tails, Map.delete(socket.assigns.harness_tails, identifier))
  end

  defp find_running_entry(running, identifier) do
    Enum.find(running, &(&1.issue_identifier == identifier)) || %{}
  end

  # An idle board has nothing to break down. Rendering the empty string left the
  # States/Kinds cells as label-only hairline compartments in the hero band — the
  # first-run impression read as broken chrome — so show a quiet placeholder mark
  # instead, and let `count_breakdown_class/1` mute the cell that carries it.
  defp format_count_breakdown(counts) do
    case count_breakdown_entries(counts) do
      [] -> @count_breakdown_placeholder
      entries -> Enum.map_join(entries, " · ", fn {key, count} -> "#{key} #{count}" end)
    end
  end

  defp count_breakdown_class(counts) do
    case count_breakdown_entries(counts) do
      [] -> "metric-pill-value metric-pill-placeholder"
      _entries -> "metric-pill-value"
    end
  end

  defp count_breakdown_entries(counts) when is_map(counts) do
    counts
    |> Enum.filter(fn {_key, count} -> is_number(count) and count > 0 end)
    |> Enum.sort_by(fn {key, count} -> {-count, to_string(key)} end)
    |> Enum.take(3)
  end

  defp count_breakdown_entries(_counts), do: []

  defp format_session_tps(entry) when is_map(entry) do
    case Map.get(entry, :tokens_per_second) do
      tps when is_number(tps) and tps > 0 -> :erlang.float_to_binary(tps * 1.0, decimals: 1)
      _ -> nil
    end
  end

  defp merge_harness_tail(acc, identifier, tail, id, seq, new_lines, dropped) do
    if Map.get(tail, :issue_id) == id do
      Map.put(acc, identifier, append_harness_tail(tail, seq, new_lines, dropped))
    else
      acc
    end
  end

  defp append_harness_tail(tail, seq, new_lines, dropped) do
    current_seq = Map.get(tail, :last_seq, 0)

    incoming =
      new_lines
      |> List.wrap()
      |> Enum.filter(fn line -> line_seq(line) > current_seq end)

    merged = Enum.take(Map.get(tail, :lines, []) ++ incoming, -@harness_tail_cap)

    tail
    |> Map.put(:lines, merged)
    |> Map.put(:last_seq, harness_tail_last_seq(merged, current_seq, seq))
    |> Map.put(:dropped, dropped)
  end

  defp harness_tail_last_seq(merged, current_seq, seq) do
    merged
    |> Enum.map(&line_seq/1)
    |> Enum.max(fn -> current_seq end)
    |> max(normalize_harness_seq(seq))
  end

  defp normalize_harness_seq(seq) when is_integer(seq), do: seq
  defp normalize_harness_seq(_seq), do: 0

  defp line_seq(%{seq: seq}), do: seq
  defp line_seq(%{"seq" => seq}), do: seq
  defp line_seq(_line), do: 0

  defp line_text(%{text: text}), do: to_string(text)
  defp line_text(%{"text" => text}), do: to_string(text)
  defp line_text(_line), do: ""

  defp send_issue_run_spec(socket, entry, issue_id, overrides) do
    project_name = Map.get(entry, :project_name)
    orchestrator_pid = lookup_orchestrator(project_name)
    pid = self()

    if orchestrator_addressable?(orchestrator_pid) do
      Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
        try do
          GenServer.call(orchestrator_pid, {:set_issue_run_spec, issue_id, overrides}, 10_000)
        catch
          :exit, _ -> {:error, :unavailable}
        end

        send(pid, :reload_payload_now)
      end)
    end

    socket
  end

  defp enqueue_linear_projects_load do
    pid = self()

    Task.Supervisor.start_child(CymphonyElixir.TaskSupervisor, fn ->
      result =
        case Control.list_linear_projects() do
          {:ok, list} when is_list(list) -> list
          {:error, reason} -> {:error, reason}
        end

      send(pid, {:linear_projects_loaded, result})
    end)

    :ok
  end

  defp draft_add_project_field(params, "agent", socket, assign_key) do
    case params["agent"] || params["value"] do
      value when is_binary(value) -> value
      _ -> socket.assigns[assign_key] || ""
    end
  end

  defp draft_add_project_field(params, key, socket, assign_key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> socket.assigns[assign_key] || ""
    end
  end

  defp add_project_attrs(params) when is_map(params) do
    required = Map.take(params, ["name", "linear_project_slug"])

    optional =
      params
      |> Map.take(["github_repo_url", "workspace_root", "agent", "model", "effort", "provider"])
      |> Enum.reduce(%{}, fn
        {_key, value}, acc when not is_binary(value) ->
          acc

        {key, value}, acc ->
          case String.trim(value) do
            "" -> acc
            trimmed -> Map.put(acc, key, trimmed)
          end
      end)

    Map.merge(required, optional)
  end

  defp project_attr(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp linear_project_option(project) do
    slug = linear_project_slug(project)
    name = linear_project_name(project)

    label =
      cond do
        name != "" and slug != "" -> "#{name} (#{slug})"
        slug != "" -> slug
        true -> name
      end

    %{value: slug, label: label}
  end

  defp linear_project_name(project) do
    Map.get(project, :name) || Map.get(project, "name") || ""
  end

  defp linear_project_slug(project) do
    Map.get(project, :slug_id) || Map.get(project, "slug_id") || ""
  end

  defp linear_connect_error_message(:empty), do: "API key cannot be empty"

  defp linear_connect_error_message(reason) when reason in [:unauthorized, :invalid] do
    "Linear rejected that API key"
  end

  defp linear_connect_error_message({:workflow_rewrite_failed, _project, _reason}) do
    "Linear key was saved, but a project workflow could not be updated"
  end

  defp linear_connect_error_message(_reason), do: "Could not reach Linear"

  defp add_project_error_message(:duplicate_name), do: "A project with that name already exists"
  defp add_project_error_message(:duplicate_slug), do: "A project with that Linear slug already exists"
  defp add_project_error_message(:not_connected), do: "Connect Linear to add a project"
  defp add_project_error_message(:invalid_project), do: "Name and Linear project are required"
  defp add_project_error_message({:project_start_failed, _reason}), do: "Project was saved but failed to start"
  defp add_project_error_message({:workflow_write_failed, _reason}), do: "Project was saved but its workflow could not be generated"
  defp add_project_error_message(_reason), do: "Could not add project"
end
