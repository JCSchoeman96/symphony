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
    :fingerprint,
    :starting_state_fingerprint
  ]

  @type t :: %__MODULE__{
          issue_id: String.t(),
          starting_state: String.t(),
          profile_name: String.t(),
          runtime_name: String.t(),
          responsibility: String.t(),
          profile: Profile.t() | nil,
          fingerprint: String.t(),
          starting_state_fingerprint: String.t()
        }

  @spec new(Issue.routable_t(), Profile.t()) :: t()
  def new(%Issue{id: issue_id, state: state}, %Profile{} = profile)
      when is_binary(issue_id) and is_binary(state) do
    route = %__MODULE__{
      issue_id: issue_id,
      starting_state: normalize_state(state),
      profile_name: profile.name,
      runtime_name: profile.runtime,
      responsibility: profile.responsibility,
      profile: profile,
      fingerprint: "",
      starting_state_fingerprint: ""
    }

    %{
      route
      | fingerprint: fingerprint(route),
        starting_state_fingerprint: starting_state_fingerprint(route)
    }
  end

  @doc false
  @spec legacy(Issue.t()) :: t()
  def legacy(%Issue{id: issue_id, state: state})
      when is_binary(issue_id) and is_binary(state) do
    route = %__MODULE__{
      issue_id: issue_id,
      starting_state: normalize_state(state),
      profile_name: "legacy",
      runtime_name: "codex",
      responsibility: "implementation",
      profile: nil,
      fingerprint: "",
      starting_state_fingerprint: ""
    }

    %{
      route
      | fingerprint: fingerprint(route),
        starting_state_fingerprint: starting_state_fingerprint(route)
    }
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

    digest(data)
  end

  @spec starting_state_fingerprint(t()) :: String.t()
  def starting_state_fingerprint(%__MODULE__{starting_state: starting_state}), do: digest(starting_state)

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

  defp profile_fingerprint(nil), do: :legacy

  defp digest(data) do
    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end
end
