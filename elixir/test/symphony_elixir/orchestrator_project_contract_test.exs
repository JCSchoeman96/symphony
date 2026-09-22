defmodule SymphonyElixir.OrchestratorProjectContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    ProjectContractEvidence,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @states WorkflowLifecycle.states()

  test "contract drift fences autonomous dispatch without a provider mutation" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract)
    }

    validated = Orchestrator.reconcile_project_contract_for_test(state, snapshot())
    assert validated.project_contract_evidence.validation.status == :valid
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(validated)

    drifted =
      Orchestrator.reconcile_project_contract_for_test(
        validated,
        Map.put(snapshot(), :project_id, "project-recreated")
      )

    assert drifted.project_contract_evidence.validation.status == :drift_detected
    assert drifted.project_contract_evidence.reason == :provider_configuration_drift
    assert ProjectContractEvidence.reconciliation_required?(drifted.project_contract_evidence)
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(drifted)
  end

  test "contract drift suspends existing WorkItems through canonical P-010 authority" do
    contract = contract!()
    issue = %Issue{id: "issue-1", identifier: "SYM-1", title: "Contract guard", state: "Ready"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :ready
      })

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract),
      work_control: %{issue.id => work_item}
    }

    drifted =
      state
      |> Orchestrator.reconcile_project_contract_for_test(snapshot())
      |> Orchestrator.reconcile_project_contract_for_test(Map.put(snapshot(), :project_id, "project-recreated"))

    suspended_work_item = drifted.work_control[issue.id]
    assert suspended_work_item.authority_disposition.status == :suspended
    assert suspended_work_item.authority_disposition.reason == :provider_configuration_drift
    assert suspended_work_item.suspension_context.reason == :provider_configuration_drift
    refute WorkItem.authority_available?(suspended_work_item)
  end

  test "contract suspension remains closed until revalidation of the current contract" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract)
    }

    suspended =
      state
      |> Orchestrator.reconcile_project_contract_for_test(snapshot())
      |> Orchestrator.reconcile_project_contract_for_test(Map.put(snapshot(), :project_id, "wrong-project"))

    assert suspended.project_contract_evidence.validation.status == :drift_detected
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(suspended)

    recovered = Orchestrator.reconcile_project_contract_for_test(suspended, snapshot())

    assert recovered.project_contract_evidence.validation.status == :valid
    refute ProjectContractEvidence.reconciliation_required?(recovered.project_contract_evidence)
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(recovered)
  end

  test "provider snapshot transport failure reuses the canonical incomplete-contract fence" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract)
    }

    validated = Orchestrator.reconcile_provider_project_snapshot_for_test(state, {:ok, snapshot()})
    assert validated.project_contract_evidence.validation.status == :valid
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(validated)

    unavailable =
      Orchestrator.reconcile_provider_project_snapshot_for_test(
        validated,
        {:error, :provider_unavailable}
      )

    assert unavailable.project_contract_evidence.validation.status == :snapshot_incomplete
    assert unavailable.project_contract_evidence.reason == :provider_contract_snapshot_incomplete
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(unavailable)

    malformed = Orchestrator.reconcile_provider_project_snapshot_for_test(unavailable, :malformed)
    assert malformed.project_contract_evidence.validation.status == :snapshot_incomplete
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(malformed)
  end

  test "public reconciliation call hands a trusted snapshot to the orchestrator" do
    name = String.to_atom("project-contract-orchestrator-#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, start_quiesced: true)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    contract = contract!()

    :sys.replace_state(pid, fn state ->
      %{state | attempt_ledger_status: :disabled, project_contract_evidence: ProjectContractEvidence.new(contract)}
    end)

    assert {:ok, %ProviderProjectContract.ValidationResult{status: :valid}} =
             Orchestrator.reconcile_project_contract(name, snapshot())

    assert :sys.get_state(pid).project_contract_evidence.validation.status == :valid
  end

  test "changing the configured contract stops running work and clears pending retries" do
    contract = contract!()
    retry_timer = Process.send_after(self(), :project_contract_retry, 60_000)

    state = %Orchestrator.State{
      project_contract_evidence: ProjectContractEvidence.new(contract),
      running: %{
        "running-issue" => %{
          pid: nil,
          ref: nil,
          identifier: "RUNNING-1",
          started_at: DateTime.utc_now()
        }
      },
      retry_attempts: %{
        "retry-issue" => %{timer_ref: retry_timer}
      },
      claimed: MapSet.new(["running-issue", "retry-issue"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    changed = Orchestrator.reconfigure_project_contract_for_test(state, %{contract | project_id: "project-2"})

    assert changed.project_contract_evidence.reason == :provider_configuration_changed
    assert ProjectContractEvidence.reconciliation_required?(changed.project_contract_evidence)
    assert changed.running == %{}
    assert changed.retry_attempts == %{}
    assert changed.claimed == MapSet.new()
    assert changed.recent_attempts |> hd() |> Map.get(:termination_reason) == :provider_configuration_changed
    refute_receive :project_contract_retry, 0
  end

  test "removing an established contract keeps canonical authority fenced" do
    contract = contract!()
    issue = %Issue{id: "issue-1", identifier: "SYM-1", title: "Contract removal", state: "Ready"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :ready
      })

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract),
      work_control: %{issue.id => work_item}
    }

    removed =
      state
      |> Orchestrator.reconcile_project_contract_for_test(snapshot())
      |> Orchestrator.reconfigure_project_contract_for_test(nil)

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(removed)
    assert removed.project_contract_evidence.reason == :provider_contract_removed
    assert removed.work_control[issue.id].authority_disposition.status == :suspended
    assert removed.work_control[issue.id].suspension_context.reason == :provider_contract_removed
  end

  test "removing a drift-suspended contract cannot clear the canonical fence" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_evidence: ProjectContractEvidence.new(contract)
    }

    removed =
      state
      |> Orchestrator.reconcile_project_contract_for_test(snapshot())
      |> Orchestrator.reconcile_project_contract_for_test(Map.put(snapshot(), :workspace_id, "workspace-recreated"))
      |> Orchestrator.reconfigure_project_contract_for_test(nil)

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(removed)
    assert removed.project_contract_evidence.reason == :provider_contract_removed
    assert ProjectContractEvidence.reconciliation_required?(removed.project_contract_evidence)
  end

  test "builds trusted transition context and enforces its context token" do
    {state, _work_item} = handoff_state()
    from = {self(), make_ref()}

    assert {:reply, {:ok, context}, _state} =
             Orchestrator.handle_call({:transition_context, "work-1", []}, from, state)

    assert context.current_state == :ready
    assert context.dependency_decision == %{allowed?: true}
    assert context.dependency_epoch_evidence.complete? == true
    assert context.provider_observation.work_item_id == "work-1"
    assert is_binary(context.context_token)

    assert {:reply, {:ok, _same_context}, _state} =
             Orchestrator.handle_call(
               {:transition_context, "work-1", [expected_context_token: context.context_token]},
               from,
               state
             )

    assert {:reply, {:error, :context_token_mismatch}, _state} =
             Orchestrator.handle_call(
               {:transition_context, "work-1", [expected_context_token: "sha256:stale"]},
               from,
               state
             )
  end

  test "semantic tool context returns current canonical work and graph evidence" do
    {state, work_item} = handoff_state()
    contract = contract!()
    graph = Graph.build([issue_for("work-1")], epoch: :semantic_epoch)
    evidence = ProjectContractEvidence.new(contract)
    from = {self(), make_ref()}
    state = %{state | dependency_graph: graph, project_contract_evidence: evidence}

    assert {:reply, {:ok, context}, _state} =
             Orchestrator.handle_call({:semantic_tool_context, "work-1"}, from, state)

    assert context.work_item == work_item
    refute Map.has_key?(context, :work_control)
    assert context.dependency_blocker_classifications == %{}
    assert context.dependency_decision == %{allowed?: true}

    assert context.dependency_epoch_evidence == %{
             epoch: :semantic_epoch,
             completeness: :complete,
             complete?: true
           }

    assert context.provider_project_contract == contract
    assert context.provider_contract_fingerprint == ProviderProjectContract.fingerprint(contract)
    assert context.project_contract_evidence == ProjectContractEvidence.observability(evidence)
    assert is_nil(context.runtime_attempt_identity)
  end

  test "semantic tool context includes the current runtime attempt identity when running" do
    {state, work_item} = handoff_state()

    identity =
      RuntimeAttemptIdentity.allocate(
        work_item.id,
        %Route{
          issue_id: work_item.id,
          starting_state: "Ready",
          profile_name: "implementation",
          runtime_name: "codex",
          responsibility: "implementation",
          fingerprint: "fp",
          starting_state_fingerprint: "sfp"
        },
        "lineage-handoff"
      )

    state = %{
      state
      | running: %{
          work_item.id => %{
            profile_name: "implementation",
            runtime_attempt: RuntimeAttempt.new(identity, :running)
          }
        }
    }

    from = {self(), make_ref()}

    assert {:reply, {:ok, context}, _state} =
             Orchestrator.handle_call({:semantic_tool_context, "work-1"}, from, state)

    assert RuntimeAttemptIdentity.same?(context.runtime_attempt_identity, identity)
  end

  test "semantic tool context preserves suspended and incomplete local facts" do
    {state, work_item} = handoff_state()
    contract = contract!()
    {:ok, suspended} = WorkItem.suspend(work_item, :provider_failed)

    graph =
      Graph.build([issue_for("work-1")],
        epoch: :incomplete_epoch,
        completeness: {:incomplete, :relation_read_failed}
      )

    evidence = %ProjectContractEvidence{
      contract: contract,
      reconciliation_required?: true,
      reason: :provider_configuration_drift
    }

    from = {self(), make_ref()}

    state = %{
      state
      | work_control: %{"work-1" => suspended},
        dependency_diagnostics: %{},
        dependency_graph: graph,
        project_contract_evidence: evidence
    }

    assert {:reply, {:ok, context}, _state} =
             Orchestrator.handle_call({:semantic_tool_context, "work-1"}, from, state)

    assert context.work_item == suspended
    assert WorkItem.suspended?(context.work_item)
    refute Map.has_key?(context, :work_control)
    assert context.dependency_blocker_classifications == %{}
    assert context.dependency_decision == nil

    assert context.dependency_epoch_evidence == %{
             epoch: :incomplete_epoch,
             completeness: {:incomplete, :relation_read_failed},
             complete?: false
           }

    assert context.provider_project_contract == contract
    assert context.project_contract_evidence == ProjectContractEvidence.observability(evidence)
  end

  test "semantic tool context reports missing work items" do
    from = {self(), make_ref()}
    state = %Orchestrator.State{}

    assert {:reply, {:error, :work_item_not_found}, _state} =
             Orchestrator.handle_call({:semantic_tool_context, "missing"}, from, state)
  end

  test "semantic tool context reports an unavailable server" do
    server = Module.concat(__MODULE__, "MissingSemanticContextServer#{System.unique_integer([:positive])}")

    assert :unavailable == Orchestrator.semantic_tool_context(server, "work-1")
  end

  test "fails closed when transition context dependencies or authority are unsafe" do
    {state, work_item} = handoff_state()
    from = {self(), make_ref()}

    cases = [
      {%{state | dependency_diagnostics: nil}, :dependency_context_unavailable},
      {%{state | dependency_graph: Graph.unavailable(:provider_timeout)}, :dependency_context_unavailable},
      {%{state | work_control: %{"work-1" => %{work_item | provider_observation: nil}}}, :work_item_context_unavailable},
      {%{
         state
         | project_contract_evidence: %ProjectContractEvidence{
             reconciliation_required?: true,
             reason: :provider_configuration_drift
           }
       }, :provider_configuration_drift}
    ]

    for {unsafe_state, reason} <- cases do
      assert {:reply, {:error, ^reason}, _state} =
               Orchestrator.handle_call({:transition_context, "work-1", []}, from, unsafe_state)
    end

    {:ok, suspended} = WorkItem.suspend(work_item, :provider_failed)
    suspended_state = %{state | work_control: %{"work-1" => suspended}}

    assert {:reply, {:error, :work_item_suspended}, _state} =
             Orchestrator.handle_call({:transition_context, "work-1", []}, from, suspended_state)
  end

  test "guards transition result application and suspension handoffs" do
    {state, work_item} = handoff_state()
    from = {self(), make_ref()}

    assert {:reply, {:error, :work_item_id_mismatch}, _state} =
             Orchestrator.handle_call(
               {:apply_transition_result, "other-work", work_item, []},
               from,
               state
             )

    assert {:reply, :ok, applied_state} =
             Orchestrator.handle_call(
               {:apply_transition_result, "work-1", work_item, []},
               from,
               state
             )

    assert applied_state.work_control["work-1"] == work_item

    assert {:reply, {:error, :context_token_mismatch}, _state} =
             Orchestrator.handle_call(
               {:apply_transition_result, "work-1", work_item, [expected_context_token: "sha256:stale"]},
               from,
               state
             )

    assert {:reply, {:ok, suspended}, suspended_state} =
             Orchestrator.handle_call(
               {:suspend_work_item, "work-1", :provider_failed},
               from,
               state
             )

    assert WorkItem.suspended?(suspended)
    assert suspended_state.work_control["work-1"] == suspended

    escalated = %{
      work_item
      | authority_disposition: AuthorityDisposition.new(%{status: :escalated})
    }

    assert {:reply, {:error, :terminal_disposition}, _state} =
             Orchestrator.handle_call(
               {:suspend_work_item, "work-1", :provider_failed},
               from,
               %{state | work_control: %{"work-1" => escalated}}
             )

    assert {:reply, {:error, :work_item_not_found}, _state} =
             Orchestrator.handle_call({:suspend_work_item, "missing", :provider_failed}, from, state)
  end

  defp handoff_state do
    issue = issue_for("work-1")

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: ~U[2026-09-18 00:00:00Z],
        prior_validated_lifecycle_state: :ready
      })

    state = %Orchestrator.State{
      work_control: %{issue.id => work_item},
      dependency_diagnostics: %{issue.id => %{allowed?: true}},
      dependency_graph: Graph.build([issue])
    }

    {state, work_item}
  end

  defp issue_for(id) when is_binary(id) do
    %Issue{
      id: id,
      identifier: "SYM-#{id}",
      title: "Transition handoff",
      state: "Ready",
      dependency_completeness: :complete
    }
  end

  defp contract! do
    attrs = %{
      schema_version: 1,
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      state_mappings:
        Map.new(@states, fn state ->
          {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
        end)
    }

    {:ok, contract} = ProviderProjectContract.new(attrs)
    contract
  end

  defp snapshot do
    groups = %{
      backlog: :backlog,
      planning: :unstarted,
      ready: :unstarted,
      in_progress: :started,
      in_review: :started,
      changes_requested: :started,
      ready_to_merge: :started,
      merging: :started,
      blocked: :started,
      done: :completed,
      canceled: :cancelled
    }

    %{
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      states:
        Enum.map(@states, fn state ->
          %{id: "state-#{state}", group: Map.fetch!(groups, state), name: WorkflowLifecycle.display(state)}
        end),
      dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
      capability_statuses: Map.new(Capabilities.vocabulary(), &{&1, :supported}),
      completeness: :complete
    }
  end
end
