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
    case Map.get(issue, :dependency_completeness, :complete) do
      :complete ->
        evaluate_complete_issue(issue, responsibility, opts)

      {:incomplete, reason} ->
        incomplete_decision(issue, responsibility, :incomplete, reason)

      {:unavailable, reason} ->
        incomplete_decision(issue, responsibility, :unavailable, reason)

      _invalid ->
        invalid_decision(issue, responsibility, :invalid_dependency_completeness)
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
      identifier: nil,
      dependency_completeness: :unavailable
    }
  end

  defp evaluate_complete_issue(%Issue{} = issue, responsibility, opts) do
    case Policy.evaluate(issue.state, responsibility, issue.blocked_by, opts) do
      {:ok, decision} ->
        Map.merge(decision, %{
          issue_id: issue.id,
          identifier: issue.identifier,
          dependency_completeness: :complete
        })

      {:error, reason} ->
        invalid_decision(issue, responsibility, reason)
    end
  end

  defp incomplete_decision(%Issue{} = issue, responsibility, status, reason) do
    %{
      allowed?: read_only_dependency_responsibility?(responsibility),
      dependency_status: status,
      dependent_state: normalize_state(issue.state),
      responsibility: responsibility,
      reason: :dependency_data_incomplete,
      merge_permitted?: false,
      blockers: issue.blocked_by,
      unresolved_blockers: [],
      invalidated_blockers: [],
      diagnostic: {:dependency_data_incomplete, reason},
      issue_id: issue.id,
      identifier: issue.identifier,
      dependency_completeness: Map.get(issue, :dependency_completeness)
    }
  end

  defp read_only_dependency_responsibility?(responsibility) when is_binary(responsibility) do
    String.downcase(String.trim(responsibility)) in ["planning", "review"]
  end

  defp read_only_dependency_responsibility?(_responsibility), do: false

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
      identifier: issue.identifier,
      dependency_completeness: Map.get(issue, :dependency_completeness, :complete)
    }
  end

  defp dependency_error_reason({:malformed_blocker, _blocker}), do: :dependency_data_invalid
  defp dependency_error_reason({:unknown_blocker_state, _state}), do: :dependency_data_invalid
  defp dependency_error_reason(:invalid_blockers), do: :dependency_data_invalid
  defp dependency_error_reason(_reason), do: :dependency_policy_invalid

  defp normalize_state(state) when is_binary(state), do: String.downcase(String.trim(state))
  defp normalize_state(_state), do: nil
end
