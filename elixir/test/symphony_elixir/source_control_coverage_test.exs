defmodule SymphonyElixir.SourceControlCoverageTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.SourceControl, as: GitHubSourceControl
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.AgentTool
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.SourceControl.CandidateVerification
  alias SymphonyElixir.SourceControl.MergeVerification
  alias SymphonyElixir.SourceControl.RepositoryProbe
  alias SymphonyElixir.WorkControl.SemanticTransitionIntent

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @tree String.duplicate("c", 40)

  @config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [%{context: "make-all", app_id: 15_368, subject: "head"}]
  }

  test "source-control enrichment handles missing repository context and review prerequisites" do
    intent = intent(:in_progress, :in_review)

    assert {:error, {:source_control, :repository_context_unavailable}} =
             SourceControl.enrich_guard_evidence(
               intent,
               %{github_opts: [source_control_config: @config]},
               []
             )

    review_intent = intent(:in_review, :ready_to_merge)

    assert {:error, {:source_control, :candidate_state_missing}} =
             SourceControl.enrich_guard_evidence(review_intent, %{github_opts: [source_control_config: @config]}, [])
  end

  test "github source control fails closed without token and for repository mismatch" do
    assert {:error, :missing_source_control_token} =
             GitHubSourceControl.fetch_repository(@config, token: nil, request_fun: &pass_through/4)

    assert {:error, :repository_id_mismatch} =
             GitHubSourceControl.capture_candidate_ref(
               @config,
               @sha_b,
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok,
                  if(String.ends_with?(path, "/repos/JCSchoeman96/symphony"),
                    do: %{"id" => 1},
                    else: pass_through_payload(path)
                  )}
               end
             )
  end

  test "builder cannot execute reviewer source-control tool" do
    profile = Profile.default_profiles("codex app-server", 20)["builder"]
    route = Route.new(%SymphonyElixir.Tracker.Issue{id: "work-1", state: "In Progress"}, profile)

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{route: route, responsibility: "implementation"}
      )

    refute response["success"]
  end

  test "dynamic tool binding advertises reviewer source-control tool" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: "project-1",
      source_control_kind: "github",
      source_control_repository: "JCSchoeman96/symphony",
      source_control_repository_id: 1_368_436_395,
      source_control_base_branch: "main",
      source_control_token_env: "GITHUB_TOKEN",
      source_control_required_checks: [
        %{"context" => "make-all", "app_id" => 15_368, "subject" => "head"}
      ]
    )

    binding = DynamicTool.bind(agent_tool_context: %{responsibility: "review"})

    assert "source_control_read_current_candidate_status" in Enum.map(binding.tool_specs, & &1["name"])
    assert "GITHUB_TOKEN" in binding.secret_environment_names
  end

  test "workflow config rejects invalid source_control sections" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: "project-1",
      source_control_kind: "github",
      source_control_repository: "invalid",
      source_control_repository_id: 1_368_436_395,
      source_control_base_branch: "main",
      source_control_token_env: "GITHUB_TOKEN"
    )

    assert {:error, _reason} = Config.validate!()
  end

  test "workflow config validates optional source_control section" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: "project-1",
      source_control_kind: "github",
      source_control_repository: "JCSchoeman96/symphony",
      source_control_repository_id: 1_368_436_395,
      source_control_base_branch: "main",
      source_control_token_env: "GITHUB_TOKEN",
      source_control_required_checks: [
        %{"context" => "make-all", "app_id" => 15_368, "subject" => "head"}
      ]
    )

    assert :ok = Config.validate!()
    assert SourceControl.configured?()
    assert SourceControl.secret_environment_names() == ["GITHUB_TOKEN"]
  end

  test "repository probe reads a clean local workspace head" do
    workspace = Path.join(System.tmp_dir!(), "scm-probe-#{System.unique_integer()}")

    try do
      File.mkdir_p!(workspace)
      System.cmd("git", ["init"], cd: workspace)
      System.cmd("git", ["commit", "--allow-empty", "-m", "init"], cd: workspace)

      assert {:ok, %{clean?: true, head_sha: head_sha}} =
               RepositoryProbe.probe(%{workspace_path: workspace})

      assert is_binary(head_sha)
    after
      File.rm_rf(workspace)
    end
  end

  test "reviewer source-control tool returns sanitized status" do
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
        candidate_tree_sha: @tree
      }
    ]

    route = reviewer_route()

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{route: route, responsibility: "review", guard_evidence: evidence},
        source_control_opts: [
          source_control_config: @config,
          token: "token",
          request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
        ]
      )

    assert response["success"]
    payload = Jason.decode!(response["output"])
    assert payload["verification_state"] == "verified"
    assert payload["candidate_sha"] == @sha_b
  end

  test "enrich review acceptance produces verified mechanical evidence" do
    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    intent = intent(:in_review, :ready_to_merge)

    context = %{
      github_opts: [
        source_control_config: @config,
        token: "token",
        request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
      ],
      guard_evidence: [
        %{
          class: :mechanical_guard,
          name: :candidate_state_verified,
          outcome: :verified,
          candidate_ref: Map.from_struct(candidate_ref),
          candidate_tree_sha: @tree
        }
      ]
    }

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(
               intent,
               context,
               [%{class: :semantic_attestation, name: :review_accepted}]
             )

    entry = Enum.find(evidence, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :verified
  end

  test "candidate verification and merge verification structs expose helpers" do
    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    verification = CandidateVerification.new(%{status: :verified, candidate_ref: candidate_ref})
    assert verification.status == :verified

    merge = MergeVerification.new(%{status: :verified, candidate_ref: candidate_ref})
    assert MergeVerification.verified?(merge)
  end

  test "repository probe surfaces local git command failures" do
    assert {:error, {:git_command_failed, _message}} =
             RepositoryProbe.probe(
               %{workspace_path: "/definitely/missing/workspace"},
               command_runner: fn _workspace, _command -> {:error, {:git_command_failed, "boom"}} end
             )
  end

  test "repository probe handles remote workers and unavailable workspaces" do
    assert {:error, :workspace_unavailable} = RepositoryProbe.probe(%{})
    assert {:error, :workspace_unavailable} = RepositoryProbe.probe(%{workspace_path: ""})

    remote_runner = fn _host, _command, _opts ->
      {:ok, "\n" <> @sha_b}
    end

    assert {:ok, %{clean?: true, head_sha: @sha_b}} =
             RepositoryProbe.probe(
               %{workspace_path: "/tmp/workspace", worker_host: "worker-1"},
               remote_command_runner: remote_runner
             )

    refute RepositoryProbe.clean_worktree?(%{workspace_path: ""})
  end

  test "source control exposes capabilities and nil policy fingerprint when unconfigured" do
    assert is_list(SourceControl.capabilities())
    assert SourceControl.policy_fingerprint() == nil
    assert SourceControl.secret_environment_names() == []
  end

  test "candidate verification exposes verified helper" do
    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    verified = CandidateVerification.new(%{status: :verified, candidate_ref: candidate_ref})
    assert CandidateVerification.verified?(verified)
    refute CandidateVerification.verified?(CandidateVerification.new(%{status: :not_ready, candidate_ref: candidate_ref}))
  end

  test "read current candidate status reports moved candidates" do
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
        candidate_tree_sha: @tree
      }
    ]

    status =
      SourceControl.read_current_candidate_status(
        %{guard_evidence: evidence},
        source_control_config: @config,
        token: "token",
        request_fun: fn _token, path, _params, _opts ->
          {:ok,
           if String.contains?(path, "/pulls/15") do
             %{
               "number" => 15,
               "state" => "open",
               "merged" => false,
               "head" => %{"sha" => String.duplicate("f", 40), "repo" => %{"id" => 1_368_436_395}},
               "base" => %{"sha" => @sha_a, "ref" => "main"}
             }
           else
             github_payload(path)
           end}
        end
      )

    assert status.verification_state == "moved"
    assert status.candidate_unchanged? == false
  end

  test "agent tool rejects unsupported tools and unauthorized callers" do
    assert AgentTool.execute("other_tool", %{}, [])["success"] == false

    response =
      AgentTool.execute(
        AgentTool.tool_name(),
        %{},
        agent_tool_context: %{responsibility: "implementation"}
      )

    refute response["success"]
  end

  test "verify merge from evidence succeeds for verified review evidence" do
    settings = %{symphony: %{project_id: "project-1"}}
    fingerprint = SourceControl.policy_fingerprint_for(@config, settings)

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
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref),
        candidate_tree_sha: @tree,
        policy_fingerprint: fingerprint
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: settings,
               token: "token",
               request_fun: fn _token, path, _params, _opts -> {:ok, merge_payload(path)} end
             )

    assert verification.status == :verified
  end

  defp intent(from, to) do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: from,
        requested_to: to,
        responsibility: "review",
        guard_evidence: []
      })

    intent
  end

  defp reviewer_route do
    profile = Profile.default_profiles("codex app-server", 20)["reviewer"]

    Route.new(%SymphonyElixir.Tracker.Issue{id: "work-1", state: "In Review"}, profile)
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
          "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
          "base" => %{"sha" => @sha_a, "ref" => "main"}
        }

      String.contains?(path, "/compare/") ->
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

  defp pass_through(_token, _path, _params, _opts), do: {:ok, %{}}

  defp pass_through_payload(path), do: github_payload(path)

  defp merge_payload(path) do
    sha_m = String.duplicate("d", 40)

    cond do
      String.contains?(path, "/pulls/15") ->
        %{"number" => 15, "merged" => true, "head" => %{"sha" => @sha_b}, "merge_commit_sha" => sha_m}

      String.contains?(path, "/git/commits/") ->
        %{"sha" => sha_m, "tree" => %{"sha" => @tree}, "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => sha_m}}

      true ->
        %{}
    end
  end
end
