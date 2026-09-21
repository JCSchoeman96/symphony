defmodule SymphonyElixir.SourceControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.WorkControl.SemanticTransitionIntent

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

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

  test "enrich adds not-applicable candidate evidence when source control is unconfigured" do
    intent = intent(:in_progress, :in_review)

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(intent, %{}, [
               %{class: :mechanical_guard, name: :implementation_checks_verified}
             ])

    assert Enum.any?(evidence, &match?(%{name: :candidate_state_verified, outcome: :not_applicable}, &1))
  end

  test "enrich captures candidate evidence from trusted host facts" do
    intent = intent(:in_progress, :in_review)

    github_opts = [
      source_control_config: @config,
      token: "token",
      request_fun: fn _token, path, _params, _opts ->
        {:ok, github_payload(path)}
      end
    ]

    command_runner = fn _workspace, command ->
      if String.contains?(command, "rev-parse") do
        {:ok, @sha_b <> "\n"}
      else
        {:ok, ""}
      end
    end

    context = %{
      repository_context: %{workspace_path: "/tmp/workspace"},
      github_opts: github_opts,
      probe_opts: [command_runner: command_runner]
    }

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(intent, context, [
               %{class: :mechanical_guard, name: :implementation_checks_verified}
             ])

    entry = Enum.find(evidence, &(&1.name == :candidate_state_verified))
    assert entry.outcome == :verified
    assert entry.candidate_ref.candidate_sha == @sha_b
  end

  test "extracts candidate ref from trusted evidence" do
    {:ok, ref} =
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
        candidate_ref: Map.from_struct(ref)
      }
    ]

    assert {:ok, extracted} = SourceControl.extract_candidate_ref(evidence)
    assert CandidateRef.equal?(extracted, ref)
  end

  test "candidate capture fails for dirty workspace" do
    intent = intent(:in_progress, :in_review)

    context = %{
      repository_context: %{workspace_path: "/tmp/ws"},
      github_opts: [source_control_config: @config],
      probe_opts: [
        command_runner: fn _workspace, command ->
          if String.contains?(command, "status --porcelain"), do: {:ok, " M file\n"}, else: {:ok, @sha_b}
        end
      ]
    }

    assert {:error, {:source_control, :dirty_workspace}} =
             SourceControl.enrich_guard_evidence(intent, context, [])
  end

  test "enrich captures candidate evidence for changes requested to in review" do
    intent = intent(:changes_requested, :in_review)

    context = %{
      repository_context: %{workspace_path: "/tmp/workspace"},
      github_opts: [
        source_control_config: @config,
        token: "token",
        request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
      ],
      probe_opts: [
        command_runner: fn _workspace, command ->
          if String.contains?(command, "rev-parse"), do: {:ok, @sha_b <> "\n"}, else: {:ok, ""}
        end
      ]
    }

    assert {:ok, evidence} = SourceControl.enrich_guard_evidence(intent, context, [])
    assert Enum.any?(evidence, &match?(%{name: :candidate_state_verified, outcome: :verified}, &1))
  end

  test "enrich adds not-applicable review acceptance when source control is unconfigured" do
    intent = intent(:in_review, :ready_to_merge)

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(intent, %{}, [
               %{class: :semantic_attestation, name: :review_accepted}
             ])

    assert Enum.any?(evidence, &match?(%{name: :review_acceptance_verified, outcome: :not_applicable}, &1))
  end

  test "policy fingerprint changes when required checks change" do
    settings = %{symphony: %{project_id: "project-1"}}

    first =
      SourceControl.policy_fingerprint_for(
        @config,
        settings
      )

    changed =
      SourceControl.policy_fingerprint_for(
        Map.put(@config, :required_checks, [
          %{context: "validate-pr-description", app_id: 15_368, subject: "head"}
        ]),
        settings
      )

    refute first == changed
  end

  defp intent(from, to) do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: from,
        requested_to: to,
        responsibility: "implementation",
        guard_evidence: []
      })

    intent
  end

  defp github_payload(path) do
    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @sha_a}}

      String.contains?(path, "/commits/" <> @sha_b <> "/pulls") ->
        [
          %{
            "number" => 15,
            "state" => "open",
            "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
            "base" => %{"sha" => @sha_a, "ref" => "main"}
          }
        ]

      String.contains?(path, "/pulls/15") ->
        %{
          "number" => 15,
          "state" => "open",
          "merged" => false,
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
        %{"commit" => %{"tree" => %{"sha" => String.duplicate("c", 40)}}}

      true ->
        %{}
    end
  end
end
