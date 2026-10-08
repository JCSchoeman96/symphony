defmodule SymphonyElixir.Pre080cProductionPathOrchestrator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:transition_context, _work_item_id, _opts}, _from, opts) do
    {:reply, Keyword.get(opts, :transition_context, :unavailable), opts}
  end
end

defmodule SymphonyElixir.Pre080cProductionRuntime do
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.AgentTool

  def start_session(_workspace, opts), do: {:ok, opts}

  def run_turn(_session, _prompt, issue, opts) do
    test_pid = Keyword.fetch!(opts, :pre_080c_test_pid)
    orchestrator = Keyword.fetch!(opts, :orchestrator_server)
    coordinator = Keyword.fetch!(opts, :coordinator)
    host_context = Keyword.fetch!(opts, :agent_tool_context)
    target_state = if host_context.route.responsibility == "planning", do: "Ready", else: "In Progress"

    send(test_pid, {:pre_080c_runtime_waiting, self(), issue.id, host_context})

    receive do
      :pre_080c_continue_to_tool -> :ok
    after
      5_000 -> raise "timed out waiting to continue PRE-080C dispatch proof"
    end

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => target_state},
        agent_tool_context: host_context,
        tracker_settings: %{kind: "plane", provider: %{"workspace_id" => "workspace-1", "project_id" => "project-1"}},
        coordinator: coordinator,
        semantic_tool_context: fn work_item_id -> Orchestrator.semantic_tool_context(orchestrator, work_item_id) end
      )

    send(test_pid, {:pre_080c_tool_response, response})

    receive do
      :pre_080c_finish_runtime -> {:ok, :completed}
    after
      5_000 -> raise "timed out waiting to finish PRE-080C dispatch proof"
    end
  end

  def stop_session(_session), do: :ok
end

defmodule SymphonyElixir.Pre080cProductionAgentRunner do
  alias SymphonyElixir.AgentRunner

  def run(issue, recipient, opts) do
    AgentRunner.run(
      issue,
      recipient,
      opts
      |> Keyword.put(:runtime, SymphonyElixir.Pre080cProductionRuntime)
      |> Keyword.put(:orchestrator_server, recipient)
      |> Keyword.put(:coordinator, Application.fetch_env!(:symphony_elixir, :pre_080c_test_coordinator))
      |> Keyword.put(:pre_080c_test_pid, Application.fetch_env!(:symphony_elixir, :pre_080c_test_pid))
      |> Keyword.put(:test_runtime_isolation_admit, fn _worker_host, _executable, _opts -> {:ok, :admitted} end)
    )
  end
end

