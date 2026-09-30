defmodule SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_call({:transition_context, _work_item_id, _opts}, _from, opts) do
    {:reply, Keyword.get(opts, :transition_context, :unavailable), opts}
  end

  def handle_call({:suspend_work_item, _work_item_id, _reason}, _from, opts) do
    {:reply, Keyword.get(opts, :suspend_result, :ok), opts}
  end

  def handle_call({:apply_transition_result, _work_item_id, work_item, _opts}, _from, opts) do
    if pid = Keyword.get(opts, :apply_recipient) do
      send(pid, {:applied, work_item})
    end

    {:reply, :ok, opts}
  end

  def handle_call(:request_refresh, _from, opts) do
    if pid = Keyword.get(opts, :refresh_recipient) do
      send(pid, :refresh_requested)
    end

    {:reply, :ok, opts}
  end

  def handle_call(_message, _from, opts), do: {:reply, :ok, opts}
end

defmodule SymphonyElixir.TransitionCoordinatorDefaultPathTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SourceControl
  alias SymphonyElixir.SourceControl.CandidateRef
  alias SymphonyElixir.SourceControl.CandidateVerification
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator
  alias SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator, as: DefaultPathOrchestrator

  alias SymphonyElixir.WorkControl.{
    CompletionProof,
    GuardClass,
    ProviderObservation,
    ProviderProjectContract,
    SemanticTransitionIntent,
    WorkflowLifecycle,
    WorkItem
  }

  @now ~U[2026-09-18 00:00:00Z]
  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @sha_m String.duplicate("d", 40)
  @tree String.duplicate("c", 40)

  @source_control_config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1_368_436_395,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [%{context: "make-all", app_id: 15_368, subject: "head"}]
  }

  test "the default path performs fresh reads and verifies the target state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    issue = issue("Ready", "state-ready")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(
        transition_context: {:ok, Map.put(context(), :work_item, work_item())},
        apply_recipient: self()
      )

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.put_env(
            :symphony_elixir,
            :memory_tracker_issues,
            [%{issue | state: "In Progress", provider_state_id: "state-in_progress", provider_state_group: :started}]
          )

          :ok
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :verified}} = TransitionCoordinator.request_transition(coordinator, intent())
    assert_received {:applied, %WorkItem{validated_lifecycle_state: :in_progress}}
  end

  test "Done submission requires SourceControl merge verification and closes against the fresh Done read" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    contract = contract()
    current_issue = issue("Merging", "state-merging")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current_issue])
    proof = merge_authorized_proof(contract)

    assert {:ok, merging_work_item} =
             WorkItem.from_issue(current_issue, %{
               provider: :plane,
               observed_at: @now,
               prior_validated_lifecycle_state: :merging,
               evidence: [proof],
               provider_project_contract: contract
             })

    transition_context =
      context()
      |> Map.merge(%{
        work_item: merging_work_item,
        guard_evidence: [proof],
        github_opts: completion_github_opts()
      })

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(
        transition_context: {:ok, transition_context},
        apply_recipient: self()
      )

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract} end,
        submit: fn _attempt, _context ->
          Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue_with_tracker_read("Done", "state-done")])
          :ok
        end,
        require_durable?: false
      )

    completion_intent = %SemanticTransitionIntent{
      work_item_id: "work-1",
      requested_from: :merging,
      requested_to: :done,
      responsibility: "system",
      guard_evidence: [proof],
      requested_at: @now
    }

    assert {:ok, %{state: :verified}} = TransitionCoordinator.request_transition(coordinator, completion_intent)
    assert_received {:applied, %WorkItem{validated_lifecycle_state: :done} = completed}
    assert WorkItem.dependency_satisfying?(completed)
    assert ProviderObservation.valid_tracker_read?(completed.provider_observation)

    assert %CompletionProof{stage: :completed, closure_observation: %{provider_state_id: "state-done"}} =
             completed_proof =
             Enum.find(completed.lifecycle_assessment.satisfied_guards, &match?(%CompletionProof{stage: :completed}, &1))

    assert CompletionProof.closes_observation?(completed_proof, completed.provider_observation)

    forged_observation = %{completed.provider_observation | provider_state_name: "In Progress"}
    refute ProviderObservation.valid_tracker_read?(forged_observation)
    refute CompletionProof.closes_observation?(completed_proof, forged_observation)
  end

  test "failed SourceControl merge verification does not submit provider Done" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    contract = contract()
    current_issue = issue("Merging", "state-merging")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current_issue])
    proof = merge_authorized_proof(contract)

    {:ok, merging_work_item} =
      WorkItem.from_issue(current_issue, %{
        provider: :plane,
        observed_at: @now,
        prior_validated_lifecycle_state: :merging,
        evidence: [proof],
        provider_project_contract: contract
      })

    transition_context =
      context()
      |> Map.merge(%{
        work_item: merging_work_item,
        guard_evidence: [proof],
        github_opts:
          Keyword.put(completion_github_opts(), :request_fun, fn _token, _path, _params, _opts ->
            {:ok, %{"merged" => false}}
          end)
      })

    {:ok, orchestrator} =
      DefaultPathOrchestrator.start_link(transition_context: {:ok, transition_context})

    parent = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract} end,
        submit: fn _attempt, _context ->
          send(parent, :provider_done_submitted)
          :ok
        end,
        require_durable?: false
      )

    completion_intent = %SemanticTransitionIntent{
      work_item_id: "work-1",
      requested_from: :merging,
      requested_to: :done,
      responsibility: "system",
      guard_evidence: [proof],
      requested_at: @now
    }

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, completion_intent)
    refute_received :provider_done_submitted
  end

  test "the default submission seam remains provider-transport only" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        verify: fn _attempt, _context -> {:indeterminate, %{reason: :transport_only}} end,
        require_durable?: false
      )

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default context loading fails closed when the orchestrator is unavailable" do
    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: self(),
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default context loading preserves provider errors" do
    orchestrator_opts = [transition_context: {:error, :context_failed}]

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(orchestrator_opts)

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default context loading fails closed when contract refresh is unavailable" do
    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:error, :contract_refresh_failed} end,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default contract refresh fails closed without a trusted provider snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    for transition_context <- [{:ok, context()}, {:ok, Map.delete(context(), :provider_project_contract)}] do
      {:ok, orchestrator} =
        SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: transition_context)

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          orchestrator: orchestrator,
          require_durable?: false
        )

      assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())

      GenServer.stop(coordinator)
      GenServer.stop(orchestrator)
    end
  end

  test "default verification classifies a proven non-submission against the source state" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context -> {:error, :econnrefused} end,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default verification classifies a proven non-submission after third-state movement as conflict" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.put_env(
            :symphony_elixir,
            :memory_tracker_issues,
            [issue("Canceled", "state-canceled")]
          )

          {:error, :econnrefused}
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default verification classifies authoritative third-state movement as conflict after an ambiguous submit" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.put_env(
            :symphony_elixir,
            :memory_tracker_issues,
            [issue("Canceled", "state-canceled")]
          )

          {:error, :timeout}
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default verification treats a missing post-read as provider failure only when non-submission is proven" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          {:error, :econnrefused}
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default pre-read rejects missing and incompatible provider observations" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")

    for {issues, expected} <- [
          {[], :provider_failed},
          {[issue("Done", "state-done")], :conflict}
        ] do
      Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

      {:ok, orchestrator} =
        SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: nil,
          orchestrator: orchestrator,
          refresh_contract: fn _context -> {:ok, contract()} end,
          require_durable?: false
        )

      assert {:ok, %{state: ^expected}} = TransitionCoordinator.request_transition(coordinator, intent())
    end
  end

  test "default verification requests refresh when the verified projection lacks a work item" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    issue = issue("Ready", "state-ready")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(
        transition_context: {:ok, context()},
        refresh_recipient: self()
      )

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.put_env(
            :symphony_elixir,
            :memory_tracker_issues,
            [%{issue | state: "In Progress", provider_state_id: "state-in_progress", provider_state_group: :started}]
          )

          :ok
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :verified}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default verification classifies an authoritative third-state movement as conflict" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    initial = issue("Ready", "state-ready")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [initial])

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, contract()} end,
        submit: fn _attempt, _context ->
          Application.put_env(
            :symphony_elixir,
            :memory_tracker_issues,
            [issue("Canceled", "state-canceled")]
          )

          :ok
        end,
        require_durable?: false
      )

    assert {:ok, %{state: :conflict}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default context validation rejects a provider observation outside the contract scope" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])

    wrong_scope = %{context() | provider_project_contract: %{contract() | workspace_id: "other-workspace"}}

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, wrong_scope})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn _context -> {:ok, wrong_scope.provider_project_contract} end,
        require_durable?: false
      )

    assert {:ok, %{state: :provider_failed}} = TransitionCoordinator.request_transition(coordinator, intent())
  end

  test "default post-read errors remain indeterminate when submission is ambiguous" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", symphony_project_id: "project-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("Ready", "state-ready")])
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, orchestrator} =
      SymphonyElixir.TransitionCoordinatorDefaultPathOrchestrator.start_link(transition_context: {:ok, context()})

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: nil,
        orchestrator: orchestrator,
        refresh_contract: fn value ->
          if Agent.get_and_update(counter, fn count -> {count, count + 1} end) == 0 do
            {:ok, value.provider_project_contract}
          else
            {:error, :post_read_unavailable}
          end
        end,
        submit: fn _attempt, _context -> {:error, :timeout} end,
        require_durable?: false
      )

    assert {:ok, %{state: :indeterminate}} = TransitionCoordinator.request_transition(coordinator, intent())
    Agent.stop(counter)
  end

  defp intent do
    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "symphony",
        guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
      })

    intent
  end

  defp issue(state, state_id) do
    %Issue{
      id: "work-1",
      identifier: "SYM-1",
      title: "H-040 default path",
      state: state,
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: state_id,
      provider_state_group: group_for_state(state),
      url: "https://memory.local/work-1",
      updated_at: @now
    }
  end

  defp issue_with_tracker_read(state, state_id) do
    issue = issue(state, state_id)

    {:ok, observation} =
      ProviderObservation.from_issue(issue, %{provider: :plane, observed_at: DateTime.utc_now()})

    %{issue | tracker_read_observation: sign_provider_observation_for_test(observation)}
  end

  defp group_for_state("Ready"), do: :unstarted
  defp group_for_state("In Progress"), do: :started
  defp group_for_state("Merging"), do: :started
  defp group_for_state("Canceled"), do: :cancelled
  defp group_for_state("Done"), do: :completed

  defp merge_authorized_proof(contract) do
    settings = %{symphony: %{project_id: contract.project_id}}

    {:ok, candidate_ref} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    policy_fingerprint = SourceControl.policy_fingerprint_for(@source_control_config, settings)

    {:ok, review_attestation} =
      GuardClass.semantic_attestation(:review_accepted, %{
        responsibility: "review",
        runtime_attempt_id: "review-attempt",
        lineage_generation: 1,
        subject: {:work_item, "work-1"},
        timestamp: @now
      })

    review_evidence = %{
      class: :mechanical_guard,
      name: :review_acceptance_verified,
      outcome: :verified,
      candidate_ref: Map.from_struct(candidate_ref),
      candidate_tree_sha: @tree,
      policy_fingerprint: policy_fingerprint
    }

    candidate_verification =
      CandidateVerification.new(%{
        status: :verified,
        candidate_ref: candidate_ref,
        candidate_tree_sha: @tree,
        policy_fingerprint: policy_fingerprint
      })

    {:ok, unsigned_proof} =
      CompletionProof.new_merge_authorized(%{
        work_item_id: "work-1",
        provider_project_fingerprint: ProviderProjectContract.fingerprint(contract),
        workspace_id: contract.workspace_id,
        project_id: contract.project_id,
        candidate_ref: candidate_ref,
        candidate_tree_sha: @tree,
        policy_fingerprint: policy_fingerprint,
        review_acceptance_evidence: review_evidence,
        review_attestation: review_attestation,
        candidate_verification: candidate_verification
      })

    sign_completion_proof_for_test(unsigned_proof)
  end

  defp completion_github_opts do
    settings = %{symphony: %{project_id: "project-1"}}

    [
      source_control_config: @source_control_config,
      settings: settings,
      token: "token",
      request_fun: fn _token, path, _params, _opts ->
        {:ok,
         cond do
           String.ends_with?(path, "/repos/JCSchoeman96/symphony") ->
             %{"id" => 1_368_436_395}

           String.contains?(path, "/pulls/15") ->
             %{"number" => 15, "merged" => true, "head" => %{"sha" => @sha_b}, "merge_commit_sha" => @sha_m}

           String.contains?(path, "/git/commits/" <> @sha_m) ->
             %{
               "sha" => @sha_m,
               "tree" => %{"sha" => @tree},
               "parents" => [%{"sha" => @sha_a}, %{"sha" => @sha_b}]
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
                   "conclusion" => "success",
                   "app" => %{"id" => 15_368}
                 }
               ]
             }

           true ->
             %{}
         end}
      end
    ]
  end

  defp context do
    %{
      provider_project_contract: contract(),
      dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none},
      dependency_epoch_evidence: %{complete?: true}
    }
  end

  defp work_item do
    {:ok, work_item} =
      WorkItem.from_issue(issue("Ready", "state-ready"), %{
        provider: :plane,
        observed_at: @now,
        prior_validated_lifecycle_state: :ready,
        provider_project_contract: contract()
      })

    work_item
  end

  defp contract do
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
        state_mappings: state_mappings,
        dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking}
      })

    contract
  end
end
