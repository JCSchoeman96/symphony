defmodule SymphonyElixir.AgentRuntime.Router do
  @moduledoc """
  Pure deterministic mapping from tracker state to an agent profile.
  """

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Tracker.Issue

  @state_profiles %{
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

  @non_dispatchable_states MapSet.new([
                             "backlog",
                             "blocked",
                             "done",
                             "closed",
                             "cancelled",
                             "canceled",
                             "duplicate"
                           ])

  @standard_profile_names MapSet.new(["planner", "builder", "reviewer", "fixer", "merge_gatekeeper"])

  @state_responsibilities %{
    "planning" => "planning",
    "ready" => "implementation",
    "todo" => "implementation",
    "open" => "implementation",
    "opened" => "implementation",
    "pending" => "implementation",
    "started" => "implementation",
    "in development" => "implementation",
    "in progress" => "implementation",
    "in review" => "review",
    "human review" => "review",
    "changes requested" => "correction",
    "rework" => "correction",
    "ready to merge" => "merge",
    "merging" => "merge"
  }

  @spec resolve(Issue.t(), %{String.t() => Profile.t()}) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve(%Issue{id: issue_id, state: state} = issue, profiles)
      when is_map(profiles) and is_binary(issue_id) and is_binary(state) do
    resolve(issue, profiles, nil)
  end

  def resolve(%Issue{}, profiles) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%Issue{}, _profiles), do: {:error, :invalid_issue}

  @spec resolve(Issue.t(), %{String.t() => Profile.t()}, map() | nil) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve(%Issue{id: issue_id, state: state} = issue, profiles, routes)
      when is_map(profiles) and is_binary(issue_id) and is_binary(state) and
             (is_map(routes) or is_nil(routes)) do
    normalized_state = Route.normalize_state(state)

    case profile_name_for_state(normalized_state, routes) do
      {:ok, profile_name} ->
        resolve_profile(issue, normalized_state, profiles, profile_name)

      {:error, reason} ->
        {:error, reason}

      :unknown ->
        if MapSet.member?(@non_dispatchable_states, normalized_state) do
          {:error, {:not_dispatchable_state, normalized_state}}
        else
          {:error, {:unknown_issue_state, normalized_state}}
        end
    end
  end

  def resolve(%Issue{}, profiles, _routes) when not is_map(profiles), do: {:error, :invalid_profiles}
  def resolve(%Issue{}, _profiles, _routes), do: {:error, :invalid_issue}

  @spec validate_routes(map() | nil, %{String.t() => Profile.t()}) :: :ok | {:error, term()}
  def validate_routes(routes, profiles) when (is_map(routes) or is_nil(routes)) and is_map(profiles) do
    routes = routes || %{}

    case normalize_routes(routes) do
      {:ok, normalized_routes} -> validate_normalized_routes(normalized_routes, profiles)
      {:error, _reason} = error -> error
    end
  end

  def validate_routes(_routes, _profiles), do: {:error, :invalid_routes}

  @spec expected_responsibility(String.t()) :: String.t() | nil
  def expected_responsibility(state), do: Map.get(@state_responsibilities, Route.normalize_state(state))

  defp resolve_profile(%Issue{} = issue, normalized_state, profiles, profile_name) do
    case Map.get(profiles, profile_name) do
      %Profile{} = profile -> validate_profile_route(issue, normalized_state, profile_name, profile)
      nil -> {:error, {:missing_profile, profile_name}}
      _profile -> {:error, {:invalid_profile, profile_name}}
    end
  end

  defp validate_profile_route(%Issue{} = issue, normalized_state, profile_name, profile) do
    with :ok <- validate_responsibility(normalized_state, profile),
         :ok <- Profile.validate_effective_policy(profile) do
      {:ok, Route.new(%{issue | state: normalized_state}, profile)}
    else
      {:error, {:route_responsibility_mismatch, _state, _responsibility} = reason} ->
        {:error, reason}

      {:error, message} ->
        {:error, {:invalid_profile, profile_name, message}}
    end
  end

  defp validate_normalized_routes(routes, profiles) do
    case validate_route_targets(routes, profiles) do
      :ok -> validate_custom_profile_references(routes, profiles)
      {:error, _reason} = error -> error
    end
  end

  defp profile_name_for_state(state, routes) do
    case Map.fetch(@state_profiles, state) do
      {:ok, default_profile_name} ->
        case normalize_routes(routes || %{}) do
          {:ok, normalized_routes} -> {:ok, Map.get(normalized_routes, state, default_profile_name)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        :unknown
    end
  end

  defp normalize_routes(routes) when is_map(routes) do
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

  defp validate_route_targets(routes, profiles) do
    Enum.reduce_while(routes, :ok, fn {state, profile_name}, :ok ->
      expected = Map.get(@state_responsibilities, state)

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

  defp validate_responsibility(state, %Profile{responsibility: responsibility}) do
    case Map.get(@state_responsibilities, state) do
      ^responsibility -> :ok
      _expected -> {:error, {:route_responsibility_mismatch, state, responsibility}}
    end
  end
end
