defmodule SymphonyElixir.SourceControl.AgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.SourceControl.AgentTool

  test "reviewer tool spec has empty input schema" do
    [spec] = AgentTool.agent_tool_specs(%{responsibility: "review"})
    assert spec["inputSchema"]["additionalProperties"] == false
    assert spec["inputSchema"]["properties"] == %{}
  end

  test "planner does not receive source-control tools" do
    assert AgentTool.agent_tool_specs(%{responsibility: "planning"}) == []
  end

  test "rejects selector arguments" do
    route = %Route{
      issue_id: "work-1",
      starting_state: "In Review",
      profile_name: "reviewer",
      runtime_name: "codex",
      responsibility: "review",
      fingerprint: "fp",
      starting_state_fingerprint: "sfp",
      profile: %Profile{
        name: "reviewer",
        responsibility: "review",
        runtime: "codex",
        command: "codex app-server",
        model: nil,
        prompt: "reviewer",
        sandbox: "read-only",
        max_turns: 5,
        concurrency_class: nil
      }
    }

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{"repo" => "evil"},
        agent_tool_context: %{route: route, responsibility: "review"}
      )

    assert response["success"] == false
  end
end
