defmodule SymphonyElixir.TransitionFreshnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.AgentTool
  alias SymphonyElixir.WorkControl.WorkItem

  test "a bound transition rejects a terminal issue from the fresh graph" do
    binding = session_binding()
    assert response(binding, [raw_issue("issue", "Canceled")])["success"] == false
    refute_received :mutation
  end

  test "a bound transition rejects newly unresolved or incomplete dependencies" do
    for graph <- [
          [raw_issue("issue", "In Review", [relation("blocker", "Ready")]), raw_issue("blocker", "Ready")],
          [Map.delete(raw_issue("issue", "In Review"), "inverseRelations")],
          [raw_issue("issue", "In Review", [relation("missing", "Done")])],
          [raw_issue("issue", "In Review", [relation("issue", "Done")])],
          []
        ] do
      assert response(session_binding(), graph)["success"] == false
      refute_received :mutation
    end
  end

  test "a fresh forward provider observation cannot replace the trusted lifecycle state" do
    binding =
      DynamicTool.bind(
        agent_tool_context: %{
          issue_id: "issue",
          current_issue_state: "In Progress",
          responsibility: "implementation",
          dependency_decision: %{
            allowed?: true,
            dependency_completeness: :complete,
            dependency_status: :none
          }
        }
      )

    assert response(binding, [raw_issue("issue", "In Review")])["success"] == false
    refute_received :mutation
  end

  test "a bound validated WorkItem supplies canonical context to the fresh Linear read" do
    {:ok, work_item} =
      WorkItem.from_issue(%Issue{id: "issue", state: "In Review"}, %{
        provider: :linear,
        observed_at: ~U[2026-09-16 00:00:00Z],
        prior_validated_lifecycle_state: :in_review
      })

    binding =
      DynamicTool.bind(
        agent_tool_context: %{
          issue_id: "issue",
          current_issue_state: "In Review",
          responsibility: "review",
          work_item: work_item,
          work_control: %{"issue" => work_item},
          dependency_decision: %{
            allowed?: true,
            dependency_completeness: :complete,
            dependency_status: :none,
            merge_permitted?: true
          }
        }
      )

    assert response(binding, [raw_issue("issue", "In Review")])["success"] == true
    assert_received :mutation
  end

  test "routed transition rejects raw provider state without trusted canonical context" do
    assert routed_response([raw_issue("issue", "In Review")])["success"] == false
    refute_received :mutation
  end

  test "routed transition accepts an explicitly trusted canonical host state" do
    context = %{
      issue_id: "issue",
      current_issue_state: "In Review",
      trusted_lifecycle_state: :in_review,
      responsibility: "review",
      dependency_decision: %{
        allowed?: true,
        dependency_completeness: :complete,
        dependency_status: :none,
        merge_permitted?: true
      }
    }

    assert routed_response([raw_issue("issue", "In Review")], context)["success"] == true
    assert_received :mutation
  end

  test "a legal forward observation without handoff evidence remains validation required" do
    assert response(session_binding(), [raw_issue("issue", "Ready to Merge")])["success"] == false
    refute_received :mutation
  end

  test "an unknown fresh provider state remains lifecycle invalid" do
    assert response(session_binding(), [raw_issue("issue", "Mystery")])["success"] == false
    refute_received :mutation
  end

  test "transition fails closed on fresh graph errors" do
    assert response(session_binding(), {:error, :timeout})["success"] == false
    refute_received :mutation
  end

  test "review handoff uses resolved dependencies rather than its stale bound decision" do
    binding = session_binding()

    context = %{
      binding.agent_tool_context
      | dependency_decision: %{
          allowed?: true,
          dependency_completeness: :complete,
          dependency_status: :unresolved,
          merge_permitted?: false
        }
    }

    binding = %{binding | agent_tool_context: context}
    assert response(binding, [raw_issue("issue", "In Review")])["success"] == true
    assert_received :mutation
  end

  test "transition keeps bound provider settings across workflow reload and paginates" do
    binding = session_binding()
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert response(binding, [raw_issue("issue", "In Review")], paginate: true)["success"] == true
    assert_received {:graph_page, nil, "project", "token"}
    assert_received {:graph_page, "next", "project", "token"}
    assert_received :mutation
  end

  test "one bound session cannot issue a second handoff even if provider reads lag" do
    binding = session_binding()
    graph = [raw_issue("issue", "In Review")]
    assert response(binding, graph)["success"] == true
    assert_received :mutation
    assert response(binding, graph)["success"] == false
    refute_received :mutation
  end

  defp session_binding do
    DynamicTool.bind(
      agent_tool_context: %{
        issue_id: "issue",
        current_issue_state: "In Review",
        responsibility: "review",
        dependency_decision: %{
          allowed?: true,
          dependency_completeness: :complete,
          dependency_status: :none,
          merge_permitted?: true
        }
      }
    )
  end

  defp response(binding, graph, opts \\ []) do
    target_state = Keyword.get(opts, :target_state, "Ready to Merge")
    target_state_id = if target_state == "In Review", do: "review", else: "merge"
    arguments = %{"targetState" => target_state, "targetStateId" => target_state_id}

    DynamicTool.execute(
      "linear_transition",
      arguments,
      binding,
      linear_client: transition_client(graph, opts, target_state, target_state_id)
    )
  end

  defp routed_response(
         graph,
         context \\ %{
           issue_id: "issue",
           current_issue_state: "In Review",
           responsibility: "review",
           dependency_decision: %{
             allowed?: true,
             dependency_completeness: :complete,
             dependency_status: :none,
             merge_permitted?: true
           }
         }
       ) do
    target_state = "Ready to Merge"
    target_state_id = "merge"

    AgentTool.execute(
      "linear_transition",
      %{"targetState" => target_state, "targetStateId" => target_state_id},
      agent_routing: "routed",
      agent_tool_context: context,
      tracker_settings: Config.settings!().tracker,
      linear_client: transition_client(graph, [], target_state, target_state_id)
    )
  end

  defp transition_client(graph, opts, target_state, target_state_id) do
    parent = self()

    fn query, variables, client_opts ->
      cond do
        String.contains?(query, "query SymphonyLinearDependencyGraph") ->
          graph_response(graph, opts, parent, variables, client_opts)

        String.contains?(query, "query SymphonyAuthorizedTransitionState") ->
          transition_state_response(target_state, target_state_id)

        true ->
          send(parent, :mutation)
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      end
    end
  end

  defp graph_response({:error, _} = error, _opts, parent, variables, client_opts) do
    send_graph_page(parent, variables, client_opts)
    error
  end

  defp graph_response(nodes, opts, parent, variables, client_opts) do
    send_graph_page(parent, variables, client_opts)
    more = Keyword.get(opts, :paginate, false) and is_nil(variables.after)

    connection = %{
      "nodes" => if(more, do: [], else: nodes),
      "pageInfo" => %{"hasNextPage" => more, "endCursor" => if(more, do: "next", else: nil)}
    }

    {:ok, %{"data" => %{"issues" => connection}}}
  end

  defp send_graph_page(parent, variables, client_opts) do
    settings = Keyword.fetch!(client_opts, :tracker_settings)
    send(parent, {:graph_page, variables.after, variables.projectSlug, settings.api_key})
  end

  defp transition_state_response(target_state, target_state_id) do
    state_name = if target_state == "In Review", do: "In Review", else: "Ready to Merge"

    {:ok,
     %{
       "data" => %{
         "issue" => %{
           "team" => %{
             "states" => %{
               "nodes" => [%{"id" => target_state_id, "name" => state_name}],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }
     }}
  end

  defp raw_issue(id, state, relations \\ []) do
    %{
      "id" => id,
      "identifier" => id,
      "title" => id,
      "state" => %{"name" => state},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => relations, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
    }
  end

  defp relation(id, state), do: %{"type" => "blocks", "issue" => %{"id" => id, "identifier" => id, "state" => %{"name" => state}}}
end
