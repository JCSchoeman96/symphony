defmodule SymphonyElixir.AgentRuntime.Route do
  @moduledoc """
  Immutable routing decision for one worker attempt.
  """

  alias SymphonyElixir.AgentRuntime.Profile
  alias SymphonyElixir.Tracker.Issue

  defstruct [
    :issue_id,
    :starting_state,
    :profile_name,
    :runtime_name,
    :responsibility,
    :profile,
    :fingerprint
  ]

  @type t :: %__MODULE__{
          issue_id: String.t(),
          starting_state: String.t(),
          profile_name: String.t(),
          runtime_name: String.t(),
          responsibility: String.t(),
          profile: Profile.t(),
          fingerprint: String.t()
        }

  @spec new(Issue.t(), Profile.t()) :: t()
  def new(%Issue{id: issue_id, state: state}, %Profile{} = profile)
      when is_binary(issue_id) and is_binary(state) do
    route = %__MODULE__{
      issue_id: issue_id,
      starting_state: normalize_state(state),
      profile_name: profile.name,
      runtime_name: profile.runtime,
      responsibility: profile.responsibility,
      profile: profile
    }

    %{route | fingerprint: fingerprint(route)}
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = route) do
    data = {
      route.issue_id,
      route.profile_name,
      route.runtime_name,
      route.responsibility,
      profile_fingerprint(route.profile)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{fingerprint: left}, %__MODULE__{fingerprint: right}), do: left == right

  @spec normalize_state(String.t()) :: String.t()
  def normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp profile_fingerprint(%Profile{} = profile) do
    {
      profile.name,
      profile.responsibility,
      profile.runtime,
      profile.command,
      profile.model,
      profile.prompt,
      profile.sandbox,
      profile.max_turns,
      profile.concurrency_class
    }
  end
end
