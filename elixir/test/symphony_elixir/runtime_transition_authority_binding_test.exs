defmodule SymphonyElixir.RuntimeAuthoritySupportingProbe do
  def capabilities, do: [:controlled_transition]

  def submit_controlled_transition(work_item_id, target_state, opts) do
    send(opts[:recipient], {:provider_request, work_item_id, target_state})
    :ok
  end
end

defmodule SymphonyElixir.RuntimeTransitionAuthorityBindingTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderProjectContract,
    SemanticTransitionIntent,
    WorkflowLifecycle
  }

  test "canonical runtime responsibility without a trusted route fails before context loading" do
    coordinator = coordinator(self())

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("work-1", :in_progress,
               coordinator: coordinator,
               intent_attrs: intent_attrs(:ready, "implementation")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "malformed trusted routes fail closed without provider side effects" do
    coordinator = coordinator(self())

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("work-1", :in_progress,
               coordinator: coordinator,
               route: %{},
               intent_attrs: intent_attrs(:ready, "implementation")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "a canonical responsibility spoofed against the trusted route fails closed" do
    coordinator = coordinator(self())
    route = route("work-1", :ready, "review")

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("work-1", :in_progress,
               coordinator: coordinator,
               route: route,
               intent_attrs: intent_attrs(:ready, "implementation")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "an atom runtime responsibility is normalized before route authority" do
    coordinator = coordinator(self())

    {:ok, intent} =
      intent_attrs(:in_progress, "implementation", :in_review, "atom-claim")
      |> SemanticTransitionIntent.new()

    atom_claim = %{intent | responsibility: :implementation}

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("atom-claim", :in_review,
               coordinator: coordinator,
               intent: atom_claim
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "a trusted route with a different starting state fails closed" do
    coordinator = coordinator(self())
    route = route("source-mismatch", :in_progress, "implementation")

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("source-mismatch", :in_progress,
               coordinator: coordinator,
               route: route,
               intent_attrs: intent_attrs(:ready, "implementation", nil, "source-mismatch")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "a stale route fingerprint rejects an altered starting state before context loading" do
    coordinator = coordinator(self())
    route = route("stale-starting-state", :ready, "implementation")
    stale_route = %{route | starting_state: "in progress"}

    assert stale_route.fingerprint == route.fingerprint
    assert stale_route.starting_state_fingerprint == route.starting_state_fingerprint
    refute stale_route.starting_state_fingerprint == Route.starting_state_fingerprint(stale_route)

    assert {:ok,
            %{
              state: :rejected,
              outcome_reason: {:authority_rejected, %{code: :invalid_subject, reason: :route_fingerprint_mismatch}}
            }} =
             Tracker.controlled_transition("stale-starting-state", :in_review,
               coordinator: coordinator,
               route: stale_route,
               intent_attrs: intent_attrs(:in_progress, "implementation", :in_review, "stale-starting-state")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "a trusted builder route denies a claimed reviewer command before the provider" do
    assert_cross_role_denied(
      "builder-claimed-reviewer",
      :ready,
      "implementation",
      :ready,
      :in_progress,
      "review"
    )
  end

  test "a trusted reviewer route denies a claimed fixer command before the provider" do
    assert_cross_role_denied(
      "reviewer-claimed-fixer",
      :in_review,
      "review",
      :in_review,
      :ready_to_merge,
      "correction"
    )
  end

  test "a trusted fixer route denies a claimed reviewer merge handoff before the provider" do
    assert_cross_role_denied(
      "fixer-claimed-reviewer",
      :in_review,
      "correction",
      :in_review,
      :ready_to_merge,
      "review"
    )
  end

  test "the six H-050A grants reach H-040 only with a matching trusted route" do
    grants = [
      {:planning, :ready, "planning"},
      {:ready, :in_progress, "implementation"},
      {:in_progress, :in_review, "implementation"},
      {:in_review, :changes_requested, "review"},
      {:in_review, :ready_to_merge, "review"},
      {:changes_requested, :in_review, "correction"}
    ]

    for {source, target, responsibility} <- grants do
      work_item_id = "grant-#{source}-#{target}"
      coordinator = coordinator(self())
      route = route(work_item_id, source, responsibility)

      assert {:ok, %{state: :verified}} =
               Tracker.controlled_transition(work_item_id, target,
                 coordinator: coordinator,
                 route: route,
                 intent_attrs: intent_attrs(source, responsibility, target, work_item_id)
               )

      assert_received :context_loaded
      assert_received :submitted
      GenServer.stop(coordinator)
    end
  end

  test "the merge route remains denied even with a matching trusted route" do
    coordinator = coordinator(self())
    route = route("merge-work", :ready_to_merge, "merge")

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("merge-work", :merging,
               coordinator: coordinator,
               route: route,
               intent_attrs: intent_attrs(:ready_to_merge, "merge", nil, "merge-work")
             )

    refute_received :context_loaded
    refute_received :submitted
  end

  test "a downstream dependency denial reaches policy but never submits" do
    coordinator = coordinator(self(), dependency_decision: %{allowed?: false})
    route = route("dependency-work", :ready, "implementation")

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition("dependency-work", :in_progress,
               coordinator: coordinator,
               route: route,
               intent_attrs: intent_attrs(:ready, "implementation", nil, "dependency-work")
             )

    assert_received :context_loaded
    refute_received :submitted
  end

  test "missing provider capability fails after authority without a provider request" do
    test_pid = self()

    coordinator =
      coordinator(test_pid,
        submit: fn _attempt, _context ->
          send(test_pid, :provider_callback)

          Tracker.submit_controlled_transition(
            "capability-work",
            :in_progress,
            adapter: SymphonyElixir.RuntimeAuthorityCapabilityProbe
          )
        end,
        verify: &provider_failed/2
      )

    route = route("capability-work", :ready, "implementation")

    assert {:ok, %{state: :provider_failed}} =
             Tracker.controlled_transition("capability-work", :in_progress,
               coordinator: coordinator,
               route: route,
               intent_attrs: intent_attrs(:ready, "implementation", nil, "capability-work")
             )

    assert_received :context_loaded
    assert_received :provider_callback
    refute_received :provider_request
  end

  test "provider capabilities do not grant runtime lifecycle authority" do
    capabilities = Adapter.capabilities()

    assert :controlled_transition in capabilities
    refute :agent_read_tools in capabilities
    refute :agent_transition_tools in capabilities
    refute :conditional_transition in capabilities
  end

  defp coordinator(test_pid, opts \\ []) do
    dependency_decision = Keyword.get(opts, :dependency_decision, allowed_dependency())

    submit =
      Keyword.get(opts, :submit, fn _attempt, _context ->
        send(test_pid, :submitted)
        :ok
      end)

    verify = Keyword.get(opts, :verify, &verified/2)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn intent ->
          send(test_pid, :context_loaded)

          {:ok,
           %{
             provider_project_contract: contract(),
             dependency_decision: dependency_decision,
             dependency_epoch_evidence: %{complete?: true},
             guard_evidence: intent.guard_evidence
           }}
        end,
        submit: submit,
        verify: verify
      )

    coordinator
  end

  defp assert_cross_role_denied(
         work_item_id,
         route_source,
         route_responsibility,
         requested_from,
         requested_to,
         claimed_responsibility
       ) do
    test_pid = self()

    coordinator =
      coordinator(test_pid,
        submit: fn _attempt, _context ->
          send(test_pid, :provider_callback)

          Tracker.submit_controlled_transition(work_item_id, requested_to,
            adapter: SymphonyElixir.RuntimeAuthoritySupportingProbe,
            recipient: test_pid
          )
        end
      )

    assert {:ok, %{state: :rejected}} =
             Tracker.controlled_transition(work_item_id, requested_to,
               coordinator: coordinator,
               route: route(work_item_id, route_source, route_responsibility),
               intent_attrs:
                 intent_attrs(
                   requested_from,
                   claimed_responsibility,
                   requested_to,
                   work_item_id
                 )
             )

    refute_received :context_loaded
    refute_received :provider_callback
    refute_received {:provider_request, ^work_item_id, ^requested_to}
    GenServer.stop(coordinator)
  end

  defp intent_attrs(source, responsibility, target \\ nil, work_item_id \\ "work-1") do
    target = target || target_for(source, responsibility)

    %{
      work_item_id: work_item_id,
      requested_from: source,
      requested_to: target,
      responsibility: responsibility,
      guard_evidence: guard_evidence(source, target, work_item_id, responsibility)
    }
  end

  defp target_for(:planning, "planning"), do: :ready
  defp target_for(:ready, "implementation"), do: :in_progress
  defp target_for(:in_progress, "implementation"), do: :in_review
  defp target_for(:changes_requested, "correction"), do: :in_review
  defp target_for(:in_review, "review"), do: :ready_to_merge
  defp target_for(:ready_to_merge, "merge"), do: :merging

  defp guard_evidence(source, target, work_item_id, responsibility) do
    source
    |> guard_evidence_names(target)
    |> Enum.map(fn {class, name} -> evidence(class, name, work_item_id, responsibility) end)
  end

  defp guard_evidence_names(:planning, :ready), do: [{:semantic_attestation, :plan_attested}, {:mechanical_guard, :planning_requirements_verified}]
  defp guard_evidence_names(:ready, :in_progress), do: [{:mechanical_guard, :dispatch_guard}]
  defp guard_evidence_names(:in_progress, :in_review), do: [{:semantic_attestation, :implementation_attested}, {:mechanical_guard, :implementation_checks_verified}]
  defp guard_evidence_names(:in_review, :changes_requested), do: [{:semantic_attestation, :review_changes_requested}]
  defp guard_evidence_names(:in_review, :ready_to_merge), do: [{:mechanical_guard, :review_acceptance_verified}, {:semantic_attestation, :review_accepted}]
  defp guard_evidence_names(:changes_requested, :in_review), do: [{:semantic_attestation, :correction_attested}, {:mechanical_guard, :correction_checks_verified}]
  defp guard_evidence_names(:ready_to_merge, :merging), do: [{:human_decision, :merge_approved}, {:mechanical_guard, :merge_guard_verified}]

  defp evidence(:semantic_attestation, name, work_item_id, responsibility) do
    {:ok, evidence} =
      GuardClass.semantic_attestation(name, %{
        responsibility: responsibility,
        runtime_attempt_id: :transition_coordinator,
        lineage_generation: 0,
        subject: {:work_item, work_item_id},
        timestamp: DateTime.utc_now()
      })

    evidence
  end

  defp evidence(class, name, _work_item_id, _responsibility), do: %{class: class, name: name}

  defp verified(attempt, _context) do
    {:verified,
     %{
       assessment: %{status: :validated, validated_state: attempt.requested_to},
       post_observation_evidence: %{
         workspace_id: "workspace-1",
         project_id: "project-1",
         work_item_id: attempt.work_item_id,
         provider_state_id: "state-#{attempt.requested_to}",
         observed_at: DateTime.utc_now()
       },
       post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
     }}
  end

  defp provider_failed(attempt, _context) do
    {:provider_failed,
     %{
       non_commit?: true,
       assessment: %{status: :provider_failed, work_item_id: attempt.work_item_id},
       post_observation_evidence: %{
         workspace_id: "workspace-1",
         project_id: "project-1",
         work_item_id: attempt.work_item_id,
         provider_state_id: "unavailable",
         observed_at: DateTime.utc_now()
       },
       post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
     }}
  end

  defp route(work_item_id, source, responsibility) do
    profile_name =
      %{
        "planning" => "planner",
        "implementation" => "builder",
        "review" => "reviewer",
        "correction" => "fixer",
        "merge" => "merge_gatekeeper"
      }[responsibility]

    profile = Profile.default_profiles("codex app-server", 20)[profile_name]
    Route.new(%Issue{id: work_item_id, state: WorkflowLifecycle.display(source), dispatchable: true}, profile)
  end

  defp allowed_dependency do
    %{allowed?: true, dependency_completeness: :complete, dependency_status: :none, merge_permitted?: true}
  end

  defp contract do
    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-1",
        project_id: "project-1",
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end
end
