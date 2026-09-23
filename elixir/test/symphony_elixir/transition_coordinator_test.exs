defmodule SymphonyElixir.TransitionCoordinatorTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    ProviderProjectContract,
    SemanticTransitionIntent,
    TransitionAttempt,
    TransitionAttemptLedger,
    WorkflowLifecycle
  }

  test "executes one prepared transition and verifies it without resubmitting" do
    test_pid = self()

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "symphony",
        guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn ^intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:ok, %{status: 204}}
        end,
        verify: fn _attempt, _context -> {:verified, verified_context()} end,
        require_durable?: false
      )

    assert {:ok, attempt} = TransitionCoordinator.request_transition(coordinator, intent)
    assert attempt.state == :verified
    assert attempt.provider_ack_status == {:http, 204}
    assert_received :submitted
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
             TransitionCoordinator.request_transition(coordinator, intent)

    refute_received :submitted
  end

  test "cleans up unavailable claims and keeps an active item claimed" do
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    unavailable_server = String.to_atom("missing-transition-coordinator-#{System.unique_integer([:positive])}")

    assert {:error, :invalid_request_options} =
             TransitionCoordinator.request_transition(unavailable_server, intent, :invalid_options)

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.request_transition(unavailable_server, intent)

    assert {:error, :coordinator_unavailable} =
             TransitionCoordinator.request_transition(unavailable_server, intent)

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

    assert {:error, :transition_in_progress} = TransitionCoordinator.request_transition(coordinator, intent)
    GenServer.stop(coordinator)
  end

  test "normalizes an invalid semantic intent struct before execution" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(name: nil, ledger: nil, require_durable?: false)

    {:ok, valid} = SemanticTransitionIntent.new(intent_attrs())
    invalid = %{valid | requested_to: :done}

    assert {:error, {:rejected, :invalid_transition}} =
             TransitionCoordinator.request_transition(coordinator, invalid)
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
    assert {:error, :transitions_disabled} = TransitionCoordinator.request_transition(coordinator, intent)

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
             TransitionCoordinator.request_transition(coordinator, %{
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
    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "pre-submit failures never reach the provider" do
    cases = [
      {:context_unavailable, {:error, :transport}, :provider_failed},
      {:missing_dependency, {:ok, Map.delete(context(), :dependency_decision)}, :rejected},
      {:missing_guard, {:ok, Map.put(context(), :guard_evidence, [])}, :rejected},
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
      assert {:ok, %{state: ^expected_state}} = TransitionCoordinator.request_transition(coordinator, intent)
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
    assert {:ok, %{state: :rejected}} = TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:ok, attempt} = TransitionCoordinator.request_transition(coordinator, intent)
    assert attempt.state == :indeterminate
    assert_received :submitted

    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent)
    refute_received :submitted
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
    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(first, intent)
    assert Agent.get(submissions, & &1) == 1
    assert :ok = GenServer.stop(first)

    {:ok, second} = TransitionCoordinator.start_link(coordinator_opts)
    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(second, intent)
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

    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent)
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

    first = Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent) end)
    assert_receive :first_submit_started

    assert {:error, :transition_in_progress} =
             Task.await(Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent) end))

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
          if count == 4, do: {:error, :disk_full}, else: :ok
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
             TransitionCoordinator.request_transition(coordinator, intent)

    assert_received :submitted
    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent)
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
             TransitionCoordinator.request_transition(coordinator, intent)

    assert {:error, :transitions_disabled} =
             TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:error, _reason} = TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:error, _reason} = TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent)
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
    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(coordinator, intent)
  end

  test "rejects malformed intents and unavailable coordinator calls" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, context()} end
      )

    assert {:error, {:rejected, :invalid_intent}} = TransitionCoordinator.request_transition(coordinator, :invalid)

    assert {:error, {:rejected, :invalid_intent_field}} =
             TransitionCoordinator.request_transition(coordinator, %{unexpected: true})

    assert :ok = GenServer.stop(coordinator)
    assert {:error, :coordinator_unavailable} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
               TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
               TransitionCoordinator.request_transition(coordinator, intent_attrs())

      GenServer.stop(coordinator)
      Agent.stop(counter)
      File.rm_rf(root)
    end
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())
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
             TransitionCoordinator.request_transition(coordinator, intent_attrs())

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

      assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
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

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
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

    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
    assert_received {:suspended, :conflict}
    assert Agent.get(submissions, & &1) == 1
    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
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

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(accepted, intent_attrs())
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
               TransitionCoordinator.request_transition(coordinator, intent_attrs())

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

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(one_arg, intent_attrs())
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

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(zero_arg, intent_attrs())
    GenServer.stop(zero_arg)

    {:ok, failing} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> raise "load failed" end
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(failing, intent_attrs())
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
             TransitionCoordinator.request_transition(malformed_context, intent_attrs())

    GenServer.stop(malformed_context)

    {:ok, malformed_target} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn _intent -> {:ok, Map.put(context(), :provider_project_contract, :invalid)} end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    assert {:ok, %{state: :rejected}} = TransitionCoordinator.request_transition(malformed_target, intent_attrs())
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
               TransitionCoordinator.request_transition(coordinator, intent_attrs())

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
             TransitionCoordinator.request_transition(bad_clock, intent_attrs())

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

      assert {:ok, %{state: ^expected}} = TransitionCoordinator.request_transition(coordinator, intent_attrs())
      refute_received :submitted
      GenServer.stop(coordinator)
    end
  end

  defp intent_attrs do
    %{
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "symphony",
      guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
    }
  end

  defp context do
    %{
      provider_project_contract: contract(),
      dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none},
      dependency_epoch_evidence: %{complete?: true}
    }
  end

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
end
