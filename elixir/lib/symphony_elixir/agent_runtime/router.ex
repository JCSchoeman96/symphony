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

  @spec resolve(Issue.t(), %{String.t() => Profile.t()}) ::
          {:ok, Route.t()} | {:error, term()}
  def resolve(%Issue{state: state} = issue, profiles) when is_map(profiles) do
    normalized_state = Route.normalize_state(state || "")

    case Map.fetch(@state_profiles, normalized_state) do
      {:ok, profile_name} ->
        case Map.fetch(profiles, profile_name) do
          {:ok, %Profile{} = profile} ->
            {:ok, Route.new(%{issue | state: normalized_state}, profile)}

          {:ok, _profile} ->
            {:error, {:invalid_profile, profile_name}}

          :error ->
            {:error, {:missing_profile, profile_name}}
        end

      :error ->
        if MapSet.member?(@non_dispatchable_states, normalized_state) do
          {:error, {:not_dispatchable_state, normalized_state}}
        else
          {:error, {:unknown_issue_state, normalized_state}}
        end
    end
  end

  def resolve(%Issue{}, _profiles), do: {:error, :invalid_profiles}
end
