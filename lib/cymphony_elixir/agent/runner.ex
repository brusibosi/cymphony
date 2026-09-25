defmodule CymphonyElixir.Agent.Runner do
  @moduledoc """
  Shared coding-agent session runner.

  Owns everything that is identical across agent CLIs — workspace validation,
  port spawn (local shell with rc-file sourcing, or SSH remote), env-var
  injection, output collection with turn timeout, lifecycle events — and
  delegates command construction and output parsing to the
  `CymphonyElixir.Agent` adapter for the session's agent kind.
  """

  require Logger

  alias CymphonyElixir.{Agent, Config, PathSafety, SSH, Text, Workspace}
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.ShellProvider
  alias CymphonyElixir.Mcp.ConfigWriter

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @harness_stdout_max 2048
  @port_eof_drain_ms 250
  @shell_env_name_pattern "^[A-Za-z_][A-Za-z0-9_]*$"

  @type session :: %{
          port: port() | nil,
          metadata: map(),
          session_id: String.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          config: term(),
          run_spec: Agent.run_spec(),
          agent_module: module()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    config = Keyword.get(opts, :config)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, config),
         {:ok, run_spec} <- build_run_spec(expanded_workspace, worker_host, config, opts),
         {:ok, agent_module} <- Agent.module_for(run_spec.kind) do
      {:ok,
       %{
         port: nil,
         metadata: %{},
         session_id: nil,
         workspace: expanded_workspace,
         worker_host: worker_host,
         config: config,
         run_spec: run_spec,
         agent_module: agent_module
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    %{
      workspace: workspace,
      worker_host: worker_host,
      session_id: session_id,
      config: session_config,
      run_spec: run_spec,
      agent_module: agent_module
    } = session

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    config = Keyword.get(opts, :config, session_config)
    run_spec = %{run_spec | prompt: prompt, session_id: session_id}

    with {:ok, command} <- agent_module.build_command(run_spec),
         {:ok, port} <-
           start_port_for_command(command, workspace, worker_host, run_spec, agent_module, config) do
      metadata = port_metadata(port, worker_host)
      display_session_id = "#{session_id || "new"}"

      emit_message(
        on_message,
        :session_started,
        %{session_id: display_session_id, thread_id: display_session_id, turn_id: 1},
        metadata
      )

      case await_process_completion(port, on_message, metadata, run_spec, agent_module, config) do
        {:ok, result} ->
          new_session_id = result[:session_id] || session_id

          Logger.info("Agent session completed for #{issue_context(issue)} session_id=#{new_session_id}")

          emit_message(
            on_message,
            :turn_completed,
            %{
              session_id: new_session_id,
              result: result[:result],
              usage: result[:usage],
              raw: result[:raw]
            },
            metadata
          )

          {:ok,
           %{
             result: result,
             session_id: new_session_id,
             thread_id: new_session_id,
             turn_id: 1
           }}

        {:error, reason} ->
          Logger.warning("Agent session ended with error for #{issue_context(issue)} session_id=#{display_session_id}: #{inspect(reason)}")

          emit_message(
            on_message,
            :turn_ended_with_error,
            %{session_id: display_session_id, reason: reason},
            metadata
          )

          {:error, reason}
      end
    else
      {:error, reason} ->
        Logger.error("Agent session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: nil}), do: :ok

  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  # The run_spec snapshots everything the adapter needs for the whole session.
  # Per-issue overrides (agent_kind/model/effort/provider) arrive via opts and
  # win over config defaults.
  defp build_run_spec(workspace, worker_host, config, opts) do
    settings = config || Config.settings!()
    kind = Keyword.get(opts, :agent_kind) || settings.agent.kind
    # EP-SECTION
    section = Agent.section(settings, kind)

    {:ok,
     %{
       kind: kind,
       command: nil,
       model: Keyword.get(opts, :model) || settings.agent.model,
       effort: Keyword.get(opts, :effort) || settings.agent.effort,
       provider: Keyword.get(opts, :provider_override) || section.provider,
       session_id: nil,
       prompt: "",
       workspace: workspace,
       mcp_descriptor: mcp_descriptor(settings, worker_host),
       settings: section_to_settings(section)
     }}
  end

  # Agent.section/2 may return a schema struct or a stub map (antigravity
  # fallback before the embed is present on every settings shape).
  defp section_to_settings(%{__struct__: _} = section), do: Map.from_struct(section)
  defp section_to_settings(section) when is_map(section), do: section

  # MCP injection is local-only (a remote workspace cannot read a local
  # descriptor file, and remote argv rendering is untested) — same behavior
  # the Claude-only runner had.
  defp mcp_descriptor(_settings, worker_host) when is_binary(worker_host), do: nil
  defp mcp_descriptor(settings, _worker_host), do: ConfigWriter.descriptor_from_config(settings)

  defp start_port_for_command(command, workspace, nil, run_spec, agent_module, config) do
    case pick_local_shell() do
      {:ok, shell} ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(shell)},
            [
              :binary,
              :exit_status,
              :eof,
              :stderr_to_stdout,
              args: [~c"-c", String.to_charlist(local_launch_script(command))],
              cd: String.to_charlist(workspace),
              line: @port_line_bytes,
              env: agent_env(run_spec, agent_module, config)
            ]
          )

        {:ok, port}

      {:error, _} = err ->
        err
    end
  end

  defp start_port_for_command(command, workspace, worker_host, run_spec, agent_module, config)
       when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, command, run_spec, agent_module, config)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  # Wrap the user's command so shell-function aliases (e.g. `cz`, `cm`, `cv1`
  # defined in ~/.cld) resolve when used as the agent command. Sourcing only
  # happens when the first word of the command isn't already on $PATH, so
  # plain binary commands (`claude`, `codex`, etc.) don't trigger rc-file
  # sourcing — that would otherwise override env vars we explicitly pass via
  # Port.open's :env option.
  defp local_launch_script(command) do
    cmd_name = command |> String.split(" ", parts: 2) |> List.first() || ""

    """
    export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
    if ! command -v #{shell_escape(cmd_name)} >/dev/null 2>&1; then
      for __cymphony_rc in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
        [ -f "$__cymphony_rc" ] && . "$__cymphony_rc" 2>/dev/null || true
      done
      unset __cymphony_rc
    fi
    # Codex exec still opens stdin for "additional input" even when the prompt
    # is on argv. An inherited open pipe never EOFs, so the turn hangs until
    # the stall watchdog kills it — no commits, no PR.
    exec #{command} </dev/null
    """
  end

  defp pick_local_shell do
    case System.find_executable("zsh") || System.find_executable("bash") do
      nil -> {:error, :shell_not_found}
      path -> {:ok, path}
    end
  end

  defp remote_launch_command(workspace, command, run_spec, agent_module, config)
       when is_binary(workspace) do
    ([Workspace.remote_guard_script(workspace, config, true), "cd \"$workspace\""] ++
       remote_env_exports(run_spec, agent_module, config) ++ ["exec #{command}"])
    |> Enum.join(" && ")
  end

  defp agent_env(run_spec, agent_module, config) do
    run_spec
    |> agent_process_env(agent_module, config, include_base?: true)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  defp remote_env_exports(run_spec, agent_module, config) do
    run_spec
    |> agent_process_env(agent_module, config, include_base?: false)
    |> Enum.map(fn {key, value} ->
      "export #{key}=#{shell_escape(value)}"
    end)
  end

  defp agent_process_env(run_spec, agent_module, config, opts) do
    config = config || Config.settings!()

    base_env =
      if Keyword.get(opts, :include_base?, false) do
        %{
          "PATH" => System.get_env("PATH") || "",
          "HOME" => System.get_env("HOME") || ""
        }
      else
        %{}
      end

    base_env
    |> Map.merge(agent_auth_env(run_spec, agent_module))
    |> Map.merge(integration_auth_env(config))
    |> valid_env_map()
  end

  defp agent_auth_env(run_spec, agent_module) do
    case provider_env(run_spec.provider, agent_module) do
      provider_env when map_size(provider_env) > 0 ->
        provider_env

      _ ->
        inherited_env(agent_module.auth_env_fallback())
    end
  end

  defp provider_env(provider_name, agent_module)
       when is_binary(provider_name) and provider_name != "" do
    prefixes = agent_module.auth_env_prefixes()

    result =
      case CymphonyConfig.provider_env(provider_name, prefixes) do
        {:ok, env_map} -> {:ok, env_map}
        :not_found -> ShellProvider.load_env(provider_name, prefixes)
      end

    case result do
      {:ok, env_map} when is_map(env_map) ->
        normalize_env_map(env_map)

      {:error, :not_found} ->
        %{}
    end
  end

  defp provider_env(_provider_name, _agent_module), do: %{}

  defp integration_auth_env(config) do
    %{}
    |> maybe_put_env("LINEAR_API_KEY", linear_api_key(config))
    |> Map.merge(inherited_env(["GH_TOKEN", "GITHUB_TOKEN"]))
  end

  defp linear_api_key(%{tracker: %{kind: "linear", api_key: api_key}})
       when is_binary(api_key) and api_key != "",
       do: api_key

  defp linear_api_key(_config), do: nil

  defp inherited_env(names) when is_list(names) do
    Enum.reduce(names, %{}, fn name, env ->
      maybe_put_env(env, name, System.get_env(name))
    end)
  end

  defp normalize_env_map(env_map) when is_map(env_map) do
    Enum.reduce(env_map, %{}, fn {key, value}, env ->
      maybe_put_env(env, to_string(key), value)
    end)
  end

  defp maybe_put_env(env, name, value)
       when is_map(env) and is_binary(name) and is_binary(value) and value != "" do
    Map.put(env, name, value)
  end

  defp maybe_put_env(env, _name, _value), do: env

  defp valid_env_map(env) when is_map(env) do
    pattern = Regex.compile!(@shell_env_name_pattern)

    env
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_binary(value) and Regex.match?(pattern, key)
    end)
    |> Map.new()
  end

  defp await_process_completion(port, on_message, metadata, run_spec, agent_module, config) do
    wrapped = wrap_on_message(on_message, metadata)

    case collect_output(port, config, wrapped) do
      {:ok, lines} ->
        agent_module.parse_output(lines, run_spec, wrapped)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Adapters emit bare %{event:, payload:, raw:, timestamp:} maps; decorate
  # them with port metadata the same way direct emit_message calls do.
  defp wrap_on_message(on_message, metadata) do
    fn details -> on_message.(Map.merge(metadata, details)) end
  end

  defp collect_output(port, config, on_message) do
    collect_output(port, "", [], config, on_message, false)
  end

  # Tail-recursive: accumulates completed lines in reverse and reverses once at
  # the end, so a long streaming turn (thousands of events) does not grow the
  # call stack proportionally to the number of output lines.
  # EP-STREAM: emit :harness_stdout incrementally for completed lines (and a
  # leftover buffer on exit 0). :noeol chunks stay buffered and are not emitted.
  # parse_output still runs only after a successful exit.
  # exit_status can race ahead of the last {:noeol, _} chunk; wait for :eof
  # (or a short drain) so leftover output is not dropped.
  defp collect_output(port, buffer, acc, config, on_message, eof?) do
    timeout_ms = if config, do: config.agent.turn_timeout_ms, else: Config.settings!().agent.turn_timeout_ms

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = buffer <> to_string(chunk)
        log_stream_line(line)
        emit_harness_stdout(on_message, line)
        collect_output(port, "", [line | acc], config, on_message, eof?)

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, buffer <> to_string(chunk), acc, config, on_message, eof?)

      {^port, :eof} ->
        collect_output(port, buffer, acc, config, on_message, true)

      {^port, {:exit_status, status}} ->
        {buffer, acc} =
          if eof? do
            {buffer, acc}
          else
            drain_port_until_eof(port, buffer, acc, on_message)
          end

        finalize_collected_output(status, buffer, acc, on_message)
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp drain_port_until_eof(port, buffer, acc, on_message) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = buffer <> to_string(chunk)
        log_stream_line(line)
        emit_harness_stdout(on_message, line)
        drain_port_until_eof(port, "", [line | acc], on_message)

      {^port, {:data, {:noeol, chunk}}} ->
        drain_port_until_eof(port, buffer <> to_string(chunk), acc, on_message)

      {^port, :eof} ->
        {buffer, acc}
    after
      @port_eof_drain_ms ->
        {buffer, acc}
    end
  end

  defp finalize_collected_output(0, buffer, acc, on_message) do
    remaining = buffer |> to_string() |> String.trim()

    if remaining != "" do
      log_stream_line(remaining)
      emit_harness_stdout(on_message, remaining)
    end

    lines = if remaining != "", do: [remaining | acc], else: acc
    {:ok, Enum.reverse(lines)}
  end

  defp finalize_collected_output(status, buffer, acc, _on_message) do
    remaining = buffer |> to_string() |> String.trim()
    if remaining != "", do: log_stream_line(remaining)
    {:error, {:agent_exit, status, failure_tail(acc, remaining)}}
  end

  # A CLI that rejects its arguments prints a complete, newline-terminated
  # error line and exits: by then the line has moved into `acc` and the
  # leftover buffer is empty. Reporting only the buffer produced
  # `{:agent_exit, 1, ""}` in the retry queue and in the tracker abandonment
  # comment, so keep a bounded, sanitized tail of everything the CLI printed.
  #
  # Newest line first. `acc` is already newest-first, and every surface that
  # renders this tail truncates from the *front* (the dashboard retry row at
  # 120 characters, the terminal dashboard at 96), after a ~50-character
  # `agent exited: Agent run failed: {:agent_exit, 1, "` prefix. Emitting it in
  # chronological order put the CLI's own error line — the last thing it
  # printed, and the whole point of retaining a tail — past every cut, so a
  # streaming turn showed nothing but its oldest retained noise line.
  #
  # This is the choke point for the tail: whatever it returns is what the retry
  # entry stores, `/api/v1/state` serves, the dashboard renders, and the tracker
  # abandonment comment publishes. `Agent.failure_excerpt/1` owns the bounding,
  # sanitizing, and redacting so the adapters' own exit-0 error payloads get
  # exactly the same treatment. `acc` is already newest-first.
  defp failure_tail(acc, remaining) do
    Agent.failure_excerpt([remaining | acc])
  end

  # The harness ring is served by `GET /api/v1/:issue/harness` and rendered in
  # the dashboard harness pane, so it carries the same bytes off the box that
  # the failure tail does and needs the same redaction. Redact after the slice:
  # the regexes then run on at most 2048 characters rather than a whole port
  # line.
  defp emit_harness_stdout(on_message, line) do
    raw =
      line
      |> to_string()
      |> String.slice(0, @harness_stdout_max)
      |> Text.redact_secrets()

    on_message.(%{event: :harness_stdout, raw: raw, timestamp: DateTime.utc_now()})
  end

  defp validate_workspace_cwd(workspace, nil, config) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(if config, do: config.workspace.root, else: Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host, config)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        case Workspace.validate_remote_workspace(workspace, worker_host, config, true) do
          :ok -> {:ok, workspace}
          {:error, reason} -> {:error, {:invalid_workspace_cwd, :remote_path, reason}}
        end
    end
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{agent_os_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp log_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, Regex.compile!("\\b(error|warn|warning|failed|fatal|panic|exception)\\b", "i")) do
        Logger.warning("Agent output: #{text}")
      else
        Logger.debug("Agent output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
