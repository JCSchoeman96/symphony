defmodule SymphonyElixir.OrchestratorRuntimeIsolationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{AttemptLedger, RuntimeAttempt, RuntimeAttempt.Identity}
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Workspace.OwnershipLedger

  defmodule ContainmentTimeoutRuntime do
    def start_session(_workspace, opts) do
      {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :completed}

    def stop_session(_session),
      do: {:error, {:containment_unconfirmed, :termination_timeout}}
  end

  test "AgentRunner containment timeout retains the current attempt and workspace authority" do
    test_pid = self()
    issue = %Issue{id: "h080b-containment-retained", identifier: "SYM-CONTAINMENT", state: "In Progress"}
    project_id = "h080b-containment-#{System.unique_integer([:positive])}"
    ledger_root = Path.join(System.tmp_dir!(), project_id)
    File.mkdir_p!(ledger_root)

    {:ok, attempt_ledger} =
      AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: ledger_root)

    on_exit(fn ->
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(ledger_root)
    end)

    assert {:ok, attempt_record} = AttemptLedger.begin_attempt(attempt_ledger, issue.id)

    identity = %Identity{
      runtime_attempt_id: "attempt-containment-retained",
      work_item_id: issue.id,
      lineage_generation: attempt_record.lineage_id,
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    assert {:ok, _bound_record} = AttemptLedger.bind_runtime_attempt(attempt_ledger, issue.id, identity)

    {:ok, task_supervisor} = Task.Supervisor.start_link()
    Process.unlink(task_supervisor)
    ownership_ledger = workspace_ownership_ledger()

    on_exit(fn ->
      if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
    end)

    task =
      Task.Supervisor.start_child(task_supervisor, fn ->
        AgentRunner.run(issue, test_pid,
          runtime: ContainmentTimeoutRuntime,
          test_pid: test_pid,
          max_turns: 1,
          runtime_attempt_identity: identity,
          ownership_ledger: ownership_ledger
        )
      end)

    assert {:ok, task_pid} = task
    monitor_ref = Process.monitor(task_pid)

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      runtime_attempt: RuntimeAttempt.new(identity, :starting),
      pid: task_pid,
      ref: monitor_ref,
      retry_attempt: 2,
      profile_name: "builder",
      runtime_name: "codex",
      responsibility: "implementation",
      started_at: DateTime.utc_now()
    }

    retry_attempts = %{"unrelated-issue" => %{attempt: 1}}

    state = %State{
      running: %{issue.id => running_entry},
      claimed: MapSet.new([issue.id]),
      retry_attempts: retry_attempts,
      attempt_counters: %{issue.id => attempt_record.safety_counters},
      attempt_ledger: attempt_ledger,
      attempt_ledger_status: :ready,
      task_supervisor: task_supervisor,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    retained_state = collect_agent_runtime_messages(monitor_ref, task_pid, state)

    assert retained_entry = retained_state.running[issue.id]
    assert retained_entry.runtime_attempt.identity == identity
    assert retained_entry.runtime_attempt.state == :containment_unconfirmed
    assert retained_entry.containment_status == :unconfirmed
    assert retained_entry.containment_reason == :termination_timeout
    assert retained_entry.pid == nil
    assert retained_entry.ref == nil
    assert retained_state.claimed == state.claimed
    assert retained_state.retry_attempts == retry_attempts
    assert retained_state.attempt_counters == state.attempt_counters
    refute Map.has_key?(retained_state.blocked, issue.id)
    refute Map.has_key?(retained_state.retry_attempts, issue.id)
    refute Orchestrator.should_dispatch_issue_for_test(issue, retained_state)

    assert {:ok, retained_record} = AttemptLedger.current(attempt_ledger, issue.id)
    assert retained_record.in_flight
    assert retained_record.safety_counters == attempt_record.safety_counters
    assert retained_record.authority_fence == %{state: :bound, runtime_attempt: identity, route_fingerprint: nil}

    assert {:ok, [ownership_record]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)
    refute ownership_record.state == :released

    newer_identity = %{identity | runtime_attempt_id: "newer-attempt"}

    newer_state = %{
      retained_state
      | running:
          Map.put(retained_state.running, issue.id, %{
            retained_state.running[issue.id]
            | runtime_attempt: RuntimeAttempt.new(newer_identity, :running)
          })
    }

    assert {:noreply, ^newer_state} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, :containment_proven_dead},
               newer_state
             )

    assert {:noreply, ^newer_state} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, {:containment_unconfirmed, :termination_timeout}},
               newer_state
             )
  end

  test "runtime lifecycle requires a positive stop result before marking containment dead" do
    issue = %Issue{id: "h080b-lifecycle-proof", identifier: "SYM-LIFECYCLE-PROOF"}
    identity = runtime_identity(issue.id, "attempt-lifecycle-proof")
    entry = %{runtime_attempt: RuntimeAttempt.new(identity, :starting)}
    state = %State{running: %{issue.id => entry}}

    assert {:noreply, started} =
             Orchestrator.handle_info({:runtime_attempt_session_started, issue.id, identity}, state)

    assert started.running[issue.id].runtime_attempt.state == :running

    assert {:noreply, active} =
             Orchestrator.handle_info({:runtime_attempt_lifecycle, issue.id, identity, :runtime_started}, started)

    assert active.running[issue.id].containment_status == :active

    assert {:noreply, stopping} =
             Orchestrator.handle_info({:runtime_attempt_lifecycle, issue.id, identity, :stopping}, active)

    assert stopping.running[issue.id].runtime_attempt.state == :stopping
    assert stopping.running[issue.id].containment_status == :stopping

    assert {:noreply, proven_dead} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, :containment_proven_dead},
               stopping
             )

    assert proven_dead.running[issue.id].runtime_attempt.state == :containment_proven_dead
    assert proven_dead.running[issue.id].containment_status == :proven_dead
  end

  test "a timeout during startup is retained and a later unverified event cannot clear it" do
    issue = %Issue{id: "h080b-starting-containment", identifier: "SYM-STARTING-CONTAINMENT"}
    identity = runtime_identity(issue.id, "attempt-starting-containment")
    entry = %{runtime_attempt: RuntimeAttempt.new(identity, :starting)}
    state = %State{running: %{issue.id => entry}}

    assert {:noreply, retained} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, {:containment_unconfirmed, :termination_timeout}},
               state
             )

    assert retained.running[issue.id].runtime_attempt.state == :containment_unconfirmed
    assert retained.running[issue.id].containment_status == :unconfirmed

    assert {:noreply, duplicate_timeout} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, {:containment_unconfirmed, :termination_timeout}},
               retained
             )

    assert duplicate_timeout.running[issue.id] == retained.running[issue.id]

    assert {:noreply, stale_start} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, :runtime_started},
               duplicate_timeout
             )

    assert stale_start.running[issue.id] == retained.running[issue.id]

    assert {:noreply, still_retained} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, :containment_proven_dead},
               stale_start
             )

    assert still_retained.running[issue.id] == retained.running[issue.id]

    assert {:noreply, unknown_state} =
             Orchestrator.handle_info(
               {:runtime_attempt_lifecycle, issue.id, identity, :unknown_lifecycle_state},
               still_retained
             )

    assert unknown_state == retained
  end

  test "runtime isolation failure after session start keeps the attempt fenced" do
    issue = %Issue{id: "h080b-isolation-after-start", identifier: "SYM-ISOLATION-AFTER-START"}
    identity = runtime_identity(issue.id, "attempt-isolation-after-start")

    running_entry = %{
      runtime_attempt: RuntimeAttempt.new(identity, :running),
      containment_status: :active
    }

    state = %State{running: %{issue.id => running_entry}, claimed: MapSet.new([issue.id])}

    assert {:noreply, retained} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, issue.id, identity, {:runtime_isolation_unavailable, :remote_containment_unproven}},
               state
             )

    assert retained.running[issue.id].runtime_attempt.state == :containment_unconfirmed
    assert retained.running[issue.id].containment_status == :unconfirmed
    assert retained.claimed == state.claimed
    refute Map.has_key?(retained.retry_attempts, issue.id)
  end

  test "dependency blocking cannot release a live routed runtime without stop proof" do
    issue = %Issue{id: "h080b-dependency-during-runtime", identifier: "SYM-DEPENDENCY-DURING-RUNTIME"}
    identity = runtime_identity(issue.id, "attempt-dependency-during-runtime")

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      runtime_attempt: RuntimeAttempt.new(identity, :running),
      containment_status: :active,
      pid: nil,
      ref: nil
    }

    state = %State{running: %{issue.id => running_entry}, claimed: MapSet.new([issue.id])}
    decision = %{"allowed?" => false, "blocking_issue_ids" => ["blocked-dependency"]}

    assert {:noreply, retained} =
             Orchestrator.handle_info(
               {:agent_dependency_blocked, issue.id, identity, decision},
               state
             )

    assert retained.running[issue.id].runtime_attempt.identity == identity
    assert retained.running[issue.id].runtime_attempt.state == :containment_unconfirmed
    assert retained.running[issue.id].containment_status == :unconfirmed
    assert retained.claimed == state.claimed
    refute Map.has_key?(retained.retry_attempts, issue.id)
  end

  defp runtime_identity(issue_id, runtime_attempt_id) do
    %Identity{
      runtime_attempt_id: runtime_attempt_id,
      work_item_id: issue_id,
      lineage_generation: "lineage-#{runtime_attempt_id}",
      responsibility: "implementation",
      runtime_profile: "builder"
    }
  end

  defp collect_agent_runtime_messages(monitor_ref, task_pid, state) do
    receive do
      {:worker_runtime_info, _issue_id, _identity, _runtime_info} = message ->
        {:noreply, next_state} = Orchestrator.handle_info(message, state)
        collect_agent_runtime_messages(monitor_ref, task_pid, next_state)

      {:runtime_attempt_session_started, _issue_id, _identity} = message ->
        {:noreply, next_state} = Orchestrator.handle_info(message, state)
        collect_agent_runtime_messages(monitor_ref, task_pid, next_state)

      {:runtime_attempt_lifecycle, _issue_id, _identity, _lifecycle_state} = message ->
        {:noreply, next_state} = Orchestrator.handle_info(message, state)
        collect_agent_runtime_messages(monitor_ref, task_pid, next_state)

      {:DOWN, ^monitor_ref, :process, ^task_pid, reason} ->
        {:noreply, next_state} = Orchestrator.handle_info({:DOWN, monitor_ref, :process, task_pid, reason}, state)
        next_state
    after
      5_000 ->
        flunk("AgentRunner did not finish after its runtime stop result")
    end
  end

  defmodule IsolationFailureRuntime do
    def start_session(workspace, opts) do
      {:ok, %{workspace: workspace, test_pid: Keyword.fetch!(opts, :test_pid)}}
    end

    def run_turn(_session, _prompt, _issue, _opts) do
      {:error, {:turn_failed, {:runtime_provenance_mismatch, :thread_start, :permission_profile, "symphony_builder_write", "symphony_wrong_profile"}}}
    end

    def stop_session(_session), do: :ok
  end

  test "runtime isolation block stops the task without recording an ordinary retry" do
    test_pid = self()
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    Process.unlink(task_supervisor)

    on_exit(fn ->
      if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
    end)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        send(test_pid, :runtime_task_started)

        receive do
          :continue -> :ok
        end
      end)

    assert_receive :runtime_task_started

    issue = %Issue{id: "h080b-runtime-block", identifier: "SYM-ISOLATION"}

    identity = %Identity{
      runtime_attempt_id: "attempt-h080b",
      work_item_id: issue.id,
      lineage_generation: "lineage-h080b",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      runtime_attempt: RuntimeAttempt.new(identity, :starting),
      pid: task.pid,
      ref: task.ref,
      retry_attempt: 2,
      profile_name: "builder",
      runtime_name: "codex",
      responsibility: "implementation"
    }

    state = %State{
      running: %{issue.id => running_entry},
      retry_attempts: %{issue.id => %{attempt: 2}},
      task_supervisor: task_supervisor
    }

    assert {:noreply, blocked_state} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, issue.id, identity, {:runtime_isolation_unavailable, :remote_containment_unproven}},
               state
             )

    assert Map.has_key?(blocked_state.blocked, issue.id)
    refute Map.has_key?(blocked_state.running, issue.id)
    refute Map.has_key?(blocked_state.retry_attempts, issue.id)
    assert blocked_state.attempt_counters == state.attempt_counters
    assert blocked_state.blocked[issue.id].termination_reason == :runtime_isolation_blocked
    assert blocked_state.blocked[issue.id].error == "runtime isolation blocked: remote containment is unproven"
    refute Process.alive?(task.pid)
  end

  test "runtime isolation reasons are reduced to safe operator messages" do
    reasons = [
      {{:runtime_isolation_failed, :probe_failed}, "Codex isolation proof failed"},
      {{:runtime_isolation_unavailable, :workspace_scm_boundary_unproven}, "workspace SCM credential boundary is unproven"},
      {{:runtime_isolation_unavailable, :verifier_unavailable}, "required runtime admission checks are unproven"},
      {{:unexpected, "credential-sentinel"}, "required runtime admission checks are unproven"}
    ]

    Enum.each(reasons, fn {reason, expected_error} ->
      issue = %Issue{id: "h080b-safe-reason-#{System.unique_integer([:positive])}", identifier: "SYM-ISOLATION"}

      identity = %Identity{
        runtime_attempt_id: "attempt-safe-reason",
        work_item_id: issue.id,
        lineage_generation: "lineage-safe-reason",
        responsibility: "implementation",
        runtime_profile: "builder"
      }

      running_entry = %{
        issue: issue,
        runtime_attempt: RuntimeAttempt.new(identity, :starting),
        retry_attempt: 1,
        profile_name: "builder",
        runtime_name: "codex",
        responsibility: "implementation"
      }

      state = %State{running: %{issue.id => running_entry}}

      assert {:noreply, blocked_state} =
               Orchestrator.handle_info(
                 {:runtime_isolation_blocked, issue.id, identity, reason},
                 state
               )

      assert blocked_state.blocked[issue.id].error == "runtime isolation blocked: #{expected_error}"
    end)
  end

  test "legacy isolation events cannot block a routed runtime attempt" do
    issue = %Issue{id: "h080b-stale-legacy-event", identifier: "SYM-ISOLATION"}

    identity = %Identity{
      runtime_attempt_id: "attempt-stale-legacy",
      work_item_id: issue.id,
      lineage_generation: "lineage-stale-legacy",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    running_entry = %{
      issue: issue,
      runtime_attempt: RuntimeAttempt.new(identity, :starting),
      retry_attempt: 1
    }

    state = %State{running: %{issue.id => running_entry}}

    assert {:noreply, ^state} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, issue.id, :untyped_legacy_reason},
               state
             )

    assert {:noreply, %State{blocked: %{}}} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, "missing-issue", :untyped_legacy_reason},
               %State{}
             )
  end

  test "stale identity-bearing isolation events leave orchestrator state unchanged" do
    issue = %Issue{id: "h080b-stale-identity-event", identifier: "SYM-ISOLATION"}

    identity = %Identity{
      runtime_attempt_id: "attempt-stale-identity",
      work_item_id: issue.id,
      lineage_generation: "lineage-stale-identity",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    state = %State{}

    assert {:noreply, ^state} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, issue.id, identity, :stale_reason},
               state
             )
  end

  test "legacy isolation events block legacy entries without runtime attempts" do
    issue = %Issue{id: "h080b-legacy-isolation-event", identifier: "SYM-ISOLATION"}
    running_entry = %{issue: issue, retry_attempt: 2}
    state = %State{running: %{issue.id => running_entry}}

    assert {:noreply, blocked_state} =
             Orchestrator.handle_info(
               {:runtime_isolation_blocked, issue.id, :legacy_runtime_unavailable},
               state
             )

    assert blocked_state.blocked[issue.id].error ==
             "runtime isolation blocked: required runtime admission checks are unproven"

    refute Map.has_key?(blocked_state.retry_attempts, issue.id)
  end

  test "AgentRunner reports runtime provenance failures as isolation blocks" do
    issue = %Issue{
      id: "h080b-runtime-provenance-block",
      identifier: "SYM-PROVENANCE",
      title: "Provenance failure",
      state: "In Progress"
    }

    assert :ok =
             SymphonyElixir.AgentRunner.run(issue, self(),
               runtime: IsolationFailureRuntime,
               test_pid: self(),
               max_turns: 1,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {:runtime_isolation_blocked, "h080b-runtime-provenance-block", {:runtime_isolation_unavailable, :app_server_boundary_unproven}}
  end
end
