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

  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.WorkControl.{GuardClass, WorkItem}

  @now ~U[2026-09-16 00:00:00Z]

  defp trusted_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: @now,
        prior_validated_lifecycle_state: issue.state
      })

    work_item
  end

  defp validated_done_work_item(id) when is_binary(id) do
    issue = %Issue{id: id, identifier: id, title: id, state: "Done"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: @now,
        prior_validated_lifecycle_state: "Merging",
        evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
      })

    work_item
  end

  test "routed polling retains raw forward observations as suspended WorkItems" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    issue = %Issue{
      id: "routed-untrusted-ready",
      identifier: "SYM-UNTRUSTED-READY",
      title: "Do not trust provider Ready",
      state: "Ready",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    orchestrator_name =
      Module.concat(__MODULE__, "SuspendedOrchestrator#{System.unique_integer([:positive])}")

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

    refute_receive {:fake_agent_run, _, _}, 300
    state = :sys.get_state(pid)
    assert %WorkItem{} = state.work_control[issue.id]
    assert state.work_control[issue.id].lifecycle_assessment.status == :validation_required
    assert state.work_control[issue.id].authority_disposition.status == :suspended
  end

  test "routed refresh removes stale WorkItems when the provider observation is malformed" do
    issue = %Issue{
      id: "routed-malformed-observation",
      identifier: "SYM-MALFORMED-OBSERVATION",
      title: "Do not retain stale authority",
      state: "Ready",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      poll_interval_ms: 60_000
    )

    state = %Orchestrator.State{work_control: %{issue.id => trusted_work_item(issue)}}
    malformed_issue = %{issue | state: nil}

    result = Orchestrator.reconcile_issue_states_for_test([malformed_issue], state)

    refute Map.has_key?(result.work_control, issue.id)
    refute Map.has_key?(result.running, issue.id)

    missing_identity = %{issue | id: nil}
    assert Orchestrator.reconcile_issue_states_for_test([missing_identity], state) == state
  end

  test "orchestrator discards malformed ephemeral WorkItems at initialization" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 60_000
    )

    malformed_map_name =
      Module.concat(__MODULE__, "MalformedWorkControlMap#{System.unique_integer([:positive])}")

    malformed_value_name =
      Module.concat(__MODULE__, "MalformedWorkControlValue#{System.unique_integer([:positive])}")

    {:ok, malformed_map_pid} =
      Orchestrator.start_link(
        name: malformed_map_name,
        work_control: %{"not-a-work-item" => :invalid}
      )

    {:ok, malformed_value_pid} =
      Orchestrator.start_link(
        name: malformed_value_name,
        work_control: :invalid
      )

    on_exit(fn ->
      if Process.alive?(malformed_map_pid), do: GenServer.stop(malformed_map_pid)
      if Process.alive?(malformed_value_pid), do: GenServer.stop(malformed_value_pid)
    end)

    assert :sys.get_state(malformed_map_pid).work_control == %{}
    assert :sys.get_state(malformed_value_pid).work_control == %{}
  end

  test "routed lifecycle suspension recovers from its last validated state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    issue = %Issue{
      id: "routed-lifecycle-recovery",
      identifier: "SYM-ROUTED-RECOVERY",
      title: "Recover from a provider suspension",
      state: "In Progress",
      dispatchable: false
    }

    state = %Orchestrator.State{work_control: %{issue.id => trusted_work_item(issue)}}
    suspended_issue = %{issue | state: "Blocked"}

    suspended_state = Orchestrator.reconcile_issue_states_for_test([suspended_issue], state)
    suspended_work_item = suspended_state.work_control[issue.id]

    assert suspended_work_item.lifecycle_assessment.status == :authority_reducing
    assert suspended_work_item.suspension_context.last_validated_lifecycle_state == :in_progress

    recovered_state = Orchestrator.reconcile_issue_states_for_test([issue], suspended_state)
    recovered_work_item = recovered_state.work_control[issue.id]

    assert recovered_work_item.lifecycle_assessment.status == :validated
    assert recovered_work_item.validated_lifecycle_state == :in_progress
    assert recovered_work_item.authority_disposition.status == :eligible
  end

  test "routed cancellation cannot automatically recover autonomous authority" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    issue = %Issue{
      id: "routed-cancellation-terminal",
      identifier: "SYM-CANCELLATION-TERMINAL",
      title: "Cancellation remains terminal",
      state: "In Progress",
      dispatchable: false
    }

    state = %Orchestrator.State{work_control: %{issue.id => trusted_work_item(issue)}}

    canceled_state =
      Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Canceled"}], state)

    canceled_work_item = canceled_state.work_control[issue.id]

    assert canceled_work_item.lifecycle_assessment.status == :authority_reducing
    assert canceled_work_item.authority_disposition.status == :suspended

    reopened_state = Orchestrator.reconcile_issue_states_for_test([issue], canceled_state)
    reopened_work_item = reopened_state.work_control[issue.id]

    assert reopened_work_item.lifecycle_assessment.status == :invalid
    assert reopened_work_item.authority_disposition.status == :suspended
    refute WorkItem.authority_available?(reopened_work_item)
  end

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

    orchestrator_name =
      Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake,
        work_control: %{issue.id => trusted_work_item(issue)}
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
    assert opts[:work_item].authority_disposition.status == :active
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

    orchestrator_name =
      Module.concat(__MODULE__, "LegacyOrchestrator#{System.unique_integer([:positive])}")

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

    blocker_issue = %Issue{
      id: "active-blocker",
      identifier: "SYM-BLOCKER",
      title: "Active blocker",
      state: "In Progress",
      dispatchable: false
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [planning_issue, ready_issue, blocker_issue])

    orchestrator_name =
      Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake,
        work_control: %{planning_issue.id => trusted_work_item(planning_issue)}
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
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    state = %Orchestrator.State{
      blocked: %{issue.id => blocked_entry},
      claimed: MapSet.new([issue.id]),
      dependency_graph: %SymphonyElixir.Dependency.Graph{},
      work_control: %{"blocker" => validated_done_work_item("blocker")}
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)
  end

  test "routed blocked attempts release on terminal observations without proving completion" do
    issue = %Issue{
      id: "routed-terminal-blocked",
      identifier: "SYM-ROUTED-TERMINAL",
      title: "Terminal routed observation",
      state: "Done",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    previous_issue = %{issue | state: "In Progress"}
    blocked_entry = %{issue_id: issue.id, issue: previous_issue, worker_host: nil}

    state = %Orchestrator.State{
      blocked: %{issue.id => blocked_entry},
      claimed: MapSet.new([issue.id]),
      work_control: %{issue.id => trusted_work_item(previous_issue)}
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue.id)
    refute MapSet.member?(updated_state.claimed, issue.id)
    assert updated_state.work_control[issue.id].lifecycle_assessment.status == :invalid
    assert updated_state.work_control[issue.id].authority_disposition.status == :suspended
    refute WorkItem.dependency_satisfying?(updated_state.work_control[issue.id])
  end

  test "routed blocked reconciliation uses canonical route availability, not active state scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Todo"],
      poll_interval_ms: 60_000
    )

    issue = %Issue{
      id: "routed-blocked-scope",
      identifier: "SYM-ROUTED-BLOCKED-SCOPE",
      title: "Canonical blocked reconciliation",
      state: "In Progress",
      dispatchable: false
    }

    state = %Orchestrator.State{
      blocked: %{issue.id => %{issue_id: issue.id, issue: issue}},
      claimed: MapSet.new([issue.id]),
      work_control: %{issue.id => trusted_work_item(issue)}
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    assert Map.has_key?(updated_state.blocked, issue.id)
    assert MapSet.member?(updated_state.claimed, issue.id)
  end

  test "routed running reconciliation uses canonical route availability, not active state scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Todo"],
      poll_interval_ms: 60_000
    )

    issue = %Issue{
      id: "routed-running-scope",
      identifier: "SYM-ROUTED-RUNNING-SCOPE",
      title: "Canonical running reconciliation",
      state: "In Progress",
      dispatchable: false
    }

    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)

    running_entry = %{
      pid: nil,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      route: route
    }

    state = %Orchestrator.State{
      running: %{issue.id => running_entry},
      claimed: MapSet.new([issue.id]),
      dependency_graph: Graph.build([issue]),
      work_control: %{issue.id => work_item}
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    assert updated_state.running[issue.id].issue == issue
    assert MapSet.member?(updated_state.claimed, issue.id)
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

    orchestrator_name =
      Module.concat(__MODULE__, "PollDependencyOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorLongRunningFake,
        work_control: %{issue.id => trusted_work_item(issue)}
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

    assert [
             %{issue_id: "poll-dependency-change", responsibility: "implementation", attempt: 0} =
               blocked
           ] = snapshot.blocked

    assert blocked.error =~ "dependency guard blocked"
    assert blocked.dependency.reason == :unresolved_hard_dependency

    assert blocked.dependency.unresolved_blockers == [
             %{id: blocker.id, identifier: blocker.identifier, state: "ready"}
           ]

    send(pid, {:DOWN, make_ref(), :process, worker_pid, :normal})
    send(pid, {:agent_dependency_blocked, changed_issue.id, blocked.dependency})

    assert Orchestrator.snapshot(orchestrator_name, 1_000).blocked == snapshot.blocked
  end

  test "poll lifecycle divergence stops the old worker without rerouting" do
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

    orchestrator_name =
      Module.concat(__MODULE__, "PollRouteOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.AgentRouterOrchestratorLongRunningFake,
        work_control: %{issue.id => trusted_work_item(issue)}
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
    assert snapshot.retrying == []
    assert state.work_control[issue.id].lifecycle_assessment.status == :validation_required
    assert state.work_control[issue.id].authority_disposition.status == :suspended
    refute MapSet.member?(state.claimed, issue.id)
    refute_receive {:agent_route_changed, "poll-route-change", _previous_route, _next_route}, 50
  end
end
