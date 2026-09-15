defmodule SymphonyElixir.TrackerMemoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  setup do
    issue = %Issue{
      id: "issue-1",
      identifier: "MEM-1",
      title: "Memory issue",
      state: "In Progress",
      url: "https://memory.local/issues/issue-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    {:ok, issue: issue}
  end

  test "advertises deterministic tools and all routed capabilities" do
    assert Enum.map(Memory.agent_tool_specs(), &Map.fetch!(&1, "name")) == [
             "memory_read",
             "memory_transition"
           ]

    assert Memory.capabilities() == [
             :current_issue_refresh,
             :dependency_graph,
             :dependency_completeness,
             :controlled_transition,
             :transition_verification,
             :agent_read_tools,
             :agent_transition_tools
           ]

    assert Memory.secret_environment_names(%{}) == []
  end

  test "reads all issues, a requested issue, and a missing issue", %{issue: issue} do
    all = Memory.execute_agent_tool("memory_read", %{}, [])
    assert all["success"]
    assert [payload] = Jason.decode!(all["output"])
    assert payload["id"] == issue.id

    by_string_key = Memory.execute_agent_tool("memory_read", %{"issueId" => issue.id}, [])
    assert Jason.decode!(by_string_key["output"])["identifier"] == issue.identifier

    by_atom_key = Memory.execute_agent_tool("memory_read", %{issueId: issue.id}, [])
    assert Jason.decode!(by_atom_key["output"])["id"] == issue.id

    by_snake_case = Memory.execute_agent_tool("memory_read", %{issue_id: issue.id}, [])
    assert Jason.decode!(by_snake_case["output"])["id"] == issue.id

    missing = Memory.execute_agent_tool("memory_read", %{"issueId" => "missing"}, [])
    assert missing["success"]
    assert Jason.decode!(missing["output"]) == nil

    malformed = Memory.execute_agent_tool("memory_read", :invalid, [])
    assert Jason.decode!(malformed["output"]) == [payload]
  end

  test "applies an authorized transition and verifies the updated state", %{issue: issue} do
    response =
      Memory.execute_agent_tool(
        "memory_transition",
        %{"targetState" => " In Review "},
        agent_tool_context: %{
          issue_id: issue.id,
          responsibility: "implementation",
          dependency_decision: %{
            allowed?: true,
            dependency_completeness: :complete,
            dependency_status: :none
          }
        }
      )

    assert response["success"]
    assert Jason.decode!(response["output"])["state"] == "In Review"
    assert {:ok, [updated]} = Memory.fetch_issues_by_ids([issue.id])
    assert updated.state == "In Review"
  end

  test "fails closed for malformed transition arguments and context", %{issue: issue} do
    invalid_arguments = Memory.execute_agent_tool("memory_transition", :invalid, [])
    assert invalid_arguments["success"] == false

    blank_target = Memory.execute_agent_tool("memory_transition", %{"targetState" => "   "}, [])
    assert blank_target["success"] == false

    missing_target =
      Memory.execute_agent_tool(
        "memory_transition",
        %{},
        agent_tool_context: %{issue_id: issue.id}
      )

    assert missing_target["success"] == false

    missing_context =
      Memory.execute_agent_tool(
        "memory_transition",
        %{"target_state" => "In Review"},
        agent_tool_context: nil
      )

    assert missing_context["success"] == false

    invalid_context =
      Memory.execute_agent_tool(
        "memory_transition",
        %{"target_state" => "In Review"},
        agent_tool_context: %{issue_id: 123}
      )

    assert invalid_context["success"] == false

    unknown_issue =
      Memory.execute_agent_tool(
        "memory_transition",
        %{targetState: "In Review"},
        agent_tool_context: %{issue_id: "missing"}
      )

    assert unknown_issue["success"] == false

    unauthorized =
      Memory.execute_agent_tool(
        "memory_transition",
        %{target_state: "In Review"},
        agent_tool_context: %{
          "issue_id" => issue.id,
          "responsibility" => "review",
          "dependency_decision" => %{allowed?: true}
        }
      )

    assert unauthorized["success"] == false
  end

  test "returns a structured error for unsupported tools" do
    response = Memory.execute_agent_tool("memory_unknown", %{}, [])

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "memory_unknown".),
               "supportedTools" => ["memory_read", "memory_transition"]
             }
           }
  end

  test "filters issue reads by normalized state and id" do
    nil_state = %Issue{id: "issue-nil", state: nil}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [nil_state])

    assert {:ok, [^nil_state]} = Memory.fetch_issues_by_states(["in progress", 42])
    assert {:ok, [^nil_state]} = Memory.fetch_issues_by_ids(["issue-nil"])
    assert {:ok, [^nil_state]} = Memory.fetch_dependency_graph()
  end
end
