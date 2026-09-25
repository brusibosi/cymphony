defmodule CymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Cymphony with an explicit WORKFLOW.md path.
  """

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Daemon
  alias CymphonyElixir.LegacySupervisor
  alias CymphonyElixir.LogFile

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.Onboarding
  alias CymphonyElixir.Cymphony.UrlFile
  alias CymphonyElixir.Cymphony.WorkflowGenerator

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @background_start_timeout_ms 60_000
  @background_poll_interval_ms 200
  @cymphony_mode_opt_keys [:project, :setup, :agent, :model, :effort, :provider, :concurrency]
  @switches [
    {@acknowledgement_switch, :boolean},
    agent: :string,
    background: :boolean,
    background_stop: :boolean,
    concurrency: :integer,
    daemon_internal: :boolean,
    effort: :string,
    help: :boolean,
    logs_root: :string,
    model: :string,
    port: :integer,
    project: :string,
    provider: :string,
    restart: :boolean,
    setup: :boolean,
    version: :boolean
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type daemon_executable_result :: {:ok, String.t()} | {:error, String.t()}
  @type deps :: %{
          :file_regular? => (String.t() -> boolean()),
          :set_workflow_file_path => (String.t() -> :ok | {:error, term()}),
          :set_logs_root => (String.t() -> :ok | {:error, term()}),
          :set_server_port_override => (non_neg_integer() | nil -> :ok | {:error, term()}),
          :ensure_all_started => (-> ensure_started_result()),
          # Optional for existing callers that inject application startup.
          optional(:start_legacy_runtime) => (-> :ok | {:error, term()}),
          # Injected by tests so the background-start conformance cases can
          # launch a stand-in binary instead of the real daemon.
          optional(:daemon_executable) => (-> daemon_executable_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      :done ->
        # One-shot command finished. In the Burrito binary the supervision
        # tree is already running and would keep the VM (and the status TUI)
        # alive forever, so halt explicitly; for the escript this matches the
        # normal exit-0 it did by returning.
        halt(0)

      {:error, message} ->
        cleanup_pidfile()
        IO.puts(:stderr, message)
        halt(1)
    end
  end

  @doc """
  Flushes the log sinks, then halts the VM.

  The disk log handlers buffer (`delayed_write` / `disk_log`) and
  `System.halt/1` does not unwind the VM, so a failure logged immediately
  before the halt would never reach the log files. Every exit path — including
  `BurritoCLI.run_cli/1`'s unhandled-error handler, which is the only place a
  crash in the shipped binary is recorded — goes through here.
  """
  @spec halt(non_neg_integer()) :: no_return()
  def halt(status) when is_integer(status) and status >= 0 do
    Logger.flush()
    System.halt(status)
  end

  @spec evaluate([String.t()], deps()) :: :ok | :done | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    args
    |> expand_shorthands()
    |> dispatch_evaluate(deps)
  end

  defp dispatch_evaluate(args, deps) do
    cond do
      help_requested?(args) ->
        {:error, help_text()}

      version_requested?(args) ->
        show_version()

      log_requested?(args) ->
        show_log(args)

      list_requested?(args) ->
        list_projects()

      add_project_requested?(args) ->
        add_project()

      true ->
        dispatch_lifecycle(args, deps)
    end
  end

  defp dispatch_lifecycle(args, deps) do
    cond do
      stop_background_requested?(args) ->
        stop_background()

      restart_requested?(args) ->
        restart_background(args, deps)

      webui_requested?(args) ->
        open_webui()

      background_requested?(args) ->
        run_background(args, deps)

      true ->
        evaluate_run_mode(args, deps)
    end
  end

  defp evaluate_run_mode(args, deps) do
    if cymphony_mode?(args) do
      cymphony_evaluate(args, deps)
    else
      legacy_evaluate(args, deps)
    end
  end

  defp expand_shorthands([]), do: []

  defp expand_shorthands(["b" | rest]), do: ["--background" | expand_shorthands(rest)]
  defp expand_shorthands(["start" | rest]), do: ["--background" | expand_shorthands(rest)]
  defp expand_shorthands(["bs" | rest]), do: ["--background-stop" | expand_shorthands(rest)]
  defp expand_shorthands(["stop" | rest]), do: ["--background-stop" | expand_shorthands(rest)]
  defp expand_shorthands(["h" | rest]), do: ["--help" | expand_shorthands(rest)]
  defp expand_shorthands(["r" | rest]), do: ["--restart" | expand_shorthands(rest)]
  defp expand_shorthands(["restart" | rest]), do: ["--restart" | expand_shorthands(rest)]
  defp expand_shorthands(["s" | rest]), do: ["--setup" | expand_shorthands(rest)]
  defp expand_shorthands(["setup" | rest]), do: ["--setup" | expand_shorthands(rest)]
  defp expand_shorthands(["l" | rest]), do: ["list" | expand_shorthands(rest)]
  defp expand_shorthands(["a" | rest]), do: ["add-project" | expand_shorthands(rest)]
  defp expand_shorthands(["add" | rest]), do: ["add-project" | expand_shorthands(rest)]
  defp expand_shorthands(["v" | rest]), do: ["--version" | expand_shorthands(rest)]
  defp expand_shorthands(["log" | rest]), do: ["log" | expand_shorthands(rest)]
  defp expand_shorthands(["logs" | rest]), do: ["log" | expand_shorthands(rest)]
  defp expand_shorthands(["p", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["p" | _]), do: ["--help"]
  defp expand_shorthands(["project", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["project" | _]), do: ["--help"]
  defp expand_shorthands(["projects", value | rest]), do: ["--project", value | expand_shorthands(rest)]
  defp expand_shorthands(["projects" | _]), do: ["--help"]
  defp expand_shorthands(["c", value | rest]), do: ["--provider", value | expand_shorthands(rest)]
  defp expand_shorthands(["c" | _]), do: ["--help"]
  defp expand_shorthands(["agent", value | rest]), do: ["--agent", value | expand_shorthands(rest)]
  defp expand_shorthands(["agent" | _]), do: ["--help"]
  defp expand_shorthands(["model", value | rest]), do: ["--model", value | expand_shorthands(rest)]
  defp expand_shorthands(["model" | _]), do: ["--help"]
  defp expand_shorthands(["effort", value | rest]), do: ["--effort", value | expand_shorthands(rest)]
  defp expand_shorthands(["effort" | _]), do: ["--help"]
  defp expand_shorthands(["cr", value | rest]), do: ["--concurrency", value | expand_shorthands(rest)]
  defp expand_shorthands(["cr" | _]), do: ["--help"]
  defp expand_shorthands(["port", value | rest]), do: ["--port", value | expand_shorthands(rest)]
  defp expand_shorthands(["port" | _]), do: ["--help"]
  defp expand_shorthands([arg | rest]), do: [arg | expand_shorthands(rest)]

  defp background_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :background, false)
  end

  defp stop_background_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :background_stop, false)
  end

  defp restart_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :restart, false)
  end

  defp help_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :help, false)
  end

  defp version_requested?(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Keyword.get(opts, :version, false)
  end

  defp list_requested?(args) do
    args == ["list"] or args == ["ls"]
  end

  defp add_project_requested?(args) do
    args == ["add-project"]
  end

  defp log_requested?(["log" | _]), do: true
  defp log_requested?(_), do: false

  defp webui_requested?(args), do: args == ["webui"]

  defp show_log(args) do
    tail_count = parse_log_tail_count(args)
    log_path = CymphonyElixir.LogFile.default_log_file()
    write_log_output(log_path, tail_count)
    :done
  end

  defp parse_log_tail_count(["log", count | _]) do
    case Integer.parse(count) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_log_tail_count(_), do: nil

  defp write_log_output(log_path, tail_count) do
    if File.exists?(log_path) or has_rotated_logs?(log_path) do
      IO.binwrite(log_contents(log_path, tail_count))
    else
      IO.puts(:stderr, "No log file found at #{log_path}")
    end
  end

  defp log_contents(log_path, nil), do: read_all_logs(log_path)
  defp log_contents(log_path, n), do: log_path |> read_all_logs() |> tail_lines(n)

  defp has_rotated_logs?(log_path) do
    log_dir = Path.dirname(log_path)
    base = Path.basename(log_path)

    case File.ls(log_dir) do
      {:ok, files} ->
        Enum.any?(files, &String.starts_with?(&1, base <> "."))

      {:error, _} ->
        false
    end
  end

  defp read_all_logs(log_path) do
    # Read rotated logs (oldest rotation index first, then newer), then current
    all_paths = Enum.reverse(rotated_log_paths(log_path)) ++ [log_path]
    Enum.map_join(all_paths, &read_log_file/1)
  end

  defp rotated_log_paths(log_path) do
    log_dir = Path.dirname(log_path)
    base = Path.basename(log_path)

    case File.ls(log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, base <> "."))
        |> Enum.sort_by(&rotation_index(&1, base), :desc)
        |> Enum.map(&Path.join(log_dir, &1))

      {:error, _} ->
        []
    end
  end

  defp rotation_index(filename, base) do
    case filename |> String.trim_leading(base <> ".") |> Integer.parse() do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp read_log_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp tail_lines(content, n) do
    content
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp format_agent_kinds do
    kinds = Agent.known_kinds()
    {leading, [last]} = Enum.split(kinds, -1)
    Enum.join(leading, ", ") <> ", or " <> last
  end

  defp help_text do
    """

    Usage:
      cymphony                       Run with saved config (all projects)
      cymphony project frontend      Run only the "frontend" project
      cymphony agent codex           Run with the Codex CLI agent
      cymphony model opus            Model override passed to the agent CLI
      cymphony effort high           Reasoning effort passed to the agent CLI
      cymphony c cz                  Run with a different provider (e.g. cz, ck, cm)
      cymphony c cv1,cz2,cz1         Run with provider rotation (random per session)
      cymphony cr 3                  Set max concurrent agents to 3
      cymphony cr 3 c cv1,cz2        Set concurrency and provider rotation together
      cymphony port 4089             Set HTTP server / dashboard port
      cymphony start                 Run in background
      cymphony stop                  Stop background process
      cymphony restart               Restart background process
      cymphony webui                 Open the dashboard in your browser
      cymphony setup                 Run setup / onboarding wizard
      cymphony add                   Add a project to existing config
      cymphony list                  List configured projects
      cymphony v                     Show version
      cymphony logs                  Show full log
      cymphony logs 50               Show last 50 lines of log
      cymphony h                     Show this help

    Flags:
      --setup                  Force onboarding wizard
      --project <name>         Run a specific project
      --agent <kind>           Coding agent: #{format_agent_kinds()}
      --model <name>           Model override passed to the agent CLI
      --effort <level>         Reasoning effort passed to the agent CLI
      --provider <name>        Provider rotation (comma-separated auth aliases)
      --concurrency <n>        Set max concurrent agents
      --logs-root <path>       Override log directory
      --port <port>            Override HTTP server port
      --help, -h               Show this help
      --version                Show version

    Legacy mode (advanced):
      cymphony [WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    """
  end

  defp cymphony_mode?(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    cymphony_mode_flag?(opts) or implicit_cymphony_mode?(opts, positional, invalid)
  end

  defp cymphony_mode_flag?(opts) do
    Keyword.get(opts, :daemon_internal, false) or
      Enum.any?(@cymphony_mode_opt_keys, &Keyword.has_key?(opts, &1))
  end

  defp implicit_cymphony_mode?(opts, positional, invalid) do
    implicit_cymphony_args?(positional, invalid) and
      not Keyword.has_key?(opts, @acknowledgement_switch) and
      implicit_cymphony_config?()
  end

  defp implicit_cymphony_args?([], []), do: true
  defp implicit_cymphony_args?(_positional, _invalid), do: false

  defp implicit_cymphony_config? do
    CymphonyConfig.exists?() or not File.regular?(Path.expand("WORKFLOW.md"))
  end

  defp list_projects do
    case Onboarding.list_projects() do
      {:ok, projects} ->
        print_projects(projects)

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  defp print_projects([]) do
    IO.puts("No projects configured. Run `cymphony s` to set up.")
    :done
  end

  defp print_projects(projects) do
    IO.puts("Configured projects:\n")
    Enum.each(projects, &print_project/1)
    :done
  end

  defp print_project(project) do
    name = Map.get(project, "name", "unnamed")
    slug = Map.get(project, "linear_project_slug", "n/a")
    IO.puts("  #{name} (slug: #{slug})")
  end

  defp add_project do
    case run_onboarding_without_tui(&Onboarding.add_project/0) do
      {:ok, _config} -> :done
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # The Burrito binary boots the status TUI before CLI.main runs; it repaints
  # the whole screen on its tick and would draw over interactive prompts.
  # Suspend rendering while the wizard owns the terminal.
  defp run_onboarding_without_tui(fun) do
    CymphonyElixir.StatusDashboard.suspend()

    try do
      fun.()
    after
      CymphonyElixir.StatusDashboard.resume()
    end
  end

  @version Mix.Project.config()[:version]

  defp show_version do
    IO.puts("cymphony #{@version}")
    :done
  end

  defp cymphony_evaluate(args, deps) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    case load_or_onboard_config(opts) do
      {:ok, cfg} ->
        cfg
        |> start_from_config(opts, deps)
        |> maybe_write_daemon_pidfile(opts)

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  # The pidfile is the daemon's liveness signal: `cymphony start` blocks until
  # it appears and only then prints "Cymphony started in background (PID …)".
  # Writing it as the first statement of the run made that message report a
  # process that had been *spawned*, not one that had *booted* — an
  # unreadable config, a missing workflow file or a taken dashboard port all
  # still printed success. Only a run that reached the started state (`:ok`,
  # i.e. `wait_for_shutdown/0` is next) claims the pidfile; every other outcome
  # leaves it absent so the launcher reports the failure with the daemon output
  # tail instead. The Burrito build already had this ordering: `BurritoCLI`
  # starts the supervision tree before handing off to `CLI.main/1`.
  defp maybe_write_daemon_pidfile(:ok, opts) do
    if Keyword.get(opts, :daemon_internal, false) do
      :ok = write_pidfile(System.pid())
    end

    :ok
  end

  defp maybe_write_daemon_pidfile(result, _opts), do: result

  defp load_or_onboard_config(opts) do
    if Keyword.get(opts, :setup, false) or not CymphonyConfig.exists?() do
      run_onboarding_without_tui(&Onboarding.run/0)
    else
      CymphonyConfig.load()
    end
  end

  defp start_from_config(cfg, opts, deps) do
    project_filter = Keyword.get(opts, :project)

    cfg
    |> CymphonyConfig.projects()
    |> filter_projects(project_filter)
    |> apply_cli_overrides(opts)
    |> start_filtered_projects(project_filter, opts, deps)
  end

  defp apply_cli_overrides(projects, opts) do
    projects
    |> apply_provider_override(Keyword.get(opts, :provider))
    |> apply_agent_override(Keyword.get(opts, :agent))
    |> apply_model_override(Keyword.get(opts, :model))
    |> apply_effort_override(Keyword.get(opts, :effort))
    |> apply_concurrency_override(Keyword.get(opts, :concurrency))
  end

  defp apply_provider_override(projects, nil), do: projects

  defp apply_provider_override(projects, value) do
    providers = parse_provider_list(value)

    Enum.map(projects, fn project ->
      project
      |> Map.put("provider", hd(providers))
      |> Map.put("providers", providers)
    end)
  end

  defp apply_agent_override(projects, kind) when is_binary(kind) do
    if Agent.known_kind?(kind) do
      Enum.map(projects, &Map.put(&1, "agent", kind))
    else
      IO.puts(:stderr, "Unknown agent '#{kind}' — using configured agent")
      projects
    end
  end

  defp apply_agent_override(projects, _), do: projects

  defp apply_model_override(projects, model) when is_binary(model) and model != "" do
    Enum.map(projects, &Map.put(&1, "model", model))
  end

  defp apply_model_override(projects, _), do: projects

  defp apply_effort_override(projects, effort) when is_binary(effort) and effort != "" do
    Enum.map(projects, &Map.put(&1, "effort", effort))
  end

  defp apply_effort_override(projects, _), do: projects

  defp apply_concurrency_override(projects, n) when is_integer(n) and n > 0 do
    Enum.map(projects, &Map.put(&1, "max_concurrent_agents", n))
  end

  defp apply_concurrency_override(projects, _), do: projects

  defp start_filtered_projects([], project_filter, _opts, _deps) do
    empty_projects_error(project_filter)
  end

  defp start_filtered_projects(projects, _project_filter, opts, deps) do
    case generate_workflow_files(projects) do
      {:ok, project_workflow_pairs} ->
        start_generated_projects(project_workflow_pairs, opts, deps)

      {:error, reason} ->
        {:error, "Failed to generate workflow: #{inspect(reason)}"}
    end
  end

  defp start_generated_projects(project_workflow_pairs, opts, deps) do
    with :ok <- maybe_set_logs_root(opts, deps),
         :ok <- maybe_set_server_port(opts, deps) do
      run_multi_project(project_workflow_pairs, deps)
    end
  end

  defp empty_projects_error(nil) do
    {:error, "No projects configured. Run `cymphony s` to set up."}
  end

  defp empty_projects_error(project_filter) do
    {:error, "Project '#{project_filter}' not found in config"}
  end

  defp parse_provider_list(value) when is_binary(value) do
    case String.split(value, ",", trim: true) do
      [] -> [value]
      list -> Enum.map(list, &String.trim/1)
    end
  end

  defp filter_projects(projects, nil), do: projects

  defp filter_projects(projects, project_name) when is_binary(project_name) do
    Enum.filter(projects, fn project ->
      Map.get(project, "name") == project_name
    end)
  end

  defp generate_workflow_files(projects) do
    results =
      Enum.map(projects, fn project ->
        case WorkflowGenerator.write_temp(project) do
          {:ok, path} -> {:ok, {project, path}}
          {:error, reason} -> {:error, reason}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, Enum.map(results, fn {:ok, pair} -> pair end)}
    end
  end

  defp run_multi_project(project_workflow_pairs, deps) do
    # Set the first project's workflow as the global default for backward compat
    {_first_project, first_workflow_path} = hd(project_workflow_pairs)
    :ok = deps.set_workflow_file_path.(first_workflow_path)

    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        # Start each project under the DynamicSupervisor
        Enum.each(project_workflow_pairs, fn {project, workflow_path} ->
          project_name = Map.get(project, "name", "default")
          start_project(project_name, workflow_path)
        end)

        :ok

      {:error, reason} ->
        {:error, "Failed to start Cymphony: #{inspect(reason)}"}
    end
  end

  defp start_project(project_name, workflow_path) do
    spec = {
      CymphonyElixir.ProjectSupervisor,
      project_name: project_name, workflow_path: workflow_path
    }

    case DynamicSupervisor.start_child(CymphonyElixir.ProjectDynamicSupervisor, spec) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start project '#{project_name}': #{inspect(reason)}")
        :ok
    end
  end

  defp legacy_evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> legacy_run(opts, Path.expand("WORKFLOW.md"), deps)
      {opts, [workflow_path], []} -> legacy_run(opts, workflow_path, deps)
      _ -> {:error, usage_message()}
    end
  end

  # Same pidfile ordering as `cymphony_evaluate/2`: the daemon only claims the
  # pidfile once `run/2` has validated the workflow path and started the
  # supervision tree.
  defp legacy_run(opts, workflow_path, deps) do
    result =
      with :ok <- maybe_require_guardrails(opts),
           :ok <- maybe_set_logs_root(opts, deps),
           :ok <- maybe_set_server_port(opts, deps) do
        run(workflow_path, deps)
      end

    maybe_write_daemon_pidfile(result, opts)
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      case LegacySupervisor.ensure_workflow_path(expanded_path) do
        :ok ->
          :ok = deps.set_workflow_file_path.(expanded_path)

          case deps.ensure_all_started.() do
            {:ok, _started_apps} ->
              case Map.get(deps, :start_legacy_runtime, fn -> :ok end).() do
                :ok -> :ok
                {:error, reason} -> {:error, "Failed to start Cymphony with workflow #{expanded_path}: #{inspect(reason)}"}
              end

            {:error, reason} ->
              {:error, "Failed to start Cymphony with workflow #{expanded_path}: #{inspect(reason)}"}
          end

        {:error, {:already_running_with_workflow, running_path}} ->
          {:error, "Cymphony is already running with workflow #{running_path}; stop it before selecting #{expanded_path}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: cymphony [--setup] [--project <name>] [--logs-root <path>] [--port <port>]\n" <>
      "       cymphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &CymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:cymphony_elixir) end,
      start_legacy_runtime: &LegacySupervisor.start/0
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp maybe_require_guardrails(_opts) do
    :ok
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:cymphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:cymphony_elixir, :server_port_override, port)

    # In the Burrito release the supervision tree boots before CLI.main runs,
    # so HttpServer already came up as :ignore (no port yet). Start it now
    # that the port is known; no-op when the tree isn't running (escript path,
    # where ensure_all_started boots HttpServer after this override is set).
    case CymphonyElixir.HttpServer.ensure_started() do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start dashboard HTTP server: #{inspect(reason)}")
        :ok
    end
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(CymphonyElixir.Supervisor) do
      nil ->
        cleanup_pidfile()
        IO.puts(:stderr, "Cymphony supervisor is not running")
        halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            cleanup_pidfile()

            case reason do
              :normal -> halt(0)
              _ -> halt(1)
            end
        end
    end
  end

  # ─── Background process management ───

  defp run_background(args, deps) do
    case read_pidfile() do
      {:ok, pid} ->
        if process_alive?(pid) do
          {:error, "Cymphony is already running in background (PID: #{pid})"}
        else
          remove_pidfile()
          do_run_background(args, deps)
        end

      :error ->
        do_run_background(args, deps)
    end
  end

  defp do_run_background(args, deps) do
    # Never emit a nohup command with a blank or unqualified argv[0]: under
    # Burrito the process cannot identify itself through escript/progname, and
    # the resulting command failed in the background while the CLI reported
    # success.
    resolve = Map.get(deps, :daemon_executable, &Daemon.executable_path/0)

    case resolve.() do
      {:ok, executable} -> launch_background(executable, args)
      {:error, message} -> {:error, message}
    end
  end

  defp launch_background(executable, args) do
    filtered_args =
      args
      |> Enum.reject(&(&1 == "--background"))
      |> Kernel.++(["--daemon-internal"])

    log_file = LogFile.daemon_output_file()

    # Use nohup to detach from terminal; the inner & backgrounds the process
    # so the outer sh exits immediately. Each token is shell-escaped so paths
    # or args containing spaces/metacharacters are treated literally.
    {raw_launcher_output, _status} =
      System.cmd("sh", ["-c", Daemon.background_command(executable, filtered_args, log_file)], stderr_to_stdout: true)

    {child_pid, launcher_output} = Daemon.split_launcher_pid(raw_launcher_output)

    case wait_for_daemon_pidfile(child_pid, @background_start_timeout_ms) do
      {:ok, pid} ->
        IO.puts("Cymphony started in background (PID: #{pid})")
        :done

      :exited ->
        {:error, Daemon.startup_failure_message(log_file, launcher_output, :exited)}

      :timeout ->
        {:error, Daemon.startup_failure_message(log_file, launcher_output, @background_start_timeout_ms)}
    end
  end

  defp stop_background do
    case read_pidfile() do
      :error ->
        {:error, "Cymphony is not running in background"}

      {:ok, pid} ->
        stop_background_pid(pid)
    end
  end

  defp stop_background_pid(pid) do
    if process_alive?(pid) do
      terminate_background_pid(pid)
    else
      remove_pidfile()
      {:error, "Cymphony is not running in background (stale pidfile removed)"}
    end
  end

  defp terminate_background_pid(pid) do
    System.cmd("kill", ["-TERM", pid])

    case wait_for_process_death(pid, 10_000) do
      :ok ->
        remove_pidfile()
        IO.puts("Cymphony stopped (PID: #{pid})")
        :done

      :timeout ->
        {:error, "Timed out waiting for Cymphony (PID: #{pid}) to stop"}
    end
  end

  defp restart_background(args, deps) do
    _ = stop_background()
    run_background(args, deps)
  end

  defp open_webui do
    with {:ok, url} <- UrlFile.read(),
         :ok <- launch_browser(url) do
      IO.puts("Opening #{url}")
      :done
    else
      {:error, :not_running} ->
        {:error, "No dashboard URL recorded. Is cymphony running with a port? Try `cymphony port 4089 start`."}

      {:error, reason} ->
        {:error, "Failed to open browser: #{inspect(reason)}"}
    end
  end

  defp launch_browser(url) do
    opener =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      end

    {cmd, args} = opener

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {output, status} -> {:error, "#{cmd} exited #{status}: #{String.trim(output)}"}
    end
  rescue
    error in [ErlangError] -> {:error, Exception.message(error)}
  end

  # ─── Pidfile helpers ───

  defp pidfile_path do
    Path.join(CymphonyConfig.config_dir(), "cymphony.pid")
  end

  defp read_pidfile do
    case File.read(pidfile_path()) do
      {:ok, content} ->
        pid = String.trim(content)
        if pid != "", do: {:ok, pid}, else: :error

      {:error, _} ->
        :error
    end
  end

  defp write_pidfile(pid) when is_binary(pid) do
    :ok = File.mkdir_p(CymphonyConfig.config_dir())
    File.write(pidfile_path(), pid)
  end

  defp remove_pidfile do
    case File.rm(pidfile_path()) do
      :ok -> :ok
      {:error, _} -> :ok
    end
  end

  defp cleanup_pidfile do
    case read_pidfile() do
      {:ok, pid} ->
        if pid == System.pid() do
          remove_pidfile()
          UrlFile.delete()
        end

      :error ->
        :ok
    end
  end

  defp process_alive?(pid) when is_binary(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # The daemon writes its own pidfile late in boot, so "no pidfile yet" is not
  # evidence of failure: a Burrito binary decompresses its whole ERTS payload
  # and deletes the previous version's install tree before the BEAM even
  # starts, which after an upgrade routinely takes longer than the old 5s wait.
  # Aborting on that clock reported a healthy start as a failure and exited 1,
  # and a service wrapper that retries on nonzero exit could then bring up a
  # second daemon on the same port and double-dispatch every issue.
  #
  # Liveness of the detached process — not the clock — is what separates slow
  # from dead, so the deadline is generous and a child that is already gone
  # ends the wait immediately.
  defp wait_for_daemon_pidfile(child_pid, timeout_ms) when timeout_ms > 0 do
    case read_pidfile() do
      {:ok, pid} -> {:ok, pid}
      :error -> continue_waiting_for_pidfile(child_pid, timeout_ms)
    end
  end

  defp wait_for_daemon_pidfile(_child_pid, _timeout_ms), do: :timeout

  defp continue_waiting_for_pidfile(child_pid, timeout_ms) do
    if daemon_gone?(child_pid) do
      :exited
    else
      Process.sleep(@background_poll_interval_ms)
      wait_for_daemon_pidfile(child_pid, max(0, timeout_ms - @background_poll_interval_ms))
    end
  end

  # Without a captured pid there is nothing to probe, so only the deadline can
  # end the wait.
  defp daemon_gone?(nil), do: false
  defp daemon_gone?(child_pid), do: not process_alive?(child_pid)

  defp wait_for_process_death(pid, timeout_ms) when timeout_ms > 0 do
    if process_alive?(pid) do
      Process.sleep(200)
      wait_for_process_death(pid, max(0, timeout_ms - 200))
    else
      :ok
    end
  end

  defp wait_for_process_death(_pid, _timeout_ms), do: :timeout
end
