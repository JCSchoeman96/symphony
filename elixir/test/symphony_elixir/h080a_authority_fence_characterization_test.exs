defmodule SymphonyElixir.H080AAuthorityFenceProbeRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, recipient, opts) do
    identity = Keyword.fetch!(opts, :runtime_attempt_identity)
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

    if is_pid(recipient) do
      send(recipient, {:runtime_attempt_session_started, issue.id, identity})
    end

    event = :atomics.add_get(sequence, 1, 1)
    send(observer, {:h080a_child_first_instruction, event, self(), issue.id, identity})

    case Application.get_env(:symphony_elixir, :h080a_runner_action, :hold) do
      {:suspend, assessment} when is_pid(recipient) ->
        send(recipient, {:agent_lifecycle_suspended, issue.id, identity, assessment})
        send(observer, {:h080a_suspension_event_sent, issue.id, identity})

      _hold ->
        :ok
    end

    receive do
      :h080a_finish_normally -> :ok
      {:h080a_exit, reason} -> exit(reason)
    end
  end
end

defmodule SymphonyElixir.H080AAuthorityFenceCharacterizationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{AttemptLedger, Route, RuntimeAttempt}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    LifecycleAssessment,
    ProviderObservation,
    RecoveryLedger,
    SuspensionContext,
    WorkItem
  }

  setup do
    sequence = :atomics.new(1, [])
    Application.put_env(:symphony_elixir, :h080a_event_sequence, sequence)
    Application.put_env(:symphony_elixir, :h080a_event_observer, self())
    Application.put_env(:symphony_elixir, :h080a_runner_action, :hold)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :h080a_event_sequence)
      Application.delete_env(:symphony_elixir, :h080a_event_observer)
      Application.delete_env(:symphony_elixir, :h080a_runner_action)
    end)

    {:ok, event_sequence: sequence}
  end

  test "syncs the exact BOUND identity before child start and releases before clearing on a genuine monitor event" do
    issue = active_issue("h080a-clean-runtime-exit")
    fixture = fixture!(issue, "clean-exit")
    {orchestrator, task_supervisor} = start_orchestrator!(fixture)

    assert_receive(
      {:h080a_attempt_sync, issue_id, armed_event, %{state: :armed, in_flight: true, runtime_attempt: nil}},
      5_000
    )

    assert issue_id == issue.id

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, bound_event, bound_record}
      when bound_record.state == :bound and bound_record.in_flight and
             is_struct(bound_record.runtime_attempt, Identity),
      5_000
    )

    identity = bound_record.runtime_attempt

    assert_receive {:h080a_child_first_instruction, child_event, child, ^issue_id, ^identity}, 5_000

    assert armed_event < bound_event
    assert bound_event < child_event
    assert identity.work_item_id == issue.id
    assert is_binary(identity.runtime_attempt_id)
    assert is_binary(identity.lineage_generation)
    assert identity.responsibility == "implementation"
    assert identity.runtime_profile == "builder"

    state = :sys.get_state(orchestrator)
    assert %RuntimeAttempt{identity: ^identity} = state.running[issue.id].runtime_attempt
    assert state.running[issue.id].pid == child

    child_monitor = Process.monitor(child)
    send(child, :h080a_finish_normally)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 5_000

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, release_event, release_record}
      when release_record.state == :released and release_record.in_flight and
             release_record.runtime_attempt == identity,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, pre_clear_event, pre_clear_record}
      when pre_clear_record.state == :released and pre_clear_record.in_flight and
             pre_clear_record.runtime_attempt == identity,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, clear_event, clear_record}
      when clear_record.state == :released and not clear_record.in_flight and
             clear_record.runtime_attempt == identity,
      5_000
    )

    assert release_event < pre_clear_event
    assert pre_clear_event < clear_event

    _snapshot = GenServer.call(orchestrator, :snapshot)
    final_state = :sys.get_state(orchestrator)
    refute Map.has_key?(final_state.running, issue.id)
    refute MapSet.member?(final_state.durable_in_flight, issue.id)

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(final_state.attempt_ledger, issue.id)

    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "a child start rejection follows synced BOUND and retires the reservation before retry" do
    issue = active_issue("h080a-child-start-rejected")
    fixture = fixture!(issue, "child-start-rejected")
    {orchestrator, task_supervisor} = start_orchestrator!(fixture, max_children: 0)

    assert_receive {:h080a_attempt_sync, issue_id, armed_event, %{state: :armed, in_flight: true}},
                   5_000

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, bound_event, %{state: :bound, in_flight: true, runtime_attempt: %Identity{}}},
      5_000
    )

    assert_receive {:h080a_attempt_sync, ^issue_id, release_event, %{state: :released, in_flight: true}},
                   5_000

    assert_receive {:h080a_attempt_sync, ^issue_id, pre_clear_event, %{state: :released, in_flight: true}},
                   5_000

    assert_receive {:h080a_attempt_sync, ^issue_id, clear_event, %{state: :released, in_flight: false}},
                   5_000

    assert armed_event < bound_event
    assert bound_event < release_event
    assert release_event < pre_clear_event
    assert pre_clear_event < clear_event

    _snapshot = GenServer.call(orchestrator, :snapshot)
    state = :sys.get_state(orchestrator)
    assert state.running == %{}
    assert Map.has_key?(state.retry_attempts, issue.id)
    refute_receive {:h080a_child_first_instruction, _, _, _, _}, 0

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} =
             AttemptLedger.current(state.attempt_ledger, issue.id)

    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "BOUND write and sync failures block child start and preserve the reopened durable fence" do
    for failure <- [:write_before, :write_after, :sync_after] do
      issue = active_issue("h080a-bound-#{failure}")
      expected_issue_id = issue.id
      fixture = fixture!(issue, "bound-#{failure}")

      failure_opts =
        case failure do
          :write_before ->
            [attempt_write_fun: failing_attempt_write_fun(self(), issue.id, :bound, :before)]

          :write_after ->
            [attempt_write_fun: failing_attempt_write_fun(self(), issue.id, :bound, :after)]

          :sync_after ->
            [attempt_sync_fun: attempt_sync_fun(self(), issue.id, :atomics.new(1, []), :bound)]
        end

      {orchestrator, task_supervisor} = start_orchestrator!(fixture, failure_opts)

      assert_receive(
        {:h080a_attempt_sync, armed_issue_id, _armed_event, armed_record}
        when armed_issue_id == expected_issue_id and armed_record.state == :armed and armed_record.in_flight,
        5_000
      )

      case failure do
        :write_before ->
          assert_receive(
            {:h080a_attempt_write_failure, failure_issue_id, :bound, :before}
            when failure_issue_id == expected_issue_id,
            5_000
          )

        :write_after ->
          assert_receive(
            {:h080a_attempt_write_failure, failure_issue_id, :bound, :after}
            when failure_issue_id == expected_issue_id,
            5_000
          )

        :sync_after ->
          assert_receive(
            {:h080a_attempt_sync, failure_issue_id, _bound_event, bound_record}
            when failure_issue_id == expected_issue_id and bound_record.state == :bound and bound_record.in_flight and
                   bound_record.result == :injected_sync_failure,
            5_000
          )
      end

      _snapshot = GenServer.call(orchestrator, :snapshot)
      refute_receive {:h080a_child_first_instruction, _, _, _, _}, 0
      stop_fixture_processes(orchestrator, task_supervisor)

      {:ok, reopened} = open_attempt!(fixture)

      case failure do
        :write_before ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :armed}}} =
                   AttemptLedger.current(reopened, issue.id)

        write_failure when write_failure in [:write_after, :sync_after] ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: %Identity{}}}} =
                   AttemptLedger.current(reopened, issue.id)

          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound}}} =
                   AttemptLedger.current(reopened, issue.id)
      end

      assert :ok = AttemptLedger.close(reopened)

      {restarted_orchestrator, restarted_task_supervisor} =
        start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

      restarted_initial_state = :sys.get_state(restarted_orchestrator)
      assert MapSet.member?(restarted_initial_state.durable_in_flight, issue.id)
      assert restarted_initial_state.startup_reconciliation == :pending

      send(restarted_orchestrator, :run_poll_cycle)
      _restart_barrier = GenServer.call(restarted_orchestrator, :snapshot)
      reconciled_state = :sys.get_state(restarted_orchestrator)

      case failure do
        :write_before ->
          refute MapSet.member?(reconciled_state.durable_in_flight, issue.id)

          assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} =
                   AttemptLedger.current(reconciled_state.attempt_ledger, issue.id)

        write_failure when write_failure in [:write_after, :sync_after] ->
          assert reconciled_state.durable_blocked[issue.id] ==
                   :stale_in_flight_authority_fence_unresolved

          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound}}} =
                   AttemptLedger.current(reconciled_state.attempt_ledger, issue.id)
      end

      refute_receive {:h080a_child_first_instruction, _, _, _, _}, 0

      stop_fixture_processes(restarted_orchestrator, restarted_task_supervisor)
    end
  end

  test "restart after successful BOUND sync before child instruction preserves unresolved authority" do
    issue = active_issue("h080a-bound-sync-crash")
    fixture = fixture!(issue, "bound-sync-crash")
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

    {orchestrator, task_supervisor} =
      start_orchestrator!(fixture,
        start_quiesced: true,
        attempt_sync_fun: crashing_attempt_sync_fun(observer, issue.id, sequence, :bound)
      )

    orchestrator_monitor = Process.monitor(orchestrator)
    send(orchestrator, :tick)

    assert_receive(
      {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}},
      5_000
    )

    assert issue_id == issue.id

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, _bound_event, bound_record}
      when bound_record.state == :bound and bound_record.in_flight and
             is_struct(bound_record.runtime_attempt, Identity),
      5_000
    )

    identity = bound_record.runtime_attempt
    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, :killed}, 5_000
    refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0

    {:ok, attempts} = open_attempt!(fixture)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    assert :ok = AttemptLedger.close(attempts)

    {restarted_orchestrator, restarted_task_supervisor} =
      start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

    initial_state = :sys.get_state(restarted_orchestrator)
    assert initial_state.startup_reconciliation == :pending
    assert MapSet.member?(initial_state.durable_in_flight, issue.id)

    send(restarted_orchestrator, :run_poll_cycle)
    _restart_barrier = GenServer.call(restarted_orchestrator, :snapshot)
    recovered_state = :sys.get_state(restarted_orchestrator)

    assert recovered_state.startup_reconciliation == :ready
    assert recovered_state.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(recovered_state.attempt_ledger, issue.id)

    refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0

    stop_fixture_processes(restarted_orchestrator, restarted_task_supervisor)
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "restart while the old child is alive keeps its BOUND fence constrained" do
    issue = active_issue("h080a-bound-child-alive-restart")
    fixture = fixture!(issue, "bound-child-alive-restart")
    {orchestrator, task_supervisor} = start_orchestrator!(fixture, start_quiesced: true)
    orchestrator_monitor = Process.monitor(orchestrator)
    send(orchestrator, :tick)

    assert_receive(
      {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}},
      5_000
    )

    assert issue_id == issue.id

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, _bound_event, %{state: :bound, in_flight: true, runtime_attempt: %Identity{}}},
      5_000
    )

    assert_receive {:h080a_child_first_instruction, _child_event, child, ^issue_id, %Identity{} = identity}, 5_000
    child_monitor = Process.monitor(child)
    Process.exit(orchestrator, :kill)
    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, :killed}, 5_000
    assert Process.alive?(child)

    {:ok, attempts} = open_attempt!(fixture)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    assert :ok = AttemptLedger.close(attempts)

    {restarted_orchestrator, restarted_task_supervisor} =
      start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

    initial_state = :sys.get_state(restarted_orchestrator)
    assert initial_state.startup_reconciliation == :pending
    assert MapSet.member?(initial_state.durable_in_flight, issue.id)

    send(restarted_orchestrator, :run_poll_cycle)
    _restart_barrier = GenServer.call(restarted_orchestrator, :snapshot)
    recovered_state = :sys.get_state(restarted_orchestrator)

    assert recovered_state.startup_reconciliation == :ready
    assert recovered_state.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(recovered_state.attempt_ledger, issue.id)

    assert Process.alive?(child)
    refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0

    send(child, :h080a_finish_normally)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 5_000
    stop_fixture_processes(restarted_orchestrator, restarted_task_supervisor)
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "same-lineage events from a different RuntimeAttempt identity cannot suspend the current attempt" do
    issue = active_issue("h080a-runtime-identity-correlation")
    fixture = fixture!(issue, "runtime-identity-correlation")
    {:ok, attempts} = open_attempt!(fixture)
    {:ok, recovery} = open_recovery!(fixture)
    {state, identity, _checkpoint} = bound_runtime_state(fixture, attempts, recovery)
    assessment = blocked_assessment(issue.id)

    stale_identities = [
      %{identity | runtime_attempt_id: "older-runtime-attempt"},
      %{identity | work_item_id: "other-work-item"},
      %{identity | lineage_generation: "older-lineage"},
      %{identity | responsibility: "review"},
      %{identity | runtime_profile: "reviewer"}
    ]

    for stale_identity <- stale_identities do
      assert {:noreply, unchanged} =
               Orchestrator.handle_info(
                 {:agent_lifecycle_suspended, issue.id, stale_identity, assessment},
                 state
               )

      assert unchanged.running == state.running

      assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
               AttemptLedger.current(attempts, issue.id)
    end

    assert {:noreply, suspended} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, issue.id, identity, assessment},
               state
             )

    assert suspended.running[issue.id].lifecycle_suspension == assessment

    assert {:ok, %{authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity, intent: intent}}} =
             AttemptLedger.current(attempts, issue.id)

    assert {:ok, %{active_suspension_context: %{status: :open, suspension_id: suspension_id}}} =
             RecoveryLedger.current(recovery, issue.id)

    assert suspension_id == intent.suspension_id
    assert is_binary(suspension_id)

    assert :ok = RecoveryLedger.close(recovery)
    assert :ok = AttemptLedger.close(attempts)
  end

  test "the pending fence sync precedes its recovery checkpoint and remains fenced after reopen" do
    issue = active_issue("h080a-pending-restart")
    fixture = fixture!(issue, "pending-restart")
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

    {:ok, attempts} = open_attempt!(fixture, sync_fun: attempt_sync_fun(observer, issue.id, sequence))

    {:ok, recovery} = open_recovery!(fixture, sync_fun: recovery_sync_fun(observer, issue.id, sequence))

    {state, identity, _checkpoint} = bound_runtime_state(fixture, attempts, recovery)
    assert_receive {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}}, 1_000
    assert_receive {:h080a_attempt_sync, ^issue_id, _bound_event, %{state: :bound, in_flight: true}}, 1_000

    assert {:noreply, suspended} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, issue.id, identity, blocked_assessment(issue.id)},
               state
             )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, pending_event, pending_record}
      when pending_record.state == :suspension_pending and pending_record.in_flight and
             pending_record.runtime_attempt == identity,
      1_000
    )

    assert_receive {:h080a_recovery_sync, ^issue_id, recovery_event, %{active_suspension_context: %{status: :open}}},
                   1_000

    assert pending_event < recovery_event
    assert suspended.running[issue.id].lifecycle_suspension.status == :authority_reducing

    assert {:ok, %{authority_fence: %{state: :suspension_pending, intent: intent}}} =
             AttemptLedger.current(attempts, issue.id)

    assert {:ok, %{active_suspension_context: %{suspension_id: suspension_id}}} =
             RecoveryLedger.current(recovery, issue.id)

    assert suspension_id == intent.suspension_id

    assert :ok = RecoveryLedger.close(recovery)
    assert :ok = AttemptLedger.close(attempts)

    {:ok, reopened_attempts} = open_attempt!(fixture)

    {:ok, reopened_recovery} = open_recovery!(fixture)

    {:ok, reopened_checkpoint} = RecoveryLedger.current(reopened_recovery, issue.id)

    recovered_state =
      recovery_state(fixture, reopened_attempts, reopened_recovery, reopened_checkpoint)

    assert {:ok, restored} = Orchestrator.restore_pending_authority_suspensions_for_test(recovered_state)
    assert not WorkItem.dispatchable?(restored.work_control[issue.id])
    assert restored.work_control[issue.id].suspension_context.suspension_id == suspension_id
    assert MapSet.member?(restored.durable_in_flight, issue.id)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
             AttemptLedger.current(reopened_attempts, issue.id)

    assert :ok = RecoveryLedger.close(reopened_recovery)
    assert :ok = AttemptLedger.close(reopened_attempts)
  end

  test "pending-fence write and sync failures retain the actual reopened ledger state" do
    for failure <- [:write_before, :write_after, :sync_after] do
      issue = active_issue("h080a-pending-#{failure}")
      expected_issue_id = issue.id
      fixture = fixture!(issue, "pending-#{failure}")
      sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
      observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
      {:ok, attempts} = open_attempt!(fixture)

      attempts =
        case failure do
          :write_before ->
            %{attempts | write_fun: failing_attempt_write_fun(observer, issue.id, :suspension_pending, :before)}

          :write_after ->
            %{attempts | write_fun: failing_attempt_write_fun(observer, issue.id, :suspension_pending, :after)}

          :sync_after ->
            %{attempts | sync_fun: attempt_sync_fun(observer, issue.id, sequence, :suspension_pending)}
        end

      {:ok, recovery} = open_recovery!(fixture)
      {state, identity, _checkpoint} = bound_runtime_state(fixture, attempts, recovery)
      assessment = blocked_assessment(issue.id)

      assert {:noreply, failed_state} =
               Orchestrator.handle_info(
                 {:agent_lifecycle_suspended, issue.id, identity, assessment},
                 state
               )

      assert failed_state.running[issue.id].lifecycle_suspension == assessment

      case failure do
        :write_before ->
          assert_receive(
            {:h080a_attempt_write_failure, failure_issue_id, :suspension_pending, :before}
            when failure_issue_id == expected_issue_id,
            1_000
          )

          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)

        :write_after ->
          assert_receive(
            {:h080a_attempt_write_failure, failure_issue_id, :suspension_pending, :after}
            when failure_issue_id == expected_issue_id,
            1_000
          )

          assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)

        :sync_after ->
          assert_receive(
            {:h080a_attempt_sync, failure_issue_id, _pending_event, pending_record}
            when failure_issue_id == expected_issue_id and pending_record.state == :suspension_pending and pending_record.in_flight and
                   pending_record.result == :injected_sync_failure,
            1_000
          )

          assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)
      end

      assert {:ok, %{active_suspension_context: nil}} = RecoveryLedger.current(recovery, issue.id)
      assert :ok = RecoveryLedger.close(recovery)
      assert :ok = AttemptLedger.close(attempts)

      {:ok, reopened_attempts} = open_attempt!(fixture)

      {:ok, reopened_recovery} = open_recovery!(fixture)

      assert {:ok, reopened_checkpoint} = RecoveryLedger.current(reopened_recovery, issue.id)

      case failure do
        :write_before ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(reopened_attempts, issue.id)

        failure_with_pending_fence when failure_with_pending_fence in [:write_after, :sync_after] ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(reopened_attempts, issue.id)

          restarted = recovery_state(fixture, reopened_attempts, reopened_recovery, reopened_checkpoint)
          assert {:ok, restored} = Orchestrator.restore_pending_authority_suspensions_for_test(restarted)
          assert MapSet.member?(restored.durable_in_flight, issue.id)

          assert {:ok, %{authority_fence: %{intent: %{suspension_id: suspension_id}}}} =
                   AttemptLedger.current(reopened_attempts, issue.id)

          assert restored.work_control[issue.id].suspension_context.suspension_id == suspension_id
          refute WorkItem.dispatchable?(restored.work_control[issue.id])
      end

      assert :ok = RecoveryLedger.close(reopened_recovery)
      assert :ok = AttemptLedger.close(reopened_attempts)
    end
  end

  test "RecoveryLedger write and sync failures are judged from reopened durable records" do
    for failure <- [:write_before, :write_after, :sync_after] do
      issue = active_issue("h080a-recovery-#{failure}")
      expected_issue_id = issue.id
      fixture = fixture!(issue, "recovery-#{failure}")
      sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
      observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
      {:ok, attempts} = open_attempt!(fixture)
      {:ok, recovery} = open_recovery!(fixture)

      recovery =
        case failure do
          :write_before ->
            %{recovery | write_fun: failing_recovery_write_fun(observer, issue.id, :before)}

          :write_after ->
            %{recovery | write_fun: failing_recovery_write_fun(observer, issue.id, :after)}

          :sync_after ->
            %{recovery | sync_fun: failing_recovery_sync_fun(observer, issue.id, sequence)}
        end

      {state, identity, _checkpoint} = bound_runtime_state(fixture, attempts, recovery)
      assessment = blocked_assessment(issue.id)

      assert {:noreply, failed_state} =
               Orchestrator.handle_info(
                 {:agent_lifecycle_suspended, issue.id, identity, assessment},
                 state
               )

      assert failed_state.running[issue.id].lifecycle_suspension == assessment

      case failure do
        :write_before ->
          assert_receive(
            {:h080a_recovery_write_failure, failure_issue_id, :before}
            when failure_issue_id == expected_issue_id,
            1_000
          )

          assert {:ok, %{active_suspension_context: nil}} = RecoveryLedger.current(recovery, issue.id)

        :write_after ->
          assert_receive(
            {:h080a_recovery_write_failure, failure_issue_id, :after}
            when failure_issue_id == expected_issue_id,
            1_000
          )

          assert {:ok, %{active_suspension_context: %{status: :open}}} =
                   RecoveryLedger.current(recovery, issue.id)

        :sync_after ->
          assert_receive(
            {:h080a_recovery_sync, failure_issue_id, _event, recovery_record}
            when failure_issue_id == expected_issue_id and
                   recovery_record.active_suspension_context.status == :open and
                   recovery_record.result == :injected_sync_failure,
            1_000
          )

          assert {:ok, %{active_suspension_context: %{status: :open}}} =
                   RecoveryLedger.current(recovery, issue.id)
      end

      assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
               AttemptLedger.current(attempts, issue.id)

      assert :ok = RecoveryLedger.close(recovery)
      assert :ok = AttemptLedger.close(attempts)

      {:ok, reopened_attempts} = open_attempt!(fixture)

      {:ok, reopened_recovery} = open_recovery!(fixture)

      assert {:ok, reopened_checkpoint} = RecoveryLedger.current(reopened_recovery, issue.id)
      restarted = recovery_state(fixture, reopened_attempts, reopened_recovery, reopened_checkpoint)
      assert {:ok, restored} = Orchestrator.restore_pending_authority_suspensions_for_test(restarted)
      assert MapSet.member?(restored.durable_in_flight, issue.id)

      assert {:ok, %{authority_fence: %{intent: %{suspension_id: suspension_id}}}} =
               AttemptLedger.current(reopened_attempts, issue.id)

      assert restored.work_control[issue.id].suspension_context.suspension_id == suspension_id
      refute WorkItem.dispatchable?(restored.work_control[issue.id])

      assert :ok = RecoveryLedger.close(reopened_recovery)
      assert :ok = AttemptLedger.close(reopened_attempts)
    end
  end

  test "matching terminal recovery releases the exact pending suspension and then clears in-flight" do
    for terminal_status <- [:resolved, :escalated] do
      issue = active_issue("h080a-terminal-release-#{terminal_status}")
      fixture = fixture!(issue, "terminal-release-#{terminal_status}")
      sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
      observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
      {:ok, attempts} = open_attempt!(fixture, sync_fun: attempt_sync_fun(observer, issue.id, sequence))
      {:ok, recovery} = open_recovery!(fixture)
      {_running_state, identity, checkpoint} = bound_runtime_state(fixture, attempts, recovery)
      {:ok, pending} = AttemptLedger.mark_suspension_pending(attempts, issue.id, identity, suspension_intent(issue.id))
      intent = pending.authority_fence.intent
      terminal = terminal_context(issue.id, identity.lineage_generation, intent, terminal_status)
      terminal_checkpoint = %{checkpoint | last_terminal_suspension_context: terminal, updated_at: DateTime.utc_now()}
      assert :ok = RecoveryLedger.put_sync(recovery, terminal_checkpoint)
      state = recovery_state(fixture, attempts, recovery, terminal_checkpoint)

      assert {:ok, released_state} = Orchestrator.restore_pending_authority_suspensions_for_test(state)
      refute MapSet.member?(released_state.durable_in_flight, issue.id)

      assert_receive(
        {:h080a_attempt_sync, issue_id, release_event, release_record}
        when release_record.state == :released and release_record.in_flight and
               release_record.runtime_attempt == identity,
        1_000
      )

      assert_receive(
        {:h080a_attempt_sync, ^issue_id, pre_clear_event, pre_clear_record}
        when pre_clear_record.state == :released and pre_clear_record.in_flight and
               pre_clear_record.runtime_attempt == identity,
        1_000
      )

      assert_receive(
        {:h080a_attempt_sync, ^issue_id, clear_event, clear_record}
        when clear_record.state == :released and not clear_record.in_flight and
               clear_record.runtime_attempt == identity,
        1_000
      )

      assert release_event < pre_clear_event
      assert pre_clear_event < clear_event

      assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
               AttemptLedger.current(attempts, issue.id)

      assert :ok = RecoveryLedger.close(recovery)
      assert :ok = AttemptLedger.close(attempts)
    end
  end

  test "older, id-less, or wrong-lineage terminal context cannot release the current suspension" do
    for terminal_case <- [:older_terminal, :legacy_without_id, :different_lineage] do
      issue = active_issue("h080a-terminal-separation-#{terminal_case}")
      issue_id = issue.id
      fixture = fixture!(issue, "terminal-separation-#{terminal_case}")
      {:ok, attempts} = open_attempt!(fixture)
      {:ok, recovery} = open_recovery!(fixture)

      {_first_state, first_identity, first_checkpoint} = bound_runtime_state(fixture, attempts, recovery)

      {:ok, first_pending} =
        AttemptLedger.mark_suspension_pending(attempts, issue.id, first_identity, suspension_intent(issue.id))

      first_terminal =
        terminal_context(issue.id, first_identity.lineage_generation, first_pending.authority_fence.intent)

      assert :ok = AttemptLedger.release_suspension_fence(attempts, issue.id, first_identity, first_terminal)
      assert :ok = AttemptLedger.clear_in_flight(attempts, issue.id)

      if terminal_case == :different_lineage do
        assert :ok = AttemptLedger.close_lineage(attempts, issue.id)
      end

      assert {:ok, second_armed} = AttemptLedger.begin_attempt(attempts, issue.id)

      if terminal_case == :different_lineage do
        assert second_armed.lineage_id != first_identity.lineage_generation
      else
        assert second_armed.lineage_id == first_identity.lineage_generation
      end

      second_identity = Identity.allocate(issue.id, Route.legacy(issue), second_armed.lineage_id)
      assert second_identity.runtime_attempt_id != first_identity.runtime_attempt_id
      assert {:ok, _second_bound} = AttemptLedger.bind_runtime_attempt(attempts, issue.id, second_identity)

      {:ok, second_pending} =
        AttemptLedger.mark_suspension_pending(attempts, issue.id, second_identity, suspension_intent(issue.id))

      old_terminal =
        case terminal_case do
          :older_terminal ->
            first_terminal

          :legacy_without_id ->
            first_terminal
            |> Map.from_struct()
            |> Map.delete(:suspension_id)
            |> Map.put(:__struct__, SuspensionContext)

          :different_lineage ->
            terminal_context(
              issue.id,
              first_identity.lineage_generation,
              second_pending.authority_fence.intent
            )
        end

      checkpoint = %{
        first_checkpoint
        | active_suspension_context: nil,
          last_terminal_suspension_context: old_terminal,
          updated_at: DateTime.utc_now()
      }

      assert :ok = RecoveryLedger.put_sync(recovery, checkpoint)
      assert :ok = RecoveryLedger.close(recovery)
      assert :ok = AttemptLedger.close(attempts)

      {orchestrator, task_supervisor} =
        start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

      initial_state = :sys.get_state(orchestrator)
      assert initial_state.startup_reconciliation == :pending
      assert MapSet.member?(initial_state.durable_in_flight, issue.id)

      send(orchestrator, :run_poll_cycle)
      _startup_barrier = GenServer.call(orchestrator, :snapshot)
      restored = :sys.get_state(orchestrator)

      assert restored.startup_reconciliation == :ready
      assert MapSet.member?(restored.durable_in_flight, issue.id)

      if terminal_case == :different_lineage do
        assert Map.has_key?(restored.durable_blocked, issue.id)
      else
        assert restored.work_control[issue.id].suspension_context.suspension_id ==
                 second_pending.authority_fence.intent.suspension_id

        assert restored.work_control[issue.id].suspension_context.suspension_id !=
                 first_pending.authority_fence.intent.suspension_id
      end

      assert {:ok,
              %{
                in_flight: true,
                authority_fence: %{state: :suspension_pending, runtime_attempt: ^second_identity}
              }} =
               AttemptLedger.current(restored.attempt_ledger, issue.id)

      refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0
      stop_fixture_processes(orchestrator, task_supervisor)
    end
  end

  test "restart after RELEASED sync before clear preserves the released in-flight fence" do
    issue = active_issue("h080a-released-before-clear-crash")
    fixture = fixture!(issue, "released-before-clear-crash")
    {:ok, attempts} = open_attempt!(fixture)
    {:ok, recovery} = open_recovery!(fixture)
    {_running_state, identity, checkpoint} = bound_runtime_state(fixture, attempts, recovery)

    {:ok, pending} =
      AttemptLedger.mark_suspension_pending(attempts, issue.id, identity, suspension_intent(issue.id))

    terminal = terminal_context(issue.id, identity.lineage_generation, pending.authority_fence.intent)
    terminal_checkpoint = %{checkpoint | last_terminal_suspension_context: terminal, updated_at: DateTime.utc_now()}
    assert :ok = RecoveryLedger.put_sync(recovery, terminal_checkpoint)
    assert :ok = RecoveryLedger.close(recovery)
    assert :ok = AttemptLedger.close(attempts)

    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

    {orchestrator, task_supervisor} =
      start_orchestrator!(fixture,
        start_quiesced: true,
        attempt_sync_fun: crashing_attempt_sync_fun(observer, issue.id, sequence, :released, true, 2)
      )

    orchestrator_monitor = Process.monitor(orchestrator)
    send(orchestrator, :run_poll_cycle)

    assert_receive(
      {:h080a_attempt_sync, issue_id, release_event, %{state: :released, in_flight: true}},
      5_000
    )

    assert issue_id == issue.id

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, pre_clear_event, %{state: :released, in_flight: true}},
      5_000
    )

    assert pre_clear_event > release_event
    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, :killed}, 5_000
    refute_receive {:h080a_attempt_sync, ^issue_id, _, %{state: :released, in_flight: false}}, 0

    {:ok, reopened_attempts} = open_attempt!(fixture)
    {:ok, reopened_recovery} = open_recovery!(fixture)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(reopened_attempts, issue.id)

    assert {:ok, reopened_checkpoint} = RecoveryLedger.current(reopened_recovery, issue.id)

    assert reopened_checkpoint.last_terminal_suspension_context.suspension_id ==
             pending.authority_fence.intent.suspension_id

    assert :ok = RecoveryLedger.close(reopened_recovery)
    assert :ok = AttemptLedger.close(reopened_attempts)
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "restart after durable terminal context before RELEASED performs the correlated release" do
    issue = active_issue("h080a-terminal-before-released-crash")
    issue_id = issue.id
    fixture = fixture!(issue, "terminal-before-released-crash")
    {:ok, attempts} = open_attempt!(fixture)
    {:ok, recovery} = open_recovery!(fixture)
    {_running_state, identity, checkpoint} = bound_runtime_state(fixture, attempts, recovery)

    {:ok, pending} =
      AttemptLedger.mark_suspension_pending(attempts, issue.id, identity, suspension_intent(issue.id))

    terminal = terminal_context(issue.id, identity.lineage_generation, pending.authority_fence.intent)
    terminal_checkpoint = %{checkpoint | last_terminal_suspension_context: terminal, updated_at: DateTime.utc_now()}
    assert :ok = RecoveryLedger.put_sync(recovery, terminal_checkpoint)
    assert :ok = RecoveryLedger.close(recovery)
    assert :ok = AttemptLedger.close(attempts)

    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

    {orchestrator, task_supervisor} =
      start_orchestrator!(fixture,
        start_quiesced: true,
        attempt_write_fun: crashing_attempt_write_fun(observer, issue_id, {:released, true})
      )

    orchestrator_monitor = Process.monitor(orchestrator)
    send(orchestrator, :run_poll_cycle)

    assert_receive {:h080a_attempt_write_crash, ^issue_id, :released, true}, 5_000
    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, :killed}, 5_000

    {:ok, reopened_attempts} = open_attempt!(fixture)
    {:ok, reopened_recovery} = open_recovery!(fixture)

    assert {:ok,
            %{
              in_flight: true,
              authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}
            }} =
             AttemptLedger.current(reopened_attempts, issue.id)

    assert {:ok, reopened_checkpoint} = RecoveryLedger.current(reopened_recovery, issue.id)

    assert reopened_checkpoint.last_terminal_suspension_context.suspension_id ==
             pending.authority_fence.intent.suspension_id

    assert :ok = RecoveryLedger.close(reopened_recovery)
    assert :ok = AttemptLedger.close(reopened_attempts)

    {restarted_orchestrator, restarted_task_supervisor} =
      start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

    send(restarted_orchestrator, :run_poll_cycle)

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, release_event, %{state: :released, in_flight: true, runtime_attempt: ^identity}},
      5_000
    )

    assert_receive(
      {
        :h080a_attempt_sync,
        ^issue_id,
        pre_clear_event,
        %{state: :released, in_flight: true, runtime_attempt: ^identity}
      },
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, clear_event, %{state: :released, in_flight: false, runtime_attempt: ^identity}},
      5_000
    )

    assert release_event < pre_clear_event
    assert pre_clear_event < clear_event

    _startup_barrier = GenServer.call(restarted_orchestrator, :snapshot)
    recovered_state = :sys.get_state(restarted_orchestrator)
    assert recovered_state.startup_reconciliation == :ready
    refute MapSet.member?(recovered_state.durable_in_flight, issue.id)
    refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0

    stop_fixture_processes(restarted_orchestrator, restarted_task_supervisor)
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "release and clear write or sync cuts retain the actual durable fence state" do
    for failure <- [
          :none,
          :release_write_before,
          :release_write_after,
          :release_sync,
          :pre_clear_sync,
          :clear_write_before,
          :clear_write_after,
          :clear_sync
        ] do
      issue = active_issue("h080a-release-cut-#{failure}")
      fixture = fixture!(issue, "release-cut-#{failure}")
      sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
      observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)

      {attempt_write_fun, attempt_sync_fun} =
        case failure do
          :release_write_before ->
            {failing_attempt_write_fun(observer, issue.id, {:released, true}, :before), nil}

          :release_write_after ->
            {failing_attempt_write_fun(observer, issue.id, {:released, true}, :after), nil}

          :release_sync ->
            {nil, attempt_sync_fun(observer, issue.id, sequence, {:released, true, 1})}

          :pre_clear_sync ->
            {nil, attempt_sync_fun(observer, issue.id, sequence, {:released, true, 2})}

          :clear_write_before ->
            {failing_attempt_write_fun(observer, issue.id, {:released, false}, :before), nil}

          :clear_write_after ->
            {failing_attempt_write_fun(observer, issue.id, {:released, false}, :after), nil}

          :clear_sync ->
            {nil, attempt_sync_fun(observer, issue.id, sequence, {:released, false, 1})}

          :none ->
            {nil, nil}
        end

      attempt_opts =
        [path: fixture.attempt_path]
        |> maybe_put(:write_fun, attempt_write_fun)
        |> maybe_put(:sync_fun, attempt_sync_fun)

      {:ok, attempts} = open_attempt!(fixture, Keyword.delete(attempt_opts, :path))
      {:ok, recovery} = open_recovery!(fixture)
      {_running_state, identity, checkpoint} = bound_runtime_state(fixture, attempts, recovery)
      {:ok, pending} = AttemptLedger.mark_suspension_pending(attempts, issue.id, identity, suspension_intent(issue.id))
      terminal = terminal_context(issue.id, identity.lineage_generation, pending.authority_fence.intent)
      terminal_checkpoint = %{checkpoint | last_terminal_suspension_context: terminal, updated_at: DateTime.utc_now()}
      assert :ok = RecoveryLedger.put_sync(recovery, terminal_checkpoint)

      state = recovery_state(fixture, attempts, recovery, terminal_checkpoint)
      assert {:ok, result_state} = Orchestrator.restore_pending_authority_suspensions_for_test(state)

      expected =
        case failure do
          :none -> {:released, false}
          :release_write_before -> {:suspension_pending, true}
          :release_write_after -> {:released, true}
          :release_sync -> {:released, true}
          :pre_clear_sync -> {:released, true}
          :clear_write_before -> {:released, true}
          :clear_write_after -> {:released, false}
          :clear_sync -> {:released, false}
        end

      {expected_fence, expected_in_flight} = expected

      assert {:ok, %{authority_fence: %{state: ^expected_fence}, in_flight: ^expected_in_flight}} =
               AttemptLedger.current(attempts, issue.id)

      if failure == :none do
        refute MapSet.member?(result_state.durable_in_flight, issue.id)
      else
        assert Map.has_key?(result_state.durable_blocked, issue.id)
      end

      assert :ok = RecoveryLedger.close(recovery)
      assert :ok = AttemptLedger.close(attempts)

      {:ok, reopened} = open_attempt!(fixture)

      assert {:ok, %{authority_fence: %{state: ^expected_fence}, in_flight: ^expected_in_flight}} =
               AttemptLedger.current(reopened, issue.id)

      assert :ok = AttemptLedger.close(reopened)
    end
  end

  test "legacy in-flight records without a modern fence remain ambiguous after restart" do
    issue = active_issue("h080a-legacy-in-flight")
    fixture = fixture!(issue, "legacy-in-flight")
    {:ok, attempts} = open_attempt!(fixture)
    assert {:ok, armed} = AttemptLedger.begin_attempt(attempts, issue.id)
    assert {:ok, record} = AttemptLedger.current(attempts, issue.id)
    legacy_record = Map.delete(record, :authority_fence)
    assert :ok = :dets.insert(attempts.table, [{{:current, issue.id}, legacy_record}])
    assert :ok = :dets.sync(attempts.table)
    assert :ok = AttemptLedger.close(attempts)

    {:ok, reopened} = open_attempt!(fixture)
    assert {:ok, ^legacy_record} = AttemptLedger.current(reopened, issue.id)
    assert {:error, :authority_fence_unresolved} = AttemptLedger.clear_in_flight(reopened, issue.id)

    state = %State{
      attempt_ledger: reopened,
      attempt_ledger_status: :ready,
      attempt_lineages: %{issue.id => armed.lineage_id},
      durable_in_flight: MapSet.new([issue.id]),
      work_control: %{issue.id => fixture.work_item}
    }

    assert {:ok, constrained} = Orchestrator.clear_stale_in_flight_for_test(state, issue.id)
    assert constrained.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved
    assert {:ok, ^legacy_record} = AttemptLedger.current(reopened, issue.id)
    assert :ok = AttemptLedger.close(reopened)
  end

  test "a genuine abnormal monitor event clears its fence before recording retry authority" do
    issue = active_issue("h080a-abnormal-runtime-exit")
    fixture = fixture!(issue, "abnormal-runtime-exit")
    {orchestrator, task_supervisor} = start_orchestrator!(fixture)

    assert_receive {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}}, 5_000
    assert_receive {:h080a_attempt_sync, ^issue_id, _bound_event, %{state: :bound, in_flight: true}}, 5_000
    assert_receive {:h080a_child_first_instruction, _child_event, child, ^issue_id, %Identity{} = identity}, 5_000

    child_monitor = Process.monitor(child)
    send(child, {:h080a_exit, :runtime_failure})
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :runtime_failure}, 5_000

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, release_event, release_record}
      when release_record.state == :released and release_record.in_flight and
             release_record.runtime_attempt == identity,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, pre_clear_event, pre_clear_record}
      when pre_clear_record.state == :released and pre_clear_record.in_flight and
             pre_clear_record.runtime_attempt == identity,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, clear_event, clear_record}
      when clear_record.state == :released and not clear_record.in_flight and
             clear_record.safety_counters.ordinary_failures == 0,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, retry_event, retry_record}
      when retry_record.state == :released and not retry_record.in_flight and
             retry_record.safety_counters.ordinary_failures == 1,
      5_000
    )

    assert release_event < pre_clear_event
    assert pre_clear_event < clear_event
    assert clear_event < retry_event

    _snapshot = GenServer.call(orchestrator, :snapshot)
    state = :sys.get_state(orchestrator)
    refute Map.has_key?(state.running, issue.id)
    refute MapSet.member?(state.durable_in_flight, issue.id)
    assert Map.has_key?(state.retry_attempts, issue.id)

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(state.attempt_ledger, issue.id)

    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "unknown monitor references are inert; a current-ref message with another PID is only a constructed control" do
    issue = active_issue("h080a-constructed-down-control")
    fixture = fixture!(issue, "constructed-down-control")
    {orchestrator, task_supervisor} = start_orchestrator!(fixture)

    assert_receive {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}}, 5_000
    assert_receive {:h080a_attempt_sync, ^issue_id, _bound_event, %{state: :bound, in_flight: true}}, 5_000
    assert_receive {:h080a_child_first_instruction, _child_event, child, ^issue_id, %Identity{} = identity}, 5_000
    child_monitor = Process.monitor(child)
    before = :sys.get_state(orchestrator).running[issue.id]

    send(orchestrator, {:DOWN, make_ref(), :process, self(), :normal})
    _snapshot_after_unknown = GenServer.call(orchestrator, :snapshot)
    unchanged = :sys.get_state(orchestrator)
    assert unchanged.running[issue.id].ref == before.ref
    assert unchanged.running[issue.id].pid == child

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(unchanged.attempt_ledger, issue.id)

    send(orchestrator, {:DOWN, before.ref, :process, self(), :normal})
    _snapshot_after_constructed_message = GenServer.call(orchestrator, :snapshot)
    constructed_only_state = :sys.get_state(orchestrator)
    refute Map.has_key?(constructed_only_state.running, issue.id)
    assert Process.alive?(child)

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, _release_event, release_record}
      when release_record.state == :released and release_record.in_flight and
             release_record.runtime_attempt == identity,
      5_000
    )

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, _clear_event, clear_record}
      when clear_record.state == :released and not clear_record.in_flight and
             clear_record.runtime_attempt == identity,
      5_000
    )

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(constructed_only_state.attempt_ledger, issue.id)

    send(child, :h080a_finish_normally)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 5_000
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "a genuine runtime exit leaves an unresolved suspension fence pending" do
    issue = active_issue("h080a-pending-runtime-exit")
    fixture = fixture!(issue, "pending-runtime-exit")
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
    assessment = blocked_assessment(issue.id)
    Application.put_env(:symphony_elixir, :h080a_runner_action, {:suspend, assessment})

    {orchestrator, task_supervisor} =
      start_orchestrator!(fixture,
        recovery_ledger_opts: [sync_fun: recovery_sync_fun(observer, issue.id, sequence)]
      )

    assert_receive {:h080a_attempt_sync, issue_id, _armed_event, %{state: :armed, in_flight: true}}, 5_000
    assert_receive {:h080a_attempt_sync, ^issue_id, _bound_event, %{state: :bound, in_flight: true}}, 5_000
    assert_receive {:h080a_child_first_instruction, _child_event, child, ^issue_id, %Identity{} = identity}, 5_000
    assert_receive {:h080a_suspension_event_sent, ^issue_id, ^identity}, 5_000

    assert_receive(
      {:h080a_attempt_sync, ^issue_id, _pending_event, pending_record}
      when pending_record.state == :suspension_pending and pending_record.in_flight and
             pending_record.runtime_attempt == identity,
      5_000
    )

    assert_receive {:h080a_recovery_sync, ^issue_id, _recovery_event, %{active_suspension_context: %{status: :open}}},
                   5_000

    child_monitor = Process.monitor(child)
    send(child, :h080a_finish_normally)
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 5_000
    _snapshot = GenServer.call(orchestrator, :snapshot)
    state = :sys.get_state(orchestrator)

    refute Map.has_key?(state.running, issue.id)
    assert MapSet.member?(state.durable_in_flight, issue.id)
    assert Map.has_key?(state.blocked, issue.id)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
             AttemptLedger.current(state.attempt_ledger, issue.id)

    refute_receive {:h080a_attempt_sync, ^issue_id, _, %{state: :released, in_flight: _}}, 0

    stop_fixture_processes(orchestrator, task_supervisor)
  end

  test "restart after pending sync reconstructs suspension before RecoveryLedger context persistence" do
    assert_restart_recovers_after_crash(:pending_fence)
  end

  test "restart after RecoveryLedger sync reconstructs suspension before volatile state update" do
    assert_restart_recovers_after_crash(:recovery_context)
  end

  defp fixture!(%Issue{} = issue, label) do
    project_id = "h080a-#{label}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-h080a-#{label}-#{System.unique_integer([:positive])}")
    attempt_path = Path.join(root, "attempt-ledger.dets")
    recovery_root = Path.join(root, "recovery")
    File.mkdir_p!(root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :in_progress
      })

    config = Config.settings!()
    tracker_identity = Tracker.identity(config.tracker)
    {:ok, recovery} = RecoveryLedger.open(project_id, tracker_identity, root: recovery_root)

    checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: project_id,
      work_item_id: issue.id,
      last_validated_lifecycle_state: :in_progress,
      durable_guard_evidence: [],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }

    assert :ok = RecoveryLedger.put_sync(recovery, checkpoint)
    assert :ok = RecoveryLedger.close(recovery)

    on_exit(fn -> File.rm_rf(root) end)

    %{
      project_id: project_id,
      root: root,
      attempt_path: attempt_path,
      recovery_root: recovery_root,
      issue: issue,
      work_item: work_item,
      tracker_identity: tracker_identity
    }
  end

  defp start_orchestrator!(fixture, opts \\ []) do
    {:ok, task_supervisor} = Task.Supervisor.start_link(Keyword.take(opts, [:max_children]))
    Process.unlink(task_supervisor)
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
    issue = fixture.issue

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        task_supervisor: task_supervisor,
        agent_runner: SymphonyElixir.H080AAuthorityFenceProbeRunner,
        start_quiesced: Keyword.get(opts, :start_quiesced, false),
        work_control: %{issue.id => fixture.work_item},
        attempt_ledger_opts:
          Keyword.merge(
            [
              path: fixture.attempt_path,
              write_fun: Keyword.get(opts, :attempt_write_fun, &:dets.insert/2),
              sync_fun: Keyword.get(opts, :attempt_sync_fun, attempt_sync_fun(observer, issue.id, sequence))
            ],
            Keyword.get(opts, :attempt_ledger_opts, [])
          ),
        recovery_ledger_opts:
          Keyword.merge(
            [root: fixture.recovery_root],
            Keyword.get(opts, :recovery_ledger_opts, [])
          )
      )

    Process.unlink(orchestrator)

    on_exit(fn -> stop_fixture_processes(orchestrator, task_supervisor) end)
    {orchestrator, task_supervisor}
  end

  defp attempt_sync_fun(observer, issue_id, sequence, fail_state \\ nil) do
    failed = :atomics.new(1, [])

    fn table ->
      actual_result = :dets.sync(table)
      report_attempt_sync(table, observer, issue_id, sequence, fail_state, failed, actual_result)
    end
  end

  defp report_attempt_sync(table, observer, issue_id, sequence, fail_state, failed, actual_result) do
    case :dets.lookup(table, {:current, issue_id}) do
      [{{:current, ^issue_id}, %{authority_fence: fence, in_flight: in_flight} = record}]
      when is_map(fence) ->
        context = %{
          observer: observer,
          issue_id: issue_id,
          sequence: sequence,
          fail_state: fail_state,
          failed: failed,
          actual_result: actual_result
        }

        report_attempt_sync_record(context, fence, in_flight, record)

      _other ->
        actual_result
    end
  end

  defp report_attempt_sync_record(context, fence, in_flight, record) do
    event = :atomics.add_get(context.sequence, 1, 1)
    target? = sync_failure_target?(context.fail_state, fence.state, in_flight)
    occurrence = if target?, do: :atomics.add_get(context.failed, 1, 1), else: 0
    failed_sync? = target? and occurrence == sync_failure_occurrence(context.fail_state)
    reported_result = if failed_sync?, do: :injected_sync_failure, else: context.actual_result

    send(context.observer, {
      :h080a_attempt_sync,
      context.issue_id,
      event,
      %{
        state: fence.state,
        in_flight: in_flight,
        runtime_attempt: Map.get(fence, :runtime_attempt),
        safety_counters: Map.get(record, :safety_counters),
        result: reported_result
      }
    })

    if failed_sync?, do: {:error, :injected_sync_failure}, else: context.actual_result
  end

  defp recovery_sync_fun(observer, issue_id, sequence, inject_failure \\ false) do
    failed = :atomics.new(1, [])

    fn table ->
      result = :dets.sync(table)
      report_recovery_sync(table, observer, issue_id, sequence, inject_failure, failed, result)
    end
  end

  defp report_recovery_sync(table, observer, issue_id, sequence, inject_failure, failed, result) do
    case :dets.lookup(table, {:current, issue_id}) do
      [{{:current, ^issue_id}, %{active_suspension_context: %{} = context}}] ->
        report_recovery_sync_context(observer, issue_id, sequence, inject_failure, failed, result, context)

      _other ->
        result
    end
  end

  defp report_recovery_sync_context(observer, issue_id, sequence, inject_failure, failed, result, context) do
    event = :atomics.add_get(sequence, 1, 1)
    failed_sync? = inject_failure and :atomics.add_get(failed, 1, 1) == 1
    reported_result = if failed_sync?, do: :injected_sync_failure, else: result

    send(observer, {
      :h080a_recovery_sync,
      issue_id,
      event,
      %{active_suspension_context: context, result: reported_result}
    })

    if failed_sync?, do: {:error, :injected_sync_failure}, else: result
  end

  defp failing_recovery_write_fun(observer, issue_id, mode) do
    failed = :atomics.new(1, [])

    fn table, records ->
      active_record =
        Enum.find_value(records, fn
          {{:current, ^issue_id}, %{active_suspension_context: context} = record} when not is_nil(context) -> record
          _other -> nil
        end)

      if active_record && :atomics.add_get(failed, 1, 1) == 1 do
        send(observer, {:h080a_recovery_write_failure, issue_id, mode})
        insert_recovery_record_after_failure(table, records, mode)
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end
  end

  defp insert_recovery_record_after_failure(table, records, :after), do: :ok = :dets.insert(table, records)
  defp insert_recovery_record_after_failure(_table, _records, _mode), do: :ok

  defp failing_recovery_sync_fun(observer, issue_id, sequence),
    do: recovery_sync_fun(observer, issue_id, sequence, true)

  defp crashing_attempt_sync_fun(
         observer,
         issue_id,
         sequence,
         target_state \\ :suspension_pending,
         target_in_flight \\ true,
         target_occurrence \\ 1
       ) do
    sync = attempt_sync_fun(observer, issue_id, sequence)
    matching_syncs = :atomics.new(1, [])

    fn table ->
      result = sync.(table)

      if attempt_sync_crash_target?(
           table,
           issue_id,
           target_state,
           target_in_flight,
           target_occurrence,
           matching_syncs
         ) do
        Process.exit(self(), :kill)
      end

      result
    end
  end

  defp attempt_sync_crash_target?(table, issue_id, target_state, target_in_flight, target_occurrence, counter) do
    case record_for_table(table, issue_id) do
      %{authority_fence: %{state: ^target_state}, in_flight: ^target_in_flight} ->
        :atomics.add_get(counter, 1, 1) == target_occurrence

      _other ->
        false
    end
  end

  defp crashing_recovery_sync_fun(observer, issue_id, sequence) do
    sync = recovery_sync_fun(observer, issue_id, sequence)

    fn table ->
      result = sync.(table)

      case record_for_table(table, issue_id) do
        %{active_suspension_context: %{} = context} when not is_nil(context) -> Process.exit(self(), :kill)
        _other -> result
      end
    end
  end

  defp assert_restart_recovers_after_crash(boundary) do
    issue = active_issue("h080a-crash-#{boundary}")
    fixture = fixture!(issue, "crash-#{boundary}")
    sequence = Application.fetch_env!(:symphony_elixir, :h080a_event_sequence)
    observer = Application.fetch_env!(:symphony_elixir, :h080a_event_observer)
    assessment = blocked_assessment(issue.id)
    Application.put_env(:symphony_elixir, :h080a_runner_action, {:suspend, assessment})

    opts =
      case boundary do
        :pending_fence ->
          [start_quiesced: true, attempt_sync_fun: crashing_attempt_sync_fun(observer, issue.id, sequence)]

        :recovery_context ->
          [
            start_quiesced: true,
            recovery_ledger_opts: [sync_fun: crashing_recovery_sync_fun(observer, issue.id, sequence)]
          ]
      end

    {orchestrator, task_supervisor} = start_orchestrator!(fixture, opts)
    orchestrator_monitor = Process.monitor(orchestrator)
    send(orchestrator, :tick)

    assert_receive {:h080a_child_first_instruction, _child_event, child, issue_id, %Identity{} = identity}, 5_000
    assert issue_id == issue.id
    assert_receive {:h080a_suspension_event_sent, ^issue_id, ^identity}, 5_000

    case boundary do
      :pending_fence ->
        assert_receive(
          {:h080a_attempt_sync, ^issue_id, _event, pending_record}
          when pending_record.state == :suspension_pending and pending_record.in_flight and
                 pending_record.runtime_attempt == identity,
          5_000
        )

      :recovery_context ->
        assert_receive {:h080a_recovery_sync, ^issue_id, _event, %{active_suspension_context: %{status: :open}}},
                       5_000
    end

    assert_receive {:DOWN, ^orchestrator_monitor, :process, ^orchestrator, :killed}, 5_000

    {:ok, attempts} = open_attempt!(fixture)
    {:ok, recovery} = open_recovery!(fixture)

    assert {:ok,
            %{
              in_flight: true,
              authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity, intent: intent}
            }} =
             AttemptLedger.current(attempts, issue.id)

    assert {:ok, checkpoint} = RecoveryLedger.current(recovery, issue.id)

    case boundary do
      :pending_fence ->
        assert checkpoint.active_suspension_context == nil

      :recovery_context ->
        assert checkpoint.active_suspension_context.suspension_id == intent.suspension_id
    end

    assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    assert :ok = RecoveryLedger.close(recovery)
    assert :ok = AttemptLedger.close(attempts)

    {restarted_orchestrator, restarted_task_supervisor} =
      start_orchestrator!(fixture, start_quiesced: true, max_children: 0)

    initial_state = :sys.get_state(restarted_orchestrator)
    assert initial_state.startup_reconciliation == :pending
    assert MapSet.member?(initial_state.durable_in_flight, issue.id)

    send(restarted_orchestrator, :run_poll_cycle)
    _restart_barrier = GenServer.call(restarted_orchestrator, :snapshot)
    recovered_state = :sys.get_state(restarted_orchestrator)

    assert recovered_state.startup_reconciliation == :ready
    assert MapSet.member?(recovered_state.durable_in_flight, issue.id)
    assert not WorkItem.dispatchable?(recovered_state.work_control[issue.id])

    assert recovered_state.work_control[issue.id].suspension_context.suspension_id ==
             intent.suspension_id

    assert {:ok,
            %{
              in_flight: true,
              authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}
            }} =
             AttemptLedger.current(recovered_state.attempt_ledger, issue.id)

    assert {:ok, recovered_checkpoint} = RecoveryLedger.current(recovered_state.recovery_ledger, issue.id)
    assert recovered_checkpoint.active_suspension_context.suspension_id == intent.suspension_id
    assert recovered_checkpoint.active_suspension_context.status in [:open, :resolving]

    refute_receive {:h080a_child_first_instruction, _, _, ^issue_id, _}, 0
    assert Process.alive?(child)

    stop_fixture_processes(restarted_orchestrator, restarted_task_supervisor)
    stop_fixture_processes(orchestrator, task_supervisor)
  end

  defp record_for_table(table, issue_id) do
    case :dets.lookup(table, {:current, issue_id}) do
      [{{:current, ^issue_id}, record}] -> record
      _other -> nil
    end
  end

  defp bound_runtime_state(fixture, attempts, recovery) do
    issue = fixture.issue
    assert {:ok, armed} = AttemptLedger.begin_attempt(attempts, issue.id)
    identity = Identity.allocate(issue.id, Route.legacy(issue), armed.lineage_id)
    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(attempts, issue.id, identity)
    assert {:ok, checkpoint} = RecoveryLedger.current(recovery, issue.id)

    state = %State{
      running: %{
        issue.id => %{
          identifier: issue.identifier,
          runtime_attempt: RuntimeAttempt.new(identity, :running),
          started_at: DateTime.utc_now()
        }
      },
      attempt_ledger: attempts,
      attempt_ledger_status: :ready,
      attempt_lineages: %{issue.id => armed.lineage_id},
      durable_in_flight: MapSet.new([issue.id]),
      recovery_ledger: recovery,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{issue.id => checkpoint},
      work_control: %{issue.id => fixture.work_item}
    }

    {state, identity, checkpoint}
  end

  defp recovery_state(fixture, attempts, recovery, checkpoint) do
    {:ok, record} = AttemptLedger.current(attempts, fixture.issue.id)

    %State{
      attempt_ledger: attempts,
      attempt_ledger_status: :ready,
      attempt_lineages: %{fixture.issue.id => record.lineage_id},
      durable_in_flight: MapSet.new([fixture.issue.id]),
      recovery_ledger: recovery,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{fixture.issue.id => checkpoint},
      work_control: %{fixture.issue.id => fixture.work_item},
      dependency_diagnostics: %{fixture.issue.id => %{allowed?: true}}
    }
  end

  defp open_attempt!(fixture, opts \\ []) do
    result =
      AttemptLedger.open(
        fixture.project_id,
        fixture.tracker_identity,
        Keyword.put_new(opts, :path, fixture.attempt_path)
      )

    case result do
      {:ok, ledger} = opened ->
        register_attempt_cleanup(ledger)
        opened

      other ->
        other
    end
  end

  defp open_recovery!(fixture, opts \\ []) do
    result =
      RecoveryLedger.open(
        fixture.project_id,
        fixture.tracker_identity,
        Keyword.put_new(opts, :root, fixture.recovery_root)
      )

    case result do
      {:ok, ledger} = opened ->
        register_recovery_cleanup(ledger)
        opened

      other ->
        other
    end
  end

  defp register_attempt_cleanup(ledger),
    do: on_exit(fn -> close_attempt_if_open(ledger) end)

  defp close_attempt_if_open(ledger) do
    if ledger.table in :dets.all(), do: AttemptLedger.close(ledger)
  end

  defp register_recovery_cleanup(ledger),
    do: on_exit(fn -> close_recovery_if_open(ledger) end)

  defp close_recovery_if_open(ledger) do
    if ledger.table in :dets.all(), do: RecoveryLedger.close(ledger)
  end

  defp failing_attempt_write_fun(observer, issue_id, fail_state, mode) do
    failed = :atomics.new(1, [])

    fn table, records ->
      record =
        Enum.find_value(records, fn
          {{:current, ^issue_id}, candidate} -> candidate
          _other -> nil
        end)

      should_fail? =
        is_map(record) and
          write_failure_target?(fail_state, Map.get(record, :authority_fence), Map.get(record, :in_flight, false)) and
          :atomics.add_get(failed, 1, 1) == 1

      if should_fail? do
        send(observer, {:h080a_attempt_write_failure, issue_id, fail_state, mode})
        insert_attempt_record_after_failure(table, records, mode)
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end
  end

  defp crashing_attempt_write_fun(observer, issue_id, {target_state, target_in_flight}) do
    fn table, records ->
      if attempt_write_crash_target?(records, issue_id, target_state, target_in_flight) do
        send(observer, {:h080a_attempt_write_crash, issue_id, target_state, target_in_flight})
        Process.exit(self(), :kill)
      end

      :dets.insert(table, records)
    end
  end

  defp attempt_write_crash_target?(records, issue_id, target_state, target_in_flight) do
    Enum.any?(records, fn
      {{:current, ^issue_id}, %{authority_fence: %{state: ^target_state}, in_flight: ^target_in_flight}} ->
        true

      _other ->
        false
    end)
  end

  defp insert_attempt_record_after_failure(table, records, :after), do: :ok = :dets.insert(table, records)
  defp insert_attempt_record_after_failure(_table, _records, _mode), do: :ok

  defp sync_failure_target?(nil, _state, _in_flight), do: false
  defp sync_failure_target?(state, state, _in_flight) when is_atom(state), do: true
  defp sync_failure_target?({state, in_flight, _occurrence}, state, in_flight), do: true
  defp sync_failure_target?(_target, _state, _in_flight), do: false

  defp sync_failure_occurrence({_state, _in_flight, occurrence}), do: occurrence
  defp sync_failure_occurrence(_state), do: 1

  defp write_failure_target?(state, %{state: state}, _in_flight) when is_atom(state), do: true
  defp write_failure_target?({state, in_flight}, %{state: state}, in_flight), do: true
  defp write_failure_target?(_target, _fence, _in_flight), do: false

  defp suspension_intent(issue_id) do
    assessment = blocked_assessment(issue_id)

    %{
      reason: :provider_blocked,
      provider_observation: assessment.provider_observation,
      required_evidence: [],
      created_at: assessment.assessed_at
    }
  end

  defp terminal_context(issue_id, lineage_id, intent, terminal_status \\ :resolved) do
    {:ok, open} =
      SuspensionContext.new(%{
        work_item_id: issue_id,
        suspension_id: intent.suspension_id,
        last_validated_lifecycle_state: :in_progress,
        provider_observation: intent.provider_observation,
        reason: intent.reason,
        lineage_generation: lineage_id,
        created_at: intent.created_at,
        recovery_policy: :fresh_reconciliation,
        required_evidence: intent.required_evidence,
        resume_target: :in_progress
      })

    {:ok, resolving} = SuspensionContext.begin_resolution(open)

    case terminal_status do
      :resolved ->
        {:ok, resolved} =
          SuspensionContext.resolve(resolving, %{
            fresh_reconciliation: true,
            resume_target: :in_progress,
            required_evidence: intent.required_evidence
          })

        resolved

      :escalated ->
        {:ok, escalated} = SuspensionContext.escalate(resolving, :operator_escalation)
        escalated
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp active_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: String.upcase(issue_id),
      title: "H-080A runtime fence characterization",
      state: "In Progress",
      dispatchable: true
    }
  end

  defp blocked_assessment(issue_id) do
    now = DateTime.utc_now()

    observation = %ProviderObservation{
      provider: :memory,
      work_item_id: issue_id,
      provider_state_name: "Blocked",
      observed_at: now
    }

    %LifecycleAssessment{
      work_item_id: issue_id,
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
  end

  defp stop_fixture_processes(orchestrator, task_supervisor) do
    if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
    if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
    :ok
  end
end
