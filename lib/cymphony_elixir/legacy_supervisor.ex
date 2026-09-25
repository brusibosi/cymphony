defmodule CymphonyElixir.LegacySupervisor do
  @moduledoc """
  On-demand supervised runtime for a single hand-authored WORKFLOW.md.

  It is not part of the application boot children: multi-project mode starts
  project-specific runtimes instead, and release boot can precede CLI parsing.
  """

  use Supervisor

  alias CymphonyElixir.{Orchestrator, WorkflowStore}

  @doc "Rejects changing the workflow path of an already-running legacy runtime."
  @spec ensure_workflow_path(String.t()) :: :ok | {:error, {:already_running_with_workflow, String.t()}}
  def ensure_workflow_path(path) when is_binary(path) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        running_path = WorkflowStore.path(WorkflowStore)

        if running_path == path do
          :ok
        else
          {:error, {:already_running_with_workflow, running_path}}
        end
    end
  end

  @doc "Starts the legacy runtime once beneath the application's dynamic supervisor."
  @spec start() :: :ok | {:error, term()}
  def start do
    case DynamicSupervisor.start_child(CymphonyElixir.ProjectDynamicSupervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([WorkflowStore, Orchestrator], strategy: :one_for_one)
  end
end
