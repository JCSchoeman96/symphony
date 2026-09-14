defmodule SymphonyElixir.Dependency.Guard do
  @moduledoc """
  Applies the pure dependency policy to one normalized tracker issue.

  Guard failures are returned as safe, machine-readable decisions so the
  scheduler can retain diagnostics without guessing that a blocker is done.
  """

  alias SymphonyElixir.Dependency.Policy
  alias SymphonyElixir.Tracker.Issue

  @type decision :: map()

  @spec evaluate(Issue.t(), String.t()) :: decision()
  def evaluate(issue, responsibility), do: evaluate(issue, responsibility, [])

  @spec evaluate(Issue.t(), String.t(), keyword()) :: decision()
  def evaluate(%Issue{} = issue, responsibility, opts) do
    case Policy.evaluate(issue.state, responsibility, issue.blocked_by, opts) do
      {:ok, decision} ->
        Map.merge(decision, %{issue_id: issue.id, identifier: issue.identifier})

      {:error, reason} ->
        invalid_decision(issue, responsibility, reason)
    end
  end

  def evaluate(issue, responsibility, _opts) do
    %{
      allowed?: false,
      dependency_status: :invalidated,
      dependent_state: nil,
      responsibility: responsibility,
      reason: :dependency_data_invalid,
      merge_permitted?: false,
      blockers: [],
      unresolved_blockers: [],
      invalidated_blockers: [],
      diagnostic: {:invalid_issue, issue},
      issue_id: nil,
      identifier: nil
    }
  end

  @spec allowed?(Issue.t(), String.t(), keyword()) :: boolean()
  def allowed?(%Issue{} = issue, responsibility, opts \\ []) do
    evaluate(issue, responsibility, opts).allowed?
  end

  defp invalid_decision(%Issue{} = issue, responsibility, reason) do
    %{
      allowed?: false,
      dependency_status: :invalidated,
      dependent_state: normalize_state(issue.state),
      responsibility: responsibility,
      reason: dependency_error_reason(reason),
      merge_permitted?: false,
      blockers: issue.blocked_by,
      unresolved_blockers: [],
      invalidated_blockers: [],
      diagnostic: reason,
      issue_id: issue.id,
      identifier: issue.identifier
    }
  end

  defp dependency_error_reason({:malformed_blocker, _blocker}), do: :dependency_data_invalid
  defp dependency_error_reason({:unknown_blocker_state, _state}), do: :dependency_data_invalid
  defp dependency_error_reason(:invalid_blockers), do: :dependency_data_invalid
  defp dependency_error_reason(_reason), do: :dependency_policy_invalid

  defp normalize_state(state) when is_binary(state), do: String.downcase(String.trim(state))
  defp normalize_state(_state), do: nil
end
