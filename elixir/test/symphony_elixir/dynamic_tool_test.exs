defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool, as: BoundDynamicTool
  alias SymphonyElixir.Linear.AgentTool, as: DynamicTool

  test "tool_specs advertises read-only GraphQL and scoped transition contracts" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             },
             %{
               "inputSchema" => %{
                 "properties" => %{
                   "targetState" => _,
                   "targetStateId" => _
                 },
                 "required" => ["targetState", "targetStateId"],
                 "type" => "object"
               },
               "name" => "linear_transition"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "read-only"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{}, [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "linear_transition"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "the app-server dynamic-tool facade also supports its default options" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    binding = BoundDynamicTool.bind()

    response = BoundDynamicTool.execute("not_a_real_tool", %{}, binding)

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "Unsupported dynamic tool"
  end

  test "bound tools keep the adapter and auth snapshot from session startup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "session-token",
      tracker_project_slug: "session-project"
    )

    binding = BoundDynamicTool.bind()

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert BoundDynamicTool.bind().tool_specs == []

    test_pid = self()

    response =
      BoundDynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        binding,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:bound_linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_bound"}}}}
        end
      )

    assert_received {:bound_linear_client_called, "query Viewer { viewer { id } }", %{}, [tracker_settings: tracker_settings]}

    assert tracker_settings.api_key == "session-token"
    assert tracker_settings.project_slug == "session-project"
    assert response["success"] == true
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ", [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query BadQuery { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql rejects mutations for every responsibility" do
    for responsibility <- ["planning", "implementation", "review", "correction", "merge"] do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => "mutation SecretMutation { issueUpdate(id: \"secret-issue\") { success } }"},
          agent_tool_context: %{responsibility: responsibility},
          linear_client: fn _query, _variables, _opts -> flunk("raw GraphQL mutation must not execute") end
        )

      assert response["success"] == false
      refute response["output"] =~ "SecretMutation"
      refute response["output"] =~ "secret-issue"

      assert Jason.decode!(response["output"]) == %{
               "error" => %{
                 "code" => "lifecycle_mutation_denied",
                 "message" => "Raw Linear GraphQL mutations are disabled; use linear_transition for workflow-controlled state changes."
               }
             }
    end
  end

  test "linear_transition executes the bound current issue through the fixed mutation" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_transition",
        %{"targetState" => "In Review", "targetStateId" => "state-review"},
        agent_tool_context: %{
          issue_id: "issue-builder",
          current_issue_state: "In Progress",
          responsibility: "implementation",
          dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none}
        },
        linear_client: fn query, variables, opts ->
          if String.starts_with?(String.trim(query), "query") do
            {:ok,
             %{
               "data" => %{
                 "issues" => graph_connection("issue-builder", "In Progress"),
                 "issue" => %{
                   "team" => %{
                     "states" => %{
                       "nodes" => [%{"id" => "state-review", "name" => "In Review"}],
                       "pageInfo" => %{"hasNextPage" => false}
                     }
                   }
                 }
               }
             }}
          else
            send(test_pid, {:transition_called, query, variables, opts})
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        end
      )

    assert_received {:transition_called, query, %{"issueId" => "issue-builder", "stateId" => "state-review"}, []}
    assert query =~ "issueUpdate"
    assert response["success"] == true
  end

  test "linear_transition denies unresolved implementation work after refreshing Linear" do
    response =
      DynamicTool.execute(
        "linear_transition",
        %{"targetState" => "In Review", "targetStateId" => "state-review"},
        agent_tool_context: %{
          issue_id: "issue-blocked",
          current_issue_state: "Ready",
          responsibility: "implementation",
          dependency_decision: %{
            allowed?: false,
            dependency_status: :unresolved,
            dependency_completeness: :complete
          }
        },
        linear_client: blocked_transition_client("issue-blocked", "Ready", "In Review", "state-review")
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["code"] == "dependency_transition_denied"
  end

  test "linear_transition denies an unresolved In Review to Ready to Merge handoff" do
    response =
      DynamicTool.execute(
        "linear_transition",
        %{"targetState" => "Ready to Merge", "targetStateId" => "state-merge"},
        agent_tool_context: %{
          issue_id: "issue-review",
          current_issue_state: "In Review",
          responsibility: "review",
          dependency_decision: %{
            allowed?: true,
            merge_permitted?: false,
            dependency_status: :unresolved,
            dependency_completeness: :complete
          }
        },
        linear_client: blocked_transition_client("issue-review", "In Review", "Ready to Merge", "state-merge")
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["code"] == "dependency_transition_denied"
  end

  test "bound dynamic tools preserve transition context from session binding" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    binding =
      BoundDynamicTool.bind(
        agent_tool_context: %{
          issue_id: "issue-fixer",
          current_issue_state: "Changes Requested",
          responsibility: "correction",
          dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none}
        }
      )

    test_pid = self()

    response =
      BoundDynamicTool.execute(
        "linear_transition",
        %{"targetState" => "In Review", "targetStateId" => "state-review"},
        binding,
        linear_client: fn query, variables, _opts ->
          if String.starts_with?(String.trim(query), "query") do
            {:ok,
             %{
               "data" => %{
                 "issues" => graph_connection("issue-fixer", "Changes Requested"),
                 "issue" => %{
                   "team" => %{
                     "states" => %{
                       "nodes" => [%{"id" => "state-review", "name" => "In Review"}],
                       "pageInfo" => %{"hasNextPage" => false}
                     }
                   }
                 }
               }
             }}
          else
            send(test_pid, {:bound_transition_called, variables})
            {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
          end
        end
      )

    assert_received {:bound_transition_called, %{"issueId" => "issue-fixer", "stateId" => "state-review"}}
    assert response["success"] == true
  end

  test "linear_transition rejects malformed arguments and session context safely" do
    invalid_arguments =
      DynamicTool.execute(
        "linear_transition",
        :invalid,
        agent_tool_context: transition_context(),
        linear_client: fn _query, _variables, _opts -> flunk("invalid arguments must not call Linear") end
      )

    assert Jason.decode!(invalid_arguments["output"])["error"]["code"] ==
             "invalid_transition_arguments"

    invalid_state_id =
      DynamicTool.execute(
        "linear_transition",
        %{"targetState" => "In Review", "targetStateId" => 123},
        agent_tool_context: transition_context(),
        linear_client: fn _query, _variables, _opts -> flunk("invalid state ID must not call Linear") end
      )

    assert Jason.decode!(invalid_state_id["output"])["error"]["code"] ==
             "invalid_transition_arguments"

    invalid_issue_id =
      DynamicTool.execute(
        "linear_transition",
        transition_arguments(),
        agent_tool_context: Map.put(transition_context(), :issue_id, 123),
        linear_client: fn _query, _variables, _opts -> flunk("invalid issue context must not call Linear") end
      )

    assert Jason.decode!(invalid_issue_id["output"])["error"]["code"] ==
             "invalid_transition_context"

    missing_context =
      DynamicTool.execute(
        "linear_transition",
        transition_arguments(),
        agent_tool_context: nil,
        linear_client: fn _query, _variables, _opts -> flunk("missing context must not call Linear") end
      )

    assert Jason.decode!(missing_context["output"])["error"]["code"] ==
             "invalid_transition_context"

    policy_context_error =
      DynamicTool.execute(
        "linear_transition",
        transition_arguments(),
        agent_tool_context: Map.put(transition_context(), :responsibility, nil),
        linear_client: fn _query, _variables, _opts -> flunk("invalid policy context must not call Linear") end
      )

    assert Jason.decode!(policy_context_error["output"])["error"]["code"] ==
             "invalid_transition_context"

    unauthorized_transition =
      DynamicTool.execute(
        "linear_transition",
        transition_arguments(),
        agent_tool_context: Map.put(transition_context(), :responsibility, "planning"),
        linear_client: fn _query, _variables, _opts -> flunk("unauthorized transition must not call Linear") end
      )

    assert Jason.decode!(unauthorized_transition["output"])["error"]["code"] ==
             "unauthorized_transition"
  end

  test "linear_transition refuses unverified or incomplete workflow state data" do
    wrong_id =
      execute_transition({:ok, state_response([%{"id" => "different-state", "name" => "In Review"}])})

    assert Jason.decode!(wrong_id["output"])["error"]["code"] ==
             "transition_state_unverified"

    wrong_page =
      execute_transition(
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{"states" => %{"nodes" => [%{"id" => "state-review", "name" => "In Review"}]}}
             }
           }
         }}
      )

    assert Jason.decode!(wrong_page["output"])["error"]["code"] ==
             "transition_state_unverified"

    missing_connection = execute_transition({:ok, %{"data" => %{}}})

    assert Jason.decode!(missing_connection["output"])["error"]["code"] ==
             "transition_state_unverified"

    malformed_node =
      execute_transition({:ok, state_response([nil])})

    assert Jason.decode!(malformed_node["output"])["error"]["code"] ==
             "transition_state_unverified"

    next_page =
      execute_transition(
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "team" => %{
                 "states" => %{
                   "nodes" => [%{"id" => "state-review", "name" => "In Review"}],
                   "pageInfo" => %{"hasNextPage" => true}
                 }
               }
             }
           }
         }}
      )

    assert Jason.decode!(next_page["output"])["error"]["code"] ==
             "transition_state_unverified"
  end

  test "linear_transition reports state lookup failures and provider payload shapes" do
    string_error = execute_transition({:ok, %{"errors" => [%{"message" => "state lookup failed"}]}})
    assert Jason.decode!(string_error["output"])["error"]["code"] == "transition_state_unavailable"

    atom_error = execute_transition({:ok, %{errors: [%{message: "state lookup failed"}]}})
    assert Jason.decode!(atom_error["output"])["error"]["code"] == "transition_state_unavailable"

    atom_success =
      execute_transition(
        {:ok, atom_state_response()},
        {:ok, %{data: %{issueUpdate: %{success: true}}}}
      )

    assert atom_success["success"] == true

    string_errors =
      execute_transition(
        {:ok, state_response()},
        {:ok, %{"errors" => [%{"message" => "mutation rejected"}]}}
      )

    assert string_errors["success"] == false

    atom_errors =
      execute_transition(
        {:ok, state_response()},
        {:ok, %{errors: [%{message: "mutation rejected"}]}}
      )

    assert atom_errors["success"] == false

    non_map_response = execute_transition({:ok, state_response()}, {:ok, :ok})
    assert non_map_response["success"] == false
  end

  test "linear_transition does not expose a provider error payload" do
    response = execute_transition({:ok, state_response()}, {:error, :provider_failure})

    assert response["success"] == false
    refute response["output"] =~ "targetStateId"

    assert Jason.decode!(response["output"])["error"]["message"] ==
             "Linear GraphQL tool execution failed."
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp transition_arguments do
    %{"targetState" => "In Review", "targetStateId" => "state-review"}
  end

  defp transition_context(overrides \\ %{}) do
    Map.merge(
      %{
        issue_id: "issue-transition",
        current_issue_state: "In Progress",
        responsibility: "implementation",
        dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none}
      },
      overrides
    )
  end

  defp execute_transition(state_result, mutation_result \\ {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}, overrides \\ %{}) do
    DynamicTool.execute(
      "linear_transition",
      transition_arguments(),
      agent_tool_context: transition_context(overrides),
      linear_client: fn query, _variables, _opts ->
        cond do
          String.contains?(query, "SymphonyLinearDependencyGraph") ->
            {:ok, %{"data" => %{"issues" => graph_connection("issue-transition", "In Progress")}}}

          String.starts_with?(String.trim(query), "query") ->
            state_result

          true ->
            mutation_result
        end
      end
    )
  end

  defp state_response(nodes \\ [%{"id" => "state-review", "name" => "In Review"}]) do
    %{
      "data" => %{
        "issue" => %{
          "team" => %{
            "states" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}
          }
        }
      }
    }
  end

  defp atom_state_response do
    %{
      data: %{
        issue: %{
          team: %{
            states: %{nodes: [%{id: "state-review", name: "In Review"}], pageInfo: %{hasNextPage: false}}
          }
        }
      }
    }
  end

  defp graph_connection(id, state) do
    %{
      "nodes" => [%{"id" => id, "identifier" => id, "title" => id, "state" => %{"name" => state}, "inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}],
      "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
    }
  end

  defp blocked_transition_client(id, state, target, target_id) do
    fn query, _variables, _opts ->
      cond do
        String.contains?(query, "SymphonyLinearDependencyGraph") ->
          graph = graph_connection(id, state)
          [issue] = graph["nodes"]
          blocker = %{"type" => "blocks", "issue" => %{"id" => "blocker", "identifier" => "BLOCKER", "state" => %{"name" => "Ready"}}}
          issue = put_in(issue, ["inverseRelations", "nodes"], [blocker])
          {:ok, %{"data" => %{"issues" => %{graph | "nodes" => [issue]}}}}

        String.starts_with?(String.trim(query), "query") ->
          {:ok, state_response([%{"id" => target_id, "name" => target}])}

        true ->
          flunk("blocked transition must not execute a mutation")
      end
    end
  end
end
