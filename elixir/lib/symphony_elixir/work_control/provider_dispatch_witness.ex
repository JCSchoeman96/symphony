defmodule SymphonyElixir.WorkControl.ProviderDispatchWitness do
  @moduledoc """
  Safe, synchronous evidence that one correlated provider request is entering
  its transport handoff.

  The witness acknowledges an application request object. It does not prove
  that network bytes were sent or that the provider received the mutation.
  """

  alias SymphonyElixir.WorkControl.{ProviderMutationEnvelope, TransitionAttempt}

  defmodule DispatchError do
    @moduledoc false
    defexception [:reason]

    @impl true
    def message(_error), do: "provider dispatch witness failed"
  end

  @private_request_id_key :symphony_provider_request_id
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
    :provider_contract_fingerprint,
    :dispatch_observed_at
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
    :provider_contract_fingerprint,
    :dispatch_observed_at,
    schema_version: 1
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
          provider_contract_fingerprint: String.t(),
          dispatch_observed_at: DateTime.t()
        }

  @spec new(ProviderMutationEnvelope.t(), DateTime.t()) :: {:ok, t()} | {:error, atom()}
  def new(%ProviderMutationEnvelope{} = envelope, %DateTime{} = observed_at) do
    if ProviderMutationEnvelope.valid?(envelope) do
      {:ok,
       %__MODULE__{
         provider_request_id: envelope.provider_request_id,
         transition_attempt_id: envelope.transition_attempt_id,
         work_item_id: envelope.work_item_id,
         provider: envelope.provider,
         workspace_id: envelope.workspace_id,
         project_id: envelope.project_id,
         requested_from: envelope.requested_from,
         requested_to: envelope.requested_to,
         target_provider_state_id: envelope.target_provider_state_id,
         provider_contract_fingerprint: envelope.provider_contract_fingerprint,
         dispatch_observed_at: observed_at
       }}
    else
      {:error, :invalid_provider_mutation_envelope}
    end
  end

  def new(_envelope, _observed_at), do: {:error, :invalid_provider_dispatch_witness}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = witness), do: valid_witness?(witness)
  def valid?(_witness), do: false

  defp valid_witness?(witness) do
    witness.schema_version == 1 and
      valid_correlation?(witness) and
      valid_scope?(witness) and
      valid_transition?(witness) and
      valid_target?(witness) and
      match?(%DateTime{}, witness.dispatch_observed_at)
  end

  defp valid_correlation?(witness) do
    TransitionAttempt.valid_provider_request_id?(witness.provider_request_id) and
      non_empty?(witness.transition_attempt_id) and
      non_empty?(witness.work_item_id)
  end

  defp valid_scope?(witness) do
    is_atom(witness.provider) and
      non_empty?(witness.workspace_id) and
      non_empty?(witness.project_id) and
      non_empty?(witness.provider_contract_fingerprint)
  end

  defp valid_transition?(witness), do: is_atom(witness.requested_from) and is_atom(witness.requested_to)

  defp valid_target?(witness), do: non_empty?(witness.target_provider_state_id)

  @spec dispatch(ProviderMutationEnvelope.t(), Finch.Request.t(), term(), boolean(), (Finch.Request.t() -> term())) ::
          term()
  def dispatch(%ProviderMutationEnvelope{} = envelope, %Finch.Request{} = request, sink, required?, transport_fun)
      when is_boolean(required?) and is_function(transport_fun, 1) do
    with :ok <- request_identity_matches(envelope, request),
         {:ok, witness} <- new(envelope, DateTime.utc_now()),
         :ok <- acknowledge(sink, witness, required?) do
      invoke_transport(transport_fun, request)
    else
      {:error, reason} -> {:error, {:dispatch_witness_failed, reason}}
    end
  end

  def dispatch(_envelope, _request, _sink, _required?, _transport_fun),
    do: {:error, {:dispatch_witness_failed, :invalid_dispatch_request}}

  @spec private_request_id_key() :: atom()
  def private_request_id_key, do: @private_request_id_key

  defp request_identity_matches(envelope, request) do
    if ProviderMutationEnvelope.valid?(envelope) and
         Map.get(request.private, @private_request_id_key) == envelope.provider_request_id do
      :ok
    else
      {:error, :request_identity_mismatch}
    end
  end

  defp acknowledge(nil, _witness, false), do: :ok
  defp acknowledge(nil, _witness, true), do: {:error, :sink_unavailable}

  defp acknowledge(sink, witness, _required?) when is_function(sink, 1) do
    case invoke_sink(sink, witness) do
      {:ok, request_id} when request_id == witness.provider_request_id -> :ok
      {:ok, _request_id} -> {:error, :acknowledgment_mismatch}
      {:error, _reason} -> {:error, :sink_rejected}
      _other -> {:error, :invalid_acknowledgment}
    end
  end

  defp acknowledge(_sink, _witness, true), do: {:error, :sink_invalid}
  defp acknowledge(_sink, _witness, false), do: {:error, :sink_invalid}

  defp invoke_sink(sink, witness) do
    sink.(witness)
  rescue
    _error -> {:error, :sink_exception}
  catch
    _kind, _reason -> {:error, :sink_exception}
  end

  defp invoke_transport(transport_fun, request) do
    transport_fun.(request)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp non_empty?(value), do: is_binary(value) and String.trim(value) != ""
end
