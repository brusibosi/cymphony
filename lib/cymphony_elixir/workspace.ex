defmodule CymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Claude agents.
  """

  require Logger
  alias CymphonyElixir.Agent.PortGuard
  alias CymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__CYMPHONY_WORKSPACE__"
  # Must match CymphonyElixir.Agent.Antigravity's @session_log_prefix.
  @session_log_prefix ".agy-"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)
    config = Keyword.get(opts, :config)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, config),
           :ok <- validate_workspace_path(workspace, worker_host, config),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host, config, opts),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, config, opts) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")

        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil, _config, _opts) do
    cond do
      File.dir?(workspace) and workspace_needs_bootstrap?(workspace) ->
        {:ok, workspace, true}

      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host, config, opts) when is_binary(worker_host) do
    script =
      [
        remote_guard_script(workspace, config),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, hooks_config(config).timeout_ms, opts) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  # A previous failed after_create (e.g. git clone) leaves an empty directory.
  # Later ticks must not treat that as "already bootstrapped" or the agent
  # runs in a folder with no repo and can never open a PR.
  defp workspace_needs_bootstrap?(workspace) do
    case File.ls(workspace) do
      {:ok, entries} ->
        Enum.all?(entries, &bootstrap_placeholder?/1)

      _ ->
        true
    end
  end

  defp bootstrap_placeholder?(name) when name in [".cymphony", ".DS_Store"], do: true
  defp bootstrap_placeholder?(_name), do: false

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil, [])

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host), do: remove(workspace, worker_host, [])

  @spec remove(Path.t(), worker_host(), keyword()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil, opts) do
    config = Keyword.get(opts, :config)

    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil, config) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, config, opts)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host, opts) when is_binary(worker_host) do
    config = Keyword.get(opts, :config)

    script =
      [
        remote_guard_script(workspace, config),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    with :ok <- validate_remote_workspace(workspace, worker_host, config, false, opts),
         :ok <- maybe_run_before_remove_hook(workspace, worker_host, config, opts) do
      case run_remote_command(worker_host, script, hooks_config(config).timeout_ms, opts) do
        {:ok, {_output, 0}} ->
          {:ok, []}

        {:ok, {output, status}} ->
          {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  @doc """
  Sweeps `workspace_root` for top-level directories whose last-modified time is older than
  `:days`. Skips paths in `:exclude_paths` (e.g. currently-running workspaces).

  Returns `{:ok, removed}` after deletion, or `{:dry_run, would_remove}` when `dry_run: true`.
  Both `removed` and `would_remove` are lists of absolute paths.
  Local-only — does not touch SSH worker hosts.
  """
  @spec clean_stale(Path.t(), keyword()) ::
          {:ok, [String.t()]} | {:dry_run, [String.t()]} | {:error, term()}
  def clean_stale(workspace_root, opts) when is_binary(workspace_root) do
    days = Keyword.fetch!(opts, :days)
    dry_run = Keyword.get(opts, :dry_run, false)
    exclude = Keyword.get(opts, :exclude_paths, []) |> MapSet.new()

    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    case File.ls(workspace_root) do
      {:ok, entries} ->
        finish_clean_stale(
          workspace_root,
          entries,
          exclude,
          cutoff,
          dry_run,
          Keyword.get(opts, :config),
          opts
        )

      {:error, :enoent} ->
        empty_clean_stale_result(dry_run)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp empty_clean_stale_result(true), do: {:dry_run, []}
  defp empty_clean_stale_result(false), do: {:ok, []}

  defp finish_clean_stale(workspace_root, entries, exclude, cutoff, true, _config, _opts) do
    {:dry_run, stale_candidates(workspace_root, entries, exclude, cutoff)}
  end

  defp finish_clean_stale(workspace_root, entries, exclude, cutoff, false, config, opts) do
    removed =
      workspace_root
      |> stale_candidates(entries, exclude, cutoff)
      |> Enum.flat_map(&remove_stale_path(&1, workspace_root, config, opts))

    {:ok, removed}
  end

  defp stale_candidates(workspace_root, entries, exclude, cutoff) do
    entries
    |> Enum.map(&Path.join(workspace_root, &1))
    |> Enum.filter(&stale_candidate?(&1, exclude, cutoff))
  end

  defp stale_candidate?(path, exclude, cutoff) do
    sweepable?(path) and not MapSet.member?(exclude, path) and stale?(path, cutoff)
  end

  # Directories are the workspaces themselves. The one plain file the sweep also
  # owns is the per-session agent log the Antigravity adapter writes *beside*
  # its workspace (`.agy-<issue>.log`), kept out of the cloned repo so it cannot
  # end up in a pull request; without this it would accumulate under the root
  # forever. Any other stray file is left alone.
  defp sweepable?(path) do
    File.dir?(path) or (File.regular?(path) and session_log?(path))
  end

  defp session_log?(path) do
    name = Path.basename(path)
    String.starts_with?(name, @session_log_prefix) and String.ends_with?(name, ".log")
  end

  defp remove_stale_path(path, workspace_root, config, opts) do
    # Sanity-check: refuse to delete anything that isn't a direct child of workspace_root.
    # (Defense in depth — Path.join above already enforces this.)
    sweep_root = %{workspace: %{root: workspace_root}}

    if Path.dirname(path) == Path.expand(workspace_root) and
         validate_workspace_path(path, nil, sweep_root) == :ok do
      delete_stale_workspace(path, config, opts)
    else
      Logger.warning("Workspace cleanup refused for #{path}: not a direct child of #{workspace_root}")
      []
    end
  end

  defp delete_stale_workspace(path, config, opts) do
    # The sibling session log is not a workspace, so it gets no `before_remove`
    # hook — the hook runs shell in a workspace directory.
    if not session_log?(path), do: maybe_run_before_remove_hook(path, nil, config, opts)

    case File.rm_rf(path) do
      {:ok, _} ->
        [path]

      {:error, reason, _} ->
        Logger.warning("Workspace cleanup failed for #{path}: #{inspect(reason)}")
        []
    end
  end

  defp stale?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime_dt = DateTime.from_unix!(mtime)
        DateTime.compare(mtime_dt, cutoff) == :lt

      _ ->
        false
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil, [])

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host),
    do: remove_issue_workspaces(identifier, worker_host, [])

  @spec remove_issue_workspaces(term(), worker_host(), keyword()) :: :ok
  def remove_issue_workspaces(identifier, worker_host, opts)
      when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)
    config = Keyword.get(opts, :config)

    case workspace_path_for_issue(safe_id, worker_host, config) do
      {:ok, workspace} -> remove(workspace, worker_host, opts)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil, opts) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)
    config = Keyword.get(opts, :config)

    case worker_config(config).ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil, config) do
          {:ok, workspace} -> remove(workspace, nil, opts)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1, opts))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host, _opts) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    config = Keyword.get(opts, :config)
    hooks = hooks_config(config)

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host, config, opts)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    config = Keyword.get(opts, :config)
    hooks = hooks_config(config)

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host, config, opts)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil, config) when is_binary(safe_id) do
    workspace_root(config)
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host, config)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(workspace_root(config), safe_id)}
  end

  defp workspace_root(nil), do: Config.settings!().workspace.root
  defp workspace_root(config), do: config.workspace.root

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", Regex.compile!("[^a-zA-Z0-9._-]"), "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host, config, opts) do
    case created? do
      true -> run_after_create_hook(workspace, issue_context, worker_host, config, opts)
      false -> :ok
    end
  end

  defp run_after_create_hook(workspace, issue_context, worker_host, config, opts) do
    case hooks_config(config).after_create do
      nil ->
        :ok

      command ->
        run_locked_after_create(command, workspace, issue_context, worker_host, config, opts)
    end
  end

  defp run_locked_after_create(command, workspace, issue_context, worker_host, config, opts) do
    with_after_create_lock(config, fn ->
      run_hook(command, workspace, issue_context, "after_create", worker_host, config, opts)
    end)
  end

  # Serialize after_create across the whole node so the storm of `git clone`s on
  # the first poll tick doesn't race on SSH agent / known_hosts / GitHub burst
  # limits. SSH-agent state is host-wide, so different projects must also wait.
  # The hook timeout still kills hangs, releasing the lock.
  defp with_after_create_lock(_config, fun) do
    :global.trans({:cymphony_after_create, self()}, fun, [Node.self()], :infinity)
  end

  defp maybe_run_before_remove_hook(workspace, nil, config, opts) do
    hooks = hooks_config(config)

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil,
              config,
              opts
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, config, opts) when is_binary(worker_host) do
    hooks = hooks_config(config)

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_guard_script(workspace, config),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, hooks_config(config).timeout_ms, opts)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil, config, opts) do
    timeout_ms = hooks_config(config).timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    opener = fn ->
      {:ok,
       Port.open(
         {:spawn_executable, System.find_executable("sh") |> String.to_charlist()},
         [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           args: [~c"-lc", String.to_charlist(PortGuard.prepare(command))],
           cd: String.to_charlist(workspace)
         ]
       )}
    end

    case PortGuard.run(port_supervisor(opts), opener, timeout_ms, handshake: true) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, :timeout} ->
        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, config, opts)
       when is_binary(worker_host) do
    timeout_ms = hooks_config(config).timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script = remote_guard_script(workspace, config, true) <> "\ncd \"$workspace\" && #{command}"

    case run_remote_command(worker_host, script, timeout_ms, opts) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil, config) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root(config))
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host, _config)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  @doc false
  @spec validate_remote_workspace(Path.t(), String.t(), term(), boolean()) :: :ok | {:error, term()}
  @spec validate_remote_workspace(Path.t(), String.t(), term(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def validate_remote_workspace(workspace, worker_host, config, require_existing \\ false, opts \\ [])
      when is_binary(workspace) and is_binary(worker_host) do
    case run_remote_command(
           worker_host,
           remote_guard_script(workspace, config, require_existing),
           hooks_config(config).timeout_ms,
           opts
         ) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:invalid_remote_workspace, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Resolve on the worker itself: local Path.expand/realpath would inspect the
  # controller's filesystem and could miss a worker-only symlink escape.
  # Paths beneath a not-yet-created root are resolved from the nearest existing
  # ancestor; existing symlinks are followed by cd -P. A configured relative
  # root may itself contain dot segments, but traversal appended after that
  # root is refused rather than normalized across missing components.
  @doc false
  @spec remote_guard_script(Path.t(), term(), boolean()) :: String.t()
  def remote_guard_script(workspace, config, require_existing \\ false) do
    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      remote_shell_assign("root", workspace_root(config)),
      ~S'''
      case "$workspace" in /*) ;; *) workspace="$PWD/$workspace" ;; esac
      case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
      while [ "$root" != / ] && [ "${root%/}" != "$root" ]; do
        root=${root%/}
      done
      case "$workspace" in
        "$root"/*) child=${workspace#"$root"/} ;;
        *) child=$workspace ;;
      esac
      case "/$child/" in *"/../"*) exit 74 ;; esac
      while [ "$workspace" != / ] && [ "${workspace%/}" != "$workspace" ]; do
        workspace=${workspace%/}
      done
      case "${workspace##*/}" in ''|.|..) exit 74 ;; esac
      [ ! -L "$workspace" ] || exit 74
      canonical_dir_or_missing() {
        path=$1
        suffix=
        while [ ! -d "$path" ]; do
          [ ! -L "$path" ] || return 1
          base=${path##*/}
          parent=${path%/*}
          [ -n "$parent" ] || parent=/
          [ "$parent" != "$path" ] || return 1
          if [ -e "$path" ]; then
            parent_real=$(cd -P -- "$parent" && pwd -P) || return 1
            printf '%s/%s%s' "$parent_real" "$base" "$suffix"
            return
          fi
          suffix="/$base$suffix"
          path=$parent
        done
        (cd -P -- "$path" && printf '%s%s' "$PWD" "$suffix")
      }
      root_real=$(canonical_dir_or_missing "$root") || exit 74
      workspace_real=$(canonical_dir_or_missing "$workspace") || exit 74
      case "$workspace_real" in "$root_real"/*) ;; *) exit 74 ;; esac
      workspace=$workspace_real
      ''',
      if(require_existing, do: "[ -d \"$workspace\" ] || exit 74", else: "")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms, opts)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    case PortGuard.run(port_supervisor(opts), fn -> SSH.start_port(worker_host, PortGuard.prepare(script)) end, timeout_ms, handshake: true) do
      {:error, :timeout} -> {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
      result -> result
    end
  end

  defp port_supervisor(opts), do: Keyword.get(opts, :port_supervisor, CymphonyElixir.TaskSupervisor)

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp hooks_config(nil), do: Config.settings!().hooks
  defp hooks_config(config), do: config.hooks

  defp worker_config(nil), do: Config.settings!().worker
  defp worker_config(config), do: config.worker
end
