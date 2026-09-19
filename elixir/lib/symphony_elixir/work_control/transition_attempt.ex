defmodule SymphonyElixir.WorkControl.TransitionAttempt do
  @moduledoc """
  Durable state law for one provider lifecycle mutation attempt.

  `:prepared` is the last state in which a mutation may be emitted. The
  `:mutation_submitted` state is a write-ahead no-resubmit fence and must be
  synced before the provider request starts.
  """

  alias SymphonyElixir.WorkControl.{GuardClass, SemanticTransitionIntent, WorkflowLifecycle}

  @schema_version 1
  @states [
    :requested,
    :intent_authorized,
    :fresh_context_loaded,
    :prepared,
    :mutation_submitted,
    :verifying,
    :verified,
    :rejected,
    :conflict,
    :provider_failed,
    :indeterminate
  ]
  @terminal_states [:verified, :rejected, :conflict, :provider_failed, :indeterminate]
  @assessment_statuses [
    :unassessed,
    :mapping_resolved,
    :validated,
    :authority_reducing,
    :validation_required,
    :invalid,
    :conflict,
    :provider_failed
  ]

  # credo:disable-for-next-line
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
         :ok <- require_state(attempt, :requested),
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

  @spec arm_submission_fence(t(), map()) :: {:ok, t()} | {:error, atom()}
  def arm_submission_fence(%__MODULE__{} = attempt, opts \\ %{}) when is_map(opts) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, :prepared) do
      at = Map.get(opts, :at, DateTime.utc_now())

      with {:ok, at} <- timestamp(at) do
        {:ok, advance(attempt, :prepared, %{submission_fenced_at: at})}
      end
    end
  end

  @spec mark_mutation_submitted(t(), map()) :: {:ok, t()} | {:error, atom()}
  def mark_mutation_submitted(%__MODULE__{} = attempt, opts \\ %{}) when is_map(opts) do
    with :ok <- available?(attempt),
         :ok <- require_state(attempt, :prepared),
         true <- submission_fenced?(attempt) do
      at = Map.get(opts, :at, DateTime.utc_now())

      with {:ok, at} <- timestamp(at) do
        {:ok,
         advance(attempt, :mutation_submitted, %{
           status: :submitted,
           submitted_at: at
         })}
      end
    else
      false -> {:error, :submission_not_fenced}
      {:error, _reason} = error -> error
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
         :ok <- require_state(attempt, :verifying),
         {:ok, outcome} <- verification_outcome(context, attempt) do
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
  def automatic_mutation_allowed?(%__MODULE__{state: :prepared} = attempt),
    do: is_nil(attempt.submission_fenced_at)

  def automatic_mutation_allowed?(%{state: :prepared} = attempt),
    do: is_nil(Map.get(attempt, :submission_fenced_at))

  def automatic_mutation_allowed?(%{status: :prepared} = attempt),
    do: is_nil(Map.get(attempt, :submission_fenced_at))

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
    with :ok <- available?(attempt),
         :ok <- terminal_source_allowed?(attempt.state, state),
         :ok <- terminal_reason_allowed?(attempt, state, reason) do
      {:ok, terminal_update(attempt, state, %{reason: reason})}
    end
  end

  defp terminal_update(attempt, state, context) do
    context = if is_map(context), do: context, else: %{reason: context}
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

  defp verification_outcome(context, attempt) do
    if is_map(context) do
      assessment = Map.get(context, :assessment)
      observation = Map.get(context, :post_observation_evidence)
      fingerprint = Map.get(context, :post_contract_fingerprint)

      if is_map(assessment) and is_map(observation) and is_binary(fingerprint) do
        verification_outcome(context, attempt, assessment, observation, fingerprint)
      else
        {:error, :invalid_verification_evidence}
      end
    else
      {:error, :invalid_verification_evidence}
    end
  end

  defp verification_outcome(context, attempt, assessment, observation, fingerprint) do
    with true <- valid_assessment?(assessment, attempt),
         true <- valid_post_observation?(observation, attempt),
         true <- fingerprint == attempt.provider_contract_fingerprint,
         outcome <- Map.get(context, :outcome) || inferred_outcome(assessment, observation, context, attempt),
         true <- valid_outcome?(outcome, assessment, observation, context, attempt) do
      {:ok, outcome}
    else
      _ -> {:error, :invalid_verification_evidence}
    end
  end

  defp valid_post_observation?(observation, %__MODULE__{} = attempt) when is_map(observation) do
    is_binary(attempt.workspace_id) and
      is_binary(attempt.project_id) and
      is_binary(attempt.provider_contract_fingerprint) and
      Map.get(observation, :workspace_id) == attempt.workspace_id and
      Map.get(observation, :project_id) == attempt.project_id and
      Map.get(observation, :work_item_id) == attempt.work_item_id and
      is_binary(Map.get(observation, :provider_state_id)) and
      match?(%DateTime{}, Map.get(observation, :observed_at))
  end

  defp valid_assessment?(assessment, %__MODULE__{} = attempt) when is_map(assessment) do
    status = Map.get(assessment, :status)
    work_item_id = Map.get(assessment, :work_item_id)
    mapped_state = Map.get(assessment, :mapped_state)
    validated_state = Map.get(assessment, :validated_state)

    status in @assessment_statuses and
      (is_nil(work_item_id) or work_item_id == attempt.work_item_id) and
      (is_nil(mapped_state) or WorkflowLifecycle.canonical?(mapped_state)) and
      (is_nil(validated_state) or WorkflowLifecycle.canonical?(validated_state))
  end

  defp valid_assessment?(_assessment, _attempt), do: false

  defp inferred_outcome(assessment, observation, context, attempt) do
    cond do
      Map.get(assessment, :status) == :validated and
        Map.get(assessment, :validated_state) == attempt.requested_to and
          Map.get(observation, :provider_state_id) == attempt.target_provider_state_id ->
        :verified

      Map.get(assessment, :status) == :provider_failed and non_commit?(context) ->
        :provider_failed

      Map.get(assessment, :status) == :conflict and incompatible_assessment?(assessment, attempt) ->
        :conflict

      true ->
        :indeterminate
    end
  end

  defp valid_outcome?(:verified, assessment, observation, _context, attempt) do
    Map.get(assessment, :status) == :validated and
      Map.get(assessment, :validated_state) == attempt.requested_to and
      Map.get(observation, :provider_state_id) == attempt.target_provider_state_id
  end

  defp valid_outcome?(:conflict, assessment, _observation, context, attempt) do
    (Map.get(context, :authoritative_conflict?, false) or
       Map.get(context, :non_commit?, Map.get(context, :non_commit, false)) or
       Map.get(assessment, :status) == :conflict) and
      incompatible_assessment?(assessment, attempt)
  end

  defp valid_outcome?(:provider_failed, assessment, _observation, context, attempt) do
    non_commit?(context) and
      (Map.get(assessment, :status) == :provider_failed or
         (Map.get(assessment, :status) == :validated and
            Map.get(assessment, :validated_state) == attempt.requested_from) or
         Map.get(assessment, :status) in [:invalid, :validation_required])
  end

  defp valid_outcome?(:indeterminate, _assessment, _observation, _context, _attempt), do: true
  defp valid_outcome?(_outcome, _assessment, _observation, _context, _attempt), do: false

  defp incompatible_assessment?(assessment, attempt) do
    mapped_state = Map.get(assessment, :mapped_state) || Map.get(assessment, :validated_state)

    WorkflowLifecycle.canonical?(mapped_state) and
      mapped_state not in [attempt.requested_from, attempt.requested_to]
  end

  defp non_commit?(context) do
    Map.get(context, :non_commit?, Map.get(context, :non_commit, false)) == true
  end

  defp status_for(:mutation_submitted), do: :submitted
  defp status_for(state), do: state

  defp advance(attempt, state, updates) do
    updated_at =
      Map.get(updates, :updated_at) ||
        Enum.find_value(
          [
            :terminal_at,
            :verifying_at,
            :submitted_at,
            :submission_fenced_at,
            :prepared_at,
            :fresh_context_loaded_at,
            :intent_authorized_at
          ],
          &Map.get(updates, &1)
        ) || DateTime.utc_now()

    struct!(attempt, Map.merge(updates, %{state: state, status: status_for(state), updated_at: updated_at}))
  end

  defp available?(%__MODULE__{state: state}) when state in @terminal_states, do: {:error, :terminal_attempt}
  defp available?(%__MODULE__{}), do: :ok

  defp require_state(%__MODULE__{state: state}, state), do: :ok
  defp require_state(%__MODULE__{state: actual}, expected), do: {:error, {:invalid_attempt_state, actual, expected}}

  defp terminal_source_allowed?(:requested, :rejected), do: :ok

  defp terminal_source_allowed?(source, target)
       when source in [:intent_authorized, :fresh_context_loaded, :prepared] and
              target in [:rejected, :conflict, :provider_failed],
       do: :ok

  defp terminal_source_allowed?(source, target)
       when source in [:mutation_submitted, :verifying] and
              target in [:conflict, :provider_failed, :indeterminate],
       do: :ok

  defp terminal_source_allowed?(source, _target),
    do: {:error, {:invalid_attempt_state, source, :terminal}}

  defp terminal_reason_allowed?(%__MODULE__{state: state}, _target, _reason)
       when state in [:requested, :intent_authorized, :fresh_context_loaded, :prepared],
       do: :ok

  defp terminal_reason_allowed?(%__MODULE__{} = attempt, target, reason) do
    evidence = if is_map(reason), do: Map.put(reason, :outcome, target), else: reason

    case verification_outcome(evidence, attempt) do
      {:ok, ^target} -> :ok
      _ -> {:error, :invalid_verification_evidence}
    end
  end

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
