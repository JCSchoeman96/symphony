defmodule SymphonyElixir.Linear.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  test "normalizes complete issues and preserves requested page ordering" do
    issue =
      base_issue("issue-1")
      |> Map.merge(%{
        "priority" => 1,
        "assignee" => %{"id" => "worker-1"},
        "labels" => %{"nodes" => [%{"name" => " Backend "}, %{"name" => "backend"}, %{"name" => 12}]},
        "createdAt" => "2026-01-02T03:04:05Z",
        "updatedAt" => "not-a-date"
      })

    assert %{
             id: "issue-1",
             identifier: "SYM-1",
             title: "Issue issue-1",
             priority: 1,
             state: "Ready",
             assignee_id: "worker-1",
             labels: ["backend"],
             dispatchable: true,
             created_at: %DateTime{},
             updated_at: nil
           } = Client.normalize_issue_for_test(issue, "worker-1")

    first = Client.normalize_issue_for_test(base_issue("issue-1"))
    second = Client.normalize_issue_for_test(base_issue("issue-2"))

    assert ["issue-2", "issue-1"] =
             Client.merge_issue_pages_for_test([[second], [first]])
             |> Enum.map(& &1.id)

    assert Client.next_page_cursor_for_test(%{"hasNextPage" => false, "endCursor" => nil}) == :done

    assert Client.next_page_cursor_for_test(%{has_next_page: true, end_cursor: "cursor-1"}) ==
             {:ok, "cursor-1"}

    assert Client.next_page_cursor_for_test(%{has_next_page: true}) ==
             {:error, :linear_missing_end_cursor}
  end

  test "normalization fails closed for malformed records and assignee mismatches" do
    assert Client.normalize_issue_for_test(%{}) == nil

    issue = base_issue("issue-malformed")

    assert Client.normalize_issue_for_test(issue, "other-worker").dispatchable == false
    assert Client.normalize_issue_for_test(issue, " ").dispatchable == true
    assert Client.normalize_issue_for_test(issue, 123).dispatchable == true

    malformed_relations =
      Map.put(issue, "inverseRelations", %{
        "nodes" => [%{"type" => "blocks", "issue" => %{"id" => "blocker"}}],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })

    normalized = Client.normalize_issue_for_test(malformed_relations)
    assert normalized.blocked_by == []
    assert normalized.dependency_completeness == {:incomplete, :malformed_relation}

    assert Client.normalize_issue_for_test(Map.put(issue, "inverseRelations", %{"pageInfo" => %{}})).dependency_completeness ==
             {:incomplete, :missing_relation_nodes}

    assert Client.normalize_issue_for_test(Map.put(issue, "inverseRelations", %{"nodes" => []})).dependency_completeness ==
             {:incomplete, :missing_relation_page_info}

    assert Client.normalize_issue_for_test(Map.put(issue, "inverseRelations", %{"unexpected" => []})).dependency_completeness ==
             {:incomplete, :malformed_relation_connection}

    assert Client.normalize_issue_for_test(Map.put(issue, "inverseRelations", nil)).dependency_completeness ==
             {:incomplete, :malformed_relation_connection}
  end

  test "issue reads use the configured Linear endpoint and preserve the public read contract" do
    response = %{
      "data" => %{
        "issues" => %{
          "nodes" => [base_issue("issue-state")],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }

    with_http_responses([response, response, response], fn endpoint ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_endpoint: endpoint,
        tracker_api_token: "synthetic-token",
        tracker_project_slug: "synthetic-project"
      )

      assert {:ok, [%{id: "issue-state"}]} = Client.fetch_issues_by_states(["Ready", "Ready"])
      assert {:ok, [%{id: "issue-state"}]} = Client.fetch_issues_by_ids(["issue-state", "issue-state"])
      assert {:ok, [%{id: "issue-state"}]} = Client.fetch_dependency_graph()
    end)
  end

  test "configured assignee `me` resolves through the viewer query before polling" do
    viewer = %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}

    issue =
      base_issue("assigned-issue")
      |> Map.put("assignee", %{"id" => "viewer-1"})

    response = %{
      "data" => %{
        "issues" => %{
          "nodes" => [issue],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      }
    }

    with_http_responses([viewer, response], fn endpoint ->
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_endpoint: endpoint,
        tracker_api_token: "synthetic-token",
        tracker_project_slug: "synthetic-project",
        tracker_assignee: "me"
      )

      assert {:ok, [%{id: "assigned-issue", dispatchable: true}]} =
               Client.fetch_issues_by_states(["Ready"])
    end)
  end

  test "empty reads short-circuit before configuration or transport" do
    assert Client.fetch_issues_by_states([]) == {:ok, []}
    assert Client.fetch_issues_by_ids([]) == {:ok, []}

    assert Client.fetch_issues_by_ids_for_test([], fn _query, _variables -> flunk("transport called") end) ==
             {:ok, []}
  end

  test "strict issue reads return GraphQL, malformed, and transport errors" do
    graphql_error = fn _query, _variables -> {:ok, %{"errors" => [%{"message" => "bad query"}]}} end

    assert Client.fetch_issues_by_ids_for_test(["issue-1"], graphql_error) ==
             {:error, :linear_graphql_errors}

    assert Client.fetch_issues_by_ids_for_test(["issue-1"], fn _query, _variables ->
             {:ok, %{"unexpected" => true}}
           end) == {:error, :linear_unknown_payload}

    assert Client.fetch_issues_by_ids_for_test(["issue-1"], fn _query, _variables ->
             {:error, :provider_timeout}
           end) == {:error, :provider_timeout}

    malformed_issue = Map.put(base_issue("issue-1"), "title", nil)

    assert Client.fetch_issues_by_ids_for_test(["issue-1"], fn _query, _variables ->
             {:ok, %{"data" => %{"issues" => %{"nodes" => [malformed_issue]}}}}
           end) == {:error, :linear_unknown_payload}
  end

  test "dependency graph reads fail closed for malformed pages and provider errors" do
    assert Client.fetch_dependency_graph_for_test("project", fn _query, _variables ->
             {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
           end) == {:error, :linear_missing_page_info}

    assert Client.fetch_dependency_graph_for_test("project", fn _query, _variables ->
             {:ok, %{"errors" => [%{"message" => "provider rejected graph"}]}}
           end) == {:error, :linear_graphql_errors}

    assert Client.fetch_dependency_graph_for_test("project", fn _query, _variables ->
             {:ok,
              %{
                "data" => %{
                  "issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}}
                }
              }}
           end) == {:error, :linear_missing_end_cursor}

    assert Client.fetch_dependency_graph_for_test("project", fn _query, _variables ->
             {:error, :graph_timeout}
           end) == {:error, :graph_timeout}
  end

  test "relation pagination preserves every page and returns provider shape errors" do
    first =
      base_issue("issue-relations")
      |> Map.put("inverseRelations", %{
        "nodes" => [relation("blocker-1")],
        "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-1"}
      })

    graphql_fun = fn _query, variables ->
      case variables[:after] do
        "cursor-1" ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "inverseRelations" => %{
                   "nodes" => [relation("blocker-2")],
                   "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
                 }
               }
             }
           }}

        "cursor-2" ->
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "inverseRelations" => %{
                   "nodes" => [relation("blocker-3")],
                   "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                 }
               }
             }
           }}

        _ ->
          {:ok, %{"data" => %{"issues" => %{"nodes" => [first]}}}}
      end
    end

    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["issue-relations"], graphql_fun)
    assert Enum.map(issue.blocked_by, & &1.id) == ["blocker-1", "blocker-2", "blocker-3"]

    assert Client.fetch_issues_by_ids_for_test(["issue-relations"], fn _query, variables ->
             if Map.has_key?(variables, :issueId) do
               {:ok, %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => []}}}}}
             else
               {:ok, %{"data" => %{"issues" => %{"nodes" => [first]}}}}
             end
           end) == {:error, {:linear_relation_response, :missing_relation_page_info}}

    assert Client.fetch_issues_by_ids_for_test(["issue-relations"], fn _query, variables ->
             if Map.has_key?(variables, :issueId) do
               {:ok, %{"errors" => [%{"message" => "relation query failed"}]}}
             else
               {:ok, %{"data" => %{"issues" => %{"nodes" => [first]}}}}
             end
           end) == {:error, {:linear_relation_response, :linear_graphql_errors}}

    assert Client.fetch_issues_by_ids_for_test(["issue-relations"], fn _query, variables ->
             if Map.has_key?(variables, :issueId) do
               {:ok, %{"unexpected" => true}}
             else
               {:ok, %{"data" => %{"issues" => %{"nodes" => [first]}}}}
             end
           end) == {:error, {:linear_relation_response, :linear_unknown_payload}}
  end

  test "graphql reports auth, transport, and non-success status errors with bounded context" do
    assert {:error, {:linear_api_request, :missing_linear_api_token}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               tracker_settings: %{api_key: nil, endpoint: "http://unused"},
               request_fun: fn _payload, _headers -> flunk("request must not run") end
             )

    assert {:error, {:linear_api_request, :timeout}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               tracker_settings: %{api_key: "synthetic-token", endpoint: "http://unused"},
               request_fun: fn _payload, headers ->
                 assert {"Authorization", "synthetic-token"} in headers
                 {:error, :timeout}
               end
             )

    long_body = String.duplicate("x", 1_100)

    log =
      capture_log(fn ->
        assert {:error, {:linear_api_status, 503}} =
                 Client.graphql("query Viewer { viewer { id } }", %{},
                   operation_name: " Viewer ",
                   tracker_settings: %{api_key: "synthetic-token", endpoint: "http://unused"},
                   request_fun: fn payload, _headers ->
                     assert payload["operationName"] == "Viewer"
                     {:ok, %{status: 503, body: long_body}}
                   end
                 )
      end)

    assert log =~ "operation=Viewer"
    assert log =~ "...<truncated>"

    assert {:ok, %{}} =
             Client.graphql("query Viewer { viewer { id } }", %{},
               operation_name: "   ",
               tracker_settings: %{api_key: "synthetic-token", endpoint: "http://unused"},
               request_fun: fn payload, _headers ->
                 refute Map.has_key?(payload, "operationName")
                 {:ok, %{status: 200, body: %{}}}
               end
             )
  end

  defp base_issue(id, state \\ "Ready") do
    %{
      "id" => id,
      "identifier" => "SYM-#{String.replace(id, "issue-", "")}",
      "title" => "Issue #{id}",
      "description" => "Synthetic issue",
      "priority" => 2,
      "state" => %{"name" => state},
      "branchName" => "branch-#{id}",
      "url" => "https://example.invalid/#{id}",
      "assignee" => nil,
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{
        "nodes" => [],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      },
      "createdAt" => nil,
      "updatedAt" => nil
    }
  end

  defp relation(id, state \\ "Ready") do
    %{
      "type" => "blocks",
      "issue" => %{
        "id" => id,
        "identifier" => String.upcase(id),
        "state" => %{"name" => state}
      }
    }
  end

  defp with_http_responses(responses, fun) when is_list(responses) and is_function(fun, 1) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        Enum.each(responses, fn response ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          body = Jason.encode!(response)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
            )

          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
      end)

    try do
      fun.("http://127.0.0.1:#{port}/graphql")
    after
      if Process.alive?(server), do: Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end
  end
end
