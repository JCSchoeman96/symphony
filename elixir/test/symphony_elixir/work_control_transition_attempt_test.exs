defmodule SymphonyElixir.WorkControlTransitionAttemptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.{GuardClass, SemanticTransitionIntent, TransitionAttempt}

  @now ~U[2026-01-02 03:04:05Z]

  test "accepts a canonical host-only intent and keeps provider routing out" do
    assert {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert intent.work_item_id == "work-1"
    assert intent.requested_from == :ready
    assert intent.requested_to == :in_progress
    assert intent.responsibility == "implementation"
    assert intent.requested_at == @now
    assert SemanticTransitionIntent.validate(intent) == :ok

    refute Map.has_key?(Map.from_struct(intent), :provider_state_id)
    refute Map.has_key?(Map.from_struct(intent), :endpoint)
  end

  test "covers public state-machine guards and normalization boundaries" do
    assert TransitionAttempt.schema_version() == 1
    assert TransitionAttempt.terminal?(%{status: :verified})
    refute TransitionAttempt.terminal?(:invalid)
    refute TransitionAttempt.submission_fenced?(:invalid)
    assert TransitionAttempt.automatic_mutation_allowed?(%{state: :prepared})

    assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    assert {:error, :invalid_intent} = TransitionAttempt.authorize_intent(attempt, :invalid)

    assert {:error, :invalid_state} =
             TransitionAttempt.new(Map.put(attempt_attrs(), :requested_from, "Ready"))

    assert {:error, :missing_responsibility} =
             TransitionAttempt.new(Map.put(attempt_attrs(), :responsibility, 123))

    assert {:ok, _atom_responsibility} =
             TransitionAttempt.new(Map.put(attempt_attrs(), :responsibility, :implementation))

    assert {:ok, _map_evidence} =
             TransitionAttempt.new(Map.put(attempt_attrs(), :guard_evidence, %{class: :mechanical_guard, name: :dispatch_guard}))

    assert {:error, :invalid_guard_evidence} =
             TransitionAttempt.new(Map.put(attempt_attrs(), :guard_evidence, :invalid))
  end

  test "rejects malformed attempt envelopes before they enter the state machine" do
    assert {:error, :invalid_attempt} = TransitionAttempt.new(:invalid)
    assert {:error, {:missing, :work_item_id}} = TransitionAttempt.new(%{})
    assert {:error, :invalid_attempt_field} = TransitionAttempt.new(Map.put(attempt_attrs(), :unexpected, true))
    assert {:error, :invalid_timestamp} = TransitionAttempt.new(Map.put(attempt_attrs(), :requested_at, 1))
    assert {:error, :invalid_guard_evidence} = TransitionAttempt.new(Map.put(attempt_attrs(), :guard_evidence, [%{}]))
    assert {:error, :missing_responsibility} = TransitionAttempt.new(Map.put(attempt_attrs(), :responsibility, nil))
  end

  test "rejects provider identity, endpoint, and untyped guard fields" do
    for attrs <- [
          Map.put(intent_attrs(), :provider_state_id, "state-2"),
          Map.put(intent_attrs(), :endpoint, "https://plane.example"),
          Map.put(intent_attrs(), :credentials, %{token: "secret"}),
          Map.put(intent_attrs(), :guard_evidence, [%{name: :dispatch_guard}])
        ] do
      assert {:error, _reason} = SemanticTransitionIntent.new(attrs)
    end
  end

  test "rejects non-canonical or impossible lifecycle intent" do
    assert {:error, :invalid_requested_from} =
             SemanticTransitionIntent.new(%{intent_attrs() | requested_from: "Ready"})

    assert {:error, :invalid_transition} =
             SemanticTransitionIntent.new(%{intent_attrs() | requested_from: :ready, requested_to: :done})
  end

  test "validates every host intent boundary field" do
    assert {:error, :invalid_intent} = SemanticTransitionIntent.new(:invalid)
    assert {:error, :invalid_intent} = SemanticTransitionIntent.validate(:invalid)
    assert {:error, :missing_work_item_id} = SemanticTransitionIntent.new(%{intent_attrs() | work_item_id: "  "})
    assert {:error, :missing_work_item_id} = SemanticTransitionIntent.new(%{intent_attrs() | work_item_id: nil})
    assert {:error, :missing_responsibility} = SemanticTransitionIntent.new(%{intent_attrs() | responsibility: " "})
    assert {:ok, atom_responsibility} = SemanticTransitionIntent.new(%{intent_attrs() | responsibility: :implementation})
    assert atom_responsibility.responsibility == "implementation"
    assert {:error, :invalid_guard_evidence} = SemanticTransitionIntent.new(%{intent_attrs() | guard_evidence: :invalid})

    assert {:ok, map_evidence} =
             SemanticTransitionIntent.new(%{intent_attrs() | guard_evidence: %{class: :mechanical_guard, name: :dispatch_guard}})

    assert map_evidence.guard_evidence == [%{class: :mechanical_guard, name: :dispatch_guard}]
    assert {:error, :invalid_requested_at} = SemanticTransitionIntent.new(%{intent_attrs() | requested_at: 1})
    assert {:error, :invalid_lineage_generation} = SemanticTransitionIntent.new(Map.put(intent_attrs(), :lineage_generation, -1))
    assert {:error, :invalid_lineage_id} = SemanticTransitionIntent.new(Map.put(intent_attrs(), :lineage_id, " "))

    {:ok, lineage} =
      SemanticTransitionIntent.new(Map.merge(intent_attrs(), %{lineage_id: " lineage-1 ", lineage_generation: 2}))

    assert lineage.lineage_id == "lineage-1"
    assert lineage.lineage_generation == 2
  end

  test "walks the strict attempt state machine and fences submission" do
    assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    assert attempt.state == :requested
    refute TransitionAttempt.terminal?(attempt)
    refute TransitionAttempt.submission_fenced?(attempt)
    refute TransitionAttempt.automatic_mutation_allowed?(attempt)

    assert {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())
    assert authorized.state == :intent_authorized

    assert {:ok, loaded} =
             TransitionAttempt.fresh_context_loaded(authorized, fresh_context())

    assert loaded.state == :fresh_context_loaded

    assert {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context())
    assert prepared.state == :prepared
    assert is_struct(prepared.prepared_at, DateTime)
    assert TransitionAttempt.automatic_mutation_allowed?(prepared)
    refute TransitionAttempt.submission_fenced?(prepared)

    assert {:ok, fenced} =
             TransitionAttempt.arm_submission_fence(prepared, %{at: @now})

    assert fenced.state == :prepared
    assert fenced.submission_fenced_at == @now
    assert TransitionAttempt.submission_fenced?(fenced)
    refute TransitionAttempt.automatic_mutation_allowed?(fenced)

    assert {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(fenced, %{at: @now})
    assert submitted.state == :mutation_submitted
    assert submitted.submitted_at == @now

    assert {:ok, verifying} = TransitionAttempt.begin_verification(submitted, %{at: @now})
    assert verifying.state == :verifying

    assert {:ok, verified} = TransitionAttempt.verify(verifying, verification_context())
    assert verified.state == :verified
    assert TransitionAttempt.terminal?(verified)
    refute TransitionAttempt.automatic_mutation_allowed?(verified)
  end

  test "rejects mismatched intents and out-of-order forward transitions" do
    assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())

    assert {:error, :intent_mismatch} =
             TransitionAttempt.authorize_intent(attempt, %{intent_attrs() | work_item_id: "other"})

    assert {:error, {:invalid_attempt_state, :requested, :intent_authorized}} =
             TransitionAttempt.fresh_context_loaded(attempt, fresh_context())

    assert {:error, {:invalid_attempt_state, :requested, :fresh_context_loaded}} =
             TransitionAttempt.prepare(attempt, prepare_context())

    assert {:error, {:invalid_attempt_state, :requested, :prepared}} =
             TransitionAttempt.arm_submission_fence(attempt, %{at: @now})

    assert {:error, {:invalid_attempt_state, :requested, :prepared}} =
             TransitionAttempt.mark_mutation_submitted(attempt, %{at: @now})

    assert {:error, {:invalid_attempt_state, :requested, :mutation_submitted}} =
             TransitionAttempt.begin_verification(attempt, %{at: @now})
  end

  test "requires a durable submission fence before marking submission" do
    {:ok, verifying} = verifying_attempt()

    assert {:error, {:invalid_attempt_state, :verifying, :prepared}} =
             TransitionAttempt.mark_mutation_submitted(verifying)

    {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())
    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context())
    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context())

    assert {:error, :submission_not_fenced} = TransitionAttempt.mark_mutation_submitted(prepared)
    assert {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared)
    assert {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(fenced)
    assert {:ok, _verifying} = TransitionAttempt.begin_verification(submitted)
  end

  test "terminal outcomes absorb every later mutation transition" do
    for terminalizer <- [
          &TransitionAttempt.reject/2,
          &TransitionAttempt.conflict/2,
          &TransitionAttempt.provider_failed/2,
          &TransitionAttempt.indeterminate/2
        ] do
      assert {:ok, attempt} = verifying_attempt()
      opts = if terminalizer == (&TransitionAttempt.provider_failed/2), do: %{}, else: %{reason: :denied}
      assert {:ok, terminal} = terminalizer.(attempt, opts)
      assert TransitionAttempt.terminal?(terminal)
      refute TransitionAttempt.automatic_mutation_allowed?(terminal)

      assert {:error, :terminal_attempt} =
               TransitionAttempt.authorize_intent(terminal, intent())
    end
  end

  test "requires the requested source before authorization and terminalization" do
    assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    assert {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())

    assert {:error, {:invalid_attempt_state, :intent_authorized, :requested}} =
             TransitionAttempt.authorize_intent(authorized, intent())

    for terminalizer <- [
          &TransitionAttempt.conflict/2,
          &TransitionAttempt.provider_failed/2,
          &TransitionAttempt.indeterminate/2
        ] do
      assert {:error, {:invalid_attempt_state, :requested, _terminal_state}} =
               terminalizer.(attempt, %{reason: :not_allowed})
    end
  end

  test "rejects unstructured verification evidence" do
    assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    assert {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())
    assert {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context())
    assert {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context())
    assert {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared, %{at: @now})
    assert {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(fenced, %{at: @now})
    assert {:ok, verifying} = TransitionAttempt.begin_verification(submitted, %{at: @now})

    assert {:error, :invalid_verification_evidence} =
             TransitionAttempt.verify(verifying, :verified)

    invalid_observation = Map.put(verification_context(), :post_observation_evidence, %{})

    assert {:error, :invalid_verification_evidence} =
             TransitionAttempt.verify(verifying, invalid_observation)
  end

  test "records structured verification outcomes without manufacturing success" do
    {:ok, verifying} = verifying_attempt()

    for {assessment, expected_state} <- [
          {%{status: :conflict}, :conflict},
          {%{status: :provider_failed}, :provider_failed},
          {%{status: :validation_required}, :indeterminate}
        ] do
      context = Map.put(verification_context(), :assessment, assessment)
      assert {:ok, terminal} = TransitionAttempt.verify(verifying, context)
      assert terminal.state == expected_state
    end
  end

  test "keeps persisted fences authoritative for map records" do
    assert TransitionAttempt.submission_fenced?(%{status: :prepared, submission_fenced_at: @now})
    assert TransitionAttempt.submission_fenced?(%{state: :mutation_submitted})
    refute TransitionAttempt.submission_fenced?(%{status: :prepared})

    refute TransitionAttempt.automatic_mutation_allowed?(%{status: :prepared, submission_fenced_at: @now})
    assert TransitionAttempt.automatic_mutation_allowed?(%{status: :prepared})
    refute TransitionAttempt.automatic_mutation_allowed?(%{status: :indeterminate})
    refute TransitionAttempt.automatic_mutation_allowed?(:invalid)
  end

  test "post-submit uncertainty cannot become an automatic mutation" do
    {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())
    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context())
    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context())
    {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared, %{at: @now})
    {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(fenced, %{at: @now})
    {:ok, verifying} = TransitionAttempt.begin_verification(submitted, %{at: @now})

    assert {:ok, indeterminate} =
             TransitionAttempt.indeterminate(verifying, %{reason: :verification_unavailable})

    assert TransitionAttempt.submission_fenced?(indeterminate)
    refute TransitionAttempt.automatic_mutation_allowed?(indeterminate)

    assert {:error, :terminal_attempt} =
             TransitionAttempt.mark_mutation_submitted(indeterminate, %{at: @now})
  end

  defp intent_attrs do
    %{
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
      requested_at: @now
    }
  end

  defp intent do
    {:ok, value} = SemanticTransitionIntent.new(intent_attrs())
    value
  end

  defp attempt_attrs do
    %{
      transition_attempt_id: "transition-1",
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
      requested_at: @now
    }
  end

  defp fresh_context do
    %{
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      provider_contract_fingerprint: "sha256:contract",
      dependency_epoch_evidence: %{complete?: true}
    }
  end

  defp prepare_context do
    %{
      guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
      target_provider_state_id: "state-in-progress",
      target_provider_state_group: :started,
      provider_contract_fingerprint: "sha256:contract",
      dependency_epoch_evidence: %{complete?: true},
      durable_sync: true
    }
  end

  defp verification_context do
    %{
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      work_item_id: "work-1",
      provider_state_id: "state-in-progress",
      provider_state_group: :started,
      provider_contract_fingerprint: "sha256:contract",
      post_contract_fingerprint: "sha256:contract",
      post_observation_evidence: %{
        workspace_id: "workspace-1",
        project_id: "project-1",
        work_item_id: "work-1",
        provider_state_id: "state-in-progress",
        observed_at: @now
      },
      assessment: %{status: :validated, validated_state: :in_progress}
    }
  end

  defp verifying_attempt do
    with {:ok, attempt} <- TransitionAttempt.new(attempt_attrs()),
         {:ok, authorized} <- TransitionAttempt.authorize_intent(attempt, intent()),
         {:ok, loaded} <- TransitionAttempt.fresh_context_loaded(authorized, fresh_context()),
         {:ok, prepared} <- TransitionAttempt.prepare(loaded, prepare_context()),
         {:ok, fenced} <- TransitionAttempt.arm_submission_fence(prepared, %{at: @now}),
         {:ok, submitted} <- TransitionAttempt.mark_mutation_submitted(fenced, %{at: @now}) do
      TransitionAttempt.begin_verification(submitted, %{at: @now})
    end
  end
end
