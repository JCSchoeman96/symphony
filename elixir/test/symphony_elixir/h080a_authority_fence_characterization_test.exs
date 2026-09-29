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

  setup do
    {:ok, registry} = Agent.start(fn -> %{} end)
    Process.put({__MODULE__, :resource_registry}, registry)

    on_exit(fn ->
      cleanup_resources(registry)
      Agent.stop(registry)
    end)

    :ok
  end

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

    supervisor = start_task_supervisor!()

    state =
      base_state(fixture, issue.id)
      |> Map.put(:attempt_ledger, attempts)
      |> Map.put(:task_supervisor, supervisor)
      |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
      |> then(&struct(State, &1))

    started = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)
    track_running_entries!(started)

    assert_receive {:h080a_bound_synced, issue_id, ^identity}, 1_000
    assert_receive {:h080a_child_first_instruction, child, ^issue_id, ^identity}, 1_000
    assert Process.alive?(child)
    running_ref = started.running[issue.id].ref

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    ref = Process.monitor(child)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^ref, :process, ^child, _reason}, 1_000
    Supervisor.stop(supervisor)
    Process.demonitor(ref, [:flush])
    Process.demonitor(running_ref, [:flush])

    assert :ok = close_attempt_ledger(attempts)
    reopened = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

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
      supervisor = start_task_supervisor!()

      state =
        base_state(fixture, issue.id)
        |> Map.put(:attempt_ledger, failed_attempts)
        |> Map.put(:task_supervisor, supervisor)
        |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
        |> then(&struct(State, &1))

      _blocked = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)
      refute_receive {:h080a_child_first_instruction, _child, _, _identity}, 50

      assert :ok = close_attempt_ledger(failed_attempts)
      reopened = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

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

    assert :ok = close_attempt_ledger(fixture.attempts)
    reopened = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

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

    supervisor = start_task_supervisor!(max_children: 0)

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

  test "a directly invoked handler accepts a constructed mismatched-PID DOWN tuple" do
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

    supervisor = start_task_supervisor!()

    state =
      base_state(fixture, issue.id)
      |> Map.put(:attempt_ledger, attempts)
      |> Map.put(:task_supervisor, supervisor)
      |> Map.put(:agent_runner, SymphonyElixir.H080AAuthorityFenceProbeRunner)
      |> then(&struct(State, &1))

    started = Orchestrator.spawn_prepared_issue_for_test(state, issue, route, 0, self(), nil, runtime_attempt)
    track_running_entries!(started)
    issue_id = issue.id
    assert_receive {:h080a_bound_synced, ^issue_id, ^identity}, 1_000
    assert_receive {:h080a_child_first_instruction, child, ^issue_id, ^identity}, 1_000
    running = started.running[issue.id]

    assert {:ok, %{in_flight: true, authority_fence: %{state: :bound, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    assert {:noreply, unchanged} =
             Orchestrator.handle_info({:DOWN, make_ref(), :process, self(), :normal}, started)

    assert unchanged == started
    assert Process.alive?(child)

    # This tuple is supplied by the test and is not a VM-generated monitor event.
    assert {:noreply, after_mismatched_down} =
             Orchestrator.handle_info({:DOWN, running.ref, :process, self(), :normal}, started)

    assert Process.alive?(child)
    refute Map.has_key?(after_mismatched_down.running, issue.id)

    assert {:ok, %{in_flight: false, authority_fence: %{state: :released, runtime_attempt: ^identity}}} =
             AttemptLedger.current(attempts, issue.id)

    Process.demonitor(running.ref, [:flush])
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

      assert :ok = close_attempt_ledger(event_attempts)
      assert :ok = close_recovery_ledger(event_recovery)
      reopened_attempts = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)
      reopened_recovery = open_recovery_ledger!(fixture.project_id, @tracker_identity, path: fixture.recovery_path)

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

      assert :ok = close_attempt_ledger(fixture.attempts)
      assert :ok = close_recovery_ledger(fixture.recovery)
      attempts_after_terminal = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)

      recovery_after_terminal =
        open_recovery_ledger!(fixture.project_id, @tracker_identity, path: fixture.recovery_path)

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

      assert :ok = close_attempt_ledger(attempts)
      assert :ok = close_recovery_ledger(recovery_after_terminal)
      reopened_attempts = open_attempt_ledger!(fixture.project_id, @tracker_identity, path: fixture.attempt_path)
      reopened_recovery = open_recovery_ledger!(fixture.project_id, @tracker_identity, path: fixture.recovery_path)

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
    register_resource({:root, root}, root)
    attempts = open_attempt_ledger!(project_id, @tracker_identity, path: attempt_path)
    recovery = open_recovery_ledger!(project_id, @tracker_identity, path: recovery_path)

    %{
      root: root,
      project_id: project_id,
      attempt_path: attempt_path,
      recovery_path: recovery_path,
      attempts: attempts,
      recovery: recovery
    }
  end

  defp start_task_supervisor!(opts \\ []) do
    {:ok, supervisor} = Task.Supervisor.start_link(opts)
    Process.unlink(supervisor)
    register_resource({:task_supervisor, supervisor}, supervisor)
    supervisor
  end

  defp track_running_entries!(%State{running: running}) do
    Enum.each(running, fn {_issue_id, entry} ->
      register_resource({:task_child, entry.pid}, entry.pid)
    end)
  end

  defp register_resource(key, value) do
    registry = Process.get({__MODULE__, :resource_registry})
    Agent.update(registry, &Map.put(&1, key, value))
    value
  end

  defp open_attempt_ledger!(project_id, tracker_identity, opts) do
    {:ok, ledger} = AttemptLedger.open(project_id, tracker_identity, opts)
    register_resource({:attempt_ledger, ledger.table}, ledger)
  end

  defp close_attempt_ledger(ledger) do
    result = AttemptLedger.close(ledger)
    forget_resource({:attempt_ledger, ledger.table})
    result
  end

  defp open_recovery_ledger!(project_id, tracker_identity, opts) do
    {:ok, ledger} = RecoveryLedger.open(project_id, tracker_identity, opts)
    register_resource({:recovery_ledger, ledger.table}, ledger)
  end

  defp close_recovery_ledger(ledger) do
    result = RecoveryLedger.close(ledger)
    forget_resource({:recovery_ledger, ledger.table})
    result
  end

  defp forget_resource(key) do
    registry = Process.get({__MODULE__, :resource_registry})
    Agent.update(registry, &Map.delete(&1, key))
  end

  defp cleanup_resources(registry) do
    resources = Agent.get(registry, & &1)

    resources
    |> Enum.filter(fn {key, _value} -> match?({:task_supervisor, _pid}, key) end)
    |> Enum.each(fn {{:task_supervisor, pid}, _value} ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid, :shutdown, 5_000)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    resources
    |> Enum.filter(fn {key, _value} -> match?({:attempt_ledger, _table}, key) end)
    |> Enum.each(fn {{:attempt_ledger, table}, ledger} ->
      _ = safe_close(ledger)
      unless table_closed?(table), do: raise("attempt DETS table remained open after cleanup: #{inspect(table)}")
    end)

    resources
    |> Enum.filter(fn {key, _value} -> match?({:recovery_ledger, _table}, key) end)
    |> Enum.each(fn {{:recovery_ledger, table}, ledger} ->
      _ = safe_close(ledger)
      unless table_closed?(table), do: raise("recovery DETS table remained open after cleanup: #{inspect(table)}")
    end)

    resources
    |> Enum.filter(fn {key, _value} -> match?({:task_child, _pid}, key) end)
    |> Enum.each(fn {{:task_child, pid}, _value} ->
      if Process.alive?(pid), do: raise("Task.Supervisor child remained alive after cleanup: #{inspect(pid)}")
    end)

    resources
    |> Enum.filter(fn {key, _value} -> match?({:root, _path}, key) end)
    |> Enum.each(fn {{:root, root}, _value} -> File.rm_rf!(root) end)
  end

  defp table_closed?(table), do: not Enum.member?(:dets.all(), table)

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

defmodule SymphonyElixir.H080ADownLifecycleRunner do
  @moduledoc false

  def run(issue, recipient, opts) do
    identity = Keyword.fetch!(opts, :runtime_attempt_identity)
    capture = Application.fetch_env!(:symphony_elixir, :h080a_down_lifecycle_capture)

    if is_pid(recipient) do
      send(recipient, {:runtime_attempt_session_started, issue.id, identity})
    end

    send(capture, {:h080a_runtime_child_started, issue.id, self(), identity})

    receive do
      {:h080a_exit, :normal} -> :ok
      {:h080a_exit, reason} -> exit(reason)
    end
  end
end

defmodule SymphonyElixir.H080ADownLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    LifecycleAssessment,
    ProviderObservation,
    RecoveryLedger,
    WorkItem
  }

  setup do
    {:ok, resources} = Agent.start(fn -> %{orchestrators: [], supervisors: [], children: []} end)
    Process.put({__MODULE__, :resources}, resources)

    previous_capture = Application.get_env(:symphony_elixir, :h080a_down_lifecycle_capture)
    Application.put_env(:symphony_elixir, :h080a_down_lifecycle_capture, self())

    on_exit(fn ->
      cleanup_resources(resources)
      restore_capture(previous_capture)
      Agent.stop(resources)
    end)

    :ok
  end

  test "D01 D05 D11 unknown monitor references preserve the live exact runtime" do
    fixture = lifecycle_fixture!("unknown-ref")
    {entry, before} = current_runtime!(fixture)

    assert entry.pid != self()
    assert %RuntimeAttempt{identity: %Identity{} = identity} = entry.runtime_attempt
    assert identity.work_item_id == fixture.issue.id
    assert before.authority_fence.state == :bound
    assert before.in_flight
    assert Process.alive?(entry.pid)

    # D05 and D11: matching PID fields do not compensate for an unknown reference.
    send(fixture.orchestrator, {:DOWN, make_ref(), :process, entry.pid, :normal})
    send(fixture.orchestrator, {:DOWN, make_ref(), :process, self(), :normal})
    # D01: unrelated reference and unrelated PID also leave the current entry alone.
    send(fixture.orchestrator, {:DOWN, make_ref(), :process, self(), :normal})

    after_state = :sys.get_state(fixture.orchestrator)
    assert after_state.running[fixture.issue.id] == entry
    assert after_state.durable_in_flight == MapSet.new([fixture.issue.id])
    assert {:ok, after_record} = AttemptLedger.current(after_state.attempt_ledger, fixture.issue.id)
    assert after_record.authority_fence == before.authority_fence
    assert after_record.in_flight == before.in_flight
    assert Process.alive?(entry.pid)
  end

  test "D04 D12 a constructed mismatched-PID tuple releases through the live Orchestrator path" do
    fixture = lifecycle_fixture!("constructed-mismatch")
    {entry, before} = current_runtime!(fixture)
    identity = entry.runtime_attempt.identity
    event = {:DOWN, entry.ref, :process, self(), :normal}

    assert self() != entry.pid

    assert before.authority_fence == %{
             state: :bound,
             runtime_attempt: identity,
             route_fingerprint: entry.route_fingerprint
           }

    assert before.in_flight
    assert Process.alive?(entry.pid)

    # Provenance is constructed: the test sends this tuple to the live GenServer.
    send(fixture.orchestrator, event)
    after_state = :sys.get_state(fixture.orchestrator)

    assert Map.get(after_state.running, fixture.issue.id) == nil
    refute MapSet.member?(after_state.durable_in_flight, fixture.issue.id)
    assert {:ok, after_record} = AttemptLedger.current(after_state.attempt_ledger, fixture.issue.id)
    assert after_record.authority_fence.state == :released
    assert after_record.authority_fence.runtime_attempt == identity
    refute after_record.in_flight
    # D12: the exact child remained alive after the application-delivered tuple.
    assert Process.alive?(entry.pid)
  end

  test "D02 D10 a genuine normal monitor event releases the exact runtime in durable order" do
    fixture = lifecycle_fixture!("normal-exit")
    {entry, before} = current_runtime!(fixture)
    identity = entry.runtime_attempt.identity
    assert before.authority_fence.state == :bound
    assert before.in_flight

    instrument_attempt_sync!(fixture.orchestrator, fixture.issue.id)
    trace_genuine_down!(fixture.orchestrator, entry, :normal)

    after_state =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)

        if not Map.has_key?(state.running, fixture.issue.id), do: state
      end)

    assert after_state
    refute MapSet.member?(after_state.durable_in_flight, fixture.issue.id)
    assert {:ok, after_record} = AttemptLedger.current(after_state.attempt_ledger, fixture.issue.id)
    assert after_record.authority_fence.state == :released
    assert after_record.authority_fence.runtime_attempt == identity
    refute after_record.in_flight

    sync_states = collect_sync_states([])
    assert Enum.take(sync_states, 3) == [{:released, true}, {:released, true}, {:released, false}]
    refute Process.alive?(entry.pid)

    assert {:ok, reopened} = AttemptLedger.open(fixture.project_id, Tracker.identity(Config.settings!().tracker), path: fixture.attempt_path)
    assert {:ok, reopened_record} = AttemptLedger.current(reopened, fixture.issue.id)
    assert reopened_record.authority_fence.state == :released
    assert reopened_record.authority_fence.runtime_attempt == identity
    refute reopened_record.in_flight
    assert :ok = AttemptLedger.close(reopened)
  end

  test "D03 a genuine abnormal monitor event tears down the exact current runtime" do
    fixture = lifecycle_fixture!("abnormal-exit")
    {entry, before} = current_runtime!(fixture)
    identity = entry.runtime_attempt.identity
    assert before.authority_fence.state == :bound
    assert before.in_flight

    trace_genuine_down!(fixture.orchestrator, entry, :h080a_runner_failure)

    after_state =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)

        if not Map.has_key?(state.running, fixture.issue.id), do: state
      end)

    assert after_state
    assert after_state.retry_attempts[fixture.issue.id]
    assert {:ok, after_record} = AttemptLedger.current(after_state.attempt_ledger, fixture.issue.id)
    assert after_record.authority_fence.state == :released
    assert after_record.authority_fence.runtime_attempt == identity
    refute after_record.in_flight
    refute Process.alive?(entry.pid)
  end

  test "D06 D07 a prior RuntimeAttempt DOWN cannot affect a newer one and duplicate information is inert" do
    fixture = lifecycle_fixture!("stale-runtime")
    {entry_a, before_a} = current_runtime!(fixture)
    identity_a = entry_a.runtime_attempt.identity
    assert before_a.authority_fence.state == :bound
    trace_genuine_down!(fixture.orchestrator, entry_a, :h080a_first_attempt_failure)

    state_after_a =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)

        if not Map.has_key?(state.running, fixture.issue.id) and Map.has_key?(state.retry_attempts, fixture.issue.id),
          do: state
      end)

    assert state_after_a
    {:ok, record_after_a} = AttemptLedger.current(state_after_a.attempt_ledger, fixture.issue.id)
    assert record_after_a.authority_fence.state == :released
    refute record_after_a.in_flight

    # D07: the exact attempt is already gone; replayed termination information cannot transition it again.
    send(fixture.orchestrator, {:DOWN, entry_a.ref, :process, entry_a.pid, :h080a_first_attempt_failure})
    send(fixture.orchestrator, {:DOWN, entry_a.ref, :process, entry_a.pid, :h080a_first_attempt_failure})
    after_duplicate = :sys.get_state(fixture.orchestrator)
    assert {:ok, duplicate_record} = AttemptLedger.current(after_duplicate.attempt_ledger, fixture.issue.id)
    assert duplicate_record == record_after_a
    assert after_duplicate.retry_attempts == state_after_a.retry_attempts
    refute Map.has_key?(after_duplicate.running, fixture.issue.id)

    retry = after_duplicate.retry_attempts[fixture.issue.id]
    send(fixture.orchestrator, {:retry_issue, fixture.issue.id, retry.retry_token})
    {entry_b, _identity_b} = await_runtime!(fixture, identity_a.runtime_attempt_id)
    identity_b = entry_b.runtime_attempt.identity
    state_b = :sys.get_state(fixture.orchestrator)
    {:ok, before_b} = AttemptLedger.current(state_b.attempt_ledger, fixture.issue.id)

    assert identity_b.runtime_attempt_id != identity_a.runtime_attempt_id
    assert identity_b.lineage_generation == identity_a.lineage_generation
    assert before_b.authority_fence.state == :bound
    assert before_b.authority_fence.runtime_attempt == identity_b
    assert before_b.in_flight
    assert Process.alive?(entry_b.pid)

    # D06: the old monitor reference and old child PID are stale for RuntimeAttempt B.
    send(fixture.orchestrator, {:DOWN, entry_a.ref, :process, entry_a.pid, :normal})
    after_stale = :sys.get_state(fixture.orchestrator)
    assert after_stale.running[fixture.issue.id] == entry_b
    assert {:ok, current_record} = AttemptLedger.current(after_stale.attempt_ledger, fixture.issue.id)
    assert current_record.authority_fence.state == :bound
    assert current_record.authority_fence.runtime_attempt == identity_b
    assert current_record.in_flight
    assert Process.alive?(entry_b.pid)
  end

  test "D08 genuine termination preserves an unresolved suspension fence" do
    fixture = lifecycle_fixture!("suspended-exit")
    {entry, before} = current_runtime!(fixture)
    identity = entry.runtime_attempt.identity
    now = DateTime.utc_now()
    assessment = blocked_assessment(fixture.issue.id, now)

    assert before.authority_fence.state == :bound
    send(fixture.orchestrator, {:agent_lifecycle_suspended, fixture.issue.id, identity, assessment})

    suspended =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)
        {:ok, record} = AttemptLedger.current(state.attempt_ledger, fixture.issue.id)

        if record.authority_fence.state == :suspension_pending, do: {state, record}
      end)

    assert suspended
    {suspended_state, pending_record} = suspended
    assert pending_record.in_flight
    assert suspended_state.running[fixture.issue.id].lifecycle_suspension == assessment

    assert {:ok, %{active_suspension_context: %{status: :open}}} =
             RecoveryLedger.current(suspended_state.recovery_ledger, fixture.issue.id)

    trace_genuine_down!(fixture.orchestrator, entry, :normal)

    after_down =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)
        if not Map.has_key?(state.running, fixture.issue.id), do: state
      end)

    assert after_down
    assert MapSet.member?(after_down.durable_in_flight, fixture.issue.id)
    assert {:ok, record_after_down} = AttemptLedger.current(after_down.attempt_ledger, fixture.issue.id)
    assert record_after_down.authority_fence.state == :suspension_pending
    assert record_after_down.authority_fence.runtime_attempt == identity
    assert record_after_down.in_flight

    assert {:ok, %{active_suspension_context: %{status: :open}}} =
             RecoveryLedger.current(after_down.recovery_ledger, fixture.issue.id)

    refute Process.alive?(entry.pid)

    attempt_path = after_down.attempt_ledger.path
    recovery_path = after_down.recovery_ledger.path
    assert :ok = GenServer.stop(fixture.orchestrator)

    tracker_identity = Tracker.identity(Config.settings!().tracker)
    assert {:ok, reopened_attempts} = AttemptLedger.open(fixture.project_id, tracker_identity, path: attempt_path)
    assert {:ok, reopened_recovery} = RecoveryLedger.open(fixture.project_id, tracker_identity, path: recovery_path)
    assert {:ok, reopened_record} = AttemptLedger.current(reopened_attempts, fixture.issue.id)
    assert reopened_record.authority_fence.state == :suspension_pending
    assert reopened_record.authority_fence.runtime_attempt == identity
    assert reopened_record.in_flight

    assert {:ok, %{active_suspension_context: %{status: :open}}} =
             RecoveryLedger.current(reopened_recovery, fixture.issue.id)

    assert :ok = AttemptLedger.close(reopened_attempts)
    assert :ok = RecoveryLedger.close(reopened_recovery)
  end

  test "D09 restart drops the old running entry and cannot release its durable fence" do
    fixture = lifecycle_fixture!("restart-old-child")
    {old_entry, before} = current_runtime!(fixture)
    identity = old_entry.runtime_attempt.identity
    external_ref = Process.monitor(old_entry.pid)
    assert before.authority_fence.state == :bound
    assert before.in_flight

    assert :ok = GenServer.stop(fixture.orchestrator)
    refute Process.alive?(fixture.orchestrator)

    fresh_orchestrator = start_orchestrator!(fixture, true)
    fresh_state = :sys.get_state(fresh_orchestrator)
    assert fresh_state.running == %{}
    assert MapSet.member?(fresh_state.durable_in_flight, fixture.issue.id)
    assert Process.alive?(old_entry.pid)
    assert {:ok, reopened_before} = AttemptLedger.current(fresh_state.attempt_ledger, fixture.issue.id)
    assert reopened_before.authority_fence.state == :bound
    assert reopened_before.authority_fence.runtime_attempt == identity
    assert reopened_before.in_flight

    # Constructed stale tuple delivered after restart; the fresh server has no matching running entry.
    send(fresh_orchestrator, {:DOWN, old_entry.ref, :process, old_entry.pid, :normal})
    after_stale = :sys.get_state(fresh_orchestrator)
    assert after_stale.running == %{}
    assert {:ok, still_bound} = AttemptLedger.current(after_stale.attempt_ledger, fixture.issue.id)
    assert still_bound.authority_fence.state == :bound
    assert still_bound.authority_fence.runtime_attempt == identity
    assert still_bound.in_flight

    send(old_entry.pid, {:h080a_exit, :normal})
    assert_receive {:DOWN, ^external_ref, :process, pid, :normal}, 5_000
    assert pid == old_entry.pid
    refute Process.alive?(old_entry.pid)

    # The real old monitor belonged to the stopped Orchestrator. The new process receives no such VM event.
    send(fresh_orchestrator, {:DOWN, old_entry.ref, :process, old_entry.pid, :normal})
    after_termination = :sys.get_state(fresh_orchestrator)
    assert after_termination.running == %{}
    assert {:ok, still_fenced} = AttemptLedger.current(after_termination.attempt_ledger, fixture.issue.id)
    assert still_fenced.authority_fence.state == :bound
    assert still_fenced.in_flight
  end

  defp lifecycle_fixture!(label) do
    suffix = System.unique_integer([:positive])
    project_id = "h080a-down-#{label}-#{suffix}"
    issue_id = "h080a-down-item-#{label}-#{suffix}"
    issue = %Issue{id: issue_id, identifier: String.upcase(issue_id), title: "H-080A DOWN lifecycle", state: "In Progress", dispatchable: true}
    attempt_root = Application.fetch_env!(:symphony_elixir, :attempt_ledger_root)
    attempt_path = AttemptLedger.path_for(project_id, root: attempt_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_recovery_checkpoint!(issue)

    {:ok, supervisor} = Task.Supervisor.start_link()
    Process.unlink(supervisor)
    remember_resource(:supervisors, supervisor)

    fixture = %{
      project_id: project_id,
      issue: issue,
      attempt_path: attempt_path,
      task_supervisor: supervisor,
      work_control: %{issue_id => eligible_work_item(issue)}
    }

    orchestrator = start_orchestrator!(fixture, false)
    Map.put(fixture, :orchestrator, orchestrator)
  end

  defp start_orchestrator!(fixture, start_quiesced) do
    name = Module.concat(__MODULE__, "Lifecycle#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        task_supervisor: fixture.task_supervisor,
        agent_runner: SymphonyElixir.H080ADownLifecycleRunner,
        work_control: fixture.work_control,
        attempt_ledger_opts: [path: fixture.attempt_path],
        start_quiesced: start_quiesced
      )

    Process.unlink(orchestrator)
    remember_resource(:orchestrators, {name, orchestrator})
    orchestrator
  end

  defp current_runtime!(fixture) do
    {entry, _identity} = await_runtime!(fixture, nil)
    state = :sys.get_state(fixture.orchestrator)
    {:ok, record} = AttemptLedger.current(state.attempt_ledger, fixture.issue.id)
    assert entry.pid == state.running[fixture.issue.id].pid
    {entry, record}
  end

  defp await_runtime!(fixture, prior_runtime_attempt_id) do
    issue_id = fixture.issue.id

    assert_receive {:h080a_runtime_child_started, ^issue_id, child, %Identity{} = identity}, 5_000
    remember_resource(:children, child)
    refute identity.runtime_attempt_id == prior_runtime_attempt_id

    entry =
      eventually_value(fn ->
        state = :sys.get_state(fixture.orchestrator)

        case Map.get(state.running, issue_id) do
          %{pid: ^child, ref: ref, runtime_attempt: %RuntimeAttempt{identity: ^identity, state: :running}} = entry
          when is_reference(ref) ->
            entry

          _other ->
            nil
        end
      end)

    assert entry
    {entry, identity}
  end

  defp trace_genuine_down!(orchestrator, entry, reason) do
    1 = :erlang.trace(orchestrator, true, [:receive, {:tracer, self()}])
    send(entry.pid, {:h080a_exit, reason})

    assert_receive {:trace, ^orchestrator, :receive, {:DOWN, ref, :process, pid, ^reason}}, 5_000
    assert ref == entry.ref
    assert pid == entry.pid
    refute Process.alive?(entry.pid)
    :erlang.trace(orchestrator, false, [:receive])
    :ok
  end

  defp instrument_attempt_sync!(orchestrator, issue_id) do
    owner = self()

    :sys.replace_state(orchestrator, fn state ->
      ledger = state.attempt_ledger

      sync_fun = fn table -> sync_and_report(table, owner, issue_id) end

      %{state | attempt_ledger: %{ledger | sync_fun: sync_fun}}
    end)
  end

  defp collect_sync_states(acc) do
    receive do
      {:h080a_authority_sync, state, in_flight} -> collect_sync_states([{state, in_flight} | acc])
    after
      25 -> Enum.reverse(acc)
    end
  end

  defp sync_and_report(table, owner, issue_id) do
    case :dets.sync(table) do
      :ok = result ->
        report_sync_snapshot(table, owner, issue_id)
        result

      result ->
        result
    end
  end

  defp report_sync_snapshot(table, owner, issue_id) do
    case :dets.lookup(table, {:current, issue_id}) do
      [{{:current, ^issue_id}, record}] ->
        send(owner, {:h080a_authority_sync, record.authority_fence.state, record.in_flight})

      _other ->
        :ok
    end
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

  defp eligible_work_item(issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :in_progress
      })

    work_item
  end

  defp eventually_value(fun, attempts \\ 250)

  defp eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually_value(_fun, 0), do: nil

  defp remember_resource(key, value) do
    resources = Process.get({__MODULE__, :resources})
    Agent.update(resources, &Map.update!(&1, key, fn items -> [value | items] end))
    value
  end

  defp cleanup_resources(resources) do
    tracked = Agent.get(resources, & &1)
    disable_orchestrator_traces(tracked.orchestrators)
    stop_supervisors(tracked.supervisors)
    stop_orchestrators(tracked.orchestrators)
    assert_children_stopped(tracked.children)
  end

  defp disable_orchestrator_traces(orchestrators) do
    Enum.each(orchestrators, fn {_name, pid} ->
      if Process.alive?(pid), do: :erlang.trace(pid, false, [:receive])
    end)
  end

  defp stop_supervisors(supervisors) do
    Enum.each(supervisors, fn pid ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid, :shutdown, 5_000)
        catch
          :exit, _reason -> :ok
        end
      end

      if Process.alive?(pid), do: raise("H-080A Task.Supervisor remained alive after cleanup")
    end)
  end

  defp stop_orchestrators(orchestrators) do
    Enum.each(orchestrators, fn {name, pid} ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :shutdown, 5_000)
        catch
          :exit, _reason -> :ok
        end
      end

      if Process.alive?(pid), do: raise("H-080A Orchestrator remained alive after cleanup")
      if Process.whereis(name), do: raise("H-080A Orchestrator name remained registered: #{inspect(name)}")
    end)
  end

  defp assert_children_stopped(children) do
    Enum.each(children, fn pid ->
      if Process.alive?(pid), do: raise("H-080A runtime child remained alive after cleanup")
    end)
  end

  defp restore_capture(nil), do: Application.delete_env(:symphony_elixir, :h080a_down_lifecycle_capture)

  defp restore_capture(value),
    do: Application.put_env(:symphony_elixir, :h080a_down_lifecycle_capture, value)
end
