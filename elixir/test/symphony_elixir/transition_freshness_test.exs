defmodule SymphonyElixir.TransitionFreshnessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

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
    parent = self()

    DynamicTool.execute("linear_transition", %{"targetState" => "Ready to Merge", "targetStateId" => "merge"}, binding,
      linear_client: fn query, variables, client_opts ->
        cond do
          String.contains?(query, "query SymphonyLinearDependencyGraph") ->
            settings = Keyword.fetch!(client_opts, :tracker_settings)
            send(parent, {:graph_page, variables.after, variables.projectSlug, settings.api_key})

            case graph do
              {:error, _} = error ->
                error

              nodes ->
                more = Keyword.get(opts, :paginate, false) and is_nil(variables.after)

                connection = %{
                  "nodes" => if(more, do: [], else: nodes),
                  "pageInfo" => %{"hasNextPage" => more, "endCursor" => if(more, do: "next", else: nil)}
                }

                {:ok, %{"data" => %{"issues" => connection}}}
            end

          String.contains?(query, "query SymphonyAuthorizedTransitionState") ->
            {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "merge", "name" => "Ready to Merge"}], "pageInfo" => %{"hasNextPage" => false}}}}}}}

          true ->
            send(parent, :mutation)
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
        end
      end
    )
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
