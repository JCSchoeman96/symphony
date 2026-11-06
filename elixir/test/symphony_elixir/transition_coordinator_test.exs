defmodule SymphonyElixir.TransitionCoordinatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.{AttemptLedger, Profile, Route, RuntimeAttempt}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProjectContractEvidence,
    ProviderProjectContract,
    SemanticTransitionIntent,
    TransitionAttempt,
    TransitionAttemptLedger,
    WorkflowLifecycle
  }

  alias SymphonyElixir.WorkControl.WorkItem

  test "a bare incoming dispatch_guard cannot authorize Ready to In Progress" do
    test_pid = self()

    route = runtime_route(%Issue{id: "work-1", state: "Ready"})

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        runtime_attempt_id: "runtime-bare-dispatch",
        lineage_generation: "lineage-bare-dispatch",
        guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn ^intent ->
          {:ok,
           Map.merge(context(), %{
             current_state: :ready,
             route: route,
             route_fingerprint: route.fingerprint,
             runtime_profile: route.profile_name,
             guard_evidence: intent.guard_evidence
           })}
        end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:ok, %{status: 204}}
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        require_durable?: false
      )

    assert {:ok, attempt} = request_transition(coordinator, intent, route: route)
    assert attempt.state == :rejected
    assert attempt.outcome_reason == :required_guard_missing
    refute_received :submitted
  end

  test "fresh dispatch provenance replaces incoming lookalikes and retains other history" do
    test_pid = self()
    route = runtime_route(%Issue{id: "work-1", state: "Ready"})
    identity = runtime_identity("runtime-current-dispatch", "lineage-current-dispatch")
    fresh_dispatch = dispatch_guard(route, identity)
    forged_dispatch = %{fresh_dispatch | runtime_attempt_id: "runtime-forged-dispatch"}
    historical_guard = %{class: :mechanical_guard, name: :historical_guard, outcome: :verified}

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        guard_evidence: [forged_dispatch]
      })

    fresh_context =
      Map.merge(context(), %{
        current_state: :ready,
        route: route,
        route_fingerprint: route.fingerprint,
        runtime_profile: route.profile_name,
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        responsibility: "implementation",
        guard_evidence: [historical_guard, fresh_dispatch],
        dispatch_authority_evidence: fresh_dispatch
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, fresh_context} end,
        submit: fn attempt, _context ->
          send(test_pid, {:submitted, attempt})
          {:ok, %{status: 204}}
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        require_durable?: false
      )

    assert {:ok, attempt} = request_transition(coordinator, intent, route: route)
    assert attempt.state == :verified
    assert_received {:submitted, submitted_attempt}
    assert submitted_attempt.guard_evidence == [historical_guard, fresh_dispatch]
    assert Enum.count(submitted_attempt.guard_evidence, &match?(%{name: :dispatch_guard}, &1)) == 1
    refute Enum.any?(submitted_attempt.guard_evidence, &(&1 == forged_dispatch))
    GenServer.stop(coordinator)
  end

  test "mismatched fresh dispatch provenance fails before provider submission" do
    test_pid = self()
    route = runtime_route(%Issue{id: "work-1", state: "Ready"})
    identity = runtime_identity("runtime-current-dispatch", "lineage-current-dispatch")
    valid_dispatch = dispatch_guard(route, identity)

    for forged_dispatch <- [
          %{valid_dispatch | runtime_attempt_id: "runtime-stale"},
          %{valid_dispatch | lineage_generation: "lineage-stale"},
          %{valid_dispatch | route_fingerprint: "sha256:wrong-route"},
          %{valid_dispatch | runtime_profile: "wrong-profile"},
          %{valid_dispatch | responsibility: "review"},
          %{valid_dispatch | transition: {:ready, :in_review}},
          %{valid_dispatch | subject: {:work_item, "foreign-work-item"}}
        ] do
      {:ok, intent} =
        SemanticTransitionIntent.new(%{
          work_item_id: "work-1",
          requested_from: :ready,
          requested_to: :in_progress,
          responsibility: "implementation",
          runtime_attempt_id: identity.runtime_attempt_id,
          lineage_generation: identity.lineage_generation,
          guard_evidence: []
        })

      fresh_context =
        Map.merge(context(), %{
          current_state: :ready,
          route: route,
          route_fingerprint: route.fingerprint,
          runtime_profile: route.profile_name,
          runtime_attempt_id: identity.runtime_attempt_id,
          lineage_generation: identity.lineage_generation,
          responsibility: "implementation",
          guard_evidence: [],
          dispatch_authority_evidence: forged_dispatch
        })

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          load_context: fn _intent -> {:ok, fresh_context} end,
          submit: fn _attempt, _context ->
            send(test_pid, :submitted)
            {:ok, %{status: 204}}
          end,
          require_durable?: false
        )

      assert {:ok, %{state: :rejected, outcome_reason: :required_guard_missing}} =
               request_transition(coordinator, intent, route: route)

      refute_received :submitted
      GenServer.stop(coordinator)
    end
  end

  test "caller route cannot replace the missing current Orchestrator route" do
    test_pid = self()
    route = runtime_route(%Issue{id: "work-1", state: "Ready"})
    identity = runtime_identity("runtime-current-dispatch", "lineage-current-dispatch")

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        guard_evidence: []
      })

    fresh_context =
      context()
      |> Map.merge(%{
        route: route,
        route_fingerprint: route.fingerprint,
        runtime_profile: route.profile_name,
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        responsibility: identity.responsibility,
        dispatch_authority_evidence: dispatch_guard(route, identity)
      })
      |> Map.delete(:route)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, fresh_context} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:ok, %{status: 204}}
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :rejected, outcome_reason: :required_guard_missing}} =
             request_transition(coordinator, intent, route: route)

    refute_received :submitted
    GenServer.stop(coordinator)
  end

  test "refuses a provider mutation when no durable ledger is available" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end
      )

    assert {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert {:error, :transitions_disabled} =
             request_transition(coordinator, intent)

    refute_received :submitted
  end

  test "cleans up unavailable claims and keeps an active item claimed" do
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    unavailable_server = String.to_atom("missing-transition-coordinator-#{System.unique_integer([:positive])}")

    assert {:error, :invalid_request_options} =
             request_transition(unavailable_server, intent, :invalid_options)

    assert {:error, :coordinator_unavailable} =
             request_transition(unavailable_server, intent)

    assert {:error, :coordinator_unavailable} =
             request_transition(unavailable_server, intent)

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.list_reconciliation_candidates(unavailable_server)

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.sync_reconciliation_ledger(unavailable_server)

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.reconciliation_marker_for_work_item(unavailable_server, "work-1")

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.reconcile_candidate(unavailable_server, %{}, :verified, "evidence")

    assert {:error, :invalid_work_item_id} =
             TransitionCoordinator.reconciliation_marker_for_work_item(unavailable_server, nil)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end
      )

    :sys.replace_state(coordinator, fn state ->
      %{state | active_work_items: MapSet.put(state.active_work_items, intent.work_item_id)}
    end)

    assert {:error, :transitions_disabled} =
             TransitionCoordinator.reconciliation_marker_for_work_item(coordinator, intent.work_item_id)

    assert {:error, :transitions_disabled} = TransitionCoordinator.sync_reconciliation_ledger(coordinator)

    assert {:error, :transitions_disabled} =
             TransitionCoordinator.reconcile_candidate(coordinator, %{}, :verified, "evidence")

    assert {:error, {:reconciliation_marker, :invalid_marker_attributes}} =
             TransitionCoordinator.reconcile_candidate(coordinator, %{}, %{})

    assert {:error, :transition_in_progress} = request_transition(coordinator, intent)
    GenServer.stop(coordinator)
  end

  test "normalizes an invalid semantic intent struct before execution" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(name: nil, ledger: nil, require_durable?: false)

    {:ok, valid} = SemanticTransitionIntent.new(intent_attrs())
    invalid = %{valid | requested_to: :done}

    assert {:error, {:rejected, :invalid_transition}} =
             request_transition(coordinator, invalid)
  end

  test "does not start with an unreadable attempt ledger" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-corrupt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}, path: path)

    assert :ok = :dets.insert(ledger.table, {{:attempt, "corrupt"}, %{status: :indeterminate}})
    assert :ok = :dets.insert(ledger.table, {{:unknown, "corrupt"}, :unexpected})
    assert :ok = :dets.sync(ledger.table)
    assert :ok = TransitionAttemptLedger.close(ledger)

    assert {:ok, coordinator} =
             TransitionCoordinator.start_link(
               name: nil,
               project_id: "project-a",
               tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
               ledger_opts: [path: path],
               submit: fn _attempt, _context ->
                 send(self(), :submitted)
                 :ok
               end
             )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:error, :transitions_disabled} = request_transition(coordinator, intent)

    refute_received :submitted
  end

  test "keeps transitions disabled when a persisted reconciliation marker is malformed" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-marker-corrupt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", identity, path: path)
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    candidate = prepared_attempt(intent)
    assert :ok = TransitionAttemptLedger.put_sync(ledger, candidate)

    malformed = %{
      schema_version: 1,
      marker_type: :transition_reconciliation,
      project_namespace: "project-a",
      attempt_id: candidate.attempt_id,
      work_item_id: "other-work",
      outcome: :verified,
      evidence_identity: "provider-observation-1",
      reconciled_at: ~U[2026-09-23 10:00:00Z]
    }

    assert :ok = :dets.insert(ledger.table, {{:reconciliation, candidate.attempt_id}, malformed})
    assert :ok = :dets.sync(ledger.table)
    assert :ok = TransitionAttemptLedger.close(ledger)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: identity,
        ledger_opts: [path: path],
        load_context: fn _intent -> {:ok, context()} end
      )

    state = :sys.get_state(coordinator)
    assert state.transition_disabled?
    assert {:error, :transitions_disabled} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    GenServer.stop(coordinator)
  end

  test "rejects an unauthorized responsibility before loading provider context" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent ->
          send(test_pid, :context_loaded)
          {:ok, context()}
        end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        require_durable?: false
      )

    assert {:ok, %{state: :rejected}} =
             request_transition(coordinator, %{
               work_item_id: "work-1",
               requested_from: :ready,
               requested_to: :in_progress,
               responsibility: "review",
               guard_evidence: []
             })

    refute_received :context_loaded
    refute_received :submitted
  end

  test "fresh source movement is Conflict and never reaches the provider" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, Map.put(context(), :current_state, :in_progress)} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :conflict}} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "pre-submit failures never reach the provider" do
    cases = [
      {:context_unavailable, {:error, :transport}, :provider_failed},
      {:missing_dependency, {:ok, Map.delete(context(), :dependency_decision)}, :rejected},
      {:missing_guard, {:ok, context() |> Map.put(:guard_evidence, []) |> Map.put(:dispatch_authority_evidence, nil)}, :rejected},
      {:non_canonical_source, {:ok, Map.put(context(), :current_state, "Ready")}, :rejected},
      {:contract_drift, {:ok, Map.put(context(), :provider_contract_fingerprint, "sha256:old")}, :rejected},
      {:dependency_denied, {:ok, Map.put(context(), :dependency_decision, %{allowed?: false})}, :rejected},
      {:contract_missing, {:ok, Map.delete(context(), :provider_project_contract)}, :provider_failed}
    ]

    for {_name, load_result, expected_state} <- cases do
      test_pid = self()

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          load_context: fn _intent -> load_result end,
          submit: fn _attempt, _context ->
            send(test_pid, :submitted)
            :ok
          end,
          verify: fn _attempt, _context -> {:verified, verified_context()} end,
          suspend: fn _work_item_id, _reason, _attempt -> :ok end,
          require_durable?: false
        )

      {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
      assert {:ok, %{state: ^expected_state}} = request_transition(coordinator, intent)
      refute_received :submitted
    end
  end

  test "classifies a canonical suspension source failure before mutation" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        load_context: fn _intent -> {:error, :work_item_suspended} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    assert {:ok, %{state: :rejected}} =
             request_transition(coordinator, intent_attrs())
  end

  test "rejects a target missing from the trusted project contract" do
    test_pid = self()
    incomplete = %{context() | provider_project_contract: %{contract() | state_mappings: Map.delete(contract().state_mappings, :in_progress)}}

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, incomplete} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :rejected}} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "fences an ambiguous submission and never resubmits it" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-coordinator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}, path: path)

    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:error, :timeout}
        end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, attempt} = request_transition(coordinator, intent)
    assert attempt.state == :indeterminate
    assert_received :submitted

    assert {:error, :transition_fenced} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "rejects stale runtime intent through the live orchestrator before another provider submission" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-runtime-boundary-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    workflow_path = Path.join(root, "WORKFLOW.md")
    attempt_root = Path.join(root, "attempt-ledgers")
    transition_path = Path.join(root, "transitions.dets")
    runtime_path = Path.join(root, "runtime.dets")
    recovery_path = Path.join(root, "recovery.dets")
    ownership_path = Path.join(root, "ownership.dets")
    workspace_root = Path.join(root, "workspaces")
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_attempt_root = Application.get_env(:symphony_elixir, :attempt_ledger_root)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn -> File.rm_rf(root) end)

    :ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    :ok =
      SymphonyElixir.TestSupport.write_workflow_file!(workflow_path,
        tracker_kind: "memory",
        symphony_project_id: "project-a",
        workspace_root: workspace_root
      )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, attempt_root)

    on_exit(fn ->
      restore_application_env(:workflow_file_path, previous_workflow_path)
      restore_application_env(:attempt_ledger_root, previous_attempt_root)
      restore_application_env(:memory_tracker_issues, previous_memory_issues)
    end)

    issue = %Issue{
      id: "work-1",
      identifier: "SYM-1",
      title: "Runtime transition boundary",
      state: "Ready",
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      dependency_completeness: :complete,
      updated_at: DateTime.utc_now()
    }

    provider_contract = contract()

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :ready,
        provider_project_contract: provider_contract,
        evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
      })

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    tracker_identity = SymphonyElixir.Tracker.identity(SymphonyElixir.Config.settings!().tracker)

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: nil,
        start_quiesced: true,
        attempt_ledger_opts: [path: runtime_path],
        recovery_ledger_opts: [path: recovery_path],
        workspace_ownership_ledger_opts: [path: ownership_path]
      )

    on_exit(fn ->
      if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
    end)

    runtime_ledger = :sys.get_state(orchestrator).attempt_ledger
    assert %AttemptLedger{} = runtime_ledger

    route = runtime_route(issue)

    {:ok, old_runtime_record} =
      AttemptLedger.begin_attempt(runtime_ledger, issue.id, route_fingerprint: route.fingerprint)

    old_identity = runtime_identity("runtime-old", old_runtime_record.lineage_id)
    {:ok, _old_runtime_record} = AttemptLedger.bind_runtime_attempt(runtime_ledger, issue.id, old_identity)

    replace_runtime_context(orchestrator, issue, work_item, provider_contract, old_identity)

    {:ok, submissions} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(submissions), do: Agent.stop(submissions) end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: tracker_identity,
        ledger_opts: [path: transition_path],
        orchestrator: orchestrator,
        refresh_contract: fn context -> {:ok, context.provider_project_contract} end,
        submit: fn _attempt, _context ->
          Agent.update(submissions, &(&1 + 1))
          {:error, :timeout}
        end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    {:ok, old_intent} =
      SemanticTransitionIntent.new(
        Map.merge(intent_attrs(), %{
          responsibility: "implementation",
          runtime_attempt_id: old_identity.runtime_attempt_id,
          lineage_generation: old_identity.lineage_generation
        })
      )

    assert {:ok, %{state: :indeterminate} = old_attempt} =
             request_transition(coordinator, old_intent, route: route)

    assert Agent.get(submissions, & &1) == 1
    assert {:ok, [candidate]} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    assert candidate.attempt_id == old_attempt.attempt_id

    assert :ok = AttemptLedger.release_authority_fence(runtime_ledger, issue.id, old_identity)
    assert :ok = AttemptLedger.clear_in_flight(runtime_ledger, issue.id)

    {:ok, new_runtime_record} =
      AttemptLedger.begin_attempt(runtime_ledger, issue.id, route_fingerprint: route.fingerprint)

    new_identity = runtime_identity("runtime-new", new_runtime_record.lineage_id)
    {:ok, _new_runtime_record} = AttemptLedger.bind_runtime_attempt(runtime_ledger, issue.id, new_identity)

    replace_runtime_context(orchestrator, issue, work_item, provider_contract, new_identity)

    assert {:error, :transition_fenced} =
             request_transition(coordinator, old_intent, route: route)

    assert Agent.get(submissions, & &1) == 1

    assert {:ok, _marker} =
             TransitionCoordinator.reconcile_candidate(
               coordinator,
               candidate,
               :conflict,
               "old-runtime-reconciled"
             )

    submissions_before_stale_attempt = Agent.get(submissions, & &1)

    assert {:ok, %{state: :rejected} = stale_attempt} =
             request_transition(coordinator, old_intent, route: route)

    assert stale_attempt.outcome_reason == {:context_unavailable, :stale_runtime_attempt}
    assert Agent.get(submissions, & &1) == submissions_before_stale_attempt

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^new_identity}}} =
             AttemptLedger.current(runtime_ledger, issue.id)

    {:ok, current_intent} =
      SemanticTransitionIntent.new(
        Map.merge(intent_attrs(), %{
          responsibility: "implementation",
          runtime_attempt_id: new_identity.runtime_attempt_id,
          lineage_generation: new_identity.lineage_generation
        })
      )

    assert {:ok, %{state: :indeterminate}} =
             request_transition(coordinator, current_intent, route: route)

    assert Agent.get(submissions, & &1) == 2

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^new_identity}}} =
             AttemptLedger.current(runtime_ledger, issue.id)
  end

  test "reopening a ledger with a persisted ambiguous attempt blocks a second submission" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-reopen-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, submissions} = Agent.start_link(fn -> 0 end)
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}

    coordinator_opts = [
      name: nil,
      project_id: "project-a",
      tracker_identity: identity,
      ledger_opts: [path: path],
      load_context: fn _intent -> {:ok, context()} end,
      submit: fn _attempt, _context ->
        Agent.update(submissions, &(&1 + 1))
        {:error, :timeout}
      end,
      verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
      suspend: fn _work_item_id, _reason, _attempt -> :ok end
    ]

    {:ok, first} = TransitionCoordinator.start_link(coordinator_opts)
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :indeterminate}} = request_transition(first, intent)
    assert Agent.get(submissions, & &1) == 1
    assert :ok = GenServer.stop(first)

    {:ok, second} = TransitionCoordinator.start_link(coordinator_opts)
    assert {:error, :transition_fenced} = request_transition(second, intent)
    assert Agent.get(submissions, & &1) == 1
  end

  test "reopening a ledger with an ordinary Prepared marker blocks submission" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-prepared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", identity, path: path)
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    {:ok, attempt} = TransitionAttempt.new(Map.from_struct(intent))
    {:ok, attempt} = TransitionAttempt.authorize_intent(attempt, intent)
    {:ok, attempt} = TransitionAttempt.fresh_context_loaded(attempt, context())

    prepare_context =
      context()
      |> Map.merge(%{
        workspace_id: "workspace-1",
        project_id: "project-1",
        target_provider_state_id: "state-in-progress",
        target_provider_state_group: :started,
        provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
      })

    {:ok, prepared} = TransitionAttempt.prepare(attempt, prepare_context)
    assert :ok = TransitionAttemptLedger.put_sync(ledger, prepared)
    assert :ok = TransitionAttemptLedger.close(ledger)

    {:ok, submissions} = Agent.start_link(fn -> 0 end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: identity,
        ledger_opts: [path: path],
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          Agent.update(submissions, &(&1 + 1))
          :ok
        end
      )

    assert {:error, :transition_fenced} = request_transition(coordinator, intent)
    assert Agent.get(submissions, & &1) == 0
  end

  test "reconciles one candidate durably and releases only its work-item fence" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-reconcile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", identity, path: path)
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    candidate = prepared_attempt(intent)
    assert :ok = TransitionAttemptLedger.put_sync(ledger, candidate)
    assert :ok = TransitionAttemptLedger.close(ledger)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: identity,
        ledger_opts: [path: path],
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> send(self(), :submitted) end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end
      )

    assert {:ok, [listed]} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    assert listed.attempt_id == candidate.attempt_id

    assert {:ok, marker} =
             TransitionCoordinator.reconcile_candidate(
               coordinator,
               listed,
               :verified,
               "provider-observation-1",
               ~U[2026-09-23 10:00:00Z]
             )

    assert marker.work_item_id == intent.work_item_id
    state = :sys.get_state(coordinator)
    refute MapSet.member?(state.fenced_work_items, intent.work_item_id)
    assert {:ok, []} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    refute_received :submitted
    GenServer.stop(coordinator)
  end

  test "keeps a work-item fenced while another unresolved candidate remains" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-reconcile-many-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", identity, path: path)
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    first = prepared_attempt(intent)
    second = prepared_attempt(intent)
    assert first.attempt_id != second.attempt_id
    assert :ok = TransitionAttemptLedger.put_sync(ledger, first)
    assert :ok = TransitionAttemptLedger.put_sync(ledger, second)
    assert :ok = TransitionAttemptLedger.close(ledger)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: identity,
        ledger_opts: [path: path],
        load_context: fn _intent -> {:ok, context()} end
      )

    assert {:ok, candidates} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    assert Enum.map(candidates, & &1.attempt_id) |> Enum.sort() == Enum.sort([first.attempt_id, second.attempt_id])

    assert {:ok, _marker} =
             TransitionCoordinator.reconcile_candidate(
               coordinator,
               first,
               :verified,
               "provider-observation-1",
               ~U[2026-09-23 10:00:00Z]
             )

    state = :sys.get_state(coordinator)
    assert MapSet.member?(state.fenced_work_items, intent.work_item_id)
    assert {:ok, [remaining]} = TransitionCoordinator.list_reconciliation_candidates(coordinator)
    assert remaining.attempt_id == second.attempt_id
    GenServer.stop(coordinator)
  end

  test "rejects a concurrent request before the first provider call completes" do
    test_pid = self()
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :first_submit_started)

          receive do
            :release_first_submit -> :ok
          end
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        require_durable?: false
      )

    first = Task.async(fn -> request_transition(coordinator, intent) end)
    assert_receive :first_submit_started

    assert {:error, :transition_in_progress} =
             Task.await(Task.async(fn -> request_transition(coordinator, intent) end))

    send(coordinator, :release_first_submit)
    assert {:ok, %{state: :verified}} = Task.await(first)
  end

  test "fences after a post-submit terminal durability failure" do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    root = Path.join(System.tmp_dir!(), "symphony-transition-durability-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, initialized} =
      TransitionAttemptLedger.open("project-a", %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}, path: path)

    ledger = %{
      initialized
      | write_fun: fn _table, _records ->
          count = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
          if count == 5, do: {:error, :disk_full}, else: :ok
        end,
        sync_fun: fn _table -> :ok end
    }

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert {:error, {:durability_failed, {:ledger_write_failed, :disk_full}}} =
             request_transition(coordinator, intent)

    assert_received :submitted
    assert {:error, :transition_fenced} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "does not report an unsafe outcome when canonical suspension fails" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> {:error, :timeout} end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
        suspend: fn _work_item_id, _reason, _attempt -> {:error, :authority_unavailable} end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert {:error, {:suspension_failed, :authority_unavailable}} =
             request_transition(coordinator, intent)

    assert {:error, :transitions_disabled} =
             request_transition(coordinator, intent)
  end

  test "a Prepared ledger write failure issues zero provider mutations" do
    test_pid = self()
    {ledger, path} = failing_ledger(:write)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:error, _reason} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "a Prepared ledger sync failure issues zero provider mutations" do
    test_pid = self()
    {ledger, path} = failing_ledger(:sync)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:error, _reason} = request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "routes a proven connection refusal through verification before ProviderFailed" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> {:error, :econnrefused} end,
        verify: fn attempt, context ->
          send(test_pid, {:verification_result, context.provider_non_commit?})
          {:provider_failed, provider_failed_evidence(attempt, :connection_refused)}
        end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :provider_failed}} = request_transition(coordinator, intent)
    assert_received {:verification_result, true}
  end

  test "classifies authoritative incompatible movement as Conflict only with non-commit evidence" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> {:ok, %{status: 202}} end,
        verify: fn _attempt, _context ->
          {:conflict,
           %{
             non_commit?: true,
             reason: :incompatible_concurrent_movement,
             assessment: %{status: :invalid, work_item_id: "work-1", mapped_state: :canceled},
             post_observation_evidence: %{
               workspace_id: "workspace-1",
               project_id: "project-1",
               work_item_id: "work-1",
               provider_state_id: "state-canceled",
               observed_at: DateTime.utc_now()
             },
             post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
           }}
        end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :conflict}} = request_transition(coordinator, intent)
  end

  test "never turns a weak verification callback into Verified" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> :ok end,
        verify: fn _attempt, _context -> {:verified, %{status: :verified}} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        require_durable?: false
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :indeterminate}} = request_transition(coordinator, intent)
  end

  test "rejects malformed intents and unavailable coordinator calls" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end
      )

    assert {:error, {:rejected, :invalid_intent}} = request_transition(coordinator, :invalid)

    assert {:error, {:rejected, :invalid_intent_field}} =
             request_transition(coordinator, %{unexpected: true})

    assert :ok = GenServer.stop(coordinator)
    assert {:error, :coordinator_unavailable} = request_transition(coordinator, intent_attrs())
  end

  test "initialization fails closed for invalid callbacks and ledgers" do
    assert {:error, {:invalid_callback, :submit}} =
             GenServer.start(TransitionCoordinator, [ledger: nil, require_durable?: false, submit: :invalid], [])

    assert {:error, {:ledger_unavailable, :invalid_ledger}} =
             GenServer.start(TransitionCoordinator, [ledger: :invalid, require_durable?: false], [])
  end

  test "keeps optional durability disabled when configured ledger opening fails" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-open-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    blocker = Path.join(root, "blocker")
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, coordinator} =
             TransitionCoordinator.start_link(
               name: nil,
               project_id: "project-a",
               tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
               ledger_opts: [path: Path.join(blocker, "attempts.dets")],
               require_durable?: false
             )

    assert {:ok, %{state: :provider_failed}} =
             request_transition(coordinator, intent_attrs())
  end

  test "normalizes callbacks with unsupported arities" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context, _extra -> :ok end,
        verify: fn _attempt, _context, _extra -> {:verified, verified_context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :indeterminate}} =
             request_transition(coordinator, intent_attrs())
  end

  test "accepts structured verification responses wrapped in an ok tuple" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> :ok end,
        verify: fn _attempt, _context -> {:ok, Map.put(verified_context(), :status, :verified)} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :verified}} =
             request_transition(coordinator, intent_attrs())
  end

  test "fails closed when required durability is lost after initialization" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    :sys.replace_state(coordinator, fn state ->
      %{state | ledger: nil, require_durable?: true, transition_disabled?: false}
    end)

    assert {:error, {:durability_failed, :ledger_unavailable}} =
             request_transition(coordinator, intent_attrs())
  end

  test "reports a configured durable ledger opening failure when durability is required" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-required-open-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    blocker = Path.join(root, "blocker")
    File.write!(blocker, "not a directory")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, {:ledger_unavailable, {:ledger_directory_failed, _reason}}} =
             GenServer.start(
               TransitionCoordinator,
               [
                 name: nil,
                 project_id: "project-a",
                 tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
                 ledger_opts: [path: Path.join(blocker, "attempts.dets")]
               ],
               []
             )
  end

  test "handles unavailable and malformed default orchestrator contexts" do
    {:ok, unavailable} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: :unavailable)

    for orchestrator <- [unavailable, make_ref()] do
      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          orchestrator: orchestrator,
          require_durable?: false
        )

      assert {:ok, %{state: :provider_failed}} =
               request_transition(coordinator, intent_attrs())
    end

    GenServer.stop(unavailable)
  end

  test "handles a default context without a trusted contract" do
    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, Map.delete(context(), :provider_project_contract)})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} =
             request_transition(coordinator, intent_attrs())
  end

  test "fails closed when verification durability fails after the submission fence" do
    for suspend_result <- [{:ok, :suspended}, {:error, :authority_unavailable}, :unavailable, :unexpected] do
      {ledger, root, counter} = post_submission_sync_failure_ledger()

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: ledger,
          load_context: fn _intent -> {:ok, context()} end,
          submit: fn _attempt, _context -> :ok end,
          verify: fn _attempt, _context -> {:verified, verified_context()} end,
          suspend: fn _work_item_id, _reason, _attempt -> suspend_result end
        )

      assert {:error, {:durability_failed, {:ledger_sync_failed, :sync_failed}}} =
               request_transition(coordinator, intent_attrs())

      GenServer.stop(coordinator)
      Agent.stop(counter)
      File.rm_rf(root)
    end
  end

  test "durably records the submitted request identity before the provider callback" do
    parent = self()
    {ledger, root, _counter} = observed_submission_ledger(parent, nil)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn attempt, context ->
          send(parent, {:provider_callback, attempt, Map.get(context, :provider_mutation_envelope)})
          :ok
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end
      )

    assert {:ok, %{state: :verified}} = request_transition(coordinator, intent_attrs())

    assert_receive {:ledger_write, %{state: :prepared, submission_fenced_at: nil}}
    assert_receive :ledger_sync
    assert_receive {:ledger_write, %{state: :prepared, submission_fenced_at: %DateTime{}}}
    assert_receive :ledger_sync

    assert_receive {:ledger_write, %{state: :mutation_submitted, status: :submitted, provider_request_id: request_id}}

    assert TransitionAttempt.valid_provider_request_id?(request_id)
    assert_receive :ledger_sync

    assert_receive {:provider_callback, %{state: :mutation_submitted, provider_request_id: ^request_id},
                    %{
                      provider_request_id: ^request_id,
                      transition_attempt_id: attempt_id,
                      work_item_id: "work-1"
                    }}

    assert attempt_id != ""

    GenServer.stop(coordinator)
    File.rm_rf(root)
  end

  test "blocks provider dispatch when submitted attempt write or sync fails" do
    for failure <- [:write, :sync] do
      parent = self()
      {ledger, root, _counter} = observed_submission_ledger(parent, failure)

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: ledger,
          load_context: fn _intent -> {:ok, context()} end,
          submit: fn _attempt, _context ->
            send(parent, :provider_callback)
            :ok
          end,
          verify: fn _attempt, _context ->
            send(parent, :verify_callback)
            {:verified, verified_context()}
          end,
          suspend: fn _work_item_id, _reason, _attempt -> :ok end
        )

      assert {:error, {:durability_failed, _reason}} = request_transition(coordinator, intent_attrs())
      refute_received :provider_callback
      refute_received :verify_callback

      assert {:ok, attempt} = TransitionAttemptLedger.latest_for_work_item(ledger, "work-1")
      assert TransitionAttempt.submission_fenced?(attempt)
      refute TransitionAttemptLedger.resubmit_allowed?(attempt)

      GenServer.stop(coordinator)
      File.rm_rf(root)
    end
  end

  test "validates required dispatch witness configuration at startup" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :dispatch_witness_sink_required} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: nil,
               require_durable?: false,
               dispatch_witness_required?: true
             )

    assert {:error, :custom_submit_disallowed_with_required_dispatch_witness} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: nil,
               require_durable?: false,
               dispatch_witness_required?: true,
               dispatch_witness_sink: fn _witness -> {:ok, "preq_00000000-0000-4000-8000-000000000001"} end,
               submit: fn _attempt, _context -> :ok end
             )

    assert {:error, :custom_verify_disallowed_with_required_dispatch_witness} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: nil,
               require_durable?: false,
               dispatch_witness_required?: true,
               dispatch_witness_sink: fn _witness -> {:ok, "preq_00000000-0000-4000-8000-000000000001"} end,
               verify: fn _attempt, _context -> {:verified, %{}} end
             )

    sink = fn _witness -> {:ok, "preq_00000000-0000-4000-8000-000000000001"} end

    for timeout_ms <- [0, -1, 5_001, "25"] do
      result =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          require_durable?: false,
          dispatch_witness_required?: true,
          dispatch_witness_sink: sink,
          dispatch_witness_timeout_ms: timeout_ms
        )

      case result do
        {:ok, coordinator} -> GenServer.stop(coordinator)
        {:error, _reason} -> :ok
      end

      assert result == {:error, {:invalid_dispatch_witness_timeout, timeout_ms}}
    end

    assert {:error, :dispatch_witness_requires_durable_ledger} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: nil,
               require_durable?: false,
               dispatch_witness_required?: true,
               dispatch_witness_sink: sink
             )

    assert {:error, :dispatch_witness_durable_ledger_required} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: nil,
               require_durable?: true,
               dispatch_witness_required?: true,
               dispatch_witness_sink: sink
             )

    root = Path.join(System.tmp_dir!(), "symphony-required-witness-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, ledger} =
      TransitionAttemptLedger.open(
        "project-a",
        %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
        path: Path.join(root, "attempts.dets")
      )

    assert {:ok, coordinator} =
             TransitionCoordinator.start_link(
               name: nil,
               ledger: ledger,
               dispatch_witness_required?: true,
               dispatch_witness_sink: sink,
               dispatch_witness_timeout_ms: 25
             )

    assert :sys.get_state(coordinator).dispatch_witness_timeout_ms == 25
    assert :ok = GenServer.stop(coordinator)

    assert {:error, :dispatch_witness_ledger_callbacks_must_be_durable} =
             TransitionCoordinator.start_link(
               name: nil,
               project_id: "project-a",
               tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
               ledger_opts: [
                 path: Path.join(root, "custom-callbacks.dets"),
                 write_fun: fn table, records -> :dets.insert(table, records) end,
                 sync_fun: fn table -> :dets.sync(table) end
               ],
               dispatch_witness_required?: true,
               dispatch_witness_sink: sink
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "dispatch witness timeout leaves the durable attempt fenced and coordinator responsive" do
    timeout_ms = 25
    parent = self()
    root = Path.join(System.tmp_dir!(), "symphony-witness-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    ledger_path = Path.join(root, "attempts.dets")
    ledger_identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", ledger_identity, path: ledger_path)
    on_exit(fn -> TransitionAttemptLedger.close(ledger) end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    finch_observer =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 200) do
          {:ok, socket} ->
            send(parent, :finch_invoked)
            :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            :gen_tcp.close(socket)
            :finch_invoked

          {:error, :timeout} ->
            :no_finch_invocation
        end
      end)

    sink = fn witness ->
      send(parent, {:sink_worker, self(), witness.provider_request_id})

      receive do
        :release -> {:ok, witness.provider_request_id}
      after
        75 -> {:ok, witness.provider_request_id}
      end
    end

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, submission_context ->
          send(parent, :submit_called)
          envelope = submission_context.provider_mutation_envelope

          result =
            Client.update_work_item_state(
              %{
                base_url: "http://127.0.0.1:#{port}",
                workspace_slug: "workspace-1",
                workspace_id: envelope.workspace_id,
                project_id: envelope.project_id,
                api_key: "test-only"
              },
              envelope.work_item_id,
              envelope.target_provider_state_id,
              provider_mutation_envelope: envelope,
              dispatch_witness_sink: sink,
              dispatch_witness_required?: true,
              dispatch_witness_timeout_ms: timeout_ms,
              request_fun: nil
            )

          send(parent, {:submit_result, result})
          result
        end,
        verify: fn _attempt, verification_context ->
          send(parent, {:verify_result, verification_context.provider_result})
          {:error, :verification_unavailable}
        end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end,
        dispatch_witness_sink: sink,
        dispatch_witness_timeout_ms: timeout_ms
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    request = Task.async(fn -> request_transition(coordinator, intent_attrs()) end)

    assert_receive {:sink_worker, worker_pid, request_id}
    assert_received :submit_called
    assert {:ok, submitted} = TransitionAttemptLedger.latest_for_work_item(ledger, "work-1")
    assert submitted.state == :mutation_submitted
    assert submitted.provider_request_id == request_id
    refute TransitionAttemptLedger.resubmit_allowed?(submitted)

    assert {:ok, %{state: :indeterminate}} = Task.await(request, 1_000)
    assert_received {:submit_result, {:error, {:dispatch_witness_failed, :sink_timeout}}}
    assert_received {:verify_result, {:error, {:dispatch_witness_failed, :sink_timeout}}}
    refute Process.alive?(worker_pid)

    assert :no_finch_invocation = Task.await(finch_observer, 300)
    assert :ok = TransitionCoordinator.sync_reconciliation_ledger(coordinator)
    assert {:ok, reconciled} = TransitionAttemptLedger.latest_for_work_item(ledger, "work-1")
    assert reconciled.provider_request_id == request_id
    refute TransitionAttemptLedger.resubmit_allowed?(reconciled)
    assert {:error, :transition_fenced} = request_transition(coordinator, intent_attrs())
    refute_received :submit_called
  end

  test "treats a missing suspension callback as an explicit no-op only after fencing" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> {:error, :timeout} end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    :sys.replace_state(coordinator, fn state -> %{state | suspend: nil} end)

    assert {:ok, %{state: :indeterminate}} =
             request_transition(coordinator, intent_attrs())
  end

  test "fences a definite provider failure carrying a durability reason" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> :ok end,
        verify: fn _attempt, _context -> {:provider_failed, {:durability_failed, :late_sync}, :non_commit} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :indeterminate}} =
             request_transition(coordinator, intent_attrs())
  end

  test "reports terminal rejection when its durable record cannot be synced" do
    {ledger, root, counter} = always_failing_sync_ledger()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, Map.put(context(), :guard_evidence, [])} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:error, {:durability_failed, {:ledger_sync_failed, :sync_failed}}} =
             request_transition(coordinator, intent_attrs())

    GenServer.stop(coordinator)
    Agent.stop(counter)
    File.rm_rf(root)
  end

  test "verification classification remains conservative for weak callback results" do
    results = [
      :verified,
      {:verified, :ok},
      {:ok, :verified},
      {:conflict, :unproven},
      {:provider_failed, :unproven},
      {:provider_failed, %{reason: :ambiguous}},
      {:indeterminate, %{reason: :unknown}},
      {:unexpected, :shape}
    ]

    for result <- results do
      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          require_durable?: false,
          load_context: fn _intent -> {:ok, context()} end,
          submit: fn _attempt, _context -> :ok end,
          verify: fn _attempt, _context -> result end,
          suspend: fn _work_item_id, _reason, _attempt -> :ok end
        )

      assert {:ok, %{state: :indeterminate}} = request_transition(coordinator, intent_attrs())
      GenServer.stop(coordinator)
    end

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> :ok end,
        verify: fn _attempt, _context -> {:provider_failed, %{non_commit?: true, reason: :definite}} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :indeterminate}} = request_transition(coordinator, intent_attrs())
  end

  test "fences a contradictory verified envelope when its authoritative assessment is Conflict" do
    test_pid = self()
    {:ok, submissions} = Agent.start_link(fn -> 0 end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          Agent.update(submissions, &(&1 + 1))
          :ok
        end,
        verify: fn _attempt, _context ->
          {:verified,
           %{
             assessment: %{status: :conflict, work_item_id: "work-1", mapped_state: :canceled},
             post_observation_evidence: %{
               workspace_id: "workspace-1",
               project_id: "project-1",
               work_item_id: "work-1",
               provider_state_id: "state-canceled",
               observed_at: DateTime.utc_now()
             },
             post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
           }}
        end,
        suspend: fn _work_item_id, reason, _attempt ->
          send(test_pid, {:suspended, reason})
          :ok
        end
      )

    assert {:ok, %{state: :conflict}} = request_transition(coordinator, intent_attrs())
    assert_received {:suspended, :conflict}
    assert Agent.get(submissions, & &1) == 1
    assert {:error, :transition_fenced} = request_transition(coordinator, intent_attrs())
    assert Agent.get(submissions, & &1) == 1
  end

  test "suspension outcomes fail closed regardless of callback shape" do
    {:ok, accepted} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context -> {:error, :timeout} end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
        suspend: fn _work_item_id, _reason, _attempt -> {:ok, :suspended} end
      )

    assert {:ok, %{state: :indeterminate}} = request_transition(accepted, intent_attrs())
    GenServer.stop(accepted)

    for suspend_result <- [:unavailable, :unexpected] do
      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          require_durable?: false,
          load_context: fn _intent -> {:ok, context()} end,
          submit: fn _attempt, _context -> {:error, :timeout} end,
          verify: fn _attempt, _context -> {:error, :verification_unavailable} end,
          suspend: fn _work_item_id, _reason, _attempt -> suspend_result end
        )

      assert {:error, {:suspension_failed, _reason}} =
               request_transition(coordinator, intent_attrs())

      GenServer.stop(coordinator)
    end
  end

  test "callback arities and callback failures are normalized" do
    {:ok, one_arg} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt -> :ok end,
        verify: fn _attempt -> {:error, :unavailable} end,
        suspend: fn _work_item_id -> :ok end
      )

    assert {:ok, %{state: :indeterminate}} = request_transition(one_arg, intent_attrs())
    GenServer.stop(one_arg)

    {:ok, zero_arg} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn -> {:ok, context()} end,
        submit: fn -> :ok end,
        verify: fn -> {:error, :unavailable} end,
        suspend: fn -> :ok end
      )

    assert {:ok, %{state: :indeterminate}} = request_transition(zero_arg, intent_attrs())
    GenServer.stop(zero_arg)

    {:ok, failing} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> raise "load failed" end
      )

    assert {:ok, %{state: :provider_failed}} = request_transition(failing, intent_attrs())
    GenServer.stop(failing)
  end

  test "normalizes malformed context and provider acknowledgement results" do
    {:ok, malformed_context} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> :not_a_context end
      )

    assert {:ok, %{state: :provider_failed}} =
             request_transition(malformed_context, intent_attrs())

    GenServer.stop(malformed_context)

    {:ok, malformed_target} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, Map.put(context(), :provider_project_contract, :invalid)} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :rejected}} = request_transition(malformed_target, intent_attrs())
    GenServer.stop(malformed_target)

    for verification <- [{:conflict, :known, :non_commit}, {:provider_failed, :definite, :non_commit}] do
      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          require_durable?: false,
          load_context: fn _intent -> {:ok, context()} end,
          submit: fn _attempt, _context -> :unexpected_ack end,
          verify: fn _attempt, _context -> verification end,
          suspend: fn _work_item_id, _reason, _attempt -> :ok end
        )

      assert {:ok, %{state: :indeterminate}} =
               request_transition(coordinator, intent_attrs())

      GenServer.stop(coordinator)
    end

    {:ok, bad_clock} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        clock: fn -> :invalid_timestamp end,
        load_context: fn _intent -> {:error, :context_unavailable} end
      )

    assert {:error, {:rejected, {:new_attempt_failed, :invalid_timestamp}}} =
             request_transition(bad_clock, intent_attrs())

    GenServer.stop(bad_clock)
  end

  test "pre-submit context classifications remain distinct" do
    for {load_result, expected} <- [
          {{:error, :source_state_changed}, :conflict},
          {{:error, :provider_contract_drift}, :rejected},
          {{:error, {:fresh_context_unavailable, :timeout}}, :provider_failed}
        ] do
      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          require_durable?: false,
          load_context: fn _intent -> load_result end,
          submit: fn _attempt, _context -> send(self(), :submitted) end,
          suspend: fn _work_item_id, _reason, _attempt -> :ok end
        )

      assert {:ok, %{state: ^expected}} = request_transition(coordinator, intent_attrs())
      refute_received :submitted
      GenServer.stop(coordinator)
    end
  end

  test "A4 preflight failure after durable submission reconciles without provider dispatch" do
    parent = self()
    root = Path.join(System.tmp_dir!(), "a4-coordinator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        project_id: "project-a",
        tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
        ledger_opts: [path: Path.join(root, "attempts.dets")],
        a4_controller: %{controller: self(), ref: make_ref(), timeout_ms: 10},
        load_context: fn _ -> {:ok, Map.put(context(), :tracker_settings, %{provider: %{workspace_slug: "workspace-a", project_id: "project-a"}})} end,
        submit: fn _, _ ->
          send(parent, :unexpected_a4_submit)
          :ok
        end,
        verify: fn attempt, ctx ->
          send(parent, {:a4_verified, attempt, ctx})
          {:error, :verification_unavailable}
        end,
        suspend: fn _, _, _ -> :ok end
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, %{state: :indeterminate}} = request_transition(coordinator, intent)
    assert_received {:a4_verified, %{state: :verifying, provider_request_id: request_id}, verification}
    assert is_binary(request_id)
    assert verification.provider_non_commit?
    assert {:error, {:dispatch_witness_failed, :invalid_proof_controller_capability}} = verification.provider_result
    refute_received :unexpected_a4_submit
    GenServer.stop(coordinator)
  end

  defp request_transition(server, intent, opts \\ [])

  defp request_transition(server, intent, opts) when is_map(intent) and is_list(opts) do
    responsibility = Map.get(intent, :responsibility)
    requested_from = Map.get(intent, :requested_from)
    work_item_id = Map.get(intent, :work_item_id)

    opts =
      if Keyword.has_key?(opts, :route) or responsibility != "implementation" or
           is_nil(requested_from) or not is_binary(work_item_id) do
        opts
      else
        route =
          runtime_route(%Issue{
            id: work_item_id,
            state: WorkflowLifecycle.display(requested_from)
          })

        Keyword.put(opts, :route, route)
      end

    TransitionCoordinator.request_transition(server, intent, opts)
  end

  defp request_transition(server, intent, opts) do
    TransitionCoordinator.request_transition(server, intent, opts)
  end

  defp intent_attrs do
    %{
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      runtime_attempt_id: "runtime-coordinator-test",
      lineage_generation: "lineage-coordinator-test",
      guard_evidence: []
    }
  end

  defp context do
    route = runtime_route(%Issue{id: "work-1", state: "Ready"})
    identity = runtime_identity("runtime-coordinator-test", "lineage-coordinator-test")

    %{
      current_state: :ready,
      route: route,
      route_fingerprint: route.fingerprint,
      runtime_profile: route.profile_name,
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_generation: identity.lineage_generation,
      responsibility: identity.responsibility,
      dispatch_authority_evidence: dispatch_guard(route, identity),
      provider_project_contract: contract(),
      dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none},
      dependency_epoch_evidence: %{complete?: true}
    }
  end

  defp runtime_identity(runtime_attempt_id, lineage_generation) do
    profile = Profile.default_profiles("codex app-server", 20)["builder"]

    %Identity{
      runtime_attempt_id: runtime_attempt_id,
      work_item_id: "work-1",
      lineage_generation: lineage_generation,
      responsibility: "implementation",
      runtime_profile: profile.name
    }
  end

  defp dispatch_guard(route, identity) do
    %{
      class: :mechanical_guard,
      name: :dispatch_guard,
      outcome: :verified,
      subject: {:work_item, identity.work_item_id},
      transition: {:ready, :in_progress},
      responsibility: identity.responsibility,
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_generation: identity.lineage_generation,
      runtime_profile: route.profile_name,
      route_fingerprint: route.fingerprint,
      verified_at: DateTime.utc_now()
    }
  end

  defp runtime_route(%Issue{} = issue) do
    profile = Profile.default_profiles("codex app-server", 20)["builder"]
    Route.new(issue, profile)
  end

  defp replace_runtime_context(orchestrator, %Issue{} = issue, %WorkItem{} = work_item, provider_contract, identity) do
    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | startup_reconciliation: :ready,
          work_control: Map.put(state.work_control, issue.id, work_item),
          dependency_diagnostics:
            Map.put(state.dependency_diagnostics, issue.id, %{
              allowed?: true,
              dependency_completeness: :complete,
              dependency_status: :none
            }),
          dependency_graph: Graph.build([issue]),
          project_contract_evidence: %ProjectContractEvidence{
            contract: provider_contract,
            reconciliation_required?: false,
            configured_before?: true
          },
          running:
            Map.put(state.running, issue.id, %{
              profile_name: "implementation",
              route: runtime_route(issue),
              route_fingerprint: runtime_route(issue).fingerprint,
              responsibility: "implementation",
              containment_status: :active,
              lifecycle_suspension: nil,
              runtime_attempt: RuntimeAttempt.new(identity, :running)
            })
      }
    end)
  end

  defp restore_application_env(:workflow_file_path, previous_path) do
    result =
      case previous_path do
        nil -> Application.delete_env(:symphony_elixir, :workflow_file_path)
        path -> Application.put_env(:symphony_elixir, :workflow_file_path, path)
      end

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    result
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp prepared_attempt(intent) do
    {:ok, attempt} = TransitionAttempt.new(Map.from_struct(intent))
    {:ok, attempt} = TransitionAttempt.authorize_intent(attempt, intent)
    {:ok, attempt} = TransitionAttempt.fresh_context_loaded(attempt, context())

    prepare_context =
      context()
      |> Map.merge(%{
        workspace_id: "workspace-1",
        project_id: "project-1",
        target_provider_state_id: "state-in-progress",
        target_provider_state_group: :started,
        provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
      })

    {:ok, attempt} = TransitionAttempt.prepare(attempt, prepare_context)
    attempt
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

  defp verified_context do
    %{
      status: :validated,
      assessment: %{status: :validated, validated_state: :in_progress},
      post_observation_evidence: %{
        workspace_id: "workspace-1",
        project_id: "project-1",
        work_item_id: "work-1",
        provider_state_id: "state-in_progress",
        observed_at: DateTime.utc_now()
      },
      post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
    }
  end

  defp provider_failed_evidence(attempt, reason) do
    %{
      non_commit?: true,
      reason: reason,
      assessment: %{status: :invalid, work_item_id: attempt.work_item_id},
      post_observation_evidence: %{
        workspace_id: attempt.workspace_id,
        project_id: attempt.project_id,
        work_item_id: attempt.work_item_id,
        provider_state_id: "unavailable",
        observed_at: DateTime.utc_now()
      },
      post_contract_fingerprint: attempt.provider_contract_fingerprint
    }
  end

  defp failing_ledger(kind) do
    root = Path.join(System.tmp_dir!(), "symphony-transition-failure-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", identity, path: path)

    ledger =
      case kind do
        :write -> %{initialized | write_fun: fn _table, _records -> {:error, :disk_full} end}
        :sync -> %{initialized | sync_fun: fn _table -> {:error, :sync_failed} end}
      end

    {ledger, root}
  end

  defp post_submission_sync_failure_ledger do
    root = Path.join(System.tmp_dir!(), "symphony-transition-post-submit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", identity, path: path)
    :ok = TransitionAttemptLedger.close(initialized)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", identity,
        path: path,
        sync_fun: fn _table ->
          count = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
          if count <= 2, do: :ok, else: {:error, :sync_failed}
        end
      )

    {ledger, root, counter}
  end

  defp observed_submission_ledger(observer, failure) do
    root = Path.join(System.tmp_dir!(), "symphony-transition-observed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", identity, path: path)
    :ok = TransitionAttemptLedger.close(initialized)
    {:ok, counter} = Agent.start_link(fn -> %{write: 0, sync: 0} end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", identity,
        path: path,
        write_fun: fn table, records ->
          attempt =
            Enum.find_value(records, fn
              {{:attempt, _attempt_id}, value} -> value
              _record -> nil
            end)

          count = Agent.get_and_update(counter, fn counts -> {counts.write + 1, %{counts | write: counts.write + 1}} end)
          send(observer, {:ledger_write, attempt})

          if failure == :write and count == 3 do
            {:error, :write_failed}
          else
            :dets.insert(table, records)
          end
        end,
        sync_fun: fn table ->
          count = Agent.get_and_update(counter, fn counts -> {counts.sync + 1, %{counts | sync: counts.sync + 1}} end)
          send(observer, :ledger_sync)

          if failure == :sync and count == 3 do
            {:error, :sync_failed}
          else
            :dets.sync(table)
          end
        end
      )

    {ledger, root, counter}
  end

  defp always_failing_sync_ledger do
    root = Path.join(System.tmp_dir!(), "symphony-transition-terminal-submit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    identity = %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", identity, path: path)
    :ok = TransitionAttemptLedger.close(initialized)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", identity,
        path: path,
        sync_fun: fn _table ->
          _ = Agent.update(counter, &(&1 + 1))
          {:error, :sync_failed}
        end
      )

    {ledger, root, counter}
  end

  test "planning to ready acquires planning_requirements_verified after fresh context authorization" do
    test_pid = self()

    issue = %Issue{id: "work-1", state: WorkflowLifecycle.display(:planning)}
    planner = Profile.default_profiles("codex app-server", 20)["planner"]
    route = Route.new(issue, planner)
    identity = Identity.allocate("work-1", route, "lineage-planning-coordinator-test")

    {:ok, plan_attested} =
      GuardClass.semantic_attestation(:plan_attested, %{
        responsibility: "planning",
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        subject: {:work_item, "work-1"},
        timestamp: DateTime.utc_now()
      })

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :planning,
        requested_to: :ready,
        responsibility: "planning",
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        guard_evidence: [plan_attested]
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        require_durable?: false,
        load_context: fn loaded_intent ->
          send(test_pid, :context_loaded)

          {:ok,
           Map.put(context(), :current_state, :planning)
           |> Map.put(:guard_evidence, loaded_intent.guard_evidence)}
        end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:ok, %{status: 204}}
        end,
        verify: fn attempt, _context ->
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
        end,
        apply_verified: fn _attempt, _context -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, attempt} = request_transition(coordinator, intent, route: route)
    assert attempt.state == :verified
    assert_received :context_loaded
    assert_received :submitted
    GenServer.stop(coordinator)
  end
end
