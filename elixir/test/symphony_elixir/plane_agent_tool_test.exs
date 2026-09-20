defmodule SymphonyElixir.PlaneAgentToolTest.CoordinatorStub do
  use GenServer

  def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

  @impl true
  def init(reply), do: {:ok, reply}

  @impl true
  def handle_call(_request, _from, reply), do: {:reply, reply, reply}
end

defmodule SymphonyElixir.PlaneAgentToolTest.ThrowingContextStub do
  use GenServer

  def start, do: GenServer.start(__MODULE__, :ok)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(_request, _from, _state), do: throw(:context_call_failed)
end

defmodule SymphonyElixir.PlaneAgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.PlaneAgentToolTest.CoordinatorStub
  alias SymphonyElixir.PlaneAgentToolTest.ThrowingContextStub
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
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
    assert target_enum("planning", :backlog) == ["Ready"]
    assert target_enum("planning", :planning) == ["Ready"]

    assert target_enum("implementation", :ready) == ["In Progress", "In Review"]

    assert target_enum("review", :in_review) == ["Changes Requested", "Ready to Merge"]
    assert target_enum("correction", :changes_requested) == ["In Review"]

    merge_specs = AgentTool.agent_tool_specs(%{route: route(:ready_to_merge, "merge")})
    refute Enum.any?(merge_specs, &(&1["name"] == "plane_request_lifecycle_transition"))
    assert Enum.count(merge_specs) == 4

    assert AgentTool.agent_tool_specs(%{}) == []
    assert AgentTool.agent_tool_specs(%{route: %Route{}}) == []
    assert AgentTool.agent_tool_specs(:not_a_context) == []
  end

  test "catalogue accepts a valid planning route and rejects a forged route" do
    planning_route = route(:backlog, "planning")

    assert Enum.count(AgentTool.agent_tool_specs(%{route: planning_route})) == 5

    forged_route = %{planning_route | fingerprint: "sha256:forged"}
    assert AgentTool.agent_tool_specs(%{route: forged_route}) == []
  end

  test "rejects unsupported tools and malformed read options with bounded responses" do
    unsupported = AgentTool.execute("plane_delete_work_item", %{}, [])

    refute unsupported["success"]

    assert Jason.decode!(unsupported["output"]) == %{
             "error" => %{
               "code" => "unsupported_tool",
               "message" => "Unsupported Plane semantic tool.",
               "supportedTools" => [
                 "plane_get_current_work_item",
                 "plane_get_dependencies",
                 "plane_get_lifecycle_assessment",
                 "plane_get_authority_disposition",
                 "plane_request_lifecycle_transition"
               ]
             }
           }

    malformed_options = AgentTool.execute("plane_get_current_work_item", %{}, :not_a_keyword_list)

    refute malformed_options["success"]

    assert Jason.decode!(malformed_options["output"]) == %{
             "error" => %{
               "code" => "invalid_options",
               "message" => "Plane semantic tool request was rejected."
             }
           }
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

  test "reads fail closed for unavailable, malformed, and raised semantic context callbacks" do
    context = semantic_context(work_item(:in_progress), contract())
    route = route(:in_progress, "implementation")
    base_opts = [agent_tool_context: %{route: route}, tracker_settings: @settings]

    direct_context =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        Keyword.put(base_opts, :semantic_tool_context, fn _issue_id -> context end)
      )

    assert direct_context["success"]

    for {callback, code} <- [
          {fn _issue_id -> {:error, :orchestrator_down} end, "context_unavailable"},
          {fn _issue_id -> :invalid_context_payload end, "invalid_context"},
          {fn _issue_id -> raise "context callback failed" end, "context_unavailable"},
          {fn _issue_id -> throw(:context_callback_failed) end, "context_unavailable"}
        ] do
      response =
        AgentTool.execute(
          "plane_get_current_work_item",
          %{},
          Keyword.put(base_opts, :semantic_tool_context, callback)
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == code
    end

    unavailable_server =
      Module.concat(__MODULE__, "MissingContextServer#{System.unique_integer([:positive])}")

    response =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        Keyword.put(base_opts, :orchestrator_server, unavailable_server)
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "context_unavailable"

    host_map_context =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        agent_tool_context: %{route: route, semantic_context: context},
        tracker_settings: @settings
      )

    assert host_map_context["success"]
  end

  test "reads handle orchestrator errors and malformed replies without leaking context" do
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())
    base_opts = [agent_tool_context: %{route: route}, tracker_settings: @settings]

    {:ok, reply_server} = CoordinatorStub.start_link({:ok, context})

    reply_response =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        Keyword.put(base_opts, :orchestrator_server, reply_server)
      )

    assert reply_response["success"]
    GenServer.stop(reply_server)

    for reply <- [{:error, :orchestrator_down}, {:ok, :malformed_context}] do
      {:ok, server} = CoordinatorStub.start_link(reply)

      response =
        AgentTool.execute(
          "plane_get_current_work_item",
          %{},
          Keyword.put(base_opts, :orchestrator_server, server)
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == "context_unavailable"
      GenServer.stop(server)
    end

    {:ok, throwing_server} = ThrowingContextStub.start()

    throwing_response =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        Keyword.put(base_opts, :orchestrator_server, throwing_server)
      )

    refute throwing_response["success"]
    assert Jason.decode!(throwing_response["output"])["error"]["code"] == "context_unavailable"
  end

  test "reads reject malformed host contexts and binding evidence" do
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())

    invalid_host =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        agent_tool_context: :not_a_context,
        tracker_settings: @settings
      )

    refute invalid_host["success"]
    assert Jason.decode!(invalid_host["output"])["error"]["code"] == "invalid_context"

    assessment = context.work_item.lifecycle_assessment
    disposition = context.work_item.authority_disposition

    malformed_contexts = [
      Map.delete(context, :work_item),
      Map.delete(context, :provider_project_contract),
      %{context | provider_contract_fingerprint: "sha256:forged"},
      %{context | work_item: %{context.work_item | provider_observation: nil}},
      %{context | work_item: %{context.work_item | lifecycle_assessment: nil}},
      %{
        context
        | work_item: %{
            context.work_item
            | lifecycle_assessment: %{assessment | status: :unsupported_status}
          }
      },
      %{
        context
        | work_item: %{
            context.work_item
            | lifecycle_assessment: %{assessment | required_guards: :not_a_list}
          }
      },
      %{context | work_item: %{context.work_item | authority_disposition: nil}}
    ]

    for malformed_context <- malformed_contexts do
      response =
        AgentTool.execute(
          "plane_get_current_work_item",
          %{},
          host_opts(route, malformed_context)
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == "invalid_context"
    end

    invalid_scope =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        host_opts(route, context, nil, [])
      )

    refute invalid_scope["success"]
    assert Jason.decode!(invalid_scope["output"])["error"]["code"] == "invalid_context"

    top_level_scope = %{
      "kind" => "plane",
      "workspace_id" => "workspace-1",
      "project_id" => "project-1"
    }

    assert AgentTool.execute(
             "plane_get_current_work_item",
             %{},
             host_opts(route, context, nil, top_level_scope)
           )["success"]

    valid_resume =
      %{disposition | status: :active, lifecycle_state: :in_progress, resume_target: :ready}

    resume_context = %{context | work_item: %{context.work_item | authority_disposition: valid_resume}}

    assert AgentTool.execute(
             "plane_get_current_work_item",
             %{},
             host_opts(route, resume_context)
           )["success"]
  end

  test "transition request delegates an authorized canonical intent to H-040" do
    parent = self()
    work_item = work_item(:in_progress)
    contract = contract()
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item, contract),
          nil,
          @settings
        )
        |> Keyword.put(:coordinator, coordinator)
        |> Keyword.put(:agent_tool_context, %{
          route: route(:in_progress, "implementation"),
          guard_evidence: transition_guard_evidence()
        })
      )

    assert response["success"]

    assert Jason.decode!(response["output"]) == %{
             "status" => "verified",
             "targetState" => "In Review"
           }

    assert_receive {:transition_context_loaded, intent}
    assert intent.work_item_id == "work-1"
    assert intent.requested_from == :in_progress
    assert intent.requested_to == :in_review
    assert intent.responsibility == "implementation"

    assert Enum.map(intent.guard_evidence, &Map.get(&1, :name)) == [
             :implementation_attested,
             :implementation_checks_verified
           ]

    assert is_nil(intent.runtime_attempt_id)
    assert is_nil(intent.lineage_id)
    assert is_nil(intent.lineage_generation)
    assert_received :transition_submitted
    refute response["output"] =~ "attempt"
    refute response["output"] =~ "provider_state_id"

    GenServer.stop(coordinator)
  end

  test "transition request validates exact arguments before loading context" do
    parent = self()

    for arguments <- [
          %{},
          %{"targetState" => "In Review", "extra" => "rejected"},
          %{"target_state" => "In Review"},
          %{"targetState" => :in_review},
          %{"targetState" => "state-in_review"},
          %{"targetState" => "Done"},
          :invalid,
          nil
        ] do
      response =
        AgentTool.execute(
          "plane_request_lifecycle_transition",
          arguments,
          semantic_tool_context: fn _issue_id ->
            send(parent, :transition_context_must_not_run)
            {:error, :unexpected}
          end,
          tracker_settings: @settings,
          agent_tool_context: %{route: route(:in_progress, "implementation")}
        )

      refute response["success"]
    end

    refute_received :transition_context_must_not_run
  end

  test "transition request parses only WorkflowLifecycle display targets" do
    parent = self()

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "in_review"},
        semantic_tool_context: fn _issue_id ->
          send(parent, :transition_context_must_not_run)
          {:ok, semantic_context(work_item(:in_progress), contract())}
        end,
        tracker_settings: @settings,
        agent_tool_context: %{route: route(:in_progress, "implementation")}
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "invalid_target_state"
    refute_received :transition_context_must_not_run
  end

  test "transition request lets Runtime.Authority reject a canonical but disallowed target" do
    parent = self()

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Blocked"},
        semantic_tool_context: fn _issue_id ->
          send(parent, :transition_context_must_not_run)
          {:error, :unexpected}
        end,
        tracker_settings: @settings,
        agent_tool_context: %{route: route(:in_progress, "implementation")}
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "unauthorized_transition"
    refute_received :transition_context_must_not_run
  end

  test "transition request rejects missing host guard evidence without submitting" do
    parent = self()
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item(:in_progress), contract())
        )
        |> Keyword.put(:coordinator, coordinator)
      )

    refute response["success"]

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "code" => "required_guard_missing",
               "message" => "Plane lifecycle transition was rejected.",
               "status" => "rejected"
             }
           }

    refute_received :transition_submitted

    GenServer.stop(coordinator)
  end

  test "transition request ignores semantic-context guard evidence" do
    parent = self()
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(
            work_item(:in_progress),
            contract(),
            %{guard_evidence: transition_guard_evidence()}
          )
        )
        |> Keyword.put(:coordinator, coordinator)
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "required_guard_missing"
    refute_received :transition_submitted

    GenServer.stop(coordinator)
  end

  test "transition request does not invoke provider request callbacks" do
    parent = self()
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item(:in_progress), contract())
        )
        |> Keyword.put(:coordinator, coordinator)
        |> Keyword.put(:request_fun, fn request ->
          send(parent, {:provider_request, request})
          {:ok, %{status: 200}}
        end)
        |> Keyword.put(:agent_tool_context, %{
          route: route(:in_progress, "implementation"),
          guard_evidence: transition_guard_evidence()
        })
      )

    assert response["success"]
    refute_received {:provider_request, _request}
    GenServer.stop(coordinator)
  end

  test "transition request serializes coordinator terminal outcomes by status and reason" do
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())

    replies = [
      {{:ok, %{state: :requested}}, %{"status" => "indeterminate", "code" => "transition_indeterminate"}},
      {{:ok, %{state: :unknown}}, %{"code" => "invalid_transition_result"}},
      {{:ok, %{state: :conflict, outcome_reason: :stale_context}}, %{"status" => "conflict", "code" => "transition_conflict"}},
      {{:ok, %{state: :provider_failed, outcome_reason: :timeout}}, %{"status" => "provider_failed", "code" => "provider_failed"}},
      {{:ok, %{state: :indeterminate, outcome_reason: :unknown}}, %{"status" => "indeterminate", "code" => "transition_indeterminate"}},
      {{:ok, %{state: :rejected, outcome_reason: :required_guard_missing}}, %{"status" => "rejected", "code" => "required_guard_missing"}},
      {{:ok, %{state: :rejected, outcome_reason: :dependency_context_unavailable}}, %{"status" => "rejected", "code" => "dependency_context_unavailable"}},
      {{:ok, %{state: :rejected, outcome_reason: :transitions_disabled}}, %{"status" => "rejected", "code" => "transitions_disabled"}},
      {{:ok, %{state: :rejected, outcome_reason: :transition_in_progress}}, %{"status" => "rejected", "code" => "transition_in_progress"}},
      {{:ok, %{state: :rejected, outcome_reason: :transition_fenced}}, %{"status" => "rejected", "code" => "transition_fenced"}},
      {{:ok, %{state: :rejected, outcome_reason: :coordinator_unavailable}}, %{"status" => "rejected", "code" => "coordinator_unavailable"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_transition_arguments}}, %{"status" => "rejected", "code" => "invalid_transition_arguments"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_target_state}}, %{"status" => "rejected", "code" => "invalid_target_state"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_transition_target}}, %{"status" => "rejected", "code" => "invalid_transition_target"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_context}}, %{"status" => "rejected", "code" => "invalid_transition_context"}},
      {{:ok, %{state: :rejected, outcome_reason: :authority_unavailable}}, %{"status" => "rejected", "code" => "authority_unavailable"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_intent}}, %{"status" => "rejected", "code" => "invalid_intent"}},
      {{:ok, %{state: :rejected, outcome_reason: :invalid_transition_result}}, %{"status" => "rejected", "code" => "invalid_transition_result"}},
      {{:ok, %{state: :rejected, outcome_reason: %{code: :not_permitted}}}, %{"status" => "rejected", "code" => "unauthorized_transition"}},
      {{:ok, %{state: :rejected, outcome_reason: %{code: :invalid_subject}}}, %{"status" => "rejected", "code" => "invalid_transition_context"}},
      {
        {:ok, %{state: :rejected, outcome_reason: {:authority_rejected, %{code: :not_permitted}}}},
        %{"status" => "rejected", "code" => "unauthorized_transition"}
      },
      {
        {:ok, %{state: :rejected, outcome_reason: {:authority_rejected, %{code: :invalid_subject}}}},
        %{"status" => "rejected", "code" => "invalid_transition_context"}
      },
      {
        {:ok, %{state: :rejected, outcome_reason: {:policy_rejected, %{code: :dependency_transition_denied}}}},
        %{"status" => "rejected", "code" => "dependency_transition_denied"}
      },
      {
        {:ok, %{state: :rejected, outcome_reason: {:policy_rejected, :dependency_transition_denied}}},
        %{"status" => "rejected", "code" => "dependency_transition_denied"}
      }
    ]

    for {reply, expected} <- replies do
      {:ok, coordinator} = CoordinatorStub.start_link(reply)

      response =
        AgentTool.execute(
          "plane_request_lifecycle_transition",
          %{"targetState" => "In Review"},
          transition_opts(route, context, coordinator)
        )

      refute response["success"]
      error = Jason.decode!(response["output"])["error"]
      assert error["code"] == expected["code"]

      if expected["status"] do
        assert error["status"] == expected["status"]
      else
        refute Map.has_key?(error, "status")
      end

      GenServer.stop(coordinator)
    end
  end

  test "transition request bounds unknown terminal and coordinator error reasons" do
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())

    for {reply, expected_code} <- [
          {{:ok, %{state: :rejected, outcome_reason: :unclassified}}, "transition_rejected"},
          {{:error, %{unexpected: :reason}}, "transition_rejected"}
        ] do
      {:ok, coordinator} = CoordinatorStub.start_link(reply)

      response =
        AgentTool.execute(
          "plane_request_lifecycle_transition",
          %{"targetState" => "In Review"},
          transition_opts(route, context, coordinator)
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == expected_code
      GenServer.stop(coordinator)
    end
  end

  test "transition request reports an unavailable coordinator without provider access" do
    parent = self()
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        transition_opts(route, context, self())
        |> Keyword.put(:agent_tool_context, %{
          route: route,
          guard_evidence: %{class: :mechanical_guard, name: :implementation_checks_verified}
        })
        |> Keyword.put(:request_fun, fn request ->
          send(parent, {:provider_request, request})
          {:ok, %{status: 200}}
        end)
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "coordinator_unavailable"
    refute_received {:provider_request, _request}

    default_response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        transition_opts(route, context, self())
        |> Keyword.delete(:coordinator)
        |> Keyword.put(:agent_tool_context, %{
          route: route,
          guard_evidence: %{class: :mechanical_guard, name: :implementation_checks_verified}
        })
      )

    refute default_response["success"]

    assert Jason.decode!(default_response["output"])["error"]["code"] in [
             "coordinator_unavailable",
             "transitions_disabled"
           ]
  end

  test "transition request rejects a forged non-Plane contract before H-040" do
    parent = self()
    route = route(:in_progress, "implementation")
    forged_contract = Map.put(contract(), :provider, :github)
    forged_contract = Map.put(forged_contract, :configuration_fingerprint, ProviderProjectContract.fingerprint(forged_contract))
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(route, semantic_context(work_item(:in_progress), forged_contract))
        |> Keyword.put(:coordinator, coordinator)
        |> Keyword.put(:agent_tool_context, %{
          route: route,
          guard_evidence: transition_guard_evidence()
        })
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "invalid_transition_context"
    refute_received {:transition_context_loaded, _intent}
    refute_received :transition_submitted

    GenServer.stop(coordinator)
  end

  test "transition request rejects unavailable authority before H-040" do
    parent = self()
    route = route(:in_progress, "implementation")

    for status <- [:none, :escalated, :suspended] do
      work_item = %{
        work_item(:in_progress)
        | authority_disposition: AuthorityDisposition.new(%{status: status, lifecycle_state: :in_progress})
      }

      coordinator = transition_coordinator(parent)

      response =
        AgentTool.execute(
          "plane_request_lifecycle_transition",
          %{"targetState" => "In Review"},
          host_opts(route, semantic_context(work_item, contract()))
          |> Keyword.put(:coordinator, coordinator)
          |> Keyword.put(:agent_tool_context, %{
            route: route,
            guard_evidence: transition_guard_evidence()
          })
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == "authority_unavailable"
      refute_received {:transition_context_loaded, _intent}
      refute_received :transition_submitted

      GenServer.stop(coordinator)
    end
  end

  test "transition request rejects cross-role and stale routes before context loading" do
    parent = self()
    semantic_context = semantic_context(work_item(:in_review), contract())

    cross_role =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Ready to Merge"},
        host_opts(
          route(:in_review, "implementation"),
          semantic_context,
          fn _issue_id ->
            send(parent, :transition_context_must_not_run)
            {:ok, semantic_context}
          end
        )
      )

    stale = %{route(:in_review, "review") | starting_state: "ready"}

    stale_response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Ready to Merge"},
        host_opts(
          stale,
          semantic_context,
          fn _issue_id ->
            send(parent, :transition_context_must_not_run)
            {:ok, semantic_context}
          end
        )
      )

    refute cross_role["success"]
    refute stale_response["success"]
    refute_received :transition_context_must_not_run
  end

  test "transition request rejects a live source that differs from the trusted route" do
    parent = self()
    semantic_context = semantic_context(work_item(:ready), contract())
    coordinator = transition_coordinator(parent)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "In Review"},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context
        )
        |> Keyword.put(:coordinator, coordinator)
      )

    refute response["success"]
    refute_received {:transition_context_loaded, _intent}
    refute_received :transition_submitted

    GenServer.stop(coordinator)
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
      semantic_context(work_item, contract, %{
        dependency_decision: decision,
        work_control: %{"blocker-1" => blocker}
      })

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
             "blockers" => [
               %{
                 "id" => "blocker-1",
                 "identifier" => "SYM-BLOCKER",
                 "classification" => "satisfied"
               }
             ]
           }

    incomplete_context =
      Map.put(complete_context, :dependency_epoch_evidence, %{complete?: false})

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
             %{
               "id" => "canceled",
               "identifier" => "SYM-CANCELED",
               "classification" => "invalidated"
             },
             %{"id" => "raw-done", "identifier" => "SYM-DONE", "classification" => "unavailable"}
           ]
  end

  test "dependency read classifies WorkItems and unknown raw blockers without leaking provider state" do
    canceled = %{work_item(:canceled) | id: "canceled", identifier: "SYM-CANCELED"}
    active = %{work_item(:in_progress) | id: "active", identifier: "SYM-ACTIVE"}

    decision = %{
      allowed?: false,
      dependency_status: "invalidated",
      reason: 42,
      blockers: [
        canceled,
        active,
        %{"id" => "unknown"},
        %{"id" => "unresolved", "identifier" => "SYM-UNRESOLVED"}
      ],
      invalidated_blockers: [:ignored, %{"id" => "unknown"}],
      unresolved_blockers: [active, %{"id" => "unresolved"}]
    }

    response =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item(:in_progress), contract(), %{
            dependency_epoch_evidence: %{epoch: 42, completeness: "complete", complete?: true},
            dependency_decision: decision,
            work_control: %{}
          })
        )
      )

    assert response["success"]

    assert Jason.decode!(response["output"]) == %{
             "epoch" => "42",
             "completeness" => "complete",
             "status" => "invalidated",
             "reason" => "42",
             "blockers" => [
               %{"id" => "canceled", "identifier" => "SYM-CANCELED", "classification" => "invalidated"},
               %{"id" => "active", "identifier" => "SYM-ACTIVE", "classification" => "unavailable"},
               %{"id" => "unknown", "identifier" => nil, "classification" => "invalidated"},
               %{"id" => "unresolved", "identifier" => "SYM-UNRESOLVED", "classification" => "unavailable"}
             ]
           }

    malformed =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(work_item(:in_progress), contract(), %{
            dependency_decision: %{allowed?: false, blockers: [:not_a_blocker]}
          })
        )
      )

    refute malformed["success"]
    assert Jason.decode!(malformed["output"])["error"]["code"] == "malformed_dependency_blocker"

    incomplete_item = %{work_item(:in_progress) | dependency_completeness: {:incomplete, :stale}}

    incomplete =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route(:in_progress, "implementation"),
          semantic_context(incomplete_item, contract())
        )
      )

    refute incomplete["success"]
    assert Jason.decode!(incomplete["output"])["error"]["code"] == "dependency_epoch_unavailable"
  end

  test "dependency read rejects missing and malformed dependency decisions" do
    route = route(:in_progress, "implementation")
    work_item = work_item(:in_progress)

    for decision <- [nil, %{allowed?: true, blockers: nil}, %{allowed?: true, blockers: %{}}] do
      response =
        AgentTool.execute(
          "plane_get_dependencies",
          %{},
          host_opts(route, semantic_context(work_item, contract(), %{dependency_decision: decision}))
        )

      refute response["success"]
      assert Jason.decode!(response["output"])["error"]["code"] == "dependency_decision_unavailable"
    end

    invalid_work_control =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route,
          semantic_context(work_item, contract(), %{
            dependency_decision: %{allowed?: true, blockers: []},
            work_control: :not_a_map
          })
        )
      )

    refute invalid_work_control["success"]
    assert Jason.decode!(invalid_work_control["output"])["error"]["code"] == "dependency_decision_unavailable"
  end

  test "dependency read serializes raw blockers, scalar epochs, and scalar reasons" do
    route = route(:in_progress, "implementation")
    work_item = work_item(:in_progress)
    contract = contract()
    blocker = blocker_work_item(:done)

    known_blocker = %{
      id: blocker.id,
      identifier: blocker.identifier
    }

    known_blocker_context =
      semantic_context(work_item, contract, %{
        dependency_decision: %{
          allowed?: false,
          dependency_status: :satisfied,
          reason: :known_work_item,
          blockers: [known_blocker]
        },
        work_control: %{blocker.id => blocker}
      })

    known_blocker_response =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(route, known_blocker_context)
      )

    assert known_blocker_response["success"]

    assert Jason.decode!(known_blocker_response["output"])["blockers"] == [
             %{
               "id" => "blocker-1",
               "identifier" => "SYM-BLOCKER",
               "classification" => "satisfied"
             }
           ]

    fallback_context =
      semantic_context(work_item, contract, %{
        dependency_decision: %{
          allowed?: false,
          dependency_status: :unknown,
          reason: :fallback,
          blockers: [%{"id" => "fallback"}],
          invalidated_blockers: :not_a_list,
          unresolved_blockers: :not_a_list
        }
      })

    fallback_response =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(route, fallback_context)
      )

    assert fallback_response["success"]

    assert Jason.decode!(fallback_response["output"])["blockers"] == [
             %{"id" => "fallback", "identifier" => nil, "classification" => "unavailable"}
           ]

    for {epoch, expected} <- [
          {:epoch_atom, "epoch_atom"},
          {1.5, "1.5"},
          {{:epoch_tuple, 1}, "{:epoch_tuple, 1}"}
        ] do
      context =
        semantic_context(work_item, contract, %{
          dependency_epoch_evidence: %{epoch: epoch, completeness: :complete, complete?: true}
        })

      response = AgentTool.execute("plane_get_dependencies", %{}, host_opts(route, context))
      assert response["success"]
      assert Jason.decode!(response["output"])["epoch"] == expected
    end

    invalid_epoch =
      AgentTool.execute(
        "plane_get_dependencies",
        %{},
        host_opts(
          route,
          semantic_context(work_item, contract, %{dependency_epoch_evidence: :malformed})
        )
      )

    refute invalid_epoch["success"]
    assert Jason.decode!(invalid_epoch["output"])["error"]["code"] == "dependency_epoch_unavailable"

    for {reason, expected} <- [
          {"text_reason", "text_reason"},
          {1.5, "1.5"},
          {true, "true"},
          {%{unexpected: :shape}, "unavailable"}
        ] do
      context =
        semantic_context(work_item, contract, %{
          dependency_decision: %{
            allowed?: true,
            dependency_status: :none,
            reason: reason,
            blockers: []
          }
        })

      response = AgentTool.execute("plane_get_dependencies", %{}, host_opts(route, context))
      assert response["success"]
      assert Jason.decode!(response["output"])["reason"] == expected
    end
  end

  test "dependency read maps string and fallback dependency statuses" do
    route = route(:in_progress, "implementation")
    work_item = work_item(:in_progress)
    contract = contract()

    for status <- ["none", "satisfied", "unresolved", "unavailable"] do
      context =
        semantic_context(work_item, contract, %{
          dependency_decision: %{allowed?: true, dependency_status: status, blockers: []}
        })

      response = AgentTool.execute("plane_get_dependencies", %{}, host_opts(route, context))
      assert response["success"]
      assert Jason.decode!(response["output"])["status"] == status
    end

    for {allowed?, blockers, expected} <- [
          {true, [], "none"},
          {false, [%{"id" => "active", "state" => "In Progress"}], "unavailable"}
        ] do
      context =
        semantic_context(work_item, contract, %{
          dependency_decision: %{
            allowed?: allowed?,
            dependency_status: :unsupported,
            blockers: blockers
          }
        })

      response = AgentTool.execute("plane_get_dependencies", %{}, host_opts(route, context))
      assert response["success"]
      assert Jason.decode!(response["output"])["status"] == expected
    end
  end

  test "current work-item read serializes incomplete evidence and absent timestamps" do
    route = route(:in_progress, "implementation")
    context = semantic_context(work_item(:in_progress), contract())

    for {completeness, expected} <- [
          {{:incomplete, :stale}, %{"status" => "incomplete", "reason" => "stale"}},
          {:unexpected, "unavailable"}
        ] do
      item = %{context.work_item | dependency_completeness: completeness}
      response = AgentTool.execute("plane_get_current_work_item", %{}, host_opts(route, %{context | work_item: item}))

      assert response["success"]
      assert Jason.decode!(response["output"])["dependencyCompleteness"] == expected
    end

    observation =
      context.work_item.provider_observation
      |> Map.put(:observed_at, :not_a_datetime)
      |> Map.put(:provider_updated_at, :also_not_a_datetime)

    assessment = %{context.work_item.lifecycle_assessment | provider_observation: observation}

    item = %{
      context.work_item
      | provider_observation: observation,
        lifecycle_assessment: assessment
    }

    response =
      AgentTool.execute(
        "plane_get_current_work_item",
        %{},
        host_opts(route, %{context | work_item: item})
      )

    assert response["success"]

    assert Jason.decode!(response["output"])["providerObservation"] == %{
             "stateName" => "In Progress",
             "observedAt" => nil,
             "providerUpdatedAt" => nil
           }
  end

  test "assessment and disposition reads expose only allowlisted fields" do
    work_item = work_item(:in_progress)
    contract = contract()
    opts = host_opts(route(:in_progress, "implementation"), semantic_context(work_item, contract))

    assessment = AgentTool.execute("plane_get_lifecycle_assessment", %{}, opts)
    disposition = AgentTool.execute("plane_get_authority_disposition", %{}, opts)

    assert Map.keys(Jason.decode!(assessment["output"])) |> Enum.sort() ==
             [
               "assessedAt",
               "mappedState",
               "missingGuards",
               "reason",
               "requiredGuards",
               "status",
               "validatedState"
             ]
             |> Enum.sort()

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

  defp transition_opts(route, context, coordinator) do
    host_opts(route, context)
    |> Keyword.put(:coordinator, coordinator)
    |> Keyword.put(:agent_tool_context, %{
      route: route,
      guard_evidence: transition_guard_evidence()
    })
  end

  defp semantic_context(work_item, contract, overrides \\ %{}) do
    Map.merge(
      %{
        work_item: work_item,
        provider_project_contract: contract,
        provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract),
        dependency_decision: %{
          allowed?: true,
          dependency_status: :none,
          reason: :no_hard_dependencies,
          blockers: []
        },
        dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
      },
      overrides
    )
  end

  defp transition_coordinator(parent) do
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

  defp transition_guard_evidence do
    {:ok, attestation} =
      GuardClass.semantic_attestation(:implementation_attested, %{
        responsibility: "implementation",
        runtime_attempt_id: :transition_coordinator,
        lineage_generation: 0,
        subject: {:work_item, "work-1"},
        timestamp: DateTime.utc_now()
      })

    [
      attestation,
      %{class: :mechanical_guard, name: :implementation_checks_verified}
    ]
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
