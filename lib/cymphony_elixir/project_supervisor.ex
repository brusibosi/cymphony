defmodule CymphonyElixir.ProjectSupervisor do
  @moduledoc """
  Supervisor for a single project's WorkflowStore and Orchestrator.

  Each project gets its own `ProjectSupervisor` under the
  `ProjectDynamicSupervisor`, with children registered via
  `ProjectRegistry` for lookup by project name.
  """

  use Supervisor

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.{Orchestrator, WorkflowStore}

  @project_roles [:supervisor, :workflow_store, :port_supervisor, :task_supervisor, :orchestrator]
  @unregister_poll_ms 5
  @unregister_budget_ms 1_000

  @type project_spec :: [
          {:name, String.t()}
          | {:workflow_path, String.t()}
          | {:project_name, String.t()}
        ]

  @spec start_link(project_spec()) :: Supervisor.on_start()
  def start_link(opts) do
    project_name = Keyword.fetch!(opts, :project_name)
    Supervisor.start_link(__MODULE__, opts, name: via_tuple(project_name, :supervisor))
  end

  @impl true
  def init(opts) do
    project_name = Keyword.fetch!(opts, :project_name)
    workflow_path = Keyword.fetch!(opts, :workflow_path)

    orchestrator_opts = [
      name: via_tuple(project_name, :orchestrator),
      project_name: project_name,
      task_supervisor: via_tuple(project_name, :task_supervisor),
      port_supervisor: via_tuple(project_name, :port_supervisor)
    ]

    children = [
      {WorkflowStore, name: via_tuple(project_name, :workflow_store), workflow_path: workflow_path},
      {DynamicSupervisor, name: via_tuple(project_name, :port_supervisor), strategy: :one_for_one},
      {Task.Supervisor, name: via_tuple(project_name, :task_supervisor)},
      {Orchestrator, orchestrator_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Builds a via tuple for registry lookup.
  """
  @spec via_tuple(String.t(), atom()) ::
          {:via, Registry, {CymphonyElixir.ProjectRegistry, {String.t(), atom()}}}
  def via_tuple(project_name, role) do
    {:via, Registry, {CymphonyElixir.ProjectRegistry, {project_name, role}}}
  end

  @doc """
  Looks up a project process by name and role.
  Returns the pid or nil.
  """
  @spec lookup(String.t(), atom()) :: pid() | nil
  def lookup(project_name, role) do
    case Registry.lookup(CymphonyElixir.ProjectRegistry, {project_name, role}) do
      [{pid, _}] ->
        if Process.alive?(pid), do: pid, else: nil

      [] ->
        nil
    end
  end

  @doc """
  Lists all registered project names.
  """
  @spec list_project_names() :: [String.t()]
  @spec list_project_names(atom()) :: [String.t()]
  def list_project_names(registry \\ CymphonyElixir.ProjectRegistry) do
    Registry.select(registry, [{{:"$1", :"$2", :_}, [], [:"$1"]}])
    |> Enum.map(fn {project_name, _role} -> project_name end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc """
  Lists all registered orchestrator pids with their project names.
  Returns a list of `{project_name, pid}` tuples.
  """
  @spec list_orchestrators() :: [{String.t(), pid()}]
  @spec list_orchestrators(atom()) :: [{String.t(), pid()}]
  def list_orchestrators(registry \\ CymphonyElixir.ProjectRegistry) do
    Registry.select(registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {{project_name, :orchestrator}, pid} when is_binary(project_name) and is_pid(pid) ->
        [{project_name, pid}]

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  @doc """
  Starts a project supervisor under `ProjectDynamicSupervisor`.

  `{:already_started, _}` is treated as success so a second start of the
  same project is a no-op. Other start errors are returned.
  """
  @spec start_project(String.t(), String.t()) :: :ok | {:error, term()}
  def start_project(project_name, workflow_path)
      when is_binary(project_name) and is_binary(workflow_path) do
    spec = {__MODULE__, project_name: project_name, workflow_path: workflow_path}

    case DynamicSupervisor.start_child(CymphonyElixir.ProjectDynamicSupervisor, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops the named project's supervisor if it is running under
  `ProjectDynamicSupervisor`.
  """
  @spec stop_project(String.t()) :: :ok | {:error, :not_found | term()}
  def stop_project(project_name) when is_binary(project_name) do
    case lookup(project_name, :supervisor) do
      nil ->
        {:error, :not_found}

      pid ->
        case DynamicSupervisor.terminate_child(CymphonyElixir.ProjectDynamicSupervisor, pid) do
          :ok ->
            await_unregistered(project_name)
            :ok

          other ->
            other
        end
    end
  end

  @doc """
  Regenerates the project's temp `WORKFLOW.md` from `config.json` and
  reloads the running `WorkflowStore`.

  The rewrite goes through `WorkflowGenerator.write/2`, so the regenerated file
  keeps mode `0600` (it carries the Linear API key) even when the original was
  created by an older build under the process umask.
  """
  @spec rewrite_workflow(String.t()) :: :ok | {:error, :not_found | term()}
  def rewrite_workflow(project_name) when is_binary(project_name) do
    case lookup(project_name, :workflow_store) do
      nil ->
        {:error, :not_found}

      store ->
        with {:ok, config} <- CymphonyConfig.load(),
             {:ok, project} <- CymphonyConfig.find_project(config, project_name),
             :ok <- WorkflowGenerator.write(WorkflowStore.path(store), project) do
          WorkflowStore.force_reload(store)
        end
    end
  end

  @doc """
  Blocks until no `ProjectRegistry` name is left for `project_name`.

  Registry drops names while handling the monitor `:DOWN`, which can still be
  in-flight after `DynamicSupervisor.terminate_child/2` returns, so callers that
  immediately re-look-up a project could otherwise see a stale pid. Gives up
  after `remaining_ms` and returns `:ok` either way — the wait is a courtesy,
  never a failure mode.
  """
  @spec await_unregistered(String.t()) :: :ok
  def await_unregistered(project_name) do
    await_unregistered(project_name, @unregister_budget_ms)
  end

  @doc """
  `await_unregistered/1` with an explicit millisecond budget.
  """
  @spec await_unregistered(String.t(), integer()) :: :ok
  def await_unregistered(project_name, remaining_ms) when remaining_ms > 0 do
    if registered?(project_name) do
      Process.sleep(@unregister_poll_ms)
      await_unregistered(project_name, remaining_ms - @unregister_poll_ms)
    else
      :ok
    end
  end

  def await_unregistered(_project_name, _remaining_ms), do: :ok

  defp registered?(project_name) do
    Enum.any?(@project_roles, fn role ->
      match?([_ | _], Registry.lookup(CymphonyElixir.ProjectRegistry, {project_name, role}))
    end)
  end
end
