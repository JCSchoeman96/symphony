defmodule SymphonyElixir.RemH080C03NoopAgentRunner do
  def run(issue, _recipient, _opts) do
    send(Application.fetch_env!(:symphony_elixir, :rem_h080c_03_test_pid), {:rem_h080c_03_runtime_started, issue.id})
    {:ok, :completed}
  end
end

defmodule SymphonyElixir.RemH080C03BacklogPlanningDependencyRouteCouplingTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.Config
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Dependency.Guard
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.TransitionPolicy
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderObservation,
    ProviderProjectContract,
    SemanticTransitionIntent,
    WorkflowLifecycle,
    WorkItem
  }

  @work_item_id "rem-h080c-03-work-item"
  @blocker_id "rem-h080c-03-blocker"

  test "human Backlog to Planning reaches the provider while the Backlog runtime route is unavailable" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)
    work_item = Map.fetch!(state.work_control, @work_item_id)

    assert work_item.validated_lifecycle_state == :backlog
    assert Graph.complete?(state.dependency_graph)
    assert state.dependency_diagnostics[@work_item_id].reason == :route_unavailable

    assert {:error, :transition_identity_unavailable} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id)

    assert {:ok, transition_context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert transition_context.transition_identity == {:backlog, :planning}
    assert transition_context.dependency_epoch_evidence.epoch == state.dependency_graph.epoch
    assert transition_context.dependency_decision.allowed?
    assert transition_context.dependency_decision.responsibility == "planning"
    assert is_nil(transition_context.route)
    assert is_nil(transition_context.runtime_attempt_id)
    assert is_nil(transition_context.dispatch_authority_evidence)

    assert {:ok, intent} =
             SemanticTransitionIntent.new(%{
               work_item_id: @work_item_id,
               requested_from: :backlog,
               requested_to: :planning,
               responsibility: "human",
               guard_evidence: [GuardClass.requirement(:human_decision, :planning_started)]
             })

    assert {:ok, attempt} = TransitionCoordinator.request_transition(scenario.coordinator, intent)

    assert attempt.state == :verified and Agent.get(scenario.provider, & &1.patch_count) == 1,
           "expected a verified provider transition; got state=#{inspect(attempt.state)}, " <>
             "reason=#{inspect(attempt.outcome_reason)}, provider_submissions=#{Agent.get(scenario.provider, & &1.patch_count)}"

    assert attempt.post_observation_evidence.provider_state_name == "Planning"
    assert ProviderObservation.valid_tracker_read?(attempt.post_observation_evidence)
    assert Agent.get(scenario.provider, & &1.patch_count) == 1
    assert {:ok, [%Issue{state: "Planning"}]} = Tracker.fetch_issues_by_ids([@work_item_id])
    updated_state = :sys.get_state(scenario.orchestrator)

    assert %WorkItem{validated_lifecycle_state: :planning, provider_observation: %ProviderObservation{} = observation} =
             updated_state.work_control[@work_item_id]

    assert ProviderObservation.valid_tracker_read?(observation)
    assert Enum.any?(updated_state.work_control[@work_item_id].lifecycle_assessment.satisfied_guards, &(&1.name == :planning_started))
    assert not Map.has_key?(updated_state.running, @work_item_id)
  end

  test "planning allows a complete graph with an unresolved active hard dependency" do
    scenario = start_scenario!(blocker_state: "In Progress", dependent_blocked_by: [@blocker_id])
    state = await_startup_ready(scenario.orchestrator)

    assert Graph.complete?(state.dependency_graph)
    assert Map.has_key?(state.dependency_graph.nodes, @blocker_id)

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert context.dependency_decision.allowed?
    assert context.dependency_decision.dependency_status == :unresolved
    assert context.dependency_decision.reason == :planning_allowed_with_unresolved_dependencies

    assert {:ok, %{state: :verified}} = request_planning(scenario)
    assert Agent.get(scenario.provider, & &1.patch_count) == 1
  end

  test "a Ready item with an unresolved dependency remains blocked from implementation dispatch" do
    scenario =
      start_scenario!(
        state: "Ready",
        blocker_state: "In Progress",
        dependent_blocked_by: [@blocker_id]
      )

    state = await_startup_ready(scenario.orchestrator)
    issue = Map.fetch!(state.dependency_graph.nodes, @work_item_id)

    assert {:ok, work_item} =
             WorkItem.from_issue(issue, %{
               provider: :plane,
               observed_at: DateTime.utc_now(),
               prior_validated_lifecycle_state: :ready,
               provider_project_contract: scenario.contract
             })

    blocker_issue = Map.fetch!(state.dependency_graph.nodes, @blocker_id)

    assert {:ok, blocker_work_item} =
             WorkItem.from_issue(blocker_issue, %{
               provider: :plane,
               observed_at: DateTime.utc_now(),
               prior_validated_lifecycle_state: :in_progress,
               provider_project_contract: scenario.contract
             })

    work_control = Map.merge(state.work_control, %{@work_item_id => work_item, @blocker_id => blocker_work_item})
    settings = Config.settings!()

    existing_decision =
      Guard.evaluate(work_item, "implementation",
        active_states: settings.tracker.active_states || [],
        terminal_states: settings.tracker.terminal_states || [],
        work_control: work_control
      )

    assert existing_decision.reason == :unresolved_hard_dependency

    :sys.replace_state(scenario.orchestrator, fn current ->
      %{
        current
        | work_control: work_control,
          dependency_diagnostics: Map.put(current.dependency_diagnostics, @work_item_id, existing_decision)
      }
    end)

    assert {:ok, %{responsibility: "implementation"}} = Router.resolve(work_item, settings.agent.profiles, settings.agent.routes)
    assert existing_decision.allowed? == false
    refute Map.has_key?(state.running, @work_item_id)
    assert state.attempt_ledger_status == :ready
    assert Agent.get(scenario.provider, & &1.patch_count) == 0
    refute_received {:rem_h080c_03_runtime_started, @work_item_id}
  end

  test "a canceled blocker denies Backlog to Planning before provider submission" do
    scenario = start_scenario!(blocker_state: "Canceled", dependent_blocked_by: [@blocker_id])
    state = await_startup_ready(scenario.orchestrator)

    assert Graph.complete?(state.dependency_graph)
    assert Map.has_key?(state.dependency_graph.nodes, @blocker_id)

    attempt = assert_rejected_without_provider_submission(scenario)

    assert {:policy_rejected, %{code: :dependency_transition_denied}} = attempt.outcome_reason
  end

  test "a dependency cycle denies Backlog to Planning before provider submission" do
    scenario =
      start_scenario!(
        blocker_state: "In Progress",
        dependent_blocked_by: [@blocker_id],
        blocker_blocked_by: [@work_item_id]
      )

    state = await_startup_ready(scenario.orchestrator)
    assert Graph.complete?(state.dependency_graph)
    assert Graph.cyclic?(state.dependency_graph, @work_item_id)

    attempt = assert_rejected_without_provider_submission(scenario)
    assert {:policy_rejected, %{code: :dependency_transition_denied}} = attempt.outcome_reason
  end

  test "an unavailable dependency graph epoch fails closed before provider submission" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)
    :sys.replace_state(scenario.orchestrator, &%{&1 | dependency_graph: Graph.unavailable(:test_epoch_unavailable)})

    attempt = assert_rejected_without_provider_submission(scenario)
    assert attempt.state == :rejected
    assert Graph.complete?(state.dependency_graph)
  end

  test "malformed trusted dependency data denies Backlog to Planning before provider submission" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)
    work_item = Map.fetch!(state.work_control, @work_item_id)
    malformed = %{work_item | blocked_by: [%{id: @blocker_id}]}

    :sys.replace_state(scenario.orchestrator, fn current ->
      %{current | work_control: Map.put(current.work_control, @work_item_id, malformed)}
    end)

    attempt = assert_rejected_without_provider_submission(scenario)
    assert {:policy_rejected, %{code: :dependency_transition_denied}} = attempt.outcome_reason
  end

  test "cross-project dependency evidence denies Backlog to Planning before provider submission" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)

    cross_project = %{
      kind: :cross_project_dependency,
      dependent_id: @work_item_id,
      blocker_id: @blocker_id,
      blocker: %{project_id: "other-project"}
    }

    :sys.replace_state(scenario.orchestrator, fn current ->
      graph = %{current.dependency_graph | diagnostics: [cross_project]}
      %{current | dependency_graph: graph}
    end)

    refute Graph.complete?(%{state.dependency_graph | diagnostics: [cross_project]})
    attempt = assert_rejected_without_provider_submission(scenario)
    assert attempt.state == :rejected
  end

  test "dependency eligibility cannot replace the human planning decision" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert context.dependency_decision.allowed?

    assert {:ok, intent} =
             SemanticTransitionIntent.new(%{
               work_item_id: @work_item_id,
               requested_from: :backlog,
               requested_to: :planning,
               responsibility: "human",
               guard_evidence: []
             })

    assert {:ok, %{state: :rejected} = attempt} =
             TransitionCoordinator.request_transition(scenario.coordinator, intent)

    assert attempt.outcome_reason != nil
    assert Agent.get(scenario.provider, & &1.patch_count) == 0
    assert Map.fetch!(state.work_control, @work_item_id).validated_lifecycle_state == :backlog
  end

  test "dependency epoch movement invalidates the scoped token at verified apply" do
    after_patch = fn orchestrator, _provider ->
      :sys.replace_state(orchestrator, fn state ->
        %{state | dependency_graph: %{state.dependency_graph | epoch: make_ref()}}
      end)
    end

    scenario = start_scenario!(after_patch: after_patch)
    state = await_startup_ready(scenario.orchestrator)
    old_epoch = state.dependency_graph.epoch

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert {:ok, %{state: :verified} = attempt} = request_planning(scenario)
    assert attempt.post_observation_evidence.provider_state_name == "Planning"
    assert Agent.get(scenario.provider, & &1.patch_count) == 1

    current = :sys.get_state(scenario.orchestrator)
    assert current.dependency_graph.epoch != old_epoch
    assert current.work_control[@work_item_id].validated_lifecycle_state == :backlog

    assert {:error, :context_token_mismatch} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning,
               expected_context_token: context.context_token
             )
  end

  test "a scoped planning token rejects a different transition identity at apply" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)
    work_item = Map.fetch!(state.work_control, @work_item_id)

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert {:error, :context_token_mismatch} =
             Orchestrator.apply_transition_result(
               scenario.orchestrator,
               @work_item_id,
               work_item,
               expected_context_token: context.context_token,
               requested_from: :backlog,
               requested_to: :ready
             )

    assert :backlog == :sys.get_state(scenario.orchestrator).work_control[@work_item_id].validated_lifecycle_state
    assert Agent.get(scenario.provider, & &1.patch_count) == 0
  end

  test "verified Backlog to Planning apply requires its scoped context token" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)
    work_item = Map.fetch!(state.work_control, @work_item_id)

    assert {:error, :context_token_mismatch} =
             Orchestrator.apply_transition_result(
               scenario.orchestrator,
               @work_item_id,
               work_item,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert :backlog == :sys.get_state(scenario.orchestrator).work_control[@work_item_id].validated_lifecycle_state
    assert Agent.get(scenario.provider, & &1.patch_count) == 0
  end

  test "a changed provider observation invalidates the scoped context token" do
    scenario = start_scenario!()
    state = await_startup_ready(scenario.orchestrator)

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning
             )

    assert {:ok, [issue]} = Tracker.fetch_issues_by_ids([@work_item_id])

    assert {:ok, changed_item} =
             WorkItem.from_issue(issue, %{
               provider: :plane,
               observed_at: DateTime.add(DateTime.utc_now(), 1, :second),
               prior_validated_lifecycle_state: :backlog,
               provider_project_contract: scenario.contract
             })

    :sys.replace_state(scenario.orchestrator, fn current ->
      %{current | work_control: Map.put(current.work_control, @work_item_id, changed_item)}
    end)

    assert {:error, :context_token_mismatch} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :backlog,
               requested_to: :planning,
               expected_context_token: context.context_token
             )

    refute state.work_control[@work_item_id].provider_observation.snapshot_identity ==
             changed_item.provider_observation.snapshot_identity

    assert Agent.get(scenario.provider, & &1.patch_count) == 0
  end

  test "Ready to In Progress keeps its cached dependency decision and RuntimeAttempt gate" do
    scenario = start_scenario!(state: "Ready")

    state = await_startup_ready(scenario.orchestrator)
    issue = Map.fetch!(state.dependency_graph.nodes, @work_item_id)
    assert issue.dependency_completeness == :complete

    assert {:ok, work_item} =
             WorkItem.from_issue(issue, %{
               provider: :plane,
               observed_at: DateTime.utc_now(),
               prior_validated_lifecycle_state: :ready,
               provider_project_contract: scenario.contract
             })

    assert work_item.lifecycle_assessment.status == :validated

    settings = Config.settings!()

    existing_decision =
      Guard.evaluate(work_item, "implementation",
        active_states: settings.tracker.active_states || [],
        terminal_states: settings.tracker.terminal_states || [],
        work_control: Map.put(state.work_control, @work_item_id, work_item)
      )

    assert existing_decision.allowed?, inspect(existing_decision)

    :sys.replace_state(scenario.orchestrator, fn current ->
      %{
        current
        | work_control: Map.put(current.work_control, @work_item_id, work_item),
          dependency_diagnostics: Map.put(current.dependency_diagnostics, @work_item_id, existing_decision)
      }
    end)

    assert TransitionPolicy.dependency_purpose(:ready, :in_progress) == {:ok, :existing}

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles, Config.settings!().agent.routes)
    assert route.responsibility == "implementation"

    assert {:ok, context} =
             Orchestrator.transition_context(scenario.orchestrator, @work_item_id,
               requested_from: :ready,
               requested_to: :in_progress
             )

    assert context.transition_identity == {:ready, :in_progress}
    assert context.dependency_decision == existing_decision
    assert context.dependency_decision.responsibility == "implementation"
    assert context.dependency_decision.allowed? == true
    assert is_nil(context.dispatch_authority_evidence)
    refute Enum.any?(work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :dispatch_guard))
    refute Map.has_key?(state.running, @work_item_id)

    assert {:ok, missing_runtime_intent} =
             SemanticTransitionIntent.new(%{
               work_item_id: @work_item_id,
               requested_from: :ready,
               requested_to: :in_progress,
               responsibility: "implementation",
               guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)]
             })

    assert {:ok, %{state: :rejected} = missing_runtime_attempt} =
             TransitionCoordinator.request_transition(scenario.coordinator, missing_runtime_intent, route: route)

    assert missing_runtime_attempt.outcome_reason == :required_guard_missing

    assert {:ok, claimed_runtime_intent} =
             SemanticTransitionIntent.new(%{
               work_item_id: @work_item_id,
               requested_from: :ready,
               requested_to: :in_progress,
               responsibility: "implementation",
               runtime_attempt_id: "rem-h080c-03-not-a-live-runtime-attempt",
               lineage_generation: "rem-h080c-03-not-a-live-lineage",
               guard_evidence: []
             })

    assert {:ok, %{state: :rejected} = stale_runtime_attempt} =
             TransitionCoordinator.request_transition(scenario.coordinator, claimed_runtime_intent, route: route)

    assert stale_runtime_attempt.outcome_reason == {:context_unavailable, :stale_runtime_attempt}

    assert {:ok, %{state: :rejected}} =
             TransitionCoordinator.request_transition(scenario.coordinator, claimed_runtime_intent)

    assert Agent.get(scenario.provider, & &1.patch_count) == 0
    refute_received {:rem_h080c_03_runtime_started, @work_item_id}
  end

  defp request_planning(scenario) do
    assert {:ok, intent} =
             SemanticTransitionIntent.new(%{
               work_item_id: @work_item_id,
               requested_from: :backlog,
               requested_to: :planning,
               responsibility: "human",
               guard_evidence: [GuardClass.requirement(:human_decision, :planning_started)]
             })

    TransitionCoordinator.request_transition(scenario.coordinator, intent)
  end

  defp assert_rejected_without_provider_submission(scenario) do
    assert {:ok, %{state: :rejected} = attempt} = request_planning(scenario)
    assert Agent.get(scenario.provider, & &1.patch_count) == 0
    refute_received {:rem_h080c_03_runtime_started, @work_item_id}
    attempt
  end

  defp start_scenario!(opts \\ []) do
    root = Path.join(System.tmp_dir!(), "rem-h080c-03-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    workflow_path = Path.join(root, "WORKFLOW.md")
    codex = Path.join(root, "codex")
    File.write!(codex, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex, 0o700)

    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_test_pid = Application.get_env(:symphony_elixir, :rem_h080c_03_test_pid)
    previous_provider = Application.get_env(:symphony_elixir, :rem_h080c_03_provider)
    previous_coordinator = Application.get_env(:symphony_elixir, :rem_h080c_03_coordinator)
    previous_options = Req.default_options()
    previous_runtime_key = System.get_env("PLANE_API_KEY_FERDI")

    provider =
      start_supervised!(
        {Agent,
         fn ->
           %{
             state: Keyword.get(opts, :state, "Backlog"),
             blocker_state: Keyword.get(opts, :blocker_state),
             dependent_blocked_by: Keyword.get(opts, :dependent_blocked_by, []),
             blocker_blocked_by: Keyword.get(opts, :blocker_blocked_by, []),
             relation_mode: Keyword.get(opts, :relation_mode, :normal),
             after_patch: Keyword.get(opts, :after_patch),
             orchestrator: nil,
             patch_count: 0
           }
         end}
      )

    contract = provider_contract()

    on_exit(fn ->
      restore_test_env(:workflow_file_path, previous_workflow_path)
      restore_test_env(:rem_h080c_03_test_pid, previous_test_pid)
      restore_test_env(:rem_h080c_03_provider, previous_provider)
      restore_test_env(:rem_h080c_03_coordinator, previous_coordinator)
      restore_env("PLANE_API_KEY_FERDI", previous_runtime_key)
      Req.default_options(previous_options)
      Req.Test.set_req_test_to_private()
      File.rm_rf(root)
    end)

    :ok =
      write_workflow_file!(workflow_path,
        tracker_kind: "plane",
        tracker_endpoint: "https://api.plane.so",
        tracker_project_slug: "project-1",
        symphony_project_id: "project-1",
        tracker_active_states: ["Planning", "Ready", "In Progress", "In Review", "Ready to Merge", "Merging"],
        agent_routing: "routed",
        codex_command: "#{codex} app-server",
        workspace_root: Path.join(root, "workspaces"),
        poll_interval_ms: 60_000,
        provider_project_contract: contract_config(contract)
      )

    File.write!(
      workflow_path,
      String.replace(
        File.read!(workflow_path),
        "tracker:\n",
        "tracker:\n  provider:\n    workspace_slug: workspace-1\n    workspace_id: workspace-1\n    project_id: project-1\n    api_key: $PLANE_API_KEY_FERDI\n"
      )
    )

    System.put_env("PLANE_API_KEY_FERDI", "rem-h080c-03-plane-test-key")
    :ok = Workflow.set_workflow_file_path(workflow_path)
    :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :rem_h080c_03_test_pid, self())
    Application.put_env(:symphony_elixir, :rem_h080c_03_provider, provider)

    req_stub = {:rem_h080c_03, System.unique_integer([:positive])}
    :ok = Req.Test.set_req_test_to_shared()
    :ok = Req.Test.stub(req_stub, &plane_request(&1, provider))
    :ok = Req.default_options(Keyword.put(previous_options, :plug, {Req.Test, req_stub}))

    {:ok, [issue]} = Tracker.fetch_issues_by_ids([@work_item_id])

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: DateTime.utc_now(),
        provider_project_contract: contract
      })

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: nil,
        start_quiesced: true,
        read_scheduler: nil,
        task_supervisor: task_supervisor,
        agent_runner: SymphonyElixir.RemH080C03NoopAgentRunner,
        work_control: %{@work_item_id => work_item},
        attempt_ledger_opts: [path: Path.join(root, "attempts.dets")],
        recovery_ledger_opts: [path: Path.join(root, "recovery.dets")],
        workspace_ownership_ledger_opts: [root: Path.join(root, "ownership")]
      )

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        orchestrator: orchestrator,
        refresh_contract: fn context -> {:ok, context.provider_project_contract} end,
        ledger_opts: [path: Path.join(root, "transitions.dets")]
      )

    :sys.replace_state(orchestrator, &%{&1 | transition_coordinator: coordinator})
    Application.put_env(:symphony_elixir, :rem_h080c_03_coordinator, coordinator)
    Agent.update(provider, &Map.put(&1, :orchestrator, orchestrator))
    send(orchestrator, :run_poll_cycle)

    on_exit(fn ->
      stop_process(coordinator)
      stop_process(orchestrator)
      stop_process(task_supervisor)
    end)

    %{orchestrator: orchestrator, coordinator: coordinator, provider: provider, contract: contract, root: root}
  end

  defp await_startup_ready(orchestrator, attempts \\ 500)

  defp await_startup_ready(orchestrator, 0) do
    state = :sys.get_state(orchestrator)

    flunk(
      "Orchestrator did not complete its dependency epoch: #{inspect(%{status: state.startup_reconciliation, epoch_status: state.plane_epoch_status, epoch_error: state.plane_epoch_error, epoch_task?: is_map(state.plane_epoch_task), graph: state.dependency_graph, provider: Agent.get(Application.fetch_env!(:symphony_elixir, :rem_h080c_03_provider), &Map.take(&1, [:state, :blocker_state, :dependent_blocked_by, :blocker_blocked_by]))})}"
    )
  end

  defp await_startup_ready(orchestrator, attempts) do
    state = :sys.get_state(orchestrator)

    if state.startup_reconciliation == :ready and Graph.complete?(state.dependency_graph) do
      state
    else
      Process.sleep(20)
      await_startup_ready(orchestrator, attempts - 1)
    end
  end

  defp plane_request(conn, provider) do
    path = conn.request_path

    send(
      Application.fetch_env!(:symphony_elixir, :rem_h080c_03_test_pid),
      {:rem_h080c_03_provider_request, path, conn.method}
    )

    case runtime_principal_response(path) do
      {:ok, body} ->
        Req.Test.json(conn, body)

      :not_runtime_principal ->
        dispatch_provider_request(conn, provider, path)
    end
  end

  defp runtime_principal_response("/api/v2/users/me/") do
    {:ok,
     %{
       "id" => "920272c2-862e-4592-b13e-b0ba11c91b12",
       "principal_kind" => "api_key"
     }}
  end

  defp runtime_principal_response("/api/v2/workspaces/workspace-1/projects/project-1/permissions/me/") do
    {:ok,
     %{
       "relation" => "contributor",
       "permission_grants" => ["workitem:view", "workitem:edit"]
     }}
  end

  defp runtime_principal_response(_path), do: :not_runtime_principal

  defp dispatch_provider_request(conn, provider, path) do
    case plane_request_kind(path, conn.method) do
      :states ->
        states = Enum.map(WorkflowLifecycle.states(), &provider_state/1)
        Req.Test.json(conn, %{"results" => states, "count" => length(states), "total_results" => length(states), "next_page_results" => false, "next_cursor" => nil})

      :project ->
        Req.Test.json(conn, %{"id" => "project-1", "name" => "Remediation test project", "identifier" => "SYM", "workspace_id" => "workspace-1", "workspace_slug" => "workspace-1"})

      :relations ->
        Req.Test.json(conn, provider_relations(path, provider))

      :patch ->
        patch_provider_state(conn, provider)

      :collection ->
        issues = provider_issues(provider)
        Req.Test.json(conn, %{"results" => issues, "count" => length(issues), "total_results" => length(issues), "next_page_results" => false, "next_cursor" => nil})

      {:issue, issue_id} ->
        Req.Test.json(conn, provider_issue(provider, issue_id))

      :unknown ->
        Plug.Conn.resp(conn, 404, "unexpected Plane path: #{path}")
    end
  end

  defp plane_request_kind(path, method) do
    cond do
      String.ends_with?(path, "/projects/project-1/states/") -> :states
      String.ends_with?(path, "/projects/project-1/") -> :project
      String.contains?(path, "/work-items/") and String.ends_with?(path, "/relations/") -> :relations
      String.contains?(path, "/work-items/#{@work_item_id}/") and method == "PATCH" -> :patch
      String.ends_with?(path, "/work-items/") -> :collection
      true -> plane_issue_request_kind(path)
    end
  end

  defp plane_issue_request_kind(path) do
    cond do
      String.contains?(path, "/work-items/#{@work_item_id}/") -> {:issue, @work_item_id}
      String.contains?(path, "/work-items/#{@blocker_id}/") -> {:issue, @blocker_id}
      true -> :unknown
    end
  end

  defp patch_provider_state(conn, provider) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    state_id = Jason.decode!(body)["state"]
    {:ok, lifecycle_state} = WorkflowLifecycle.parse(String.replace_prefix(state_id, "state-", ""))

    Agent.update(provider, &Map.merge(&1, %{state: WorkflowLifecycle.display(lifecycle_state), patch_count: &1.patch_count + 1}))

    case Agent.get(provider, &{&1.after_patch, &1.orchestrator}) do
      {after_patch, orchestrator} when is_function(after_patch, 2) -> after_patch.(orchestrator, provider)
      _no_hook -> :ok
    end

    Req.Test.json(conn, %{})
  end

  defp provider_issues(provider) do
    blocker_state = Agent.get(provider, & &1.blocker_state)

    [provider_issue(provider, @work_item_id)] ++
      if(is_binary(blocker_state), do: [provider_issue(provider, @blocker_id)], else: [])
  end

  defp provider_issue(provider, @work_item_id) do
    state = Agent.get(provider, & &1.state)
    provider_issue(@work_item_id, "Backlog dependency route test", state)
  end

  defp provider_issue(provider, @blocker_id) do
    state = Agent.get(provider, & &1.blocker_state)
    provider_issue(@blocker_id, "Dependency blocker", state)
  end

  defp provider_issue(issue_id, name, state) do
    {:ok, lifecycle_state} = WorkflowLifecycle.parse(state)

    %{
      "id" => issue_id,
      "name" => name,
      "state" => %{
        "id" => "state-#{lifecycle_state}",
        "name" => state,
        "group" => provider_group(lifecycle_state)
      },
      "project" => "project-1",
      "workspace" => "workspace-1",
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp provider_relations(path, provider) do
    issue_id = if String.contains?(path, "/work-items/#{@blocker_id}/"), do: @blocker_id, else: @work_item_id

    %{relation_mode: mode, dependent_blocked_by: dependent_blocked_by, blocker_blocked_by: blocker_blocked_by} =
      Agent.get(provider, &Map.take(&1, [:relation_mode, :dependent_blocked_by, :blocker_blocked_by]))

    blocked_by_ids = if issue_id == @work_item_id, do: dependent_blocked_by, else: blocker_blocked_by

    blocking_ids =
      reciprocal_blocking_ids(issue_id, dependent_blocked_by, blocker_blocked_by)

    if mode == :malformed and issue_id == @work_item_id do
      %{"blocked_by" => %{}, "blocking" => []}
    else
      relation_project_id = if mode == :cross_project, do: "other-project", else: "project-1"
      relation_entry = fn id -> %{"issue_id" => id, "project_id" => relation_project_id} end

      %{
        "blocked_by" => Enum.map(blocked_by_ids, relation_entry),
        "blocking" => Enum.map(blocking_ids, relation_entry)
      }
    end
  end

  defp reciprocal_blocking_ids(issue_id, dependent_blocked_by, blocker_blocked_by) do
    blocker_blocks_work_item =
      if issue_id == @blocker_id and Enum.member?(dependent_blocked_by, @blocker_id),
        do: [@work_item_id],
        else: []

    work_item_blocks_blocker =
      if issue_id == @work_item_id and Enum.member?(blocker_blocked_by, @work_item_id),
        do: [@blocker_id],
        else: []

    blocker_blocks_work_item ++ work_item_blocks_blocker
  end

  defp provider_state(state) do
    %{
      "id" => "state-#{state}",
      "name" => WorkflowLifecycle.display(state),
      "group" => provider_group(state),
      "project" => "project-1",
      "workspace" => "workspace-1"
    }
  end

  defp provider_group(:backlog), do: "backlog"
  defp provider_group(state) when state in [:planning, :ready], do: "unstarted"
  defp provider_group(:done), do: "completed"
  defp provider_group(:canceled), do: "cancelled"
  defp provider_group(_state), do: "started"

  defp provider_contract do
    mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-1",
        project_id: "project-1",
        runtime_principal: runtime_principal_policy(),
        state_mappings: mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end

  defp contract_config(contract) do
    %{
      schema_version: contract.schema_version,
      provider: "plane",
      workspace_id: contract.workspace_id,
      project_id: contract.project_id,
      runtime_principal: Map.new(contract.runtime_principal, fn {key, value} -> {Atom.to_string(key), value} end),
      state_mappings:
        Map.new(contract.state_mappings, fn {state, mapping} ->
          {state, Map.take(mapping, [:state_id, :name])}
        end),
      dependency_relation_semantics: contract.dependency_relation_semantics
    }
  end

  defp runtime_principal_policy do
    %{
      api_key_env: "PLANE_API_KEY_FERDI",
      user_id: "920272c2-862e-4592-b13e-b0ba11c91b12",
      principal_kind: "api_key",
      project_relation: "contributor",
      required_permissions: ["workitem:view", "workitem:edit"]
    }
  end

  defp restore_test_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_test_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp stop_process(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end
