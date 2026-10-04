defmodule SymphonyElixir.AgentRunnerStartIsolationFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:error, term()}
  def start_session(_workspace, _opts),
    do: {:error, {:runtime_isolation_unavailable, :start_boundary_unproven}}

  @spec run_turn(term(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :unreachable}

  @spec stop_session(term()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerRunIsolationFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:error, term()}
  def run_turn(_session, _prompt, _issue, _opts),
    do: {:error, {:runtime_isolation_failed, :run_boundary_unproven}}

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerRaisedIsolationFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: no_return()
  def start_session(_workspace, _opts),
    do: throw({:runtime_isolation_unavailable, :raised_start_boundary_unproven})

  @spec run_turn(term(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :unreachable}

  @spec stop_session(term()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerNestedProvenanceFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:error, term()}
  def run_turn(_session, _prompt, _issue, _opts) do
    {:error, {:turn_failed, {:runtime_provenance_mismatch, :thread_start, :active_permission_profile, "symphony_builder_write", "symphony_wrong_profile"}}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerNestedTypedIsolationFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:error, term()}
  def run_turn(_session, _prompt, _issue, _opts) do
    {:error, {:turn_failed, {:runtime_wrapper, {:runtime_isolation_unavailable, :nested_probe_unproven}}}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerTurnStopFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:error, term()}
  def run_turn(_session, _prompt, _issue, _opts),
    do: {:error, {:stop_failed, :process_state_unavailable}}

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerStopBoundaryFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :completed}

  @spec stop_session(map()) :: {:error, term()}
  def stop_session(_session), do: {:error, {:stop_failed, :process_still_running}}
end

defmodule SymphonyElixir.AgentRunnerNestedContainmentTimeoutRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :completed}

  @spec stop_session(map()) :: {:error, term()}
  def stop_session(_session),
    do: {:error, {:runtime_stop_failed, {:containment_unconfirmed, :termination_timeout}}}
end

defmodule SymphonyElixir.AgentRunnerRaisedNestedContainmentTimeoutRuntime do
  @spec start_session(Path.t(), keyword()) :: no_return()
  def start_session(_workspace, _opts) do
    throw({:turn_failed, {:runtime_stop_failed, {:containment_unconfirmed, :termination_timeout}, :app_server_stop}})
  end

  @spec run_turn(term(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :unreachable}

  @spec stop_session(term()) :: :ok
  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.AgentRunnerRestartIsolationFailureRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(_workspace, opts) do
    start_count = Process.get(:agent_runner_restart_start_count, 0) + 1
    Process.put(:agent_runner_restart_start_count, start_count)
    send(Keyword.fetch!(opts, :test_pid), {:restart_runtime_started, start_count})

    case start_count do
      1 -> {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
      _ -> {:error, {:start_failed, {:runtime_isolation_unavailable, :restart_boundary_unproven}}}
    end
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(session, _prompt, _issue, _opts) do
    send(session.test_pid, :restart_runtime_turn)
    {:ok, :completed}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, :restart_runtime_stopped)
    :ok
  end
end

defmodule SymphonyElixir.AgentRunnerSuccessfulRestartRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts) do
    start_count = Process.get(:agent_runner_successful_restart_start_count, 0) + 1
    Process.put(:agent_runner_successful_restart_start_count, start_count)
    send(Keyword.fetch!(opts, :test_pid), {:successful_restart_started, start_count})
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid), start_count: start_count}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(session, _prompt, _issue, _opts) do
    send(session.test_pid, {:successful_restart_turn, session.start_count})
    {:ok, :completed}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, {:successful_restart_stopped, session.start_count})
    :ok
  end
end

