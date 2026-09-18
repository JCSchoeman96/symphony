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

    assert {:ok, submitted} =
             TransitionAttempt.mark_mutation_submitted(prepared, %{at: @now})

    assert submitted.state == :mutation_submitted
    assert submitted.submission_fenced_at == @now
    assert TransitionAttempt.submission_fenced?(submitted)
    refute TransitionAttempt.automatic_mutation_allowed?(submitted)

    assert {:ok, verifying} = TransitionAttempt.begin_verification(submitted, %{at: @now})
    assert verifying.state == :verifying

    assert {:ok, verified} = TransitionAttempt.verify(verifying, verification_context())
    assert verified.state == :verified
    assert TransitionAttempt.terminal?(verified)
    refute TransitionAttempt.automatic_mutation_allowed?(verified)
  end

  test "terminal outcomes absorb every later mutation transition" do
    for terminalizer <- [
          &TransitionAttempt.reject/2,
          &TransitionAttempt.conflict/2,
          &TransitionAttempt.provider_failed/2,
          &TransitionAttempt.indeterminate/2
        ] do
      assert {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
      opts = if terminalizer == (&TransitionAttempt.provider_failed/2), do: %{}, else: %{reason: :denied}
      assert {:ok, terminal} = terminalizer.(attempt, opts)
      assert TransitionAttempt.terminal?(terminal)
      refute TransitionAttempt.automatic_mutation_allowed?(terminal)

      assert {:error, :terminal_attempt} =
               TransitionAttempt.authorize_intent(terminal, intent())
    end
  end

  test "post-submit uncertainty cannot become an automatic mutation" do
    {:ok, attempt} = TransitionAttempt.new(attempt_attrs())
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())
    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context())
    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context())
    {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(prepared, %{at: @now})
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
      provider_state_id: "state-in-progress",
      provider_state_group: :started,
      provider_contract_fingerprint: "sha256:contract",
      assessment: %{status: :validated, validated_state: :in_progress}
    }
  end
end
