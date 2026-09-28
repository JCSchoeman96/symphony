defmodule SymphonyElixir.RemHi21RestartGapTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    LifecycleAssessment,
    ProviderObservation,
    RecoveryLedger,
    SuspensionContext,
    WorkItem
  }

  test "an accepted lifecycle suspension is durably fenced before restart" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-gap-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    recovery_path = Path.join(root, "recovery.dets")
    attempt_path = Path.join(root, "attempt.dets")

    {:ok, recovery_ledger} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
    {:ok, attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    on_exit(fn ->
      RecoveryLedger.close(recovery_ledger)
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(root)
    end)

    now = DateTime.utc_now()

    prior_checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :in_progress,
      durable_guard_evidence: [],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: now
    }

    assert :ok = RecoveryLedger.put_sync(recovery_ledger, prior_checkpoint)
    assert {:ok, armed} = AttemptLedger.fence_attempt(attempt_ledger, work_item_id)

    observation = %ProviderObservation{
      provider: :memory,
      work_item_id: work_item_id,
      provider_state_name: "In Progress",
      observed_at: now
    }

    trusted_assessment = %LifecycleAssessment{
      work_item_id: work_item_id,
      provider_observation: observation,
      mapped_state: :in_progress,
      validated_state: :in_progress,
      status: :validated,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      assessed_at: now
    }

    work_item = %WorkItem{
      id: work_item_id,
      provider_observation: observation,
      lifecycle_assessment: trusted_assessment,
      validated_lifecycle_state: :in_progress,
      authority_disposition: %AuthorityDisposition{status: :eligible, lifecycle_state: :in_progress}
    }

    runtime_identity = %Identity{
      runtime_attempt_id: "runtime-hi21",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(attempt_ledger, work_item_id, runtime_identity)

    unsafe_assessment = %LifecycleAssessment{
      work_item_id: work_item_id,
      provider_observation: observation,
      mapped_state: :blocked,
      validated_state: :blocked,
      status: :authority_reducing,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      reason: :provider_blocked,
      assessed_at: now
    }

    runtime_state = %State{
      running: %{
        work_item_id => %{
          runtime_attempt: RuntimeAttempt.new(runtime_identity, :running),
          identifier: "SYM-HI21",
          started_at: now
        }
      },
      attempt_ledger: attempt_ledger,
      attempt_ledger_status: :ready,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      durable_in_flight: MapSet.new([work_item_id]),
      attempt_lineages: %{work_item_id => armed.lineage_id},
      recovery_ledger: recovery_ledger,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{work_item_id => prior_checkpoint},
      work_control: %{work_item_id => work_item}
    }

    assert {:noreply, suspended_runtime_state} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, work_item_id, runtime_identity, unsafe_assessment},
               runtime_state
             )

    assert suspended_runtime_state.running[work_item_id].lifecycle_suspension == unsafe_assessment

    assert {:ok,
            %{
              active_suspension_context: %{
                status: :open,
                last_validated_lifecycle_state: :in_progress
              }
            } = durable_checkpoint} =
             RecoveryLedger.current(recovery_ledger, work_item_id)

    assert {:ok, %{authority_fence: %{state: :suspension_pending}, in_flight: true}} =
             AttemptLedger.current(attempt_ledger, work_item_id)

    assert {:noreply, duplicate_state} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, work_item_id, runtime_identity, unsafe_assessment},
               suspended_runtime_state
             )

    assert duplicate_state.running[work_item_id].lifecycle_suspension == unsafe_assessment

    assert RecoveryLedger.current(recovery_ledger, work_item_id) ==
             Map.fetch(suspended_runtime_state.recovery_checkpoints, work_item_id)

    runtime_ref = make_ref()

    monitored_entry =
      suspended_runtime_state.running[work_item_id]
      |> Map.put(:pid, self())
      |> Map.put(:ref, runtime_ref)

    monitored_state = %{
      suspended_runtime_state
      | running: Map.put(suspended_runtime_state.running, work_item_id, monitored_entry)
    }

    assert {:noreply, after_down} =
             Orchestrator.handle_info({:DOWN, runtime_ref, :process, self(), :normal}, monitored_state)

    refute Map.has_key?(after_down.running, work_item_id)
    assert Map.has_key?(after_down.blocked, work_item_id)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
             AttemptLedger.current(attempt_ledger, work_item_id)

    assert :ok = RecoveryLedger.close(recovery_ledger)
    assert :ok = AttemptLedger.close(attempt_ledger)

    {:ok, restarted_recovery_ledger} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
    {:ok, restarted_attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)
    assert {:ok, ^durable_checkpoint} = RecoveryLedger.current(restarted_recovery_ledger, work_item_id)

    assert {:ok, %{authority_fence: %{state: :suspension_pending}, in_flight: true}} =
             AttemptLedger.current(restarted_attempt_ledger, work_item_id)

    restarted_state = %State{
      attempt_ledger: restarted_attempt_ledger,
      attempt_ledger_status: :ready,
      durable_in_flight: MapSet.new([work_item_id]),
      recovery_ledger: restarted_recovery_ledger,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{work_item_id => durable_checkpoint},
      work_control: %{work_item_id => work_item},
      dependency_diagnostics: %{work_item_id => %{allowed?: true}}
    }

    assert {:ok, cleared_state} = Orchestrator.clear_stale_in_flight_for_test(restarted_state, work_item_id)

    assert cleared_state.durable_blocked[work_item_id] == :stale_in_flight_suspension_unresolved

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
             AttemptLedger.current(restarted_attempt_ledger, work_item_id)
  end

  test "a blocked AttemptLedger cannot release a clean task-down fence" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-blocked-ledger-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-blocked-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21-blocked"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    attempt_path = Path.join(root, "attempt.dets")
    {:ok, attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    on_exit(fn ->
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(root)
    end)

    assert {:ok, armed} = AttemptLedger.begin_attempt(attempt_ledger, work_item_id)

    runtime_identity = %Identity{
      runtime_attempt_id: "runtime-hi21-blocked",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(attempt_ledger, work_item_id, runtime_identity)

    runtime_ref = make_ref()
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: runtime_ref,
      identifier: "SYM-HI21-BLOCKED",
      started_at: started_at,
      runtime_attempt: RuntimeAttempt.new(runtime_identity, :running)
    }

    blocked_reason = {:attempt_ledger_unavailable, :injected_failure}

    state = %State{
      running: %{work_item_id => running_entry},
      attempt_ledger: attempt_ledger,
      attempt_ledger_status: {:blocked, blocked_reason},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      durable_in_flight: MapSet.new([work_item_id])
    }

    assert {:noreply, after_down} =
             Orchestrator.handle_info({:DOWN, runtime_ref, :process, self(), :normal}, state)

    assert Map.has_key?(after_down.blocked, work_item_id)
    assert MapSet.member?(after_down.durable_in_flight, work_item_id)
    assert after_down.attempt_ledger_status == {:blocked, blocked_reason}

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^runtime_identity}}} =
             AttemptLedger.current(attempt_ledger, work_item_id)
  end

  test "pending suspension without its trusted checkpoint stays fenced" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-pending-without-checkpoint-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-pending-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21-pending"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    attempt_path = Path.join(root, "attempt.dets")
    {:ok, attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    on_exit(fn ->
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(root)
    end)

    assert {:ok, armed} = AttemptLedger.begin_attempt(attempt_ledger, work_item_id)

    runtime_identity = %Identity{
      runtime_attempt_id: "runtime-hi21-pending",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(attempt_ledger, work_item_id, runtime_identity)

    suspension_intent = %{
      reason: :provider_blocked,
      provider_observation: nil,
      required_evidence: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, _pending} =
             AttemptLedger.mark_suspension_pending(attempt_ledger, work_item_id, runtime_identity, suspension_intent)

    state = %State{
      attempt_ledger: attempt_ledger,
      attempt_ledger_status: :ready,
      durable_in_flight: MapSet.new([work_item_id]),
      attempt_lineages: %{work_item_id => armed.lineage_id},
      recovery_checkpoints: %{}
    }

    assert {:ok, recovered} = Orchestrator.restore_pending_authority_suspensions_for_test(state)

    assert recovered.durable_blocked[work_item_id] ==
             {:stale_in_flight_suspension_unresolved, :suspension_intent_incomplete}

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
             AttemptLedger.current(attempt_ledger, work_item_id)
  end

  test "terminal suspension from a different lineage cannot release the pending fence" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-terminal-lineage-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-terminal-lineage-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21-terminal-lineage"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    attempt_path = Path.join(root, "attempt.dets")
    {:ok, attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    on_exit(fn ->
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(root)
    end)

    assert {:ok, armed} = AttemptLedger.begin_attempt(attempt_ledger, work_item_id)

    runtime_identity = %Identity{
      runtime_attempt_id: "runtime-hi21-terminal-lineage",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(attempt_ledger, work_item_id, runtime_identity)

    now = DateTime.utc_now()

    observation = %ProviderObservation{
      provider: :memory,
      work_item_id: work_item_id,
      provider_state_name: "In Progress",
      observed_at: now
    }

    intent = %{
      reason: :provider_blocked,
      provider_observation: observation,
      required_evidence: [],
      created_at: now
    }

    assert {:ok, _pending} =
             AttemptLedger.mark_suspension_pending(attempt_ledger, work_item_id, runtime_identity, intent)

    assert {:ok, terminal_context} =
             SuspensionContext.new(%{
               work_item_id: work_item_id,
               last_validated_lifecycle_state: :in_progress,
               provider_observation: observation,
               reason: :provider_blocked,
               lineage_generation: "different-lineage",
               created_at: now,
               recovery_policy: :fresh_reconciliation,
               required_evidence: [],
               resume_target: :in_progress,
               status: :resolved
             })

    checkpoint = %{
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :in_progress,
      active_suspension_context: nil,
      last_terminal_suspension_context: terminal_context
    }

    state = %State{
      attempt_ledger: attempt_ledger,
      attempt_ledger_status: :ready,
      durable_in_flight: MapSet.new([work_item_id]),
      recovery_checkpoints: %{work_item_id => checkpoint}
    }

    assert {:ok, recovered} = Orchestrator.restore_pending_authority_suspensions_for_test(state)

    assert recovered.durable_blocked[work_item_id] ==
             {:stale_in_flight_suspension_unresolved, :terminal_suspension_lineage_mismatch}

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
             AttemptLedger.current(attempt_ledger, work_item_id)
  end

  test "RecoveryLedger write and sync failures remain fenced after a healthy restart" do
    for failure <- [:write, :sync], assessment_kind <- [:valid, nil, :malformed] do
      root = Path.join(System.tmp_dir!(), "rem-hi21-#{failure}-#{System.unique_integer([:positive])}")
      project_id = "rem-hi21-#{failure}-#{System.unique_integer([:positive])}"
      work_item_id = "work-hi21-#{failure}"
      tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
      recovery_path = Path.join(root, "recovery.dets")
      attempt_path = Path.join(root, "attempt.dets")
      {:ok, recovery_ledger} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
      {:ok, attempt_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

      on_exit(fn ->
        RecoveryLedger.close(recovery_ledger)
        AttemptLedger.close(attempt_ledger)
        File.rm_rf(root)
      end)

      now = DateTime.utc_now()

      observation = %ProviderObservation{
        provider: :memory,
        work_item_id: work_item_id,
        provider_state_name: "In Progress",
        observed_at: now
      }

      checkpoint = %{
        schema_version: RecoveryLedger.schema_version(),
        project_namespace: project_id,
        work_item_id: work_item_id,
        last_validated_lifecycle_state: :in_progress,
        durable_guard_evidence: [],
        active_suspension_context: nil,
        last_terminal_suspension_context: nil,
        updated_at: now
      }

      assert :ok = RecoveryLedger.put_sync(recovery_ledger, checkpoint)
      {:ok, armed} = AttemptLedger.begin_attempt(attempt_ledger, work_item_id)

      identity = %Identity{
        runtime_attempt_id: "runtime-#{failure}",
        work_item_id: work_item_id,
        lineage_generation: armed.lineage_id,
        responsibility: "implementation",
        runtime_profile: "implementation"
      }

      assert {:ok, _} = AttemptLedger.bind_runtime_attempt(attempt_ledger, work_item_id, identity)

      valid_assessment = %LifecycleAssessment{
        work_item_id: work_item_id,
        provider_observation: observation,
        mapped_state: :blocked,
        validated_state: :blocked,
        status: :authority_reducing,
        required_guards: [],
        satisfied_guards: [],
        missing_guards: [],
        reason: :provider_blocked,
        assessed_at: now
      }

      event_assessment =
        case assessment_kind do
          :valid -> valid_assessment
          nil -> nil
          :malformed -> %{reason: "untrusted"}
        end

      work_item = %WorkItem{
        id: work_item_id,
        provider_observation: observation,
        lifecycle_assessment: %{
          valid_assessment
          | status: :validated,
            mapped_state: :in_progress,
            validated_state: :in_progress
        },
        validated_lifecycle_state: :in_progress,
        authority_disposition: %AuthorityDisposition{status: :eligible, lifecycle_state: :in_progress}
      }

      failing_recovery =
        case failure do
          :write -> %{recovery_ledger | write_fun: fn _table, _records -> {:error, :disk_full} end}
          :sync -> %{recovery_ledger | sync_fun: fn _table -> {:error, :sync_failed} end}
        end

      runtime_state = %State{
        running: %{work_item_id => %{runtime_attempt: RuntimeAttempt.new(identity, :running), identifier: "SYM-HI21"}},
        attempt_ledger: attempt_ledger,
        attempt_ledger_status: :ready,
        attempt_lineages: %{work_item_id => armed.lineage_id},
        durable_in_flight: MapSet.new([work_item_id]),
        recovery_ledger: failing_recovery,
        recovery_ledger_status: :ready,
        recovery_checkpoints: %{work_item_id => checkpoint},
        work_control: %{work_item_id => work_item}
      }

      assert {:noreply, failed_state} =
               Orchestrator.handle_info(
                 {:agent_lifecycle_suspended, work_item_id, identity, event_assessment},
                 runtime_state
               )

      assert not is_nil(failed_state.running[work_item_id].lifecycle_suspension)

      assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
               AttemptLedger.current(attempt_ledger, work_item_id)

      assert {:ok, _} = RecoveryLedger.current(recovery_ledger, work_item_id)

      assert :ok = RecoveryLedger.close(recovery_ledger)
      assert :ok = AttemptLedger.close(attempt_ledger)
      {:ok, reopened_recovery} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
      {:ok, reopened_attempt} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

      restarted_state = %State{
        attempt_ledger: reopened_attempt,
        attempt_ledger_status: :ready,
        attempt_lineages: %{work_item_id => armed.lineage_id},
        durable_in_flight: MapSet.new([work_item_id]),
        recovery_ledger: reopened_recovery,
        recovery_ledger_status: :ready,
        recovery_checkpoints: %{work_item_id => checkpoint},
        work_control: %{work_item_id => work_item},
        dependency_diagnostics: %{work_item_id => %{allowed?: true}}
      }

      assert {:ok, restored_state} = Orchestrator.restore_pending_authority_suspensions_for_test(restarted_state)

      assert {:ok, %{active_suspension_context: %{status: :open}}} =
               RecoveryLedger.current(reopened_recovery, work_item_id)

      assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
               AttemptLedger.current(reopened_attempt, work_item_id)

      assert {:ok, blocked_state} = Orchestrator.clear_stale_in_flight_for_test(restored_state, work_item_id)
      assert blocked_state.durable_blocked[work_item_id] == :stale_in_flight_suspension_unresolved

      assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
               AttemptLedger.current(reopened_attempt, work_item_id)

      RecoveryLedger.close(reopened_recovery)
      AttemptLedger.close(reopened_attempt)
    end
  end

  test "a BOUND attempt remains fenced after restart despite a fresh eligible WorkItem" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-bound-restart-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-bound-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21-bound"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    attempt_path = Path.join(root, "attempt.dets")
    {:ok, ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    assert {:ok, armed} = AttemptLedger.begin_attempt(ledger, work_item_id)

    identity = %Identity{
      runtime_attempt_id: "runtime-bound-restart",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(ledger, work_item_id, identity)
    assert :ok = AttemptLedger.close(ledger)
    {:ok, restarted_ledger} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

    on_exit(fn ->
      AttemptLedger.close(restarted_ledger)
      File.rm_rf(root)
    end)

    now = DateTime.utc_now()

    observation = %ProviderObservation{
      provider: :memory,
      work_item_id: work_item_id,
      provider_state_name: "In Progress",
      observed_at: now
    }

    assessment = %LifecycleAssessment{
      work_item_id: work_item_id,
      provider_observation: observation,
      mapped_state: :in_progress,
      validated_state: :in_progress,
      status: :validated,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      assessed_at: now
    }

    work_item = %WorkItem{
      id: work_item_id,
      provider_observation: observation,
      lifecycle_assessment: assessment,
      validated_lifecycle_state: :in_progress,
      authority_disposition: %AuthorityDisposition{status: :eligible, lifecycle_state: :in_progress}
    }

    restarted_state = %State{
      attempt_ledger: restarted_ledger,
      attempt_ledger_status: :ready,
      durable_in_flight: MapSet.new([work_item_id]),
      work_control: %{work_item_id => work_item},
      dependency_diagnostics: %{work_item_id => %{allowed?: true}}
    }

    assert {:ok, blocked_state} = Orchestrator.clear_stale_in_flight_for_test(restarted_state, work_item_id)
    assert blocked_state.durable_blocked[work_item_id] == :stale_in_flight_authority_fence_unresolved

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(restarted_ledger, work_item_id)
  end

  test "a stale RuntimeAttempt suspension cannot mutate the current durable fence" do
    root = Path.join(System.tmp_dir!(), "rem-hi21-stale-#{System.unique_integer([:positive])}")
    project_id = "rem-hi21-stale-#{System.unique_integer([:positive])}"
    work_item_id = "work-hi21-stale"
    tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
    {:ok, ledger} = AttemptLedger.open(project_id, tracker_identity, path: Path.join(root, "attempt.dets"))

    on_exit(fn ->
      AttemptLedger.close(ledger)
      File.rm_rf(root)
    end)

    {:ok, armed} = AttemptLedger.begin_attempt(ledger, work_item_id)

    current = %Identity{
      runtime_attempt_id: "runtime-current",
      work_item_id: work_item_id,
      lineage_generation: armed.lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }

    assert {:ok, _} = AttemptLedger.bind_runtime_attempt(ledger, work_item_id, current)
    stale = %{current | runtime_attempt_id: "runtime-stale"}
    running_entry = %{runtime_attempt: RuntimeAttempt.new(current, :running)}

    state = %State{
      running: %{work_item_id => running_entry},
      attempt_ledger: ledger,
      attempt_ledger_status: :ready
    }

    assert {:noreply, unchanged} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, work_item_id, stale, nil},
               state
             )

    assert unchanged.running[work_item_id] == running_entry

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^current}}} =
             AttemptLedger.current(ledger, work_item_id)
  end

  test "startup releases pending fences only from matching durable terminal recovery" do
    for terminal_status <- [:resolved, :escalated] do
      root = Path.join(System.tmp_dir!(), "rem-hi21-terminal-#{terminal_status}-#{System.unique_integer([:positive])}")
      project_id = "rem-hi21-terminal-#{terminal_status}-#{System.unique_integer([:positive])}"
      work_item_id = "work-hi21-terminal-#{terminal_status}"
      tracker_identity = %{tracker_kind: "memory", provider_scope: %{}}
      recovery_path = Path.join(root, "recovery.dets")
      attempt_path = Path.join(root, "attempt.dets")
      {:ok, recovery} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
      {:ok, attempts} = AttemptLedger.open(project_id, tracker_identity, path: attempt_path)

      on_exit(fn ->
        RecoveryLedger.close(recovery)
        AttemptLedger.close(attempts)
        File.rm_rf(root)
      end)

      now = DateTime.utc_now()

      observation = %ProviderObservation{
        provider: :memory,
        work_item_id: work_item_id,
        provider_state_name: "In Progress",
        observed_at: now
      }

      {:ok, context} =
        SuspensionContext.new(%{
          work_item_id: work_item_id,
          last_validated_lifecycle_state: :in_progress,
          provider_observation: observation,
          reason: :provider_blocked,
          lineage_generation: "pending",
          created_at: now,
          recovery_policy: :fresh_reconciliation,
          required_evidence: [],
          resume_target: :in_progress
        })

      {:ok, resolving} = SuspensionContext.begin_resolution(context)

      terminal =
        case terminal_status do
          :resolved ->
            elem(
              SuspensionContext.resolve(resolving, %{
                fresh_reconciliation: true,
                resume_target: :in_progress,
                required_evidence: []
              }),
              1
            )

          :escalated ->
            elem(SuspensionContext.escalate(resolving, :operator_review), 1)
        end

      {:ok, armed} = AttemptLedger.begin_attempt(attempts, work_item_id)

      identity = %Identity{
        runtime_attempt_id: "runtime-terminal-#{terminal_status}",
        work_item_id: work_item_id,
        lineage_generation: armed.lineage_id,
        responsibility: "implementation",
        runtime_profile: "implementation"
      }

      {:ok, _} = AttemptLedger.bind_runtime_attempt(attempts, work_item_id, identity)
      intent = %{reason: :provider_blocked, provider_observation: observation, required_evidence: [], created_at: now}
      {:ok, _} = AttemptLedger.mark_suspension_pending(attempts, work_item_id, identity, intent)
      terminal = %{terminal | lineage_generation: armed.lineage_id}

      checkpoint = %{
        schema_version: RecoveryLedger.schema_version(),
        project_namespace: project_id,
        work_item_id: work_item_id,
        last_validated_lifecycle_state: :in_progress,
        durable_guard_evidence: [],
        active_suspension_context: nil,
        last_terminal_suspension_context: terminal,
        updated_at: now
      }

      assert :ok = RecoveryLedger.put_sync(recovery, checkpoint)

      state = %State{
        attempt_ledger: attempts,
        attempt_ledger_status: :ready,
        durable_in_flight: MapSet.new([work_item_id]),
        recovery_ledger: recovery,
        recovery_ledger_status: :ready,
        recovery_checkpoints: %{work_item_id => checkpoint}
      }

      assert {:ok, released} = Orchestrator.restore_pending_authority_suspensions_for_test(state)
      assert not MapSet.member?(released.durable_in_flight, work_item_id)

      assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
               AttemptLedger.current(attempts, work_item_id)
    end
  end
end
