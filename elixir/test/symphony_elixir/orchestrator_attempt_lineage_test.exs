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
  alias SymphonyElixir.AgentRuntime.Route

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
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
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

  test "retains a lineage and blocks autonomous dispatch when startup reconciliation cannot find the issue" do
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
             case Map.get(:sys.get_state(pid), :attempt_ledger_status) do
               {:blocked, {:attempt_ledger_issue_missing, [^issue_id]}} -> true
               _ -> false
             end
           end)

    assert {:ok, snapshot} = read_snapshot(path, project_id, issue_id)
    assert snapshot.safety_counters.ordinary_failures == 2
    refute_receive {:attempt_ledger_runner_started, ^issue_id, _opts}, 300
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
      if :atomics.add_get(sync_count, 1, 1) == 1 do
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

  defp read_snapshot(path, project_id, issue_id) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    result = AttemptLedger.current(ledger, issue_id)
    :ok = AttemptLedger.close(ledger)
    result
  end

  defp start_orchestrator(name, extra_opts \\ []) do
    Orchestrator.start_link(
      Keyword.merge(
        [
          name: name,
          agent_runner: SymphonyElixir.AttemptLedgerFailingRunner
        ],
        extra_opts
      )
    )
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
