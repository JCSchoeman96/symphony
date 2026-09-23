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

  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, SemanticTransitionIntent, WorkflowLifecycle, WorkItem}

  @now ~U[2026-09-18 00:00:00Z]

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

  defp group_for_state("Ready"), do: :unstarted
  defp group_for_state("In Progress"), do: :started
  defp group_for_state("Canceled"), do: :cancelled
  defp group_for_state("Done"), do: :completed

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
