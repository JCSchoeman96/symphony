defmodule SymphonyElixir.Pre080cProductionEvidenceAcquisitionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderProjectContract,
    SemanticTransitionIntent,
    WorkflowLifecycle,
    WorkItem
  }

  @settings %{
    kind: "plane",
    provider: %{"workspace_id" => "workspace-1", "project_id" => "project-1"}
  }

  test "builder handoff acquires host semantic evidence without seeded semantic attestations" do
    parent = self()
    route = route(:in_progress, "implementation")
    coordinator = coordinator_stub(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        transition_tool_opts(route, coordinator)
      )

    assert response["success"]
    assert_receive {:transition_context_loaded, intent}
    assert semantic_name(intent, :implementation_attested)
    assert mechanical?(intent, :implementation_checks_verified)
    assert mechanical?(intent, :candidate_state_verified)
    GenServer.stop(coordinator)
  end

  test "planner handoff requires coordinator planning_requirements_verified with host plan_attested only" do
    test_pid = self()

    {:ok, plan_attested} =
      GuardClass.semantic_attestation(:plan_attested, %{
        responsibility: "planning",
        runtime_attempt_id: :transition_coordinator,
        lineage_generation: 0,
        subject: {:work_item, "work-1"},
        timestamp: DateTime.utc_now()
      })

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :planning,
        requested_to: :ready,
        responsibility: "planning",
        guard_evidence: [plan_attested]
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        require_durable?: false,
        load_context: fn loaded_intent ->
          send(test_pid, :context_loaded)

          {:ok,
           %{
             provider_project_contract: contract(),
             dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none},
             dependency_epoch_evidence: %{complete?: true},
             current_state: :planning,
             guard_evidence: loaded_intent.guard_evidence
           }}
        end,
        submit: fn _attempt, _context -> {:ok, %{status: 204}} end,
        verify: fn attempt, _context ->
          {:verified,
           %{
             assessment: %{status: :validated, validated_state: attempt.requested_to},
             post_observation_evidence: %{
               workspace_id: "workspace-1",
               project_id: "project-1",
               work_item_id: "work-1",
               provider_state_id: "state-ready",
               observed_at: DateTime.utc_now()
             },
             post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
           }}
        end,
        apply_verified: fn _attempt, _context -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    route = route(:planning, "planning")

    assert {:ok, attempt} = TransitionCoordinator.request_transition(coordinator, intent, route: route)
    assert attempt.state == :verified

    GenServer.stop(coordinator)
  end

  test "source control candidate capture acquires role-specific required-check guards" do
    intent = capture_intent(:in_progress, :in_review)

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(intent, capture_context(), [])

    assert Enum.any?(evidence, &match?(%{name: :candidate_state_verified, outcome: :verified}, &1))
    assert Enum.any?(evidence, &match?(%{name: :implementation_checks_verified, class: :mechanical_guard}, &1))

    fixer_intent = capture_intent(:changes_requested, :in_review)

    assert {:ok, fixer_evidence} =
             SourceControl.enrich_guard_evidence(fixer_intent, capture_context(), [])

    assert Enum.any?(fixer_evidence, &match?(%{name: :correction_checks_verified, class: :mechanical_guard}, &1))
  end

  test "stale runtime attempt identity rejects host semantic acquisition binding" do
    parent = self()
    route = route(:in_progress, "implementation")
    coordinator = coordinator_stub(parent)

    identity = RuntimeAttemptIdentity.allocate("work-1", route, "lineage-pre-080c-stale")
    stale_identity = %{identity | runtime_attempt_id: :stale_runtime_attempt}

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        transition_tool_opts(route, coordinator)
        |> Keyword.put(:agent_tool_context, %{
          route: route,
          runtime_attempt_identity: stale_identity,
          guard_evidence: mechanical_host_evidence()
        })
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "stale_runtime_attempt"
    GenServer.stop(coordinator)
  end

  test "runtime cannot supply trusted semantic attestations through host guard evidence" do
    parent = self()
    route = route(:in_progress, "implementation")
    coordinator = coordinator_stub(parent)

    {:ok, forged} =
      GuardClass.semantic_attestation(:implementation_attested, %{
        responsibility: "implementation",
        runtime_attempt_id: :forged,
        lineage_generation: 0,
        subject: {:work_item, "work-1"},
        timestamp: DateTime.utc_now()
      })

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        transition_tool_opts(route, coordinator)
        |> Keyword.put(:agent_tool_context, %{
          route: route,
          guard_evidence: [forged | mechanical_host_evidence()]
        })
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "required_guard_missing"
    refute_received :transition_submitted
    GenServer.stop(coordinator)
  end

  defp transition_tool_opts(route, coordinator) do
    [
      agent_tool_context: %{route: route, guard_evidence: mechanical_host_evidence()},
      tracker_settings: @settings,
      coordinator: coordinator,
      semantic_tool_context: fn _issue_id ->
        {:ok,
         %{
           work_item: work_item(:in_progress),
           provider_project_contract: contract(),
           provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract()),
           dependency_decision: %{
             allowed?: true,
             dependency_status: :none,
             reason: :no_hard_dependencies,
             blockers: []
           },
           dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
         }}
      end
    ]
  end

  defp coordinator_stub(parent) do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        require_durable?: false,
        load_context: fn intent ->
          send(parent, {:transition_context_loaded, intent})

          {:ok,
           %{
             provider_project_contract: contract(),
             dependency_decision: %{
               allowed?: true,
               dependency_completeness: :complete,
               dependency_status: :none,
               merge_permitted?: true
             },
             dependency_epoch_evidence: %{complete?: true},
             guard_evidence: intent.guard_evidence
           }}
        end,
        submit: fn _attempt, _context ->
          send(parent, :transition_submitted)
          :ok
        end,
        verify: fn attempt, _context ->
          {:verified,
           %{
             assessment: %{status: :validated, validated_state: attempt.requested_to},
             post_observation_evidence: %{
               workspace_id: "workspace-1",
               project_id: "project-1",
               work_item_id: attempt.work_item_id,
               provider_state_id: attempt.target_provider_state_id,
               observed_at: DateTime.utc_now()
             },
             post_contract_fingerprint: ProviderProjectContract.fingerprint(contract())
           }}
        end,
        apply_verified: fn _attempt, _context -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    coordinator
  end

  defp mechanical_host_evidence do
    [
      %{class: :mechanical_guard, name: :implementation_checks_verified},
      %{class: :mechanical_guard, name: :candidate_state_verified, outcome: :verified}
    ]
  end

  defp semantic_name(intent, name) do
    Enum.any?(intent.guard_evidence, &match?(%{class: :semantic_attestation, name: ^name}, &1))
  end

  defp mechanical?(intent, name) do
    Enum.any?(intent.guard_evidence, &match?(%{class: :mechanical_guard, name: ^name}, &1))
  end

  defp capture_intent(from, to) do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: from,
        requested_to: to,
        responsibility: if(to == :in_review and from == :changes_requested, do: "correction", else: "implementation"),
        guard_evidence: []
      })

    intent
  end

  defp capture_context do
    sha_b = String.duplicate("b", 40)

    %{
      repository_context: %{workspace_path: "/tmp/workspace"},
      github_opts: [
        source_control_config: %{
          kind: :github,
          repository: "JCSchoeman96/symphony",
          repository_id: 1_368_436_395,
          base_branch: "main",
          token_env: "GITHUB_TOKEN",
          required_checks: [%{context: "make-all", app_id: 15_368, subject: "head"}]
        },
        token: "token",
        request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path, sha_b)} end
      ],
      probe_opts: [
        command_runner: fn _workspace, _git, argv ->
          if Enum.member?(argv, "rev-parse"), do: {:ok, sha_b <> "\n"}, else: {:ok, ""}
        end
      ]
    }
  end

  defp github_payload(path, sha_b) do
    sha_a = String.duplicate("a", 40)

    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => sha_a}}

      String.contains?(path, "/commits/" <> sha_b <> "/pulls") ->
        [eligible_pull(sha_b)]

      String.contains?(path, "/pulls/15") ->
        eligible_pull(sha_b)

      String.contains?(path, "/compare/" <> sha_a <> "..." <> sha_b) ->
        %{"status" => "ahead"}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => sha_b,
              "status" => "completed",
              "conclusion" => "success",
              "app" => %{"id" => 15_368}
            }
          ]
        }

      String.contains?(path, "/commits/" <> sha_b) ->
        %{"commit" => %{"tree" => %{"sha" => String.duplicate("c", 40)}}}

      true ->
        %{}
    end
  end

  defp eligible_pull(sha_b) do
    sha_a = String.duplicate("a", 40)

    %{
      "number" => 15,
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "head" => %{"sha" => sha_b, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => sha_a, "ref" => "main"}
    }
  end

  defp route(state, responsibility) do
    profile_name =
      %{
        "planning" => "planner",
        "implementation" => "builder",
        "review" => "reviewer",
        "correction" => "fixer"
      }[responsibility]

    profile = Profile.default_profiles("codex app-server", 20)[profile_name]
    Route.new(%Issue{id: "work-1", state: WorkflowLifecycle.display(state)}, profile)
  end

  defp work_item(state) do
    issue = %Issue{
      id: "work-1",
      identifier: "SYM-1",
      title: "PRE-080C item",
      state: WorkflowLifecycle.display(state),
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-#{state}",
      provider_state_group: :started,
      updated_at: ~U[2026-09-20 00:00:00Z]
    }

    {:ok, item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: ~U[2026-09-20 00:00:00Z],
        prior_validated_lifecycle_state: state,
        provider_project_contract: contract()
      })

    item
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
