defmodule CymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Cymphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias CymphonyElixir.{Agent, CompletionStore, HarnessStream}
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.ShellProvider
  alias CymphonyElixirWeb.{Control, Endpoint, Presenter}
  alias Plug.Conn

  @completed_default_limit 100
  @completed_max_limit 1_000

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec projects(Conn.t(), map()) :: Conn.t()
  def projects(conn, _params) do
    case Presenter.projects_payload() do
      {:error, :snapshot_unavailable} ->
        error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")

      projects ->
        json(conn, %{projects: projects})
    end
  end

  @spec create_project(Conn.t(), map()) :: Conn.t()
  def create_project(conn, params) do
    case Control.add_project(project_attrs(params)) do
      {:ok, project} ->
        conn
        |> put_status(202)
        |> json(%{
          name: project["name"],
          linear_project_slug: project["linear_project_slug"],
          started: true
        })

      {:error, :not_connected} ->
        error_response(conn, 422, "not_connected", "Connect Linear to add a project")

      {:error, :invalid_project} ->
        error_response(conn, 422, "invalid_project", "Project name and Linear slug are required")

      {:error, :duplicate_name} ->
        error_response(conn, 422, "duplicate_project_name", "A project with that name already exists")

      {:error, :duplicate_slug} ->
        error_response(conn, 422, "duplicate_project_slug", "A project with that Linear slug already exists")

      {:error, {:project_start_failed, _reason}} ->
        error_response(conn, 422, "project_start_failed", "Project was saved but failed to start")

      {:error, {:workflow_write_failed, _reason}} ->
        error_response(conn, 422, "project_workflow_failed", "Project was saved but its workflow could not be generated")

      {:error, _reason} ->
        error_response(conn, 422, "invalid_project", "Could not add project")
    end
  end

  @spec linear(Conn.t(), map()) :: Conn.t()
  def linear(conn, _params) do
    json(conn, Control.linear_status())
  end

  @spec connect_linear(Conn.t(), map()) :: Conn.t()
  def connect_linear(conn, params) do
    case Control.connect_linear(linear_api_key_param(params)) do
      {:ok, status} ->
        conn
        |> put_status(202)
        |> json(status)

      {:error, :empty} ->
        error_response(conn, 422, "empty_api_key", "API key cannot be empty")

      {:error, :unauthorized} ->
        error_response(conn, 422, "linear_unauthorized", "Linear rejected that API key")

      {:error, :invalid} ->
        error_response(conn, 422, "invalid_api_key", "Linear rejected that API key")

      {:error, {:workflow_rewrite_failed, _project, _reason}} ->
        error_response(conn, 422, "linear_workflow_rewrite_failed", "Linear key was saved, but a project workflow could not be updated")

      {:error, _reason} ->
        error_response(conn, 422, "linear_error", "Could not reach Linear")
    end
  end

  @spec linear_projects(Conn.t(), map()) :: Conn.t()
  def linear_projects(conn, _params) do
    case Control.list_linear_projects() do
      {:ok, projects} ->
        json(conn, %{projects: Enum.map(projects, &linear_project_payload/1)})

      {:error, :not_connected} ->
        error_response(conn, 422, "linear_not_connected", "Connect Linear to list projects")

      {:error, :empty} ->
        error_response(conn, 422, "linear_not_connected", "Connect Linear to list projects")

      {:error, :unauthorized} ->
        error_response(conn, 422, "linear_unauthorized", "Linear rejected that API key")

      {:error, _reason} ->
        error_response(conn, 422, "linear_error", "Could not reach Linear")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    project = conn.query_params["project"]

    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms(), project) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec harness(Conn.t(), map()) :: Conn.t()
  def harness(conn, %{"issue_identifier" => issue_identifier}) do
    project = conn.query_params["project"]

    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms(), project) do
      {:ok, %{status: "running", issue_id: issue_id}} when is_binary(issue_id) and issue_id != "" ->
        payload = Map.merge(HarnessStream.snapshot(issue_id), %{issue_identifier: issue_identifier})
        json(conn, payload)

      _ ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @doc """
  Persists the dashboard payload refresh interval. Distinct from `refresh/2`
  (Linear poll). Ignores `?project=`.
  """
  @spec refresh_interval(Conn.t(), map()) :: Conn.t()
  def refresh_interval(conn, params) do
    case Control.parse_concurrency(params["value"]) do
      {:ok, n} ->
        persist_refresh_interval(conn, n)

      :error ->
        error_response(
          conn,
          422,
          "invalid_refresh_interval",
          "refresh interval 'value' must be a positive integer"
        )
    end
  end

  # The interval is only useful if it was written: this route is the only one in
  # the family that used to discard the result and answer 202 regardless, so a
  # config store that could not be read or written silently reverted the setting
  # on the next restart. `/api/v1/pause` already reports its persist failure.
  defp persist_refresh_interval(conn, n) do
    case Control.set_dashboard_refresh_seconds(n) do
      :ok ->
        conn
        |> put_status(202)
        |> json(%{dashboard_refresh_seconds: n})

      {:error, _reason} ->
        error_response(
          conn,
          422,
          "refresh_interval_not_persisted",
          "refresh interval could not be saved to ~/.cymphony/config.json"
        )
    end
  end

  @spec completed(Conn.t(), map()) :: Conn.t()
  def completed(conn, params) do
    project_filter = normalize_project(params["project"])

    entries =
      case parse_limit(params["limit"]) do
        {:explicit, limit} ->
          load_completed_from_store(project_filter, limit)

        :default ->
          load_completed_from_snapshot(project_filter)
      end

    json(conn, %{recent_completed: entries})
  end

  defp load_completed_from_store(project_filter, limit) do
    selector = project_filter || :all

    CompletionStore.recent(selector, limit)
    |> Enum.map(&Presenter.completed_entry_payload/1)
  end

  defp load_completed_from_snapshot(project_filter) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
    entries = Map.get(payload, :recent_completed, [])

    case project_filter do
      nil -> entries
      project -> Enum.filter(entries, &(&1.project_name == project))
    end
  end

  defp normalize_project(nil), do: nil
  defp normalize_project(""), do: nil
  defp normalize_project(project) when is_binary(project), do: project
  defp normalize_project(_), do: nil

  defp parse_limit(nil), do: :default
  defp parse_limit(""), do: :default

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> {:explicit, min(n, @completed_max_limit)}
      _ -> {:explicit, @completed_default_limit}
    end
  end

  defp parse_limit(value) when is_integer(value) and value > 0,
    do: {:explicit, min(value, @completed_max_limit)}

  defp parse_limit(_), do: :default

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    respond_dispatch_paused(conn, Control.pause(Control.scope(params["project"])), params["project"], true)
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, params) do
    respond_dispatch_paused(conn, Control.resume(Control.scope(params["project"])), params["project"], false)
  end

  # `dispatch_paused` is documented as durable, so a persist failure is not a
  # 202: the orchestrators flipped, but the next daemon restart undoes it.
  # Answering `{"paused": true}` here is how a fleet an operator stopped comes
  # back dispatching with nothing having reported a problem.
  defp respond_dispatch_paused(conn, :ok, project, paused?) do
    conn |> put_status(202) |> json(%{paused: paused?, project: project})
  end

  defp respond_dispatch_paused(conn, {:error, :not_found}, project, _paused?) do
    error_response(conn, 422, "project_not_found", "No orchestrator is registered for project #{inspect(project)}")
  end

  defp respond_dispatch_paused(conn, {:error, _reason}, _project, paused?) do
    error_response(
      conn,
      422,
      "dispatch_pause_not_persisted",
      "Dispatch is now #{if paused?, do: "paused", else: "resumed"}, but the flag could not be written to config.json"
    )
  end

  @spec concurrency(Conn.t(), map()) :: Conn.t()
  def concurrency(conn, params) do
    project = params["project"]

    case Control.parse_concurrency(params["value"]) do
      {:ok, n} ->
        case control_scope(project) do
          {:ok, scope} ->
            respond_control_change(
              conn,
              Control.set_concurrency(scope, n),
              %{max_concurrent_agents: n, project: project},
              "concurrency_not_persisted",
              "Concurrency was applied, but could not be saved to config.json"
            )

          :error ->
            error_response(conn, 422, "invalid_scope", "project must be a name")
        end

      :error ->
        error_response(
          conn,
          422,
          "invalid_concurrency",
          "concurrency 'value' must be a positive integer"
        )
    end
  end

  @spec providers(Conn.t(), map()) :: Conn.t()
  def providers(conn, params) do
    project = params["project"]

    case parse_providers(params["value"]) do
      {:ok, list} ->
        case control_scope(project) do
          {:ok, scope} ->
            respond_control_change(
              conn,
              Control.set_providers(scope, list),
              %{providers: list, project: project},
              "providers_not_persisted",
              "Providers were applied, but could not be saved to config.json"
            )

          :error ->
            error_response(conn, 422, "invalid_scope", "project must be a name")
        end

      :error ->
        error_response(
          conn,
          422,
          "invalid_providers",
          "providers 'value' must be a non-empty comma-separated list"
        )
    end
  end

  @spec agent(Conn.t(), map()) :: Conn.t()
  def agent(conn, params) do
    project = params["project"]

    case Control.parse_agent_settings(params) do
      {:ok, settings} ->
        case control_scope(project) do
          {:ok, scope} ->
            respond_control_change(
              conn,
              Control.set_agent_settings(scope, settings),
              %{
                agent: settings["agent"],
                model: settings["model"],
                effort: settings["effort"],
                project: project
              },
              "agent_settings_not_persisted",
              "Agent settings were applied, but could not be fully saved"
            )

          :error ->
            error_response(conn, 422, "invalid_scope", "project must be a name")
        end

      :error ->
        error_response(
          conn,
          422,
          "invalid_agent_settings",
          "body must include at least one of kind/model/effort; kind must be one of: " <> Enum.join(Agent.known_kinds(), ", ")
        )
    end
  end

  @doc """
  Replaces the waiting-list order for `?project=` (required). Distinct from
  Linear priority. No Linear writes.
  """
  @spec queue(Conn.t(), map()) :: Conn.t()
  def queue(conn, params) do
    case required_project(params) do
      :error ->
        error_response(conn, 422, "invalid_scope", "query param 'project' is required")

      {:ok, project} ->
        case Control.parse_queue_order(params["order"]) do
          {:ok, order} ->
            respond_queue_order(conn, project, order)

          :error ->
            error_response(
              conn,
              422,
              "invalid_queue_order",
              "body 'order' must be a list of issue identifiers"
            )
        end
    end
  end

  @doc """
  Pins agent/model/effort for one waiting issue on `?project=` (required).
  Empty/`keep` fields are skipped. Does not kill a session. No Linear writes.
  """
  @spec queue_pin(Conn.t(), map()) :: Conn.t()
  def queue_pin(conn, params) do
    case required_project(params) do
      :error ->
        error_response(conn, 422, "invalid_scope", "query param 'project' is required")

      {:ok, project} ->
        case Control.parse_queue_pin(params) do
          {:ok, {issue, pin}} ->
            respond_queue_pin(conn, project, issue, pin)

          :error ->
            error_response(
              conn,
              422,
              "invalid_queue_pin",
              "body must include issue and at least one of kind/model/effort; kind must be one of: " <>
                Enum.join(Agent.known_kinds(), ", ")
            )
        end
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp respond_control_change(conn, :ok, payload, _code, _message) do
    conn |> put_status(202) |> json(payload)
  end

  defp respond_control_change(conn, {:error, :not_found}, _payload, _code, _message) do
    error_response(conn, 422, "project_not_found", "No orchestrator is registered for that project")
  end

  defp respond_control_change(conn, {:error, _reason}, _payload, code, message) do
    error_response(conn, 422, code, message)
  end

  defp control_scope(project) when is_binary(project) or is_nil(project),
    do: {:ok, Control.scope(project)}

  defp control_scope(_project), do: :error

  defp linear_api_key_param(params) when is_map(params) do
    case Map.get(params, "api_key") do
      key when is_binary(key) -> key
      _ -> ""
    end
  end

  defp project_attrs(params) when is_map(params) do
    [
      "name",
      "linear_project_slug",
      "github_repo_url",
      "workspace_root",
      "agent",
      "model",
      "effort",
      "provider"
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(params, key) do
        value when is_binary(value) -> Map.put(acc, key, String.trim(value))
        _ -> acc
      end
    end)
  end

  defp linear_project_payload(project) when is_map(project) do
    %{
      id: project[:id] || project["id"],
      name: project[:name] || project["name"],
      slug_id: project[:slug_id] || project["slug_id"]
    }
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || CymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp parse_providers(value) when is_binary(value) do
    case CymphonyConfig.parse_providers_csv(value) do
      {:ok, list} -> {:ok, list}
      {:error, _reason} -> :error
    end
  end

  defp parse_providers(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      list = value |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      if list != [] and Enum.all?(list, &ShellProvider.valid_name?/1), do: {:ok, list}, else: :error
    else
      :error
    end
  end

  defp parse_providers(_), do: :error

  defp required_project(params) when is_map(params) do
    case Map.get(params, "project") do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  defp respond_queue_order(conn, project, order) do
    case Control.set_queue_order({:project, project}, order) do
      :ok ->
        conn
        |> put_status(202)
        |> json(%{order: order, project: project})

      {:error, reason} when reason in [:invalid_scope, :not_found] ->
        error_response(conn, 422, "invalid_scope", "query param 'project' is required")

      {:error, _reason} ->
        error_response(conn, 422, "invalid_queue_order", "Could not persist queue order")
    end
  end

  defp respond_queue_pin(conn, project, issue, pin) do
    case Control.set_queue_pin({:project, project}, issue, pin) do
      :ok ->
        conn
        |> put_status(202)
        |> json(%{
          issue: issue,
          agent_kind: pin["agent_kind"],
          model: pin["model"],
          effort: pin["effort"],
          project: project
        })

      {:error, reason} when reason in [:invalid_scope, :not_found] ->
        error_response(conn, 422, "invalid_scope", "query param 'project' is required")

      {:error, _reason} ->
        error_response(conn, 422, "invalid_queue_pin", "Could not persist queue pin")
    end
  end
end
