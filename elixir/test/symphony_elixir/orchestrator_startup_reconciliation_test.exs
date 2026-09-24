defmodule SymphonyElixir.StartupOrderingCoordinator do
  use GenServer

  alias SymphonyElixir.WorkControl.RecoveryLedger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %{
       parent: Keyword.fetch!(opts, :parent),
       ledger: Keyword.fetch!(opts, :ledger),
       candidates: Keyword.fetch!(opts, :candidates),
       list_response: Keyword.get(opts, :list_response),
       sync_response: Keyword.get(opts, :sync_response, :ok),
       reconcile_response: Keyword.get(opts, :reconcile_response)
     }}
  end

  @impl true
  def handle_call(:list_reconciliation_candidates, _from, state) do
    {:reply, state.list_response || {:ok, state.candidates}, state}
  end

  def handle_call(:sync_reconciliation_ledger, _from, state), do: {:reply, state.sync_response, state}

  def handle_call({:reconciliation_marker_for_work_item, _work_item_id}, _from, state),
    do: {:reply, :not_found, state}

  def handle_call(
        {:reconcile_candidate, candidate, outcome, evidence_identity, _reconciled_at},
        _from,
        state
      ) do
    {:ok, checkpoint} = RecoveryLedger.current(state.ledger, candidate.work_item_id)
    send(state.parent, {:checkpoint_before_transition_marker, checkpoint})

    marker = %{
      attempt_id: candidate.attempt_id,
      work_item_id: candidate.work_item_id,
      outcome: outcome,
      evidence_identity: evidence_identity
    }

    case state.reconcile_response do
      nil ->
        candidates = Enum.reject(state.candidates, &(&1.attempt_id == candidate.attempt_id))
        {:reply, {:ok, marker}, %{state | candidates: candidates}}

      response ->
        {:reply, response, state}
    end
  end
end

defmodule SymphonyElixir.StartupReconciliationRunnerFake do
  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, _recipient, opts) do
    send(Process.whereis(:symphony_agent_router_capture), {:fake_agent_run, issue, opts})
    :ok
  end
end

