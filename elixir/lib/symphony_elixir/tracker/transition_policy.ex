defmodule SymphonyElixir.Tracker.TransitionPolicy do
  @moduledoc """
  Pure authorization policy for workflow-controlled issue state transitions.

  Provider-native transition tools call this policy with the responsibility and
  dependency decision captured when the agent session was bound. The policy
  authorizes only the handoff owned by that responsibility; it does not mutate
  tracker or orchestrator state.
  """

  @handoff_targets %{
    "planning" => %{"planning" => ["ready"]},
    "implementation" => %{
      "ready" => ["in review"],
      "todo" => ["in review"],
      "open" => ["in review"],
      "opened" => ["in review"],
      "pending" => ["in review"],
      "started" => ["in review"],
      "in development" => ["in review"],
      "in progress" => ["in review"]
    },
    "review" => %{"in review" => ["changes requested", "ready to merge"]},
    "correction" => %{
      "changes requested" => ["in review"],
      "rework" => ["in review"]
    },
    "merge" => %{}
  }

  @type authorization_error :: %{
          code: :invalid_transition_context | :unauthorized_transition | :dependency_transition_denied,
          reason: atom()
        }

  @spec authorize(map()) :: :ok | {:error, authorization_error()}
  def authorize(context) when is_map(context) do
    with {:ok, responsibility} <- normalized_context_token(context, :responsibility),
         {:ok, current_state} <- normalized_context_token(context, :current_state),
         {:ok, target_state} <- normalized_context_token(context, :target_state),
         {:ok, dependency_decision} <- dependency_decision(context),
         :ok <- authorize_handoff(responsibility, current_state, target_state),
         :ok <- authorize_dependencies(responsibility, target_state, dependency_decision) do
      :ok
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, invalid_context_error(reason)}
    end
  end

  def authorize(_context), do: {:error, invalid_context_error(:not_a_map)}

  @doc "Checks the role-owned handoff before reading mutable provider state."
  @spec authorize_intent(map()) :: :ok | {:error, authorization_error()}
  def authorize_intent(context) do
    with {:ok, responsibility} <- normalized_context_token(context, :responsibility),
         {:ok, current_state} <- normalized_context_token(context, :current_state),
         {:ok, target_state} <- normalized_context_token(context, :target_state),
         :ok <- authorize_handoff(responsibility, current_state, target_state) do
      :ok
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, invalid_context_error(reason)}
    end
  end

  defp normalized_context_token(context, key) do
    value = context_value(context, key)

    case value do
      value when is_binary(value) ->
        normalized = normalize_token(value)
        if normalized == "", do: {:error, {:missing, key}}, else: {:ok, normalized}

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp context_value(context, :current_state) do
    Map.get(context, :current_state) ||
      Map.get(context, "current_state") ||
      Map.get(context, :current_issue_state) ||
      Map.get(context, "current_issue_state")
  end

  defp context_value(context, key), do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp dependency_decision(context) do
    case Map.get(context, :dependency_decision) || Map.get(context, "dependency_decision") do
      decision when is_map(decision) -> {:ok, decision}
      _ -> {:error, :missing_dependency_decision}
    end
  end

  defp authorize_handoff(responsibility, current_state, target_state) do
    allowed_targets = get_in(@handoff_targets, [responsibility, current_state]) || []

    if target_state in allowed_targets do
      :ok
    else
      {:error, unauthorized_error()}
    end
  end

  defp authorize_dependencies("implementation", _target_state, decision),
    do: require_complete_allowed_dependency(decision)

  defp authorize_dependencies("correction", _target_state, decision),
    do: require_complete_allowed_dependency(decision)

  defp authorize_dependencies("review", "ready to merge", decision) do
    if complete_allowed_dependency?(decision) and truthy?(decision_value(decision, :merge_permitted?)) do
      :ok
    else
      {:error, dependency_error()}
    end
  end

  defp authorize_dependencies(_responsibility, _target_state, decision) do
    if truthy?(decision_value(decision, :allowed?)) do
      :ok
    else
      {:error, dependency_error()}
    end
  end

  defp require_complete_allowed_dependency(decision) do
    if complete_allowed_dependency?(decision) do
      :ok
    else
      {:error, dependency_error()}
    end
  end

  defp complete_allowed_dependency?(decision) do
    truthy?(decision_value(decision, :allowed?)) and
      decision_value(decision, :dependency_completeness) == :complete and
      dependency_status(decision) in [:none, :satisfied]
  end

  defp dependency_status(decision) do
    case decision_value(decision, :dependency_status) do
      status when status in [:none, :satisfied] -> status
      "none" -> :none
      "satisfied" -> :satisfied
      _ -> :unsafe
    end
  end

  defp decision_value(decision, key) do
    Map.get(decision, key) || Map.get(decision, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp invalid_context_error(reason), do: %{code: :invalid_transition_context, reason: reason}
  defp unauthorized_error, do: %{code: :unauthorized_transition, reason: :handoff_not_owned}
  defp dependency_error, do: %{code: :dependency_transition_denied, reason: :dependency_not_safe}

  defp normalize_token(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end
end
