defmodule SymphonyElixir.ProviderMutationEnvelopeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderMutationEnvelope,
    ProviderProjectContract,
    SemanticTransitionIntent,
    TransitionAttempt,
    WorkflowLifecycle
  }

  @now ~U[2026-10-19 09:00:00Z]
  @request_id "preq_00000000-0000-4000-8000-000000000001"

  test "binds one request identity to the prepared transition and provider target" do
    attempt = prepared_attempt()
    context = dispatch_context()

    assert {:ok, envelope} =
             ProviderMutationEnvelope.new(attempt, context,
               provider_request_id: @request_id,
               submitted_at: @now
             )

    assert ProviderMutationEnvelope.valid?(envelope)
    assert envelope.provider_request_id == @request_id
    assert envelope.transition_attempt_id == attempt.transition_attempt_id
    assert envelope.work_item_id == "work-1"
    assert envelope.provider == :plane
    assert envelope.workspace_id == "workspace-1"
    assert envelope.project_id == "project-1"
    assert envelope.requested_from == :merging
    assert envelope.requested_to == :done
    assert envelope.target_provider_state_id == "state-done"
    assert envelope.target_provider_state_group == :completed
    assert envelope.provider_contract_fingerprint == ProviderProjectContract.fingerprint(contract())
    assert envelope.submitted_at == @now

    refute Map.has_key?(Map.from_struct(envelope), :headers)
    refute Map.has_key?(Map.from_struct(envelope), :body)
    refute Map.has_key?(Map.from_struct(envelope), :credential)
    assert ProviderMutationEnvelope.matches?(envelope, "work-1", :done, contract())
  end

  test "rejects changes to work item, scope, target mapping, or contract identity" do
    attempt = prepared_attempt()
    context = dispatch_context()

    for changed_context <- [
          Map.put(context, :work_item_id, "work-other"),
          Map.put(context, :workspace_id, "workspace-other"),
          Map.put(context, :project_id, "project-other"),
          Map.put(context, :provider_contract_fingerprint, "sha256:other"),
          Map.put(context, :target_provider_state_id, "state-other"),
          Map.put(context, :target_provider_state_group, :started)
        ] do
      assert {:error, :provider_mutation_binding_mismatch} =
               ProviderMutationEnvelope.new(attempt, changed_context, provider_request_id: @request_id)
    end

    assert {:error, :provider_project_contract_required} =
             ProviderMutationEnvelope.new(attempt, Map.delete(context, :provider_project_contract), provider_request_id: @request_id)
  end

  test "requires the conservative submission fence and an opaque request id" do
    attempt = prepared_attempt()
    {:ok, submitted} = TransitionAttempt.mark_mutation_submitted(attempt, %{provider_request_id: @request_id})

    assert {:error, :attempt_not_prepared} =
             ProviderMutationEnvelope.new(submitted, dispatch_context(), provider_request_id: @request_id)

    assert {:error, :invalid_provider_request_id} =
             ProviderMutationEnvelope.new(attempt, dispatch_context(), provider_request_id: "ghp_secret")
  end

  defp prepared_attempt do
    intent = %SemanticTransitionIntent{
      work_item_id: "work-1",
      requested_from: :merging,
      requested_to: :done,
      responsibility: "system",
      guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
      requested_at: @now
    }

    attrs = Map.from_struct(intent) |> Map.put(:transition_attempt_id, "transition-h100")
    {:ok, attempt} = TransitionAttempt.new(attrs)
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent)
    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, dispatch_context())

    prepare_context =
      dispatch_context()
      |> Map.put(:target_provider_state_id, "state-done")
      |> Map.put(:target_provider_state_group, :completed)

    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context)
    {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared, %{at: @now})
    fenced
  end

  defp dispatch_context do
    %{
      provider: :plane,
      provider_project_contract: contract(),
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract()),
      target_provider_state_id: "state-done",
      target_provider_state_group: :completed,
      dependency_epoch_evidence: %{complete?: true}
    }
  end

  defp contract do
    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, value} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-1",
        project_id: "project-1",
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    value
  end
end
