defmodule SymphonyElixir.SourceControl.MergeVerificationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Dependency.Policy
  alias SymphonyElixir.GitHub.SourceControl, as: GitHubSourceControl
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.SourceControl.MergeVerification
  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    ProviderProjectContract,
    SemanticTransitionIntent,
    WorkflowLifecycle,
    WorkItem
  }

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @sha_m String.duplicate("d", 40)
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

  test "verifies accepted ordinary two-parent merge form" do
    candidate_ref = candidate_ref()

    assert {:ok, %{merge_strategy: :ordinary}} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(ordinary_merge_payload())
             )
  end

  test "verifies accepted squash one-parent merge form" do
    candidate_ref = candidate_ref()

    assert {:ok, %{merge_strategy: :squash}} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(squash_merge_payload())
             )
  end

  test "fails closed on unsupported rebase-style merge" do
    candidate_ref = candidate_ref()

    assert {:error, :unsupported_merge_strategy} =
             GitHubSourceControl.verify_merge(
               @config,
               candidate_ref,
               @tree,
               request_opts(rebase_merge_payload())
             )
  end

  test "host verify_merge_from_evidence reports not merged pull requests" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok,
                  cond do
                    repository_payload(path) ->
                      repository_payload(path)

                    String.contains?(path, "/pulls/15") ->
                      %{"number" => 15, "merged" => false, "head" => %{"sha" => @sha_b}}

                    true ->
                      %{}
                  end}
               end
             )

    assert verification.status == :not_merged
  end

  test "host verify_merge_from_evidence with synthetic_merge checks after ordinary merge" do
    config = synthetic_merge_config()
    evidence = review_acceptance_evidence(config)

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_payload_with_checks(path, "success", :ordinary)}
               end
             )

    assert MergeVerification.verified?(verification)
    assert verification.merge_strategy == :ordinary
  end

  test "host verify_merge_from_evidence with synthetic_merge checks after squash merge" do
    config = synthetic_merge_config()
    evidence = review_acceptance_evidence(config)

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_payload_with_checks(path, "success", :squash)}
               end
             )

    assert MergeVerification.verified?(verification)
    assert verification.merge_strategy == :squash
  end

  test "host verify_merge_from_evidence requires required checks after exact merge" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_payload_with_checks(path, "success")}
               end
             )

    assert MergeVerification.verified?(verification)
  end

  test "host verify_merge_from_evidence rejects merged candidate when required checks fail" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: SourceControl.policy_fingerprint_for(@config, %{symphony: %{project_id: "project-1"}})
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}},
               token: "token",
               request_fun: fn _token, path, _params, _opts ->
                 {:ok, merged_payload_with_checks(path, "failure")}
               end
             )

    refute MergeVerification.verified?(verification)
  end

  test "host verify_merge_from_evidence rejects stale policy fingerprint" do
    evidence = [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: "sha256:deadbeef"
      }
    ]

    assert {:ok, verification} =
             SourceControl.verify_merge_from_evidence(evidence,
               source_control_config: @config,
               settings: %{symphony: %{project_id: "project-1"}}
             )

    refute MergeVerification.verified?(verification)
  end

  test "completion proof API rejects untyped and incomplete inputs" do
    refute CompletionProof.valid_evidence?(%{})
    refute CompletionProof.valid_revalidation_seed?(%{})
    refute CompletionProof.satisfies_guard?(%{}, :completion_proof_verified, %{})
    refute CompletionProof.closes_observation?(nil, nil)

    assert {:error, :invalid_merge_authorization} = CompletionProof.new_merge_authorized(nil)
    assert {:error, :invalid_merge_authorization} = CompletionProof.new_merge_authorized(%{})
    assert {:error, :invalid_merge_verification} = CompletionProof.with_merge_verification(nil, nil)
    assert {:error, :provider_closure_mismatch} = CompletionProof.close(nil, nil, nil)
  end

  test "completion proof binds source-control merge verification to a fresh Plane Done observation" do
    settings = %{symphony: %{project_id: "project-1"}}
    config = @config
    contract = provider_contract()
    policy_fingerprint = SourceControl.policy_fingerprint_for(config, settings)
    candidate = candidate_ref()

    {:ok, review_attestation} =
      GuardClass.semantic_attestation(:review_accepted, %{
        responsibility: "review",
        runtime_attempt_id: "review-attempt-1",
        lineage_generation: 1,
        subject: {:work_item, "issue-1"},
        timestamp: DateTime.utc_now()
      })

    candidate_evidence = [
      %{
        class: :mechanical_guard,
        name: :candidate_state_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate),
        candidate_tree_sha: @tree,
        policy_fingerprint: policy_fingerprint
      }
    ]

    review_context = %{
      provider_project_contract: contract,
      provider_observation: provider_observation(:in_review, "issue-1", contract),
      github_opts: source_control_opts(config, settings, :open),
      guard_evidence: candidate_evidence
    }

    review_intent = intent(:in_review, :ready_to_merge, [review_attestation])

    assert {:ok, review_evidence} =
             SourceControl.enrich_guard_evidence(review_intent, review_context, [review_attestation])

    merge_authorization_context = %{
      review_context
      | provider_observation: provider_observation(:ready_to_merge, "issue-1", contract),
        guard_evidence: review_evidence
    }

    assert {:ok, authorized_evidence} =
             SourceControl.enrich_guard_evidence(
               intent(:ready_to_merge, :merging, review_evidence),
               merge_authorization_context,
               review_evidence
             )

    authorized_proof = Enum.find(authorized_evidence, &match?(%CompletionProof{stage: :merge_authorized}, &1))
    assert %CompletionProof{stage: :merge_authorized, candidate_ref: ^candidate} = authorized_proof
    refute CompletionProof.valid_revalidation_seed?(%{authorized_proof | candidate_verification: nil})

    invalid_stage_proof = %{authorized_proof | stage: :unknown, name: nil}
    refute CompletionProof.valid_revalidation_seed?(invalid_stage_proof)

    assert {:ok, caller_created_proof} =
             CompletionProof.new_merge_authorized(%{
               work_item_id: authorized_proof.work_item_id,
               provider_project_fingerprint: authorized_proof.provider_project_fingerprint,
               workspace_id: authorized_proof.workspace_id,
               project_id: authorized_proof.project_id,
               candidate_ref: authorized_proof.candidate_ref,
               candidate_tree_sha: authorized_proof.candidate_tree_sha,
               policy_fingerprint: authorized_proof.policy_fingerprint,
               review_acceptance_evidence: authorized_proof.review_acceptance_evidence,
               review_attestation: review_attestation,
               candidate_verification: authorized_proof.candidate_verification
             })

    refute CompletionProof.valid_evidence?(caller_created_proof)

    fake_merge_verification =
      MergeVerification.new(%{
        status: :verified,
        candidate_ref: candidate,
        merge_strategy: :ordinary,
        merge_sha: @sha_m,
        merge_tree_sha: @tree,
        current_main_sha: @sha_m,
        main_contains_merge?: true
      })

    assert {:error, :invalid_merge_verification} =
             CompletionProof.with_merge_verification(caller_created_proof, fake_merge_verification)

    assert GuardClass.satisfied?(
             GuardClass.requirement(:mechanical_guard, :merge_guard_verified),
             authorized_evidence,
             %{subject: {:work_item, "issue-1"}, provider_project_contract: contract}
           )

    assert CompletionProof.satisfies_guard?(authorized_proof, :merge_guard_verified, %{})

    invalid_review_context = %{
      merge_authorization_context
      | guard_evidence:
          Enum.map(review_evidence, fn
            %{class: :semantic_attestation, name: :review_accepted} = attestation ->
              %{attestation | responsibility: "implementation"}

            evidence ->
              evidence
          end)
    }

    assert {:error, {:source_control, :verified_review_acceptance_required}} =
             SourceControl.enrich_guard_evidence(
               intent(:ready_to_merge, :merging, invalid_review_context.guard_evidence),
               invalid_review_context,
               invalid_review_context.guard_evidence
             )

    refute GuardClass.satisfied?(
             GuardClass.requirement(:mechanical_guard, :merge_guard_verified),
             [%{class: :mechanical_guard, name: :merge_guard_verified, outcome: :verified}]
           )

    completion_context = %{
      merge_authorization_context
      | provider_observation: provider_observation(:merging, "issue-1", contract),
        github_opts: source_control_opts(config, settings, :merged),
        guard_evidence: authorized_evidence
    }

    assert {:ok, merge_verified_evidence} =
             SourceControl.enrich_guard_evidence(
               intent(:merging, :done, authorized_evidence),
               completion_context,
               authorized_evidence
             )

    merge_verified = Enum.find(merge_verified_evidence, &match?(%CompletionProof{stage: :merge_verified}, &1))
    assert %CompletionProof{merge_verification: %MergeVerification{status: :verified}} = merge_verified

    assert GuardClass.satisfied?(
             GuardClass.requirement(:mechanical_guard, :completion_merge_verified),
             merge_verified,
             %{subject: {:work_item, "issue-1"}, provider_project_contract: contract}
           )

    recovered_context = %{completion_context | guard_evidence: [merge_verified]}

    assert {:ok, recovered_merge_evidence} =
             SourceControl.enrich_guard_evidence(
               intent(:merging, :done, [merge_verified]),
               recovered_context,
               [merge_verified]
             )

    assert %CompletionProof{stage: :merge_verified} =
             Enum.find(recovered_merge_evidence, &match?(%CompletionProof{stage: :merge_verified}, &1))

    done_observation = provider_observation(:done, "issue-1", contract)

    assert CompletionProof.valid_evidence?(merge_verified)
    assert {:ok, _completed} = CompletionProof.close(merge_verified, done_observation, contract)

    assessment =
      LifecycleAssessment.assess(done_observation, :merging, merge_verified_evidence, %{
        provider_project_contract: contract
      })

    assert assessment.status == :validated, inspect(assessment)
    assert LifecycleAssessment.dependency_satisfying?(assessment)

    assert %CompletionProof{stage: :completed} =
             Enum.find(assessment.satisfied_guards, &match?(%CompletionProof{stage: :completed}, &1))

    [completed_proof] = assessment.satisfied_guards
    assert CompletionProof.closes_observation?(completed_proof, Map.from_struct(done_observation))

    assert {:error, :invalid_merge_verification} =
             CompletionProof.with_merge_verification(completed_proof, completed_proof.merge_verification)

    forged_proof = %{
      completed_proof
      | issuance_signature: "sha256:" <> Base.encode16(<<0::256>>, case: :lower)
    }

    refute CompletionProof.valid_evidence?(forged_proof)
    refute GuardClass.satisfied?(GuardClass.requirement(:mechanical_guard, :completion_proof_verified), forged_proof)

    forged_source_control_proof = %{
      completed_proof
      | source_control_signature: "sha256:" <> Base.encode16(<<0::256>>, case: :lower)
    }

    refute CompletionProof.valid_evidence?(forged_source_control_proof)

    malformed_closure_signature = %{completed_proof | issuance_signature: "sha256:invalid"}
    refute CompletionProof.valid_evidence?(malformed_closure_signature)

    missing_closure_signature = %{completed_proof | issuance_signature: nil}
    refute CompletionProof.valid_evidence?(missing_closure_signature)

    later_observation = %{done_observation | observed_at: DateTime.add(done_observation.observed_at, 1, :second)}

    unchanged_done =
      LifecycleAssessment.assess(later_observation, :done, [completed_proof], %{
        provider_project_contract: contract
      })

    assert LifecycleAssessment.dependency_satisfying?(unchanged_done)

    renamed_state = %{later_observation | provider_state_name: "Finished"}

    rebound_done =
      LifecycleAssessment.assess(renamed_state, :done, [completed_proof], %{
        provider_project_contract: contract
      })

    assert rebound_done.status == :validation_required
    refute LifecycleAssessment.dependency_satisfying?(rebound_done)

    done_issue = %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      state: "Done",
      workspace_id: contract.workspace_id,
      project_id: contract.project_id,
      provider_state_id: "state-done",
      provider_state_group: :completed
    }

    assert {:ok, done_work_item} =
             WorkItem.from_issue(done_issue, %{
               provider: :plane,
               prior_validated_lifecycle_state: :done,
               evidence: assessment.satisfied_guards,
               provider_project_contract: contract
             })

    assert WorkItem.dependency_satisfying?(done_work_item)
    assert {:ok, %{status: :satisfied}} = Policy.classify_blocker(done_work_item)

    wrong_item = provider_observation(:done, "another-issue", contract)
    rejected = LifecycleAssessment.assess(wrong_item, :merging, merge_verified_evidence, %{provider_project_contract: contract})
    assert rejected.status == :validation_required
    refute LifecycleAssessment.dependency_satisfying?(rejected)
  end

  defp intent(from, to, evidence) do
    responsibility = if to == :ready_to_merge, do: "review", else: if(to == :merging, do: "merge", else: "completion")

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "issue-1",
        requested_from: from,
        requested_to: to,
        responsibility: responsibility,
        guard_evidence: evidence
      })

    intent
  end

  defp provider_observation(state, work_item_id, contract) do
    {:ok, mapping} = ProviderProjectContract.provider_mapping_for(contract, state)

    {:ok, observation} =
      ProviderObservation.new(%{
        provider: :plane,
        work_item_id: work_item_id,
        workspace_id: contract.workspace_id,
        project_id: contract.project_id,
        provider_state_id: mapping.state_id,
        provider_state_group: mapping.group,
        provider_state_name: mapping.name,
        observed_at: DateTime.utc_now()
      })

    observation
  end

  defp provider_contract do
    state_mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: "workspace-1",
        project_id: "project-1",
        state_mappings: state_mappings
      })

    contract
  end

  defp source_control_opts(config, settings, merge_state) do
    [
      source_control_config: config,
      settings: settings,
      token: "token",
      request_fun: fn _token, path, _params, _opts ->
        {:ok, completion_payload(path, merge_state)}
      end
    ]
  end

  defp completion_payload(path, merge_state) do
    case repository_payload(path) do
      nil -> completion_payload_without_repository(path, merge_state)
      payload -> payload
    end
  end

  defp completion_payload_without_repository(path, merge_state) do
    if String.contains?(path, "/git/ref/heads/main") do
      main_ref_payload(merge_state)
    else
      completion_detail_payload(path, merge_state)
    end
  end

  defp main_ref_payload(:merged), do: %{"object" => %{"sha" => @sha_m}}
  defp main_ref_payload(_merge_state), do: %{"object" => %{"sha" => @sha_a}}

  defp completion_detail_payload(path, merge_state) do
    cond do
      String.contains?(path, "/pulls/15") and merge_state == :open ->
        open_pull_payload()

      String.contains?(path, "/pulls/15") ->
        merged_pull_payload()

      String.contains?(path, "/compare/") ->
        %{"status" => "ahead"}

      String.contains?(path, "/git/commits/" <> @sha_m) ->
        merge_commit_payload()

      String.contains?(path, "/check-runs") ->
        check_runs_payload()

      String.contains?(path, "/commits/" <> @sha_b) ->
        %{"commit" => %{"tree" => %{"sha" => @tree}}}

      true ->
        %{}
    end
  end

  defp open_pull_payload do
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

  defp merged_pull_payload do
    %{"number" => 15, "merged" => true, "head" => %{"sha" => @sha_b}, "merge_commit_sha" => @sha_m}
  end

  defp merge_commit_payload do
    %{
      "sha" => @sha_m,
      "tree" => %{"sha" => @tree},
      "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
    }
  end

  defp check_runs_payload do
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
  end

  defp candidate_ref do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    ref
  end

  defp request_opts(payload_fun) do
    [
      token: "token",
      request_fun: fn _token, path, _params, _opts ->
        {:ok, payload_fun.(path)}
      end
    ]
  end

  defp repository_payload(path) do
    if String.ends_with?(path, "/repos/JCSchoeman96/symphony"),
      do: %{"id" => 1_368_436_395},
      else: nil
  end

  defp synthetic_merge_config do
    Map.put(@config, :required_checks, [
      %{context: "make-all", app_id: 15_368, subject: "synthetic_merge"}
    ])
  end

  defp review_acceptance_evidence(config) do
    [
      %{
        class: :mechanical_guard,
        name: :review_acceptance_verified,
        outcome: :verified,
        candidate_ref: Map.from_struct(candidate_ref()),
        candidate_tree_sha: @tree,
        policy_fingerprint: SourceControl.policy_fingerprint_for(config, %{symphony: %{project_id: "project-1"}})
      }
    ]
  end

  defp merged_payload_with_checks(path, conclusion, merge_strategy \\ :ordinary) do
    merge_parents =
      case merge_strategy do
        :squash -> [%{"sha" => @sha_a}]
        _ -> [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
      end

    cond do
      repository_payload(path) ->
        repository_payload(path)

      String.contains?(path, "/pulls/15") ->
        %{
          "number" => 15,
          "merged" => true,
          "head" => %{"sha" => @sha_b},
          "merge_commit_sha" => @sha_m
        }

      String.contains?(path, "/git/commits/" <> @sha_m) ->
        %{
          "sha" => @sha_m,
          "tree" => %{"sha" => @tree},
          "parents" => merge_parents
        }

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @sha_m}}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => @sha_b,
              "status" => "completed",
              "conclusion" => conclusion,
              "app" => %{"id" => 15_368}
            }
          ]
        }

      true ->
        %{}
    end
  end

  defp ordinary_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end

  defp squash_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end

  defp rebase_merge_payload do
    fn path ->
      cond do
        repository_payload(path) ->
          repository_payload(path)

        String.contains?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "merged" => true,
            "head" => %{"sha" => @sha_b},
            "merge_commit_sha" => @sha_m
          }

        String.contains?(path, "/git/commits/" <> @sha_m) ->
          %{
            "sha" => @sha_m,
            "tree" => %{"sha" => @tree},
            "parents" => [%{"sha" => @sha_a}, %{"sha" => String.duplicate("e", 40)}]
          }

        String.contains?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @sha_m}}

        true ->
          %{}
      end
    end
  end
end
