defmodule CymphonyElixir.Agent.Codex do
  @moduledoc """
  Codex CLI adapter: builds `codex exec --json` (or `codex exec resume <id>`)
  commands and parses the JSONL event stream into the normalized turn result.

  Sandbox is always passed as `-c sandbox_mode=…` because `codex exec resume`
  does not accept the `-s` shorthand.
  """

  @behaviour CymphonyElixir.Agent

  alias CymphonyElixir.Mcp.Command

  @mcp_server_name "cymphony-linear"

  @impl true
  def default_command, do: "codex"

  @impl true
  def auth_env_prefixes, do: ["OPENAI_", "CODEX_", "API_TIMEOUT"]

  @impl true
  def auth_env_fallback, do: ["OPENAI_API_KEY"]

  @impl true
  def build_command(%{settings: settings} = run_spec) do
    command =
      case run_spec.command || settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> default_command()
      end

    subcommand =
      case run_spec.session_id do
        session_id when is_binary(session_id) and session_id != "" ->
          ["exec", "resume", shell_escape(session_id)]

        _ ->
          ["exec"]
      end

    args =
      ["--json", "--skip-git-repo-check"]
      |> maybe_add_model(run_spec.model)
      |> add_config_override("sandbox_mode", toml_string(settings.sandbox))
      |> maybe_add_network_access(settings)
      |> maybe_add_effort(run_spec.effort)
      |> maybe_add_mcp_overrides(run_spec.mcp_descriptor)
      |> maybe_add_extra_args(Map.get(settings, :extra_args))

    {:ok, Enum.join([command | subcommand] ++ args ++ [shell_escape(run_spec.prompt)], " ")}
  end

  @impl true
  def parse_output(lines, _run_spec, on_message) do
    initial = %{session_id: nil, last_message: nil, completed: nil, failed: nil}

    state =
      Enum.reduce(lines, initial, fn line, acc ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            emit(on_message, %{event: :stream_event, payload: event, raw: line})
            integrate_event(acc, event)

          _other ->
            # Blank lines, stderr noise, and non-object JSON are ignored.
            acc
        end
      end)

    cond do
      is_map(state.failed) ->
        {:error, {:turn_failed, CymphonyElixir.Agent.redact_payload(state.failed)}}

      is_map(state.completed) ->
        {:ok,
         %{
           session_id: state.session_id,
           result: state.last_message,
           usage: normalize_usage(state.completed["usage"]),
           raw: Jason.encode!(state.completed)
         }}

      true ->
        {:error, {:no_result_in_stream, transcript_excerpt(lines)}}
    end
  end

  defp integrate_event(acc, event) do
    acc
    |> maybe_take_thread_id(event)
    |> integrate_typed_event(event)
  end

  # Prefer thread.started; if it is missing, accept thread_id from any later event.
  defp maybe_take_thread_id(acc, %{"type" => "thread.started", "thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    %{acc | session_id: thread_id}
  end

  defp maybe_take_thread_id(%{session_id: nil} = acc, %{"thread_id" => thread_id})
       when is_binary(thread_id) and thread_id != "" do
    %{acc | session_id: thread_id}
  end

  defp maybe_take_thread_id(acc, _event), do: acc

  defp integrate_typed_event(acc, %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}})
       when is_binary(text),
       do: %{acc | last_message: text}

  defp integrate_typed_event(acc, %{"type" => "turn.completed"} = event), do: %{acc | completed: event}
  defp integrate_typed_event(acc, %{"type" => "turn.failed"} = event), do: %{acc | failed: event["error"] || event}
  defp integrate_typed_event(acc, _event), do: acc

  defp normalize_usage(%{} = usage) do
    input = integer_or_zero(usage["input_tokens"])
    output = integer_or_zero(usage["output_tokens"])

    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
  end

  defp normalize_usage(_usage), do: nil

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp maybe_add_model(args, model) when is_binary(model) and model != "",
    do: args ++ ["-m", shell_escape(model)]

  defp maybe_add_model(args, _model), do: args

  defp maybe_add_effort(args, effort) when is_binary(effort) and effort != "",
    do: add_config_override(args, "model_reasoning_effort", toml_string(effort))

  defp maybe_add_effort(args, _effort), do: args

  defp maybe_add_network_access(args, %{sandbox: "workspace-write", network_access: true}),
    do: add_config_override(args, "sandbox_workspace_write.network_access", "true")

  defp maybe_add_network_access(args, _settings), do: args

  # Codex takes MCP servers as -c config overrides. The API key is NEVER put
  # on the command line: `env_vars=["LINEAR_API_KEY"]` whitelists it to
  # inherit from the codex process environment, which the Runner populates.
  defp maybe_add_mcp_overrides(args, %{api_key: key} = descriptor)
       when is_binary(key) and key != "" do
    endpoint = Map.get(descriptor, :endpoint) || "https://api.linear.app/graphql"
    prefix = "mcp_servers.#{@mcp_server_name}"
    {command, command_args} = Command.build()

    args
    |> add_config_override("#{prefix}.command", toml_string(command))
    |> add_config_override("#{prefix}.args", Jason.encode!(command_args))
    |> add_config_override("#{prefix}.env", "{LINEAR_ENDPOINT = " <> toml_string(endpoint) <> "}")
    |> add_config_override("#{prefix}.env_vars", ~s(["LINEAR_API_KEY"]))
  end

  defp maybe_add_mcp_overrides(args, _descriptor), do: args

  # Before the prompt: `codex exec` takes the prompt as its final positional.
  defp maybe_add_extra_args(args, extra), do: CymphonyElixir.Agent.append_extra_args(args, extra)

  defp transcript_excerpt(lines), do: CymphonyElixir.Agent.transcript_excerpt(lines)

  defp add_config_override(args, key, toml_value),
    do: args ++ ["-c", shell_escape("#{key}=#{toml_value}")]

  defp toml_string(value), do: Jason.encode!(value)

  defp emit(on_message, details) when is_function(on_message, 1) do
    on_message.(Map.put(details, :timestamp, DateTime.utc_now()))
  end

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
