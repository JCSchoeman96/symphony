defmodule SymphonyElixir.SourceControl.CandidateVerification do
  @moduledoc """
  One immutable candidate/CI verification snapshot.
  """

  alias SymphonyElixir.SourceControl.CandidateRef

  @enforce_keys [:status, :candidate_ref, :observed_at]
  defstruct [
    :status,
    :reason,
    :candidate_ref,
    :candidate_tree_sha,
    :policy_fingerprint,
    :check_results,
    :observed_at
  ]

  @type status ::
          :verified
          | :moved
          | :not_ready
          | :unavailable
          | :malformed
          | :ambiguous

  @type t :: %__MODULE__{
          status: status(),
          reason: atom() | String.t() | nil,
          candidate_ref: CandidateRef.t() | nil,
          candidate_tree_sha: String.t() | nil,
          policy_fingerprint: String.t() | nil,
          check_results: [map()] | nil,
          observed_at: DateTime.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, Map.put_new(attrs, :observed_at, DateTime.utc_now()))
  end

  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{status: :verified}), do: true
  def verified?(_verification), do: false
end
