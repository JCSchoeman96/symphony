defmodule SymphonyElixir.H080AAuthorityFenceProbeRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, recipient, opts) do
    identity = Keyword.fetch!(opts, :runtime_attempt_identity)
    send(recipient, {:h080a_child_first_instruction, self(), issue.id, identity})

    receive do
      :h080a_stop -> :ok
    end
  end
end

defmodule SymphonyElixir.H080AAuthorityFenceCharacterizationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
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

  @tracker_identity %{tracker_kind: "memory", provider_scope: %{}}

  test "the first child instruction follows a synced BOUND record, and runtime loss keeps it fenced" do
    fixture = fixture!("bound-first-instruction")
    issue = issue("bound-first-instruction")
    route = Route.legacy(issue)
    {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id, route_fingerprint: route.fingerprint)
    identity = Identity.allocate(issue.id, route, armed.lineage_id)
    runtime_attempt = RuntimeAttempt.new(identity, :starting)
    owner = self()

    attempts = %{
      fixture.attempts
      | sync_fun: fn table ->
          result = :dets.sync(table)

          if result == :ok and fence_state(table, issue.id) == :bound do
            send(owner, {:h080a_bound_synced, issue.id, identity})
          end

          result
        end
    }

    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :kill) end)

    state =
      base_state(fixture, issue.id)
      |> Map.put(:attempt_ledger, attempts)
      |> Map.put(:task_supervisor, supervisor)
      |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
      |> then(&struct(State, &1))

    _started = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)

    assert_receive {:h080a_bound_synced, issue_id, ^identity}, 1_000
    assert_receive {:h080a_child_first_instruction, child, ^issue_id, ^identity}, 1_000
    assert Process.alive?(child)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    ref = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^ref, :process, ^child, _reason}, 1_000
    Supervisor.stop(supervisor)

    assert :ok = AttemptLedger.close(attempts)
    {:ok, reopened} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

    state =
      %State{
        attempt_ledger: reopened,
        attempt_ledger_status: :ready,
        durable_in_flight: MapSet.new([issue.id]),
        work_control: %{issue.id => eligible_work_item(issue)},
        dependency_diagnostics: %{issue.id => %{allowed?: true}}
      }

    assert {:ok, restarted} = Orchestrator.clear_stale_in_flight_for_test(state, issue.id)
    assert restarted.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(reopened, issue.id)
  end

  test "failed BOUND writes leave ARMED recoverable, while failed BOUND syncs keep BOUND blocked" do
    for failure <- [:write, :sync] do
      fixture = fixture!("bound-#{failure}")
      issue = issue("bound-#{failure}")
      route = Route.legacy(issue)
      {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id, route_fingerprint: route.fingerprint)
      identity = Identity.allocate(issue.id, route, armed.lineage_id)
      runtime_attempt = RuntimeAttempt.new(identity, :starting)
      failed_attempts = fail_fence_persistence(fixture.attempts, issue.id, :bound, failure)
      {:ok, supervisor} = Task.Supervisor.start_link()
      on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :kill) end)

      state =
        base_state(fixture, issue.id)
        |> Map.put(:attempt_ledger, failed_attempts)
        |> Map.put(:task_supervisor, supervisor)
        |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
        |> then(&struct(State, &1))

      _blocked = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)
      refute_receive {:h080a_child_first_instruction, _child, _, _identity}, 50

      assert :ok = AttemptLedger.close(failed_attempts)
      {:ok, reopened} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

      case failure do
        :write ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :armed}}} =
                   AttemptLedger.current(reopened, issue.id)

          armed_state = %State{
            attempt_ledger: reopened,
            attempt_ledger_status: :ready,
            durable_in_flight: MapSet.new([issue.id])
          }

          assert {:ok, recovered} = Orchestrator.clear_stale_in_flight_for_test(armed_state, issue.id)
          assert MapSet.new() == recovered.durable_in_flight

          assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} =
                   AttemptLedger.current(reopened, issue.id)

        :sync ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(reopened, issue.id)

          bound_state = %State{
            attempt_ledger: reopened,
            attempt_ledger_status: :ready,
            durable_in_flight: MapSet.new([issue.id]),
            work_control: %{issue.id => eligible_work_item(issue)},
            dependency_diagnostics: %{issue.id => %{allowed?: true}}
          }

          assert {:ok, blocked} = Orchestrator.clear_stale_in_flight_for_test(bound_state, issue.id)
          assert blocked.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved

          assert {:ok, %{in_flight: true, authority_fence: %{state: :bound}}} =
                   AttemptLedger.current(reopened, issue.id)
      end
    end
  end

  test "an ARMED reservation can be retired after a crash before binding any runtime" do
    fixture = fixture!("armed-restart")
    issue = issue("armed-restart")

    {:ok, %{in_flight: true, authority_fence: %{state: :armed}}} =
      AttemptLedger.begin_attempt(fixture.attempts, issue.id)

    assert :ok = AttemptLedger.close(fixture.attempts)
    {:ok, reopened} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

    state = %State{attempt_ledger: reopened, attempt_ledger_status: :ready, durable_in_flight: MapSet.new([issue.id])}
    assert {:ok, recovered} = Orchestrator.clear_stale_in_flight_for_test(state, issue.id)
    assert recovered.durable_in_flight == MapSet.new()
    assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} = AttemptLedger.current(reopened, issue.id)
    refute_receive {:h080a_child_first_instruction, _, _, _}, 50
  end

  test "a child start rejection happens after BOUND and runs no child instruction" do
    fixture = fixture!("child-start-rejected")
    issue = issue("child-start-rejected")
    route = Route.legacy(issue)
    {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id, route_fingerprint: route.fingerprint)
    identity = Identity.allocate(issue.id, route, armed.lineage_id)
    runtime_attempt = RuntimeAttempt.new(identity, :starting)
    owner = self()

    attempts = %{
      fixture.attempts
      | sync_fun: fn table ->
          result = :dets.sync(table)

          if result == :ok and fence_state(table, issue.id) == :bound do
            send(owner, {:h080a_bound_synced, issue.id, identity})
          end

          result
        end
    }

    {:ok, supervisor} = Task.Supervisor.start_link(max_children: 0)
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :kill) end)

    state =
      base_state(fixture, issue.id)
      |> Map.put(:attempt_ledger, attempts)
      |> Map.put(:task_supervisor, supervisor)
      |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
      |> then(&struct(State, &1))

    started = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)

    issue_id = issue.id
    assert_receive {:h080a_bound_synced, ^issue_id, ^identity}, 1_000
    refute_receive {:h080a_child_first_instruction, _, _, _}, 50
    assert started.running == %{}
    assert Map.has_key?(started.retry_attempts, issue.id)

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)
  end

  test "a mismatched DOWN process cannot release the live runtime fence" do
    fixture = fixture!("mismatched-down")
    issue = issue("mismatched-down")
    route = Route.legacy(issue)
    {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id, route_fingerprint: route.fingerprint)
    identity = Identity.allocate(issue.id, route, armed.lineage_id)
    runtime_attempt = RuntimeAttempt.new(identity, :starting)
    owner = self()

    attempts = %{
      fixture.attempts
      | sync_fun: fn table ->
          result = :dets.sync(table)

          if result == :ok and fence_state(table, issue.id) == :bound do
            send(owner, {:h080a_bound_synced, issue.id, identity})
          end

          result
        end
    }

    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> if Process.alive?(supervisor), do: Process.exit(supervisor, :kill) end)

    state =
      base_state(fixture, issue.id)
      |> Map.put(:attempt_ledger, attempts)
      |> Map.put(:task_supervisor, supervisor)
      |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
      |> then(&struct(State, &1))

    started = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)
    issue_id = issue.id
    assert_receive {:h080a_bound_synced, ^issue_id, ^identity}, 1_000
    assert_receive {:h080a_child_first_instruction, child, ^issue_id, ^identity}, 1_000
    running = started.running[issue.id]

    assert {:noreply, unchanged} =
             Orchestrator.handle_info({:DOWN, make_ref(), :process, self(), :normal}, started)

    assert unchanged == started
    assert Process.alive?(child)

    assert {:noreply, _after_mismatched_down} =
             Orchestrator.handle_info({:DOWN, running.ref, :process, self(), :normal}, started)

    assert Process.alive?(child)

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)
  end

  test "suspension fence and recovery checkpoint faults preserve the exact runtime across restart" do
    for {ledger_kind, failure} <- [
          {:attempt, :write},
          {:attempt, :sync},
          {:recovery, :write},
          {:recovery, :sync}
        ] do
      fixture = fixture!("suspend-#{ledger_kind}-#{failure}")
      issue = issue("suspend-#{ledger_kind}-#{failure}")
      now = DateTime.utc_now()
      work_item = eligible_work_item(issue, now)
      checkpoint = checkpoint(fixture.project_id, issue.id, now)
      assert :ok = RecoveryLedger.put_sync(fixture.recovery, checkpoint)
      {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id)
      identity = runtime_identity(issue.id, armed.lineage_id, "runtime-#{ledger_kind}-#{failure}")
      assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(fixture.attempts, issue.id, identity)

      event_attempts =
        if ledger_kind == :attempt,
          do: fail_fence_persistence(fixture.attempts, issue.id, :suspension_pending, failure),
          else: fixture.attempts

      event_recovery =
        if ledger_kind == :recovery,
          do: fail_recovery_persistence(fixture.recovery, issue.id, failure),
          else: fixture.recovery

      state = suspension_state(issue, work_item, checkpoint, event_attempts, event_recovery, identity, armed.lineage_id)
      assessment = blocked_assessment(issue.id, now)

      assert {:noreply, after_event} =
               Orchestrator.handle_info(
                 {:agent_lifecycle_suspended, issue.id, identity, assessment},
                 state
               )

      assert after_event.running[issue.id].lifecycle_suspension
      assert {:ok, record} = AttemptLedger.current(event_attempts, issue.id)
      assert record.in_flight
      assert record.authority_fence.runtime_attempt == identity
      assert {:ok, checkpoint_after_event} = RecoveryLedger.current(event_recovery, issue.id)

      if ledger_kind == :attempt and failure == :write do
        assert record.authority_fence.state == :bound
      else
        assert record.authority_fence.state == :suspension_pending
        assert record.authority_fence.intent.suspension_id == suspension_id(identity)
      end

      if failure == :write or ledger_kind == :attempt do
        assert checkpoint_after_event.active_suspension_context == nil
      else
        assert checkpoint_after_event.active_suspension_context.status == :open
        assert checkpoint_after_event.active_suspension_context.suspension_id == suspension_id(identity)
      end

      assert :ok = AttemptLedger.close(event_attempts)
      assert :ok = RecoveryLedger.close(event_recovery)
      {:ok, reopened_attempts} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)
      {:ok, reopened_recovery} = RecoveryLedger.open(fixture.project_id, @tracker_identity, path: fixture.recovery_path)

      assert {:ok, reopened_record} = AttemptLedger.current(reopened_attempts, issue.id)
      assert reopened_record.in_flight
      assert reopened_record.authority_fence.runtime_attempt == identity

      if reopened_record.authority_fence.state == :suspension_pending do
        checkpoint_after_restart = recovery_checkpoint(reopened_recovery, issue.id)

        restart_state = %State{
          attempt_ledger: reopened_attempts,
          attempt_ledger_status: :ready,
          durable_in_flight: MapSet.new([issue.id]),
          attempt_lineages: %{issue.id => armed.lineage_id},
          recovery_ledger: reopened_recovery,
          recovery_ledger_status: :ready,
          recovery_checkpoints: %{issue.id => checkpoint_after_restart},
          work_control: %{issue.id => work_item}
        }

        assert {:ok, restored} = Orchestrator.restore_pending_authority_suspensions_for_test(restart_state)
        assert MapSet.member?(restored.durable_in_flight, issue.id)

        assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending, runtime_attempt: ^identity}}} =
                 AttemptLedger.current(reopened_attempts, issue.id)

        assert {:ok, %{active_suspension_context: %SuspensionContext{status: :open}}} =
                 RecoveryLedger.current(reopened_recovery, issue.id)
      else
        assert reopened_record.authority_fence.state == :bound

        assert {:ok, blocked} =
                 Orchestrator.clear_stale_in_flight_for_test(
                   %State{attempt_ledger: reopened_attempts, attempt_ledger_status: :ready, durable_in_flight: MapSet.new([issue.id])},
                   issue.id
                 )

        assert blocked.durable_blocked[issue.id] == :stale_in_flight_authority_fence_unresolved
      end
    end
  end

  test "matching terminal recovery applies RELEASED before clearing in-flight, with restart at each cut" do
    for cut <- [:release_write, :release_sync, :clear_write, :clear_sync] do
      fixture = fixture!("recovery-#{cut}")
      issue = issue("recovery-#{cut}")
      now = DateTime.utc_now()
      work_item = eligible_work_item(issue, now)
      {:ok, armed} = AttemptLedger.begin_attempt(fixture.attempts, issue.id)
      identity = runtime_identity(issue.id, armed.lineage_id, "runtime-#{cut}")
      assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(fixture.attempts, issue.id, identity)
      assert {:ok, pending} = AttemptLedger.mark_suspension_pending(fixture.attempts, issue.id, identity, suspension_intent(issue.id, now))
      terminal = terminal_context(issue.id, armed.lineage_id, pending.authority_fence.intent.suspension_id, now)
      terminal_checkpoint = checkpoint(fixture.project_id, issue.id, now, nil, terminal)
      assert :ok = RecoveryLedger.put_sync(fixture.recovery, terminal_checkpoint)

      assert :ok = AttemptLedger.close(fixture.attempts)
      assert :ok = RecoveryLedger.close(fixture.recovery)
      {:ok, attempts_after_terminal} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)
      {:ok, recovery_after_terminal} = RecoveryLedger.open(fixture.project_id, @tracker_identity, path: fixture.recovery_path)
      attempts = recovery_cut_attempt_ledger(attempts_after_terminal, issue.id, cut)

      state = %State{
        attempt_ledger: attempts,
        attempt_ledger_status: :ready,
        durable_in_flight: MapSet.new([issue.id]),
        attempt_lineages: %{issue.id => armed.lineage_id},
        recovery_ledger: recovery_after_terminal,
        recovery_ledger_status: :ready,
        recovery_checkpoints: %{issue.id => terminal_checkpoint},
        work_control: %{issue.id => work_item},
        dependency_diagnostics: %{issue.id => %{allowed?: true}}
      }

      assert {:ok, after_recovery} = Orchestrator.restore_pending_authority_suspensions_for_test(state)
      assert MapSet.member?(after_recovery.durable_in_flight, issue.id)

      case cut do
        :release_write ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :suspension_pending}}} =
                   AttemptLedger.current(attempts, issue.id)

        :release_sync ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)

        :clear_write ->
          assert {:ok, %{in_flight: true, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)

        :clear_sync ->
          assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
                   AttemptLedger.current(attempts, issue.id)
      end

      assert :ok = AttemptLedger.close(attempts)
      assert :ok = RecoveryLedger.close(recovery_after_terminal)
      {:ok, reopened_attempts} = AttemptLedger.open(fixture.project_id, @tracker_identity, path: fixture.attempt_path)
      {:ok, reopened_recovery} = RecoveryLedger.open(fixture.project_id, @tracker_identity, path: fixture.recovery_path)

      restarted_state = %State{
        attempt_ledger: reopened_attempts,
        attempt_ledger_status: :ready,
        durable_in_flight: MapSet.new([issue.id]),
        attempt_lineages: %{issue.id => armed.lineage_id},
        recovery_ledger: reopened_recovery,
        recovery_ledger_status: :ready,
        recovery_checkpoints: %{issue.id => terminal_checkpoint},
        work_control: %{issue.id => work_item},
        dependency_diagnostics: %{issue.id => %{allowed?: true}}
      }

      case cut do
        :release_write ->
          assert {:ok, recovered} = Orchestrator.restore_pending_authority_suspensions_for_test(restarted_state)
          assert recovered.durable_in_flight == MapSet.new()

        :release_sync ->
          assert {:ok, released} = Orchestrator.restore_pending_authority_suspensions_for_test(restarted_state)
          assert MapSet.member?(released.durable_in_flight, issue.id)
          assert {:ok, cleared} = Orchestrator.clear_stale_in_flight_for_test(released, issue.id)
          assert cleared.durable_in_flight == MapSet.new()

        :clear_write ->
          assert {:ok, cleared} = Orchestrator.clear_stale_in_flight_for_test(restarted_state, issue.id)
          assert cleared.durable_in_flight == MapSet.new()

        :clear_sync ->
          assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} =
                   AttemptLedger.current(reopened_attempts, issue.id)
      end

      assert {:ok, %{in_flight: false, authority_fence: %{state: :released}}} =
               AttemptLedger.current(reopened_attempts, issue.id)
    end
  end

  defp fixture!(label) do
    root = Path.join(System.tmp_dir!(), "h080a-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project_id = "h080a-#{label}-#{System.unique_integer([:positive])}"
    attempt_path = Path.join(root, "attempts.dets")
    recovery_path = Path.join(root, "recovery.dets")
    {:ok, attempts} = AttemptLedger.open(project_id, @tracker_identity, path: attempt_path)
    {:ok, recovery} = RecoveryLedger.open(project_id, @tracker_identity, path: recovery_path)

    on_exit(fn ->
      safe_close(attempts)
      safe_close(recovery)
      File.rm_rf(root)
    end)

    %{
      root: root,
      project_id: project_id,
      attempt_path: attempt_path,
      recovery_path: recovery_path,
      attempts: attempts,
      recovery: recovery
    }
  end

  defp base_state(fixture, issue_id) do
    %{
      attempt_ledger: fixture.attempts,
      attempt_ledger_status: :ready,
      recovery_ledger: fixture.recovery,
      recovery_ledger_status: :ready,
      durable_in_flight: MapSet.new([issue_id]),
      attempt_lineages: %{},
      work_control: %{},
      dependency_diagnostics: %{},
      running: %{},
      blocked: %{},
      retry_attempts: %{},
      attempt_counters: %{},
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(id) do
    %Issue{id: id, identifier: String.upcase(id), title: "Authority fence probe", state: "In Progress", dispatchable: true}
  end

  defp eligible_work_item(issue, now \\ DateTime.utc_now()) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: now,
        prior_validated_lifecycle_state: :in_progress
      })

    work_item
  end

  defp runtime_identity(issue_id, lineage_id, runtime_id) do
    %Identity{
      runtime_attempt_id: runtime_id,
      work_item_id: issue_id,
      lineage_generation: lineage_id,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }
  end

  defp suspension_state(issue, work_item, checkpoint, attempts, recovery, identity, lineage_id) do
    now = DateTime.utc_now()

    %State{
      running: %{
        issue.id => %{
          runtime_attempt: RuntimeAttempt.new(identity, :running),
          identifier: issue.identifier,
          started_at: now
        }
      },
      attempt_ledger: attempts,
      attempt_ledger_status: :ready,
      attempt_lineages: %{issue.id => lineage_id},
      durable_in_flight: MapSet.new([issue.id]),
      recovery_ledger: recovery,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{issue.id => checkpoint},
      work_control: %{issue.id => work_item},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp blocked_assessment(issue_id, now) do
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

  defp checkpoint(project_id, issue_id, now, active \\ nil, terminal \\ nil) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: project_id,
      work_item_id: issue_id,
      last_validated_lifecycle_state: :in_progress,
      durable_guard_evidence: [],
      active_suspension_context: active,
      last_terminal_suspension_context: terminal,
      updated_at: now
    }
  end

  defp suspension_intent(issue_id, now) do
    %{
      reason: :provider_blocked,
      provider_observation: %ProviderObservation{
        provider: :memory,
        work_item_id: issue_id,
        provider_state_name: "Blocked",
        observed_at: now
      },
      required_evidence: [],
      created_at: now
    }
  end

  defp terminal_context(issue_id, lineage_id, suspension_id, now) do
    {:ok, context} =
      SuspensionContext.new(%{
        work_item_id: issue_id,
        suspension_id: suspension_id,
        last_validated_lifecycle_state: :in_progress,
        provider_observation: %ProviderObservation{
          provider: :memory,
          work_item_id: issue_id,
          provider_state_name: "Blocked",
          observed_at: now
        },
        reason: :provider_blocked,
        lineage_generation: lineage_id,
        created_at: now,
        recovery_policy: :fresh_reconciliation,
        required_evidence: [],
        resume_target: :in_progress
      })

    {:ok, resolving} = SuspensionContext.begin_resolution(context)

    {:ok, resolved} =
      SuspensionContext.resolve(resolving, %{
        fresh_reconciliation: true,
        resume_target: :in_progress,
        required_evidence: []
      })

    resolved
  end

  defp fail_fence_persistence(ledger, issue_id, target_state, failure) do
    write_fun = fn table, records ->
      if target_record?(records, issue_id, target_state) and failure == :write do
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end

    sync_fun = fn table ->
      # Persist the row, then report failure to model an ambiguous sync acknowledgment.
      result = :dets.sync(table)

      if result == :ok and fence_state(table, issue_id) == target_state and failure == :sync do
        {:error, :injected_sync_failure}
      else
        result
      end
    end

    %{ledger | write_fun: write_fun, sync_fun: sync_fun}
  end

  defp fail_recovery_persistence(ledger, issue_id, failure) do
    write_fun = fn table, records ->
      if recovery_record?(records, issue_id, :active_suspension_context) and failure == :write do
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end

    sync_fun = fn table ->
      # Persist the row, then report failure to model an ambiguous sync acknowledgment.
      result = :dets.sync(table)

      if result == :ok and recovery_context_open?(table, issue_id) and failure == :sync do
        {:error, :injected_sync_failure}
      else
        result
      end
    end

    %{ledger | write_fun: write_fun, sync_fun: sync_fun}
  end

  defp recovery_cut_attempt_ledger(ledger, issue_id, cut) do
    write_fun = fn table, records -> recovery_cut_write(table, records, issue_id, cut) end
    sync_fun = fn table -> recovery_cut_sync(table, issue_id, cut) end

    %{ledger | write_fun: write_fun, sync_fun: sync_fun}
  end

  defp recovery_cut_write(table, records, issue_id, cut) do
    cond do
      cut == :release_write and target_record?(records, issue_id, :released) ->
        {:error, :injected_release_write_failure}

      cut == :clear_write and target_in_flight_record?(records, issue_id, false) ->
        {:error, :injected_clear_write_failure}

      true ->
        :dets.insert(table, records)
    end
  end

  defp recovery_cut_sync(table, issue_id, cut) do
    # Persist the row, then report failure to model an ambiguous sync acknowledgment.
    result = :dets.sync(table)
    record = dets_current(table, issue_id)

    if result == :ok and recovery_cut_sync_failure?(cut, record) do
      {:error, :injected_sync_failure}
    else
      result
    end
  end

  defp recovery_cut_sync_failure?(:release_sync, %{authority_fence: %{state: :released}, in_flight: true}),
    do: true

  defp recovery_cut_sync_failure?(:clear_sync, %{authority_fence: %{state: :released}, in_flight: false}),
    do: true

  defp recovery_cut_sync_failure?(_cut, _record), do: false

  defp target_record?(records, issue_id, state) do
    Enum.any?(records, fn
      {{:current, ^issue_id}, %{authority_fence: %{state: ^state}}} -> true
      _record -> false
    end)
  end

  defp target_in_flight_record?(records, issue_id, value) do
    Enum.any?(records, fn
      {{:current, ^issue_id}, %{in_flight: ^value}} -> true
      _record -> false
    end)
  end

  defp recovery_record?(records, issue_id, field) do
    Enum.any?(records, fn
      {{:current, ^issue_id}, %{^field => nil}} -> true
      {{:current, ^issue_id}, %{^field => %SuspensionContext{status: :open}}} -> true
      _record -> false
    end)
  end

  defp recovery_context_open?(table, issue_id) do
    case dets_current(table, issue_id) do
      %{active_suspension_context: %SuspensionContext{status: :open}} -> true
      _record -> false
    end
  end

  defp fence_state(table, issue_id) do
    case dets_current(table, issue_id) do
      %{authority_fence: %{state: state}} -> state
      _record -> nil
    end
  end

  defp dets_current(table, issue_id) do
    case :dets.lookup(table, {:current, issue_id}) do
      [{{:current, ^issue_id}, record}] -> record
      [] -> nil
    end
  end

  defp suspension_id(%Identity{runtime_attempt_id: runtime_id}) do
    :crypto.hash(:sha256, runtime_id) |> Base.encode16(case: :lower)
  end

  defp recovery_checkpoint(ledger, issue_id) do
    {:ok, checkpoint} = RecoveryLedger.current(ledger, issue_id)
    checkpoint
  end

  defp safe_close(ledger) do
    case ledger do
      %AttemptLedger{} -> AttemptLedger.close(ledger)
      %RecoveryLedger{} -> RecoveryLedger.close(ledger)
      _ -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
