defmodule SymphonyElixir.WorkControl.ProviderDispatchWitness do
  @moduledoc """
  Bounded evidence that one correlated provider request is entering its
  transport handoff.

  The witness acknowledges an application request object. It does not prove
  that network bytes were sent or that the provider received the mutation.
  """

  alias SymphonyElixir.WorkControl.{ProviderMutationEnvelope, TransitionAttempt}

  @default_sink_timeout_ms 1_000
  @max_sink_timeout_ms 5_000

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

  @spec dispatch(
          ProviderMutationEnvelope.t(),
          Finch.Request.t(),
          term(),
          boolean(),
          (Finch.Request.t() -> term())
        ) :: term()
  def dispatch(%ProviderMutationEnvelope{} = envelope, %Finch.Request{} = request, sink, required?, transport_fun)
      when is_boolean(required?) and is_function(transport_fun, 1) do
    dispatch(envelope, request, sink, required?, transport_fun, default_timeout_ms())
  end

  def dispatch(_envelope, _request, _sink, _required?, _transport_fun),
    do: {:error, {:dispatch_witness_failed, :invalid_dispatch_request}}

  @spec dispatch(
          ProviderMutationEnvelope.t(),
          Finch.Request.t(),
          term(),
          boolean(),
          (Finch.Request.t() -> term()),
          term()
        ) :: term()
  def dispatch(%ProviderMutationEnvelope{} = envelope, %Finch.Request{} = request, sink, required?, transport_fun, timeout_ms)
      when is_boolean(required?) and is_function(transport_fun, 1) do
    if valid_timeout?(timeout_ms) do
      do_dispatch(envelope, request, sink, required?, transport_fun, timeout_ms)
    else
      {:error, {:dispatch_witness_failed, :invalid_sink_timeout}}
    end
  end

  def dispatch(_envelope, _request, _sink, _required?, _transport_fun, _timeout_ms),
    do: {:error, {:dispatch_witness_failed, :invalid_dispatch_request}}

  defp do_dispatch(envelope, request, sink, required?, transport_fun, timeout_ms) do
    with :ok <- request_identity_matches(envelope, request),
         {:ok, witness} <- new(envelope, DateTime.utc_now()),
         :ok <- acknowledge(sink, witness, required?, timeout_ms) do
      invoke_transport(transport_fun, request)
    else
      {:error, reason} -> {:error, {:dispatch_witness_failed, reason}}
    end
  end

  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_sink_timeout_ms

  @spec valid_timeout?(term()) :: boolean()
  def valid_timeout?(timeout_ms),
    do: is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= @max_sink_timeout_ms

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

  defp acknowledge(nil, _witness, false, _timeout_ms), do: :ok
  defp acknowledge(nil, _witness, true, _timeout_ms), do: {:error, :sink_unavailable}

  defp acknowledge(sink, witness, _required?, timeout_ms) when is_function(sink, 1) do
    case invoke_sink(sink, witness, timeout_ms) do
      {:ok, {:ok, request_id}} when request_id == witness.provider_request_id -> :ok
      {:ok, {:ok, _request_id}} -> {:error, :acknowledgment_mismatch}
      {:ok, {:error, _reason}} -> {:error, :sink_rejected}
      {:ok, _other} -> {:error, :invalid_acknowledgment}
      {:error, :sink_timeout} -> {:error, :sink_timeout}
      {:error, _reason} -> {:error, :sink_rejected}
    end
  end

  defp acknowledge(_sink, _witness, true, _timeout_ms), do: {:error, :sink_invalid}
  defp acknowledge(_sink, _witness, false, _timeout_ms), do: {:error, :sink_invalid}

  defp invoke_sink(sink, witness, timeout_ms) do
    caller = self()
    reply_ref = make_ref()

    {controller, monitor_ref} =
      spawn_monitor(fn -> run_sink_controller(caller, reply_ref, sink, witness, timeout_ms) end)

    receive do
      {^reply_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^controller, _reason} ->
        {:error, :sink_rejected}
    end
  end

  defp run_sink_controller(caller, reply_ref, sink, witness, timeout_ms) do
    controller = self()
    caller_monitor = Process.monitor(caller)

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn -> send(controller, {:sink_result, invoke_sink_callback(sink, witness)}) end,
        [:link, :monitor]
      )

    receive do
      {:sink_result, result} ->
        Process.unlink(worker)
        await_worker_exit(worker, worker_monitor)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reply_ref, {:ok, result}})

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reply_ref, {:error, :sink_rejected}})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        stop_sink_worker(worker, worker_monitor)
    after
      timeout_ms ->
        stop_sink_worker(worker, worker_monitor)
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reply_ref, {:error, :sink_timeout}})
    end
  end

  defp invoke_sink_callback(sink, witness) do
    sink.(witness)
  rescue
    _error -> {:error, :sink_exception}
  catch
    _kind, _reason -> {:error, :sink_exception}
  end

  defp stop_sink_worker(worker, worker_monitor) do
    Process.unlink(worker)
    Process.exit(worker, :kill)
    await_worker_exit(worker, worker_monitor)
  end

  defp await_worker_exit(worker, worker_monitor) do
    receive do
      {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
    end
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
