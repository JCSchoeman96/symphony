defmodule SymphonyElixir.WorkControl.TransitionAttempt do
  @moduledoc """
  Durable state law for one provider lifecycle mutation attempt.

  `:prepared` is the last state in which a mutation may be emitted. The
  `:mutation_submitted` state is a write-ahead no-resubmit fence and must be
  synced before the provider request starts.
  """

  alias SymphonyElixir.WorkControl.{GuardClass, SemanticTransitionIntent, WorkflowLifecycle}

  @schema_version 1
  @states [:requested, :intent_authorized, :fresh_context_loaded, :prepared, :mutation_submitted, :verifying, :verified, :rejected, :conflict, :provider_failed, :indeterminate]
  @terminal_states [:verified, :rejected, :conflict, :provider_failed, :indeterminate]

  defstruct [
    :schema_version,
    :attempt_id,
    :transition_attempt_id,
    :work_item_id,
    :provider,
    :workspace_id,
    :project_id,
    :requested_from,
    :requested_to,
    :responsibility,
    :guard_evidence,
    :transition_identity,
    :runtime_attempt_id,
    :lineage_id,
    :lineage_generation,
    :target_provider_state_id,
    :target_provider_state_group,
    :provider_contract_fingerprint,
    :post_contract_fingerprint,
    :pre_observation_evidence,
    :post_observation_evidence,
    :pre_assessment_evidence,
    :post_assessment_evidence,
    :dependency_epoch_evidence,
    :provider_ack_status,
    :outcome_reason,
    :created_at,
    :updated_at,
    :requested_at,
    :intent_authorized_at,
    :fresh_context_loaded_at,
    :prepared_at,
    :submission_fenced_at,
    :submitted_at,
    :verifying_at,
    :verified_at,
    :terminal_at,
    state: :requested,
    status: :requested
  ]

  @type state :: unquote(Enum.reduce(@states, &{:|, [], [&1, &2]}))
  @type t :: %__MODULE__{state: state(), status: state() | :submitted}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    attempt_id = Map.get(attrs, :attempt_id) || Map.get(attrs, :transition_attempt_id) || new_id()
    transition_attempt_id = Map.get(attrs, :transition_attempt_id, attempt_id)

    with :ok <- validate_keys(attrs),
         :ok <- validate_id(attempt_id, :attempt_id),
         :ok <- validate_id(transition_attempt_id, :transition_attempt_id),
         :ok <- validate_id(Map.get(attrs, :work_item_id), :work_item_id),
         {:ok, source} <- canonical_atom(Map.get(attrs, :requested_from)),
         {:ok, target} <- canonical_atom(Map.get(attrs, :requested_to)),
         :ok <- validate_transition(source, target),
         {:ok, responsibility} <- validate_responsibility(Map.get(attrs, :responsibility)),
         :ok <- validate_guard_evidence(Map.get(attrs, :guard_evidence, [])),
         {:ok, requested_at} <- timestamp(Map.get(attrs, :requested_at, DateTime.utc_now())) do
      {:ok,
       struct(
         __MODULE__,
         attrs
         |> Map.take(struct_keys())
         |> Map.merge(%{
           schema_version: @schema_version,
           attempt_id: attempt_id,
           transition_attempt_id: transition_attempt_id,
           work_item_id: String.trim(attrs.work_item_id),
           requested_from: source,
           requested_to: target,
           responsibility: responsibility,
           created_at: requested_at,
           updated_at: requested_at,
           requested_at: requested_at,
           state: :requested,
           status: :requested
         })
       )}
    end
  end

  def new(_attrs), do: {:error, :invalid_attempt}

  @spec authorize_intent(t(), SemanticTransitionIntent.t() | map()) :: {:ok, t()} | {:error, atom()}
  def authorize_intent(%__MODULE__{} = attempt, %SemanticTransitionIntent{} = intent) do
    with :ok <- available?(attempt),
         true <- attempt.work_item_id == intent.work_item_id,
         true <- attempt.requested_from == intent.requested_from,
         true <- attempt.requested_to == intent.requested_to do
      {:ok, advance(attempt, :intent_authorized, %{intent_authorized_at: DateTime.utc_now()})}
    else
      false -> {:error, :intent_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def authorize_intent(%__MODULE__{} = attempt, attrs) when is_map(attrs) do
    case SemanticTransitionIntent.new(attrs) do
      {:ok, intent} -> authorize_intent(attempt, intent)
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_intent(%__MODULE__{}, _intent) do
    {:error, :invalid_intent}
  end

  @spec fresh_context_loaded(t(), map()) :: {:ok, t()} | {:error, atom()}
  def fresh_context_loaded(%__MODULE__{} = attempt, context) when is_map(context) do
    transition_from(attempt, :intent_authorized, :fresh_context_loaded, context, :fresh_context_loaded_at)
  end

  @spec prepare(t(), map()) :: {:ok, t()} | {:error, atom()}
  def prepare(%__MODULE__{} = attempt, context) when is_map(context) do
    transition_from(attempt, :fresh_context_loaded, :prepared, context, :prepared_at)
  end

  @spec mark_mutation_submitted(t(), map()) :: {:ok, t()} | {:error, atom()}
  def mark_mutation_submitted(%__MODULE__{} = attempt, opts \\ %{}) when is_map(opts) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, :prepared) do
      at = Map.get(opts, :at, DateTime.utc_now())
      submitted_at = Map.get(opts, :submitted_at, at)

      with {:ok, at} <- timestamp(at),
           {:ok, submitted_at} <- timestamp(submitted_at) do
        {:ok,
         advance(attempt, :mutation_submitted, %{
           status: :submitted,
           submission_fenced_at: at,
           submitted_at: submitted_at
         })}
      end
    end
  end

  @spec begin_verification(t(), map()) :: {:ok, t()} | {:error, atom()}
  def begin_verification(%__MODULE__{} = attempt, opts \\ %{}) when is_map(opts) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, :mutation_submitted) do
      at = Map.get(opts, :at, DateTime.utc_now())

      with {:ok, at} <- timestamp(at) do
        updates =
          %{verifying_at: at}
          |> maybe_put(:provider_ack_status, Map.get(opts, :provider_ack_status))

        {:ok, advance(attempt, :verifying, updates)}
      end
    end
  end

  @spec verify(t(), map() | atom()) :: {:ok, t()} | {:error, atom()}
  def verify(%__MODULE__{} = attempt, context) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, :verifying) do
      outcome = verification_outcome(context, attempt)
      {:ok, terminal_update(attempt, outcome, context)}
    end
  end

  @spec reject(t(), map() | atom()) :: {:ok, t()} | {:error, atom()}
  def reject(%__MODULE__{} = attempt, reason), do: terminalize(attempt, :rejected, reason)

  @spec conflict(t(), map() | atom()) :: {:ok, t()} | {:error, atom()}
  def conflict(%__MODULE__{} = attempt, reason), do: terminalize(attempt, :conflict, reason)

  @spec provider_failed(t(), map() | atom()) :: {:ok, t()} | {:error, atom()}
  def provider_failed(%__MODULE__{} = attempt, reason), do: terminalize(attempt, :provider_failed, reason)

  @spec indeterminate(t(), map() | atom()) :: {:ok, t()} | {:error, atom()}
  def indeterminate(%__MODULE__{} = attempt, reason), do: terminalize(attempt, :indeterminate, reason)

  @spec terminal?(t() | map()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states
  def terminal?(%{status: status}), do: status in @terminal_states
  def terminal?(_attempt), do: false

  @spec submission_fenced?(t() | map()) :: boolean()
  def submission_fenced?(%__MODULE__{} = attempt) do
    attempt.state in [:mutation_submitted, :verifying, :conflict, :provider_failed, :indeterminate, :verified] or
      not is_nil(attempt.submission_fenced_at)
  end

  def submission_fenced?(attempt) when is_map(attempt) do
    status = Map.get(attempt, :status) || Map.get(attempt, :state)

    status in [:submitted, :mutation_submitted, :verifying, :verified, :conflict, :provider_failed, :indeterminate] or
      not is_nil(Map.get(attempt, :submission_fenced_at))
  end

  def submission_fenced?(_attempt), do: false

  @spec automatic_mutation_allowed?(t() | map()) :: boolean()
  def automatic_mutation_allowed?(%__MODULE__{state: :prepared}), do: true
  def automatic_mutation_allowed?(%{state: :prepared}), do: true
  def automatic_mutation_allowed?(%{status: :prepared}), do: true
  def automatic_mutation_allowed?(_attempt), do: false

  defp transition_from(attempt, expected, next, context, timestamp_key) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, expected) do
      at = Map.get(context, :at, DateTime.utc_now())

      with {:ok, at} <- timestamp(at) do
        updates =
          context
          |> Map.take([
            :provider,
            :workspace_id,
            :project_id,
            :target_provider_state_id,
            :target_provider_state_group,
            :provider_contract_fingerprint,
            :post_contract_fingerprint,
            :provider_ack_status,
            :dependency_epoch_evidence,
            :pre_observation_evidence,
            :post_observation_evidence,
            :pre_assessment_evidence,
            :post_assessment_evidence,
            :guard_evidence,
            :transition_identity
          ])
          |> Map.merge(non_nil_context_values(context, [:runtime_attempt_id, :lineage_id, :lineage_generation]))
          |> Map.put(timestamp_key, at)

        {:ok, advance(attempt, next, updates)}
      end
    end
  end

  defp terminalize(attempt, state, reason) do
    with :ok <- available?(attempt) do
      {:ok, terminal_update(attempt, state, %{reason: reason})}
    end
  end

  defp terminal_update(attempt, state, context) do
    now = Map.get(context, :at, DateTime.utc_now())
    reason = Map.get(context, :reason, Map.get(context, "reason"))

    advance(attempt, state, %{
      status: status_for(state),
      outcome_reason: reason,
      terminal_at: now,
      verified_at: if(state == :verified, do: now, else: attempt.verified_at),
      post_observation_evidence: Map.get(context, :post_observation_evidence, attempt.post_observation_evidence),
      post_contract_fingerprint: Map.get(context, :post_contract_fingerprint, attempt.post_contract_fingerprint),
      post_assessment_evidence: Map.get(context, :assessment, Map.get(context, :post_assessment_evidence, attempt.post_assessment_evidence))
    })
  end

  defp verification_outcome(:verified, _attempt), do: :verified
  defp verification_outcome({:verified, _reason}, _attempt), do: :verified
  defp verification_outcome(%{assessment: assessment}, attempt), do: verification_outcome(assessment, attempt)
  defp verification_outcome(%{status: :validated, validated_state: state}, %{requested_to: target}) when state == target, do: :verified
  defp verification_outcome(%{status: :verified}, _attempt), do: :verified
  defp verification_outcome(%{status: :conflict}, _attempt), do: :conflict
  defp verification_outcome(%{status: :provider_failed}, _attempt), do: :provider_failed
  defp verification_outcome(_, _attempt), do: :indeterminate

  defp status_for(:mutation_submitted), do: :submitted
  defp status_for(state), do: state

  defp advance(attempt, state, updates) do
    updated_at =
      Map.get(updates, :updated_at) ||
        Enum.find_value(
          [:terminal_at, :verifying_at, :submitted_at, :submission_fenced_at, :prepared_at, :fresh_context_loaded_at, :intent_authorized_at],
          &Map.get(updates, &1)
        ) || DateTime.utc_now()

    struct!(attempt, Map.merge(updates, %{state: state, status: status_for(state), updated_at: updated_at}))
  end

  defp available?(%__MODULE__{state: state}) when state in @terminal_states, do: {:error, :terminal_attempt}
  defp available?(%__MODULE__{}), do: :ok

  defp require_state(%__MODULE__{state: state}, state), do: :ok
  defp require_state(%__MODULE__{state: :requested}, :intent_authorized), do: {:error, :intent_not_authorized}
  defp require_state(%__MODULE__{state: actual}, expected), do: {:error, {:invalid_attempt_state, actual, expected}}

  defp canonical_atom(value) when is_atom(value) do
    if WorkflowLifecycle.canonical?(value), do: {:ok, value}, else: {:error, :invalid_state}
  end

  defp canonical_atom(_value), do: {:error, :invalid_state}

  defp validate_transition(source, target) do
    if WorkflowLifecycle.valid_transition?(source, target), do: :ok, else: {:error, :invalid_transition}
  end

  defp validate_id(value, _field) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp validate_id(_value, field), do: {:error, {:missing, field}}

  defp validate_keys(attrs) do
    allowed = Map.keys(%__MODULE__{}) -- [:__struct__]

    if Enum.all?(Map.keys(attrs), &(&1 in allowed)), do: :ok, else: {:error, :invalid_attempt_field}
  end

  defp validate_responsibility(value) when is_atom(value) and not is_nil(value), do: {:ok, Atom.to_string(value)}
  defp validate_responsibility(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, String.trim(value)}
  defp validate_responsibility(_value), do: {:error, :missing_responsibility}

  defp validate_guard_evidence(evidence) when is_map(evidence), do: validate_guard_evidence([evidence])

  defp validate_guard_evidence(evidence) when is_list(evidence) do
    if Enum.all?(evidence, &GuardClass.valid_evidence?/1), do: :ok, else: {:error, :invalid_guard_evidence}
  end

  defp validate_guard_evidence(_evidence), do: {:error, :invalid_guard_evidence}

  defp timestamp(%DateTime{} = value), do: {:ok, value}
  defp timestamp(_value), do: {:error, :invalid_timestamp}

  defp struct_keys, do: Map.keys(%__MODULE__{})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp non_nil_context_values(context, keys) do
    context
    |> Map.take(keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp new_id, do: "transition-" <> Integer.to_string(System.unique_integer([:positive]))
end
