defmodule SymphonyElixir.DependencyCompletenessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dependency.{Graph, Guard}

  defmodule FinalRefreshLinearClient do
    alias SymphonyElixir.Tracker.Issue

    def fetch_issues_by_states(_states), do: {:ok, [candidate([])]}
    def fetch_issues_by_ids(_ids), do: {:ok, [candidate([])]}

    def fetch_dependency_graph do
      case Process.get(:final_refresh_graph_calls, 0) do
        0 ->
          Process.put(:final_refresh_graph_calls, 1)
          {:ok, [candidate([])]}

        _ ->
          {:ok, [candidate([%{id: "late-blocker", identifier: "SYM-LATE-BLOCKER", state: "In Progress"}]), blocker()]}
      end
    end

    defp candidate(blocked_by) do
      %Issue{
        id: "final-refresh-candidate",
        identifier: "SYM-FINAL-REFRESH",
        title: "Final refresh candidate",
        state: "Ready",
        dispatchable: true,
        blocked_by: blocked_by
      }
    end

    defp blocker do
      %Issue{
        id: "late-blocker",
        identifier: "SYM-LATE-BLOCKER",
        title: "Late blocker",
        state: "In Progress",
        dispatchable: false
      }
    end
  end

  test "linear relation pagination retains every blocker and filters mixed relation types" do
    first_blockers = Enum.map(1..50, &relation(&1, "blocks"))
    second_blockers = Enum.map(51..55, &relation(&1, "blocks"))

    raw_issue = linear_issue("issue-dependent")

    raw_issue =
      Map.put(raw_issue, "inverseRelations", %{
        "nodes" => first_blockers ++ [relation(999, "relatesTo")],
        "pageInfo" => %{"hasNextPage" => true, "endCursor" => "relation-cursor-1"}
      })

    graphql_fun = fn _query, variables ->
      if Map.has_key?(variables, :issueId) do
        assert variables.after == "relation-cursor-1"

        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "inverseRelations" => %{
                 "nodes" => second_blockers,
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      else
        {:ok, %{"data" => %{"issues" => %{"nodes" => [raw_issue]}}}}
      end
    end

    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["issue-dependent"], graphql_fun)
    assert Enum.map(issue.blocked_by, & &1.id) == Enum.map(1..55, &"blocker-#{&1}")
    assert Map.get(issue, :dependency_completeness) == :complete
  end

  test "linear relation data is incomplete when page information is absent or malformed" do
    missing_page_info =
      linear_issue("missing-page-info")
      |> Map.put("inverseRelations", %{"nodes" => []})

    malformed_page_info =
      linear_issue("malformed-page-info")
      |> Map.put("inverseRelations", %{
        "nodes" => [],
        "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}
      })

    assert %{id: "missing-page-info"} = Client.normalize_issue_for_test(missing_page_info)
    assert %{id: "malformed-page-info"} = Client.normalize_issue_for_test(malformed_page_info)

    assert Map.get(Client.normalize_issue_for_test(missing_page_info), :dependency_completeness) ==
             {:incomplete, :missing_relation_page_info}

    assert Map.get(Client.normalize_issue_for_test(malformed_page_info), :dependency_completeness) ==
             {:incomplete, :missing_relation_end_cursor}
  end

  test "an explicitly empty Linear relation connection is complete" do
    issue =
      linear_issue("empty-relations")
      |> Map.put("inverseRelations", %{
        "nodes" => [],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })
      |> Client.normalize_issue_for_test()

    assert issue.blocked_by == []
    assert Map.get(issue, :dependency_completeness) == :complete
  end

  test "a relation with missing blocker state is incomplete even when the page is terminal" do
    issue =
      linear_issue("malformed-relation")
      |> Map.put("inverseRelations", %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "blocker-1",
              "identifier" => "SYM-BLOCKER-1",
              "state" => %{}
            }
          }
        ],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })
      |> Client.normalize_issue_for_test()

    assert issue.blocked_by == []
    assert Map.get(issue, :dependency_completeness) == {:incomplete, :malformed_relation}
  end

  test "linear relation page errors are returned instead of becoming an empty blocker list" do
    raw_issue =
      linear_issue("relation-error")
      |> Map.put("inverseRelations", %{
        "nodes" => [relation(1, "blocks")],
        "pageInfo" => %{"hasNextPage" => true, "endCursor" => "relation-cursor-1"}
      })

    graphql_fun = fn _query, variables ->
      if Map.has_key?(variables, :issueId) do
        {:error, :relation_timeout}
      else
        {:ok, %{"data" => %{"issues" => %{"nodes" => [raw_issue]}}}}
      end
    end

    assert {:error, {:linear_relation_request, :relation_timeout}} =
             Client.fetch_issues_by_ids_for_test(["relation-error"], graphql_fun)
  end

  test "linear full dependency graph paginates all project issues independent of active states" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_page_ids = Enum.take(issue_ids, 50)
    second_page_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn id ->
      linear_issue(id)
      |> Map.put("state", %{"name" => "Backlog"})
      |> Map.put("inverseRelations", %{
        "nodes" => [],
        "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
      })
    end

    graphql_fun = fn query, variables ->
      assert query =~ "SymphonyLinearDependencyGraph"
      ids = if variables.after == "project-cursor-1", do: second_page_ids, else: first_page_ids

      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => Enum.map(ids, raw_issue),
             "pageInfo" => %{
               "hasNextPage" => variables.after != "project-cursor-1",
               "endCursor" => if(variables.after == "project-cursor-1", do: nil, else: "project-cursor-1")
             }
           }
         }
       }}
    end

    assert {:ok, issues} = Client.fetch_dependency_graph_for_test("test-project", graphql_fun)
    assert Enum.map(issues, & &1.id) == issue_ids
  end

  test "incomplete dependency metadata prevents implementation even when blockers look empty" do
    issue =
      %Issue{
        id: "incomplete-dependency",
        identifier: "SYM-INCOMPLETE",
        state: "Ready",
        blocked_by: [],
        dispatchable: true
      }
      |> Map.put(:dependency_completeness, {:incomplete, :missing_relation_page_info})

    decision = Guard.evaluate(issue, "implementation")

    refute decision.allowed?
    assert decision.reason == :dependency_data_incomplete
    assert decision.dependency_completeness == {:incomplete, :missing_relation_page_info}
  end

  test "memory poll builds the dependency graph from inactive closure nodes" do
    candidate = %Issue{
      id: "active-cycle",
      identifier: "SYM-ACTIVE-CYCLE",
      title: "Active cycle member",
      state: "Ready",
      dispatchable: true,
      blocked_by: [%{id: "backlog-cycle", identifier: "SYM-BACKLOG-CYCLE", state: "Backlog"}]
    }

    inactive = %Issue{
      id: "backlog-cycle",
      identifier: "SYM-BACKLOG-CYCLE",
      title: "Inactive cycle member",
      state: "Backlog",
      dispatchable: false,
      blocked_by: [%{id: "active-cycle", identifier: "SYM-ACTIVE-CYCLE", state: "Ready"}]
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [candidate, inactive])

    state = %Orchestrator.State{
      poll_interval_ms: 60_000,
      max_concurrent_agents: 10,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
    }

    {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert Graph.cycles(updated_state.dependency_graph) == [["active-cycle", "backlog-cycle"]]
    assert updated_state.dependency_graph.diagnostics == []

    if is_reference(updated_state.tick_timer_ref), do: Process.cancel_timer(updated_state.tick_timer_ref)
  end

  test "final graph refresh denies a candidate whose blocker appears after selection" do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FinalRefreshLinearClient)
    Process.delete(:final_refresh_graph_calls)

    on_exit(fn ->
      Process.delete(:final_refresh_graph_calls)

      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_active_states: ["Ready"],
      poll_interval_ms: 60_000
    )

    state = %Orchestrator.State{
      poll_interval_ms: 60_000,
      max_concurrent_agents: 10,
      task_supervisor: SymphonyElixir.TaskSupervisor,
      agent_runner: SymphonyElixir.AgentRouterOrchestratorRunnerFake
    }

    {:noreply, updated_state} = Orchestrator.handle_info(:run_poll_cycle, state)

    assert updated_state.running == %{}
    refute MapSet.member?(updated_state.claimed, "final-refresh-candidate")

    assert updated_state.dependency_diagnostics["final-refresh-candidate"].reason ==
             :unresolved_hard_dependency

    if is_reference(updated_state.tick_timer_ref), do: Process.cancel_timer(updated_state.tick_timer_ref)
  end

  defp linear_issue(id) do
    %{
      "id" => id,
      "identifier" => "SYM-#{id}",
      "title" => "Dependency fixture",
      "description" => "",
      "priority" => 2,
      "state" => %{"name" => "Ready"},
      "assignee" => nil,
      "labels" => %{"nodes" => []},
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }
  end

  defp relation(index, type) do
    %{
      "type" => type,
      "issue" => %{
        "id" => "blocker-#{index}",
        "identifier" => "SYM-BLOCKER-#{index}",
        "state" => %{"name" => "In Progress"}
      }
    }
  end
end
