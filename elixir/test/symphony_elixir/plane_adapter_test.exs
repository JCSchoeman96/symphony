defmodule SymphonyElixir.PlaneAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    LifecycleAssessment,
    ProviderObservation,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @settings %{
    kind: "plane",
    api_key: "secret",
    endpoint: "https://api.plane.so",
    provider: %{"workspace_slug" => "workspace-1", "workspace_id" => "workspace-stable-1", "project_id" => "project-1", "api_key" => "$PLANE_API_KEY"},
    secret_environment_names: ["PLANE_API_KEY"]
  }

  test "declares the graduated host capabilities" do
    assert Adapter.capabilities() == [
             :current_issue_refresh,
             :dependency_graph,
             :dependency_completeness,
             :controlled_transition,
             :transition_verification,
             :agent_read_tools,
             :agent_transition_tools
           ]

    assert {:ok, Adapter.capabilities()} == Capabilities.validate_adapter(Adapter)
    assert Adapter.secret_environment_names(@settings) == ["PLANE_API_KEY", "PLANE_WEBHOOK_SECRET"]
  end

  test "forwards semantic Plane tool callbacks without exposing provider scope" do
    assert Adapter.agent_tool_specs() == AgentTool.agent_tool_specs()

    assert Adapter.agent_tool_specs(%{}) == []

    specs = Adapter.agent_tool_specs(%{route: merge_route()})
    assert Enum.count(specs) == 4
    refute Enum.any?(specs, &(&1["name"] == "plane_request_lifecycle_transition"))

    encoded_specs = Jason.encode!(specs)
    refute encoded_specs =~ "workspace-stable-1"
    refute encoded_specs =~ "project-1"
    refute encoded_specs =~ "PLANE_API_KEY"
    refute encoded_specs =~ "secret"

    assert Adapter.execute_agent_tool("plane_request_lifecycle_transition", %{}, [])[
             "success"
           ] == false
  end

  test "fresh ID refresh returns factual Plane fields and performs a fresh request" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "item-1",
           "name" => "Work",
           "state" => %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"},
           "project" => "project-1",
           "workspace" => "workspace-stable-1",
           "assignees" => ["user-1"],
           "updated_at" => "2026-09-17T08:09:10Z"
         }
       }}
    end

    assert {:ok, [%Issue{} = first]} = Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, request_fun)
    assert {:ok, [%Issue{} = second]} = Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, request_fun)
    assert first.id == second.id
    assert first.workspace_id == "workspace-stable-1"
    assert first.project_id == "project-1"
    assert first.provider_state_id == "state-ready"
    assert first.provider_state_group == :unstarted
    assert first.assignee_id == "user-1"
    assert first.updated_at == ~U[2026-09-17 08:09:10Z]
    assert_receive {:request, _}
    assert_receive {:request, _}
  end

  test "caller-supplied Tracker reads cannot mint completion authority" do
    done_response = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "item-1",
           "name" => "Work",
           "state" => %{"id" => "state-done", "name" => "Done", "group" => "completed"},
           "project" => "project-1",
           "workspace" => "workspace-stable-1",
           "updated_at" => "2026-09-17T08:09:10Z"
         }
       }}
    end

    project_contract = contract()
    merge_verified = TestSupport.completion_proof_fixture("item-1", project_contract)

    assert {:ok, [%Issue{} = issue]} =
             Tracker.fetch_issues_by_ids(["item-1"],
               tracker_settings: @settings,
               request_fun: done_response
             )

    assert issue.tracker_read_observation == nil

    assert {:ok, observation} =
             ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: DateTime.utc_now()})

    refute ProviderObservation.valid_tracker_read?(observation)

    assert {:error, :provider_closure_mismatch} =
             CompletionProof.close(merge_verified, observation, project_contract)

    assert {:ok, work_item} =
             WorkItem.from_issue(issue, %{
               provider: :plane,
               prior_validated_lifecycle_state: :merging,
               evidence: [merge_verified],
               provider_project_contract: project_contract
             })

    refute WorkItem.dependency_satisfying?(work_item)

    assert {:error, :provider_observation_mismatch} =
             ProviderObservation.from_issue(
               %{issue | state: "In Progress", tracker_read_observation: observation},
               %{provider: :plane}
             )

    assert {:error, :provider_observation_mismatch} =
             ProviderObservation.from_issue(
               %{issue | tracker_read_observation: observation},
               %{provider: :memory}
             )

    refute ProviderObservation.valid_tracker_read?(:forged)
    refute ProviderObservation.fresh_tracker_read?(:forged)
  end

  test "a pre-merge Tracker Done receipt cannot revalidate completed work" do
    done_response = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "item-1",
           "name" => "Work",
           "state" => %{"id" => "state-done", "name" => "Done", "group" => "completed"},
           "project" => "project-1",
           "workspace" => "workspace-stable-1",
           "updated_at" => "2026-09-17T08:09:10Z"
         }
       }}
    end

    project_contract = contract()

    assert {:ok, [%Issue{} = pre_merge_issue]} =
             Tracker.fetch_issues_by_ids(["item-1"],
               tracker_settings: @settings,
               request_fun: done_response
             )

    merge_verified = TestSupport.completion_proof_fixture("item-1", project_contract)
    merge_verified_at = merge_verified.merge_verification.observed_at

    {:ok, unsigned_pre_merge_observation} =
      ProviderObservation.from_issue(pre_merge_issue, %{
        provider: :plane,
        observed_at: DateTime.add(merge_verified_at, -1, :second)
      })

    pre_merge_observation = TestSupport.sign_provider_observation_for_test(unsigned_pre_merge_observation)
    assert DateTime.compare(pre_merge_observation.observed_at, merge_verified_at) == :lt

    same_time_observation = %{
      pre_merge_observation
      | observed_at: merge_verified_at,
        tracker_read_signature: nil
    }

    same_time_observation = TestSupport.sign_provider_observation_for_test(same_time_observation)

    assert {:error, :provider_closure_mismatch} =
             CompletionProof.close(merge_verified, same_time_observation, project_contract)

    assert {:ok, [%Issue{} = post_merge_issue]} =
             Tracker.fetch_issues_by_ids(["item-1"],
               tracker_settings: @settings,
               request_fun: done_response
             )

    {:ok, unsigned_post_merge_observation} =
      ProviderObservation.from_issue(post_merge_issue, %{
        provider: :plane,
        observed_at: DateTime.utc_now()
      })

    post_merge_observation = TestSupport.sign_provider_observation_for_test(unsigned_post_merge_observation)
    assert DateTime.compare(post_merge_observation.observed_at, merge_verified_at) == :gt

    assert {:ok, %CompletionProof{stage: :completed} = completed_proof} =
             CompletionProof.close(merge_verified, post_merge_observation, project_contract)

    assessment =
      LifecycleAssessment.assess(pre_merge_observation, :done, [completed_proof], %{
        provider_project_contract: project_contract
      })

    assert assessment.status == :validation_required
    refute LifecycleAssessment.dependency_satisfying?(assessment)

    assert {:ok, stale_work_item} =
             WorkItem.from_issue(pre_merge_issue, %{
               provider: :plane,
               provider_observation: pre_merge_observation,
               prior_validated_lifecycle_state: :done,
               evidence: [completed_proof],
               provider_project_contract: project_contract
             })

    refute WorkItem.dependency_satisfying?(stale_work_item)
  end

  test "completion closure fails closed when merge verification time is absent or invalid" do
    done_response = fn _request ->
      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "item-1",
           "name" => "Work",
           "state" => %{"id" => "state-done", "name" => "Done", "group" => "completed"},
           "project" => "project-1",
           "workspace" => "workspace-stable-1",
           "updated_at" => "2026-09-17T08:09:10Z"
         }
       }}
    end

    project_contract = contract()

    assert {:ok, [%Issue{} = issue]} =
             Tracker.fetch_issues_by_ids(["item-1"],
               tracker_settings: @settings,
               request_fun: done_response
             )

    {:ok, unsigned_observation} =
      ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: DateTime.utc_now()})

    observation = TestSupport.sign_provider_observation_for_test(unsigned_observation)

    merge_verified = TestSupport.completion_proof_fixture("item-1", project_contract)
    malformed_timestamp = %{merge_verified.merge_verification.observed_at | year: nil}

    for observed_at <- [nil, malformed_timestamp] do
      merge_verification = %{merge_verified.merge_verification | observed_at: observed_at}

      invalid_timestamp_proof =
        %{merge_verified | merge_verification: merge_verification, source_control_signature: nil}
        |> TestSupport.sign_completion_proof_for_test()

      assert {:error, :provider_closure_mismatch} =
               CompletionProof.close(invalid_timestamp_proof, observation, project_contract)
    end
  end

  test "caller-supplied dependency graph reads do not attest Plane nodes" do
    work_item = %{
      "id" => "item-1",
      "name" => "Work",
      "state" => %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"},
      "project" => "project-1",
      "workspace" => "workspace-stable-1",
      "updated_at" => "2026-09-17T08:09:10Z"
    }

    request_fun = fn request ->
      case request.path do
        path when is_binary(path) ->
          cond do
            String.ends_with?(path, "/work-items/") ->
              {:ok,
               %{
                 status: 200,
                 body: %{
                   "results" => [work_item],
                   "count" => 1,
                   "total_results" => 1,
                   "next_page_results" => false,
                   "next_cursor" => nil
                 }
               }}

            String.ends_with?(path, "/relations/") ->
              {:ok, %{status: 200, body: %{"blocked_by" => [], "blocking" => []}}}

            true ->
              flunk("unexpected Plane request path #{path}")
          end

        _invalid_path ->
          flunk("Plane request path must be a string")
      end
    end

    assert {:ok, %Graph{} = graph} =
             Tracker.fetch_dependency_graph(tracker_settings: @settings, request_fun: request_fun)

    assert graph.nodes["item-1"].tracker_read_observation == nil
  end

  test "lists the complete project and locally filters descriptive provider states" do
    request_fun = fn request ->
      case request.path do
        "/api/v1/workspaces/workspace-1/projects/project-1/work-items/" ->
          assert request.params["fields"] ==
                   "id,name,description,priority,sequence_id,state,assignees,labels,created_at,updated_at,project,workspace"

          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [
                 %{
                   "id" => "one",
                   "name" => "One",
                   "state" => %{"id" => "s1", "name" => "Ready", "group" => "unstarted"},
                   "updated_at" => "2026-09-17T08:09:10Z",
                   "project" => "project-1",
                   "workspace" => "workspace-stable-1"
                 },
                 %{
                   "id" => "two",
                   "name" => "Two",
                   "state" => %{"id" => "s2", "name" => "In Progress", "group" => "started"},
                   "updated_at" => "2026-09-17T08:09:11Z",
                   "project" => "project-1",
                   "workspace" => "workspace-stable-1"
                 }
               ],
               "count" => 2,
               "total_results" => 2,
               "next_page_results" => false,
               "next_cursor" => nil
             }
           }}

        "/api/v1/workspaces/workspace-1/projects/project-1/states/" ->
          {:ok, %{status: 200, body: %{"results" => [], "count" => 0, "total_results" => 0, "next_page_results" => false, "next_cursor" => nil}}}
      end
    end

    assert {:ok, [%Issue{id: "one", state: "Ready"}]} =
             Adapter.fetch_issues_by_states_for_test([" ready "], @settings, request_fun)

    assert {:ok, []} = Adapter.fetch_issues_by_states_for_test([nil], @settings, request_fun)
  end

  test "does not silently accept a Plane failure as a Linear read" do
    assert {:error, :unauthorized} =
             Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, fn _request ->
               {:ok, %{status: 401, body: %{}}}
             end)
  end

  test "builds a fresh complete project snapshot from scoped project and state reads" do
    request_fun = fn request ->
      case request.path do
        "/api/v1/workspaces/workspace-1/projects/project-1/" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => "project-1",
               "name" => "Project",
               "identifier" => "PROJ",
               "description" => "Description",
               "workspace_slug" => "workspace-1"
             }
           }}

        "/api/v1/workspaces/workspace-1/projects/project-1/states/" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [
                 %{
                   "id" => "state-ready",
                   "name" => "Ready",
                   "group" => "unstarted",
                   "project" => "project-1",
                   "workspace" => "workspace-stable-1"
                 }
               ],
               "count" => 1,
               "total_results" => 1,
               "next_page_results" => false,
               "next_cursor" => nil
             }
           }}
      end
    end

    assert {:ok, snapshot} = Adapter.fetch_project_snapshot_for_test(@settings, request_fun)
    assert snapshot.provider == :plane
    assert snapshot.workspace_id == "workspace-stable-1"
    assert snapshot.project_id == "project-1"
    assert snapshot.workspace_name == nil
    assert snapshot.project_identifier == "PROJ"
    assert snapshot.project_description == "Description"
    assert snapshot.completeness == :complete

    assert hd(snapshot.states) == %{
             id: "state-ready",
             name: "Ready",
             group: :unstarted,
             project_id: "project-1",
             workspace_id: "workspace-stable-1"
           }

    assert snapshot.capability_statuses.current_issue_refresh == :supported
    assert snapshot.capability_statuses.dependency_graph == :supported
    assert snapshot.capability_statuses.dependency_completeness == :supported
    assert snapshot.capability_statuses.controlled_transition == :supported
    assert snapshot.capability_statuses.transition_verification == :supported
    assert snapshot.capability_statuses.agent_read_tools == :supported
    assert snapshot.capability_statuses.agent_transition_tools == :supported
    assert snapshot.capability_statuses.conditional_transition == :unsupported

    assert snapshot.capability_statuses == %{
             current_issue_refresh: :supported,
             dependency_graph: :supported,
             dependency_completeness: :supported,
             controlled_transition: :supported,
             transition_verification: :supported,
             agent_read_tools: :supported,
             agent_transition_tools: :supported,
             conditional_transition: :unsupported
           }
  end

  test "performs a host-only stable-UUID transition through the scoped PATCH" do
    contract = contract()
    parent = self()

    assert :ok =
             Adapter.controlled_transition_for_test(
               "item-1",
               :in_progress,
               @settings,
               contract,
               fn request ->
                 send(parent, {:request, request})
                 {:ok, %{status: 204, body: nil}}
               end
             )

    assert_receive {:request, %{method: :patch, body: %{"state" => "state-in_progress"}}}
  end

  test "does not resolve provider targets by display name or cross-scope observation" do
    contract = contract()

    request_fun = fn _request ->
      flunk("the adapter must reject before issuing a provider request")
    end

    assert {:error, :unknown_canonical_state} =
             Adapter.controlled_transition_for_test("item-1", "In Progress", @settings, contract, request_fun)

    assert {:error, :wrong_project} =
             Adapter.submit_controlled_transition(
               "item-1",
               :in_progress,
               tracker_settings: @settings,
               provider_project_contract: contract,
               pre_observation: %{work_item_id: "item-1", project_id: "other-project"},
               request_fun: request_fun
             )
  end

  test "normalizes string and atom settings while enforcing submission scope" do
    atom_settings = %{
      kind: "plane",
      api_key: "$PLANE_API_KEY",
      provider: %{
        api_key: "$PLANE_API_KEY",
        endpoint: "https://api.plane.so",
        workspace_slug: "workspace-1",
        workspace_id: "workspace-stable-1",
        project_id: "project-1"
      },
      secret_environment_names: ["CUSTOM_TOKEN", "literal"]
    }

    assert :ok = Adapter.validate_config(atom_settings)
    assert "CUSTOM_TOKEN" in Adapter.secret_environment_names(atom_settings)

    contract = contract()

    assert {:error, :provider_project_contract_required} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               request_fun: fn _request -> flunk("must reject without a contract") end
             )

    assert {:error, :invalid_provider_project_contract} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               provider_project_contract: :invalid,
               request_fun: fn _request -> flunk("must reject malformed contract") end
             )

    assert {:error, :invalid_work_item_observation} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               provider_project_contract: contract,
               pre_observation: :invalid,
               request_fun: fn _request -> flunk("must reject malformed observation") end
             )

    assert {:error, :invalid_work_item_id} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               provider_project_contract: contract,
               pre_observation: %{work_item_id: 123},
               request_fun: fn _request -> flunk("must reject malformed item id") end
             )

    assert {:error, :work_item_mismatch} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               provider_project_contract: contract,
               pre_observation: %{work_item_id: "other-item"},
               request_fun: fn _request -> flunk("must reject mismatched item id") end
             )

    assert {:error, :wrong_project} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: @settings,
               provider_project_contract: contract,
               pre_observation: %{work_item_id: "item-1", workspace_id: "other-workspace"},
               request_fun: fn _request -> flunk("must reject wrong workspace") end
             )
  end

  test "rejects a snapshot with states from multiple workspaces" do
    assert {:error, :wrong_project} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok, %{status: 200, body: %{"id" => "project-1", "workspace" => "workspace-stable-1"}}}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [
                          %{"id" => "state-1", "name" => "Ready", "group" => "unstarted", "project" => "project-1", "workspace" => "workspace-stable-1"},
                          %{"id" => "state-2", "name" => "Done", "group" => "completed", "project" => "project-1", "workspace" => "workspace-other"}
                        ],
                        "count" => 2,
                        "total_results" => 2,
                        "next_page_results" => false,
                        "next_cursor" => nil
                      }
                    }}
               end
             end)
  end

  defp contract do
    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state,
         %{
           state_id: "state-#{state}",
           name: WorkflowLifecycle.display(state)
         }}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-stable-1",
        project_id: "project-1",
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end

  defp merge_route do
    profile = Profile.default_profiles("codex app-server", 20)["merge_gatekeeper"]
    Route.new(%Issue{id: "merge-work", state: "Ready to Merge", dispatchable: true}, profile)
  end

  test "rejects a project response with a contradictory stable workspace or project ID" do
    for project <- [
          %{"id" => "project-1", "workspace_id" => "other-stable-workspace"},
          %{"id" => "project-1", "workspace" => "other-stable-workspace"},
          %{"id" => "other-project", "name" => "Project"}
        ] do
      assert {:error, :wrong_project} =
               Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
                 case request.path do
                   "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                     {:ok, %{status: 200, body: project}}

                   _states_path ->
                     {:ok, %{status: 200, body: %{"results" => [], "count" => 0, "total_results" => 0, "next_page_results" => false}}}
                 end
               end)
    end
  end

  test "rejects a fresh state snapshot whose stable workspace or project scope disagrees" do
    for state <- [
          %{"id" => "state-1", "name" => "Ready", "group" => "unstarted", "project" => "project-1", "workspace" => "other-workspace"},
          %{"id" => "state-1", "name" => "Ready", "group" => "unstarted", "project" => "other-project", "workspace" => "workspace-stable-1"},
          %{"id" => "state-1", "name" => "Ready", "group" => "unstarted", "project" => "project-1"}
        ] do
      assert {:error, reason} =
               Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
                 case request.path do
                   "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                     {:ok, %{status: 200, body: %{"id" => "project-1", "name" => "Project"}}}

                   _states_path ->
                     {:ok,
                      %{
                        status: 200,
                        body: %{
                          "results" => [state],
                          "count" => 1,
                          "total_results" => 1,
                          "next_page_results" => false,
                          "next_cursor" => nil
                        }
                      }}
                 end
               end)

      assert reason in [:wrong_project, {:provider_malformed, {:missing_scope, :workspace_id}}]
    end
  end

  test "does not accept same descriptive names or slugs with different stable IDs" do
    assert {:error, :wrong_project} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "id" => "project-1",
                        "name" => "Project",
                        "workspace_slug" => "workspace-1"
                      }
                    }}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [
                          %{
                            "id" => "state-1",
                            "name" => "Ready",
                            "group" => "unstarted",
                            "project" => %{"id" => "project-1", "name" => "Project"},
                            "workspace" => %{"id" => "workspace-recreated", "slug" => "workspace-1", "name" => "Workspace"}
                          }
                        ],
                        "count" => 1,
                        "total_results" => 1,
                        "next_page_results" => false,
                        "next_cursor" => nil
                      }
                    }}
               end
             end)
  end

  test "does not claim a complete snapshot without provider workspace evidence" do
    assert {:error, :snapshot_incomplete} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok, %{status: 200, body: %{"id" => "project-1", "name" => "Project"}}}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [],
                        "count" => 0,
                        "total_results" => 0,
                        "next_page_results" => false,
                        "next_cursor" => nil
                      }
                    }}
               end
             end)
  end

  test "uses provider project workspace evidence when the project has no states" do
    assert {:ok, snapshot} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "id" => "project-1",
                        "name" => "Project",
                        "workspace" => "workspace-stable-1"
                      }
                    }}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [],
                        "count" => 0,
                        "total_results" => 0,
                        "next_page_results" => false,
                        "next_cursor" => nil
                      }
                    }}
               end
             end)

    assert snapshot.workspace_id == "workspace-stable-1"
    assert snapshot.completeness == :complete
  end

  test "validates Plane scope, host credential references and operator endpoint boundaries" do
    assert {:error, :invalid_plane_configuration} = Adapter.validate_config(:invalid)
    assert {:error, :missing_plane_workspace_slug} = Adapter.validate_config(%{kind: "plane", api_key: "secret"})

    assert {:error, :missing_plane_project_id} =
             Adapter.validate_config(%{kind: "plane", api_key: "secret", workspace_slug: "workspace-1"})

    assert {:error, :missing_plane_workspace_id} =
             Adapter.validate_config(%{kind: "plane", api_key: "secret", workspace_slug: "workspace-1", project_id: "project-1"})

    assert {:error, :missing_plane_api_key} =
             Adapter.validate_config(%{kind: "plane", workspace_slug: "workspace-1", project_id: "project-1"})

    assert {:error, :invalid_plane_api_key_reference} =
             Adapter.validate_config(%{
               kind: "plane",
               api_key: "$OTHER_TOKEN",
               workspace_slug: "workspace-1",
               workspace_id: "workspace-stable-1",
               project_id: "project-1",
               provider: %{"api_key" => "$OTHER_TOKEN"}
             })

    assert {:error, :literal_plane_api_key_forbidden} =
             Adapter.validate_config(%{
               kind: "plane",
               api_key: "literal",
               workspace_slug: "workspace-1",
               workspace_id: "workspace-stable-1",
               project_id: "project-1",
               provider: %{"api_key" => "literal"}
             })

    assert {:error, :plane_endpoint_must_be_host_controlled} =
             Adapter.validate_config(%{@settings | endpoint: "https://other.example"})
  end

  test "fresh ID reads skip not-found items but fail malformed or foreign responses" do
    assert {:ok, []} =
             Adapter.fetch_issues_by_ids_for_test(["missing"], @settings, fn _request ->
               {:ok, %{status: 404, body: %{}}}
             end)

    assert {:error, {:provider_malformed, :missing_state}} =
             Adapter.fetch_issues_by_ids_for_test(["broken"], @settings, fn _request ->
               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "broken",
                    "project" => "project-1",
                    "workspace" => "workspace-stable-1",
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)

    assert {:error, :wrong_project} =
             Adapter.fetch_issues_by_ids_for_test(["foreign"], @settings, fn _request ->
               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "foreign",
                    "project_id" => "other-project",
                    "workspace" => "workspace-stable-1",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)

    assert {:error, :wrong_project} =
             Adapter.fetch_issues_by_ids_for_test(["foreign-workspace"], @settings, fn _request ->
               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "foreign-workspace",
                    "project_id" => "project-1",
                    "workspace_id" => "other-stable-workspace",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)
  end

  test "project listings fail closed for malformed projected items and state snapshots" do
    assert {:error, {:provider_malformed, :missing_state}} =
             Adapter.fetch_issues_by_states_for_test(["Ready"], @settings, fn request ->
               if String.ends_with?(request.path, "/work-items/"),
                 do:
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [%{"id" => "broken", "project" => "project-1", "workspace" => "workspace-stable-1", "updated_at" => "2026-09-17T08:09:10Z"}],
                        "count" => 1,
                        "total_results" => 1,
                        "next_page_results" => false
                      }
                    }},
                 else: {:ok, %{status: 200, body: %{"results" => [], "count" => 0, "total_results" => 0, "next_page_results" => false}}}
             end)

    assert {:error, {:provider_malformed, :invalid_group}} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok, %{status: 200, body: %{"id" => "project-1", "workspace" => %{"slug" => "workspace-1"}}}}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [%{"id" => "state-1", "name" => "Ready", "group" => "unknown", "project" => "project-1", "workspace" => "workspace-stable-1"}],
                        "count" => 1,
                        "total_results" => 1,
                        "next_page_results" => false
                      }
                    }}
               end
             end)
  end

  test "supports contract scope fallback and string-keyed tracker settings" do
    settings = %{
      "kind" => "plane",
      "api_key" => "secret",
      "provider" => %{"workspace_slug" => "workspace-1", "workspace_id" => "workspace-stable-1", "api_key" => "$PLANE_API_KEY"},
      "secret_environment_names" => ["PLANE_API_KEY"],
      "provider_project_contract" => %{"workspace_id" => "workspace-stable-1", "project_id" => "project-1"}
    }

    assert {:ok, [%Issue{id: "item-1"}]} =
             Adapter.fetch_issues_by_ids_for_test(["item-1"], settings, fn request ->
               assert request.path =~ "/workspaces/workspace-1/projects/project-1/"

               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "item-1",
                    "project" => "project-1",
                    "workspace" => "workspace-stable-1",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)
  end
end
