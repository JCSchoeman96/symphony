defmodule SymphonyElixir.PlaneAgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @settings %{
    kind: "plane",
    provider: %{
      "workspace_id" => "workspace-1",
      "project_id" => "project-1"
    }
  }

  test "advertises the five semantic Plane tool names" do
    assert Enum.map(AgentTool.agent_tool_specs(), &Map.fetch!(&1, "name")) == [
             "plane_get_current_work_item",
             "plane_get_dependencies",
             "plane_get_lifecycle_assessment",
             "plane_get_authority_disposition",
             "plane_request_lifecycle_transition"
           ]
  end

  test "read schemas accept exactly an empty object and transition stays structural" do
    specs = AgentTool.agent_tool_specs()

    for spec <- Enum.take(specs, 4) do
      assert spec["inputSchema"] == %{
               "type" => "object",
               "additionalProperties" => false,
               "properties" => %{}
             }
    end

    transition = List.last(specs)
    assert transition["name"] == "plane_request_lifecycle_transition"
    assert transition["inputSchema"]["required"] == ["targetState"]
    assert transition["inputSchema"]["additionalProperties"] == false
  end

  test "catalogue exposes only responsibility-authorized targets" do
    assert target_enum("planning", :planning) == ["Ready"]

    assert target_enum("implementation", :ready) == ["In Progress", "In Review"]

    assert target_enum("review", :in_review) == ["Changes Requested", "Ready to Merge"]
    assert target_enum("correction", :changes_requested) == ["In Review"]

    merge_specs = AgentTool.agent_tool_specs(%{route: route(:ready_to_merge, "merge")})
    refute Enum.any?(merge_specs, &(&1["name"] == "plane_request_lifecycle_transition"))
    assert Enum.count(merge_specs) == 4

    assert AgentTool.agent_tool_specs(%{}) == []
    assert AgentTool.agent_tool_specs(%{route: %Route{}}) == []
  end

  test "current work-item read uses the injected trusted semantic context" do
    parent = self()
    work_item = work_item(:in_progress)
    route = route(:in_progress, "implementation")
    contract = contract()

    response =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        host_opts(route, semantic_context(work_item, contract), fn issue_id ->
          send(parent, {:semantic_context_requested, issue_id})
          :ok
        end)
      )

    assert response["success"]
    assert_received {:semantic_context_requested, "work-1"}

    assert Jason.decode!(response["output"]) == %{
             "workItemId" => "work-1",
             "identifier" => "SYM-1",
             "title" => "Semantic Plane item",
             "canonicalLifecycleState" => "in_progress",
             "dependencyCompleteness" => "complete",
             "providerObservation" => %{
               "stateName" => "In Progress",
               "observedAt" => "2026-09-20T00:00:00Z",
               "providerUpdatedAt" => "2026-09-20T00:00:00Z"
             }
           }

    refute response["output"] =~ "workspace-1"
    refute response["output"] =~ "project-1"
    refute response["output"] =~ "state-in_progress"
    refute response["output"] =~ "token"
  end

  test "reads reject non-empty or malformed arguments without loading context" do
    parent = self()

    fetcher = fn _issue_id ->
      send(parent, :semantic_context_must_not_run)
      {:error, :unexpected}
    end

    for arguments <- [%{"issueId" => "work-1"}, %{issue_id: "work-1"}, :invalid, nil] do
      response =
        AgentTool.execute(
          "plane_get_current_work_item",
          arguments,
          semantic_tool_context: fetcher,
          tracker_settings: @settings,
          agent_tool_context: %{route: route(:in_progress, "implementation")}
        )

      refute response["success"]
    end

    refute_received :semantic_context_must_not_run
  end

  test "transition request is bounded unsupported and never loads context" do
    parent = self()

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        semantic_tool_context: fn _issue_id ->
          send(parent, :must_not_run)
          :ok
        end,
        tracker_settings: @settings,
        agent_tool_context: %{route: route(:in_progress, "implementation")}
      )

    refute response["success"]

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "code" => "transition_unsupported",
               "message" => "Plane semantic tool request was rejected."
             }
           }

    refute_received :must_not_run
  end

  test "dependency read requires a complete epoch and returns bounded blocker classifications" do
    work_item = work_item(:in_progress)
    blocker = blocker_work_item(:done)
    contract = contract()

    decision = %{
      allowed?: true,
      dependency_status: :satisfied,
      reason: :dependencies_satisfied,
      blockers: [blocker],
      unresolved_blockers: [],
      invalidated_blockers: []
    }

    complete_context =
      semantic_context(work_item, contract, %{dependency_decision: decision, work_control: %{"blocker-1" => blocker}})

    complete =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(route(:in_progress, "implementation"), complete_context)
      )

    assert complete["success"]

    assert Jason.decode!(complete["output"]) == %{
             "epoch" => "epoch-1",
             "completeness" => "complete",
             "status" => "satisfied",
             "reason" => "dependencies_satisfied",
             "blockers" => [%{"id" => "blocker-1", "identifier" => "SYM-BLOCKER", "classification" => "satisfied"}]
           }

    incomplete_context = Map.put(complete_context, :dependency_epoch_evidence, %{complete?: false})

    incomplete =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(route(:in_progress, "implementation"), incomplete_context)
      )

    refute incomplete["success"]
  end

  test "dependency read classifies cancellation as invalidated and raw Done as unavailable" do
    work_item = work_item(:in_progress)
    contract = contract()

    decision = %{
      allowed?: false,
      dependency_status: :invalidated,
      reason: :invalidated_dependency,
      blockers: [
        %{id: "canceled", identifier: "SYM-CANCELED", state: "Canceled"},
        %{id: "raw-done", identifier: "SYM-DONE", state: "Done"}
      ]
    }

    response =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item, contract, %{dependency_decision: decision})
        )
      )

    assert response["success"]

    assert Jason.decode!(response["output"])["blockers"] == [
             %{"id" => "canceled", "identifier" => "SYM-CANCELED", "classification" => "invalidated"},
             %{"id" => "raw-done", "identifier" => "SYM-DONE", "classification" => "unavailable"}
           ]
  end

  test "assessment and disposition reads expose only allowlisted fields" do
    work_item = work_item(:in_progress)
    contract = contract()
    opts = host_opts(route(:in_progress, "implementation"), semantic_context(work_item, contract))

    assessment = AgentTool.execute("plane_get_lifecycle_assessment", %{}, opts)
    disposition = AgentTool.execute("plane_get_authority_disposition", %{}, opts)

    assert Map.keys(Jason.decode!(assessment["output"])) |> Enum.sort() ==
             ["assessedAt", "mappedState", "missingGuards", "reason", "requiredGuards", "status", "validatedState"] |> Enum.sort()

    assert Map.keys(Jason.decode!(disposition["output"])) |> Enum.sort() ==
             ["lifecycleState", "reason", "resumeTarget", "status", "updatedAt"] |> Enum.sort()

    refute assessment["output"] =~ "providerObservation"
    refute assessment["output"] =~ "satisfiedGuards"
    refute disposition["output"] =~ "suspend"
  end

  test "route, item, and project scope mismatches fail closed" do
    work_item = work_item(:in_progress)
    contract = contract()
    context = semantic_context(work_item, contract)

    stale_route = %{route(:in_progress, "implementation") | starting_state: "ready"}

    for {route, context_override, settings} <- [
          {stale_route, context, @settings},
          {route(:in_progress, "implementation"), %{context | work_item: %{work_item | id: "other"}}, @settings},
          {route(:in_progress, "implementation"), context, put_in(@settings, [:provider, "project_id"], "other-project")},
          {route(:in_progress, "implementation"), %{context | provider_project_contract: %{contract | project_id: "other-project"}}, @settings}
        ] do
      response =
        AgentTool.execute(
          "plane_get_current_work_item",
          %{},
          host_opts(route, context_override, nil, settings)
        )

      refute response["success"]
    end
  end

  defp target_enum(responsibility, state) do
    route = route(state, responsibility)

    AgentTool.agent_tool_specs(%{route: route})
    |> List.last()
    |> get_in(["inputSchema", "properties", "targetState", "enum"])
  end

  defp host_opts(route, context, callback \\ nil, settings \\ @settings) do
    callback = callback || fn _issue_id -> {:ok, context} end

    [
      agent_tool_context: %{route: route},
      tracker_settings: settings,
      semantic_tool_context: fn issue_id ->
        case callback.(issue_id) do
          :ok -> {:ok, context}
          other -> other
        end
      end
    ]
  end

  defp semantic_context(work_item, contract, overrides \\ %{}) do
    Map.merge(
      %{
        work_item: work_item,
        provider_project_contract: contract,
        provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract),
        dependency_decision: %{allowed?: true, dependency_status: :none, reason: :no_hard_dependencies, blockers: []},
        dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
      },
      overrides
    )
  end

  defp route(state, responsibility) do
    profile_name =
      %{
        "planning" => "planner",
        "implementation" => "builder",
        "review" => "reviewer",
        "correction" => "fixer",
        "merge" => "merge_gatekeeper"
      }[responsibility]

    profile = Profile.default_profiles("codex app-server", 20)[profile_name]
    Route.new(%Issue{id: "work-1", state: WorkflowLifecycle.display(state)}, profile)
  end

  defp work_item(state) do
    issue = %Issue{
      id: "work-1",
      identifier: "SYM-1",
      title: "Semantic Plane item",
      state: WorkflowLifecycle.display(state),
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-#{state}",
      provider_state_group: if(state in [:done, :canceled], do: :completed, else: :started),
      updated_at: ~U[2026-09-20 00:00:00Z]
    }

    evidence =
      if state == :done,
        do: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)],
        else: []

    {:ok, item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: ~U[2026-09-20 00:00:00Z],
        prior_validated_lifecycle_state: state,
        evidence: evidence
      })

    item
  end

  defp blocker_work_item(:done) do
    issue = %Issue{
      id: "blocker-1",
      identifier: "SYM-BLOCKER",
      title: "Validated blocker",
      state: "Done",
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-done",
      provider_state_group: :completed,
      updated_at: ~U[2026-09-20 00:00:00Z]
    }

    WorkItem.from_issue(issue, %{
      provider: :plane,
      observed_at: ~U[2026-09-20 00:00:00Z],
      prior_validated_lifecycle_state: :merging,
      evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
    })
    |> elem(1)
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
