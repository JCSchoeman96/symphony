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

  test "enrich leaves unrelated transitions unchanged" do
    intent = intent(:merging, :done)

    assert {:ok, evidence} =
             SourceControl.enrich_guard_evidence(intent, %{}, [
               %{class: :mechanical_guard, name: :merge_verified}
             ])

    assert evidence == [%{class: :mechanical_guard, name: :merge_verified}]
  end

  test "enrich fails closed when source control is unconfigured for candidate capture" do
    intent = intent(:in_progress, :in_review)

    assert {:error, {:source_control, :unconfigured}} =
             SourceControl.enrich_guard_evidence(intent, %{}, [
               %{class: :mechanical_guard, name: :implementation_checks_verified}
             ])
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

  test "verify merge from evidence returns mismatch when review acceptance is absent" do
    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence([], source_control_config: @config)

    refute verification.status == :verified
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

  test "enrich fails closed when source control is unconfigured for review acceptance" do
    intent = intent(:in_review, :ready_to_merge)

    assert {:error, {:source_control, :unconfigured}} =
             SourceControl.enrich_guard_evidence(intent, %{}, [
               %{class: :semantic_attestation, name: :review_accepted}
             ])
  end

  test "reconcile invalidates source-control evidence when unconfigured" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified
      }
    ]

    assert {:ok, reconciled} = SourceControl.reconcile_stored_evidence(:ready_to_merge, evidence, [])
    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :stale
    assert entry.stale_reason == :unconfigured
  end

  test "reconcile leaves non-ready states unchanged" do
    evidence = [%{class: :mechanical_guard, name: :candidate_state_verified, outcome: :verified}]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(:in_review, evidence, source_control_config: @config)

    assert reconciled == evidence
  end

  test "reconcile preserves verified review acceptance when candidate is unchanged" do
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
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: String.duplicate("c", 40),
        policy_fingerprint: policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :verified
  end

  test "reconcile marks non-verified review acceptance as missing" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :stale
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :stale
    assert entry.stale_reason == :review_acceptance_missing
  end

  test "reconcile preserves verified review acceptance after exact human merge" do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    sha_m = String.duplicate("d", 40)
    tree = String.duplicate("c", 40)

    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: tree,
        policy_fingerprint: policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_github_payload(path, sha_m, tree)}
               end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :verified
  end

  test "reconcile preserves merged review acceptance for synthetic_merge required checks" do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    sha_m = String.duplicate("d", 40)
    tree = String.duplicate("c", 40)
    synthetic_config = synthetic_merge_config()

    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: tree,
        policy_fingerprint: synthetic_policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: synthetic_config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_github_payload(path, sha_m, tree, merge_strategy: :squash)}
               end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :verified
  end

  test "reconcile invalidates merged review acceptance when required checks are no longer green" do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    sha_m = String.duplicate("d", 40)
    tree = String.duplicate("c", 40)

    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: tree,
        policy_fingerprint: policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_github_payload(path, sha_m, tree, check_conclusion: "failure")}
               end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :stale
  end

  test "reconcile still invalidates pre-merge candidate movement" do
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
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: String.duplicate("c", 40),
        policy_fingerprint: policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok,
                  if String.contains?(path, "/pulls/15") do
                    Map.put(eligible_pull(), "head", %{
                      "sha" => String.duplicate("f", 40),
                      "repo" => %{"id" => 1_368_436_395}
                    })
                  else
                    github_payload(path)
                  end}
               end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :stale
  end

  test "reconcile invalidates stale review acceptance for ready to merge" do
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
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(ref),
        candidate_tree_sha: String.duplicate("c", 40),
        policy_fingerprint: policy_fingerprint()
      }
    ]

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok,
                  if String.contains?(path, "/pulls/15") do
                    Map.put(eligible_pull(), "head", %{
                      "sha" => String.duplicate("f", 40),
                      "repo" => %{"id" => 1_368_436_395}
                    })
                  else
                    github_payload(path)
                  end}
               end
             )

    entry = Enum.find(reconciled, &(&1.name == :review_acceptance_verified))
    assert entry.outcome == :stale
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

  test "enrich review acceptance rejects policy fingerprint drift from candidate capture" do
    {:ok, ref} =
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
          candidate_ref: Map.from_struct(ref),
          candidate_tree_sha: String.duplicate("c", 40),
          policy_fingerprint: "sha256:deadbeef"
        }
      ]
    }

    assert {:error, {:source_control, :policy_fingerprint_mismatch}} =
             SourceControl.enrich_guard_evidence(
               intent,
               context,
               [%{class: :semantic_attestation, name: :review_accepted}]
             )
  end

  test "settings reject source control config without required checks" do
    intent = intent(:in_progress, :in_review)

    assert {:error, {:source_control, :required_checks_missing}} =
             SourceControl.enrich_guard_evidence(
               intent,
               %{repository_context: %{workspace_path: "/tmp/ws"}, github_opts: [source_control_config: Map.put(@config, :required_checks, [])]},
               []
             )
  end

  defp policy_fingerprint do
    SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
  end

  defp synthetic_merge_config do
    Map.put(@config, :required_checks, [
      %{context: "make-all", app_id: 15_368, subject: "synthetic_merge"}
    ])
  end

  defp synthetic_policy_fingerprint do
    SourceControl.policy_fingerprint_for(synthetic_merge_config(), %{symphony: %{project_id: "project-1"}})
  end

  defp eligible_pull do
    %{
      "number" => 15,
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "head" => %{"sha" => @sha_b, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => @sha_a, "ref" => "main"}
    }
  end

  defp merged_github_payload(path, sha_m, tree, opts \\ []) do
    check_conclusion = Keyword.get(opts, :check_conclusion, "success")
    merge_strategy = Keyword.get(opts, :merge_strategy, :ordinary)

    merge_parents =
      case merge_strategy do
        :squash -> [%{"sha" => @sha_a}]
        _ -> [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
      end

    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/pulls/15") ->
        %{
          "number" => 15,
          "merged" => true,
          "head" => %{"sha" => @sha_b},
          "merge_commit_sha" => sha_m
        }

      String.contains?(path, "/git/commits/" <> sha_m) ->
        %{
          "sha" => sha_m,
          "tree" => %{"sha" => tree},
          "parents" => merge_parents
        }

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => sha_m}}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => @sha_b,
              "status" => "completed",
              "conclusion" => check_conclusion,
              "app" => %{"id" => 15_368}
            }
          ]
        }

      true ->
        %{}
    end
  end

  defp github_payload(path) do
    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @sha_a}}

      String.contains?(path, "/commits/" <> @sha_b <> "/pulls") ->
        [eligible_pull()]

      String.contains?(path, "/pulls/15") ->
        eligible_pull()

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
