defmodule SymphonyElixir.RemH080CReviewProvenanceFixtures do
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.WorkControl.{ProviderObservation, ProviderProjectContract}

  @provenance_fields [
    :schema_version,
    :work_item_id,
    :provider_project_fingerprint,
    :workspace_id,
    :project_id,
    :candidate_ref,
    :candidate_tree_sha,
    :policy_fingerprint,
    :semantic_attestation_fingerprint,
    :review_responsibility,
    :review_runtime_attempt_fingerprint,
    :review_runtime_profile,
    :review_lineage_generation,
    :review_attested_at
  ]

  def review_evidence(work_item_id, %ProviderProjectContract{} = contract, config, settings, %CandidateRef{} = candidate_ref, tree_sha) do
    attested_at = DateTime.utc_now()
    lineage_generation = "review-fixture-lineage"
    runtime_attempt_id = "review-fixture-attempt"
    profile = "reviewer"

    semantic = %{
      class: :semantic_attestation,
      name: :review_accepted,
      responsibility: :review,
      runtime_attempt_id: runtime_attempt_id,
      lineage_generation: lineage_generation,
      subject: {:work_item, work_item_id},
      timestamp: attested_at
    }

    provenance = %{
      schema_version: 1,
      work_item_id: work_item_id,
      provider_project_fingerprint: ProviderProjectContract.fingerprint(contract),
      workspace_id: contract.workspace_id,
      project_id: contract.project_id,
      candidate_ref: Map.from_struct(candidate_ref),
      candidate_tree_sha: tree_sha,
      policy_fingerprint: SymphonyElixir.SourceControl.policy_fingerprint_for(config, settings),
      semantic_attestation_fingerprint: fingerprint(semantic),
      review_responsibility: :review,
      review_runtime_attempt_fingerprint:
        fingerprint(%{
          runtime_attempt_id: runtime_attempt_id,
          work_item_id: work_item_id,
          lineage_generation: lineage_generation,
          responsibility: "review",
          runtime_profile: profile
        }),
      review_runtime_profile: profile,
      review_lineage_generation: lineage_generation,
      review_attested_at: attested_at
    }

    %{
      class: :mechanical_guard,
      name: :review_acceptance_verified,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref),
      candidate_tree_sha: tree_sha,
      policy_fingerprint: provenance.policy_fingerprint,
      review_provenance: sign_provenance(provenance)
    }
  end

  def provider_observation(work_item_id, state, %ProviderProjectContract{} = contract) do
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

    sign_observation(observation)
  end

  def sign_provenance(provenance) do
    key = configured_secret()
    derived_key = :crypto.hash(:sha256, "symphony-source-control-review-provenance-v1:" <> key)
    payload = provenance |> Map.take(@provenance_fields) |> :erlang.term_to_binary()
    signature = :crypto.mac(:hmac, :sha256, derived_key, payload)
    Map.put(provenance, :signature, "sha256:" <> Base.encode16(signature, case: :lower))
  end

  defp sign_observation(%ProviderObservation{} = observation) do
    key = configured_secret()
    derived_key = :crypto.hash(:sha256, "symphony-tracker-read-v1:" <> key)
    signature = :crypto.mac(:hmac, :sha256, derived_key, ProviderObservation.tracker_read_payload(observation))

    %{observation | tracker_read_signature: "sha256:" <> Base.encode16(signature, case: :lower)}
  end

  defp configured_secret do
    Application.get_env(:symphony_elixir, :completion_proof_signing_key) ||
      SymphonyElixir.Config.settings!().tracker.api_key
  end

  defp fingerprint(term) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(term))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end
end

defmodule SymphonyElixir.RemH080CReviewRecoveryOrchestrator do
  use GenServer

  def start_link(context), do: GenServer.start_link(__MODULE__, context)

  @impl true
  def init(context), do: {:ok, context}

  @impl true
  def handle_call({:transition_context, _work_item_id, _opts}, _from, context) do
    {:reply, {:ok, context}, context}
  end
end

