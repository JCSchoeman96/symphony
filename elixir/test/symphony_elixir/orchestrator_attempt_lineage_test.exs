defmodule SymphonyElixir.AttemptLedgerFailingRunner do
  @spec run(map(), pid() | nil, keyword()) :: no_return()
  def run(issue, _recipient, opts) do
    if capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid) do
      send(capture, {:attempt_ledger_runner_started, issue.id, opts})
    end

    exit(:simulated_worker_failure)
  end
end

defmodule SymphonyElixir.OrchestratorAttemptLineageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.AgentRuntime.{Route, Router}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.WorkControl.RecoveryLedger
  alias SymphonyElixir.WorkControl.WorkItem

  test "restores consumed ordinary retry budget across orchestrator restart" do
    project_id = "restart-#{System.unique_integer([:positive])}"
    issue = active_issue("restart-issue")
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 2, ordinary_retries: 2})

    first_name = Module.concat(__MODULE__, "First#{System.unique_integer([:positive])}")
    {:ok, first_pid} = start_orchestrator(first_name)
    issue_id = issue.id

    assert_receive {:attempt_ledger_runner_started, ^issue_id, _first_opts}, 1_000
    assert eventually(fn -> get_in(:sys.get_state(first_pid).attempt_counters, [issue_id, :ordinary_failures]) == 3 end)

    assert {:ok, first_snapshot} = read_snapshot(path, project_id, issue.id)
    assert first_snapshot.status == :open
    assert first_snapshot.safety_counters.ordinary_failures == 3
    assert first_snapshot.safety_counters.ordinary_retries == 3

    :ok = GenServer.stop(first_pid)

    second_name = Module.concat(__MODULE__, "Second#{System.unique_integer([:positive])}")
    {:ok, second_pid} = start_orchestrator(second_name)

    on_exit(fn ->
      if Process.alive?(second_pid) do
        try do
          GenServer.stop(second_pid)
        catch
          :exit, _ -> :ok
        end
      end

      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert_receive {:attempt_ledger_runner_started, ^issue_id, second_opts}, 1_000
    assert second_opts[:attempt] == nil

    assert eventually(fn ->
             state = :sys.get_state(second_pid)

             state.attempt_counters[issue_id].ordinary_failures == 4 and
               state.blocked[issue_id].termination_reason == :retry_exhausted
           end)

    assert {:ok, exhausted} = read_snapshot(path, project_id, issue.id)
    assert exhausted.status == :exhausted
    assert exhausted.safety_counters.ordinary_failures == 4
  end

  test "does not dispatch an exhausted lineage after restart" do
    project_id = "exhausted-#{System.unique_integer([:positive])}"
    issue = active_issue("exhausted-issue")
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 4, ordinary_retries: 3}, :exhausted)

    name = Module.concat(__MODULE__, "Exhausted#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
    state = :sys.get_state(pid)
    assert state.attempt_counters[issue.id].ordinary_failures == 4
    assert Map.has_key?(Map.get(state, :durable_exhausted, %{}), issue.id)
  end

  test "a zero timestamp cannot prove an H-030 operator rearm" do
    project_id = "rearm-zero-#{System.unique_integer([:positive])}"
    issue_id = "rearm-zero-issue"
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: ledger_root)
    on_exit(fn -> AttemptLedger.close(ledger) end)

    assert {:ok, exhausted} =
             AttemptLedger.persist_safety(
               ledger,
               issue_id,
               %{ordinary_failures: 4, ordinary_retries: 3, review_cycles: 0},
               status: :exhausted,
               stop_reason: :ordinary_retry_limit,
               updated_at: 1
             )

    assert {:ok, rearmed} = AttemptLedger.rearm(ledger, issue_id, "operator verified", "operator", 0)

    state = %Orchestrator.State{attempt_ledger: ledger, attempt_lineages: %{issue_id => rearmed.lineage_id}}
    assert is_nil(Orchestrator.h030_rearm_proof_for_test(state, issue_id, exhausted.lineage_id))
  end

  test "a complete retained-history H-030 rearm proves a replacement lineage" do
    project_id = "rearm-proof-#{System.unique_integer([:positive])}"
    issue_id = "rearm-proof-issue"
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: ledger_root)
    on_exit(fn -> AttemptLedger.close(ledger) end)

    assert {:ok, exhausted} =
             AttemptLedger.persist_safety(
               ledger,
               issue_id,
               %{ordinary_failures: 4, ordinary_retries: 3, review_cycles: 0},
               status: :exhausted,
               stop_reason: :ordinary_retry_limit,
               updated_at: 1
             )

    assert {:ok, rearmed} =
             AttemptLedger.rearm(ledger, issue_id, "operator verified recovery", "host-operator", 1_700_000_000_000)

    state = %Orchestrator.State{attempt_ledger: ledger, attempt_lineages: %{issue_id => rearmed.lineage_id}}
    proof = Orchestrator.h030_rearm_proof_for_test(state, issue_id, exhausted.lineage_id)

    assert proof.explicitly_rearmed?
    assert proof.old_lineage == exhausted.lineage_id
    assert proof.replacement_lineage == rearmed.lineage_id
    assert proof.rearm_reason == "operator verified recovery"
    assert proof.rearmed_by == "host-operator"
    assert proof.rearmed_at == 1_700_000_000_000
    assert proof.old_history_retained?
  end

  test "terminal Plane state does not close an exhausted lineage or replace H-030 rearm" do
    project_id = "exhausted-terminal-#{System.unique_integer([:positive])}"
    issue = %{active_issue("exhausted-terminal-issue") | state: "Done"}
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 4, ordinary_retries: 3}, :exhausted)

    name = Module.concat(__MODULE__, "ExhaustedTerminal#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert {:ok, exhausted} = read_snapshot(path, project_id, issue.id)
    assert exhausted.status == :exhausted
    old_lineage_id = exhausted.lineage_id

    terminal_state = Orchestrator.handle_retry_issue_lookup_for_test(issue, :sys.get_state(pid), issue.id, 0, %{})

    assert Map.has_key?(terminal_state.durable_exhausted, issue.id)
    assert {:ok, after_manual_terminal} = read_snapshot(path, project_id, issue.id)
    assert after_manual_terminal.status == :exhausted
    assert after_manual_terminal.lineage_id == old_lineage_id

    active_issue = %{issue | state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [active_issue])
    :ok = GenServer.stop(pid)

    second_name = Module.concat(__MODULE__, "ExhaustedTerminalRestart#{System.unique_integer([:positive])}")
    {:ok, second_pid} = start_orchestrator(second_name)

    on_exit(fn ->
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
    end)

    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
    assert {:ok, still_exhausted} = read_snapshot(path, project_id, issue.id)
    assert still_exhausted.status == :exhausted
    assert still_exhausted.lineage_id == old_lineage_id
  end

  test "blocks autonomous recovery when a reopened record is missing in_flight" do
    assert_corrupt_record_blocks_autonomy(:in_flight)
  end

  test "blocks autonomous recovery when a reopened record is missing close_pending" do
    assert_corrupt_record_blocks_autonomy(:close_pending)
  end

  test "retains a lineage and fences the affected issue when startup reconciliation cannot find it" do
    project_id = "missing-#{System.unique_integer([:positive])}"
    issue_id = "missing-issue"
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, issue_id, %{ordinary_failures: 2, ordinary_retries: 2})

    name = Module.concat(__MODULE__, "Missing#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
    end)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             state.attempt_ledger_status == :ready and
               state.durable_blocked[issue_id] == {:attempt_ledger_issue_missing, issue_id}
           end)

    assert {:ok, snapshot} = read_snapshot(path, project_id, issue_id)
    assert snapshot.safety_counters.ordinary_failures == 2
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
  end

  test "a missing durable issue does not fence unrelated autonomous work" do
    project_id = "missing-local-#{System.unique_integer([:positive])}"
    missing_issue_id = "missing-local-issue"
    unrelated_issue = active_issue("unrelated-local-issue")
    unrelated_issue_id = unrelated_issue.id
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [unrelated_issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())
    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, missing_issue_id, %{ordinary_failures: 2, ordinary_retries: 2})

    name = Module.concat(__MODULE__, "MissingLocal#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert_receive {:attempt_ledger_runner_started, ^unrelated_issue_id, _opts}, 1_000
    state = :sys.get_state(pid)
    assert state.attempt_ledger_status == :ready
    assert state.durable_blocked[missing_issue_id] == {:attempt_ledger_issue_missing, missing_issue_id}
  end

  test "blocks startup when a terminal lineage cannot be durably closed" do
    project_id = "startup-close-failure-#{System.unique_integer([:positive])}"
    issue = %{active_issue("startup-close-failure-issue") | state: "Done"}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 2, ordinary_retries: 2})

    name = Module.concat(__MODULE__, "StartupCloseFailure#{System.unique_integer([:positive])}")

    {:ok, pid} =
      start_orchestrator(name,
        attempt_ledger_opts: [path: path, sync_fun: fn _table -> {:error, :injected_sync_failure} end]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             match?({:blocked, {:attempt_ledger_close_failed, _}}, state.attempt_ledger_status) and
               MapSet.member?(state.attempt_ledger_pending_closes, issue.id)
           end)
  end

  test "reconciles a durably marked close after orchestrator restart" do
    project_id = "restart-close-marker-#{System.unique_integer([:positive])}"
    issue = %{active_issue("restart-close-marker-issue") | state: "Done"}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_snapshot(path, project_id, issue.id, %{})

    first_name = Module.concat(__MODULE__, "RestartCloseMarkerFirst#{System.unique_integer([:positive])}")

    {:ok, first_pid} =
      start_orchestrator(first_name,
        attempt_ledger_opts: [path: path, sync_fun: fn _table -> {:error, :injected_sync_failure} end]
      )

    assert eventually(fn ->
             state = :sys.get_state(first_pid)

             match?({:blocked, {:attempt_ledger_close_failed, _}}, state.attempt_ledger_status) and
               MapSet.member?(state.attempt_ledger_pending_closes, issue.id)
           end)

    :ok = GenServer.stop(first_pid)

    second_name = Module.concat(__MODULE__, "RestartCloseMarkerSecond#{System.unique_integer([:positive])}")
    {:ok, second_pid} = start_orchestrator(second_name, attempt_ledger_opts: [path: path])

    on_exit(fn ->
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
    end)

    assert eventually(fn ->
             state = :sys.get_state(second_pid)

             state.attempt_ledger_status == :ready and
               state.attempt_counters == %{} and
               MapSet.size(state.attempt_ledger_pending_closes) == 0
           end)

    :ok = GenServer.stop(second_pid)
    assert {:ok, %{status: :closed, close_pending: false}} = read_snapshot(path, project_id, issue.id)
  end

  test "keeps a pending close fenced when its current record disappears" do
    project_id = "pending-missing-#{System.unique_integer([:positive])}"
    issue_id = "pending-missing-issue"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_close_failed, [{issue_id, :sync_failed}]}},
      attempt_ledger_opts: [path: path],
      attempt_ledger_pending_closes: MapSet.new([issue_id]),
      poll_interval_ms: 60_000
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert match?(
             {:blocked, {:attempt_ledger_close_failed, [{^issue_id, :missing_after_close_failure}]}},
             updated.attempt_ledger_status
           )

    assert MapSet.member?(updated.attempt_ledger_pending_closes, issue_id)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "keeps a pending close fenced when the ledger cannot be read" do
    project_id = "pending-read-failure-#{System.unique_integer([:positive])}"
    issue_id = "pending-read-failure-issue"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)
    :ok = AttemptLedger.close(ledger)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_close_failed, [{issue_id, :read_failed}]}},
      attempt_ledger_opts: [path: path],
      attempt_ledger_pending_closes: MapSet.new([issue_id]),
      poll_interval_ms: 60_000
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert match?(
             {:blocked, {:attempt_ledger_close_failed, [{^issue_id, {:ledger_read_failed, _}}]}},
             updated.attempt_ledger_status
           )
  end

  test "does not reopen autonomous work for an unconfirmed pending close" do
    project_id = "pending-sync-failure-#{System.unique_integer([:positive])}"
    issue_id = "pending-sync-failure-issue"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    seed_snapshot(path, project_id, issue_id, %{})

    {:ok, ledger} =
      AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker),
        path: path,
        sync_fun: fn _table -> {:error, :injected_sync_failure} end
      )

    assert {:error, {:ledger_sync_failed, :injected_sync_failure}} =
             AttemptLedger.close_lineage(ledger, issue_id)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_close_failed, [{issue_id, :sync_failed}]}},
      attempt_ledger_opts: [path: path],
      attempt_ledger_pending_closes: MapSet.new([issue_id]),
      poll_interval_ms: 60_000
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert match?(
             {:blocked, {:attempt_ledger_close_failed, [{^issue_id, {:ledger_sync_failed, :injected_sync_failure}}]}},
             updated.attempt_ledger_status
           )

    assert MapSet.member?(updated.attempt_ledger_pending_closes, issue_id)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "keeps an open lineage fenced when a pending close cannot be persisted" do
    project_id = "pending-open-close-failure-#{System.unique_integer([:positive])}"
    issue_id = "pending-open-close-failure-issue"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    seed_snapshot(path, project_id, issue_id, %{})

    {:ok, ledger} =
      AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker),
        path: path,
        sync_fun: fn _table -> {:error, :injected_sync_failure} end
      )

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_close_failed, [{issue_id, :sync_failed}]}},
      attempt_ledger_opts: [path: path],
      attempt_ledger_pending_closes: MapSet.new([issue_id]),
      poll_interval_ms: 60_000
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert match?(
             {:blocked, {:attempt_ledger_close_failed, [{^issue_id, {:ledger_sync_failed, :injected_sync_failure}}]}},
             updated.attempt_ledger_status
           )

    assert MapSet.member?(updated.attempt_ledger_pending_closes, issue_id)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "retries transient ledger reconciliation reasons without using a stale fence" do
    project_id = "retryable-reasons-#{System.unique_integer([:positive])}"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)

    reasons = [
      {:attempt_ledger_issue_missing, "issue-a"},
      {:attempt_ledger_tracker_unavailable, :temporary},
      {:attempt_ledger_unavailable, {:attempt_ledger_close_failed, []}},
      {:attempt_ledger_unavailable, {:ledger_write_failed, :temporary}},
      {:attempt_ledger_unavailable, {:ledger_sync_failed, :temporary}}
    ]

    for reason <- reasons do
      state = %Orchestrator.State{
        attempt_ledger: ledger,
        attempt_ledger_status: {:blocked, reason},
        attempt_ledger_opts: [path: path],
        poll_interval_ms: 60_000
      }

      {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)
      assert updated.attempt_ledger_status == :ready
    end

    assert :ok = AttemptLedger.close(ledger)
  end

  test "blocks a reservation when the durable fallback fence also fails" do
    project_id = "reservation-fence-failure-#{System.unique_integer([:positive])}"
    issue = active_issue("reservation-fence-failure-issue")
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_snapshot(path, project_id, issue.id, %{})

    name = Module.concat(__MODULE__, "ReservationFenceFailure#{System.unique_integer([:positive])}")

    {:ok, pid} =
      start_orchestrator(name,
        attempt_ledger_opts: [path: path, write_fun: fn _table, _records -> {:error, :injected_write_failure} end]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             write_failure = {:ledger_write_failed, :injected_write_failure}
             fence_failure = {:attempt_reservation_fence_failed, write_failure}
             expected_status = {:blocked, {:attempt_ledger_unavailable, fence_failure}}

             state.attempt_ledger_status == expected_status
           end)
  end

  test "blocks startup when the attempt ledger callbacks are invalid" do
    project_id = "invalid-ledger-callbacks-#{System.unique_integer([:positive])}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    name = Module.concat(__MODULE__, "InvalidLedgerCallbacks#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name, attempt_ledger_opts: [write_fun: :invalid])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert eventually(fn ->
             :sys.get_state(pid).attempt_ledger_status ==
               {:blocked, {:attempt_ledger_unavailable, :invalid_ledger_callbacks}}
           end)
  end

  test "does not schedule a retry when a safety snapshot sync fails" do
    project_id = "sync-failure-#{System.unique_integer([:positive])}"
    issue = active_issue("sync-failure-issue")
    ledger_root = temporary_ledger_root()
    sync_count = :atomics.new(1, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    sync_fun = fn table ->
      if :atomics.add_get(sync_count, 1, 1) <= 2 do
        :dets.sync(table)
      else
        {:error, :injected_sync_failure}
      end
    end

    name = Module.concat(__MODULE__, "SyncFailure#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name, attempt_ledger_opts: [sync_fun: sync_fun])
    issue_id = issue.id

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 1_000

    assert eventually(fn ->
             state = :sys.get_state(pid)

             state.retry_attempts == %{} and
               String.contains?(to_string(get_in(state.blocked, [issue_id, :error])), "attempt ledger")
           end)
  end

  test "keeps a sync-failed ledger blocked when recovery resync fails again" do
    project_id = "recovery-sync-failure-#{System.unique_integer([:positive])}"
    issue = %{active_issue("recovery-sync-failure-issue") | dispatchable: false}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    {sync_fun, sync_count} = controlled_sync_fun(self(), :always_fail)

    configure_sync_recovery_test(project_id, issue)

    ledger = open_controlled_ledger(project_id, path, sync_fun)

    assert {:error, {:ledger_sync_failed, :injected_sync_failure}} =
             AttemptLedger.persist_safety(ledger, issue.id, %{
               ordinary_failures: 1,
               ordinary_retries: 1,
               review_cycles: 0
             })

    state = blocked_sync_failure_state(ledger, path)
    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert updated.attempt_ledger_status == state.attempt_ledger_status
    assert :atomics.get(sync_count, 1) == 2
    assert updated.retry_attempts == %{}
    assert updated.running == %{}
    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 100

    cancel_tick(updated)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "performs a successful recovery resync before reconciliation and ready state" do
    project_id = "recovery-sync-success-#{System.unique_integer([:positive])}"
    issue = %{active_issue("recovery-sync-success-issue") | dispatchable: false}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    {sync_fun, sync_count} = controlled_sync_fun(self(), :fail_then_succeed)

    configure_sync_recovery_test(project_id, issue)

    ledger = open_controlled_ledger(project_id, path, sync_fun)

    assert {:error, {:ledger_sync_failed, :injected_sync_failure}} =
             AttemptLedger.persist_safety(ledger, issue.id, %{
               ordinary_failures: 1,
               ordinary_retries: 1,
               review_cycles: 0
             })

    state = blocked_sync_failure_state(ledger, path)
    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert_receive {:h030g_sync, 1}, 100
    assert_receive {:h030g_sync, 2}, 100
    assert :atomics.get(sync_count, 1) == 2
    assert updated.attempt_ledger_status == :ready
    assert updated.retry_attempts == %{}
    assert updated.running == %{}
    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 100

    assert {:ok, snapshot} = reopen_snapshot(path, project_id, issue.id)
    assert snapshot.safety_counters.ordinary_failures == 1
    assert snapshot.safety_counters.ordinary_retries == 1
    assert snapshot.in_flight == false
    assert snapshot.close_pending == false
  end

  test "recovers and preserves ordinary exhaustion only after a durable resync" do
    project_id = "recovery-exhaustion-#{System.unique_integer([:positive])}"
    issue = %{active_issue("recovery-exhaustion-issue") | dispatchable: false}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    {sync_fun, sync_count} = controlled_sync_fun(self(), :fail_then_succeed)

    configure_sync_recovery_test(project_id, issue)

    ledger = open_controlled_ledger(project_id, path, sync_fun)

    assert {:error, {:ledger_sync_failed, :injected_sync_failure}} =
             AttemptLedger.persist_safety(
               ledger,
               issue.id,
               %{
                 ordinary_failures: 4,
                 ordinary_retries: 3,
                 review_cycles: 0
               },
               status: :exhausted,
               stop_reason: :ordinary_retry_limit
             )

    state = blocked_sync_failure_state(ledger, path)
    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert_receive {:h030g_sync, 1}, 100
    assert_receive {:h030g_sync, 2}, 100
    assert :atomics.get(sync_count, 1) == 2
    assert updated.attempt_ledger_status == :ready
    assert updated.durable_exhausted[issue.id].status == :exhausted
    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 100

    assert {:ok, snapshot} = reopen_snapshot(path, project_id, issue.id)
    assert snapshot.status == :exhausted
    assert snapshot.stop_reason == :ordinary_retry_limit
    assert snapshot.safety_counters.ordinary_failures == 4
    assert snapshot.safety_counters.ordinary_retries == 3
    assert {:error, :lineage_exhausted} = begin_attempt_after_reopen(path, project_id, issue.id)
  end

  test "does not dispatch a queued retry while the ledger is blocked" do
    project_id = "blocked-fence-#{System.unique_integer([:positive])}"
    issue = active_issue("blocked-fence-issue")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())
    issue_id = issue.id
    retry_token = make_ref()

    state = %Orchestrator.State{
      attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, :disk_full}},
      max_concurrent_agents: 1,
      agent_runner: SymphonyElixir.AttemptLedgerFailingRunner,
      retry_attempts: %{
        issue.id => %{
          attempt: 1,
          retry_token: retry_token,
          timer_ref: nil,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: issue.identifier,
          issue_url: issue.url
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    assert {:noreply, ^state} = Orchestrator.handle_info({:retry_issue, issue_id, retry_token}, state)
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 100
  end

  test "route refresh persistence errors fail closed instead of crashing the orchestrator" do
    project_id = "route-sync-error-#{System.unique_integer([:positive])}"
    issue = %{active_issue("route-sync-error-issue") | state: "Ready"}
    next_issue = %{issue | state: "Canceled"}
    ledger_root = temporary_ledger_root()
    recovery_path = RecoveryLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["Ready", "Canceled"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [next_issue])
    tracker_identity = Tracker.identity(Config.settings!().tracker)
    {:ok, seed_ledger} = RecoveryLedger.open(project_id, tracker_identity, path: recovery_path)
    checkpoint = recovery_checkpoint(issue.id, :ready)
    assert :ok = RecoveryLedger.put_sync(seed_ledger, checkpoint)
    assert :ok = RecoveryLedger.close(seed_ledger)

    {:ok, recovery_ledger} =
      RecoveryLedger.open(project_id, tracker_identity,
        path: recovery_path,
        sync_fun: fn _table -> {:error, :injected_sync_failure} end
      )

    work_item = trusted_work_item(issue)

    state = %Orchestrator.State{
      recovery_ledger: recovery_ledger,
      recovery_ledger_status: :ready,
      recovery_ledger_opts: [path: recovery_path],
      recovery_checkpoints: %{issue.id => checkpoint},
      work_control: %{issue.id => work_item}
    }

    updated = Orchestrator.refresh_work_control_for_test(state, [next_issue])

    assert match?({:blocked, {:recovery_ledger_unavailable, _reason}}, updated.recovery_ledger_status)
    assert match?({:blocked, {:recovery_ledger_unavailable, _reason}}, updated.startup_reconciliation)
    assert updated.work_control[issue.id] == work_item
    assert :ok = RecoveryLedger.close(recovery_ledger)
  end

  test "rechecks the ledger fence after terminal reconciliation blocks it" do
    project_id = "terminal-fence-#{System.unique_integer([:positive])}"
    terminal_issue = %{active_issue("terminal-fence-issue") | state: "Done"}
    unrelated_issue = active_issue("unrelated-after-terminal-fence")
    unrelated_issue_id = unrelated_issue.id
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    sync_count = :atomics.new(1, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue, unrelated_issue])
    seed_snapshot(path, project_id, terminal_issue.id, %{ordinary_failures: 2, ordinary_retries: 2})

    {:ok, ledger} =
      AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker),
        path: path,
        sync_fun: fn table ->
          if :atomics.add_get(sync_count, 1, 1) == 1 do
            {:error, :injected_sync_failure}
          else
            :dets.sync(table)
          end
        end
      )

    queued_retry_token = make_ref()
    queued_retry_timer = Process.send_after(self(), :stale_retry_timer, 60_000)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      attempt_ledger_opts: [path: path],
      poll_interval_ms: 60_000,
      max_concurrent_agents: 1,
      running: %{
        terminal_issue.id => %{
          pid: nil,
          ref: nil,
          identifier: terminal_issue.identifier,
          issue: terminal_issue,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([terminal_issue.id]),
      retry_attempts: %{
        "queued-after-terminal-fence" => %{
          attempt: 1,
          retry_token: queued_retry_token,
          timer_ref: queued_retry_timer,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: "QUEUED-TERMINAL-FENCE",
          issue_url: "https://example.org/issues/QUEUED-TERMINAL-FENCE"
        }
      },
      agent_runner: SymphonyElixir.AttemptLedgerFailingRunner,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert match?({:blocked, _reason}, updated.attempt_ledger_status)
    refute_receive {:attempt_ledger_runner_started, ^unrelated_issue_id, _opts}, 100

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue])
    {:noreply, recovered} = Orchestrator.handle_info(:run_poll_cycle, updated)
    assert recovered.attempt_ledger_status == :ready
    refute Map.has_key?(recovered.attempt_counters, terminal_issue.id)
    assert_receive {:retry_issue, "queued-after-terminal-fence", _retry_token}, 1_000
  end

  test "persists an issue fence when the initial reservation write fails" do
    project_id = "initial-write-failure-#{System.unique_integer([:positive])}"
    issue = active_issue("initial-write-failure-issue")
    ledger_root = temporary_ledger_root()
    write_count = :atomics.new(1, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    write_fun = fn table, records ->
      if :atomics.add_get(write_count, 1, 1) == 2 do
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end

    first_name = Module.concat(__MODULE__, "InitialWriteFirst#{System.unique_integer([:positive])}")
    {:ok, first_pid} = start_orchestrator(first_name, attempt_ledger_opts: [write_fun: write_fun])
    issue_id = issue.id

    assert eventually(fn -> :sys.get_state(first_pid).blocked[issue_id] != nil end)
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
    :ok = GenServer.stop(first_pid)

    second_name = Module.concat(__MODULE__, "InitialWriteSecond#{System.unique_integer([:positive])}")
    {:ok, second_pid} = start_orchestrator(second_name)

    on_exit(fn ->
      if Process.alive?(second_pid) do
        try do
          GenServer.stop(second_pid)
        catch
          :exit, _ -> :ok
        end
      end

      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert_receive {:attempt_ledger_runner_started, ^issue_id, second_opts}, 1_000
    assert %RuntimeAttemptIdentity{} = second_opts[:runtime_attempt_identity]
  end

  test "does not reuse an old ledger identity while reconciliation is blocked" do
    old_project_id = "old-project-#{System.unique_integer([:positive])}"
    new_project_id = "new-project-#{System.unique_integer([:positive])}"
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(old_project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: old_project_id,
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(old_project_id, Tracker.identity(Config.settings!().tracker), path: path)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_issue_missing, ["old-issue"]}},
      attempt_ledger_opts: [path: path],
      poll_interval_ms: 60_000,
      max_concurrent_agents: 1,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: new_project_id,
      poll_interval_ms: 60_000
    )

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    expected_status =
      {:blocked, {:attempt_ledger_unavailable, {:ledger_project_namespace_mismatch, old_project_id, new_project_id}}}

    assert updated.attempt_ledger_status == expected_status
  end

  test "holds an in-flight reservation across restart when failure persistence fails" do
    project_id = "in-flight-restart-#{System.unique_integer([:positive])}"
    issue = active_issue("in-flight-restart-issue")
    ledger_root = temporary_ledger_root()
    write_count = :atomics.new(1, [])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    write_fun = fn table, records ->
      if :atomics.add_get(write_count, 1, 1) == 3 do
        {:error, :injected_write_failure}
      else
        :dets.insert(table, records)
      end
    end

    first_name = Module.concat(__MODULE__, "InFlightFirst#{System.unique_integer([:positive])}")
    {:ok, first_pid} = start_orchestrator(first_name, attempt_ledger_opts: [write_fun: write_fun])
    issue_id = issue.id

    assert_receive {:attempt_ledger_runner_started, ^issue_id, first_opts}, 1_000
    assert %RuntimeAttemptIdentity{} = first_opts[:runtime_attempt_identity]
    first_runtime_attempt_id = first_opts[:runtime_attempt_identity].runtime_attempt_id
    assert eventually(fn -> :sys.get_state(first_pid).blocked[issue_id] != nil end)
    :ok = GenServer.stop(first_pid)

    second_name = Module.concat(__MODULE__, "InFlightSecond#{System.unique_integer([:positive])}")
    {:ok, second_pid} = start_orchestrator(second_name)

    on_exit(fn ->
      if Process.alive?(second_pid) do
        try do
          GenServer.stop(second_pid)
        catch
          :exit, _ -> :ok
        end
      end

      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    assert_receive {:attempt_ledger_runner_started, ^issue_id, second_opts}, 1_000
    assert %RuntimeAttemptIdentity{} = second_opts[:runtime_attempt_identity]
    refute second_opts[:runtime_attempt_identity].runtime_attempt_id == first_runtime_attempt_id
  end

  test "retries a pending terminal close before reopening autonomous dispatch" do
    project_id = "pending-close-#{System.unique_integer([:positive])}"
    issue = %{active_issue("pending-close-issue") | state: "Done"}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 2, ordinary_retries: 2})
    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_close_failed, [{issue.id, :sync_failed}]}},
      attempt_ledger_opts: [path: path],
      attempt_ledger_pending_closes: MapSet.new([issue.id]),
      attempt_counters: %{issue.id => %{ordinary_failures: 2, ordinary_retries: 2, review_cycles: 0}},
      poll_interval_ms: 60_000,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    {:noreply, updated} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert updated.attempt_ledger_status == :ready
    assert updated.attempt_counters == %{}
    assert {:ok, %{status: :closed}} = AttemptLedger.current(ledger, issue.id)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "persists review-cycle exhaustion without charging non-safety events" do
    project_id = "review-#{System.unique_integer([:positive])}"
    ledger_root = temporary_ledger_root()
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      symphony_project_id: project_id,
      agent_routing: "routed"
    )

    ledger_path = AttemptLedger.path_for(project_id, root: ledger_root)
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: ledger_path)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      attempt_counters: %{}
    }

    assert {:ok, state} = Orchestrator.record_attempt_event_for_test(state, "issue-review", :capacity_wait)
    assert :not_found = AttemptLedger.current(ledger, "issue-review")

    assert {:ok, state} = Orchestrator.record_attempt_event_for_test(state, "issue-review", :review_cycle)
    assert {:ok, state} = Orchestrator.record_attempt_event_for_test(state, "issue-review", :review_cycle)
    assert {:ok, state} = Orchestrator.record_attempt_event_for_test(state, "issue-review", :review_cycle)

    assert {:stop, state, :review_cycle_limit} =
             Orchestrator.record_attempt_event_for_test(state, "issue-review", :review_cycle)

    assert {:ok, snapshot} = AttemptLedger.current(ledger, "issue-review")
    assert snapshot.status == :exhausted
    assert snapshot.safety_counters.review_cycles == 3
    assert state.durable_exhausted["issue-review"].status == :exhausted
    assert :ok = AttemptLedger.close(ledger)
  end

  test "persists review exhaustion before stopping a running route-change attempt" do
    project_id = "running-review-exhaustion-#{System.unique_integer([:positive])}"
    issue = %{active_issue("running-review-exhaustion-issue") | state: "In Review"}
    next_issue = %{issue | state: "Changes Requested"}
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)
    counters = %{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 3}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Review", "Changes Requested"],
      poll_interval_ms: 60_000
    )

    {:ok, ledger} = AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)

    assert {:ok, %{status: :open, in_flight: true}} =
             AttemptLedger.persist_safety(ledger, issue.id, counters,
               status: :open,
               in_flight: true,
               updated_at: 1_700_000_000_000
             )

    {:ok, previous_route} = Router.resolve(trusted_work_item(issue), Config.settings!().agent.profiles)

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      attempt_ledger_opts: [path: path],
      attempt_counters: %{issue.id => counters},
      durable_in_flight: MapSet.new([issue.id]),
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          route: previous_route,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      recovery_checkpoints: %{issue.id => recovery_checkpoint(issue.id, :changes_requested)},
      work_control: %{issue.id => trusted_work_item(next_issue)},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    updated = Orchestrator.reconcile_issue_states_for_test([next_issue], state)

    assert updated.blocked[issue.id].termination_reason == :review_cycle_exhausted
    assert MapSet.disjoint?(updated.durable_in_flight, MapSet.new([issue.id]))
    assert {:ok, snapshot} = AttemptLedger.current(ledger, issue.id)
    assert snapshot.status == :exhausted
    assert snapshot.in_flight == false
    assert snapshot.stop_reason == :review_cycle_limit
    assert :ok = AttemptLedger.close(ledger)
  end

  test "closes a durable lineage when the tracker reports a terminal issue" do
    project_id = "terminal-#{System.unique_integer([:positive])}"
    issue = %{active_issue("terminal-issue") | state: "Done"}
    ledger_root = temporary_ledger_root()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :attempt_ledger_root, ledger_root)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    path = AttemptLedger.path_for(project_id, root: ledger_root)
    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 2, ordinary_retries: 2})

    name = Module.concat(__MODULE__, "Terminal#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_root)
    end)

    assert eventually(fn ->
             case read_snapshot(path, project_id, issue.id) do
               {:ok, %{status: :closed}} -> true
               _ -> false
             end
           end)

    state = :sys.get_state(pid)
    refute Map.has_key?(state.attempt_counters, issue.id)
    issue_id = issue.id
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
  end

  test "holds safety state while receiving stale or unsupported control messages" do
    state = %Orchestrator.State{}
    previous_route = %Route{profile_name: "review", responsibility: "review"}
    next_route = %Route{profile_name: "correction", responsibility: "correction"}

    assert :ok = Orchestrator.terminate(:normal, state)
    assert {:noreply, ^state} = Orchestrator.handle_info({:worker_runtime_info, "missing", %{}}, state)
    assert {:noreply, ^state} = Orchestrator.handle_info({:agent_route_changed, "missing", previous_route, next_route}, state)
    assert {:noreply, ^state} = Orchestrator.handle_info({:codex_worker_update, "missing", :invalid}, state)
    assert {:noreply, ^state} = Orchestrator.handle_info({:retry_issue, "missing"}, state)
    assert {:noreply, ^state} = Orchestrator.handle_info(:unsupported_message, state)
  end

  test "blocks durable events when the ledger status or handle is invalid" do
    invalid_status = %Orchestrator.State{attempt_ledger_status: :invalid}

    assert {:error, invalid_state, invalid_reason} =
             Orchestrator.record_attempt_event_for_test(invalid_status, "issue-a", :ordinary_failure)

    assert invalid_state.attempt_ledger_status == {:blocked, invalid_reason}
    assert invalid_reason == {:attempt_ledger_unavailable, :invalid_ledger_status}

    missing_handle = %Orchestrator.State{attempt_ledger_status: :ready}

    assert {:error, missing_state, missing_reason} =
             Orchestrator.record_attempt_event_for_test(missing_handle, "issue-a", :ordinary_failure)

    assert missing_state.attempt_ledger_status == {:blocked, missing_reason}
    assert missing_reason == {:attempt_ledger_unavailable, :missing_ledger_handle}
  end

  defp active_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: String.upcase(issue_id),
      title: "Attempt lineage test",
      state: "In Progress",
      dispatchable: true
    }
  end

  defp temporary_ledger_root do
    root = Path.join(System.tmp_dir!(), "symphony-orchestrator-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp seed_snapshot(path, project_id, issue_id, counters, status \\ :open) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    counters = Map.merge(%{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0}, counters)

    assert {:ok, _snapshot} =
             AttemptLedger.persist_safety(ledger, issue_id, counters,
               status: status,
               stop_reason: if(status == :exhausted, do: :ordinary_retry_limit, else: nil),
               updated_at: 1_700_000_000_000
             )

    assert :ok = AttemptLedger.close(ledger)
  end

  defp assert_corrupt_record_blocks_autonomy(field) do
    project_id = "corrupt-#{field}-#{System.unique_integer([:positive])}"
    issue = active_issue("corrupt-#{field}-issue")
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())
    seed_snapshot(path, project_id, issue.id, %{})
    remove_snapshot_field(path, issue.id, field)

    name = Module.concat(__MODULE__, "Corrupt#{field}#{System.unique_integer([:positive])}")
    {:ok, pid} = start_orchestrator(name, attempt_ledger_opts: [path: path])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    issue_id = issue.id

    assert eventually(fn ->
             case :sys.get_state(pid).attempt_ledger_status do
               {:blocked, {:attempt_ledger_unavailable, {:corrupt_attempt_record, key, :invalid_record}}} ->
                 key == {:current, issue_id}

               _ ->
                 false
             end
           end)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert state.retry_attempts == %{}
    assert state.attempt_counters == %{}
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
  end

  defp remove_snapshot_field(path, issue_id, field) do
    {:ok, table} = :dets.open_file(path, type: :set, file: String.to_charlist(path))
    [{key, record}] = :dets.lookup(table, {:current, issue_id})
    :ok = :dets.insert(table, {key, Map.delete(record, field)})
    :ok = :dets.sync(table)
    :ok = :dets.close(table)
  end

  defp configure_sync_recovery_test(project_id, issue) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    on_exit(fn -> Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid) end)
  end

  defp controlled_sync_fun(test_pid, :always_fail) do
    sync_count = :atomics.new(1, [])

    sync_fun = fn _table ->
      count = :atomics.add_get(sync_count, 1, 1)
      send(test_pid, {:h030g_sync, count})
      {:error, :injected_sync_failure}
    end

    {sync_fun, sync_count}
  end

  defp controlled_sync_fun(test_pid, :fail_then_succeed) do
    sync_count = :atomics.new(1, [])

    sync_fun = fn table ->
      count = :atomics.add_get(sync_count, 1, 1)
      send(test_pid, {:h030g_sync, count})

      if count == 1 do
        {:error, :injected_sync_failure}
      else
        :dets.sync(table)
      end
    end

    {sync_fun, sync_count}
  end

  defp open_controlled_ledger(project_id, path, sync_fun) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, initial_ledger} = AttemptLedger.open(project_id, identity, path: path)
    :ok = AttemptLedger.close(initial_ledger)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path, sync_fun: sync_fun)
    ledger
  end

  defp blocked_sync_failure_state(ledger, path) do
    %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, :injected_sync_failure}}},
      attempt_ledger_opts: [path: path],
      poll_interval_ms: 60_000,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp cancel_tick(%{tick_timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_tick(_state), do: :ok

  defp reopen_snapshot(path, project_id, issue_id) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    result = AttemptLedger.current(ledger, issue_id)
    :ok = AttemptLedger.close(ledger)
    result
  end

  defp begin_attempt_after_reopen(path, project_id, issue_id) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    result = AttemptLedger.begin_attempt(ledger, issue_id)
    :ok = AttemptLedger.close(ledger)
    result
  end

  defp read_snapshot(path, project_id, issue_id) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    result = AttemptLedger.current(ledger, issue_id)
    :ok = AttemptLedger.close(ledger)
    result
  end

  defp start_orchestrator(name, extra_opts \\ []) do
    extra_opts = seed_recovery_checkpoints(extra_opts)

    Orchestrator.start_link(
      Keyword.merge(
        [
          name: name,
          agent_runner: SymphonyElixir.AttemptLedgerFailingRunner,
          work_control: trusted_work_control()
        ],
        extra_opts
      )
    )
  end

  defp seed_recovery_checkpoints(extra_opts) do
    config = Config.settings!()

    if config.agent.routing == "routed" and not Keyword.has_key?(extra_opts, :recovery_ledger_opts) do
      project_id = config.symphony.project_id
      recovery_root = Path.join(System.tmp_dir!(), "symphony-attempt-lineage-recovery-#{project_id}")
      recovery_path = Path.join(recovery_root, project_id <> ".dets")
      recovery_opts = [path: recovery_path]
      {:ok, ledger} = RecoveryLedger.open(project_id, Tracker.identity(config.tracker), recovery_opts)

      Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
      |> Enum.each(&seed_recovery_checkpoint(ledger, &1))

      assert :ok = RecoveryLedger.close(ledger)
      on_exit(fn -> File.rm_rf(recovery_root) end)
      Keyword.put(extra_opts, :recovery_ledger_opts, recovery_opts)
    else
      extra_opts
    end
  end

  defp seed_recovery_checkpoint(ledger, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    if work_item.lifecycle_assessment.status == :validated do
      checkpoint = %{
        schema_version: RecoveryLedger.schema_version(),
        project_namespace: Config.settings!().symphony.project_id,
        work_item_id: issue_id,
        last_validated_lifecycle_state: work_item.validated_lifecycle_state,
        durable_guard_evidence:
          Enum.filter(work_item.lifecycle_assessment.satisfied_guards, &match?(%{class: :mechanical_guard}, &1))
          |> Enum.map(&Map.take(&1, [:class, :name, :outcome])),
        active_suspension_context: nil,
        last_terminal_suspension_context: nil,
        updated_at: DateTime.utc_now()
      }

      assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    end
  end

  defp seed_recovery_checkpoint(_ledger, _issue), do: :ok

  defp recovery_checkpoint(issue_id, lifecycle_state) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: Config.settings!().symphony.project_id,
      work_item_id: issue_id,
      last_validated_lifecycle_state: lifecycle_state,
      durable_guard_evidence: [],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }
  end

  defp trusted_work_control do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
    |> Enum.reduce(%{}, fn
      %Issue{id: issue_id} = issue, work_control when is_binary(issue_id) ->
        Map.put(work_control, issue_id, trusted_work_item(issue))

      _issue, work_control ->
        work_control
    end)
  end

  defp trusted_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    work_item
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
