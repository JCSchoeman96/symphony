defmodule SymphonyElixir.WorkControl.CompletionProof do
  @moduledoc """
  Typed source-control evidence for the controlled completion path.

  A proof moves through merge authorization, verified merge, and provider
  closure. Each stage is bound to one work item, candidate, policy snapshot,
  and provider project contract.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.{CandidateRef, CandidateVerification, MergeVerification}

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderObservation,
    ProviderProjectContract
  }

  @sha_pattern ~r/\A[0-9a-f]{40}\z/

  @stage_guards %{
    merge_authorized: :merge_guard_verified,
    merge_verified: :completion_merge_verified,
    completed: :completion_proof_verified
  }

  defstruct [
    :class,
    :name,
    :outcome,
    :stage,
    :work_item_id,
    :provider_project_fingerprint,
    :workspace_id,
    :project_id,
    :candidate_ref,
    :candidate_tree_sha,
    :policy_fingerprint,
    :review_acceptance_evidence,
    :review_attestation_fingerprint,
    :review_responsibility,
    :review_runtime_attempt_fingerprint,
    :review_lineage_generation,
    :review_attested_at,
    :candidate_verification,
    :merge_verification,
    :closure_observation,
    :source_control_signature,
    :issuance_signature
  ]

  @type stage :: :merge_authorized | :merge_verified | :completed

  @type t :: %__MODULE__{
          class: :mechanical_guard,
          name: :merge_guard_verified | :completion_merge_verified | :completion_proof_verified,
          outcome: :verified,
          stage: stage(),
          work_item_id: String.t(),
          provider_project_fingerprint: String.t(),
          workspace_id: String.t(),
          project_id: String.t(),
          candidate_ref: CandidateRef.t(),
          candidate_tree_sha: String.t(),
          policy_fingerprint: String.t(),
          review_acceptance_evidence: map(),
          review_attestation_fingerprint: String.t(),
          review_responsibility: atom() | String.t(),
          review_runtime_attempt_fingerprint: String.t(),
          review_lineage_generation: non_neg_integer() | String.t(),
          review_attested_at: DateTime.t(),
          candidate_verification: CandidateVerification.t(),
          merge_verification: MergeVerification.t() | nil,
          closure_observation: map() | nil,
          source_control_signature: String.t() | nil,
          issuance_signature: String.t() | nil
        }

  @spec new_merge_authorized(map()) :: {:ok, t()} | {:error, atom()}
  def new_merge_authorized(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.update(:review_acceptance_evidence, nil, &sanitize_review_evidence/1)
      |> Map.put(:review_attestation_fingerprint, review_attestation_fingerprint(attrs))
      |> Map.merge(review_attestation_provenance(attrs))
      |> Map.delete(:review_attestation)

    proof =
      struct(
        __MODULE__,
        Map.merge(attrs, %{
          class: :mechanical_guard,
          name: :merge_guard_verified,
          outcome: :verified,
          stage: :merge_authorized
        })
      )

    if valid_revalidation_seed?(proof) do
      {:ok, proof}
    else
      {:error, :invalid_merge_authorization}
    end
  end

  def new_merge_authorized(_attrs), do: {:error, :invalid_merge_authorization}

  @spec with_merge_verification(t(), MergeVerification.t()) :: {:ok, t()} | {:error, atom()}
  def with_merge_verification(%__MODULE__{} = proof, %MergeVerification{} = verification) do
    verified = %{
      proof
      | name: :completion_merge_verified,
        stage: :merge_verified,
        merge_verification: verification,
        closure_observation: nil,
        source_control_signature: nil,
        issuance_signature: nil
    }

    with true <- proof.stage in [:merge_authorized, :merge_verified],
         true <- valid_evidence?(proof),
         true <- valid_revalidation_seed?(verified) do
      {:ok, verified}
    else
      _failure -> {:error, :invalid_merge_verification}
    end
  end

  def with_merge_verification(_proof, _verification), do: {:error, :invalid_merge_verification}

  @spec close(t(), ProviderObservation.t(), ProviderProjectContract.t()) ::
          {:ok, t()} | {:error, atom()}
  def close(
        %__MODULE__{} = proof,
        %ProviderObservation{} = observation,
        %ProviderProjectContract{} = contract
      ) do
    completed = %{
      proof
      | name: :completion_proof_verified,
        stage: :completed,
        closure_observation: closure_snapshot(observation)
    }

    with true <- proof.stage == :merge_verified,
         true <- valid_evidence?(proof),
         true <- provider_closure_matches?(completed, observation, contract),
         {:ok, completed} <- sign_proof(completed),
         true <- valid_evidence?(completed) do
      {:ok, completed}
    else
      _failure -> {:error, :provider_closure_mismatch}
    end
  end

  def close(_proof, _observation, _contract), do: {:error, :provider_closure_mismatch}

  @spec valid_evidence?(term()) :: boolean()
  def valid_evidence?(%__MODULE__{} = proof) do
    valid_revalidation_seed?(proof) and SourceControl.valid_completion_proof_signature?(proof) and
      valid_closure_signature?(proof)
  end

  def valid_evidence?(_proof), do: false

  @spec valid_revalidation_seed?(term()) :: boolean()
  def valid_revalidation_seed?(%__MODULE__{} = proof) do
    proof.class == :mechanical_guard and proof.outcome == :verified and
      proof.name == Map.get(@stage_guards, proof.stage) and valid_identity?(proof) and
      valid_candidate?(proof) and valid_review_evidence?(proof) and stage_evidence_valid?(proof)
  end

  def valid_revalidation_seed?(_proof), do: false

  @doc false
  @spec source_control_payload(t()) :: binary()
  def source_control_payload(%__MODULE__{} = proof) do
    proof
    |> Map.from_struct()
    |> Map.drop([:stage, :name, :closure_observation, :source_control_signature, :issuance_signature])
    |> :erlang.term_to_binary()
  end

  @spec satisfies_guard?(t(), atom(), map()) :: boolean()
  def satisfies_guard?(%__MODULE__{} = proof, guard_name, context) when is_map(context) do
    valid_evidence?(proof) and Map.get(@stage_guards, proof.stage) == guard_name and
      context_identity_matches?(proof, context)
  end

  def satisfies_guard?(_proof, _guard_name, _context), do: false

  @spec closes_observation?(t(), ProviderObservation.t() | map()) :: boolean()
  def closes_observation?(
        %__MODULE__{stage: :completed, closure_observation: closed} = proof,
        %ProviderObservation{} = observed
      ) do
    is_map(closed) and valid_evidence?(proof) and observation_identity(closed) == observation_identity(observed)
  end

  def closes_observation?(
        %__MODULE__{stage: :completed, closure_observation: closed} = proof,
        observed
      )
      when is_map(observed) do
    is_map(closed) and valid_evidence?(proof) and observation_identity(closed) == observation_identity(observed)
  end

  def closes_observation?(_proof, _observed), do: false

  defp valid_identity?(proof) do
    non_empty_string?(proof.work_item_id) and non_empty_string?(proof.provider_project_fingerprint) and
      non_empty_string?(proof.workspace_id) and non_empty_string?(proof.project_id)
  end

  defp valid_candidate?(proof) do
    match?(%CandidateRef{}, proof.candidate_ref) and CandidateRef.validate(proof.candidate_ref) == :ok and
      valid_sha?(proof.candidate_tree_sha) and non_empty_string?(proof.policy_fingerprint)
  end

  defp valid_review_evidence?(proof) do
    valid_review_snapshot?(proof) and valid_candidate_verification?(proof) and
      valid_review_attestation_provenance?(proof)
  rescue
    _error -> false
  end

  defp valid_review_snapshot?(proof) do
    review = proof.review_acceptance_evidence

    match?(
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified
      },
      review
    ) and candidate_ref_matches?(Map.get(review, :candidate_ref), proof.candidate_ref) and
      Map.get(review, :candidate_tree_sha) == proof.candidate_tree_sha and
      Map.get(review, :policy_fingerprint) == proof.policy_fingerprint
  end

  defp valid_candidate_verification?(proof) do
    case proof.candidate_verification do
      %CandidateVerification{status: :verified} = verification ->
        CandidateRef.equal?(verification.candidate_ref, proof.candidate_ref) and
          verification.candidate_tree_sha == proof.candidate_tree_sha and
          verification.policy_fingerprint == proof.policy_fingerprint

      _other ->
        false
    end
  end

  defp valid_review_attestation_provenance?(proof) do
    valid_sha256_fingerprint?(proof.review_attestation_fingerprint) and
      proof.review_responsibility in [:review, "review"] and
      valid_sha256_fingerprint?(proof.review_runtime_attempt_fingerprint) and
      valid_lineage_generation?(proof.review_lineage_generation) and
      match?(%DateTime{}, proof.review_attested_at)
  end

  defp stage_evidence_valid?(%__MODULE__{stage: :merge_authorized, merge_verification: nil, closure_observation: nil}),
    do: true

  defp stage_evidence_valid?(%__MODULE__{stage: :merge_verified} = proof) do
    match?(%MergeVerification{status: :verified, main_contains_merge?: true}, proof.merge_verification) and
      CandidateRef.equal?(proof.merge_verification.candidate_ref, proof.candidate_ref) and
      valid_sha?(proof.merge_verification.merge_sha) and valid_sha?(proof.merge_verification.merge_tree_sha) and
      valid_sha?(proof.merge_verification.current_main_sha) and is_nil(proof.closure_observation)
  rescue
    _error -> false
  end

  defp stage_evidence_valid?(%__MODULE__{stage: :completed} = proof) do
    is_map(proof.closure_observation) and
      stage_evidence_valid?(%{
        proof
        | stage: :merge_verified,
          name: :completion_merge_verified,
          closure_observation: nil
      }) and
      Map.get(proof.closure_observation, :work_item_id) == proof.work_item_id and
      Map.get(proof.closure_observation, :workspace_id) == proof.workspace_id and
      Map.get(proof.closure_observation, :project_id) == proof.project_id and
      Map.get(proof.closure_observation, :provider) == :plane and
      Map.get(proof.closure_observation, :presence) == :present
  end

  defp stage_evidence_valid?(_proof), do: false

  defp provider_closure_matches?(proof, observation, contract) do
    with true <- contract.provider == :plane,
         true <- proof.provider_project_fingerprint == ProviderProjectContract.fingerprint(contract),
         true <- proof.workspace_id == contract.workspace_id,
         true <- proof.project_id == contract.project_id,
         true <- proof.work_item_id == observation.work_item_id,
         true <- observation.provider == :plane,
         true <- observation.presence == :present,
         true <- observation.workspace_id == contract.workspace_id,
         true <- observation.project_id == contract.project_id,
         {:ok, :done} <- ProviderObservation.map_state(observation, contract) do
      true
    else
      _failure -> false
    end
  end

  defp context_identity_matches?(proof, context) do
    context_subject_matches?(proof, Map.get(context, :subject)) and
      context_contract_matches?(proof, Map.get(context, :provider_project_contract))
  end

  defp context_subject_matches?(_proof, nil), do: true
  defp context_subject_matches?(proof, {:work_item, work_item_id}), do: work_item_id == proof.work_item_id
  defp context_subject_matches?(_proof, _subject), do: false

  defp context_contract_matches?(_proof, nil), do: true

  defp context_contract_matches?(proof, %ProviderProjectContract{} = contract) do
    proof.provider_project_fingerprint == ProviderProjectContract.fingerprint(contract) and
      proof.workspace_id == contract.workspace_id and proof.project_id == contract.project_id
  end

  defp context_contract_matches?(_proof, _contract), do: false

  defp candidate_ref_matches?(candidate_ref, expected_ref) do
    case candidate_ref do
      %CandidateRef{} = ref ->
        CandidateRef.equal?(ref, expected_ref)

      map when is_map(map) ->
        case CandidateRef.new(map) do
          {:ok, ref} -> CandidateRef.equal?(ref, expected_ref)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp review_attestation_fingerprint(attrs) do
    work_item_id = Map.get(attrs, :work_item_id)

    case Map.get(attrs, :review_attestation) do
      %{class: :semantic_attestation, name: :review_accepted, subject: {:work_item, ^work_item_id}} = attestation ->
        if GuardClass.valid_evidence?(attestation) do
          digest = :crypto.hash(:sha256, :erlang.term_to_binary(attestation))
          "sha256:" <> Base.encode16(digest, case: :lower)
        end

      _invalid ->
        nil
    end
  end

  defp review_attestation_provenance(attrs) do
    work_item_id = Map.get(attrs, :work_item_id)

    case Map.get(attrs, :review_attestation) do
      %{class: :semantic_attestation, name: :review_accepted, subject: {:work_item, ^work_item_id}} = attestation ->
        if GuardClass.valid_evidence?(attestation) and review_responsibility?(attestation) do
          %{
            review_responsibility: Map.get(attestation, :responsibility),
            review_runtime_attempt_fingerprint: fingerprint_term(Map.get(attestation, :runtime_attempt_id)),
            review_lineage_generation: Map.get(attestation, :lineage_generation),
            review_attested_at: Map.get(attestation, :timestamp)
          }
        else
          %{}
        end

      _invalid ->
        %{}
    end
  end

  defp review_responsibility?(attestation),
    do: Map.get(attestation, :responsibility) in [:review, "review"]

  defp valid_lineage_generation?(value) when is_integer(value), do: value >= 0

  defp valid_lineage_generation?(value) when is_binary(value),
    do: String.trim(value) != ""

  defp valid_lineage_generation?(_value), do: false

  defp fingerprint_term(value) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(value))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp sign_proof(%__MODULE__{} = proof) do
    with {:ok, key} <- signing_key() do
      signature = :crypto.mac(:hmac, :sha256, key, proof_payload(proof))

      {:ok,
       %{
         proof
         | issuance_signature: "sha256:" <> Base.encode16(signature, case: :lower)
       }}
    end
  end

  defp valid_closure_signature?(%__MODULE__{stage: stage, issuance_signature: nil})
       when stage in [:merge_authorized, :merge_verified],
       do: true

  defp valid_closure_signature?(%__MODULE__{stage: :completed, issuance_signature: signature} = proof)
       when is_binary(signature) do
    with {:ok, key} <- signing_key(),
         {:ok, supplied} <- decode_signature(signature) do
      expected = :crypto.mac(:hmac, :sha256, key, proof_payload(proof))
      :crypto.hash_equals(supplied, expected)
    else
      _failure -> false
    end
  end

  defp valid_closure_signature?(_proof), do: false

  defp decode_signature("sha256:" <> encoded) do
    case Base.decode16(encoded, case: :lower) do
      {:ok, signature} when byte_size(signature) == 32 -> {:ok, signature}
      _ -> :error
    end
  end

  defp decode_signature(_signature), do: :error

  defp proof_payload(%__MODULE__{} = proof) do
    proof
    |> Map.from_struct()
    |> Map.put(:issuance_signature, nil)
    |> :erlang.term_to_binary()
  end

  defp signing_key do
    case Application.get_env(:symphony_elixir, :completion_proof_signing_key) do
      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, derive_signing_key(key)}

      _missing ->
        plane_api_key_signing_key()
    end
  end

  defp plane_api_key_signing_key do
    case Config.settings() do
      {:ok, %{tracker: %{kind: kind, api_key: api_key}}}
      when kind in [:plane, "plane"] and is_binary(api_key) and api_key != "" ->
        {:ok, derive_signing_key(api_key)}

      _missing ->
        {:error, :completion_proof_signing_key_required}
    end
  end

  defp derive_signing_key(key) do
    :crypto.hash(:sha256, "symphony-completion-proof-v1:" <> key)
  end

  defp sanitize_review_evidence(%{} = evidence) do
    Map.take(evidence, [
      :class,
      :name,
      :outcome,
      :candidate_ref,
      :candidate_tree_sha,
      :policy_fingerprint
    ])
  end

  defp sanitize_review_evidence(_evidence), do: nil

  defp valid_sha256_fingerprint?(value) when is_binary(value),
    do: Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, value)

  defp valid_sha256_fingerprint?(_value), do: false

  defp closure_snapshot(observation) do
    observation
    |> Map.from_struct()
    |> Map.take([
      :provider,
      :presence,
      :work_item_id,
      :workspace_id,
      :project_id,
      :provider_state_id,
      :provider_state_group,
      :provider_state_name,
      :provider_updated_at,
      :observed_at
    ])
  end

  defp observation_identity(observation) do
    Map.take(observation, [
      :provider,
      :work_item_id,
      :workspace_id,
      :project_id,
      :provider_state_id,
      :provider_state_group,
      :provider_state_name,
      :provider_updated_at,
      :presence
    ])
  end

  defp valid_sha?(value) when is_binary(value), do: Regex.match?(@sha_pattern, value)
  defp valid_sha?(_value), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false
end
