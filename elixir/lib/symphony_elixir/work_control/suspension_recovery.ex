defmodule SymphonyElixir.WorkControl.SuspensionRecovery do
  @moduledoc """
  Pure reason-specific policy for recovering a suspended work item.

  `classify_reason/1` maps a suspension reason to the recovery rule that owns
  it. `evaluate/2` then checks an explicit map of fresh facts. The evaluator
  never reads provider state, changes a ledger, resubmits a transition, or
  grants runtime authority. A decision with `status: :resolved` only says
  that the host may persist the resolution before releasing authority.

  A provider-reported blocked lifecycle remains suspended until a separate
  authorized operator recovery path exists. A fresh provider observation or a
  validated lifecycle movement alone cannot resolve it.

  `fresh_reconciliation` must be exactly `true`. `resume_target` must be a
  canonical `WorkflowLifecycle` atom. Provider display names are not accepted
  as resume targets. The target is trusted because the caller supplies it from
  its durable recovery context.
  """

  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  @type reason_class ::
          :retry_exhaustion
          | :provider_configuration
          | :h040_reconciliation
          | :dependency_incomplete
          | :dependency_cycle
          | :provider_blocked
          | :provider_lifecycle_unknown
          | :manual_lifecycle_movement
          | :candidate_evidence
          | :runtime_unavailable
          | :security
          | :durability
          | :unknown

  @type decision :: %{
          action: :resolve | :remain_suspended,
          allowed?: boolean(),
          missing_facts: [atom()],
          reason: term(),
          reason_class: reason_class(),
          resolved?: boolean(),
          resume_target: WorkflowLifecycle.state() | nil,
          resubmit?: false,
          status: :resolved | :suspended
        }

  @retry_exhaustion_reasons [
    :retry_exhausted,
    :ordinary_retry_limit,
    :review_cycle_exhausted,
    :review_cycle_limit,
    :ci_retry_disabled
  ]

  @provider_configuration_reasons [
    :provider_configuration_required,
    :provider_configuration_changed,
    :provider_configuration_drift,
    :provider_contract_reconciliation_required,
    :provider_contract_removed,
    :provider_contract_snapshot_incomplete,
    :provider_contract_validation_required,
    :provider_project_contract_not_configured,
    :invalid_provider_project_contract,
    :provider_contract_provider_malformed,
    :provider_malformed
  ]

  @h040_reconciliation_reasons [
    :prepared,
    :submitted,
    :mutation_submitted,
    :verifying,
    :conflict,
    :indeterminate,
    :provider_failed,
    :transition_conflict,
    :transition_indeterminate
  ]

  @dependency_incomplete_reasons [
    :dependency_data_incomplete,
    :dependency_graph_incomplete,
    :dependency_graph_unavailable,
    :dependency_graph_unsupported,
    :dependency_context_unavailable,
    :invalid_dependency_graph,
    :dependency_data_invalid,
    :dependency_blocked,
    :dependency_data_unknown,
    :dependency_relation_incomplete,
    :dependency_relation_redefinition,
    :dependency_relation_semantics
  ]

  @provider_lifecycle_unknown_reasons [
    :unknown_provider_state,
    :unknown_state_mapping,
    :state_group_mismatch,
    :initial_state_requires_validation,
    :initial_inactive_state,
    :lifecycle_validation_required,
    :validation_required,
    :impossible_transition,
    :invalid_lifecycle,
    :unsafe_lifecycle_observation,
    :provider_observation_incomplete,
    :provider_unknown
  ]

  @manual_lifecycle_reasons [
    :manual_lifecycle_movement,
    :required_evidence_missing,
    :completion_proof_required,
    :canceled,
    :blocked,
    :candidate_state_changed
  ]

  @provider_blocked_reasons [:provider_blocked]

  @candidate_evidence_reasons [
    :candidate_moved,
    :candidate_evidence_invalid,
    :source_control_evidence_invalid,
    :review_acceptance_stale,
    :review_acceptance_invalid
  ]

  @runtime_unavailable_reasons [
    :runtime_unavailable,
    :runtime_not_available,
    :runtime_interrupted,
    :runtime_failure,
    :stale_runtime_attempt,
    :in_flight
  ]

  @security_reasons [
    :security_boundary_failed,
    :security_boundary_violation,
    :security_suspension,
    :security
  ]

  @durability_reasons [
    :durability_failed,
    :recovery_ledger_corrupt,
    :corrupt_recovery_state,
    :schema_mismatch,
    :project_identity_mismatch,
    :tracker_identity_mismatch,
    :durability_corrupt,
    :corrupt_ledger,
    :ledger_unavailable
  ]

  @reason_class_by_reason Enum.reduce(
                            [
                              {:retry_exhaustion, @retry_exhaustion_reasons},
                              {:provider_configuration, @provider_configuration_reasons},
                              {:h040_reconciliation, @h040_reconciliation_reasons},
                              {:dependency_incomplete, @dependency_incomplete_reasons},
                              {:provider_blocked, @provider_blocked_reasons},
                              {:provider_lifecycle_unknown, @provider_lifecycle_unknown_reasons},
                              {:manual_lifecycle_movement, @manual_lifecycle_reasons},
                              {:candidate_evidence, @candidate_evidence_reasons},
                              {:runtime_unavailable, @runtime_unavailable_reasons},
                              {:security, @security_reasons},
                              {:durability, @durability_reasons}
                            ],
                            %{dependency_cycle: :dependency_cycle},
                            fn {reason_class, reasons}, classes ->
                              Enum.reduce(reasons, classes, &Map.put(&2, &1, reason_class))
                            end
                          )

  @doc """
  Classifies a raw suspension reason or a context map containing `:reason`.

  Unknown reasons return `:unknown`, which is fail-closed by `evaluate/2`.
  """
  @spec classify_reason(term()) :: reason_class()
  def classify_reason(%{} = context) do
    context
    |> context_reason()
    |> classify_reason()
  end

  def classify_reason(reason) do
    Map.get(@reason_class_by_reason, reason_atom(reason), :unknown)
  end

  @doc """
  Evaluates one recovery reason against explicit fresh recovery facts.

  The first argument may be a raw reason or a map with `:reason`. The second
  argument is a facts map. A resolved result requires fresh reconciliation and
  a canonical resume target, then applies the rule for the classified reason.
  All other results remain suspended. `resubmit?` is always `false` because an
  old H-040 transition attempt is historical evidence and is never retried.
  """
  @spec evaluate(term(), map()) :: decision()
  def evaluate(reason_or_context, facts) when is_map(facts) do
    reason = context_reason(reason_or_context)
    reason_class = classify_reason(reason)
    decision = base_decision(reason, reason_class)
    common_missing = common_missing_facts(facts)

    cond do
      reason_class == :provider_blocked ->
        suspend(decision, append_missing(common_missing, :provider_blocked_operator_recovery))

      reason_class in [:security, :durability] ->
        suspend(decision, common_missing)

      common_missing != [] ->
        suspend(decision, common_missing)

      true ->
        facts
        |> rule_missing_facts(reason_class)
        |> finish(decision, facts)
    end
  end

  def evaluate(reason_or_context, _facts) do
    reason = context_reason(reason_or_context)
    decision = base_decision(reason, classify_reason(reason))
    suspend(decision, [:fresh_recovery_facts])
  end

  defp common_missing_facts(facts) do
    []
    |> maybe_missing(not true?(facts, :fresh_reconciliation), :fresh_reconciliation)
    |> maybe_missing(not trusted_resume_target(facts), :trusted_resume_target)
  end

  defp maybe_missing(missing, true, fact_name), do: append_missing(missing, fact_name)
  defp maybe_missing(missing, false, _fact_name), do: missing

  defp base_decision(reason, reason_class) do
    %{
      action: :remain_suspended,
      allowed?: false,
      missing_facts: [],
      reason: reason,
      reason_class: reason_class,
      resolved?: false,
      resume_target: nil,
      resubmit?: false,
      status: :suspended
    }
  end

  defp finish(missing_facts, decision, facts) do
    missing_facts = Enum.uniq(missing_facts)

    if missing_facts == [] do
      resolve(decision, fact(facts, :resume_target))
    else
      suspend(decision, missing_facts)
    end
  end

  defp resolve(decision, resume_target) do
    %{
      decision
      | action: :resolve,
        allowed?: true,
        resolved?: true,
        resume_target: resume_target,
        status: :resolved
    }
  end

  defp suspend(decision, missing_facts) do
    %{decision | missing_facts: Enum.uniq(missing_facts)}
  end

  defp rule_missing_facts(facts, :retry_exhaustion), do: retry_exhaustion_missing(facts)

  defp rule_missing_facts(facts, :provider_configuration),
    do: provider_configuration_missing(facts)

  defp rule_missing_facts(facts, :h040_reconciliation), do: h040_missing(facts)

  defp rule_missing_facts(facts, :dependency_incomplete), do: dependency_missing(facts)

  defp rule_missing_facts(facts, :dependency_cycle), do: dependency_cycle_missing(facts)

  defp rule_missing_facts(facts, :provider_lifecycle_unknown),
    do: lifecycle_missing(facts)

  defp rule_missing_facts(facts, :manual_lifecycle_movement),
    do: lifecycle_missing(facts)

  defp rule_missing_facts(facts, :candidate_evidence), do: candidate_missing(facts)

  defp rule_missing_facts(facts, :runtime_unavailable), do: runtime_missing(facts)

  defp rule_missing_facts(_facts, :unknown), do: [:known_recovery_reason]

  defp retry_exhaustion_missing(facts) do
    proof = fact(facts, :h030_rearm) || fact(facts, :rearm_proof) || fact(facts, :retry_rearm)
    explicitly_rearmed? = explicitly_rearmed?(proof)
    old_lineage = lineage_value(proof, [:old_lineage, :old_lineage_id, :history_lineage_id])

    replacement_lineage =
      lineage_value(proof, [:replacement_lineage, :current_lineage, :current_lineage_id, :lineage_id])

    old_history_retained? =
      true?(proof, :old_history_retained?) or true?(proof, :history_retained?)

    checks = [
      {:h030_rearm, is_map(proof)},
      {:h030_rearm, explicitly_rearmed?},
      {:old_lineage, lineage?(old_lineage)},
      {:replacement_lineage, lineage?(replacement_lineage)},
      {:distinct_lineage, old_lineage != replacement_lineage},
      {:old_lineage_history, old_history_retained?}
    ]

    case Enum.find(checks, fn {_missing_fact, satisfied?} -> not satisfied? end) do
      {missing_fact, _unsatisfied} -> [missing_fact]
      nil -> []
    end
  end

  defp explicitly_rearmed?(proof) when is_map(proof) do
    true?(proof, :explicitly_rearmed?) or
      true?(proof, :rearmed?) or
      (fact(proof, :closed_reason) == :rearmed and
         present_identity?(fact(proof, :rearm_reason)) and
         present_identity?(fact(proof, :rearmed_by)) and
         not is_nil(fact(proof, :rearmed_at)))
  end

  defp explicitly_rearmed?(_proof), do: false

  defp lineage_value(proof, keys) when is_map(proof) do
    Enum.find_value(keys, &fact(proof, &1))
  end

  defp lineage_value(_proof, _keys), do: nil

  defp provider_configuration_missing(facts) do
    []
    |> require_true(facts, [:contract_revalidated?, :project_contract_validated?], :contract_revalidated)
    |> require_true(facts, [:stable_provider_ids?, :stable_project_identity?], :stable_provider_identity)
    |> reject_display_name_substitution(facts)
  end

  defp h040_missing(facts) do
    missing =
      []
      |> require_true(
        facts,
        [:authoritative_observation?, :provider_observation_authoritative?],
        :authoritative_observation
      )
      |> require_true(facts, [:evidence_identity_stable?], :stable_evidence_identity)
      |> require_any_true(
        facts,
        [:transition_reconciliation_durable?, :transition_candidate_reconciled?],
        :durable_transition_reconciliation
      )
      |> reject_incomplete_observation(facts)

    identity = fact(facts, :evidence_identity) || fact(facts, :observation_identity)

    missing =
      if present_identity?(identity), do: missing, else: append_missing(missing, :evidence_identity)

    if fact(facts, :resubmit?) == true do
      append_missing(missing, :old_attempt_must_not_be_resubmitted)
    else
      missing
    end
  end

  defp reject_incomplete_observation(missing, facts) do
    observation_status = fact(facts, :provider_observation_status) || fact(facts, :observation_status)
    observation = fact(facts, :provider_observation)

    incomplete? =
      fact(facts, :provider_observation_complete?) == false or
        (is_map(observation) and fact(observation, :complete?) == false) or
        observation_status in [:partial, :incomplete, :error, :timeout, :unknown]

    if incomplete?, do: append_missing(missing, :authoritative_observation), else: missing
  end

  defp dependency_missing(facts) do
    []
    |> require_true(facts, [:dependency_graph_complete?, :graph_complete?], :complete_dependency_graph)
    |> require_true(facts, [:dependency_satisfied?, :dependency_guard_passed?], :dependency_guard)
  end

  defp dependency_cycle_missing(facts) do
    missing =
      []
      |> require_true(facts, [:dependency_graph_complete?, :graph_complete?], :complete_dependency_graph)
      |> require_false(facts, [:dependency_cycle?, :cyclic?], :dependency_cycle_cleared)

    require_true(missing, facts, [:dependency_satisfied?, :dependency_guard_passed?], :dependency_guard)
  end

  defp lifecycle_missing(facts) do
    require_true(
      [],
      facts,
      [:lifecycle_assessment_validated?, :lifecycle_reconciled?, :canonical_lifecycle_validated?],
      :lifecycle_assessment
    )
  end

  defp candidate_missing(facts) do
    []
    |> require_true(
      facts,
      [:candidate_evidence_revalidated?, :source_control_evidence_revalidated?],
      :candidate_evidence_revalidated
    )
    |> require_true(facts, [:candidate_identity_stable?, :candidate_ref_stable?], :candidate_identity_stable)
  end

  defp runtime_missing(facts) do
    []
    |> require_true(facts, [:runtime_available?, :runtime_health_verified?], :runtime_available)
    |> require_true(facts, [:old_runtime_discarded?, :old_runtime_dead?], :old_runtime_discarded)
  end

  defp reject_display_name_substitution(missing, facts) do
    if fact(facts, :display_name_substitution?) == true do
      append_missing(missing, :stable_provider_identity)
    else
      missing
    end
  end

  defp require_true(missing, facts, keys, label) do
    values = fact_values(facts, keys)

    if values != [] and Enum.all?(values, &(&1 === true)), do: missing, else: append_missing(missing, label)
  end

  defp require_any_true(missing, facts, keys, label) do
    if Enum.any?(fact_values(facts, keys), &(&1 === true)), do: missing, else: append_missing(missing, label)
  end

  defp require_false(missing, facts, keys, label) do
    values = fact_values(facts, keys)

    if values != [] and Enum.all?(values, &(&1 === false)), do: missing, else: append_missing(missing, label)
  end

  defp append_missing(missing, fact_name), do: [fact_name | missing]

  defp fact_values(facts, keys) do
    Enum.flat_map(keys, fn key ->
      case fact_entry(facts, key) do
        {:ok, value} -> [value]
        :error -> []
      end
    end)
  end

  defp trusted_resume_target(facts) do
    target = fact(facts, :resume_target)

    is_atom(target) and
      WorkflowLifecycle.canonical?(target) and
      fact(facts, :trusted_resume_target?) != false and
      fact(facts, :resume_target_trusted?) != false
  end

  defp lineage?(value), do: is_binary(value) and String.trim(value) != ""

  defp present_identity?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_identity?(value), do: not is_nil(value)

  defp true?(facts, key), do: fact(facts, key) === true

  defp fact(facts, key) when is_map(facts) do
    case fact_entry(facts, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fact(_facts, _key), do: nil

  defp fact_entry(facts, key) when is_map(facts) do
    case Map.fetch(facts, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_atom(key) ->
        string_key = Atom.to_string(key)

        case Map.fetch(facts, string_key) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp context_reason(%{} = context) do
    case fact(context, :reason) do
      nil -> fact(context, :status)
      reason -> reason
    end
  end

  defp context_reason(reason), do: reason

  defp reason_atom(%{} = context), do: context |> context_reason() |> reason_atom()
  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom({:error, reason}), do: reason_atom(reason)
  defp reason_atom({reason, _detail}) when is_atom(reason), do: reason
  defp reason_atom(_reason), do: nil
end
