defmodule CymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Current status: {{ issue.state }}
  URL: {{ issue.url }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}

  Review re-entry:
  - A Linear comment alone is not the trigger. When a human moves an issue from Human Review back to In Progress, treat new human comments as the work request.
  - If an attached PR already exists, read issue comments and PR comments before changing code.
  - Ignore agent workpad/progress comments and maintain this workpad checkpoint: Last processed human comment: <comment id or timestamp>
  - For merge-conflict requests, update the existing PR branch with latest origin/main, resolve conflicts, rerun validation, push, and move back to Human Review only after checks are green.
  """

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        normalize_workflow_prompt(prompt)

      _ ->
        @default_prompt_template
    end
  end

  @doc "Uses the built-in prompt for a blank body without consulting any workflow store."
  @spec normalize_workflow_prompt(String.t()) :: String.t()
  def normalize_workflow_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "", do: @default_prompt_template, else: prompt
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:cymphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        # The supervision tree boots before the CLI has generated/pointed at a
        # workflow file (Burrito release path), so a missing config must mean
        # "no port configured", never a boot crash.
        case settings() do
          {:ok, settings} -> settings.server.port
          {:error, _reason} -> nil
        end
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec validate!(Schema.t()) :: :ok | {:error, term()}
  def validate!(%Schema{} = settings) do
    validate_semantics(settings)
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