defmodule SymphonyElixir.AgentRunnerIsolationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.WorkControl.{GuardClass, WorkItem}
  alias SymphonyElixir.Workspace.OwnershipLedger

  test "routed local command validation blocks before workspace creation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      agent_profiles: %{"builder" => %{"command" => "codex | touch app-server"}}
    )

    issue = %Issue{
      id: "runner-command-preflight",
      identifier: "SYM-COMMAND-PREFLIGHT",
      title: "Command preflight",
      state: "In Progress",
      dispatchable: true
    }

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)
    ledger = workspace_ownership_ledger()

    assert :ok =
             AgentRunner.run(issue, self(),
               route: route,
               work_item: work_item,
               runtime: SymphonyElixir.AgentRunnerRunIsolationFailureRuntime,
               test_pid: self(),
               ownership_ledger: ledger
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-command-preflight",
      {:runtime_isolation_unavailable, {:unsafe_routed_command, :shape}}
    }

    assert {:ok, []} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    refute_receive :restart_runtime_turn
  end

  test "invalid and raised isolation admission callbacks block without starting the runtime" do
    root = Path.join(System.tmp_dir!(), "h080b-agent-admission-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    codex = Path.join(root, "codex")
    File.mkdir_p!(workspace_root)
    File.write!(codex, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex, 0o700)
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agent_routing: "routed",
      codex_command: "#{codex} app-server"
    )

    settings = Config.settings!()
    ledger = workspace_ownership_ledger()

    callbacks = [
      {"invalid", true, {:runtime_isolation_unavailable, :workspace_identity_or_runtime_unproven}},
      {
        "raised",
        fn _worker_host, _executable, _opts -> raise ArgumentError, "test callback failure" end,
        {:runtime_isolation_unavailable, :workspace_identity_or_runtime_unproven}
      },
      {
        "thrown",
        fn _worker_host, _executable, _opts -> throw(:test_callback_failure) end,
        {:runtime_isolation_unavailable, :workspace_identity_or_runtime_unproven}
      },
      {
        "unavailable",
        fn _worker_host, _executable, _opts -> {:error, {:runtime_isolation_unavailable, :verifier_missing}} end,
        {:runtime_isolation_unavailable, :verifier_missing}
      },
      {
        "failed",
        fn _worker_host, _executable, _opts -> {:error, {:runtime_isolation_failed, :proof_failed}} end,
        {:runtime_isolation_failed, :proof_failed}
      },
      {
        "two-arity",
        fn _worker_host, _executable -> {:error, {:runtime_isolation_unavailable, :two_arity_unproven}} end,
        {:runtime_isolation_unavailable, :two_arity_unproven}
      }
    ]

    Enum.each(callbacks, fn {suffix, callback, expected_reason} ->
      issue = %Issue{
        id: "runner-admission-#{suffix}",
        identifier: "SYM-ADMISSION-#{String.upcase(suffix)}",
        title: "Admission callback #{suffix}",
        state: "In Progress",
        dispatchable: true
      }

      {:ok, work_item} =
        WorkItem.from_issue(issue, %{
          provider: :memory,
          observed_at: DateTime.utc_now(),
          prior_validated_lifecycle_state: issue.state
        })

      assert {:ok, route} = Router.resolve(work_item, settings.agent.profiles)

      assert :ok =
               AgentRunner.run(issue, self(),
                 route: route,
                 work_item: work_item,
                 runtime: SymphonyElixir.AgentRunnerRunIsolationFailureRuntime,
                 test_pid: self(),
                 test_runtime_isolation_admit: callback,
                 ownership_ledger: ledger
               )

      assert_receive {
        :runtime_isolation_blocked,
        issue_id,
        reason
      }

      assert issue_id == issue.id
      assert reason == expected_reason
      refute_receive :restart_runtime_turn
    end)
  end

  test "typed isolation failure from session start reports a block" do
    issue = %Issue{
      id: "runner-start-isolation",
      identifier: "SYM-START-ISOLATION",
      title: "Start isolation",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerStartIsolationFailureRuntime,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-start-isolation",
      {:runtime_isolation_unavailable, :start_boundary_unproven}
    }
  end

  test "typed isolation failure from a turn reports a block" do
    issue = %Issue{
      id: "runner-run-isolation",
      identifier: "SYM-RUN-ISOLATION",
      title: "Run isolation",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerRunIsolationFailureRuntime,
               test_pid: self(),
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-run-isolation",
      {:runtime_isolation_failed, :run_boundary_unproven}
    }
  end

  test "nested typed isolation reasons survive AppServer error wrappers" do
    issue = %Issue{
      id: "runner-nested-typed-isolation",
      identifier: "SYM-NESTED-TYPED-ISOLATION",
      title: "Nested typed isolation failure",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerNestedTypedIsolationFailureRuntime,
               test_pid: self(),
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-nested-typed-isolation",
      {:runtime_isolation_unavailable, :nested_probe_unproven}
    }
  end

  test "unconfirmed stop state returned from a turn is an isolation block" do
    issue = %Issue{
      id: "runner-turn-stop-failure",
      identifier: "SYM-TURN-STOP-FAILURE",
      title: "Turn stop failure",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerTurnStopFailureRuntime,
               test_pid: self(),
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-turn-stop-failure",
      {:runtime_isolation_unavailable, :runtime_cleanup_unconfirmed}
    }
  end

  test "nested runtime provenance failures report the app-server boundary block" do
    issue = %Issue{
      id: "runner-nested-provenance-isolation",
      identifier: "SYM-NESTED-PROVENANCE",
      title: "Nested provenance failure",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerNestedProvenanceFailureRuntime,
               test_pid: self(),
               max_turns: 1,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-nested-provenance-isolation",
      {:runtime_isolation_unavailable, :app_server_boundary_unproven}
    }
  end

  test "unconfirmed runtime stop reports an isolation block" do
    issue = %Issue{
      id: "runner-stop-isolation",
      identifier: "SYM-STOP-ISOLATION",
      title: "Stop isolation",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerStopBoundaryFailureRuntime,
               test_pid: self(),
               max_turns: 1,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-stop-isolation",
      {:runtime_isolation_unavailable, :runtime_cleanup_unconfirmed}
    }
  end

  test "nested runtime stop containment timeout reports a typed retained lifecycle event" do
    issue = %Issue{
      id: "runner-nested-containment-timeout",
      identifier: "SYM-NESTED-CONTAINMENT",
      title: "Nested containment timeout",
      state: "In Progress"
    }

    identity = %Identity{
      runtime_attempt_id: "attempt-nested-containment-timeout",
      work_item_id: issue.id,
      lineage_generation: "lineage-nested-containment-timeout",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    issue_id = issue.id

    assert {:error, {:runtime_containment_unconfirmed, :termination_timeout}} =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerNestedContainmentTimeoutRuntime,
               test_pid: self(),
               max_turns: 1,
               runtime_attempt_identity: identity,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :stopping}

    assert_receive {
      :runtime_attempt_lifecycle,
      ^issue_id,
      ^identity,
      {:containment_unconfirmed, :termination_timeout}
    }
  end

  test "nested contextual containment timeout from startup is classified and sanitized" do
    issue = %Issue{
      id: "runner-raised-nested-containment-timeout",
      identifier: "SYM-RAISED-NESTED-CONTAINMENT",
      title: "Raised nested containment timeout",
      state: "In Progress"
    }

    identity = %Identity{
      runtime_attempt_id: "attempt-raised-nested-containment-timeout",
      work_item_id: issue.id,
      lineage_generation: "lineage-raised-nested-containment-timeout",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    issue_id = issue.id

    assert {:error, {:runtime_containment_unconfirmed, :termination_timeout}} =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerRaisedNestedContainmentTimeoutRuntime,
               runtime_attempt_identity: identity,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_attempt_lifecycle,
      ^issue_id,
      ^identity,
      {:containment_unconfirmed, :termination_timeout}
    }
  end

  test "unconfirmed teardown without a RuntimeAttempt identity raises a typed safe error" do
    issue = %Issue{
      id: "runner-containment-missing-identity",
      identifier: "SYM-CONTAINMENT-MISSING-IDENTITY",
      title: "Containment missing identity",
      state: "In Progress"
    }

    assert_raise RuntimeError, "Routed runtime containment could not be associated with an attempt", fn ->
      AgentRunner.run(issue, self(),
        runtime: SymphonyElixir.AgentRunnerNestedContainmentTimeoutRuntime,
        test_pid: self(),
        max_turns: 1,
        ownership_ledger: workspace_ownership_ledger()
      )
    end
  end

  test "raised typed isolation failure from session start reports a block" do
    issue = %Issue{
      id: "runner-raised-start-isolation",
      identifier: "SYM-RAISED-START-ISOLATION",
      title: "Raised start isolation",
      state: "In Progress"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerRaisedIsolationFailureRuntime,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {
      :runtime_isolation_blocked,
      "runner-raised-start-isolation",
      {:runtime_isolation_unavailable, :raised_start_boundary_unproven}
    }
  end

  test "typed isolation failure from a restarted session reports a block" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "runner-restart-isolation",
      identifier: "SYM-RESTART-ISOLATION",
      title: "Restart isolation",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)
    admission = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerRestartIsolationFailureRuntime,
               test_pid: self(),
               route: route,
               work_item: work_item,
               guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
               issue_state_fetcher: fn [_issue_id] -> {:ok, [refreshed_issue]} end,
               test_runtime_isolation_admit: admission,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {:restart_runtime_started, 1}
    assert_receive :restart_runtime_turn
    assert_receive :restart_runtime_stopped
    assert_receive {:restart_runtime_started, 2}
    assert_receive {:runtime_isolation_blocked, "runner-restart-isolation", reason}
    assert reason == {:runtime_isolation_unavailable, :restart_boundary_unproven}
  end

  test "restarted runtime reports active containment after positive stop proof" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "runner-successful-restart",
      identifier: "SYM-SUCCESSFUL-RESTART",
      title: "Successful restart",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)

    identity = %Identity{
      runtime_attempt_id: "attempt-successful-restart",
      work_item_id: issue.id,
      lineage_generation: "lineage-successful-restart",
      responsibility: "implementation",
      runtime_profile: "builder"
    }

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.AgentRunnerSuccessfulRestartRuntime,
               test_pid: self(),
               runtime_attempt_identity: identity,
               route: route,
               work_item: work_item,
               guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
               issue_state_fetcher: fn [_issue_id] -> {:ok, [refreshed_issue]} end,
               test_runtime_isolation_admit: fn _worker_host, _executable, _opts -> {:ok, :admitted} end,
               ownership_ledger: workspace_ownership_ledger()
             )

    assert_receive {:successful_restart_started, 1}
    assert_receive {:runtime_attempt_lifecycle, issue_id, ^identity, :runtime_started}
    assert issue_id == issue.id
    assert_receive {:successful_restart_turn, 1}
    assert_receive {:successful_restart_stopped, 1}
    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :stopping}
    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :containment_proven_dead}

    assert_receive {:successful_restart_started, 2}
    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :runtime_started}
    assert_receive {:successful_restart_turn, 2}
    assert_receive {:successful_restart_stopped, 2}
    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :stopping}
    assert_receive {:runtime_attempt_lifecycle, ^issue_id, ^identity, :containment_proven_dead}
  end

  test "restarted routed sessions repeat workspace SCM residue admission" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "runner-restart-residue",
      identifier: "SYM-RESTART-RESIDUE",
      title: "Restart residue",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)
    ledger = workspace_ownership_ledger()
    test_pid = self()

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRunnerTestRestartResidueRuntime,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
               guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
               issue_state_fetcher: fn [_issue_id] ->
                 {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
                 File.mkdir_p!(Path.join(record.canonical_workspace_path, ".git"))
                 File.write!(Path.join(record.canonical_workspace_path, ".git/config"), "[credential]\n  helper = store\n")
                 {:ok, [refreshed_issue]}
               end,
               test_runtime_isolation_admit: fn _worker_host, _executable, _opts -> {:ok, :admitted} end,
               ownership_ledger: ledger
             )

    assert_receive {:restart_residue_runtime_started, 1}
    assert_receive :restart_residue_runtime_turn
    assert_receive :restart_residue_runtime_stopped

    assert_receive {
      :runtime_isolation_blocked,
      "runner-restart-residue",
      {:runtime_isolation_unavailable, :workspace_scm_boundary_unproven}
    }

    refute_receive {:restart_residue_runtime_started, 2}
  end
end

defmodule SymphonyElixir.AgentRunnerTestRestartResidueRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(_workspace, opts) do
    start_count = Process.get(:agent_runner_restart_residue_start_count, 0) + 1
    Process.put(:agent_runner_restart_residue_start_count, start_count)
    send(Keyword.fetch!(opts, :test_pid), {:restart_residue_runtime_started, start_count})
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, term()}
  def run_turn(session, _prompt, _issue, _opts) do
    send(session.test_pid, :restart_residue_runtime_turn)
    {:ok, :completed}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, :restart_residue_runtime_stopped)
    :ok
  end
end
