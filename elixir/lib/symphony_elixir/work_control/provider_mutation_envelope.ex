defmodule SymphonyElixir.WorkControl.ProviderMutationEnvelope do
  @moduledoc """
  Provider-neutral identity for one already-authorized lifecycle mutation.

  The envelope carries correlation and bound target data. It grants no
  lifecycle authority and contains no transport credentials or payload.
  """

  alias SymphonyElixir.WorkControl.{ProviderProjectContract, TransitionAttempt}

  @enforce_keys [
    :provider_request_id,
    :transition_attempt_id,
    :work_item_id,
    :provider,
    :workspace_id,
    :project_id,
    :requested_from,
    :requested_to,
    :target_provider_state_id,
    :target_provider_state_group,
    :provider_contract_fingerprint,
    :submitted_at
  ]
  defstruct [
    :provider_request_id,
    :transition_attempt_id,
    :work_item_id,
    :provider,
    :workspace_id,
    :project_id,
    :requested_from,
    :requested_to,
    :target_provider_state_id,
    :target_provider_state_group,
    :provider_contract_fingerprint,
    :submitted_at,
    schema_version: 1,
    operation: :lifecycle_transition
  ]

  @type t :: %__MODULE__{
          schema_version: 1,
          provider_request_id: String.t(),
          transition_attempt_id: String.t(),
          work_item_id: String.t(),
          provider: atom(),
          workspace_id: String.t(),
          project_id: String.t(),
          requested_from: atom(),
          requested_to: atom(),
          target_provider_state_id: String.t(),
          target_provider_state_group: atom(),
          provider_contract_fingerprint: String.t(),
          submitted_at: DateTime.t(),
          operation: :lifecycle_transition
        }

  @spec new(TransitionAttempt.t(), map()) :: {:ok, t()} | {:error, atom()}
  def new(attempt, context), do: new(attempt, context, [])

  @spec new(TransitionAttempt.t(), map(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(%TransitionAttempt{} = attempt, context, opts) when is_map(context) and is_list(opts) do
    request_id = Keyword.get(opts, :provider_request_id) || generated_request_id()
    submitted_at = Keyword.get(opts, :submitted_at, DateTime.utc_now())

    with :ok <- prepared_and_fenced(attempt),
         :ok <- valid_request_id(request_id),
         :ok <- validate_binding(attempt, context),
         true <- match?(%DateTime{}, submitted_at) do
      envelope = %__MODULE__{
        provider_request_id: request_id,
        transition_attempt_id: attempt.transition_attempt_id,
        work_item_id: attempt.work_item_id,
        provider: attempt.provider,
        workspace_id: attempt.workspace_id,
        project_id: attempt.project_id,
        requested_from: attempt.requested_from,
        requested_to: attempt.requested_to,
        target_provider_state_id: attempt.target_provider_state_id,
        target_provider_state_group: attempt.target_provider_state_group,
        provider_contract_fingerprint: attempt.provider_contract_fingerprint,
        submitted_at: submitted_at
      }

      if valid?(envelope), do: {:ok, envelope}, else: {:error, :invalid_provider_mutation_envelope}
    else
      false -> {:error, :invalid_submitted_at}
      {:error, _reason} = error -> error
    end
  end

  def new(_attempt, _context, _opts), do: {:error, :invalid_provider_mutation_envelope}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = envelope), do: valid_envelope?(envelope)
  def valid?(_envelope), do: false

  defp valid_envelope?(envelope) do
    envelope.schema_version == 1 and
      envelope.operation == :lifecycle_transition and
      valid_correlation?(envelope) and
      valid_scope?(envelope) and
      valid_transition?(envelope) and
      valid_target?(envelope) and
      match?(%DateTime{}, envelope.submitted_at)
  end

  defp valid_correlation?(envelope) do
    TransitionAttempt.valid_provider_request_id?(envelope.provider_request_id) and
      valid_text?(envelope.transition_attempt_id) and
      valid_text?(envelope.work_item_id)
  end

  defp valid_scope?(envelope) do
    is_atom(envelope.provider) and
      valid_text?(envelope.workspace_id) and
      valid_text?(envelope.project_id) and
      valid_text?(envelope.provider_contract_fingerprint)
  end

  defp valid_transition?(envelope),
    do: is_atom(envelope.requested_from) and is_atom(envelope.requested_to)

  defp valid_target?(envelope) do
    valid_text?(envelope.target_provider_state_id) and is_atom(envelope.target_provider_state_group)
  end

  @spec matches?(t(), String.t(), atom(), ProviderProjectContract.t()) :: boolean()
  def matches?(%__MODULE__{} = envelope, work_item_id, requested_to, %ProviderProjectContract{} = contract) do
    valid?(envelope) and matches_identity?(envelope, work_item_id, requested_to, contract) and
      matches_target?(envelope, requested_to, contract)
  end

  def matches?(_envelope, _work_item_id, _requested_to, _contract), do: false

  defp matches_identity?(envelope, work_item_id, requested_to, contract) do
    envelope.work_item_id == work_item_id and
      envelope.requested_to == requested_to and
      envelope.provider == contract.provider and
      envelope.workspace_id == contract.workspace_id and
      envelope.project_id == contract.project_id and
      envelope.provider_contract_fingerprint == ProviderProjectContract.fingerprint(contract)
  end

  defp matches_target?(envelope, requested_to, contract) do
    case ProviderProjectContract.provider_mapping_for(contract, requested_to) do
      {:ok, mapping} ->
        envelope.target_provider_state_id == mapping.state_id and
          envelope.target_provider_state_group == mapping.group

      _error ->
        false
    end
  end

  defp prepared_and_fenced(%TransitionAttempt{state: :prepared} = attempt) do
    cond do
      is_nil(attempt.submission_fenced_at) -> {:error, :submission_not_fenced}
      not is_nil(Map.get(attempt, :provider_request_id)) -> {:error, :provider_request_id_already_bound}
      true -> :ok
    end
  end

  defp prepared_and_fenced(%TransitionAttempt{}), do: {:error, :attempt_not_prepared}

  defp valid_request_id(value) do
    if TransitionAttempt.valid_provider_request_id?(value), do: :ok, else: {:error, :invalid_provider_request_id}
  end

  defp validate_binding(attempt, context) do
    contract = Map.get(context, :provider_project_contract) || Map.get(context, :contract)
    context_work_item_id = Map.get(context, :work_item_id) || context_work_item_id(context)

    with %ProviderProjectContract{} = contract <- contract,
         true <- is_nil(context_work_item_id) or context_work_item_id == attempt.work_item_id,
         true <- attempt.provider == contract.provider,
         true <- attempt.workspace_id == contract.workspace_id,
         true <- attempt.project_id == contract.project_id,
         true <- attempt.provider_contract_fingerprint == ProviderProjectContract.fingerprint(contract),
         true <- Map.get(context, :workspace_id) == attempt.workspace_id,
         true <- Map.get(context, :project_id) == attempt.project_id,
         true <- Map.get(context, :provider_contract_fingerprint) == attempt.provider_contract_fingerprint,
         true <- Map.get(context, :target_provider_state_id) == attempt.target_provider_state_id,
         true <- Map.get(context, :target_provider_state_group) == attempt.target_provider_state_group,
         {:ok, mapping} <- ProviderProjectContract.provider_mapping_for(contract, attempt.requested_to),
         true <- mapping.state_id == attempt.target_provider_state_id,
         true <- mapping.group == attempt.target_provider_state_group do
      :ok
    else
      false -> {:error, :provider_mutation_binding_mismatch}
      nil -> {:error, :provider_project_contract_required}
      {:error, _reason} -> {:error, :provider_mutation_binding_mismatch}
      _invalid -> {:error, :provider_project_contract_required}
    end
  end

  defp context_work_item_id(%{work_item: %{id: id}}), do: id
  defp context_work_item_id(%{work_item: %{work_item_id: id}}), do: id
  defp context_work_item_id(_context), do: nil

  defp valid_text?(value), do: is_binary(value) and String.trim(value) != ""

  defp generated_request_id, do: "preq_" <> Ecto.UUID.generate()
end
