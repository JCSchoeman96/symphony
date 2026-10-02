defmodule SymphonyElixir.OrchestratorRuntimeIsolationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{RuntimeAttempt, RuntimeAttempt.Identity}
  alias SymphonyElixir.Orchestrator.State

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
