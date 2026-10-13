defmodule SymphonyElixir.RemH080CCandidateEvidenceRecoveryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    ProviderProjectContract,
    RecoveryLedger,
    WorkflowLifecycle,
    WorkItem
  }

  @base_sha String.duplicate("a", 40)
  @candidate_sha String.duplicate("b", 40)
  @moved_sha String.duplicate("d", 40)
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
      symphony_project_id: "rem-h080c-01"
    )

    root = Path.join(System.tmp_dir!(), "rem-h080c01-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "recovery.dets")

    {:ok, ledger} =
      RecoveryLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        path: path
      )

    on_exit(fn ->
      RecoveryLedger.close(ledger)
      File.rm_rf(root)
    end)

    {:ok, ledger: ledger}
  end

  test "candidate-bound evidence keeps its bounded identity across recovery refresh", %{ledger: ledger} do
    issue = %Issue{id: "rem-h080c01-review", state: "In Review"}
    candidate_state = candidate_evidence(:candidate_state_verified)
    review_acceptance = candidate_evidence(:review_acceptance_verified) |> Map.put(:verification, %{status: :verified})
    checkpoint = checkpoint(issue.id, :in_review, [candidate_state, review_acceptance])

    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)

    state = %State{
      recovery_ledger: ledger,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{issue.id => checkpoint},
      startup_reconciliation: :ready
    }

    refreshed_state = Orchestrator.refresh_work_control_for_test(state, [issue])
    work_item = refreshed_state.work_control[issue.id]

    assert %WorkItem{} = work_item
    assert {:ok, restored_checkpoint} = RecoveryLedger.current(ledger, issue.id)

    expected_candidate_state = Map.take(candidate_state, durable_candidate_fields())
    expected_review_acceptance = Map.take(review_acceptance, durable_candidate_fields())

    assert restored_checkpoint.durable_guard_evidence == [expected_candidate_state, expected_review_acceptance]
    assert work_item.lifecycle_assessment.satisfied_guards == [expected_candidate_state, expected_review_acceptance]

    for evidence <- restored_checkpoint.durable_guard_evidence do
      assert Map.keys(evidence) |> Enum.sort() == Enum.sort(durable_candidate_fields())
      assert is_map(evidence.candidate_ref)
      refute is_struct(evidence.candidate_ref)
      assert evidence.candidate_ref.candidate_sha == @candidate_sha
    end

    assert Enum.map(work_item.lifecycle_assessment.satisfied_guards, & &1.candidate_ref.candidate_sha) ==
             [@candidate_sha, @candidate_sha]
  end

  test "recovered WorkItem exposes candidate identity to the next Reviewer", %{ledger: ledger} do
    issue = %Issue{id: "rem-h080c01-second-reviewer", state: "In Review"}
    candidate_state = candidate_evidence(:candidate_state_verified)
    checkpoint = checkpoint(issue.id, :in_review, [candidate_state])

    refreshed_state = refresh_work_item(ledger, issue, checkpoint)
    work_item = refreshed_state.work_control[issue.id]

    assert [%{name: :candidate_state_verified, candidate_ref: %{candidate_sha: @candidate_sha}}] =
             work_item.lifecycle_assessment.satisfied_guards
  end

  test "validated CandidateRef structs are persisted as plain maps", %{ledger: ledger} do
    issue = %Issue{id: "candidate-ref-struct-input", state: "In Review"}

    evidence =
      candidate_evidence(:candidate_state_verified)
      |> Map.put(:candidate_ref, candidate_ref())

    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint(issue.id, :in_review, [evidence]))

    assert [%{candidate_ref: persisted_ref} = persisted_evidence] = refreshed_checkpoint.durable_guard_evidence
    assert persisted_evidence.candidate_tree_sha == @tree_sha
    assert is_map(persisted_ref)
    refute is_struct(persisted_ref)
    assert persisted_ref.candidate_sha == @candidate_sha
  end

  test "malformed CandidateRefs are dropped for both candidate-bound guards", %{ledger: ledger} do
    valid_ref = candidate_evidence(:candidate_state_verified).candidate_ref

    malformed_refs = [
      Map.put(valid_ref, :candidate_sha, @moved_sha),
      Map.put(valid_ref, :repository_identity, "not-a-github-repository"),
      Map.put(valid_ref, :base_sha, "invalid-sha"),
      Map.put(valid_ref, :pr_identity, "not-a-pr-number"),
      nil
    ]

    for name <- [:candidate_state_verified, :review_acceptance_verified], malformed_ref <- malformed_refs do
      evidence = candidate_evidence(name)

      evidence =
        if is_nil(malformed_ref),
          do: Map.delete(evidence, :candidate_ref),
          else: Map.put(evidence, :candidate_ref, malformed_ref)

      assert_dropped_after_refresh(ledger, "malformed-ref-#{name}-#{inspect(malformed_ref)}", [evidence], name)
    end
  end

  test "malformed candidate trees are dropped for both candidate-bound guards", %{ledger: ledger} do
    for name <- [:candidate_state_verified, :review_acceptance_verified] do
      evidence = Map.put(candidate_evidence(name), :candidate_tree_sha, "not-a-tree-sha")

      assert_dropped_after_refresh(ledger, "malformed-tree-#{name}", [evidence], name)
    end
  end

  test "legacy reduced candidate tokens are removed during checkpoint refresh", %{ledger: ledger} do
    issue = %Issue{id: "legacy-candidate-evidence", state: "In Review"}

    evidence = [
      %{class: :mechanical_guard, name: :candidate_state_verified, outcome: :verified},
      %{class: :mechanical_guard, name: :review_acceptance_verified, outcome: :verified}
    ]

    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint(issue.id, :in_review, evidence))

    refute Enum.any?(refreshed_checkpoint.durable_guard_evidence, &(&1.name in candidate_guard_names()))
  end

  test "candidate movement after recovery makes review acceptance stale", %{ledger: ledger} do
    settings = %{symphony: %{project_id: "rem-h080c-01"}}
    policy_fingerprint = SourceControl.policy_fingerprint_for(@github_config, settings)

    review_acceptance =
      candidate_evidence(:review_acceptance_verified)
      |> Map.put(:policy_fingerprint, policy_fingerprint)
      |> Map.put(:verification, %{status: :verified})

    issue = %Issue{id: "candidate-moved-after-recovery", state: "In Review"}
    checkpoint = checkpoint(issue.id, :in_review, [review_acceptance])
    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint)

    assert [recovered_review_acceptance] = refreshed_checkpoint.durable_guard_evidence
    assert recovered_review_acceptance.candidate_ref.candidate_sha == @candidate_sha

    assert {:ok, reconciled} =
             SourceControl.reconcile_stored_evidence(
               :ready_to_merge,
               [recovered_review_acceptance],
               source_control_config: @github_config,
               settings: settings,
               token: "token",
               request_fun: &moved_candidate_payload/4
             )

    assert [%{outcome: :stale, stale_reason: :candidate_moved}] = reconciled
  end

  test "ordinary, dispatch, semantic, and human evidence keep existing durability rules", %{ledger: ledger} do
    issue = %Issue{id: "durability-controls", state: "In Review"}

    ordinary = %{
      class: :mechanical_guard,
      name: :implementation_checks_verified,
      outcome: :verified,
      report: %{checks: ["one"]}
    }

    dispatch = %{class: :mechanical_guard, name: :dispatch_guard, outcome: :verified}
    semantic = %{class: :semantic_attestation, name: :review_accepted, subject: {:work_item, issue.id}}
    human = %{class: :human_decision, name: :merge_approved, outcome: :approved}
    candidate = candidate_evidence(:candidate_state_verified)
    checkpoint = checkpoint(issue.id, :in_review, [ordinary, dispatch, semantic, human, candidate])

    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint)

    assert [ordinary_evidence, candidate_evidence] = refreshed_checkpoint.durable_guard_evidence
    assert ordinary_evidence == Map.take(ordinary, [:class, :name, :outcome])
    refute Enum.any?(refreshed_checkpoint.durable_guard_evidence, &(&1.name == :dispatch_guard))
    refute Enum.any?(refreshed_checkpoint.durable_guard_evidence, &(&1.class == :semantic_attestation))
    refute Enum.any?(refreshed_checkpoint.durable_guard_evidence, &(&1.class == :human_decision))
    assert candidate_evidence.candidate_ref.candidate_sha == @candidate_sha
  end

  test "valid CompletionProof remains typed and complete through checkpoint refresh", %{ledger: ledger} do
    issue = %Issue{id: "typed-completion-proof", state: "Merging"}
    proof = completion_proof_fixture(issue.id, provider_contract())
    checkpoint = checkpoint(issue.id, :merging, [proof])

    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint)

    assert [%CompletionProof{} = restored_proof] = refreshed_checkpoint.durable_guard_evidence
    assert restored_proof == proof
    assert CompletionProof.valid_evidence?(restored_proof)
  end

  defp candidate_evidence(name) do
    candidate_ref = candidate_ref()

    %{
      class: :mechanical_guard,
      name: name,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref),
      candidate_tree_sha: @tree_sha,
      policy_fingerprint: "sha256:recovery-test"
    }
  end

  defp candidate_ref do
    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: String.duplicate("a", 40),
        candidate_sha: @candidate_sha,
        pr_identity: "15",
        observed_pr_head_sha: @candidate_sha
      })

    candidate_ref
  end

  defp checkpoint(work_item_id, lifecycle_state, evidence) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: Config.settings!().symphony.project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: lifecycle_state,
      durable_guard_evidence: evidence,
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }
  end

  defp durable_candidate_fields do
    [:class, :name, :outcome, :candidate_ref, :candidate_tree_sha, :policy_fingerprint]
  end

  defp assert_dropped_after_refresh(ledger, work_item_id, evidence, expected_name) do
    issue = %Issue{id: work_item_id, state: "In Review"}
    refreshed_checkpoint = refresh_checkpoint(ledger, issue, checkpoint(issue.id, :in_review, evidence))

    refute Enum.any?(refreshed_checkpoint.durable_guard_evidence, &(&1.name == expected_name))
  end

  defp refresh_checkpoint(ledger, %Issue{} = issue, checkpoint) do
    _refreshed_state = refresh_work_item(ledger, issue, checkpoint)
    assert {:ok, refreshed_checkpoint} = RecoveryLedger.current(ledger, issue.id)
    refreshed_checkpoint
  end

  defp refresh_work_item(ledger, %Issue{} = issue, checkpoint) do
    seed_checkpoint = %{
      checkpoint
      | durable_guard_evidence:
          Enum.filter(checkpoint.durable_guard_evidence, fn
            %CompletionProof{} -> true
            %{class: :mechanical_guard} -> true
            _other -> false
          end)
    }

    assert :ok = RecoveryLedger.put_sync(ledger, seed_checkpoint)

    state = %State{
      recovery_ledger: ledger,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{issue.id => checkpoint},
      startup_reconciliation: :ready
    }

    refreshed_state = Orchestrator.refresh_work_control_for_test(state, [issue])
    assert %WorkItem{} = refreshed_state.work_control[issue.id]
    refreshed_state
  end

  defp candidate_guard_names, do: [:candidate_state_verified, :review_acceptance_verified]

  defp moved_candidate_payload(_token, path, _params, _opts) do
    payload =
      cond do
        String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
          %{"id" => 1_368_436_395}

        String.ends_with?(path, "/git/ref/heads/main") ->
          %{"object" => %{"sha" => @base_sha}}

        String.ends_with?(path, "/pulls/15") ->
          %{
            "number" => 15,
            "state" => "open",
            "merged" => false,
            "draft" => false,
            "mergeable" => true,
            "head" => %{"sha" => @moved_sha, "repo" => %{"id" => 1_368_436_395}},
            "base" => %{"sha" => @base_sha, "ref" => "main"}
          }

        true ->
          %{}
      end

    {:ok, payload}
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
        workspace_id: "workspace-a-id",
        project_id: "project-a",
        state_mappings: state_mappings
      })

    contract
  end
end
