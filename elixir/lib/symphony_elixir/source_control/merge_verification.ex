defmodule SymphonyElixir.SourceControl.MergeVerification do
  @moduledoc """
  One immutable human-merge verification snapshot.
  """

  alias SymphonyElixir.SourceControl.CandidateRef

  @enforce_keys [:status, :candidate_ref, :observed_at]
  defstruct [
    :status,
    :reason,
    :candidate_ref,
    :merge_strategy,
    :merge_sha,
    :merge_tree_sha,
    :current_main_sha,
    :main_contains_merge?,
    :observed_at
  ]

  @type status ::
          :verified
          | :not_merged
          | :mismatch
          | :unsupported_strategy
          | :unavailable
          | :ambiguous

  @type merge_strategy :: :ordinary | :squash

  @type t :: %__MODULE__{
          status: status(),
          reason: atom() | String.t() | nil,
          candidate_ref: CandidateRef.t(),
          merge_strategy: merge_strategy() | nil,
          merge_sha: String.t() | nil,
          merge_tree_sha: String.t() | nil,
          current_main_sha: String.t() | nil,
          main_contains_merge?: boolean() | nil,
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
