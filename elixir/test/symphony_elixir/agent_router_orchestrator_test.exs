defmodule SymphonyElixir.AgentRouterOrchestratorRunnerFake do
  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, _recipient, opts) do
    send(Process.whereis(:symphony_agent_router_capture), {:fake_agent_run, issue, opts})
    :ok
  end
end

defmodule SymphonyElixir.AgentRouterOrchestratorLongRunningFake do
  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, _recipient, opts) do
    parent = Process.whereis(:symphony_agent_router_long_running_capture)
    send(parent, {:long_running_worker_started, self(), issue, opts})

    receive do
      :finish -> :ok
    end
  end
end

defmodule SymphonyElixir.AgentRouterOrchestratorTest do
  use SymphonyElixir.TestSupport

  test "orchestrator resolves and passes the selected route to a worker attempt" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    issue = %Issue{
      id: "orchestrator-route",
      identifier: "SYM-ORCH-ROUTE",
      title: "Route an issue",
      state: "Planning",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)
    end)

    assert_receive {:fake_agent_run, ^issue, opts}, 1_000
    assert opts[:route].profile_name == "planner"
    assert opts[:route].runtime_name == "codex"
    assert opts[:route].responsibility == "planning"
  end

  test "legacy workflows dispatch without applying routed profile permissions" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    issue = %Issue{
      id: "legacy-route",
      identifier: "SYM-LEGACY-ROUTE",
      title: "Keep legacy policy",
      state: "In Progress",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      codex_thread_sandbox: "read-only",
      codex_turn_sandbox_policy: %{type: "readOnly"},
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, "LegacyOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)
    end)

    assert_receive {:fake_agent_run, ^issue, opts}, 1_000
    assert opts[:route].profile == nil
    assert opts[:route].responsibility == "implementation"
  end

  test "orchestrator keeps implementation behind active dependencies while allowing planning" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    planning_issue = %Issue{
      id: "planning-dependent",
      identifier: "SYM-PLAN-DEPENDENT",
      title: "Plan around a blocker",
      state: "Planning",
      dispatchable: true,
      blocked_by: [%{id: "active-blocker", identifier: "SYM-BLOCKER", state: "In Progress"}]
    }

    ready_issue = %Issue{
      id: "ready-dependent",
      identifier: "SYM-READY-DEPENDENT",
      title: "Implement behind a blocker",
      state: "Ready",
      dispatchable: true,
      blocked_by: [%{id: "active-blocker", identifier: "SYM-BLOCKER", state: "In Progress"}]
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning", "Ready", "In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [planning_issue, ready_issue])

    orchestrator_name =
      Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)
    end)

    assert_receive {:fake_agent_run, ^planning_issue, opts}, 1_000
    assert opts[:route].profile_name == "planner"
    refute_receive {:fake_agent_run, ^ready_issue, _opts}, 250
  end

  test "orchestrator refuses a dependency cycle without retry churn" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    issue_a = %Issue{
      id: "cycle-a",
      identifier: "SYM-CYCLE-A",
      title: "Cycle A",
      state: "Ready",
      dispatchable: true,
      blocked_by: [%{id: "cycle-b", identifier: "SYM-CYCLE-B", state: "Ready"}]
    }

    issue_b = %Issue{
      id: "cycle-b",
      identifier: "SYM-CYCLE-B",
      title: "Cycle B",
      state: "Ready",
      dispatchable: true,
      blocked_by: [%{id: "cycle-a", identifier: "SYM-CYCLE-A", state: "Ready"}]
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue_a, issue_b])

    orchestrator_name =
      Module.concat(__MODULE__, "CycleOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)
    end)

    refute_receive {:fake_agent_run, _issue, _opts}, 500
  end

  test "orchestrator records a runtime dependency stop as a blocked attempt" do
    issue = %Issue{
      id: "runtime-dependency-block",
      identifier: "SYM-RUNTIME-BLOCK",
      title: "Runtime dependency block",
      state: "In Progress",
      blocked_by: [%{id: "blocker", identifier: "SYM-BLOCKER", state: "Ready"}]
    }

    running_entry = %{
      pid: nil,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      profile_name: "builder",
      runtime_name: "codex",
      responsibility: "implementation",
      route_fingerprint: "sha256:builder",
      session_id: "session-builder",
      worker_host: nil,
      workspace_path: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      running: %{issue.id => running_entry},
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    decision = %{
      dependency_status: :unresolved,
      dependent_state: "in progress",
      responsibility: "implementation",
      reason: :unresolved_hard_dependency,
      blockers: issue.blocked_by,
      unresolved_blockers: issue.blocked_by,
      invalidated_blockers: [],
      diagnostic: nil
    }

    assert {:noreply, updated_state} =
             Orchestrator.handle_info({:agent_dependency_blocked, issue.id, decision}, state)

    refute Map.has_key?(updated_state.running, issue.id)
    assert updated_state.blocked[issue.id].dependency.reason == :unresolved_hard_dependency
    assert MapSet.member?(updated_state.claimed, issue.id)
  end

  test "orchestrator releases a dependency-blocked attempt after blockers finish" do
    issue = %Issue{
      id: "runtime-dependency-resume",
      identifier: "SYM-RUNTIME-RESUME",
      title: "Runtime dependency resume",
      state: "In Progress",
      dispatchable: true,
      blocked_by: [%{id: "blocker", identifier: "SYM-BLOCKER", state: "Done"}]
    }

    blocked_entry = %{
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: %{issue | blocked_by: [%{id: "blocker", identifier: "SYM-BLOCKER", state: "Ready"}]},
      profile_name: "builder",
      runtime_name: "codex",
      responsibility: "implementation",
      route_fingerprint: "sha256:builder",
      dependency: %{
        reason: :unresolved_hard_dependency,
        unresolved_blockers: [%{id: "blocker", identifier: "SYM-BLOCKER", state: "Ready"}]
      }
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    state = %Orchestrator.State{
      blocked: %{issue.id => blocked_entry},
      claimed: MapSet.new([issue.id]),
      dependency_graph: %SymphonyElixir.Dependency.Graph{}
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)
  end

  test "poll reconciliation stops a live worker when a dependency reappears" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_long_running_capture)

    issue = %Issue{
      id: "poll-dependency-change",
      identifier: "SYM-POLL-DEPENDENCY",
      title: "Poll dependency change",
      state: "In Progress",
      dispatchable: true
    }

    blocker = %Issue{
      id: "poll-blocker",
      identifier: "SYM-POLL-BLOCKER",
      title: "Poll blocker",
      state: "Ready",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, "PollDependencyOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorLongRunningFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_long_running_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_long_running_capture)
    end)

    assert_receive {:long_running_worker_started, worker_pid, ^issue, _opts}, 1_000
    assert Process.alive?(worker_pid)

    changed_issue = %{
      issue
      | blocked_by: [%{id: blocker.id, identifier: blocker.identifier, state: blocker.state}]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [changed_issue, blocker])
    send(pid, :run_poll_cycle)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

    refute Process.alive?(worker_pid)
    assert snapshot.running == []
    assert [%{issue_id: "poll-dependency-change", responsibility: "implementation", attempt: 0} = blocked] = snapshot.blocked
    assert blocked.error =~ "dependency guard blocked"
    assert blocked.dependency.reason == :unresolved_hard_dependency

    assert blocked.dependency.unresolved_blockers == [
             %{id: blocker.id, identifier: blocker.identifier, state: "ready"}
           ]

    send(pid, {:DOWN, make_ref(), :process, worker_pid, :normal})
    send(pid, {:agent_dependency_blocked, changed_issue.id, blocked.dependency})

    assert Orchestrator.snapshot(orchestrator_name, 1_000).blocked == snapshot.blocked
  end

  test "poll route changes stop the old worker and preserve a retry claim" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_long_running_capture)

    issue = %Issue{
      id: "poll-route-change",
      identifier: "SYM-POLL-ROUTE",
      title: "Poll route change",
      state: "Planning",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning", "Ready"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    orchestrator_name = Module.concat(__MODULE__, "PollRouteOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorLongRunningFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)

      if Process.whereis(:symphony_agent_router_long_running_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_long_running_capture)
    end)

    assert_receive {:long_running_worker_started, worker_pid, ^issue, _opts}, 1_000

    changed_issue = %{issue | state: "Ready"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [changed_issue])
    send(pid, :run_poll_cycle)

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    state = :sys.get_state(pid)

    refute Process.alive?(worker_pid)
    assert snapshot.running == []
    assert [%{issue_id: "poll-route-change", attempt: 1, route_change: route_change}] = snapshot.retrying
    assert route_change.previous.profile_name == "planner"
    assert route_change.next.profile_name == "builder"
    assert state.retry_attempts[issue.id].attempt == 1
    assert MapSet.member?(state.claimed, issue.id)

    send(pid, {:DOWN, make_ref(), :process, worker_pid, :normal})
    assert [snapshot_retry] = snapshot.retrying
    assert [refreshed_retry] = Orchestrator.snapshot(orchestrator_name, 1_000).retrying
    assert Map.delete(refreshed_retry, :due_in_ms) == Map.delete(snapshot_retry, :due_in_ms)
  end
end