defmodule SymphonyElixir.OrchestratorStartupReconciliationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator.State

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    RecoveryLedger,
    SuspensionContext,
    WorkItem
  }

  alias SymphonyElixir.Workspace.OwnershipLedger

  defp suspended_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :in_progress
      })

    {:ok, suspended} = WorkItem.suspend(work_item, :provider_failed)
    suspended
  end

  defp test_ownership_ledger_root(workspace_root) do
    Path.join(Path.dirname(workspace_root), "#{Path.basename(workspace_root)}-ownership-ledger")
  end

  test "startup stays pending and preserves terminal workspaces until reconciliation" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060b-startup-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "startup-terminal-issue",
      identifier: "SYM-H060B-STARTUP",
      title: "Terminal issue with a retained workspace",
      state: "Canceled"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Canceled"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)
    {:ok, [owned_record]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)

    assert {:ok, %{state: :release_pending}} =
             OwnershipLedger.transition_sync(ownership_ledger, owned_record.workspace_ownership_id, :release_pending)

    assert :ok = OwnershipLedger.close(ownership_ledger)

    name = Module.concat(__MODULE__, "Pending#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    state = :sys.get_state(pid)

    assert Map.get(state, :startup_reconciliation) == :pending
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(state)

    {:ok, pending_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :done,
        evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
      })

    :sys.replace_state(pid, fn current ->
      %{current | work_control: Map.put(current.work_control, issue.id, pending_item)}
    end)

    assert {:error, :startup_reconciliation_pending} = Orchestrator.transition_context(pid, issue.id)
    assert {:error, :startup_reconciliation_pending} = Orchestrator.semantic_tool_context(pid, issue.id)
    assert File.dir?(workspace)

    send(pid, :tick)

    assert eventually(fn ->
             :sys.get_state(pid).startup_reconciliation == :ready
           end)

    reconciled_state = :sys.get_state(pid)
    assert reconciled_state.startup_cleanup_ran?
    refute File.dir?(workspace)
  end

  test "terminal cleanup uses the current issue identity and ignores a stale workspace path" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-terminal-cleanup-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "terminal-owned-workspace",
      identifier: "SYM-H060C-OWNED",
      title: "Release the owned workspace",
      state: "In Progress"
    }

    terminal_issue = %{issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)

    assert {:error, :workspace_cleanup_authorization_required} =
             Workspace.remove_issue_workspaces(issue, nil, ownership_ledger)

    assert File.dir?(workspace)

    state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ownership_ledger,
      workspace_ownership_ledger_status: :ready,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          started_at: DateTime.utc_now(),
          workspace_path: Path.join(workspace_root, "foreign-path")
        }
      },
      claimed: MapSet.new([issue.id])
    }

    updated_state =
      Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)

    refute File.dir?(workspace)
    refute Map.has_key?(updated_state.running, issue.id)

    assert :ok = OwnershipLedger.close(ownership_ledger)
    File.rm_rf(workspace_root)
    File.rm_rf(ledger_root)
  end

  test "startup preserves an unowned terminal workspace and still completes reconciliation" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-unowned-terminal-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "unowned-terminal-workspace",
      identifier: "SYM-H060C-UNOWNED",
      title: "Preserve an unowned terminal directory",
      state: "Done"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    unowned_workspace = Path.join(workspace_root, Workspace.workspace_key(issue.identifier))
    File.mkdir_p!(unowned_workspace)

    name = Module.concat(__MODULE__, "UnownedTerminal#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert state.startup_cleanup_ran?
    assert File.dir?(unowned_workspace)
  end

  test "terminal cleanup preserves a workspace with an active suspension context" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-terminal-suspension-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    active_issue = %Issue{
      id: "terminal-suspended-workspace",
      identifier: "SYM-H060C-SUSPENDED",
      title: "Preserve the suspended workspace",
      state: "In Progress"
    }

    terminal_issue = %{active_issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(active_issue, nil, ownership_ledger)
    suspended_work_item = suspended_work_item(active_issue)

    state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ownership_ledger,
      workspace_ownership_ledger_status: :ready,
      blocked: %{active_issue.id => %{issue: active_issue, worker_host: nil}},
      claimed: MapSet.new([active_issue.id]),
      work_control: %{active_issue.id => suspended_work_item}
    }

    updated_state =
      Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], state)

    assert File.dir?(workspace)
    refute Map.has_key?(updated_state.blocked, active_issue.id)

    assert :ok = OwnershipLedger.close(ownership_ledger)
    File.rm_rf(workspace_root)
    File.rm_rf(ledger_root)
  end

  test "routed terminal cleanup preserves a workspace without a current canonical work item" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-missing-terminal-work-item-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    active_issue = %Issue{id: "missing-terminal-work-item", identifier: "SYM-H060C-MISSING-WORK-ITEM", state: "In Progress"}
    terminal_issue = %{active_issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ownership_ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    {:ok, workspace} = Workspace.create_for_issue(active_issue, nil, ownership_ledger)

    state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ownership_ledger,
      workspace_ownership_ledger_status: :ready,
      blocked: %{active_issue.id => %{issue: active_issue, worker_host: nil}},
      claimed: MapSet.new([active_issue.id])
    }

    _updated = Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], state)

    assert File.dir?(workspace)
    assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ownership_ledger, active_issue.id)
    assert owned.state == :owned
  end

  test "terminal workspace cleanup failure remains blocked and can be retried" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-terminal-cleanup-retry-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    active_issue = %Issue{id: "terminal-cleanup-retry", identifier: "SYM-H060C-CLEANUP-RETRY", state: "In Progress"}
    terminal_issue = %{active_issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      hook_before_remove: "printf cleanup-blocked; exit 17"
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ownership_ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    {:ok, workspace} = Workspace.create_for_issue(active_issue, nil, ownership_ledger)

    blocked_state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ownership_ledger,
      workspace_ownership_ledger_status: :ready,
      blocked: %{active_issue.id => %{issue: active_issue, worker_host: nil}},
      claimed: MapSet.new([active_issue.id])
    }

    failed_state = Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], blocked_state)

    assert Map.has_key?(failed_state.blocked, active_issue.id)
    assert File.dir?(workspace)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ownership_ledger, active_issue.id)
    assert pending.state == :release_pending

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root
    )

    retried_state = Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], failed_state)

    refute Map.has_key?(retried_state.blocked, active_issue.id)
    refute File.exists?(workspace)
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ownership_ledger, active_issue.id)
    assert released.state == :released
  end

  test "startup terminal cleanup stays pending after a hook failure and retries safely" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-startup-cleanup-retry-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    issue = %Issue{id: "startup-cleanup-retry", identifier: "SYM-H060C-STARTUP-CLEANUP", state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      hook_before_remove: "printf cleanup-blocked; exit 17",
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)
    assert :ok = OwnershipLedger.close(ownership_ledger)

    name = Module.concat(__MODULE__, "StartupCleanupRetry#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    send(pid, :tick)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             with true <- state.startup_reconciliation == :pending,
                  true <- not state.startup_cleanup_ran?,
                  {:ok, [pending]} <- OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id) do
               pending.state == :release_pending
             else
               _ -> false
             end
           end)

    pending_state = :sys.get_state(pid)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(pending_state.workspace_ownership_ledger, issue.id)
    assert pending.state == :release_pending
    assert File.dir?(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    send(pid, :tick)
    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert state.startup_cleanup_ran?
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id)
    assert released.state == :released
    refute File.exists?(workspace)
  end

  test "terminal workspace cleanup preserves open, resolving, and escalated suspension contexts" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-suspension-status-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    active_issue = %Issue{id: "terminal-suspension-status", identifier: "SYM-H060C-SUSPENSION-STATUS", state: "In Progress"}
    terminal_issue = %{active_issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ownership_ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    {:ok, workspace} = Workspace.create_for_issue(active_issue, nil, ownership_ledger)
    suspended = suspended_work_item(active_issue)
    context = suspended.suspension_context

    for status <- [:open, :resolving, :escalated] do
      status_item = %{suspended | suspension_context: %{context | status: status}}

      state = %State{
        startup_reconciliation: :ready,
        workspace_ownership_ledger: ownership_ledger,
        workspace_ownership_ledger_status: :ready,
        blocked: %{active_issue.id => %{issue: active_issue, worker_host: nil}},
        claimed: MapSet.new([active_issue.id]),
        work_control: %{active_issue.id => status_item}
      }

      _updated = Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], state)
      assert File.dir?(workspace)
      assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ownership_ledger, active_issue.id)
      assert owned.state == :owned
    end

    assert :ok =
             Workspace.remove_issue_workspaces(active_issue, nil, ownership_ledger, cleanup_authorized?: true)
  end

  test "terminal cleanup follows authority escalation and cancellation dispositions" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-authority-disposition-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ownership_ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    for {status, lifecycle_state, preserved?} <- [
          {:escalated, :in_progress, true},
          {:suspended, :in_progress, true},
          {:suspended, :canceled, false}
        ] do
      issue = %Issue{
        id: "authority-disposition-#{status}-#{lifecycle_state}",
        identifier: "SYM-H060C-#{status}-#{lifecycle_state}",
        state: "In Progress"
      }

      terminal_issue = %{issue | state: "Done"}
      {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)

      work_item =
        suspended_work_item(issue)
        |> Map.put(:suspension_context, nil)
        |> Map.put(
          :authority_disposition,
          AuthorityDisposition.new(%{status: status, lifecycle_state: lifecycle_state})
        )

      state = %State{
        startup_reconciliation: :ready,
        workspace_ownership_ledger: ownership_ledger,
        workspace_ownership_ledger_status: :ready,
        blocked: %{issue.id => %{issue: issue, worker_host: nil}},
        claimed: MapSet.new([issue.id]),
        work_control: %{issue.id => work_item}
      }

      _updated = Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], state)

      if preserved? do
        assert File.dir?(workspace)
        assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)
        assert owned.state == :owned
      else
        refute File.exists?(workspace)
        assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)
        assert released.state == :released
      end
    end
  end

  test "shutdown termination never authorizes workspace deletion" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-shutdown-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "shutdown-owned-workspace",
      identifier: "SYM-H060C-SHUTDOWN",
      title: "Keep the workspace on shutdown",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)

    state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ownership_ledger,
      workspace_ownership_ledger_status: :ready,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          started_at: DateTime.utc_now(),
          workspace_path: workspace
        }
      },
      claimed: MapSet.new([issue.id])
    }

    _updated_state =
      Orchestrator.terminate_running_issue_for_test(state, issue.id, true, :shutdown)

    assert File.dir?(workspace)

    assert :ok = OwnershipLedger.close(ownership_ledger)
    File.rm_rf(workspace_root)
    File.rm_rf(ledger_root)
  end

  test "startup cancels a pending workspace release only after matching fresh tracker state" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-pending-release-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "pending-release-issue",
      identifier: "SYM-H060C-PENDING",
      title: "Keep the active workspace",
      state: "In Progress"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)
    {:ok, [record]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)

    assert {:ok, %{state: :release_pending}} =
             OwnershipLedger.transition_sync(ownership_ledger, record.workspace_ownership_id, :release_pending)

    assert :ok = OwnershipLedger.close(ownership_ledger)

    name = Module.concat(__MODULE__, "PendingRelease#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id)
    assert owned.state == :owned
    assert File.dir?(workspace)
  end

  test "startup preserves a pending workspace release when the work item is missing" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-missing-pending-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    issue = %Issue{id: "missing-pending-issue", identifier: "SYM-H060C-MISSING", state: "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)
    {:ok, [record]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)

    assert {:ok, %{state: :release_pending}} =
             OwnershipLedger.transition_sync(ownership_ledger, record.workspace_ownership_id, :release_pending)

    assert :ok = OwnershipLedger.close(ownership_ledger)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    name = Module.concat(__MODULE__, "MissingPendingRelease#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id)
    assert pending.state == :release_pending
    assert File.dir?(workspace)
  end

  test "startup preserves a pending release when the tracker identifier is unavailable" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-ambiguous-pending-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    recorded_issue = %Issue{id: "ambiguous-pending-issue", identifier: "SYM-H060C-RECORDED", state: "In Progress"}
    current_issue = %{recorded_issue | identifier: nil}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(recorded_issue, nil, ownership_ledger)
    {:ok, [record]} = OwnershipLedger.list_for_work_item(ownership_ledger, recorded_issue.id)

    assert {:ok, %{state: :release_pending}} =
             OwnershipLedger.transition_sync(ownership_ledger, record.workspace_ownership_id, :release_pending)

    assert :ok = OwnershipLedger.close(ownership_ledger)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [current_issue])

    name = Module.concat(__MODULE__, "AmbiguousPendingRelease#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, recorded_issue.id)
    assert pending.state == :release_pending
    assert pending.issue_identifier == recorded_issue.identifier
    assert File.dir?(workspace)
  end

  test "corrupt ownership records fence pending-release reconciliation" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-corrupt-ownership-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    name = Module.concat(__MODULE__, "CorruptOwnership#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    state = :sys.get_state(pid)
    ledger = state.workspace_ownership_ledger
    corrupt_key = {:ownership, "corrupt-record"}
    assert :ok = :dets.insert(ledger.table, {corrupt_key, %{unexpected: true}})

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).workspace_ownership_ledger_status != :ready end)

    blocked_state = :sys.get_state(pid)

    assert {:blocked, {:workspace_ownership_ledger_unavailable, ownership_error}} =
             blocked_state.workspace_ownership_ledger_status

    assert {:corrupt_ownership_record, ^corrupt_key, :invalid_record} = ownership_error

    assert match?({:blocked, {:workspace_pending_reconciliation_unavailable, _}}, blocked_state.startup_reconciliation)
  end

  test "startup resumes a failed provisioning release instead of converting it to owned" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-failed-provisioning-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    cleanup_attempt_marker = workspace_root <> "-retry-marker"
    issue = %Issue{id: "failed-provisioning", identifier: "SYM-H060C-BOOTSTRAP", state: "In Progress"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      hook_after_create: "exit 17",
      hook_before_remove: "exit 18",
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root,
        workspace_root: Config.local_workspace_root()
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ownership_ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
      File.rm(cleanup_attempt_marker)
    end)

    workspace = Path.join(workspace_root, Workspace.workspace_key(issue.identifier))

    assert {:error, {:after_create_cleanup_failed, _, {:workspace_hook_failed, "before_remove", 18, _}}} =
             Workspace.create_for_issue(issue, nil, ownership_ledger)

    assert File.dir?(workspace)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)
    assert pending.state == :release_pending
    assert pending.release_origin == :failed_provisioning
    assert :ok = OwnershipLedger.close(ownership_ledger)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      hook_before_remove: "printf attempt >> #{cleanup_attempt_marker}; exit 18",
      poll_interval_ms: 60_000
    )

    name = Module.concat(__MODULE__, "FailedProvisioningRelease#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    send(pid, :tick)
    assert eventually(fn -> File.exists?(cleanup_attempt_marker) end)
    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :pending end)

    state = :sys.get_state(pid)
    assert {:ok, [still_pending]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id)
    assert still_pending.state == :release_pending
    assert still_pending.release_origin == :failed_provisioning
    assert File.dir?(workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    send(pid, :tick)
    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    state = :sys.get_state(pid)
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(state.workspace_ownership_ledger, issue.id)
    assert released.state == :released
    assert released.release_origin == :failed_provisioning
    refute File.exists?(workspace)
  end

  test "runtime config reload fences dispatch when tracker ownership identity changes" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-reload-root-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      symphony_project_id: "h060c-reload-project",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    name = Module.concat(__MODULE__, "OwnershipReload#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
    end)

    assert :sys.get_state(pid).workspace_ownership_ledger_status == :ready

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "a-different-project",
      agent_routing: "legacy",
      symphony_project_id: "h060c-reload-project",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).workspace_ownership_ledger_status != :ready end)

    state = :sys.get_state(pid)

    assert {:blocked, {:workspace_ownership_ledger_unavailable, {:ledger_tracker_identity_mismatch, _, _}}} =
             state.workspace_ownership_ledger_status

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(state)
  end

  test "runtime config reload fences dispatch when workspace root changes" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-reload-root-#{System.unique_integer([:positive])}")

    next_workspace_root = workspace_root <> "-next"
    ledger_root = test_ownership_ledger_root(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      symphony_project_id: "h060c-root-reload-project",
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    name = Module.concat(__MODULE__, "WorkspaceRootReload#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        workspace_ownership_ledger_opts: [root: ledger_root]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(workspace_root)
      File.rm_rf(next_workspace_root)
      File.rm_rf(ledger_root)
    end)

    assert :sys.get_state(pid).workspace_ownership_ledger_status == :ready

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      symphony_project_id: "h060c-root-reload-project",
      workspace_root: next_workspace_root,
      poll_interval_ms: 60_000
    )

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).workspace_ownership_ledger_status != :ready end)

    state = :sys.get_state(pid)

    assert {:blocked, {:workspace_ownership_ledger_unavailable, {:workspace_root_changed, _, _}}} =
             state.workspace_ownership_ledger_status

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(state)
  end

  test "live terminal workspace cleanup retries a durable pending release on the next poll" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-h060c-live-cleanup-#{System.unique_integer([:positive])}")

    ledger_root = test_ownership_ledger_root(workspace_root)
    first_remove_attempt = Path.join(System.tmp_dir!(), "symphony-h060c-remove-once-#{System.unique_integer([:positive])}")

    issue = %Issue{
      id: "live-pending-cleanup",
      identifier: "SYM-H060C-LIVE-CLEANUP",
      title: "Retry a pending terminal cleanup",
      state: "In Progress"
    }

    terminal_issue = %{issue | state: "Done"}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "legacy",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      hook_before_remove: "if [ -e '#{first_remove_attempt}' ]; then exit 0; else touch '#{first_remove_attempt}'; exit 17; fi",
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal_issue])

    {:ok, ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ledger_root,
        workspace_root: Config.local_workspace_root()
      )

    on_exit(fn ->
      _ = OwnershipLedger.close(ledger)
      File.rm_rf(workspace_root)
      File.rm_rf(ledger_root)
      File.rm(first_remove_attempt)
    end)

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)

    state = %State{
      startup_reconciliation: :ready,
      workspace_ownership_ledger: ledger,
      workspace_ownership_ledger_status: :ready,
      workspace_ownership_ledger_opts: [root: ledger_root, workspace_root: Config.local_workspace_root()],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      running: %{
        issue.id => %{
          pid: nil,
          ref: nil,
          identifier: issue.identifier,
          issue: terminal_issue,
          worker_host: nil,
          started_at: DateTime.utc_now(),
          workspace_path: workspace
        }
      },
      claimed: MapSet.new([issue.id])
    }

    pending_state =
      Orchestrator.terminate_running_issue_for_test(state, issue.id, true, :terminal_cancelled)

    assert File.dir?(workspace)
    assert {:ok, [pending_record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending_record.state == :release_pending

    {:noreply, retried_state} = Orchestrator.handle_info(:run_poll_cycle, pending_state)

    refute File.dir?(workspace)
    assert {:ok, [released_record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released_record.state == :released

    if retried_state.tick_timer_ref, do: Process.cancel_timer(retried_state.tick_timer_ref)
  end

  test "an open security suspension stays fenced after a clean restart" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)
    workspace_root = Path.join(System.tmp_dir!(), "symphony-h060c-suspended-workspace-#{System.unique_integer([:positive])}")
    ownership_ledger_root = test_ownership_ledger_root(workspace_root)

    issue = %Issue{
      id: "startup-security-suspension",
      identifier: "SYM-H060B-SECURITY",
      title: "Keep security suspension across restart",
      state: "Planning",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning"],
      workspace_root: workspace_root,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_recovery_checkpoint!(issue)

    {:ok, ownership_ledger} =
      OwnershipLedger.open(
        Config.settings!().symphony.project_id,
        Tracker.identity(Config.settings!().tracker),
        root: ownership_ledger_root
      )

    {:ok, workspace} = Workspace.create_for_issue(issue, nil, ownership_ledger)
    {:ok, [owned]} = OwnershipLedger.list_for_work_item(ownership_ledger, issue.id)

    assert {:ok, %{state: :release_pending}} =
             OwnershipLedger.transition_sync(ownership_ledger, owned.workspace_ownership_id, :release_pending)

    assert :ok = OwnershipLedger.close(ownership_ledger)

    {:ok, initial_work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :planning
      })

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: nil,
        candidates: []
      )

    first_name = Module.concat(__MODULE__, "SecurityFirst#{System.unique_integer([:positive])}")

    {:ok, first_pid} =
      Orchestrator.start_link(
        name: first_name,
        start_quiesced: true,
        transition_coordinator: coordinator,
        work_control: %{issue.id => initial_work_item},
        workspace_ownership_ledger_opts: [root: ownership_ledger_root]
      )

    second_name = Module.concat(__MODULE__, "SecurityRestart#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if Process.alive?(first_pid), do: GenServer.stop(first_pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)

      File.rm_rf(workspace_root)
      File.rm_rf(ownership_ledger_root)
    end)

    assert {:ok, suspended_item} =
             Orchestrator.suspend_work_item(first_pid, issue.id, :security_boundary_failed)

    assert WorkItem.suspended?(suspended_item)
    initial_state = :sys.get_state(first_pid)

    assert {:ok, open_checkpoint} = RecoveryLedger.current(initial_state.recovery_ledger, issue.id)
    assert open_checkpoint.active_suspension_context.status == :open
    assert :ok = GenServer.stop(first_pid)

    {:ok, restarted_pid} =
      Orchestrator.start_link(
        name: second_name,
        start_quiesced: true,
        transition_coordinator: coordinator,
        agent_runner: SymphonyElixir.StartupReconciliationRunnerFake,
        workspace_ownership_ledger_opts: [root: ownership_ledger_root]
      )

    on_exit(fn -> if Process.alive?(restarted_pid), do: GenServer.stop(restarted_pid) end)

    pending_state = :sys.get_state(restarted_pid)
    assert pending_state.startup_reconciliation == :pending
    assert pending_state.recovery_checkpoints[issue.id].active_suspension_context.status == :open

    send(restarted_pid, :tick)
    assert eventually(fn -> :sys.get_state(restarted_pid).startup_reconciliation == :ready end)

    reconciled_state = :sys.get_state(restarted_pid)
    recovered_item = reconciled_state.work_control[issue.id]

    assert WorkItem.suspended?(recovered_item)
    assert recovered_item.suspension_context.reason == :security_boundary_failed
    assert recovered_item.suspension_context.status == :resolving
    assert reconciled_state.recovery_checkpoints[issue.id].active_suspension_context.status == :resolving
    assert recovered_item.authority_disposition.status == :suspended
    assert recovered_item.lifecycle_assessment.status == :validated
    assert Graph.complete?(reconciled_state.dependency_graph)

    assert {:ok, [pending_workspace]} =
             OwnershipLedger.list_for_work_item(reconciled_state.workspace_ownership_ledger, issue.id)

    assert pending_workspace.state == :release_pending
    assert File.dir?(workspace)
    refute_receive {:fake_agent_run, ^issue, _opts}, 50
  end

  test "startup remains fenced when the transition coordinator cannot list candidates" do
    cases = [
      {{:error, :coordinator_down}, nil, {:transition_coordinator_unavailable, :coordinator_down}},
      {:ok, {:error, :candidate_list_failed}, {:transition_coordinator_unavailable, :candidate_list_failed}},
      {:ok, :malformed, :invalid_transition_reconciliation_candidates}
    ]

    for {sync_response, list_response, expected_reason} <- cases do
      project_id = "startup-blocked-#{System.unique_integer([:positive])}"
      root = Path.join(System.tmp_dir!(), "symphony-startup-blocked-#{System.unique_integer([:positive])}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        agent_routing: "routed",
        symphony_project_id: project_id,
        poll_interval_ms: 60_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      {:ok, coordinator} =
        SymphonyElixir.StartupOrderingCoordinator.start_link(
          parent: self(),
          ledger: nil,
          candidates: [],
          sync_response: sync_response,
          list_response: list_response
        )

      name = Module.concat(__MODULE__, "Blocked#{System.unique_integer([:positive])}")

      {:ok, pid} =
        Orchestrator.start_link(
          name: name,
          start_quiesced: true,
          transition_coordinator: coordinator,
          attempt_ledger_opts: [root: Path.join(root, "attempts")],
          recovery_ledger_opts: [root: Path.join(root, "recovery")]
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        if Process.alive?(coordinator), do: GenServer.stop(coordinator)
        File.rm_rf(root)
      end)

      send(pid, :tick)

      assert eventually(fn ->
               :sys.get_state(pid).startup_reconciliation == {:blocked, expected_reason}
             end)

      refute Orchestrator.autonomous_dispatch_allowed_for_test?(:sys.get_state(pid))
    end
  end

  test "startup remains fenced on an incomplete dependency epoch" do
    project_id = "startup-incomplete-graph-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-startup-incomplete-graph-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: project_id,
      poll_interval_ms: 60_000
    )

    issue = %Issue{
      id: "startup-incomplete-dependency-item",
      identifier: "SYM-STARTUP-INCOMPLETE",
      state: "Ready",
      dependency_completeness: {:incomplete, :relation_read_failed}
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(parent: self(), ledger: nil, candidates: [])

    {:ok, pid} =
      Orchestrator.start_link(
        name: Module.concat(__MODULE__, "Incomplete#{System.unique_integer([:positive])}"),
        start_quiesced: true,
        transition_coordinator: coordinator,
        attempt_ledger_opts: [root: Path.join(root, "attempts")],
        recovery_ledger_opts: [root: Path.join(root, "recovery")]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf(root)
    end)

    send(pid, :tick)

    assert eventually(fn ->
             match?(
               {:blocked, {:dependency_graph_incomplete, _reason}},
               :sys.get_state(pid).startup_reconciliation
             )
           end)

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(:sys.get_state(pid))
  end

  test "a disabled transition coordinator permits only an empty non-Plane startup reconciliation" do
    project_id = "startup-transitions-disabled-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-startup-transitions-disabled-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: project_id,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: nil,
        candidates: [],
        sync_response: {:error, :transitions_disabled}
      )

    {:ok, pid} =
      Orchestrator.start_link(
        name: Module.concat(__MODULE__, "TransitionsDisabled#{System.unique_integer([:positive])}"),
        start_quiesced: true,
        transition_coordinator: coordinator,
        attempt_ledger_opts: [root: Path.join(root, "attempts")],
        recovery_ledger_opts: [root: Path.join(root, "recovery")]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf(root)
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(:sys.get_state(pid))
  end

  test "startup retries blocked attempt and recovery ledger syncs before becoming ready" do
    project_id = "startup-resync-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-startup-resync-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: project_id,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: nil,
        candidates: []
      )

    name = Module.concat(__MODULE__, "Resync#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        transition_coordinator: coordinator,
        attempt_ledger_opts: [root: Path.join(root, "attempts")],
        recovery_ledger_opts: [root: Path.join(root, "recovery")]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf(root)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | startup_reconciliation: :pending,
          attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, :previous}}},
          attempt_ledger: %{state.attempt_ledger | sync_fun: fn _table -> :ok end},
          recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, {:ledger_sync_failed, :previous}}},
          recovery_ledger: %{state.recovery_ledger | sync_fun: fn _table -> :ok end}
      }
    end)

    send(pid, :tick)

    assert eventually(fn ->
             :sys.get_state(pid).startup_reconciliation == :ready
           end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | startup_reconciliation: :pending,
          attempt_ledger_status: {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, :previous}}},
          attempt_ledger: %{state.attempt_ledger | sync_fun: fn _table -> {:error, :attempt_sync_failed} end}
      }
    end)

    send(pid, :tick)

    assert eventually(fn ->
             :sys.get_state(pid).startup_reconciliation ==
               {:blocked, {:attempt_ledger_unavailable, {:ledger_sync_failed, :attempt_sync_failed}}}
           end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | startup_reconciliation: :pending,
          attempt_ledger_status: :ready,
          recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, {:ledger_sync_failed, :previous}}},
          recovery_ledger: %{state.recovery_ledger | sync_fun: fn _table -> {:error, :recovery_sync_failed} end}
      }
    end)

    send(pid, :tick)

    assert eventually(fn ->
             :sys.get_state(pid).startup_reconciliation ==
               {:blocked, {:recovery_ledger_unavailable, {:ledger_sync_failed, :recovery_sync_failed}}}
           end)

    refute Orchestrator.autonomous_dispatch_allowed_for_test?(:sys.get_state(pid))
  end

  test "startup retries recovery ledger initialization before reconciliation" do
    recovery_root =
      Path.join(System.tmp_dir!(), "symphony-recovery-retry-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: nil,
        candidates: []
      )

    name = Module.concat(__MODULE__, "ReopenRecovery#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        transition_coordinator: coordinator,
        recovery_ledger_opts: [
          root: recovery_root,
          write_fun: fn _table, _records -> {:error, :metadata_write_failed} end
        ]
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
      File.rm_rf(recovery_root)
    end)

    assert eventually(fn ->
             case :sys.get_state(pid).recovery_ledger_status do
               {:blocked, {:recovery_ledger_unavailable, {:ledger_write_failed, :metadata_write_failed}}} -> true
               _other -> false
             end
           end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | startup_reconciliation: :pending,
          recovery_ledger_opts: [root: recovery_root]
      }
    end)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).startup_reconciliation == :ready end)

    reconciled_state = :sys.get_state(pid)
    assert %RecoveryLedger{} = reconciled_state.recovery_ledger
    assert reconciled_state.recovery_ledger_status == :ready
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(reconciled_state)
  end

  test "fresh active state cannot bootstrap authority, while backlog gets a trusted checkpoint" do
    project_id = "startup-checkpoint-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-startup-checkpoint-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: project_id,
      tracker_active_states: ["Ready", "In Progress"],
      tracker_terminal_states: ["Done"],
      poll_interval_ms: 60_000
    )

    {:ok, recovery_ledger} =
      RecoveryLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: root)

    on_exit(fn ->
      RecoveryLedger.close(recovery_ledger)
      File.rm_rf(root)
    end)

    active_issue = %Issue{id: "startup-active-without-checkpoint", state: "Ready"}
    backlog_issue = %Issue{id: "startup-backlog-without-checkpoint", state: "Backlog"}

    state = %State{
      recovery_ledger: recovery_ledger,
      recovery_ledger_status: :ready,
      startup_reconciliation: :ready
    }

    active_state = Orchestrator.refresh_work_control_for_test(state, [active_issue])
    active_work_item = active_state.work_control[active_issue.id]

    assert active_work_item.lifecycle_assessment.reason == :initial_state_requires_validation
    assert WorkItem.suspended?(active_work_item)
    refute active_state.recovery_checkpoints[active_issue.id]
    assert :not_found = RecoveryLedger.current(recovery_ledger, active_issue.id)

    backlog_state = Orchestrator.refresh_work_control_for_test(state, [backlog_issue])
    assert backlog_state.work_control[backlog_issue.id].validated_lifecycle_state == :backlog
    assert {:ok, backlog_checkpoint} = RecoveryLedger.current(recovery_ledger, backlog_issue.id)
    assert backlog_checkpoint.last_validated_lifecycle_state == :backlog

    moved_issue = %Issue{id: "startup-moved-while-down", state: "Done"}
    prior_checkpoint = recovery_checkpoint(project_id, moved_issue.id, :ready)
    assert :ok = RecoveryLedger.put_sync(recovery_ledger, prior_checkpoint)

    moved_state = %{
      state
      | recovery_checkpoints: %{moved_issue.id => prior_checkpoint},
        dependency_graph: Graph.build([moved_issue])
    }

    refreshed_state = Orchestrator.refresh_work_control_for_test(moved_state, [moved_issue])
    refreshed_item = refreshed_state.work_control[moved_issue.id]
    refreshed_checkpoint = refreshed_state.recovery_checkpoints[moved_issue.id]

    assert WorkItem.suspended?(refreshed_item)
    assert refreshed_checkpoint.last_validated_lifecycle_state == :ready
    assert refreshed_checkpoint.active_suspension_context.status == :resolving

    assert :ok = RecoveryLedger.close(recovery_ledger)
    {:ok, reopened} = RecoveryLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: root)
    assert {:ok, durable_after_restart} = RecoveryLedger.current(reopened, moved_issue.id)
    assert durable_after_restart.last_validated_lifecycle_state == :ready
    assert durable_after_restart.active_suspension_context.status == :resolving
    assert :ok = RecoveryLedger.close(reopened)
  end

  test "a missing checkpoint stays fenced while a safe item dispatches after startup" do
    test_pid = self()
    Process.register(test_pid, :symphony_agent_router_capture)

    safe_issue = %Issue{
      id: "startup-safe-checkpoint",
      identifier: "SYM-H060B-SAFE",
      title: "Dispatch from trusted recovery state",
      state: "Planning",
      dispatchable: true
    }

    missing_issue = %Issue{
      id: "startup-missing-checkpoint",
      identifier: "SYM-H060B-MISSING",
      title: "Keep active state without recovery state fenced",
      state: "Planning",
      dispatchable: true
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Planning"],
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [safe_issue, missing_issue])
    seed_recovery_checkpoint!(safe_issue)

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: nil,
        candidates: []
      )

    name = Module.concat(__MODULE__, "IndependentSafe#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: name,
        start_quiesced: true,
        transition_coordinator: coordinator,
        agent_runner: SymphonyElixir.StartupReconciliationRunnerFake
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)

      if Process.whereis(:symphony_agent_router_capture) == test_pid,
        do: Process.unregister(:symphony_agent_router_capture)
    end)

    pending_state = :sys.get_state(pid)
    assert pending_state.startup_reconciliation == :pending
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(pending_state)
    send(pid, :tick)

    assert_receive {:fake_agent_run, ^safe_issue, _opts}, 1_000

    reconciled_state = :sys.get_state(pid)
    assert reconciled_state.startup_reconciliation == :ready
    assert WorkItem.authority_available?(reconciled_state.work_control[safe_issue.id])
    assert WorkItem.suspended?(reconciled_state.work_control[missing_issue.id])
    refute Map.has_key?(reconciled_state.recovery_checkpoints, missing_issue.id)
    refute_receive {:fake_agent_run, ^missing_issue, _opts}, 100
  end

  test "verified transition authority is checkpointed before it is released" do
    project_id = "transition-checkpoint-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "symphony-transition-checkpoint-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      symphony_project_id: project_id,
      poll_interval_ms: 60_000
    )

    issue = %Issue{id: "transition-authority-checkpoint", state: "Ready"}

    {:ok, ready_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :ready
      })

    {:ok, recovery_ledger} =
      RecoveryLedger.open(project_id, Tracker.identity(Config.settings!().tracker), root: root)

    on_exit(fn ->
      RecoveryLedger.close(recovery_ledger)
      File.rm_rf(root)
    end)

    state = %State{
      startup_reconciliation: :ready,
      recovery_ledger: recovery_ledger,
      recovery_ledger_status: :ready,
      work_control: %{issue.id => ready_item}
    }

    assert {:reply, :ok, persisted_state} =
             Orchestrator.handle_call(
               {:apply_transition_result, issue.id, ready_item, []},
               {self(), make_ref()},
               state
             )

    assert {:ok, ready_checkpoint} = RecoveryLedger.current(recovery_ledger, issue.id)
    assert ready_checkpoint.last_validated_lifecycle_state == :ready
    assert persisted_state.recovery_checkpoints[issue.id] == ready_checkpoint

    {:ok, progressed_item} =
      WorkItem.from_issue(%{issue | state: "In Progress"}, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :in_progress
      })

    assert {:reply, {:error, :startup_reconciliation_pending}, _pending_state} =
             Orchestrator.handle_call(
               {:apply_transition_result, issue.id, progressed_item, []},
               {self(), make_ref()},
               %{persisted_state | startup_reconciliation: :pending}
             )

    assert {:reply, {:error, :transition_reconciliation_pending}, _pending_candidate_state} =
             Orchestrator.handle_call(
               {:apply_transition_result, issue.id, progressed_item, []},
               {self(), make_ref()},
               %{persisted_state | transition_reconciliation_candidates: [%{work_item_id: issue.id}]}
             )

    missing_ledger_state = %{
      persisted_state
      | recovery_ledger: nil,
        recovery_ledger_status: {:blocked, {:recovery_ledger_unavailable, :missing_handle}}
    }

    assert {:reply, {:error, {:recovery_ledger_unavailable, :missing_recovery_ledger}}, blocked_state} =
             Orchestrator.handle_call(
               {:apply_transition_result, issue.id, progressed_item, []},
               {self(), make_ref()},
               missing_ledger_state
             )

    assert blocked_state.startup_reconciliation ==
             {:blocked, {:recovery_ledger_unavailable, :missing_recovery_ledger}}

    failure_cases = [
      {
        %{recovery_ledger | write_fun: fn _table, _records -> {:error, :disk_full} end},
        {:ledger_write_failed, :disk_full}
      },
      {
        %{recovery_ledger | sync_fun: fn _table -> {:error, :sync_failed} end},
        {:ledger_sync_failed, :sync_failed}
      }
    ]

    for {failing_ledger, persistence_reason} <- failure_cases do
      failing_state = %{persisted_state | recovery_ledger: failing_ledger}

      assert {:reply, {:error, {:recovery_ledger_unavailable, ^persistence_reason}}, blocked_state} =
               Orchestrator.handle_call(
                 {:apply_transition_result, issue.id, progressed_item, []},
                 {self(), make_ref()},
                 failing_state
               )

      assert blocked_state.startup_reconciliation == {:blocked, {:recovery_ledger_unavailable, persistence_reason}}
      assert blocked_state.work_control[issue.id] == ready_item
      assert blocked_state.recovery_checkpoints[issue.id] == ready_checkpoint
    end

    assert {:reply, {:ok, suspended_item}, suspended_state} =
             Orchestrator.handle_call(
               {:suspend_work_item, issue.id, :provider_failed},
               {self(), make_ref()},
               persisted_state
             )

    assert WorkItem.suspended?(suspended_item)
    assert {:ok, suspended_checkpoint} = RecoveryLedger.current(recovery_ledger, issue.id)
    assert suspended_checkpoint.active_suspension_context.status == :open
    assert suspended_state.recovery_checkpoints[issue.id] == suspended_checkpoint

    suspension_failures = [
      {
        %{recovery_ledger | write_fun: fn _table, _records -> {:error, :suspension_disk_full} end},
        {:ledger_write_failed, :suspension_disk_full}
      },
      {
        %{recovery_ledger | sync_fun: fn _table -> {:error, :suspension_sync_failed} end},
        {:ledger_sync_failed, :suspension_sync_failed}
      }
    ]

    for {failing_ledger, persistence_reason} <- suspension_failures do
      failing_state = %{persisted_state | recovery_ledger: failing_ledger}

      assert {:reply, {:error, {:recovery_ledger_unavailable, ^persistence_reason}}, blocked_state} =
               Orchestrator.handle_call(
                 {:suspend_work_item, issue.id, :provider_failed},
                 {self(), make_ref()},
                 failing_state
               )

      assert blocked_state.startup_reconciliation == {:blocked, {:recovery_ledger_unavailable, persistence_reason}}
      assert blocked_state.work_control[issue.id] == ready_item
      assert blocked_state.recovery_checkpoints[issue.id] == ready_checkpoint
    end
  end

  test "syncs a resolved recovery checkpoint before writing an H-040 marker" do
    project_id = "startup-order-#{System.unique_integer([:positive])}"
    work_item_id = "startup-order-item"
    ledger_root = Path.join(System.tmp_dir!(), "symphony-startup-order-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done"],
      poll_interval_ms: 60_000
    )

    identity = %{tracker_kind: "memory", provider_scope: %{}}
    {:ok, ledger} = RecoveryLedger.open(project_id, identity, root: ledger_root)

    on_exit(fn ->
      RecoveryLedger.close(ledger)
      File.rm_rf(ledger_root)
    end)

    observed_at = DateTime.utc_now()

    observation = %ProviderObservation{
      provider: :plane,
      work_item_id: work_item_id,
      workspace_id: "workspace-a",
      project_id: "provider-project-a",
      provider_state_id: "state-in-progress",
      provider_state_group: "started",
      provider_state_name: "In Progress",
      observed_at: observed_at,
      snapshot_identity: "snapshot-a"
    }

    {:ok, suspension} =
      SuspensionContext.new(%{
        work_item_id: work_item_id,
        last_validated_lifecycle_state: :in_progress,
        provider_observation: observation,
        reason: :conflict,
        created_at: observed_at,
        recovery_policy: :fresh_reconciliation,
        required_evidence: [],
        resume_target: :in_progress
      })

    checkpoint = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :in_progress,
      durable_guard_evidence: [],
      active_suspension_context: suspension,
      last_terminal_suspension_context: nil,
      updated_at: observed_at
    }

    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)

    assessment = %LifecycleAssessment{
      work_item_id: work_item_id,
      provider_observation: observation,
      mapped_state: :in_progress,
      validated_state: :in_progress,
      status: :validated,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      assessed_at: observed_at
    }

    work_item = %WorkItem{
      id: work_item_id,
      provider_observation: observation,
      lifecycle_assessment: assessment,
      validated_lifecycle_state: :in_progress,
      authority_disposition: AuthorityDisposition.derive(assessment)
    }

    issue = %Issue{id: work_item_id, identifier: "SYM-ORDER", state: "In Progress"}

    candidate = %{
      attempt_id: "attempt-a",
      work_item_id: work_item_id,
      status: :indeterminate,
      source_state: :ready,
      target_state: :in_progress
    }

    second_candidate = %{candidate | attempt_id: "attempt-b"}
    candidates = [candidate, second_candidate]

    {:ok, coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: ledger,
        candidates: candidates
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator)
    end)

    state = %State{
      transition_coordinator: coordinator,
      recovery_ledger: ledger,
      recovery_ledger_status: :ready,
      recovery_checkpoints: %{work_item_id => checkpoint},
      work_control: %{work_item_id => work_item},
      dependency_diagnostics: %{work_item_id => %{allowed?: true}},
      dependency_graph: Graph.build([issue])
    }

    assert {:ok, reconciled_state} =
             Orchestrator.reconcile_startup_transition_candidates_for_test(
               state,
               candidates,
               Graph.build([issue])
             )

    assert_receive {:checkpoint_before_transition_marker, first_candidate_checkpoint}
    assert first_candidate_checkpoint.active_suspension_context.status == :resolving

    assert_receive {:checkpoint_before_transition_marker, marker_checkpoint}
    assert marker_checkpoint.active_suspension_context == nil
    assert marker_checkpoint.last_terminal_suspension_context.status == :resolved
    assert RecoveryLedger.current(ledger, work_item_id) == {:ok, marker_checkpoint}
    assert reconciled_state.recovery_checkpoints[work_item_id] == marker_checkpoint
    refute WorkItem.suspended?(reconciled_state.work_control[work_item_id])

    for {sync_response, list_response, expected} <- [
          {{:error, :coordinator_down}, nil, {:blocked, {:transition_coordinator_unavailable, :coordinator_down}}},
          {{:error, :transitions_disabled}, nil, :legacy_disabled},
          {:ok, {:error, :list_down}, {:blocked, {:transition_coordinator_unavailable, :list_down}}},
          {:ok, :malformed, {:blocked, :invalid_transition_reconciliation_candidates}}
        ] do
      {:ok, candidate_list_coordinator} =
        SymphonyElixir.StartupOrderingCoordinator.start_link(
          parent: self(),
          ledger: ledger,
          candidates: [],
          sync_response: sync_response,
          list_response: list_response
        )

      on_exit(fn ->
        if Process.alive?(candidate_list_coordinator), do: GenServer.stop(candidate_list_coordinator)
      end)

      candidate_list_result =
        Orchestrator.reconcile_startup_transition_candidates_for_test(
          %{state | transition_coordinator: candidate_list_coordinator},
          [],
          Graph.build([issue])
        )

      case expected do
        :legacy_disabled ->
          assert {:ok, %{transition_reconciliation_candidates: []}} = candidate_list_result

        {:blocked, reason} ->
          assert {:blocked, _blocked_state, ^reason} = candidate_list_result
      end
    end

    attempt_root = ledger_root <> "-attempts"
    {:ok, attempt_ledger} = AttemptLedger.open(project_id, identity, root: attempt_root)

    on_exit(fn ->
      AttemptLedger.close(attempt_ledger)
      File.rm_rf(attempt_root)
    end)

    assert {:ok, in_flight_record} = AttemptLedger.fence_attempt(attempt_ledger, work_item_id)
    assert in_flight_record.in_flight

    stale_state = %{
      reconciled_state
      | attempt_ledger: attempt_ledger,
        durable_in_flight: MapSet.new([work_item_id])
    }

    assert {:ok, cleared_state} = Orchestrator.clear_stale_in_flight_for_test(stale_state, work_item_id)
    assert {:ok, %{in_flight: false}} = AttemptLedger.current(attempt_ledger, work_item_id)
    refute MapSet.member?(cleared_state.durable_in_flight, work_item_id)

    unresolved_suspension_state = %{
      stale_state
      | recovery_checkpoints: state.recovery_checkpoints
    }

    assert {:ok, blocked_stale_state} =
             Orchestrator.clear_stale_in_flight_for_test(unresolved_suspension_state, work_item_id)

    assert blocked_stale_state.durable_blocked[work_item_id] == :stale_in_flight_suspension_unresolved
    assert {:ok, %{in_flight: false}} = AttemptLedger.current(attempt_ledger, work_item_id)

    stale_in_flight_cases = [
      {
        %{stale_state | durable_exhausted: %{work_item_id => "lineage-old"}},
        :stale_in_flight_lineage_exhausted
      },
      {
        %{stale_state | transition_reconciliation_candidates: [candidate]},
        :stale_in_flight_transition_unresolved
      },
      {%{stale_state | work_control: %{}}, :stale_in_flight_work_item_unavailable},
      {
        %{
          stale_state
          | work_control: %{
              work_item_id => %{work_item | lifecycle_assessment: %{assessment | status: :stale}}
            }
        },
        :stale_in_flight_lifecycle_unvalidated
      },
      {
        %{stale_state | dependency_diagnostics: %{work_item_id => %{allowed?: false}}},
        :stale_in_flight_dependency_unavailable
      }
    ]

    for {unsafe_state, expected_reason} <- stale_in_flight_cases do
      assert {:ok, blocked_state} = Orchestrator.clear_stale_in_flight_for_test(unsafe_state, work_item_id)
      assert blocked_state.durable_blocked[work_item_id] == expected_reason
      assert MapSet.member?(blocked_state.durable_in_flight, work_item_id)
    end

    running_state = %{stale_state | running: %{work_item_id => self()}}
    assert {:ok, still_running_state} = Orchestrator.clear_stale_in_flight_for_test(running_state, work_item_id)
    assert MapSet.member?(still_running_state.durable_in_flight, work_item_id)

    assert {:blocked, unavailable_attempt_ledger_state, {:stale_in_flight_attempt_ledger_unavailable, ^work_item_id}} =
             Orchestrator.clear_stale_in_flight_for_test(%{stale_state | attempt_ledger: nil}, work_item_id)

    assert MapSet.member?(unavailable_attempt_ledger_state.durable_in_flight, work_item_id)

    assert {:ok, _in_flight_record} = AttemptLedger.fence_attempt(attempt_ledger, work_item_id)
    failing_attempt_ledger = %{attempt_ledger | write_fun: fn _table, _records -> {:error, :disk_full} end}

    assert {:blocked, clear_failed_state,
            {
              :attempt_ledger_clear_in_flight_failed,
              ^work_item_id,
              {:ledger_write_failed, :disk_full}
            }} =
             Orchestrator.clear_stale_in_flight_for_test(
               %{stale_state | attempt_ledger: failing_attempt_ledger},
               work_item_id
             )

    assert match?(
             {:blocked, {:attempt_ledger_unavailable, {:ledger_write_failed, :disk_full}}},
             clear_failed_state.attempt_ledger_status
           )

    assert {:unresolved, ^state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(state, :invalid, %{})

    assert {:unresolved, exhausted_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | durable_exhausted: %{work_item_id => "lineage-old"}},
               candidate,
               %{work_item_id => issue}
             )

    assert Map.has_key?(exhausted_state.durable_blocked, work_item_id)

    assert {:unresolved, dependency_blocked_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | dependency_diagnostics: %{work_item_id => %{allowed?: false}}},
               candidate,
               %{work_item_id => issue}
             )

    assert Map.has_key?(dependency_blocked_state.durable_blocked, work_item_id)

    assert {:unresolved, missing_checkpoint_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | recovery_checkpoints: %{}},
               candidate,
               %{work_item_id => issue}
             )

    assert Map.has_key?(missing_checkpoint_state.durable_blocked, work_item_id)

    invalid_assessment = %{assessment | status: :validation_required}
    invalid_lifecycle_item = %{work_item | lifecycle_assessment: invalid_assessment}

    assert {:unresolved, invalid_lifecycle_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | work_control: %{work_item_id => invalid_lifecycle_item}},
               candidate,
               %{work_item_id => issue}
             )

    assert invalid_lifecycle_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    suspended_item = %{
      work_item
      | authority_disposition:
          AuthorityDisposition.new(%{
            status: :suspended,
            lifecycle_state: :in_progress,
            reason: :retry_exhausted
          })
    }

    assert {:unresolved, suspended_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | recovery_checkpoints: %{}, work_control: %{work_item_id => suspended_item}},
               candidate,
               %{work_item_id => issue}
             )

    assert suspended_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    other_suspension = %{suspension | reason: :retry_exhausted}
    other_context_checkpoint = %{checkpoint | active_suspension_context: other_suspension}

    assert {:unresolved, other_context_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | recovery_checkpoints: %{work_item_id => other_context_checkpoint}},
               candidate,
               %{work_item_id => issue}
             )

    assert other_context_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    missing_identity_observation = %{observation | snapshot_identity: nil}
    missing_identity_item = %{work_item | provider_observation: missing_identity_observation}

    assert {:unresolved, missing_identity_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | work_control: %{work_item_id => missing_identity_item}},
               candidate,
               %{work_item_id => issue}
             )

    assert missing_identity_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    no_outcome_candidate = %{candidate | source_state: :in_progress, target_state: :done}

    assert {:unresolved, no_outcome_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               state,
               no_outcome_candidate,
               %{work_item_id => issue}
             )

    assert no_outcome_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    invalid_lifecycle_checkpoint = %{
      checkpoint
      | last_validated_lifecycle_state: :unknown,
        active_suspension_context: nil
    }

    assert {:unresolved, invalid_checkpoint_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | recovery_checkpoints: %{work_item_id => invalid_lifecycle_checkpoint}},
               candidate,
               %{work_item_id => issue}
             )

    assert invalid_checkpoint_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    missing_observation_item = %{work_item | provider_observation: nil}
    checkpoint_without_active_context = %{checkpoint | active_suspension_context: nil}

    assert {:unresolved, missing_observation_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{
                 state
                 | work_control: %{work_item_id => missing_observation_item},
                   recovery_checkpoints: %{work_item_id => checkpoint_without_active_context}
               },
               candidate,
               %{work_item_id => issue}
             )

    assert missing_observation_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    assert {:unresolved, missing_ledger_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{state | recovery_ledger: nil},
               candidate,
               %{work_item_id => issue}
             )

    assert missing_ledger_state.durable_blocked[work_item_id] == :transition_reconciliation_unresolved

    for list_response <- [{:error, :unavailable}, :malformed] do
      {:ok, list_failure_coordinator} =
        SymphonyElixir.StartupOrderingCoordinator.start_link(
          parent: self(),
          ledger: ledger,
          candidates: [candidate],
          list_response: list_response
        )

      on_exit(fn ->
        if Process.alive?(list_failure_coordinator), do: GenServer.stop(list_failure_coordinator)
      end)

      list_failure_state = %{state | transition_coordinator: list_failure_coordinator}

      assert {:blocked, _blocked_state, {:transition_coordinator_unavailable, _reason}} =
               Orchestrator.reconcile_startup_transition_candidate_for_test(
                 list_failure_state,
                 candidate,
                 %{work_item_id => issue}
               )
    end

    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint_without_active_context)

    {:ok, checkpoint_recovery_coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: ledger,
        candidates: [candidate]
      )

    on_exit(fn ->
      if Process.alive?(checkpoint_recovery_coordinator), do: GenServer.stop(checkpoint_recovery_coordinator)
    end)

    assert {:reconciled, checkpoint_recovered_state} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{
                 state
                 | transition_coordinator: checkpoint_recovery_coordinator,
                   recovery_checkpoints: %{work_item_id => checkpoint_without_active_context}
               },
               candidate,
               %{work_item_id => issue}
             )

    assert_receive {:checkpoint_before_transition_marker, recovered_checkpoint}
    assert recovered_checkpoint.active_suspension_context == nil
    assert recovered_checkpoint.last_terminal_suspension_context.status == :resolved
    refute WorkItem.suspended?(checkpoint_recovered_state.work_control[work_item_id])

    failing_recovery_ledger = %{ledger | sync_fun: fn _table -> {:error, :checkpoint_disk_failure} end}

    {:ok, recovery_failure_coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: ledger,
        candidates: [candidate]
      )

    on_exit(fn ->
      if Process.alive?(recovery_failure_coordinator), do: GenServer.stop(recovery_failure_coordinator)
    end)

    assert {:blocked, _blocked_state, {:recovery_ledger_sync_failed, ^work_item_id, :checkpoint_disk_failure}} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{reconciled_state | recovery_ledger: failing_recovery_ledger},
               candidate,
               %{work_item_id => issue}
             )

    refute_receive {:checkpoint_before_transition_marker, _checkpoint}

    {:ok, failing_coordinator} =
      SymphonyElixir.StartupOrderingCoordinator.start_link(
        parent: self(),
        ledger: ledger,
        candidates: [candidate],
        reconcile_response: {:error, {:ledger_sync_failed, :marker_disk_failure}}
      )

    on_exit(fn ->
      if Process.alive?(failing_coordinator), do: GenServer.stop(failing_coordinator)
    end)

    assert {:blocked, blocked_state, marker_sync_failure} =
             Orchestrator.reconcile_startup_transition_candidate_for_test(
               %{reconciled_state | transition_coordinator: failing_coordinator},
               candidate,
               %{work_item_id => issue}
             )

    assert marker_sync_failure == {:transition_reconciliation_marker_sync_failed, work_item_id, :marker_disk_failure}

    assert_receive {:checkpoint_before_transition_marker, blocked_checkpoint}
    assert blocked_checkpoint.active_suspension_context == nil
    assert WorkItem.suspended?(blocked_state.work_control[work_item_id])
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp recovery_checkpoint(project_id, work_item_id, lifecycle_state) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: project_id,
      work_item_id: work_item_id,
      last_validated_lifecycle_state: lifecycle_state,
      durable_guard_evidence: [],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: DateTime.utc_now()
    }
  end
end