defmodule SymphonyElixir.RemH080CReadyToMergeReviewProvenanceTest do
  use SymphonyElixir.TestSupport, async: false

  alias SymphonyElixir.AgentRuntime.{Profile, Route, RuntimeAttempt}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity, as: RuntimeAttemptIdentity
  alias SymphonyElixir.Plane.AgentTool
  alias SymphonyElixir.RemH080CReviewProvenanceFixtures, as: ReviewProvenanceFixtures
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    GuardClass,
    ProviderObservation,
    ProviderProjectContract,
    RecoveryLedger,
    SemanticTransitionIntent,
    WorkflowLifecycle,
    WorkItem
  }

  @work_item_id "rem-h080c-review-provenance"
  @base_sha String.duplicate("a", 40)
  @candidate_sha String.duplicate("b", 40)
  @tree_sha String.duplicate("c", 40)

  @github_config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [%{context: "make-all", app_id: 15_368, subject: "head"}]
  }

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: "project-1"
    )

    :ok
  end

  test "recovered Ready to Merge review evidence authorizes merge without restoring semantic or runtime authority" do
    contract = provider_contract()
    settings = %{symphony: %{project_id: "project-1"}}
    policy_fingerprint = SourceControl.policy_fingerprint_for(@github_config, settings)
    candidate_ref = candidate_ref()

    candidate_evidence = %{
      class: :mechanical_guard,
      name: :candidate_state_verified,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref),
      candidate_tree_sha: @tree_sha,
      policy_fingerprint: policy_fingerprint
    }

    issue = tracker_issue(:in_review, contract)
    reviewer_route = route(:in_review, "review")
    reviewer_identity = RuntimeAttemptIdentity.allocate(@work_item_id, reviewer_route, "review-lineage-1")
    work_item = work_item(issue, contract, [candidate_evidence])
    transition_context = reviewer_transition_context(work_item, contract, reviewer_route, reviewer_identity)
    {orchestrator, coordinator} = start_reviewer_transition(transition_context, contract, issue)

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Ready to Merge"},
        agent_tool_context: %{route: reviewer_route, runtime_attempt_identity: reviewer_identity},
        tracker_settings: %{kind: "plane", provider: %{"workspace_id" => "workspace-1", "project_id" => "project-1"}},
        coordinator: coordinator,
        semantic_tool_context: fn _id ->
          {:ok,
           %{
             work_item: work_item,
             provider_project_contract: contract,
             runtime_attempt_identity: reviewer_identity,
             dependency_decision: %{
               allowed?: true,
               dependency_status: :none,
               dependency_completeness: :complete,
               merge_permitted?: true,
               reason: :no_hard_dependencies,
               blockers: []
             },
             dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
           }}
        end
      )

    assert response["success"]
    assert_receive {:review_transition_submitted, attempt, enriched_evidence}
    raw_review_attestation = Enum.find(attempt.guard_evidence, &match?(%{name: :review_accepted}, &1))
    assert raw_review_attestation.class == :semantic_attestation
    assert raw_review_attestation.runtime_attempt_id == reviewer_identity.runtime_attempt_id
    assert raw_review_attestation.lineage_generation == reviewer_identity.lineage_generation

    review_evidence = Enum.find(enriched_evidence, &match?(%{name: :review_acceptance_verified}, &1))
    assert review_evidence.outcome == :verified
    refute CompletionProof.valid_evidence?(raw_review_attestation)

    GenServer.stop(coordinator)
    GenServer.stop(orchestrator)

    durable_evidence =
      [candidate_evidence, review_evidence]
      |> Enum.map(fn evidence ->
        assert {:ok, persisted} = SourceControl.durable_candidate_evidence(evidence)
        persisted
      end)

    checkpoint_path = Path.join(System.tmp_dir!(), "rem-h080c-review-#{System.unique_integer([:positive])}.dets")
    tracker_identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = RecoveryLedger.open("project-1", tracker_identity, path: checkpoint_path)

    on_exit(fn ->
      RecoveryLedger.close(ledger)
      File.rm(checkpoint_path)
    end)

    checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: "project-1",
      work_item_id: @work_item_id,
      last_validated_lifecycle_state: :ready_to_merge,
      durable_guard_evidence: durable_evidence,
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }

    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    assert :ok = RecoveryLedger.close(ledger)
    {:ok, recovered_ledger} = RecoveryLedger.open("project-1", tracker_identity, path: checkpoint_path)
    on_exit(fn -> RecoveryLedger.close(recovered_ledger) end)
    assert {:ok, recovered_checkpoint} = RecoveryLedger.current(recovered_ledger, @work_item_id)
    recovered_evidence = recovered_checkpoint.durable_guard_evidence

    refute Enum.any?(recovered_evidence, &match?(%{class: :semantic_attestation}, &1))
    refute Enum.any?(recovered_evidence, &match?(%RuntimeAttempt{}, &1))
    refute Enum.any?(recovered_evidence, &Map.has_key?(&1, :runtime_attempt_id))
    assert Enum.any?(recovered_evidence, &(&1.name == :candidate_state_verified))

    ready_issue = tracker_issue(:ready_to_merge, contract)

    assessment_context = %{source_control_opts: source_control_opts(settings)}
    recovered_work_item = work_item(ready_issue, contract, recovered_evidence, assessment_context: assessment_context)

    assert recovered_work_item.validated_lifecycle_state == :ready_to_merge
    assert recovered_work_item.lifecycle_assessment.status == :validated

    assert [%{name: :review_acceptance_verified, outcome: :verified} = reconciled_review] =
             Enum.filter(recovered_work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :review_acceptance_verified))

    merge_approved = GuardClass.requirement(:human_decision, :merge_approved)

    merge_intent = %SemanticTransitionIntent{
      work_item_id: @work_item_id,
      requested_from: :ready_to_merge,
      requested_to: :merging,
      responsibility: "merge",
      guard_evidence: [merge_approved | recovered_work_item.lifecycle_assessment.satisfied_guards],
      requested_at: DateTime.utc_now()
    }

    merge_context = %{
      provider_project_contract: contract,
      provider_observation: recovered_work_item.provider_observation,
      guard_evidence: [merge_approved | recovered_work_item.lifecycle_assessment.satisfied_guards],
      github_opts: source_control_opts(settings)
    }

    assert {:ok, authorized_evidence} =
             SourceControl.enrich_guard_evidence(merge_intent, merge_context, merge_intent.guard_evidence)

    proof = Enum.find(authorized_evidence, &match?(%CompletionProof{stage: :merge_authorized}, &1))

    assert %CompletionProof{
             stage: :merge_authorized,
             review_acceptance_evidence: %{review_provenance: provenance}
           } = proof

    assert provenance.review_responsibility == :review
    assert CompletionProof.valid_evidence?(proof)
    refute is_nil(reconciled_review)
    refute Map.has_key?(provenance, :runtime_attempt_id)
  end

  test "legacy six-field review evidence and forged receipts fail closed after recovery" do
    settings = %{symphony: %{project_id: "project-1"}}
    contract = provider_contract()
    review = review_acceptance_evidence(@work_item_id, contract, @github_config, settings)

    legacy = Map.delete(review, :review_provenance)
    assert :drop = SourceControl.durable_candidate_evidence(legacy)

    assert [%{outcome: :stale, stale_reason: :review_provenance_missing}] =
             reconcile_review([legacy], @work_item_id, contract, @github_config, settings)

    forged_provenance = Map.put(review.review_provenance, :signature, "sha256:" <> String.duplicate("0", 64))
    forged_signature = Map.put(review, :review_provenance, forged_provenance)
    refute SourceControl.valid_review_provenance?(forged_provenance)
    assert :drop = SourceControl.durable_candidate_evidence(forged_signature)

    assert [%{outcome: :stale, stale_reason: :review_provenance_invalid}] =
             reconcile_review([forged_signature], @work_item_id, contract, @github_config, settings)

    forged_mechanical = Map.put(review, :candidate_tree_sha, String.duplicate("d", 40))
    assert :drop = SourceControl.durable_candidate_evidence(forged_mechanical)
  end

  test "review provenance is bound to the current work item and provider project" do
    settings = %{symphony: %{project_id: "project-1"}}
    contract = provider_contract()
    review = review_acceptance_evidence("reviewed-item", contract, @github_config, settings)

    assert [%{outcome: :stale, stale_reason: :review_provenance_binding_mismatch}] =
             reconcile_review([review], "different-item", contract, @github_config, settings)

    other_contract = provider_contract(workspace_id: "workspace-2", project_id: "project-2")

    assert [%{outcome: :stale, stale_reason: :review_provenance_binding_mismatch}] =
             reconcile_review([review], "reviewed-item", other_contract, @github_config, settings)
  end

  test "review provenance is bound to the repository and current policy checks" do
    settings = %{symphony: %{project_id: "project-1"}}
    contract = provider_contract()
    review = review_acceptance_evidence(@work_item_id, contract, @github_config, settings)
    other_repository = Map.merge(@github_config, %{repository: "another/project", repository_id: 77})

    assert [%{outcome: :stale, stale_reason: :repository_identity_mismatch}] =
             reconcile_review([review], @work_item_id, contract, other_repository, settings)

    changed_checks =
      Map.put(@github_config, :required_checks, [
        %{context: "validate-pr-description", app_id: 15_368, subject: "head"}
      ])

    assert [%{outcome: :stale, stale_reason: :policy_fingerprint_mismatch}] =
             reconcile_review([review], @work_item_id, contract, changed_checks, settings)
  end

  test "a caller-built semantic lookalike cannot pass the reviewer host transition" do
    contract = provider_contract()
    settings = %{symphony: %{project_id: "project-1"}}
    policy_fingerprint = SourceControl.policy_fingerprint_for(@github_config, settings)

    candidate = %{
      class: :mechanical_guard,
      name: :candidate_state_verified,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref()),
      candidate_tree_sha: @tree_sha,
      policy_fingerprint: policy_fingerprint
    }

    issue = tracker_issue(:in_review, contract)
    reviewer_route = route(:in_review, "review")
    identity = RuntimeAttemptIdentity.allocate(@work_item_id, reviewer_route, "review-lineage-current")
    work_item = work_item(issue, contract, [candidate])

    forged_attestation = %{
      class: :semantic_attestation,
      name: :review_accepted,
      responsibility: "review",
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_generation: identity.lineage_generation,
      subject: {:work_item, @work_item_id},
      timestamp: DateTime.utc_now()
    }

    response =
      AgentTool.execute(
        "plane_request_lifecycle_transition",
        %{"targetState" => "Ready to Merge"},
        agent_tool_context: %{
          route: reviewer_route,
          runtime_attempt_identity: identity,
          guard_evidence: [forged_attestation]
        },
        tracker_settings: %{kind: "plane", provider: %{"workspace_id" => "workspace-1", "project_id" => "project-1"}},
        semantic_tool_context: fn _id ->
          {:ok,
           %{
             work_item: work_item,
             provider_project_contract: contract,
             runtime_attempt_identity: identity,
             dependency_decision: %{
               allowed?: true,
               dependency_status: :none,
               dependency_completeness: :complete,
               merge_permitted?: true,
               reason: :no_hard_dependencies,
               blockers: []
             },
             dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true}
           }}
        end
      )

    refute response["success"]
    assert Jason.decode!(response["output"])["error"]["code"] == "required_guard_missing"
    refute Enum.any?(work_item.lifecycle_assessment.satisfied_guards, &(&1.name == :review_acceptance_verified))
  end

  test "an attestation from a stale reviewer RuntimeAttempt cannot issue provenance" do
    contract = provider_contract()
    settings = %{symphony: %{project_id: "project-1"}}
    policy_fingerprint = SourceControl.policy_fingerprint_for(@github_config, settings)

    candidate = %{
      class: :mechanical_guard,
      name: :candidate_state_verified,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref()),
      candidate_tree_sha: @tree_sha,
      policy_fingerprint: policy_fingerprint
    }

    issue = tracker_issue(:in_review, contract)
    route = route(:in_review, "review")
    current_identity = RuntimeAttemptIdentity.allocate(@work_item_id, route, "review-lineage-current")
    old_identity = RuntimeAttemptIdentity.allocate(@work_item_id, route, "review-lineage-old")
    work_item = work_item(issue, contract, [candidate])
    context = reviewer_transition_context(work_item, contract, route, current_identity)

    {:ok, stale_attestation} =
      GuardClass.semantic_attestation(:review_accepted, %{
        responsibility: "review",
        runtime_attempt_id: old_identity.runtime_attempt_id,
        lineage_generation: old_identity.lineage_generation,
        subject: {:work_item, @work_item_id},
        timestamp: DateTime.utc_now()
      })

    {:ok, stale_intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: @work_item_id,
        requested_from: :in_review,
        requested_to: :ready_to_merge,
        responsibility: "review",
        runtime_attempt_id: old_identity.runtime_attempt_id,
        lineage_generation: old_identity.lineage_generation,
        guard_evidence: [stale_attestation]
      })

    assert {:error, _reason} =
             SourceControl.enrich_guard_evidence(stale_intent, context, [stale_attestation])
  end

  defp start_reviewer_transition(context, contract, issue) do
    parent = self()
    {:ok, orchestrator} = SymphonyElixir.RemH080CReviewRecoveryOrchestrator.start_link(context)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        orchestrator: orchestrator,
        ledger: nil,
        require_durable?: false,
        refresh_contract: fn current -> {:ok, current.provider_project_contract} end,
        submit: fn attempt, current ->
          send(parent, {:review_transition_submitted, attempt, current.guard_evidence})
          set_tracker_issue(issue, :ready_to_merge, contract)
          {:ok, %{status: 204}}
        end,
        verify: fn attempt, _current -> {:verified, verified_payload(attempt, contract)} end,
        apply_verified: fn _attempt, _current -> :ok end,
        suspend: fn _work_item_id, _reason, _attempt -> :ok end
      )

    {orchestrator, coordinator}
  end

  defp reviewer_transition_context(work_item, contract, route, identity) do
    %{
      work_item: work_item,
      current_state: :in_review,
      dependency_decision: %{
        allowed?: true,
        dependency_status: :none,
        dependency_completeness: :complete,
        merge_permitted?: true
      },
      dependency_epoch_evidence: %{epoch: "epoch-1", completeness: :complete, complete?: true},
      guard_evidence: work_item.lifecycle_assessment.satisfied_guards,
      provider_observation: work_item.provider_observation,
      provider_project_contract: contract,
      provider_contract_fingerprint: ProviderProjectContract.fingerprint(contract),
      route: route,
      trusted_route: route,
      route_fingerprint: route.fingerprint,
      runtime_attempt_id: identity.runtime_attempt_id,
      lineage_id: identity.lineage_generation,
      lineage_generation: identity.lineage_generation,
      runtime_profile: identity.runtime_profile,
      responsibility: "review",
      github_opts: source_control_opts(%{symphony: %{project_id: "project-1"}})
    }
  end

  defp work_item(issue, contract, evidence, assessment_opts \\ []) do
    {:ok, state} = WorkflowLifecycle.parse(issue.state)

    {:ok, item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: state,
        evidence: evidence,
        provider_project_contract: contract,
        assessment_context: Keyword.get(assessment_opts, :assessment_context, %{})
      })

    assessment = %{
      item.lifecycle_assessment
      | status: :validated,
        validated_state: state,
        satisfied_guards: evidence
    }

    %{item | lifecycle_assessment: assessment, validated_lifecycle_state: state}
  end

  defp tracker_issue(state, contract) do
    issue = %Tracker.Issue{
      id: @work_item_id,
      identifier: "SYM-REM-H080C",
      title: "Review provenance recovery",
      state: WorkflowLifecycle.display(state),
      workspace_id: contract.workspace_id,
      project_id: contract.project_id,
      provider_state_id: "state-#{state}",
      provider_state_group: state_group(state),
      updated_at: DateTime.utc_now()
    }

    set_tracker_issue(issue, state, contract)
    Application.get_env(:symphony_elixir, :memory_tracker_issues) |> hd()
  end

  defp set_tracker_issue(issue, state, contract) do
    issue = %{
      issue
      | state: WorkflowLifecycle.display(state),
        provider_state_id: "state-#{state}",
        provider_state_group: state_group(state),
        workspace_id: contract.workspace_id,
        project_id: contract.project_id
    }

    {:ok, observation} = ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: DateTime.utc_now()})
    signed = sign_provider_observation_for_test(observation)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | tracker_read_observation: signed}])
  end

  defp candidate_ref do
    {:ok, ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @base_sha,
        candidate_sha: @candidate_sha,
        pr_identity: "15",
        observed_pr_head_sha: @candidate_sha
      })

    ref
  end

  defp provider_contract(opts \\ []) do
    mappings =
      Map.new(WorkflowLifecycle.states(), fn state ->
        {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
      end)

    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: Keyword.get(opts, :workspace_id, "workspace-1"),
        project_id: Keyword.get(opts, :project_id, "project-1"),
        state_mappings: mappings
      })

    contract
  end

  defp route(state, responsibility) do
    profile_name = %{"review" => "reviewer", "merge" => "human"}[responsibility]
    profile = Profile.default_profiles("codex app-server", 20)[profile_name]
    Route.new(%Tracker.Issue{id: @work_item_id, state: WorkflowLifecycle.display(state)}, profile)
  end

  defp source_control_opts(settings) do
    [
      source_control_config: @github_config,
      settings: settings,
      token: "test-token",
      request_fun: fn _token, path, _params, _opts -> {:ok, github_payload(path)} end
    ]
  end

  defp review_acceptance_evidence(work_item_id, contract, config, settings) do
    ReviewProvenanceFixtures.review_evidence(
      work_item_id,
      contract,
      config,
      settings,
      candidate_ref(),
      @tree_sha
    )
  end

  defp reconcile_review(evidence, work_item_id, contract, config, settings) do
    opts =
      source_control_opts(settings)
      |> Keyword.put(:source_control_config, config)
      |> Keyword.put(:subject, {:work_item, work_item_id})
      |> Keyword.put(:provider_project_contract, contract)
      |> Keyword.put(
        :provider_observation,
        ReviewProvenanceFixtures.provider_observation(work_item_id, :ready_to_merge, contract)
      )

    assert {:ok, reconciled} = SourceControl.reconcile_stored_evidence(:ready_to_merge, evidence, opts)
    Enum.filter(reconciled, &(&1.name == :review_acceptance_verified))
  end

  defp github_payload(path) do
    cond do
      String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
        %{"id" => 1_368_436_395}

      String.contains?(path, "/git/ref/heads/main") ->
        %{"object" => %{"sha" => @base_sha}}

      String.contains?(path, "/commits/#{@candidate_sha}/pulls") ->
        [eligible_pull()]

      String.contains?(path, "/pulls/15") ->
        eligible_pull()

      String.contains?(path, "/compare/#{@base_sha}...#{@candidate_sha}") ->
        %{"status" => "ahead"}

      String.contains?(path, "/check-runs") ->
        %{
          "total_count" => 1,
          "check_runs" => [
            %{
              "name" => "make-all",
              "head_sha" => @candidate_sha,
              "status" => "completed",
              "conclusion" => "success",
              "app" => %{"id" => 15_368}
            }
          ]
        }

      String.contains?(path, "/commits/#{@candidate_sha}") ->
        %{"commit" => %{"tree" => %{"sha" => @tree_sha}}}

      true ->
        %{}
    end
  end

  defp eligible_pull do
    %{
      "number" => 15,
      "state" => "open",
      "merged" => false,
      "draft" => false,
      "mergeable" => true,
      "head" => %{"sha" => @candidate_sha, "repo" => %{"id" => 1_368_436_395}},
      "base" => %{"sha" => @base_sha, "ref" => "main"}
    }
  end

  defp verified_payload(attempt, contract) do
    %{
      assessment: %{status: :validated, validated_state: attempt.requested_to},
      post_observation_evidence: %{
        workspace_id: contract.workspace_id,
        project_id: contract.project_id,
        work_item_id: attempt.work_item_id,
        provider_state_id: "state-#{attempt.requested_to}",
        observed_at: DateTime.utc_now()
      },
      post_contract_fingerprint: ProviderProjectContract.fingerprint(contract)
    }
  end

  defp state_group(state) when state in [:backlog, :planning, :ready], do: :unstarted
  defp state_group(:done), do: :completed
  defp state_group(:canceled), do: :cancelled
  defp state_group(_state), do: :started
end
