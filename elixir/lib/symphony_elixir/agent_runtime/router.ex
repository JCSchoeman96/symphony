defmodule SymphonyElixir.AgentRuntime.Router do
  @moduledoc """
  Pure deterministic mapping from canonical work control to an agent profile.

  Routed resolution accepts only a validated `WorkItem`. The explicitly named
  legacy resolver retains provider aliases for the legacy workflow path.
  """

  alias SymphonyElixir.AgentRuntime.{Authority, Profile, Route}
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{LifecycleAssessment, WorkflowLifecycle, WorkItem}

  @canonical_responsibility_profiles %{
    "planning" => "planner",
    "implementation" => "builder",
    "review" => "reviewer",
    "correction" => "fixer",
    "merge" => "merge_gatekeeper"
  }

  @legacy_state_profiles %{
    "planning" => "planner",
    "ready" => "builder",
    "todo" => "builder",
    "open" => "builder",
    "opened" => "builder",
    "pending" => "builder",
    "started" => "builder",
    "in development" => "builder",
    "in progress" => "builder",
    "in review" => "reviewer",
    "human review" => "reviewer",
    "changes requested" => "fixer",
    "rework" => "fixer",
    "ready to merge" => "merge_gatekeeper",
    "merging" => "merge_gatekeeper"
  }

  @legacy_non_dispatchable_states MapSet.new([
                                    "backlog",
                                    "blocked",
                                    "done",
                                    "closed",
                                    "cancelled",
                                    "canceled",
                                    "duplicate"
                                  ])

  @standard_profile_names MapSet.new(["planner", "builder", "reviewer", "fixer", "merge_gatekeeper"])

  @spec resolve(WorkItem.t(), %{String.t() => Profile.t()}) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve(%WorkItem{} = work_item, profiles) when is_map(profiles) do
    resolve(work_item, profiles, nil)
  end

  def resolve(%WorkItem{}, profiles) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%Issue{}, profiles) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%Issue{}, _profiles), do: {:error, :canonical_work_item_required}
  def resolve(_work_item, _profiles), do: {:error, :invalid_work_item}

  @spec resolve(WorkItem.t(), %{String.t() => Profile.t()}, map() | nil) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve(%WorkItem{} = work_item, profiles, routes)
      when is_map(profiles) and (is_map(routes) or is_nil(routes)) do
    with {:ok, canonical_state} <- canonical_route_state(work_item),
         {:ok, profile_name} <- profile_name_for_state(canonical_state, routes),
         {:ok, profile} <- fetch_profile(profiles, profile_name),
         :ok <- validate_responsibility(canonical_state, profile),
         :ok <- Profile.validate_effective_policy(profile),
         :ok <- Authority.validate_profile(profile) do
      issue = %Issue{id: work_item.id, state: WorkflowLifecycle.display(canonical_state), dispatchable: true}
      {:ok, Route.new(issue, profile)}
    else
      {:error, _reason} = error -> error
    end
  end

  def resolve(%WorkItem{}, profiles, _routes) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%WorkItem{}, _profiles, _routes), do: {:error, :invalid_work_item}
  def resolve(%Issue{}, profiles, _routes) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%Issue{}, _profiles, _routes), do: {:error, :canonical_work_item_required}
  def resolve(_work_item, _profiles, _routes), do: {:error, :invalid_work_item}

  @doc """
  Resolves a raw provider issue for the explicitly configured legacy workflow.

  This function is intentionally not used by routed authority decisions.
  """
  @spec resolve_legacy(Issue.t(), %{String.t() => Profile.t()}) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve_legacy(%Issue{id: issue_id, state: state} = issue, profiles)
      when is_map(profiles) and is_binary(issue_id) and is_binary(state) do
    resolve_legacy(issue, profiles, nil)
  end

  def resolve_legacy(%Issue{}, profiles) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve_legacy(%Issue{}, _profiles), do: {:error, :invalid_issue}

  @spec resolve_legacy(Issue.t(), %{String.t() => Profile.t()}, map() | nil) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve_legacy(%Issue{id: issue_id, state: state} = issue, profiles, routes)
      when is_map(profiles) and is_binary(issue_id) and is_binary(state) and
             (is_map(routes) or is_nil(routes)) do
    normalized_state = Route.normalize_state(state)

    case legacy_profile_name_for_state(normalized_state, routes) do
      {:ok, profile_name} ->
        resolve_legacy_profile(issue, normalized_state, profiles, profile_name)

      {:error, reason} ->
        {:error, reason}

      :unknown ->
        if MapSet.member?(@legacy_non_dispatchable_states, normalized_state) do
          {:error, {:not_dispatchable_state, normalized_state}}
        else
          {:error, {:unknown_issue_state, normalized_state}}
        end
    end
  end

  def resolve_legacy(%Issue{}, profiles, _routes) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve_legacy(%Issue{}, _profiles, _routes), do: {:error, :invalid_issue}

  @spec validate_routes(map() | nil, %{String.t() => Profile.t()}) :: :ok | {:error, term()}
  def validate_routes(routes, profiles) when (is_map(routes) or is_nil(routes)) and is_map(profiles) do
    routes = routes || %{}

    case normalize_routes(routes) do
      {:ok, normalized_routes} -> validate_normalized_routes(normalized_routes, profiles)
      {:error, _reason} = error -> error
    end
  end

  def validate_routes(_routes, _profiles), do: {:error, :invalid_routes}

  @spec expected_responsibility(term()) :: String.t() | nil
  def expected_responsibility(state), do: WorkflowLifecycle.responsibility(state)

  defp canonical_route_state(
         %WorkItem{
           lifecycle_assessment: assessment,
           authority_disposition: _disposition,
           validated_lifecycle_state: state
         } = work_item
       ) do
    cond do
      not LifecycleAssessment.validated?(assessment) ->
        {:error, lifecycle_assessment_error(assessment)}

      not WorkItem.authority_available?(%WorkItem{} = work_item) ->
        {:error, :authority_unavailable}

      not WorkflowLifecycle.canonical?(state) ->
        {:error, :missing_validated_lifecycle_state}

      not WorkflowLifecycle.dispatchable?(state) and not routed_continuation_state?(state) ->
        {:error, {:not_dispatchable_state, WorkflowLifecycle.display(state) |> Route.normalize_state()}}

      true ->
        {:ok, state}
    end
  end

  defp canonical_route_state(%WorkItem{}), do: {:error, :invalid_work_item}

  defp lifecycle_assessment_error(%LifecycleAssessment{status: :validation_required}),
    do: :lifecycle_validation_required

  defp lifecycle_assessment_error(%LifecycleAssessment{status: :authority_reducing, reason: reason}),
    do: {:authority_reducing, reason}

  defp lifecycle_assessment_error(%LifecycleAssessment{status: :invalid, reason: reason}),
    do: {:invalid_lifecycle, reason}

  defp lifecycle_assessment_error(%LifecycleAssessment{status: status}), do: {:invalid_lifecycle, status}

  defp routed_continuation_state?(state), do: state in [:planning, :in_progress, :in_review, :changes_requested]

  defp profile_name_for_state(state, routes) do
    normalized_state = Route.normalize_state(WorkflowLifecycle.display(state))

    case normalize_routes(routes || %{}) do
      {:ok, normalized_routes} ->
        profile_name_from_routes(state, normalized_state, normalized_routes)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp profile_name_from_routes(state, normalized_state, routes) do
    case Map.fetch(routes, normalized_state) do
      {:ok, profile_name} -> {:ok, profile_name}
      :error -> default_profile_name(state, normalized_state)
    end
  end

  defp default_profile_name(state, normalized_state) do
    case Map.fetch(@canonical_responsibility_profiles, WorkflowLifecycle.responsibility(state)) do
      {:ok, profile_name} -> {:ok, profile_name}
      :error -> {:error, {:not_dispatchable_state, normalized_state}}
    end
  end

  defp fetch_profile(profiles, profile_name) do
    case Map.get(profiles, profile_name) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, {:missing_profile, profile_name}}
      _profile -> {:error, {:invalid_profile, profile_name}}
    end
  end

  defp validate_responsibility(state, %Profile{responsibility: responsibility}) do
    case WorkflowLifecycle.responsibility(state) do
      ^responsibility ->
        :ok

      expected ->
        {:error, {:route_responsibility_mismatch, Route.normalize_state(WorkflowLifecycle.display(state)), expected}}
    end
  end

  defp resolve_legacy_profile(%Issue{} = issue, normalized_state, profiles, profile_name) do
    case Map.get(profiles, profile_name) do
      %Profile{} = profile ->
        with :ok <- validate_legacy_responsibility(normalized_state, profile),
             :ok <- Profile.validate_effective_policy(profile) do
          {:ok, Route.new(%{issue | state: normalized_state}, profile)}
        else
          {:error, {:route_responsibility_mismatch, _state, _responsibility} = reason} -> {:error, reason}
          {:error, message} -> {:error, {:invalid_profile, profile_name, message}}
        end

      nil ->
        {:error, {:missing_profile, profile_name}}

      _profile ->
        {:error, {:invalid_profile, profile_name}}
    end
  end

  defp legacy_profile_name_for_state(state, routes) do
    case Map.fetch(@legacy_state_profiles, state) do
      {:ok, default_profile_name} ->
        case normalize_legacy_routes(routes || %{}) do
          {:ok, normalized_routes} -> {:ok, Map.get(normalized_routes, state, default_profile_name)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        :unknown
    end
  end

  defp validate_legacy_responsibility(state, %Profile{responsibility: responsibility}) do
    expected =
      case state do
        "planning" -> "planning"
        state when state in ["ready", "todo", "open", "opened", "pending", "started", "in development", "in progress"] -> "implementation"
        state when state in ["in review", "human review"] -> "review"
        state when state in ["changes requested", "rework"] -> "correction"
        state when state in ["ready to merge", "merging"] -> "merge"
        _state -> nil
      end

    case expected do
      ^responsibility -> :ok
      _expected -> {:error, {:route_responsibility_mismatch, state, responsibility}}
    end
  end

  defp validate_normalized_routes(routes, profiles) do
    case validate_route_targets(routes, profiles) do
      :ok -> validate_custom_profile_references(routes, profiles)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_routes(routes) when is_map(routes) do
    Enum.reduce_while(routes, {:ok, %{}}, fn {raw_state, raw_profile_name}, {:ok, normalized} ->
      case normalize_route_entry(raw_state, raw_profile_name, normalized) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_routes(_routes), do: {:error, :invalid_routes}

  defp normalize_route_entry(raw_state, raw_profile_name, normalized) do
    case WorkflowLifecycle.parse(to_string(raw_state)) do
      {:ok, canonical_state} ->
        state = Route.normalize_state(WorkflowLifecycle.display(canonical_state))

        cond do
          not is_binary(raw_profile_name) or String.trim(raw_profile_name) == "" ->
            {:error, {:invalid_route_profile, state, raw_profile_name}}

          Map.has_key?(normalized, state) ->
            {:error, {:route_state_collision, state}}

          true ->
            {:ok, Map.put(normalized, state, Profile.normalize_name(raw_profile_name))}
        end

      {:error, _reason} ->
        {:error, {:invalid_route_state, raw_state}}
    end
  end

  defp normalize_legacy_routes(routes) when is_map(routes) do
    Enum.reduce_while(routes, {:ok, %{}}, fn {raw_state, raw_profile_name}, {:ok, normalized} ->
      state = Route.normalize_state(to_string(raw_state))

      cond do
        state == "" ->
          {:halt, {:error, {:invalid_route_state, raw_state}}}

        not is_binary(raw_profile_name) or String.trim(raw_profile_name) == "" ->
          {:halt, {:error, {:invalid_route_profile, state, raw_profile_name}}}

        Map.has_key?(normalized, state) ->
          {:halt, {:error, {:route_state_collision, state}}}

        true ->
          {:cont, {:ok, Map.put(normalized, state, Profile.normalize_name(raw_profile_name))}}
      end
    end)
  end

  defp normalize_legacy_routes(_routes), do: {:error, :invalid_routes}

  defp validate_route_targets(routes, profiles) do
    Enum.reduce_while(routes, :ok, fn {state, profile_name}, :ok ->
      expected = WorkflowLifecycle.responsibility(state)

      case Map.get(profiles, profile_name) do
        %Profile{responsibility: ^expected} ->
          {:cont, :ok}

        %Profile{responsibility: responsibility} ->
          {:halt, {:error, {:route_responsibility_mismatch, state, responsibility}}}

        _ ->
          {:halt, {:error, {:missing_profile, profile_name}}}
      end
    end)
  end

  defp validate_custom_profile_references(routes, profiles) do
    referenced_profiles = Map.values(routes) |> MapSet.new()

    Enum.reduce_while(Map.keys(profiles), :ok, fn profile_name, :ok ->
      if MapSet.member?(@standard_profile_names, profile_name) or
           MapSet.member?(referenced_profiles, profile_name) do
        {:cont, :ok}
      else
        {:halt, {:error, {:unreferenced_profile, profile_name}}}
      end
    end)
  end
end
