defmodule SymphonyElixir.WorkControlAssessmentTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    SuspensionContext,
    WorkflowLifecycle
  }

  @now ~U[2026-09-16 00:00:00Z]

  defp observation(state, id \\ "issue-1") do
    {:ok, observation} =
      ProviderObservation.new(%{
        provider: :memory,
        work_item_id: id,
        provider_state_name: state,
        observed_at: @now
      })

    observation
  end

  defp semantic_evidence(name \\ :plan_attested, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          responsibility: "planning",
          runtime_attempt_id: "attempt-1",
          lineage_generation: 1,
          subject: {:work_item, "issue-1"},
          timestamp: @now
        },
        overrides
      )

    {:ok, evidence} = GuardClass.semantic_attestation(name, attrs)
    evidence
  end

  defp assessment_context(overrides \\ %{}) do
    Map.merge(
      %{
        runtime_attempt_id: "attempt-1",
        lineage_generation: 1
      },
      overrides
    )
  end

  test "provider observation is immutable factual evidence and maps without authorizing" do
    assert {:ok, observation} =
             ProviderObservation.new(%{
               provider: :linear,
               work_item_id: "issue-1",
               provider_state_name: "Ready",
               provider_state_id: nil,
               observed_at: @now
             })

    assert observation.provider == :linear
    assert observation.provider_state_name == "Ready"
    assert is_nil(observation.provider_state_id)
    refute Map.has_key?(observation, :canonical_state)
    assert ProviderObservation.map_state(observation) == {:ok, :ready}
    assert {:error, :missing_work_item_id} = ProviderObservation.new(%{provider_state_name: "Ready"})

    assert {:error, :missing_provider_state_name} =
             ProviderObservation.new(%{work_item_id: "issue-1"})

    assert {:error, :invalid_observation} = ProviderObservation.new(:not_a_map)

    assert {:ok, stable_observation} =
             ProviderObservation.new(%{
               work_item_id: "issue-1",
               provider_state_name: "Ready",
               provider_state_id: "state-1",
               provider_state_group: :started,
               provider_updated_at: @now,
               snapshot_identity: %{version: 1},
               observed_at: @now
             })

    assert ProviderObservation.stable_state_identity?(stable_observation)
    refute ProviderObservation.stable_state_identity?(observation("Ready"))

    assert ProviderObservation.map_state(%{stable_observation | provider_state_name: "Unknown"}) ==
             {:error, :unknown_provider_state}
  end

  test "legacy provider aliases map only at the observation boundary" do
    for {provider_state, canonical_state} <- [
          {"Todo", :ready},
          {"Open", :ready},
          {"Started", :in_progress},
          {"In Development", :in_progress},
          {"Rework", :changes_requested},
          {"Cancelled", :canceled},
          {"Duplicate", :canceled}
        ] do
      provider_observation = observation(provider_state)

      assert ProviderObservation.map_legacy_state(provider_observation) == {:ok, canonical_state}
      assert {:error, {:unknown_state, _}} = WorkflowLifecycle.parse(provider_state)
    end
  end

  test "assessment moves through mapping and rejects an unknown mapping" do
    unassessed = LifecycleAssessment.new(observation("Ready"))
    assert unassessed.status == :unassessed

    assert {:ok, mapped} = LifecycleAssessment.resolve_mapping(unassessed)
    assert mapped.status == :mapping_resolved
    assert mapped.mapped_state == :ready

    unknown = LifecycleAssessment.new(observation("Mystery"))
    assert {:error, invalid} = LifecycleAssessment.resolve_mapping(unknown)
    assert invalid.status == :invalid
    assert invalid.reason == :unknown_mapping
  end

  test "an assessment is single-use after mapping and normalizes trusted inputs" do
    assessment = LifecycleAssessment.new(observation("Ready"))
    assert {:ok, mapped} = LifecycleAssessment.resolve_mapping(assessment)
    assert {:error, :assessment_already_resolved} = LifecycleAssessment.resolve_mapping(mapped)

    reused = LifecycleAssessment.assess(mapped, :planning, [])
    assert reused.status == :invalid
    assert reused.reason == :assessment_reused

    planning_guard = GuardClass.requirement(:mechanical_guard, :planning_requirements_verified)
    plan_attestation = GuardClass.requirement(:semantic_attestation, :plan_attested)

    from_map =
      LifecycleAssessment.assess(
        observation("Ready"),
        :planning,
        %{class: :semantic_attestation, name: :plan_attested}
      )

    assert from_map.status == :validation_required
    assert from_map.missing_guards == [plan_attestation, planning_guard]
    assert from_map.satisfied_guards == []

    from_malformed_evidence = LifecycleAssessment.assess(observation("Ready"), :planning, :not_evidence)
    assert from_malformed_evidence.status == :validation_required
    assert from_malformed_evidence.missing_guards == [plan_attestation, planning_guard]
  end

  test "semantic attestation evidence cannot be a replayable class and name token" do
    requirement = GuardClass.requirement(:semantic_attestation, :plan_attested)

    evidence = %{
      class: :semantic_attestation,
      name: :plan_attested,
      responsibility: "planning",
      runtime_attempt_id: "attempt-1",
      lineage_generation: 1,
      subject: {:work_item, "issue-1"},
      timestamp: @now
    }

    refute GuardClass.satisfied?(requirement, %{class: requirement.class, name: requirement.name})
    refute GuardClass.satisfied?(requirement, evidence)
  end

  test "semantic attestations require attributed and contextually matching evidence" do
    requirement = GuardClass.requirement(:semantic_attestation, :plan_attested)
    evidence = semantic_evidence()

    context =
      assessment_context()
      |> Map.put(:responsibility, "planning")
      |> Map.put(:subject, {:work_item, "issue-1"})

    assert GuardClass.valid_evidence?(evidence)
    assert GuardClass.satisfied?(requirement, evidence, Map.put(context, :subject, {:work_item, "issue-1"}))

    for field <- [:responsibility, :runtime_attempt_id, :lineage_generation, :subject, :timestamp] do
      refute GuardClass.satisfied?(requirement, Map.delete(evidence, field), context)
    end

    refute GuardClass.satisfied?(requirement, %{evidence | responsibility: "review"}, context)
    refute GuardClass.satisfied?(requirement, %{evidence | runtime_attempt_id: "attempt-2"}, context)
    refute GuardClass.satisfied?(requirement, %{evidence | lineage_generation: 2}, context)
    refute GuardClass.satisfied?(requirement, %{evidence | subject: {:work_item, "issue-2"}}, context)
    refute GuardClass.satisfied?(requirement, %{evidence | timestamp: "not-a-timestamp"}, context)

    for field <- [:responsibility, :runtime_attempt_id, :lineage_generation, :subject, :timestamp] do
      assert {:error, _reason} =
               GuardClass.semantic_attestation(:plan_attested, Map.delete(evidence, field))
    end
  end

  test "semantic attestation validation rejects malformed fields and contexts" do
    requirement = GuardClass.requirement(:semantic_attestation, :plan_attested)
    evidence = semantic_evidence()

    context =
      assessment_context()
      |> Map.put(:responsibility, "planning")
      |> Map.put(:subject, {:work_item, "issue-1"})

    assert {:error, :invalid_semantic_attestation} =
             GuardClass.semantic_attestation(:plan_attested, :not_a_map)

    refute GuardClass.valid_evidence?(:malformed)
    assert GuardClass.valid_evidence?(GuardClass.requirement(:mechanical_guard, :dispatch_guard), :not_a_context)
    refute GuardClass.satisfied?(requirement, evidence, :not_a_context)
    refute GuardClass.all_satisfied?([requirement], evidence, :not_a_context)
    assert GuardClass.missing(%{}, evidence, :not_a_context) == []

    refute GuardClass.valid_evidence?(%{class: :semantic_attestation, name: "not_an_atom"})

    refute GuardClass.satisfied?(requirement, evidence, Map.put(context, :timestamp, DateTime.add(@now, 1, :second)))

    for {field, value} <- [
          {:responsibility, 123},
          {:runtime_attempt_id, %{}},
          {:lineage_generation, -1},
          {:subject, 123},
          {:timestamp, "not-a-timestamp"}
        ] do
      assert {:error, _reason} =
               GuardClass.semantic_attestation(:plan_attested, Map.put(evidence, field, value))
    end

    assert {:ok, _atom_responsibility} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | responsibility: :planning})

    assert {:ok, _atom_attempt} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | runtime_attempt_id: :attempt_1})

    assert {:ok, _integer_attempt} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | runtime_attempt_id: 1})

    assert {:ok, _reference_attempt} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | runtime_attempt_id: make_ref()})

    assert {:ok, _map_subject} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | subject: %{work_item_id: "issue-1"}})

    assert {:ok, _string_subject} =
             GuardClass.semantic_attestation(:plan_attested, %{evidence | subject: "issue-1"})
  end

  test "lifecycle assessment rejects cross-item and cross-attempt semantic replay" do
    requirement = GuardClass.requirement(:semantic_attestation, :plan_attested)
    planning_guard = GuardClass.requirement(:mechanical_guard, :planning_requirements_verified)
    evidence = semantic_evidence()
    context = Map.put(assessment_context(), :responsibility, "planning")

    assert LifecycleAssessment.assess(
             observation("Ready"),
             :planning,
             [evidence, planning_guard],
             context
           ).status == :validated

    cross_item =
      LifecycleAssessment.assess(
        observation("Ready", "issue-2"),
        :planning,
        [evidence, planning_guard],
        context
      )

    assert cross_item.status == :validation_required
    assert cross_item.missing_guards == [requirement]

    cross_attempt =
      LifecycleAssessment.assess(
        observation("Ready"),
        :planning,
        [evidence, planning_guard],
        %{context | runtime_attempt_id: "attempt-2"}
      )

    assert cross_attempt.status == :validation_required
    assert cross_attempt.missing_guards == [requirement]
  end

  test "initial inactive backlog is validated without granting authority" do
    assessment = LifecycleAssessment.assess(observation("Backlog"), nil, [])

    assert assessment.status == :validated
    assert assessment.validated_state == :backlog
    assert assessment.reason == :initial_inactive_state

    assert AuthorityDisposition.derive(assessment).status == :none
  end

  test "a corroborating observation validates while an untrusted forward observation does not" do
    corroborated = LifecycleAssessment.assess(observation("Ready"), :ready, [])
    assert corroborated.status == :validated
    assert corroborated.validated_state == :ready

    bare_ready = LifecycleAssessment.assess(observation("Ready"), nil, [])
    assert bare_ready.status == :validation_required
    assert bare_ready.reason == :initial_state_requires_validation

    bare_review = LifecycleAssessment.assess(observation("In Review"), nil, [])
    assert bare_review.status == :validation_required

    bare_merge = LifecycleAssessment.assess(observation("Ready to Merge"), nil, [])
    assert bare_merge.status == :validation_required
  end

  test "legal forward transitions require every typed guard" do
    plan_attestation = semantic_evidence()
    planning_guard = GuardClass.requirement(:mechanical_guard, :planning_requirements_verified)
    context = Map.put(assessment_context(), :responsibility, "planning")

    missing_guard = LifecycleAssessment.assess(observation("Ready"), :planning, [plan_attestation], context)
    assert missing_guard.status == :validation_required
    assert missing_guard.missing_guards == [planning_guard]

    complete =
      LifecycleAssessment.assess(
        observation("Ready"),
        :planning,
        [plan_attestation, planning_guard],
        context
      )

    assert complete.status == :validated
    assert complete.validated_state == :ready
    assert complete.required_guards == [GuardClass.requirement(:semantic_attestation, :plan_attested), planning_guard]
  end

  test "done requires a typed completion proof and canceled or blocked reduce authority" do
    done_without_proof = LifecycleAssessment.assess(observation("Done"), :merging, [])
    assert done_without_proof.status == :validation_required
    refute LifecycleAssessment.dependency_satisfying?(done_without_proof)

    completion_proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
    done = LifecycleAssessment.assess(observation("Done"), :merging, [completion_proof])
    assert done.status == :validated
    assert done.validated_state == :done
    assert LifecycleAssessment.completion_validated?(done)
    assert LifecycleAssessment.dependency_satisfying?(done)

    canceled = LifecycleAssessment.assess(observation("Canceled"), :in_progress, [])
    assert canceled.status == :authority_reducing
    assert canceled.validated_state == :canceled
    refute LifecycleAssessment.dependency_satisfying?(canceled)

    blocked = LifecycleAssessment.assess(observation("Blocked"), :in_progress, [])
    assert blocked.status == :authority_reducing
    assert blocked.validated_state == :blocked

    initial_canceled = LifecycleAssessment.assess(observation("Canceled"), nil, [])
    assert initial_canceled.status == :authority_reducing

    initial_blocked = LifecycleAssessment.assess(observation("Blocked"), nil, [])
    assert initial_blocked.status == :authority_reducing
  end

  test "done cannot be inferred from a non-merging lifecycle state" do
    completion_proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)

    initial_done = LifecycleAssessment.assess(observation("Done"), nil, [completion_proof])
    assert initial_done.status == :validation_required
    refute LifecycleAssessment.dependency_satisfying?(initial_done)

    invalid_done = LifecycleAssessment.assess(observation("Done"), :ready, [completion_proof])
    assert invalid_done.status == :invalid
    assert invalid_done.reason == :impossible_transition
    refute LifecycleAssessment.dependency_satisfying?(invalid_done)
  end

  test "corroborated done still requires its completion proof" do
    proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)

    without_proof = LifecycleAssessment.assess(observation("Done"), :done, [])
    assert without_proof.status == :validation_required
    assert without_proof.reason == :completion_proof_required

    with_proof = LifecycleAssessment.assess(observation("Done"), :done, %{class: proof.class, name: proof.name})
    assert with_proof.status == :validated
    assert with_proof.reason == :corroborated_completion
    assert LifecycleAssessment.completion_validated?(with_proof)
  end

  test "impossible transitions become invalid rather than being inferred" do
    impossible = LifecycleAssessment.assess(observation("In Review"), :ready, [])

    assert impossible.status == :invalid
    assert impossible.reason == :impossible_transition
    refute LifecycleAssessment.dependency_satisfying?(impossible)
  end

  test "an invalid trusted state fails closed and status predicates remain distinct" do
    invalid_prior = LifecycleAssessment.assess(observation("Ready"), :provider_open, [])
    assert invalid_prior.status == :invalid
    assert invalid_prior.reason == :impossible_transition

    refute LifecycleAssessment.validated?(invalid_prior)
    refute LifecycleAssessment.authority_reducing?(invalid_prior)
    refute LifecycleAssessment.validation_required?(invalid_prior)
    assert LifecycleAssessment.invalid?(invalid_prior)
    refute LifecycleAssessment.completion_validated?(invalid_prior)

    backlog = LifecycleAssessment.assess(observation("Backlog"), nil, [])
    refute LifecycleAssessment.invalid?(backlog)
    refute LifecycleAssessment.authority_reducing?(backlog)
    refute LifecycleAssessment.validation_required?(backlog)
  end

  test "authority disposition models eligibility, activity, suspension, and escalation" do
    ready = LifecycleAssessment.assess(observation("Ready"), :ready, [])
    eligible = AuthorityDisposition.derive(ready)
    assert eligible.status == :eligible

    assert {:ok, active} =
             AuthorityDisposition.transition(eligible, :active, %{attempt_started: true})

    assert active.status == :active
    assert {:error, :attempt_not_started} = AuthorityDisposition.transition(eligible, :active, %{})

    canceled = LifecycleAssessment.assess(observation("Canceled"), :ready, [])
    suspended = AuthorityDisposition.derive(canceled, active)
    assert suspended.status == :suspended
    assert suspended.reason == :canceled

    assert {:error, :canceled_terminal} =
             AuthorityDisposition.transition(suspended, :eligible, %{resume_target: :ready})

    assert {:error, :canceled_terminal} =
             AuthorityDisposition.transition(suspended, :eligible, %{
               fresh_reconciliation: true,
               resume_target: :ready
             })

    assert {:ok, escalated} =
             AuthorityDisposition.transition(suspended, :escalated, %{human_decision: true})

    assert escalated.status == :escalated

    assert {:error, :terminal_disposition} =
             AuthorityDisposition.transition(escalated, :eligible, %{})
  end

  test "authority disposition transitions fail closed and keep statuses explicit" do
    none = AuthorityDisposition.new()
    assert AuthorityDisposition.none?(none)
    refute AuthorityDisposition.eligible?(none)
    refute AuthorityDisposition.active?(none)
    refute AuthorityDisposition.suspended?(none)
    refute AuthorityDisposition.escalated?(none)

    assert {:error, :lifecycle_not_eligible} =
             AuthorityDisposition.transition(none, :eligible, %{})

    assert {:error, :invalid_disposition_transition} =
             AuthorityDisposition.transition(none, :active, %{})

    assert {:ok, eligible} =
             AuthorityDisposition.transition(none, :eligible, %{lifecycle_eligible: true})

    assert AuthorityDisposition.eligible?(eligible)
    refute AuthorityDisposition.none?(eligible)

    assert {:ok, suspended} =
             AuthorityDisposition.transition(eligible, :suspended, %{reason: :unsafe_runtime})

    assert AuthorityDisposition.suspended?(suspended)
    refute AuthorityDisposition.eligible?(suspended)

    assert {:error, :fresh_reconciliation_required} =
             AuthorityDisposition.transition(suspended, :eligible, %{})

    assert {:error, :trusted_resume_target_required} =
             AuthorityDisposition.transition(suspended, :active, %{
               fresh_reconciliation: true,
               resume_target: :provider_open
             })

    assert {:ok, active} =
             AuthorityDisposition.transition(suspended, :active, %{
               fresh_reconciliation: true,
               resume_target: :in_progress,
               attempt_started: true
             })

    assert AuthorityDisposition.active?(active)
    refute AuthorityDisposition.suspended?(active)

    assert {:error, :attempt_not_started} =
             AuthorityDisposition.transition(%{suspended | lifecycle_state: :in_progress}, :active, %{
               fresh_reconciliation: true,
               resume_target: :in_progress
             })

    assert {:error, :attempt_not_started} =
             AuthorityDisposition.transition(eligible, :active, %{attempt_started: false})

    assert {:error, :human_decision_required} =
             AuthorityDisposition.transition(suspended, :escalated, %{})

    assert {:ok, escalated} =
             AuthorityDisposition.transition(suspended, :escalated, %{
               human_decision: true,
               reason: :operator_required
             })

    assert AuthorityDisposition.escalated?(escalated)
    refute AuthorityDisposition.active?(escalated)

    assert {:error, :invalid_disposition_transition} =
             AuthorityDisposition.transition(active, :eligible, %{})
  end

  test "a later validated observation cannot reopen an escalated disposition" do
    suspension_assessment = LifecycleAssessment.assess(observation("Blocked"), :ready, [])
    suspended = AuthorityDisposition.derive(suspension_assessment)

    assert {:ok, escalated} =
             AuthorityDisposition.transition(suspended, :escalated, %{human_decision: true})

    validated_assessment = LifecycleAssessment.assess(observation("Ready"), :ready, [])
    preserved = AuthorityDisposition.derive(validated_assessment, escalated)
    assert preserved.status == :escalated
    assert preserved.reason == :human_decision_required

    assert {:error, :terminal_disposition} =
             AuthorityDisposition.transition(preserved, :eligible, %{})
  end

  test "unresolved assessment statuses never create positive authority" do
    unassessed = LifecycleAssessment.new(observation("Ready"))
    assert AuthorityDisposition.derive(unassessed).status == :none

    assert {:ok, mapping_resolved} = LifecycleAssessment.resolve_mapping(unassessed)
    assert AuthorityDisposition.derive(mapping_resolved).status == :none

    invalid = LifecycleAssessment.assess(observation("Ready"), :provider_open, [])
    assert AuthorityDisposition.derive(invalid).status == :suspended
    assert AuthorityDisposition.derive(invalid).reason == :impossible_transition
  end

  test "assessment status predicates distinguish positive and reducing outcomes" do
    validated = LifecycleAssessment.assess(observation("Ready"), :ready, [])
    validation_required = LifecycleAssessment.assess(observation("Ready"), nil, [])
    reducing = LifecycleAssessment.assess(observation("Blocked"), nil, [])

    refute LifecycleAssessment.authority_reducing?(validated)
    assert LifecycleAssessment.validation_required?(validation_required)
    refute LifecycleAssessment.validation_required?(validated)
    assert LifecycleAssessment.authority_reducing?(reducing)
  end

  test "suspension context has a pure recovery lifecycle" do
    assert {:ok, context} =
             SuspensionContext.new(%{
               work_item_id: "issue-1",
               last_validated_lifecycle_state: :in_progress,
               provider_observation: observation("Blocked"),
               reason: :provider_blocked,
               lineage_generation: 2,
               created_at: @now,
               recovery_policy: :fresh_reconciliation,
               required_evidence: [:trusted_resume_target],
               resume_target: :in_progress
             })

    assert context.status == :open
    assert {:ok, resolving} = SuspensionContext.begin_resolution(context)
    assert resolving.status == :resolving

    assert {:error, :required_evidence_missing} =
             SuspensionContext.resolve(resolving, %{fresh_reconciliation: true, resume_target: :in_progress})

    assert {:ok, resolved} =
             SuspensionContext.resolve(resolving, %{
               fresh_reconciliation: true,
               resume_target: :in_progress,
               required_evidence: [:trusted_resume_target]
             })

    assert resolved.status == :resolved
    assert {:error, :terminal_suspension_context} = SuspensionContext.begin_resolution(resolved)

    assert {:ok, open_again} = SuspensionContext.new(%{context | status: :open})
    assert {:ok, resolving_again} = SuspensionContext.begin_resolution(open_again)
    assert {:ok, escalated} = SuspensionContext.escalate(resolving_again, :human_decision_required)
    assert escalated.status == :escalated
  end

  test "suspension context validates its shape and recovery prerequisites" do
    assert {:error, :invalid_suspension_context} = SuspensionContext.new(:not_a_map)

    valid_attrs = %{
      work_item_id: "issue-1",
      last_validated_lifecycle_state: :in_progress,
      provider_observation: observation("Blocked"),
      reason: :provider_blocked,
      required_evidence: [:trusted_resume_target]
    }

    assert {:error, :missing_work_item_id} =
             SuspensionContext.new(%{valid_attrs | work_item_id: " "})

    assert {:error, :missing_work_item_id} =
             SuspensionContext.new(%{valid_attrs | work_item_id: 123})

    assert {:error, :invalid_last_validated_lifecycle_state} =
             SuspensionContext.new(%{valid_attrs | last_validated_lifecycle_state: :provider_open})

    assert {:error, :invalid_provider_observation} =
             SuspensionContext.new(%{valid_attrs | provider_observation: :raw_observation})

    assert {:error, :missing_reason} = SuspensionContext.new(%{valid_attrs | reason: nil})

    assert {:error, :invalid_required_evidence} =
             SuspensionContext.new(%{valid_attrs | required_evidence: :malformed})

    assert {:ok, context} = SuspensionContext.new(valid_attrs)
    assert SuspensionContext.open?(context)
    refute SuspensionContext.resolving?(context)
    refute SuspensionContext.resolved?(context)
    refute SuspensionContext.escalated?(context)

    assert {:error, :context_not_resolving} = SuspensionContext.resolve(context, %{})
    assert {:error, :context_not_resolving} = SuspensionContext.resolve(context, :not_a_map)
    assert {:error, :context_not_resolving} = SuspensionContext.escalate(context, :operator_required)

    assert {:ok, resolving} = SuspensionContext.begin_resolution(context)
    assert SuspensionContext.resolving?(resolving)
    refute SuspensionContext.open?(resolving)
    assert {:error, :already_resolving} = SuspensionContext.begin_resolution(resolving)

    assert {:error, :fresh_reconciliation_required} =
             SuspensionContext.resolve(resolving, %{})

    assert {:error, :trusted_resume_target_required} =
             SuspensionContext.resolve(resolving, %{fresh_reconciliation: true})

    assert {:error, :required_evidence_missing} =
             SuspensionContext.resolve(resolving, %{
               fresh_reconciliation: true,
               resume_target: :in_progress,
               required_evidence: []
             })

    assert {:ok, resolved} =
             SuspensionContext.resolve(resolving, %{
               fresh_reconciliation: true,
               resume_target: :in_progress,
               required_evidence: [:trusted_resume_target]
             })

    assert SuspensionContext.resolved?(resolved)
    refute SuspensionContext.escalated?(resolved)
    assert {:error, :terminal_suspension_context} = SuspensionContext.begin_resolution(resolved)

    assert {:ok, resolving_again} = SuspensionContext.begin_resolution(%{context | status: :open})
    assert {:ok, escalated} = SuspensionContext.escalate(resolving_again, :operator_required)
    assert SuspensionContext.escalated?(escalated)
    refute SuspensionContext.open?(escalated)
    refute SuspensionContext.resolving?(escalated)
    assert {:error, :terminal_suspension_context} = SuspensionContext.begin_resolution(escalated)
    assert {:error, :context_not_resolving} = SuspensionContext.escalate(escalated, :again)
  end
end
