defmodule SymphonyElixir.WorkControl.SuspensionRecoveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.SuspensionRecovery

  test "classifies the supported recovery reasons" do
    assert SuspensionRecovery.classify_reason(:retry_exhausted) == :retry_exhaustion
    assert SuspensionRecovery.classify_reason(:provider_configuration_drift) == :provider_configuration
    assert SuspensionRecovery.classify_reason(:indeterminate) == :h040_reconciliation
    assert SuspensionRecovery.classify_reason(:dependency_data_incomplete) == :dependency_incomplete
    assert SuspensionRecovery.classify_reason(:dependency_cycle) == :dependency_cycle

    assert SuspensionRecovery.classify_reason(%{reason: :provider_blocked, status: :resolving}) ==
             :provider_blocked

    assert SuspensionRecovery.classify_reason(:candidate_moved) == :candidate_evidence
    assert SuspensionRecovery.classify_reason(:runtime_unavailable) == :runtime_unavailable
    assert SuspensionRecovery.classify_reason(:security_boundary_failed) == :security
    assert SuspensionRecovery.classify_reason(:durability_failed) == :durability
    assert SuspensionRecovery.classify_reason(:unrecognised_reason) == :unknown
  end

  test "missing fresh reconciliation and resume target keep every reason suspended" do
    decision = SuspensionRecovery.evaluate(:manual_lifecycle_movement, %{})

    assert decision.status == :suspended
    assert decision.action == :remain_suspended
    assert :fresh_reconciliation in decision.missing_facts
    assert :trusted_resume_target in decision.missing_facts
  end

  test "accepts a canonical target only when fresh reconciliation is explicit" do
    facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      lifecycle_assessment_validated?: true
    }

    decision = SuspensionRecovery.evaluate(:manual_lifecycle_movement, facts)

    assert decision.status == :resolved
    assert decision.resume_target == :ready
  end

  test "provider display names are not trusted resume targets" do
    decision =
      SuspensionRecovery.evaluate(:manual_lifecycle_movement, %{
        fresh_reconciliation: true,
        resume_target: "Ready",
        lifecycle_assessment_validated?: true
      })

    assert decision.status == :suspended
    assert :trusted_resume_target in decision.missing_facts
  end

  test "retry exhaustion requires a rearm proof for distinct retained lineages" do
    facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      h030_rearm: %{
        explicitly_rearmed?: true,
        old_lineage: "lineage-1",
        replacement_lineage: "lineage-2",
        old_history_retained?: true
      }
    }

    assert SuspensionRecovery.evaluate(:retry_exhausted, facts).status == :resolved

    assert SuspensionRecovery.evaluate(:retry_exhausted, %{
             fresh_reconciliation: true,
             resume_target: :ready,
             h030_rearm: %{
               rearmed?: true,
               old_lineage_id: "lineage-1",
               current_lineage_id: "lineage-2",
               history_retained?: true
             }
           }).status == :resolved

    for proof <- [
          %{explicitly_rearmed?: false, old_lineage: "lineage-1", replacement_lineage: "lineage-2", old_history_retained?: true},
          %{explicitly_rearmed?: true, old_lineage: "lineage-1", replacement_lineage: "lineage-1", old_history_retained?: true},
          %{explicitly_rearmed?: true, old_lineage: "lineage-1", replacement_lineage: "lineage-2", old_history_retained?: false}
        ] do
      decision = SuspensionRecovery.evaluate(:retry_exhausted, %{facts | h030_rearm: proof})
      assert decision.status == :suspended
    end
  end

  test "an H-040 recovery requires authoritative observation and stable evidence" do
    base = %{fresh_reconciliation: true, resume_target: :ready}

    assert SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: true,
               transition_reconciliation_durable?: true,
               evidence_identity: "observation-1",
               evidence_identity_stable?: true,
               resubmit?: false
             })
           ).status == :resolved

    refute SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: false,
               transition_reconciliation_durable?: true,
               evidence_identity: "observation-1",
               evidence_identity_stable?: true
             })
           ).status == :resolved

    refute SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: true,
               transition_reconciliation_durable?: true,
               evidence_identity: "observation-1",
               evidence_identity_stable?: false
             })
           ).status == :resolved

    refute SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: true,
               transition_reconciliation_durable?: true,
               provider_observation_status: :partial,
               evidence_identity: "observation-1",
               evidence_identity_stable?: true
             })
           ).status == :resolved

    refute SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: true,
               transition_reconciliation_durable?: true,
               evidence_identity: "observation-1",
               evidence_identity_stable?: true,
               resubmit?: true
             })
           ).status == :resolved

    refute SuspensionRecovery.evaluate(
             :indeterminate,
             Map.merge(base, %{
               authoritative_observation?: true,
               transition_reconciliation_durable?: false,
               evidence_identity: "observation-1",
               evidence_identity_stable?: true
             })
           ).status == :resolved
  end

  test "security and durability contexts never auto-resolve" do
    facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      human_decision?: true,
      ledger_healthy?: true
    }

    for reason <- [:security_boundary_failed, :durability_failed] do
      decision = SuspensionRecovery.evaluate(reason, facts)
      assert decision.status == :suspended
      assert decision.action == :remain_suspended
    end
  end

  test "dependency recovery requires a complete fresh epoch and a passing guard" do
    facts = %{fresh_reconciliation: true, resume_target: :ready}

    assert SuspensionRecovery.evaluate(
             :dependency_data_incomplete,
             Map.merge(facts, %{
               dependency_graph_complete?: true,
               dependency_satisfied?: true
             })
           ).status == :resolved

    assert SuspensionRecovery.evaluate(
             :dependency_data_incomplete,
             Map.merge(facts, %{
               dependency_graph_complete?: false,
               dependency_satisfied?: true
             })
           ).status == :suspended
  end

  test "a healthy provider observation cannot resolve an unknown lifecycle without validation" do
    decision =
      SuspensionRecovery.evaluate(:initial_state_requires_validation, %{
        fresh_reconciliation: true,
        resume_target: :ready,
        provider_healthy?: true
      })

    assert decision.status == :suspended
    assert :lifecycle_assessment in decision.missing_facts
  end

  test "provider-blocked suspension requires explicit operator recovery" do
    decision =
      SuspensionRecovery.evaluate(
        %{reason: :provider_blocked, status: :resolving},
        %{
          fresh_reconciliation: true,
          resume_target: :ready,
          trusted_resume_target?: true,
          lifecycle_assessment_validated?: true
        }
      )

    assert decision.reason_class == :provider_blocked
    assert decision.status == :suspended
    assert decision.action == :remain_suspended
    assert decision.missing_facts == [:provider_blocked_operator_recovery]
  end

  test "runtime recovery requires health and discards the old runtime" do
    facts = %{fresh_reconciliation: true, resume_target: :in_progress}

    assert SuspensionRecovery.evaluate(
             :runtime_unavailable,
             Map.merge(facts, %{
               runtime_available?: true,
               old_runtime_discarded?: true
             })
           ).status == :resolved

    assert SuspensionRecovery.evaluate(
             :runtime_unavailable,
             Map.merge(facts, %{
               runtime_available?: true,
               old_runtime_discarded?: false
             })
           ).status == :suspended
  end

  test "an unknown reason fails closed" do
    decision = SuspensionRecovery.evaluate(:new_reason, %{fresh_reconciliation: true, resume_target: :ready})

    assert decision.status == :suspended
    assert decision.reason_class == :unknown
  end

  test "normalizes wrapped and context reasons, and rejects non-map facts" do
    assert SuspensionRecovery.classify_reason(%{reason: :conflict}) == :h040_reconciliation
    assert SuspensionRecovery.classify_reason({:error, :retry_exhausted}) == :retry_exhaustion
    assert SuspensionRecovery.classify_reason({:provider_configuration_drift, :changed}) == :provider_configuration
    assert SuspensionRecovery.classify_reason(%{status: :candidate_moved}) == :candidate_evidence
    assert SuspensionRecovery.classify_reason(%{}) == :unknown

    decision = SuspensionRecovery.evaluate(:manual_lifecycle_movement, :invalid_facts)
    assert decision.missing_facts == [:fresh_recovery_facts]
  end

  test "requires explicit project contract facts and rejects display-name substitution" do
    base = %{fresh_reconciliation: true, resume_target: :ready}

    decision = SuspensionRecovery.evaluate(:provider_configuration_drift, base)
    assert :contract_revalidated in decision.missing_facts
    assert :stable_provider_identity in decision.missing_facts

    valid = %{contract_revalidated?: true, stable_provider_ids?: true}
    assert SuspensionRecovery.evaluate(:provider_configuration_drift, Map.merge(base, valid)).status == :resolved

    substituted = Map.merge(base, Map.merge(valid, %{display_name_substitution?: true}))
    decision = SuspensionRecovery.evaluate(:provider_configuration_drift, substituted)
    assert :stable_provider_identity in decision.missing_facts
  end

  test "checks dependency cycle clearance and source candidate proof independently" do
    base = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      dependency_graph_complete?: true,
      dependency_satisfied?: true
    }

    assert SuspensionRecovery.evaluate(:dependency_cycle, Map.put(base, :dependency_cycle?, false)).status == :resolved
    assert :dependency_cycle_cleared in SuspensionRecovery.evaluate(:dependency_cycle, Map.put(base, :dependency_cycle?, true)).missing_facts

    candidate_facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      candidate_evidence_revalidated?: true,
      candidate_identity_stable?: true
    }

    assert SuspensionRecovery.evaluate(:candidate_moved, candidate_facts).status == :resolved
    assert :candidate_identity_stable in SuspensionRecovery.evaluate(:candidate_moved, Map.put(candidate_facts, :candidate_identity_stable?, false)).missing_facts
  end

  test "supports the durable rearm record shape and rejects incomplete observations" do
    facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      h030_rearm: %{
        closed_reason: :rearmed,
        rearm_reason: "operator confirmed",
        rearmed_by: "operator",
        rearmed_at: 1,
        old_lineage_id: "old",
        current_lineage_id: "new",
        history_retained?: true
      }
    }

    assert SuspensionRecovery.evaluate(:retry_exhausted, facts).status == :resolved

    h040_facts = %{
      fresh_reconciliation: true,
      resume_target: :ready,
      authoritative_observation?: true,
      evidence_identity_stable?: true,
      transition_reconciliation_durable?: true,
      evidence_identity: "snapshot"
    }

    for incomplete_observation <- [
          %{provider_observation_complete?: false},
          %{provider_observation: %{complete?: false}}
        ] do
      decision = SuspensionRecovery.evaluate(:indeterminate, Map.merge(h040_facts, incomplete_observation))
      assert decision.status == :suspended
    end

    assert SuspensionRecovery.evaluate(:indeterminate, %{
             "fresh_reconciliation" => true,
             "resume_target" => :ready,
             "authoritative_observation?" => true,
             "evidence_identity_stable?" => true,
             "transition_candidate_reconciled?" => true,
             "evidence_identity" => "snapshot"
           }).status == :resolved
  end
end
