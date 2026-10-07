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

defmodule SymphonyElixir.Pre080cProductionEvidenceAcquisitionTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.Pre080cProductionPathOrchestrator, as: ProductionPathOrchestrator
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderObservation,
    ProviderProjectContract,
    SemanticTransitionIntent,
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

    assert_receive {:transition_submitted, _builder_attempt, builder_evidence}
    GenServer.stop(builder_coordinator)

    candidate_guards =
      Enum.filter(builder_evidence, fn guard ->
        guard.name in [:candidate_state_verified, :implementation_checks_verified]
      end)

    issue = tracked_issue(work_item_id, :in_review)
    work_item = work_item_with_satisfied_guards(work_item_for_issue(issue), candidate_guards)

    reviewer_route = route(work_item_id, :in_review, "review")
    reviewer_identity = RuntimeAttemptIdentity.allocate(work_item_id, reviewer_route, "lineage-pre-080c-reviewer-accept")
    reviewer_coordinator = production_coordinator(work_item_id, :in_review, capture?: true, work_item: work_item)

    response =
      transition_response(work_item_id, reviewer_route, reviewer_coordinator, "Ready to Merge",
        identity: reviewer_identity,
        source: :in_review
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

  test "runtime cannot supply trusted semantic attestations through host guard evidence" do
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

  defp agent_tool_opts(work_item_id, route, coordinator, opts) do
    source = Keyword.get(opts, :source, :in_progress)
    identity = Keyword.get(opts, :identity)
    host_identity = Keyword.get(opts, :host_identity, identity)
    semantic_identity = Keyword.get(opts, :semantic_identity, identity)
    item = work_item_for_issue(tracked_issue(work_item_id, source))

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

    agent_tool_context = %{route: route} |> maybe_put_identity(host_identity)

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

  defp update_memory_issue(work_item_id, target_state) do
    display = WorkflowLifecycle.display(target_state)

    case Application.get_env(:symphony_elixir, :memory_tracker_issues, []) do
      [%Issue{id: ^work_item_id} = issue | _] ->
        updated =
          %{
            issue
            | state: display,
              provider_state_id: "state-#{target_state}",
              provider_state_group: provider_state_group(target_state)
          }

        {:ok, observation} =
          ProviderObservation.from_issue(updated, %{provider: :plane, observed_at: DateTime.utc_now()})

        signed = %{updated | tracker_read_observation: sign_provider_observation_for_test(observation)}
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [signed])

      _ ->
        :ok
    end
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
end