defmodule SymphonyElixir.Pre080cProductionEvidenceAcquisitionTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRuntime.{AttemptLedger, Profile, Route, RuntimeAttempt}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.Pre080cProductionPathOrchestrator, as: ProductionPathOrchestrator
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderObservation,
    ProviderProjectContract,
    RecoveryLedger,
    SemanticTransitionIntent,
    TransitionAttemptLedger,
    WorkflowLifecycle,
    WorkItem
  }

  @now ~U[2026-09-20 00:00:00Z]
  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  @settings %{
    kind: "plane",
    provider: %{"workspace_id" => "workspace-1", "project_id" => "project-1"}
  }

  @source_control_config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [%{context: "make-all", app_id: 15_368, subject: "head"}]
  }

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    :ok
  end

  describe "RuntimeAttempt identity binding (fail-closed matrix)" do
    test "missing RuntimeAttempt identity fails closed before semantic attestation is created" do
      work_item_id = "pre-080c-missing-identity"
      route = route(work_item_id, :in_progress, "implementation")
      coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

      response =
        transition_response(work_item_id, route, coordinator, "In Review",
          identity: nil,
          source: :in_progress
        )

      assert_rejects_runtime(response)
      refute_received {:transition_submitted, _, _}
      GenServer.stop(coordinator)
    end

    test "host and semantic RuntimeAttempt mismatch fails closed" do
      work_item_id = "pre-080c-identity-mismatch"
      route = route(work_item_id, :in_progress, "implementation")
      identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-current")
      stale_host = %{identity | runtime_attempt_id: "stale-attempt-id"}
      coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

      response =
        transition_response(work_item_id, route, coordinator, "In Review",
          identity: identity,
          host_identity: stale_host,
          source: :in_progress
        )

      assert_rejects_runtime(response)
      GenServer.stop(coordinator)
    end

    test "correct attempt id with wrong lineage generation fails closed" do
      work_item_id = "pre-080c-wrong-generation"
      route = route(work_item_id, :in_progress, "implementation")
      identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-current")
      stale_lineage = %{identity | lineage_generation: "lineage-prior-rearm"}
      coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

      response =
        transition_response(work_item_id, route, coordinator, "In Review",
          identity: identity,
          semantic_identity: stale_lineage,
          source: :in_progress
        )

      assert_rejects_runtime(response)
      GenServer.stop(coordinator)
    end

    test "prior retry or rearm lineage cannot satisfy a replacement RuntimeAttempt" do
      work_item_id = "pre-080c-replacement-attempt"
      route = route(work_item_id, :in_progress, "implementation")
      prior = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-prior-retry")
      replacement = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-replacement")
      coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

      response =
        transition_response(work_item_id, route, coordinator, "In Review",
          identity: replacement,
          semantic_identity: prior,
          source: :in_progress
        )

      assert_rejects_runtime(response)
      GenServer.stop(coordinator)
    end

    test "current exact RuntimeAttempt id and lineage generation succeeds" do
      work_item_id = "pre-080c-identity-success"
      route = route(work_item_id, :in_progress, "implementation")
      identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-exact")
      coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

      response =
        transition_response(work_item_id, route, coordinator, "In Review",
          identity: identity,
          source: :in_progress
        )

      assert response["success"]

      assert_receive {:transition_submitted, attempt, _enriched}
      attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
      assert attestation.runtime_attempt_id == identity.runtime_attempt_id
      assert attestation.lineage_generation == identity.lineage_generation
      GenServer.stop(coordinator)
    end
  end

  test "builder ordinary path acquires semantic and mechanical evidence without seeded guard_evidence" do
    work_item_id = "pre-080c-builder"
    route = route(work_item_id, :in_progress, "implementation")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-pre-080c-builder")
    coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        agent_tool_opts(work_item_id, route, coordinator, identity: identity, source: :in_progress)
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, enriched_evidence}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :implementation_attested
    assert attestation.runtime_attempt_id == identity.runtime_attempt_id
    assert attestation.lineage_generation == identity.lineage_generation

    assert Enum.any?(enriched_evidence, &match?(%{name: :candidate_state_verified, outcome: :verified}, &1))
    assert Enum.any?(enriched_evidence, &match?(%{name: :implementation_checks_verified, class: :mechanical_guard}, &1))

    GenServer.stop(coordinator)
  end

  test "planner ordinary path acquires plan_attested and planning_requirements_verified without seeded guard_evidence" do
    work_item_id = "pre-080c-planner"
    route = route(work_item_id, :planning, "planning")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-pre-080c-planner")
    coordinator = production_coordinator(work_item_id, :planning, capture?: false)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Ready"},
        agent_tool_opts(work_item_id, route, coordinator, identity: identity, source: :planning)
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, enriched_evidence}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :plan_attested
    assert attestation.runtime_attempt_id == identity.runtime_attempt_id
    assert attestation.lineage_generation == identity.lineage_generation

    assert Enum.any?(enriched_evidence, &match?(%{name: :planning_requirements_verified, class: :mechanical_guard}, &1))

    GenServer.stop(coordinator)
  end

  test "fixer ordinary path acquires correction_attested and correction_checks_verified without seeded guard_evidence" do
    work_item_id = "pre-080c-fixer"
    route = route(work_item_id, :changes_requested, "correction")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-pre-080c-fixer")
    coordinator = production_coordinator(work_item_id, :changes_requested, capture?: true)

    response =
      transition_response(work_item_id, route, coordinator, "In Review",
        identity: identity,
        source: :changes_requested
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, enriched_evidence}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :correction_attested
    assert attestation.runtime_attempt_id == identity.runtime_attempt_id
    assert attestation.lineage_generation == identity.lineage_generation

    assert Enum.any?(enriched_evidence, &match?(%{name: :candidate_state_verified, outcome: :verified}, &1))
    assert Enum.any?(enriched_evidence, &match?(%{name: :correction_checks_verified, class: :mechanical_guard}, &1))

    GenServer.stop(coordinator)
  end

  test "reviewer ordinary path acquires review_changes_requested without seeded guard_evidence" do
    work_item_id = "pre-080c-reviewer-changes"
    route = route(work_item_id, :in_review, "review")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-pre-080c-reviewer-changes")
    coordinator = production_coordinator(work_item_id, :in_review, capture?: false)

    response =
      transition_response(work_item_id, route, coordinator, "Changes Requested",
        identity: identity,
        source: :in_review
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, _enriched}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :review_changes_requested
    assert attestation.runtime_attempt_id == identity.runtime_attempt_id
    assert attestation.lineage_generation == identity.lineage_generation

    GenServer.stop(coordinator)
  end

  test "reviewer ordinary path acquires review_accepted and review_acceptance_verified after builder candidate facts" do
    work_item_id = "pre-080c-reviewer-accept"
    builder_route = route(work_item_id, :in_progress, "implementation")
    builder_identity = RuntimeAttemptIdentity.allocate(work_item_id, builder_route, "lineage-pre-080c-builder-phase")
    builder_coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

    assert transition_response(work_item_id, builder_route, builder_coordinator, "In Review",
             identity: builder_identity,
             source: :in_progress
           )["success"]

    assert_receive {:transition_submitted, builder_attempt, builder_evidence}
    GenServer.stop(builder_coordinator)

    issue = tracked_issue(work_item_id, :in_review)
    handoff_guards = projected_handoff_guards(builder_attempt, builder_evidence)
    work_item = work_item_with_satisfied_guards(work_item_for_issue(issue), handoff_guards)

    reviewer_route = route(work_item_id, :in_review, "review")
    reviewer_identity = RuntimeAttemptIdentity.allocate(work_item_id, reviewer_route, "lineage-pre-080c-reviewer-accept")
    reviewer_coordinator = production_coordinator(work_item_id, :in_review, capture?: true, work_item: work_item)

    response =
      transition_response(work_item_id, reviewer_route, reviewer_coordinator, "Ready to Merge",
        identity: reviewer_identity,
        source: :in_review,
        work_item: work_item,
        runner_host_context?: true
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, enriched_evidence}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :review_accepted
    assert attestation.runtime_attempt_id == reviewer_identity.runtime_attempt_id
    assert attestation.lineage_generation == reviewer_identity.lineage_generation

    assert Enum.any?(enriched_evidence, &match?(%{name: :review_acceptance_verified, class: :mechanical_guard}, &1))

    GenServer.stop(reviewer_coordinator)
  end

  test "builder transition succeeds when trusted host context retains prior planner semantic evidence" do
    work_item_id = "pre-080c-planner-to-builder"
    planner_route = route(work_item_id, :planning, "planning")
    planner_identity = RuntimeAttemptIdentity.allocate(work_item_id, planner_route, "lineage-pre-080c-planner-handoff")
    planner_coordinator = production_coordinator(work_item_id, :planning, capture?: false)

    assert transition_response(work_item_id, planner_route, planner_coordinator, "Ready",
             identity: planner_identity,
             source: :planning
           )["success"]

    assert_receive {:transition_submitted, planner_attempt, planner_enriched}
    GenServer.stop(planner_coordinator)

    handoff_guards = projected_handoff_guards(planner_attempt, planner_enriched)
    in_progress_issue = tracked_issue(work_item_id, :in_progress)

    in_progress_work_item =
      work_item_with_satisfied_guards(work_item_for_issue(in_progress_issue), handoff_guards)

    builder_route = route(work_item_id, :in_progress, "implementation")
    builder_identity = RuntimeAttemptIdentity.allocate(work_item_id, builder_route, "lineage-pre-080c-builder-handoff")

    builder_coordinator =
      production_coordinator(work_item_id, :in_progress, capture?: true, work_item: in_progress_work_item)

    response =
      transition_response(work_item_id, builder_route, builder_coordinator, "In Review",
        identity: builder_identity,
        source: :in_progress,
        work_item: in_progress_work_item,
        runner_host_context?: true
      )

    assert response["success"]

    assert_receive {:transition_submitted, attempt, _enriched}
    attestation = Enum.find(attempt.guard_evidence, &(&1.class == :semantic_attestation))
    assert attestation.name == :implementation_attested
    refute Enum.any?(attempt.guard_evidence, &(&1.name == :plan_attested))
    GenServer.stop(builder_coordinator)
  end

  @tag :documented_production_gap
  test "reproducer: planner-ready work item does not supply dispatch_guard for unseeded ready to in progress" do
    work_item_id = "pre-080c-dispatch-gap"
    planner_route = route(work_item_id, :planning, "planning")
    planner_identity = RuntimeAttemptIdentity.allocate(work_item_id, planner_route, "lineage-pre-080c-dispatch-gap")
    planner_coordinator = production_coordinator(work_item_id, :planning, capture?: false)

    assert transition_response(work_item_id, planner_route, planner_coordinator, "Ready",
             identity: planner_identity,
             source: :planning
           )["success"]

    assert_receive {:transition_submitted, planner_attempt, planner_enriched}
    GenServer.stop(planner_coordinator)

    ready_work_item =
      work_item_with_satisfied_guards(
        work_item_for_issue(tracked_issue(work_item_id, :ready)),
        projected_handoff_guards(planner_attempt, planner_enriched)
      )

    dispatch_route = route(work_item_id, :ready, "implementation")

    dispatch_identity =
      RuntimeAttemptIdentity.allocate(work_item_id, dispatch_route, "lineage-pre-080c-dispatch-gap")

    dispatch_coordinator = production_coordinator(work_item_id, :ready, capture?: false, work_item: ready_work_item)

    response =
      transition_response(work_item_id, dispatch_route, dispatch_coordinator, "In Progress",
        work_item: ready_work_item,
        identity: dispatch_identity,
        runner_host_context?: true,
        source: :ready
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "required_guard_missing"
    GenServer.stop(dispatch_coordinator)
  end

  test "a bare dispatch_guard does not satisfy the contextual Ready to In Progress requirement" do
    work_item_id = "pre-080c-bare-dispatch-guard"
    route = route(work_item_id, :ready, "implementation")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-bare-dispatch-guard")
    requirement = GuardClass.requirement(:mechanical_guard, :dispatch_guard)
    bare_guard = %{class: :mechanical_guard, name: :dispatch_guard}

    context = %{
      subject: {:work_item, work_item_id},
      transition: {:ready, :in_progress},
      responsibility: "implementation",
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_generation: identity.lineage_generation,
      runtime_profile: route.profile_name,
      route_fingerprint: route.fingerprint,
      trusted_route: route
    }

    refute GuardClass.satisfied?(requirement, bare_guard, context)
    refute GuardClass.all_satisfied?([requirement], [bare_guard], context)
  end

  test "real Planner to Ready result feeds real Builder dispatch and fresh Coordinator authority" do
    root = Path.join(System.tmp_dir!(), "pre-080c-production-path-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workflow_path = Path.join(root, "WORKFLOW.md")
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_test_pid = Application.get_env(:symphony_elixir, :pre_080c_test_pid)
    previous_coordinator = Application.get_env(:symphony_elixir, :pre_080c_test_coordinator)
    previous_plane_api_key = System.get_env("PLANE_API_KEY")
    previous_req_options = Req.default_options()
    codex = Path.join(root, "codex")
    File.mkdir_p!(root)
    File.write!(codex, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex, 0o700)

    on_exit(fn ->
      restore_application_env(:workflow_file_path, previous_workflow_path)
      restore_application_env(:memory_tracker_issues, previous_memory_issues)
      restore_application_env(:pre_080c_test_pid, previous_test_pid)
      restore_application_env(:pre_080c_test_coordinator, previous_coordinator)
      restore_env("PLANE_API_KEY", previous_plane_api_key)
      Req.default_options(previous_req_options)
      Req.Test.set_req_test_to_private()
      File.rm_rf(root)
    end)

    provider_contract = contract()

    :ok =
      SymphonyElixir.TestSupport.write_workflow_file!(workflow_path,
        tracker_kind: "plane",
        tracker_endpoint: "https://api.plane.so",
        symphony_project_id: "project-1",
        tracker_active_states: ["Planning", "Ready"],
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex} app-server",
        poll_interval_ms: 60_000,
        provider_project_contract: provider_contract_config(provider_contract)
      )

    workflow = File.read!(workflow_path)

    File.write!(
      workflow_path,
      String.replace(
        workflow,
        "tracker:\n",
        "tracker:\n  provider:\n    workspace_slug: workspace-1\n    workspace_id: workspace-1\n    project_id: project-1\n    api_key: $PLANE_API_KEY\n"
      )
    )

    System.put_env("PLANE_API_KEY", "pre-080c-plane-test-key")
    :ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)
    :ok = SymphonyElixir.WorkflowStore.force_reload()

    issue =
      tracked_issue("pre-080c-planner-to-builder", :planning)
      |> Map.put(:dispatchable, true)
      |> fresh_plane_observation()

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    req_stub = {:pre_080c_plane, System.unique_integer([:positive])}
    test_pid = self()
    :ok = Req.Test.set_req_test_to_shared()

    :ok =
      Req.Test.stub(req_stub, fn conn ->
        case conn.request_path do
          "/api/v1/workspaces/workspace-1/projects/project-1/" ->
            Req.Test.json(conn, %{
              "id" => "project-1",
              "name" => "PRE-080C test project",
              "identifier" => "PRE",
              "workspace_id" => "workspace-1",
              "workspace_slug" => "workspace-1"
            })

          "/api/v1/workspaces/workspace-1/projects/project-1/states/" ->
            states =
              Enum.map(WorkflowLifecycle.states(), fn state ->
                %{
                  "id" => "state-#{state}",
                  "name" => WorkflowLifecycle.display(state),
                  "group" => provider_state_group(state) |> Atom.to_string(),
                  "project" => "project-1",
                  "workspace" => "workspace-1"
                }
              end)

            Req.Test.json(conn, %{
              "results" => states,
              "count" => length(states),
              "total_results" => length(states),
              "next_page_results" => false,
              "next_cursor" => nil
            })

          "/api/v1/workspaces/workspace-1/projects/project-1/work-items/" ->
            issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
            results = Enum.map(issues, &raw_plane_work_item/1)

            Req.Test.json(conn, %{
              "results" => results,
              "count" => length(results),
              "total_results" => length(results),
              "next_page_results" => false,
              "next_cursor" => nil
            })

          path when is_binary(path) ->
            case Regex.run(~r{/work-items/([^/]+)/relations/$}, path) do
              [_, _work_item_id] ->
                Req.Test.json(conn, %{"blocked_by" => [], "blocking" => []})

              _not_relation_path ->
                case Regex.run(~r{/work-items/([^/]+)/$}, path) do
                  [_, work_item_id] ->
                    case Enum.find(
                           Application.get_env(:symphony_elixir, :memory_tracker_issues, []),
                           &match?(%Issue{id: ^work_item_id}, &1)
                         ) do
                      %Issue{} = current_issue ->
                        send(test_pid, {:pre_080c_plane_read, current_issue.id, current_issue.state})
                        Req.Test.json(conn, raw_plane_work_item(current_issue))

                      nil ->
                        Plug.Conn.resp(conn, 404, "work item not found")
                    end

                  _unexpected_path ->
                    Plug.Conn.resp(conn, 404, "unexpected Plane request")
                end
            end
        end
      end)

    :ok = Req.default_options(Keyword.put(previous_req_options, :plug, {Req.Test, req_stub}))

    {:ok, planning_work_item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: @now,
        prior_validated_lifecycle_state: :planning,
        provider_project_contract: provider_contract
      })

    assert planning_work_item.validated_lifecycle_state == :planning
    assert planning_work_item.lifecycle_assessment.status == :validated
    refute Enum.any?(planning_work_item.lifecycle_assessment.satisfied_guards, &(&1.name in [:plan_attested, :planning_requirements_verified, :dispatch_guard]))

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: nil,
        start_quiesced: true,
        task_supervisor: task_supervisor,
        agent_runner: SymphonyElixir.Pre080cProductionAgentRunner,
        attempt_ledger_opts: [path: Path.join(root, "attempts.dets")],
        recovery_ledger_opts: [path: Path.join(root, "recovery.dets")],
        workspace_ownership_ledger_opts: [root: Path.join(root, "ownership")]
      )

    on_exit(fn ->
      try do
        if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      catch
        :exit, _reason -> :ok
      end

      try do
        if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
      catch
        :exit, _reason -> :ok
      end
    end)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        orchestrator: orchestrator,
        ledger_opts: [path: Path.join(root, "transitions.dets")],
        submit: fn attempt, context ->
          target_state = WorkflowLifecycle.display(attempt.requested_to)

          updated_issues =
            Enum.map(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), fn
              %Issue{id: work_item_id} = issue when work_item_id == attempt.work_item_id ->
                updated = %{
                  issue
                  | state: target_state,
                    provider_state_id: "state-#{attempt.requested_to}",
                    provider_state_group: provider_state_group(attempt.requested_to),
                    updated_at: DateTime.utc_now(),
                    tracker_read_observation: nil
                }

                {:ok, observation} =
                  ProviderObservation.from_issue(updated, %{provider: :plane, observed_at: DateTime.utc_now()})

                %{updated | tracker_read_observation: sign_provider_observation_for_test(observation)}

              issue ->
                issue
            end)

          Application.put_env(:symphony_elixir, :memory_tracker_issues, updated_issues)

          [%Issue{state: state}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
          send(test_pid, {:pre_080c_provider_mutation, attempt.work_item_id, state})
          send(test_pid, {:pre_080c_submit, attempt, context})

          :ok
        end
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    Application.put_env(:symphony_elixir, :pre_080c_test_pid, self())
    Application.put_env(:symphony_elixir, :pre_080c_test_coordinator, coordinator)

    initial_checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: "project-1",
      work_item_id: issue.id,
      last_validated_lifecycle_state: planning_work_item.validated_lifecycle_state,
      durable_guard_evidence: [],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }

    recovery_ledger = :sys.get_state(orchestrator).recovery_ledger
    assert :ok = RecoveryLedger.put_sync(recovery_ledger, initial_checkpoint)

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | transition_coordinator: coordinator,
          work_control: Map.put(state.work_control, issue.id, planning_work_item),
          recovery_checkpoints: Map.put(state.recovery_checkpoints, issue.id, initial_checkpoint)
      }
    end)

    planner_dispatch = await_planner_dispatch(orchestrator, issue.id)
    assert {:ok, planner_running} = planner_dispatch
    assert_receive {:pre_080c_runtime_waiting, planner_pid, issue_id, planner_host_context}, 5_000
    assert issue_id == issue.id
    planner_identity = planner_host_context.runtime_attempt_identity
    planner_route = planner_host_context.route

    assert %RuntimeAttemptIdentity{} = planner_identity
    assert planner_route.issue_id == issue.id
    assert planner_route.starting_state == "planning"
    assert planner_route.responsibility == "planning"
    assert planner_identity.runtime_profile == planner_route.profile_name

    assert {:ok, semantic_context} = Orchestrator.semantic_tool_context(orchestrator, issue.id)
    assert semantic_context.dependency_decision.allowed?
    assert semantic_context.dependency_epoch_evidence.complete?
    assert semantic_context.work_item.validated_lifecycle_state == :planning
    assert %WorkItem{validated_lifecycle_state: :planning} = semantic_context.work_item
    assert :sys.get_state(orchestrator).dependency_diagnostics[issue.id].allowed?
    initial_orchestrator_state = :sys.get_state(orchestrator)
    assert initial_orchestrator_state.project_contract_evidence.validation.status == :valid
    assert initial_orchestrator_state.dependency_diagnostics[issue.id].allowed?

    assert %RuntimeAttempt{state: :running} = planner_running.runtime_attempt

    state = :sys.get_state(orchestrator)
    ledger = state.attempt_ledger
    assert %AttemptLedger{} = ledger
    assert {:ok, record} = AttemptLedger.current(ledger, issue.id)
    assert record.status == :open
    assert record.in_flight
    assert record.authority_fence.state == :bound
    assert RuntimeAttemptIdentity.same?(record.authority_fence.runtime_attempt, planner_identity)

    send(planner_pid, :pre_080c_continue_to_tool)

    assert_receive {:pre_080c_tool_response, planner_response}, 5_000
    assert_receive {:pre_080c_provider_mutation, ^issue_id, "Ready"}, 5_000
    assert_receive {:pre_080c_submit, planner_attempt, planner_submit_context}, 5_000
    planner_guards = Map.get(planner_submit_context, :guard_evidence, [])
    assert planner_attempt.requested_from == :planning
    assert planner_attempt.requested_to == :ready
    assert planner_attempt.runtime_attempt_id == planner_identity.runtime_attempt_id
    assert Enum.any?(planner_attempt.guard_evidence, &(&1.name == :plan_attested))
    assert Enum.any?(planner_guards, &(&1.name == :planning_requirements_verified))
    refute Enum.any?(planner_attempt.guard_evidence ++ planner_guards, &(&1.name == :dispatch_guard))

    assert planner_response["success"]
    assert Jason.decode!(planner_response["output"])["status"] == "verified"
    assert [%Issue{state: "Ready"}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    assert_receive {:pre_080c_plane_read, ^issue_id, "Ready"}, 5_000

    state = :sys.get_state(orchestrator)
    assert %WorkItem{validated_lifecycle_state: :ready} = ready_work_item = state.work_control[issue.id]
    assert WorkItem.dispatchable?(ready_work_item)
    assert Enum.any?(ready_work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :plan_attested))
    assert Enum.any?(ready_work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :planning_requirements_verified))
    refute Enum.any?(ready_work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :dispatch_guard))

    send(planner_pid, :pre_080c_finish_runtime)
    planner_finished_state = await_runtime_release(orchestrator, issue.id, planner_pid)

    assert %{termination_reason: nil, route_change: %{next: %{responsibility: "implementation"}}} =
             planner_finished_state.retry_attempts[issue.id]

    builder_dispatch = await_builder_dispatch(orchestrator, issue.id)
    assert {:ok, builder_running} = builder_dispatch
    assert_receive {:pre_080c_runtime_waiting, builder_pid, ^issue_id, builder_host_context}, 5_000
    builder_identity = builder_host_context.runtime_attempt_identity
    builder_route = builder_host_context.route
    refute builder_identity.runtime_attempt_id == planner_identity.runtime_attempt_id
    assert builder_route.starting_state == "ready"
    assert builder_route.responsibility == "implementation"
    assert %RuntimeAttempt{state: :running, identity: ^builder_identity} = builder_running.runtime_attempt

    builder_state = :sys.get_state(orchestrator)
    assert %AttemptLedger{} = builder_ledger = builder_state.attempt_ledger
    assert {:ok, builder_record} = AttemptLedger.current(builder_ledger, issue.id)
    assert builder_record.status == :open
    assert builder_record.in_flight
    assert builder_record.authority_fence.state == :bound
    assert RuntimeAttemptIdentity.same?(builder_record.authority_fence.runtime_attempt, builder_identity)
    assert builder_record.route_fingerprint == builder_record.authority_fence.route_fingerprint
    assert builder_record.authority_fence.route_fingerprint == builder_route.fingerprint

    assert {:ok, first_builder_context} =
             Orchestrator.transition_context(orchestrator, issue.id, expected_runtime_identity: expected_dispatch_identity(builder_identity))

    assert first_builder_context.dispatch_authority_evidence.runtime_attempt_id == builder_identity.runtime_attempt_id
    assert first_builder_context.dispatch_authority_evidence.lineage_generation == builder_identity.lineage_generation
    assert first_builder_context.dispatch_authority_evidence.route_fingerprint == builder_route.fingerprint

    send(builder_pid, :pre_080c_continue_to_tool)

    assert_receive {:pre_080c_submit, builder_attempt, _builder_submit_context}, 5_000
    assert builder_attempt.requested_from == :ready
    assert builder_attempt.requested_to == :in_progress
    assert builder_attempt.runtime_attempt_id == builder_identity.runtime_attempt_id
    assert builder_attempt.lineage_generation == builder_identity.lineage_generation
    assert Enum.count(builder_attempt.guard_evidence, &(&1.name == :dispatch_guard)) == 1

    assert_receive {:pre_080c_tool_response, %{"success" => true} = builder_response}, 5_000
    assert builder_response["success"]
    assert Jason.decode!(builder_response["output"])["status"] == "verified"
    assert [%Issue{state: "In Progress"}] = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    assert_receive {:pre_080c_plane_read, ^issue_id, "In Progress"}, 5_000

    state = :sys.get_state(orchestrator)
    assert %WorkItem{validated_lifecycle_state: :in_progress} = state.work_control[issue.id]
    assert %RecoveryLedger{} = recovery_ledger = state.recovery_ledger
    assert {:ok, checkpoint} = RecoveryLedger.current(recovery_ledger, issue.id)
    refute Enum.any?(checkpoint.durable_guard_evidence, &(&1.name == :dispatch_guard))

    send(builder_pid, :pre_080c_finish_runtime)
  end

  test "recovery startup strips legacy dispatch guards before restoring durable evidence" do
    root = Path.join(System.tmp_dir!(), "pre-080c-recovery-#{System.unique_integer([:positive])}")
    workflow_path = Path.join(root, "WORKFLOW.md")
    recovery_path = Path.join(root, "recovery.dets")
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    File.mkdir_p!(root)

    on_exit(fn ->
      restore_application_env(:workflow_file_path, previous_workflow_path)
      File.rm_rf(root)
    end)

    :ok = SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    :ok =
      SymphonyElixir.TestSupport.write_workflow_file!(workflow_path,
        tracker_kind: "memory",
        symphony_project_id: "pre-080c-recovery",
        agent_routing: "routed"
      )

    settings = SymphonyElixir.Config.settings!()
    tracker_identity = SymphonyElixir.Tracker.identity(settings.tracker)
    work_item_id = "pre-080c-recovered-dispatch-guard"

    {:ok, legacy_ledger} =
      RecoveryLedger.open(settings.symphony.project_id, tracker_identity, path: recovery_path)

    legacy_checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: settings.symphony.project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :ready,
      durable_guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard, outcome: :verified}],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }

    assert :ok = RecoveryLedger.put_sync(legacy_ledger, legacy_checkpoint)
    assert :ok = RecoveryLedger.close(legacy_ledger)

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: nil,
        start_quiesced: true,
        task_supervisor: task_supervisor,
        attempt_ledger_opts: [path: Path.join(root, "attempts.dets")],
        recovery_ledger_opts: [path: recovery_path],
        workspace_ownership_ledger_opts: [root: Path.join(root, "ownership")]
      )

    on_exit(fn ->
      try do
        if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      catch
        :exit, _reason -> :ok
      end

      try do
        if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
      catch
        :exit, _reason -> :ok
      end
    end)

    state = :sys.get_state(orchestrator)
    assert state.recovery_ledger_status == :ready
    assert %{durable_guard_evidence: []} = state.recovery_checkpoints[work_item_id]
    assert {:ok, %{durable_guard_evidence: []}} = RecoveryLedger.current(state.recovery_ledger, work_item_id)
  end

  test "Orchestrator exposes dispatch authority only for the exact bound running attempt and route" do
    issue = tracked_issue("pre-080c-bound-dispatch-proof", :ready)
    route = route(issue.id, :ready, "implementation")
    work_item = work_item_for_issue(issue)
    {orchestrator, ledger, identity} = start_dispatch_context_orchestrator(issue, route, work_item)

    assert {:ok, record} = AttemptLedger.current(ledger, issue.id)
    assert record.status == :open
    assert record.in_flight
    assert record.authority_fence.state == :bound
    assert RuntimeAttemptIdentity.same?(record.authority_fence.runtime_attempt, identity)

    assert {:ok, context} =
             Orchestrator.transition_context(orchestrator, issue.id, expected_runtime_identity: expected_dispatch_identity(identity))

    assert Map.get(context, :route) == route

    assert %{verified_at: %DateTime{}} = evidence = Map.get(context, :dispatch_authority_evidence)

    assert evidence == %{
             class: :mechanical_guard,
             name: :dispatch_guard,
             outcome: :verified,
             subject: {:work_item, issue.id},
             transition: {:ready, :in_progress},
             responsibility: "implementation",
             runtime_attempt_id: identity.runtime_attempt_id,
             lineage_generation: identity.lineage_generation,
             runtime_profile: identity.runtime_profile,
             route_fingerprint: route.fingerprint,
             verified_at: evidence.verified_at
           }
  end

  test "Orchestrator withholds dispatch authority for an armed unbound fence" do
    issue = tracked_issue("pre-080c-armed-dispatch-proof", :ready)
    route = route(issue.id, :ready, "implementation")
    work_item = work_item_for_issue(issue)

    {orchestrator, ledger, identity} =
      start_dispatch_context_orchestrator(issue, route, work_item, bind?: false)

    assert {:ok, %{authority_fence: %{state: :armed}}} = AttemptLedger.current(ledger, issue.id)

    assert {:ok, context} =
             Orchestrator.transition_context(orchestrator, issue.id, expected_runtime_identity: expected_dispatch_identity(identity))

    assert is_nil(Map.get(context, :dispatch_authority_evidence))
  end

  test "Orchestrator withholds fresh dispatch authority for every stale or mismatched boundary" do
    variants = [
      :released_fence,
      :suspension_pending_fence,
      :wrong_work_item,
      :wrong_runtime_attempt,
      :stale_replaced_runtime_attempt,
      :wrong_lineage,
      :wrong_responsibility,
      :record_fence_route_mismatch,
      :running_route_mismatch,
      :route_not_ready,
      :runtime_profile_mismatch,
      :dependency_blocked,
      :dependency_incomplete,
      :source_no_longer_ready,
      :attempt_ledger_unavailable,
      :runtime_not_running
    ]

    for variant <- variants do
      issue = tracked_issue("pre-080c-negative-#{variant}", :ready)
      route = route(issue.id, :ready, "implementation")
      work_item = work_item_for_issue(issue)
      {orchestrator, ledger, identity} = start_dispatch_context_orchestrator(issue, route, work_item)

      expected_identity = expected_dispatch_identity(identity)

      expected_identity =
        case variant do
          :wrong_work_item -> Map.put(expected_identity, :work_item_id, "foreign-work-item")
          :wrong_runtime_attempt -> Map.put(expected_identity, :runtime_attempt_id, "stale-runtime-attempt")
          :wrong_lineage -> Map.put(expected_identity, :lineage_generation, "stale-lineage")
          :wrong_responsibility -> Map.put(expected_identity, :responsibility, "review")
          _ -> expected_identity
        end

      case variant do
        :released_fence ->
          assert :ok = AttemptLedger.release_authority_fence(ledger, issue.id, identity)

        :suspension_pending_fence ->
          suspension_intent = %{
            reason: :provider_blocked,
            provider_observation: work_item.provider_observation,
            required_evidence: [],
            created_at: DateTime.utc_now()
          }

          assert {:ok, %{authority_fence: %{state: :suspension_pending}}} =
                   AttemptLedger.mark_suspension_pending(ledger, issue.id, identity, suspension_intent)

        :stale_replaced_runtime_attempt ->
          assert :ok = AttemptLedger.release_authority_fence(ledger, issue.id, identity)
          assert :ok = AttemptLedger.clear_in_flight(ledger, issue.id)

          assert {:ok, replacement_record} =
                   AttemptLedger.begin_attempt(ledger, issue.id, route_fingerprint: route.fingerprint)

          replacement = RuntimeAttemptIdentity.allocate(issue.id, route, replacement_record.lineage_id)
          assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(ledger, issue.id, replacement)

          :sys.replace_state(orchestrator, fn state ->
            running_entry = Map.fetch!(state.running, issue.id)

            Map.update!(state, :running, fn running ->
              Map.put(running, issue.id, %{running_entry | runtime_attempt: RuntimeAttempt.new(replacement, :running)})
            end)
          end)

        :record_fence_route_mismatch ->
          assert {:ok, record} = AttemptLedger.current(ledger, issue.id)

          assert {:ok, _mismatched} =
                   AttemptLedger.persist_safety(ledger, issue.id, record.safety_counters,
                     status: :open,
                     in_flight: true,
                     route_fingerprint: "sha256:record-route-mismatch"
                   )

        :running_route_mismatch ->
          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :running, fn running ->
              Map.update!(running, issue.id, &Map.put(&1, :route_fingerprint, "sha256:running-route-mismatch"))
            end)
          end)

        :route_not_ready ->
          changed_route = route(issue.id, :planning, "implementation")

          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :running, fn running ->
              Map.update!(running, issue.id, fn entry ->
                %{entry | route: changed_route, route_fingerprint: changed_route.fingerprint}
              end)
            end)
          end)

        :runtime_profile_mismatch ->
          changed_route = route(issue.id, :ready, "review")

          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :running, fn running ->
              Map.update!(running, issue.id, fn entry ->
                %{entry | route: changed_route, route_fingerprint: changed_route.fingerprint}
              end)
            end)
          end)

        :dependency_blocked ->
          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :dependency_diagnostics, fn diagnostics ->
              Map.update!(diagnostics, issue.id, &Map.put(&1, :allowed?, false))
            end)
          end)

        :dependency_incomplete ->
          :sys.replace_state(orchestrator, fn state ->
            %{state | dependency_graph: %{state.dependency_graph | completeness: {:incomplete, :test}}}
          end)

        :source_no_longer_ready ->
          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :work_control, fn work_control ->
              Map.update!(work_control, issue.id, &%{&1 | validated_lifecycle_state: :in_progress})
            end)
          end)

        :attempt_ledger_unavailable ->
          :sys.replace_state(orchestrator, fn state ->
            %{state | attempt_ledger_status: :disabled, attempt_ledger: nil}
          end)

        :runtime_not_running ->
          :sys.replace_state(orchestrator, fn state ->
            Map.update!(state, :running, fn running ->
              Map.update!(running, issue.id, fn entry ->
                %{entry | runtime_attempt: RuntimeAttempt.new(identity, :starting)}
              end)
            end)
          end)

        _unchanged ->
          :ok
      end

      result =
        Orchestrator.transition_context(orchestrator, issue.id, expected_runtime_identity: expected_identity)

      case {variant, result} do
        {identity_mismatch, {:error, :stale_runtime_attempt}}
        when identity_mismatch in [
               :wrong_work_item,
               :wrong_runtime_attempt,
               :stale_replaced_runtime_attempt,
               :wrong_lineage,
               :wrong_responsibility
             ] ->
          :ok

        {:dependency_incomplete, {:error, :dependency_context_unavailable}} ->
          :ok

        {_variant, {:ok, context}} ->
          assert is_nil(Map.get(context, :dispatch_authority_evidence)),
                 "variant=#{variant} unexpectedly produced proof"

        {_variant, other} ->
          flunk("variant=#{variant} returned unexpected transition context result: #{inspect(other)}")
      end
    end
  end

  test "final pre-submit dispatch recheck rejects an authority released after the first load" do
    assert_final_dispatch_recheck_rejects(:released)
  end

  test "final pre-submit dispatch recheck rejects suspension pending after the first load" do
    assert_final_dispatch_recheck_rejects(:suspension_pending)
  end

  test "final pre-submit dispatch recheck rejects a replacement RuntimeAttempt after the first load" do
    assert_final_dispatch_recheck_rejects(:replacement)
  end

  test "final pre-submit dispatch recheck submits once when the bound RuntimeAttempt remains current" do
    work_item_id = "pre-080c-final-recheck-success"
    issue = tracked_issue(work_item_id, :ready)
    route = route(issue.id, :ready, "implementation")
    work_item = work_item_for_issue(issue)
    {orchestrator, ledger, identity} = start_dispatch_context_orchestrator(issue, route, work_item)
    {:ok, loads} = Agent.start_link(fn -> 0 end)
    {:ok, submissions} = Agent.start_link(fn -> 0 end)
    {:ok, transition_ledger_ref} = Agent.start_link(fn -> nil end)
    test_pid = self()

    before_final = fn ->
      %TransitionAttemptLedger{} = transition_ledger = Agent.get(transition_ledger_ref, & &1)
      assert {:ok, prepared} = TransitionAttemptLedger.latest_for_work_item(transition_ledger, work_item_id)
      send(test_pid, {:final_recheck_persisted_fence, prepared.state, prepared.submission_fenced_at})
    end

    {:ok, coordinator} =
      start_final_recheck_coordinator(orchestrator, identity, loads,
        before_final: before_final,
        submit: fn attempt, context ->
          Agent.update(submissions, &(&1 + 1))
          send(test_pid, {:final_recheck_submitted, attempt, context})
          {:ok, %{status: 204}}
        end,
        verify: fn attempt, context ->
          send(test_pid, {:final_recheck_verified, attempt, context})
          {:verified, verified_payload(attempt, context.provider_project_contract)}
        end
      )

    Agent.update(transition_ledger_ref, fn _ -> :sys.get_state(coordinator).ledger end)

    intent = dispatch_transition_intent(work_item_id, identity)

    request = Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent, route: route) end)
    assert {:ok, first_load, {:ok, first_context}, first_loader} = receive_final_recheck_load()
    assert first_load == 1
    assert first_context.dispatch_authority_evidence.runtime_attempt_id == identity.runtime_attempt_id
    send(first_loader, :continue_final_recheck)

    assert {:ok, attempt} = Task.await(request, 5_000)
    assert attempt.state == :verified
    assert Agent.get(loads, & &1) == 2
    assert Agent.get(submissions, & &1) == 1

    assert_received {:final_recheck_load, 2, {:ok, second_context}}
    assert_received {:final_recheck_persisted_fence, :prepared, %DateTime{}}
    assert first_context.dispatch_authority_evidence.runtime_attempt_id == identity.runtime_attempt_id
    assert second_context.dispatch_authority_evidence.runtime_attempt_id == identity.runtime_attempt_id

    assert_received {:final_recheck_submitted, submitted_attempt, submitted_context}
    assert submitted_attempt.submission_fenced_at
    assert submitted_context.dispatch_authority_evidence.runtime_attempt_id == identity.runtime_attempt_id
    assert submitted_context.dispatch_authority_evidence.lineage_generation == identity.lineage_generation
    assert submitted_context.dispatch_authority_evidence.route_fingerprint == route.fingerprint
    assert_received {:final_recheck_verified, verified_attempt, verified_context}
    assert verified_attempt.attempt_id == submitted_attempt.attempt_id
    assert verified_context.dispatch_authority_evidence == submitted_context.dispatch_authority_evidence

    assert {:ok, record} = AttemptLedger.current(ledger, issue.id)
    assert record.authority_fence.state == :bound
    GenServer.stop(coordinator)
    Agent.stop(loads)
    Agent.stop(submissions)
    Agent.stop(transition_ledger_ref)
  end

  test "rejects forged current-transition semantic attestation in trusted host context" do
    work_item_id = "pre-080c-forged"
    route = route(work_item_id, :in_progress, "implementation")
    identity = RuntimeAttemptIdentity.allocate(work_item_id, route, "lineage-pre-080c-forged")
    coordinator = production_coordinator(work_item_id, :in_progress, capture?: true)

    {:ok, forged} =
      GuardClass.semantic_attestation(:implementation_attested, %{
        responsibility: "implementation",
        runtime_attempt_id: :forged,
        lineage_generation: 0,
        subject: {:work_item, work_item_id},
        timestamp: DateTime.utc_now()
      })

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        agent_tool_opts(work_item_id, route, coordinator, identity: identity, source: :in_progress)
        |> Keyword.update!(:agent_tool_context, fn ctx -> Map.put(ctx, :guard_evidence, [forged]) end)
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "required_guard_missing"
    GenServer.stop(coordinator)
  end

  test "source control candidate capture acquires role-specific required-check guards in isolation" do
    intent = capture_intent(:in_progress, :in_review)

    assert {:ok, evidence} = SourceControl.enrich_guard_evidence(intent, capture_context(), [])

    assert Enum.any?(evidence, &match?(%{name: :candidate_state_verified, outcome: :verified}, &1))
    assert Enum.any?(evidence, &match?(%{name: :implementation_checks_verified, class: :mechanical_guard}, &1))
  end

  defp transition_response(work_item_id, route, coordinator, target_state, opts) do
    AgentTool.execute(
      "plane_request_lifecycle_transition",
      %{"targetState" => target_state},
      agent_tool_opts(work_item_id, route, coordinator, opts)
    )
  end

  defp assert_rejects_runtime(response) do
    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "stale_runtime_attempt"
  end

  defp production_coordinator(work_item_id, lifecycle_state, opts) do
    capture? = Keyword.get(opts, :capture?, true)
    test_pid = self()
    contract = contract()
    tracked_issue(work_item_id, lifecycle_state)

    issue = tracked_issue(work_item_id, lifecycle_state)
    work_item = Keyword.get(opts, :work_item) || work_item_for_issue(issue)

    transition_context =
      base_transition_context(contract, capture?)
      |> Map.put(:work_item, work_item)
      |> maybe_put_prior_candidate_guards(work_item)

    {:ok, orchestrator} =
      ProductionPathOrchestrator.start_link(transition_context: {:ok, transition_context})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        orchestrator: orchestrator,
        ledger: nil,
        require_durable?: false,
        refresh_contract: fn _context -> {:ok, contract} end,
        submit: fn attempt, context ->
          send(test_pid, {:transition_submitted, attempt, Map.get(context, :guard_evidence, [])})
          update_memory_issue(work_item_id, attempt.requested_to)
          {:ok, %{status: 204}}
        end,
        verify: fn attempt, _context ->
          {:verified, verified_payload(attempt, contract)}
        end,
        apply_verified: fn _attempt, _context -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    coordinator
  end

  defp start_dispatch_context_orchestrator(issue, route, work_item, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "pre-080c-orchestrator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: nil,
        start_quiesced: true,
        task_supervisor: task_supervisor,
        attempt_ledger_opts: [path: Path.join(root, "attempts.dets")],
        recovery_ledger_opts: [path: Path.join(root, "recovery.dets")],
        workspace_ownership_ledger_opts: [root: Path.join(root, "ownership")]
      )

    on_exit(fn ->
      try do
        if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      catch
        :exit, _reason -> :ok
      end

      try do
        if Process.alive?(task_supervisor), do: Supervisor.stop(task_supervisor)
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf(root)
    end)

    ledger = :sys.get_state(orchestrator).attempt_ledger
    assert %AttemptLedger{} = ledger

    assert {:ok, record} =
             AttemptLedger.begin_attempt(ledger, issue.id, route_fingerprint: route.fingerprint)

    identity = RuntimeAttemptIdentity.allocate(issue.id, route, record.lineage_id)

    if Keyword.get(opts, :bind?, true) do
      assert {:ok, _record} = AttemptLedger.bind_runtime_attempt(ledger, issue.id, identity)
    end

    running_entry = %{
      issue: issue,
      route: route,
      route_fingerprint: route.fingerprint,
      profile_name: route.profile_name,
      runtime_name: route.runtime_name,
      responsibility: route.responsibility,
      containment_status: :active,
      lifecycle_suspension: nil,
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | startup_reconciliation: :ready,
          work_control: Map.put(state.work_control, issue.id, work_item),
          dependency_graph: Graph.build([issue]),
          dependency_diagnostics:
            Map.put(state.dependency_diagnostics, issue.id, %{
              allowed?: true,
              dependency_completeness: :complete,
              dependency_status: :none
            }),
          running: Map.put(state.running, issue.id, running_entry)
      }
    end)

    {orchestrator, ledger, identity}
  end

  defp assert_final_dispatch_recheck_rejects(variant) do
    work_item_id = "pre-080c-final-recheck-#{variant}"
    issue = tracked_issue(work_item_id, :ready)
    route = route(issue.id, :ready, "implementation")
    work_item = work_item_for_issue(issue)
    {orchestrator, ledger, identity} = start_dispatch_context_orchestrator(issue, route, work_item)
    {:ok, loads} = Agent.start_link(fn -> 0 end)
    {:ok, submissions} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    {:ok, coordinator} =
      start_final_recheck_coordinator(orchestrator, identity, loads,
        submit: fn attempt, _context ->
          Agent.update(submissions, &(&1 + 1))
          send(test_pid, {:final_recheck_unexpected_submit, attempt})
          {:ok, %{status: 204}}
        end,
        verify: fn attempt, context -> {:verified, verified_payload(attempt, context.provider_project_contract)} end
      )

    intent = dispatch_transition_intent(work_item_id, identity)

    request = Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent, route: route) end)
    assert {:ok, first_load, {:ok, first_context}, first_loader} = receive_final_recheck_load()
    assert first_load == 1
    assert first_context.dispatch_authority_evidence.runtime_attempt_id == identity.runtime_attempt_id
    mutate_final_dispatch_authority(variant, orchestrator, ledger, issue, work_item, route, identity)
    send(first_loader, :continue_final_recheck)

    result = Task.await(request, 5_000)

    assert {:ok, attempt} = result
    assert attempt.state == :rejected

    if variant == :replacement do
      assert attempt.outcome_reason == {:context_unavailable, :stale_runtime_attempt}
    end

    assert attempt.submission_fenced_at
    assert is_nil(attempt.submitted_at)
    assert Agent.get(loads, & &1) == 2
    assert Agent.get(submissions, & &1) == 0
    refute_received {:final_recheck_unexpected_submit, _attempt}

    coordinator_state = :sys.get_state(coordinator)
    assert {:ok, persisted} = TransitionAttemptLedger.latest_for_work_item(coordinator_state.ledger, work_item_id)
    assert persisted.state == attempt.state
    assert persisted.submission_fenced_at
    assert is_nil(persisted.submitted_at)

    assert_received {:final_recheck_load, 2, _second_result}
    GenServer.stop(coordinator)
    Agent.stop(loads)
    Agent.stop(submissions)
  end

  defp receive_final_recheck_load do
    receive do
      {:final_recheck_load, 1, {:ok, context}, loader_pid} -> {:ok, 1, {:ok, context}, loader_pid}
    after
      5_000 -> flunk("timed out waiting for the first Orchestrator context acquisition")
    end
  end

  defp mutate_final_dispatch_authority(:released, _orchestrator, ledger, issue, _work_item, _route, identity) do
    assert :ok = AttemptLedger.release_authority_fence(ledger, issue.id, identity)
  end

  defp mutate_final_dispatch_authority(
         :suspension_pending,
         _orchestrator,
         ledger,
         issue,
         work_item,
         _route,
         identity
       ) do
    assert {:ok, %{authority_fence: %{state: :suspension_pending}}} =
             AttemptLedger.mark_suspension_pending(ledger, issue.id, identity, %{
               reason: :provider_blocked,
               provider_observation: work_item.provider_observation,
               required_evidence: [],
               created_at: DateTime.utc_now()
             })
  end

  defp mutate_final_dispatch_authority(:replacement, orchestrator, ledger, issue, _work_item, route, identity) do
    assert :ok = AttemptLedger.release_authority_fence(ledger, issue.id, identity)
    assert :ok = AttemptLedger.clear_in_flight(ledger, issue.id)

    assert {:ok, replacement_record} =
             AttemptLedger.begin_attempt(ledger, issue.id, route_fingerprint: route.fingerprint)

    replacement = RuntimeAttemptIdentity.allocate(issue.id, route, replacement_record.lineage_id)
    assert {:ok, _bound} = AttemptLedger.bind_runtime_attempt(ledger, issue.id, replacement)

    :sys.replace_state(orchestrator, fn state ->
      running_entry = Map.fetch!(state.running, issue.id)
      replacement_entry = %{running_entry | runtime_attempt: RuntimeAttempt.new(replacement, :running)}
      %{state | running: Map.put(state.running, issue.id, replacement_entry)}
    end)
  end

  defp start_final_recheck_coordinator(orchestrator, identity, loads, opts) do
    root = Path.join(System.tmp_dir!(), "pre-080c-final-recheck-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    test_pid = self()
    before_final = Keyword.get(opts, :before_final, fn -> :ok end)
    expected_identity = expected_dispatch_identity(identity)

    on_exit(fn -> File.rm_rf(root) end)

    load_context = fn intent ->
      load_number = Agent.get_and_update(loads, fn count -> {count, count + 1} end)
      if load_number == 1, do: before_final.()

      result =
        Orchestrator.transition_context(orchestrator, intent.work_item_id, expected_runtime_identity: expected_identity)
        |> then(fn
          {:ok, context} ->
            provider_contract = contract()

            {:ok,
             Map.merge(context, %{
               provider_project_contract: provider_contract,
               provider_contract_fingerprint: ProviderProjectContract.fingerprint(provider_contract)
             })}

          other ->
            other
        end)

      if load_number == 0 do
        send(test_pid, {:final_recheck_load, 1, result, self()})

        receive do
          :continue_final_recheck -> :ok
        after
          5_000 -> raise "timed out waiting for final recheck authority mutation"
        end
      else
        send(test_pid, {:final_recheck_load, load_number + 1, result})
      end

      result
    end

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        orchestrator: orchestrator,
        project_id: "project-1",
        tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-1"}},
        ledger_opts: [path: Path.join(root, "transition-attempts.dets")],
        load_context: load_context,
        refresh_contract: fn context -> {:ok, context.provider_project_contract} end,
        submit: Keyword.fetch!(opts, :submit),
        verify: Keyword.fetch!(opts, :verify),
        apply_verified: fn _attempt, _context -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    {:ok, coordinator}
  end

  defp dispatch_transition_intent(work_item_id, identity) do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: work_item_id,
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        runtime_attempt_id: identity.runtime_attempt_id,
        lineage_generation: identity.lineage_generation,
        guard_evidence: []
      })

    intent
  end

  defp await_builder_dispatch(orchestrator, work_item_id, attempts \\ 200) do
    send(orchestrator, :run_poll_cycle)
    await_builder_dispatch_state(orchestrator, work_item_id, attempts)
  end

  defp await_runtime_release(orchestrator, work_item_id, runtime_pid, attempts \\ 200)

  defp await_runtime_release(_orchestrator, _work_item_id, _runtime_pid, 0),
    do: flunk("runtime did not finish and release its current attempt")

  defp await_runtime_release(orchestrator, work_item_id, runtime_pid, attempts) do
    state = :sys.get_state(orchestrator)

    if not Process.alive?(runtime_pid) and not Map.has_key?(state.running, work_item_id) do
      state
    else
      Process.sleep(20)
      await_runtime_release(orchestrator, work_item_id, runtime_pid, attempts - 1)
    end
  end

  defp await_builder_dispatch_state(orchestrator, work_item_id, attempts) when attempts > 0 do
    state = :sys.get_state(orchestrator)

    case Map.get(state.running, work_item_id) do
      %{
        route: %Route{starting_state: "ready"},
        runtime_attempt: %RuntimeAttempt{state: :running}
      } = running_entry ->
        {:ok, running_entry}

      nil ->
        Process.sleep(20)
        await_builder_dispatch_state(orchestrator, work_item_id, attempts - 1)

      _planner_or_other_route ->
        Process.sleep(20)
        await_builder_dispatch_state(orchestrator, work_item_id, attempts - 1)
    end
  end

  defp await_builder_dispatch_state(_orchestrator, _work_item_id, 0), do: {:error, :builder_not_dispatched}

  defp await_planner_dispatch(orchestrator, work_item_id, attempts \\ 200) do
    send(orchestrator, :run_poll_cycle)
    await_planner_dispatch_state(orchestrator, work_item_id, attempts)
  end

  defp await_planner_dispatch_state(orchestrator, work_item_id, attempts) when attempts > 0 do
    state = :sys.get_state(orchestrator)

    case Map.get(state.running, work_item_id) do
      %{
        route: %Route{starting_state: "planning"},
        runtime_attempt: %RuntimeAttempt{state: :running}
      } = running_entry ->
        {:ok, running_entry}

      nil ->
        Process.sleep(20)
        await_planner_dispatch_state(orchestrator, work_item_id, attempts - 1)

      _starting_or_other_route ->
        Process.sleep(20)
        await_planner_dispatch_state(orchestrator, work_item_id, attempts - 1)
    end
  end

  defp await_planner_dispatch_state(_orchestrator, _work_item_id, 0), do: {:error, :planner_not_dispatched}

  defp expected_dispatch_identity(identity) do
    %{
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_generation: identity.lineage_generation,
      work_item_id: identity.work_item_id,
      responsibility: identity.responsibility
    }
  end

  defp agent_tool_opts(work_item_id, route, coordinator, opts) do
    source = Keyword.get(opts, :source, :in_progress)
    identity = Keyword.get(opts, :identity)
    host_identity = Keyword.get(opts, :host_identity, identity)
    semantic_identity = Keyword.get(opts, :semantic_identity, identity)
    item = Keyword.get(opts, :work_item) || work_item_for_issue(tracked_issue(work_item_id, source))

    semantic_context =
      %{
        work_item: item,
        provider_project_contract: contract(),
        provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract()),
        dependency_decision: %{
          allowed?: true,
          dependency_status: :none,
          dependency_completeness: :complete,
          merge_permitted?: true,
          reason: :no_hard_dependencies,
          blockers: []
        },
        dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
      }
      |> maybe_put_identity(semantic_identity)

    agent_tool_context =
      %{route: route}
      |> maybe_put_identity(host_identity)
      |> maybe_put_runner_host_context(item, opts)

    [
      agent_tool_context: agent_tool_context,
      tracker_settings: @settings,
      coordinator: coordinator,
      semantic_tool_context: fn _issue_id -> {:ok, semantic_context} end
    ]
  end

  defp maybe_put_identity(map, %RuntimeAttemptIdentity{} = identity),
    do: Map.put(map, :runtime_attempt_identity, identity)

  defp maybe_put_identity(map, nil), do: map

  defp maybe_put_runner_host_context(context, %WorkItem{} = work_item, opts) do
    if Keyword.get(opts, :runner_host_context?, false) do
      Map.merge(context, %{
        work_item: work_item,
        guard_evidence: SourceControl.canonical_host_guard_evidence(%{work_item: work_item, guard_evidence: []})
      })
    else
      context
    end
  end

  defp projected_handoff_guards(attempt, enriched_evidence) do
    (attempt.guard_evidence ++ enriched_evidence)
    |> Enum.uniq_by(fn guard -> {guard.class, guard.name} end)
  end

  defp base_transition_context(contract, capture?) do
    base = %{
      provider_project_contract: contract,
      dependency_decision: %{
        allowed?: true,
        dependency_completeness: :complete,
        dependency_status: :none,
        merge_permitted?: true
      },
      dependency_epoch_evidence: %{complete?: true}
    }

    if capture?, do: Map.merge(base, capture_context()), else: base
  end

  defp update_memory_issue(work_item_id, target_state, opts \\ []) do
    display = WorkflowLifecycle.display(target_state)
    sign_observation? = Keyword.get(opts, :sign_observation?, true)

    case Application.get_env(:symphony_elixir, :memory_tracker_issues, []) do
      [%Issue{id: ^work_item_id} = issue | _] ->
        updated =
          %{
            issue
            | state: display,
              provider_state_id: "state-#{target_state}",
              provider_state_group: provider_state_group(target_state)
          }

        projected =
          if sign_observation? do
            {:ok, observation} =
              ProviderObservation.from_issue(updated, %{provider: :plane, observed_at: DateTime.utc_now()})

            %{updated | tracker_read_observation: sign_provider_observation_for_test(observation)}
          else
            %{updated | tracker_read_observation: nil}
          end

        Application.put_env(:symphony_elixir, :memory_tracker_issues, [projected])

      _ ->
        :ok
    end
  end

  defp fresh_plane_observation(%Issue{} = issue) do
    {:ok, observation} =
      ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: DateTime.utc_now()})

    %{issue | tracker_read_observation: sign_provider_observation_for_test(observation)}
  end

  defp raw_plane_work_item(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "name" => issue.title,
      "state" => %{
        "id" => issue.provider_state_id,
        "name" => issue.state,
        "group" => Atom.to_string(issue.provider_state_group)
      },
      "project" => "project-1",
      "workspace" => "workspace-1",
      "updated_at" => DateTime.to_iso8601(issue.updated_at)
    }
  end

  defp tracked_issue(work_item_id, lifecycle_state) do
    issue =
      %Issue{
        id: work_item_id,
        identifier: String.upcase(work_item_id),
        title: "PRE-080C #{work_item_id}",
        state: WorkflowLifecycle.display(lifecycle_state),
        workspace_id: "workspace-1",
        project_id: "project-1",
        provider_state_id: "state-#{lifecycle_state}",
        provider_state_group: provider_state_group(lifecycle_state),
        updated_at: @now
      }

    {:ok, observation} = ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: @now})
    signed_issue = %{issue | tracker_read_observation: sign_provider_observation_for_test(observation)}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [signed_issue])
    signed_issue
  end

  defp maybe_put_prior_candidate_guards(context, %WorkItem{lifecycle_assessment: %{satisfied_guards: guards}})
       when is_list(guards) and guards != [] do
    Map.put(context, :guard_evidence, guards)
  end

  defp maybe_put_prior_candidate_guards(context, _work_item), do: context

  defp work_item_with_satisfied_guards(%WorkItem{} = item, guards) when is_list(guards) do
    assessment = %{item.lifecycle_assessment | status: :validated, satisfied_guards: guards}
    %{item | lifecycle_assessment: assessment}
  end

  defp work_item_for_issue(%Issue{} = issue) do
    {:ok, lifecycle_state} = WorkflowLifecycle.parse(issue.state)

    {:ok, item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: @now,
        prior_validated_lifecycle_state: lifecycle_state,
        provider_project_contract: contract()
      })

    validated_assessment = %{
      item.lifecycle_assessment
      | status: :validated,
        validated_state: lifecycle_state,
        work_item_id: item.id,
        provider_observation: item.provider_observation
    }

    active_disposition = %{
      item.authority_disposition
      | status: :active,
        lifecycle_state: lifecycle_state
    }

    %{
      item
      | validated_lifecycle_state: lifecycle_state,
        lifecycle_assessment: validated_assessment,
        authority_disposition: active_disposition
    }
  end

  defp verified_payload(attempt, contract) do
    %{
      assessment: %{status: :validated, validated_state: attempt.requested_to},
      post_observation_evidence: %{
        workspace_id: "workspace-1",
        project_id: "project-1",
        work_item_id: attempt.work_item_id,
        provider_state_id: "state-#{attempt.requested_to}",
        observed_at: DateTime.utc_now()
      },
      post_contract_fingerprint: ProviderProjectContract.fingerprint(contract)
    }
  end

  defp capture_intent(from, to) do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: from,
        requested_to: to,
        responsibility: "implementation",
        guard_evidence: []
      })

    intent
  end

  defp capture_context do
    %{
      repository_context: %{workspace_path: "/tmp/pre-080c-workspace"},
      github_opts: github_opts(),
      probe_opts: [
        command_runner: fn _workspace, _git, argv ->
          if Enum.member?(argv, "rev-parse"), do: {:ok, @sha_b <> "\n"}, else: {:ok, ""}
        end
      ]
    }
  end

  defp github_opts do
    [
      source_control_config: @source_control_config,
      token: "token",
      request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
    ]
  end

  defp github_payload(path) do
    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @sha_a}}

      String.contains?(path, "/commits/" <> @sha_b <> "/pulls") ->
        [eligible_pull()]

      String.contains?(path, "/pulls/15") ->
        eligible_pull()

      String.contains?(path, "/compare/" <> @sha_a <> "..." <> @sha_b) ->
        %{"status" => "ahead"}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => @sha_b,
              "status" => "completed",
              "conclusion" => "success",
              "app" => %{"id" => 15_368}
            }
          ]
        }

      String.contains?(path, "/commits/" <> @sha_b) ->
        %{"commit" => %{"tree" => %{"sha" => String.duplicate("c", 40)}}}

      true ->
        %{}
    end
  end

  defp eligible_pull do
    %{
      "number" => 15,
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => @sha_a, "ref" => "main"}
    }
  end

  defp provider_state_group(:backlog), do: :backlog
  defp provider_state_group(state) when state in [:planning, :ready], do: :unstarted
  defp provider_state_group(:done), do: :completed
  defp provider_state_group(:canceled), do: :cancelled
  defp provider_state_group(_state), do: :started

  defp route(work_item_id, state, responsibility) do
    profile_name =
      %{
        "planning" => "planner",
        "implementation" => "builder",
        "review" => "reviewer",
        "correction" => "fixer"
      }[responsibility]

    profile = Profile.default_profiles("codex app-server", 20)[profile_name]
    Route.new(%Issue{id: work_item_id, state: WorkflowLifecycle.display(state)}, profile)
  end

  defp contract do
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
        state_mappings: mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end

  defp provider_contract_config(%ProviderProjectContract{} = provider_contract) do
    %{
      schema_version: provider_contract.schema_version,
      provider: "plane",
      workspace_id: provider_contract.workspace_id,
      project_id: provider_contract.project_id,
      state_mappings:
        Map.new(provider_contract.state_mappings, fn {state, mapping} ->
          {state, Map.take(mapping, [:state_id, :name])}
        end),
      dependency_relation_semantics: provider_contract.dependency_relation_semantics
    }
  end

  defp restore_application_env(:workflow_file_path, previous_path) do
    restore_application_env_value(:workflow_file_path, previous_path)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end
  end

  defp restore_application_env(key, value), do: restore_application_env_value(key, value)

  defp restore_application_env_value(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env_value(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
