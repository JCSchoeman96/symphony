defmodule SymphonyElixir.TransitionCoordinatorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    ProviderProjectContract,
    SemanticTransitionIntent,
    TransitionAttemptLedger,
    WorkflowLifecycle
  }

  test "executes one prepared transition and verifies it without resubmitting" do
    test_pid = self()

    {:ok, intent} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "symphony",
        guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
      })

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn ^intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:ok, %{status: 204}}
        end,
        verify: fn _attempt, _context -> :verified end,
        require_durable?: false
      )

    assert {:ok, attempt} = TransitionCoordinator.request_transition(coordinator, intent)
    assert attempt.state == :verified
    assert attempt.provider_ack_status == {:http, 204}
    assert_received :submitted
  end

  test "refuses a provider mutation when no durable ledger is available" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> :verified end
      )

    assert {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert {:error, {:durability_failed, :ledger_unavailable}} =
             TransitionCoordinator.request_transition(coordinator, intent)

    refute_received :submitted
  end

  test "rejects an unauthorized responsibility before loading provider context" do
    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent ->
          send(test_pid, :context_loaded)
          {:ok, context()}
        end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> :verified end,
        require_durable?: false
      )

    assert {:ok, %{state: :rejected}} =
             TransitionCoordinator.request_transition(coordinator, %{
               work_item_id: "work-1",
               requested_from: :ready,
               requested_to: :in_progress,
               responsibility: "review",
               guard_evidence: []
             })

    refute_received :context_loaded
    refute_received :submitted
  end

  test "fences an ambiguous submission and never resubmits it" do
    root = Path.join(System.tmp_dir!(), "symphony-transition-coordinator-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "attempts.dets")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}, path: path)

    test_pid = self()

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          {:error, :timeout}
        end,
        verify: fn _attempt, _context -> {:error, :verification_unavailable} end
      )

    assert {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())
    assert {:ok, attempt} = TransitionCoordinator.request_transition(coordinator, intent)
    assert attempt.state == :indeterminate
    assert_received :submitted

    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent)
    refute_received :submitted
  end

  test "rejects a concurrent request before the first provider call completes" do
    test_pid = self()
    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :first_submit_started)

          receive do
            :release_first_submit -> :ok
          end
        end,
        verify: fn _attempt, _context -> :verified end,
        require_durable?: false
      )

    first = Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent) end)
    assert_receive :first_submit_started

    assert {:error, :transition_in_progress} =
             Task.await(Task.async(fn -> TransitionCoordinator.request_transition(coordinator, intent) end))

    send(coordinator, :release_first_submit)
    assert {:ok, %{state: :verified}} = Task.await(first)
  end

  test "fences after a post-submit terminal durability failure" do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    ledger = %TransitionAttemptLedger{
      table: :transition_test_table,
      path: "/tmp/transition-test-ledger",
      project_id: "project-a",
      tracker_identity: %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
      write_fun: fn _table, _records ->
        count = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)
        if count == 4, do: {:error, :disk_full}, else: :ok
      end,
      sync_fun: fn _table -> :ok end
    }

    {:ok, coordinator} =
      TransitionCoordinator.start_link(
        name: nil,
        ledger: ledger,
        load_context: fn _intent -> {:ok, context()} end,
        submit: fn _attempt, _context ->
          send(test_pid, :submitted)
          :ok
        end,
        verify: fn _attempt, _context -> :verified end
      )

    {:ok, intent} = SemanticTransitionIntent.new(intent_attrs())

    assert {:error, {:durability_failed, {:ledger_write_failed, :disk_full}}} =
             TransitionCoordinator.request_transition(coordinator, intent)

    assert_received :submitted
    assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent)
    refute_received :submitted
  end

  defp intent_attrs do
    %{
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "symphony",
      guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}]
    }
  end

  defp context do
    %{
      provider_project_contract: contract(),
      dependency_decision: %{allowed?: true, dependency_completeness: :complete, dependency_status: :none},
      dependency_epoch_evidence: %{complete?: true}
    }
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
