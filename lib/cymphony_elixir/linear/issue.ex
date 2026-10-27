defmodule CymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_type,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          state_type: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @doc """
  Native Todo dependency gate shared by dispatch, continuation and reconciliation.

  Terminal state names are normalized in the supplied set. Unknown blockers hold
  Todo; an in-progress phase may continue while its predecessors remain open.
  """
  @spec todo_blocked_by_non_terminal?(t(), MapSet.t(String.t())) :: boolean()
  def todo_blocked_by_non_terminal?(%__MODULE__{state: state, blocked_by: blockers}, terminal_states)
      when is_binary(state) and is_list(blockers) do
    normalize_state(state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not MapSet.member?(terminal_states, normalize_state(blocker_state))

        _ ->
          true
      end)
  end

  def todo_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()
end
