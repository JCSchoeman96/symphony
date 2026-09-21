defmodule SymphonyElixir.SourceControl.AgentToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.AgentTool
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.WorkItem

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @tree String.duplicate("c", 40)

  @config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [
      %{context: "make-all", app_id: 15_368, subject: "head"}
    ]
  }

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

  test "reviewer read uses canonical WorkItem evidence without guard_evidence keyword" do
    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    evidence = [
      %{
        class: :mechanical_guard,
        name: :candidate_state_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref),
        candidate_tree_sha: @tree,
        policy_fingerprint: policy_fingerprint()
      }
    ]

    {:ok, work_item} =
      WorkItem.from_issue(%Issue{id: "work-1", state: "In Review"}, %{
        provider: :memory,
        observed_at: ~U[2026-09-21 00:00:00Z],
        prior_validated_lifecycle_state: :in_review,
        evidence: evidence
      })

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{
          route: reviewer_route(),
          responsibility: "review",
          work_item: work_item
        },
        source_control_opts: github_opts()
      )

    assert response["success"] == true
    payload = Jason.decode!(response["output"])
    assert payload["verification_state"] == "verified"
    assert payload["candidate_sha"] == @sha_b
    assert payload["candidate_tree_sha"] == @tree
  end

  test "reviewer read fails closed when canonical WorkItem evidence is missing" do
    {:ok, work_item} =
      WorkItem.from_issue(%Issue{id: "work-1", state: "In Review"}, %{
        provider: :memory,
        observed_at: ~U[2026-09-21 00:00:00Z],
        prior_validated_lifecycle_state: :in_review,
        evidence: []
      })

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{
          route: reviewer_route(),
          responsibility: "review",
          work_item: work_item
        },
        source_control_opts: github_opts()
      )

    assert response["success"] == true
    payload = Jason.decode!(response["output"])
    assert payload["verification_state"] == "not_ready"
  end

  test "builder route cannot execute reviewer source-control read" do
    profile = Profile.default_profiles("codex app-server", 20)["builder"]

    route =
      Route.new(%Issue{id: "work-1", state: "In Progress"}, profile)

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{route: route, responsibility: "implementation"}
      )

    assert response["success"] == false
  end

  defp reviewer_route do
    profile = Profile.default_profiles("codex app-server", 20)["reviewer"]
    Route.new(%Issue{id: "work-1", state: "In Review"}, profile)
  end

  defp policy_fingerprint do
    SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
  end

  defp github_opts do
    [
      source_control_config: @config,
      settings: %{symphony: %{project_id: "project-1"}},
      token: "token",
      request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
    ]
  end

  defp github_payload(path) do
    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @sha_a}}

      String.contains?(path, "/pulls/15") ->
        %{
          "number" => 15,
          "state" => "open",
          "merged" => false,
          "draft" => false,
          "mergeable" => true,
          "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
          "base" => %{"sha" => @sha_a, "ref" => "main"}
        }

      String.contains?(path, "/compare/" <> @sha_a <> "..." <> @sha_b) ->
        %{"status" => "ahead"}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => @sha_b,
              "status" => "completed",
              "conclusion" => "success",
              "app" => %{"id" => 15_368}
            }
          ]
        }

      String.contains?(path, "/commits/" <> @sha_b) ->
        %{"commit" => %{"tree" => %{"sha" => @tree}}}

      true ->
        %{}
    end
  end
end
