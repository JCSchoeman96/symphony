defmodule SymphonyElixir.SourceControl.CandidateRef do
  @moduledoc """
  Immutable five-field source-control candidate identity mandated by H-050C.
  """

  @enforce_keys [
    :repository_identity,
    :base_sha,
    :candidate_sha,
    :pr_identity,
    :observed_pr_head_sha
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          repository_identity: String.t(),
          base_sha: String.t(),
          candidate_sha: String.t(),
          pr_identity: String.t(),
          observed_pr_head_sha: String.t()
        }

  @sha_pattern ~r/\A[0-9a-f]{40}\z/

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    ref = %__MODULE__{
      repository_identity: Map.get(attrs, :repository_identity),
      base_sha: normalize_sha(Map.get(attrs, :base_sha)),
      candidate_sha: normalize_sha(Map.get(attrs, :candidate_sha)),
      pr_identity: normalize_pr_identity(Map.get(attrs, :pr_identity)),
      observed_pr_head_sha: normalize_sha(Map.get(attrs, :observed_pr_head_sha))
    }

    with :ok <- validate(ref) do
      {:ok, ref}
    end
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = ref) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary([
          ref.repository_identity,
          ref.base_sha,
          ref.candidate_sha,
          ref.pr_identity,
          ref.observed_pr_head_sha
        ])
      )

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  @spec equal?(t(), t()) :: boolean()
  def equal?(%__MODULE__{} = left, %__MODULE__{} = right) do
    fingerprint(left) == fingerprint(right)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = ref) do
    with :ok <- validate_repository_identity(ref.repository_identity),
         :ok <- validate_sha(ref.base_sha, :base_sha),
         :ok <- validate_sha(ref.candidate_sha, :candidate_sha),
         :ok <- validate_pr_identity(ref.pr_identity),
         :ok <- validate_sha(ref.observed_pr_head_sha, :observed_pr_head_sha),
         true <- ref.candidate_sha == ref.observed_pr_head_sha do
      :ok
    else
      false -> {:error, :candidate_head_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec github_repository_identity(non_neg_integer()) :: String.t()
  def github_repository_identity(repository_id) when is_integer(repository_id) and repository_id > 0 do
    "github:repository:#{repository_id}"
  end

  defp validate_repository_identity(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.match?(trimmed, ~r/^github:repository:\d+$/) do
      :ok
    else
      {:error, :invalid_repository_identity}
    end
  end

  defp validate_repository_identity(_value), do: {:error, :invalid_repository_identity}

  defp validate_pr_identity(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.match?(trimmed, ~r/^\d+$/) do
      :ok
    else
      {:error, :invalid_pr_identity}
    end
  end

  defp validate_pr_identity(value) when is_integer(value) and value > 0, do: :ok
  defp validate_pr_identity(_value), do: {:error, :invalid_pr_identity}

  defp validate_sha(value, _field) when is_binary(value) do
    if Regex.match?(@sha_pattern, value), do: :ok, else: {:error, :invalid_sha}
  end

  defp validate_sha(_value, _field), do: {:error, :invalid_sha}

  defp normalize_sha(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_sha(_value), do: nil

  defp normalize_pr_identity(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_pr_identity(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> Integer.to_string(number)
      _ -> value
    end
  end

  defp normalize_pr_identity(_value), do: nil
end
