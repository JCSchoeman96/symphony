defmodule SymphonyElixir.RuntimeAttemptTeardownTest do
  use SymphonyElixir.TestSupport, async: true

  alias SymphonyElixir.AgentRuntime.AttemptLedger
  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @issue_id "runtime-teardown-1"
  @lineage "lineage-teardown"

  defp sample_route do
    %Route{
      issue_id: @issue_id,
      starting_state: "In Progress",
      profile_name: "implementation",
      runtime_name: "codex",
      responsibility: "implementation",
      fingerprint: "fp-teardown",
      starting_state_fingerprint: "sfp-teardown"
    }
  end

  defp sample_identity(attempt_id) do
    %Identity{
      runtime_attempt_id: attempt_id,
      work_item_id: @issue_id,
      lineage_generation: @lineage,
      responsibility: "implementation",
      runtime_profile: "implementation"
    }
  end

  defp running_worker do
    spawn(fn ->
      receive do
        :done -> :ok
      end
    end)
  end

  defp temporary_ledger_root do
    Path.join(
      System.tmp_dir!(),
      "symphony-attempt-ledger-#{System.unique_integer([:positive])}"
    )
  end

  defp open_ledger_with_in_flight! do
    project_id = "teardown-ledger-#{System.unique_integer([:positive])}"
    root = temporary_ledger_root()
    File.mkdir_p!(root)
    path = AttemptLedger.path_for(project_id, root: root)

    {:ok, ledger} =
      AttemptLedger.open(project_id, Tracker.identity(Config.settings!().tracker), path: path)

    assert {:ok, %{in_flight: true}} =
             AttemptLedger.begin_attempt(ledger, @issue_id, route_fingerprint: "fp-teardown")

    {ledger, path, project_id}
  end

  defp base_orchestrator_state(running, extra \\ %{}) do
    Map.merge(
      %{
        attempt_ledger_status: :disabled,
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        running: running
      },
      extra
    )
    |> then(&struct(Orchestrator.State, &1))
  end

  defp provider_observation(state_name) do
    {:ok, observation} =
      ProviderObservation.new(%{
        provider: :memory,
        work_item_id: @issue_id,
        provider_state_name: state_name,
        observed_at: DateTime.utc_now()
      })

    observation
  end

  defp completion_validated_assessment(display_name) do
    proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)

    assessment =
      LifecycleAssessment.assess(provider_observation("Done"), :done, proof)

    observation = %{assessment.provider_observation | provider_state_name: display_name}
    %{assessment | provider_observation: observation}
  end

  defp plane_contract_config do
    %{
      schema_version: 1,
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      state_mappings:
        Map.new(WorkflowLifecycle.states(), fn state ->
          {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
        end)
    }
  end

  defp plane_done_issue(display_name) do
    %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: display_name,
      url: "https://example.org/issues/rt-1",
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-done",
      provider_state_group: :completed
    }
  end

  defp configure_plane_routed_workflow! do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["In Progress"],
      tracker_terminal_states: ["Done", "Shipped", "Canceled", "Cancelled"],
      provider_project_contract: plane_contract_config()
    )

    case WorkflowStore.force_reload() do
      :ok -> :ok
      {:error, reason} -> flunk("plane workflow reload failed: #{inspect(reason)}")
    end

    assert Config.settings!().agent.routing == "routed"
    assert %ProviderProjectContract{} = Config.settings!().provider_project_contract
  end

  defp work_item_with_assessment(issue, assessment) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :in_progress
      })

    %{
      work_item
      | lifecycle_assessment: assessment,
        validated_lifecycle_state: assessment.validated_state
    }
  end

  defp base_running_entry(worker_pid, runtime_state) do
    identity = sample_identity("attempt-live")

    %{
      pid: worker_pid,
      ref: Process.monitor(worker_pid),
      identifier: "RT-1",
      issue: %Issue{
        id: @issue_id,
        identifier: "RT-1",
        state: "In Progress",
        url: "https://example.org/issues/rt-1"
      },
      session_id: "session-teardown",
      retry_attempt: 0,
      started_at: DateTime.utc_now(),
      runtime_attempt: RuntimeAttempt.new(identity, runtime_state)
    }
  end

  test "terminate_running_issue transitions authority-revoked attempts to cancelled before teardown" do
    worker_pid = running_worker()
    running_entry = base_running_entry(worker_pid, :running)

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{claimed: MapSet.new([@issue_id])})

    updated =
      Orchestrator.terminate_running_issue_for_test(state, @issue_id, false, :observed)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)
    assert MapSet.disjoint?(updated.claimed, MapSet.new([@issue_id]))
  end

  test "terminate_running_issue fails closed when the required RuntimeAttempt transition is invalid" do
    worker_pid = running_worker()
    running_entry = base_running_entry(worker_pid, :completed)

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{claimed: MapSet.new([@issue_id])})

    updated =
      Orchestrator.terminate_running_issue_for_test(state, @issue_id, false, :observed)

    assert Process.alive?(worker_pid)
    assert updated.running[@issue_id].runtime_attempt.state == :completed
    assert MapSet.member?(updated.claimed, @issue_id)
    refute Map.has_key?(updated.retry_attempts, @issue_id)
  end

  test "stall retry transitions running attempts to retry_queued before scheduling replacement" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    worker_pid = running_worker()
    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)

    running_entry =
      base_running_entry(worker_pid, :running)
      |> Map.merge(%{
        last_codex_timestamp: stale_activity_at,
        last_codex_event: :notification,
        started_at: stale_activity_at
      })

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{claimed: MapSet.new([@issue_id])})

    updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)
    assert Map.has_key?(updated.retry_attempts, @issue_id)
  end

  test "stall retry fails closed when RuntimeAttempt cannot enter retry_queued" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      codex_stall_timeout_ms: 1_000
    )

    worker_pid = running_worker()
    stale_activity_at = DateTime.add(DateTime.utc_now(), -5, :second)

    running_entry =
      base_running_entry(worker_pid, :completed)
      |> Map.merge(%{
        last_codex_timestamp: stale_activity_at,
        last_codex_event: :notification,
        started_at: stale_activity_at
      })

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{claimed: MapSet.new([@issue_id])})

    updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

    assert Process.alive?(worker_pid)
    assert updated.running[@issue_id].runtime_attempt.state == :completed
    refute Map.has_key?(updated.retry_attempts, @issue_id)
  end

  test "poll route-change retry transitions to retry_queued before scheduling replacement" do
    worker_pid = running_worker()
    previous_route = sample_route()
    next_route = %{previous_route | profile_name: "review", responsibility: "review", fingerprint: "fp-review"}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      title: "Route change teardown",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry =
      base_running_entry(worker_pid, :running)
      |> Map.put(:route, previous_route)

    state = base_orchestrator_state(%{@issue_id => running_entry})

    updated =
      Orchestrator.stop_running_issue_for_route_change_for_test(
        state,
        issue,
        running_entry,
        previous_route,
        next_route
      )

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)

    assert %{
             error: "route changed during poll refresh",
             delay_type: :route_change
           } = updated.retry_attempts[@issue_id]
  end

  test "poll route-change retry fails closed when RuntimeAttempt cannot enter retry_queued" do
    worker_pid = running_worker()
    previous_route = sample_route()
    next_route = %{previous_route | profile_name: "review", responsibility: "review", fingerprint: "fp-review"}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      title: "Route change teardown",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry =
      base_running_entry(worker_pid, :completed)
      |> Map.put(:route, previous_route)

    state = base_orchestrator_state(%{@issue_id => running_entry})

    updated =
      Orchestrator.stop_running_issue_for_route_change_for_test(
        state,
        issue,
        running_entry,
        previous_route,
        next_route
      )

    assert Process.alive?(worker_pid)
    assert updated.running[@issue_id].runtime_attempt.state == :completed
    refute Map.has_key?(updated.retry_attempts, @issue_id)
  end

  test "tracker canceled during starting maps to cancelled terminal teardown" do
    worker_pid = running_worker()

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Canceled",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = base_running_entry(worker_pid, :starting) |> Map.put(:issue, issue)

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{claimed: MapSet.new([@issue_id])})

    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_cancelled

    updated =
      Orchestrator.terminate_running_issue_for_test(state, @issue_id, false, :terminal_cancelled)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)
  end

  test "tracker canceled while running maps to cancelled terminal teardown" do
    worker_pid = running_worker()

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Canceled",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = base_running_entry(worker_pid, :running) |> Map.put(:issue, issue)
    state = base_orchestrator_state(%{@issue_id => running_entry})

    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_cancelled

    updated =
      Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)
  end

  test "renamed provider display with completion-validated assessment maps to completed teardown" do
    assessment = completion_validated_assessment("Shipped")
    assert LifecycleAssessment.completion_validated?(assessment)

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Shipped",
      url: "https://example.org/issues/rt-1"
    }

    work_item = work_item_with_assessment(issue, assessment)
    state = base_orchestrator_state(%{}, %{work_control: %{@issue_id => work_item}})

    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_completed
  end

  test "reconcile refresh retains completion proof when only Plane display name changes" do
    configure_plane_routed_workflow!()
    contract = Config.settings!().provider_project_contract
    proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
    issue_done = plane_done_issue("Done")

    assert {:ok, previous} =
             WorkItem.from_issue(issue_done, %{
               provider: :memory,
               prior_validated_lifecycle_state: :merging,
               evidence: [proof],
               provider_project_contract: contract
             })

    assert LifecycleAssessment.completion_validated?(previous.lifecycle_assessment)

    worker_pid = running_worker()
    running_entry = base_running_entry(worker_pid, :running) |> Map.put(:issue, issue_done)

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{
        work_control: %{@issue_id => previous},
        claimed: MapSet.new([@issue_id])
      })

    issue_shipped = %{issue_done | state: "Shipped"}

    updated = Orchestrator.reconcile_issue_states_for_test([issue_shipped], state)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)

    refreshed = updated.work_control[@issue_id]
    assert refreshed.provider_observation.provider_state_name == "Shipped"
    assert LifecycleAssessment.completion_validated?(refreshed.lifecycle_assessment)
    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue_shipped, updated) == :terminal_completed
  end

  test "reconcile refresh drops completion proof when provider state UUID changes" do
    configure_plane_routed_workflow!()
    contract = Config.settings!().provider_project_contract
    proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
    issue_done = plane_done_issue("Done")

    assert {:ok, previous} =
             WorkItem.from_issue(issue_done, %{
               provider: :memory,
               prior_validated_lifecycle_state: :merging,
               evidence: [proof],
               provider_project_contract: contract
             })

    worker_pid = running_worker()
    running_entry = base_running_entry(worker_pid, :running) |> Map.put(:issue, issue_done)

    state =
      base_orchestrator_state(%{@issue_id => running_entry}, %{
        work_control: %{@issue_id => previous},
        claimed: MapSet.new([@issue_id])
      })

    issue_in_progress =
      %{
        issue_done
        | state: "In Progress",
          provider_state_id: "state-in_progress",
          provider_state_group: :started
      }

    updated = Orchestrator.refresh_work_control_for_test(state, [issue_in_progress])

    refreshed = updated.work_control[@issue_id]
    refute LifecycleAssessment.completion_validated?(refreshed.lifecycle_assessment)
    assert refreshed.lifecycle_assessment.mapped_state == :in_progress
  end

  test "provider-observed done without completion-validated assessment maps to cancelled teardown" do
    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Done",
      url: "https://example.org/issues/rt-1"
    }

    assessment = LifecycleAssessment.assess(provider_observation("Done"), :merging, [])
    work_item = work_item_with_assessment(issue, assessment)
    state = base_orchestrator_state(%{}, %{work_control: %{@issue_id => work_item}})

    refute LifecycleAssessment.completion_validated?(assessment)
    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_cancelled
  end

  test "provider-observed canceled maps to cancelled teardown" do
    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Canceled",
      url: "https://example.org/issues/rt-1"
    }

    assessment = LifecycleAssessment.assess(provider_observation("Canceled"), :in_progress, [])
    work_item = work_item_with_assessment(issue, assessment)
    state = base_orchestrator_state(%{}, %{work_control: %{@issue_id => work_item}})

    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_cancelled
  end

  test "tracker done without validated completion semantics maps to cancelled teardown" do
    worker_pid = running_worker()

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "Done",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = base_running_entry(worker_pid, :running) |> Map.put(:issue, issue)
    state = base_orchestrator_state(%{@issue_id => running_entry})

    assert Orchestrator.tracker_terminal_teardown_reason_for_test(issue, state) == :terminal_cancelled
  end

  test "normal continuation does not schedule when runtime session never reached running" do
    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry =
      base_running_entry(self(), :starting)
      |> Map.put(:issue, issue)
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)

    state = base_orchestrator_state(%{@issue_id => running_entry})

    updated = Orchestrator.handle_normal_continuation_for_test(state, @issue_id, running_entry)

    assert updated == state
    refute Map.has_key?(updated.retry_attempts, @issue_id)
    assert updated.running[@issue_id].runtime_attempt.state == :starting
  end

  test "agent route change schedules retry when durable clear succeeds after RetryQueued" do
    identity = sample_identity("route-clear-ok")
    route_change = %{previous: %{profile_name: "implementation"}, next: %{profile_name: "review"}}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :retry_queued),
      route: sample_route(),
      route_change: route_change
    }

    {ledger, _path, _project_id} = open_ledger_with_in_flight!()

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      running: %{@issue_id => running_entry},
      claimed: MapSet.new([@issue_id])
    }

    updated =
      Orchestrator.schedule_agent_route_change_retry_for_test(state, @issue_id, running_entry, route_change)

    assert updated.running[@issue_id].runtime_attempt.state == :retry_queued
    assert %{delay_type: :route_change} = updated.retry_attempts[@issue_id]
    assert updated.attempt_ledger_status == :ready
    refute Map.has_key?(updated.blocked, @issue_id)
  end

  test "worker DOWN route change blocks when review-cycle policy rejects retry before RetryQueued" do
    identity = sample_identity("route-down")

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      title: "Route change teardown",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    route_change = %{
      previous: %{profile_name: "review", responsibility: "review"},
      next: %{profile_name: "correction", responsibility: "correction"}
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :running),
      route_change: route_change
    }

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      attempt_counters: %{
        @issue_id => %{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 3}
      }
    }

    updated = Orchestrator.handle_normal_route_change_for_test(state, @issue_id, running_entry)

    assert Map.has_key?(updated.blocked, @issue_id)
    refute Map.has_key?(updated.retry_attempts, @issue_id)
    assert updated.blocked[@issue_id].termination_reason == :review_cycle_exhausted
  end

  test "worker DOWN route change blocks when durable review-cycle accounting fails before RetryQueued" do
    identity = sample_identity("route-down-accounting")

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      title: "Route change teardown",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    route_change = %{
      previous: %{profile_name: "review", responsibility: "review"},
      next: %{profile_name: "correction", responsibility: "correction"}
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :running),
      route_change: route_change
    }

    state = %Orchestrator.State{
      attempt_ledger_status: :ready,
      attempt_counters: %{@issue_id => %{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0}}
    }

    updated = Orchestrator.handle_normal_route_change_for_test(state, @issue_id, running_entry)

    assert Map.has_key?(updated.blocked, @issue_id)
    refute Map.has_key?(updated.retry_attempts, @issue_id)
    assert updated.blocked[@issue_id].error =~ "attempt ledger unavailable"
  end

  test "agent route change blocks issue when durable clear fails after RetryQueued" do
    identity = sample_identity("route-clear-fail")
    route_change = %{previous: %{profile_name: "implementation"}, next: %{profile_name: "review"}}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :retry_queued),
      route: sample_route(),
      route_change: route_change
    }

    {ledger, _path, _project_id} = open_ledger_with_in_flight!()
    :ok = :dets.insert(ledger.table, {{:current, @issue_id}, :corrupt})

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      running: %{@issue_id => running_entry},
      claimed: MapSet.new([@issue_id])
    }

    updated =
      Orchestrator.schedule_agent_route_change_retry_for_test(state, @issue_id, running_entry, route_change)

    refute Map.has_key?(updated.retry_attempts, @issue_id)
    refute Map.has_key?(updated.running, @issue_id)
    assert Map.has_key?(updated.blocked, @issue_id)
    assert MapSet.member?(updated.claimed, @issue_id)
    assert match?({:blocked, {:attempt_ledger_unavailable, _}}, updated.attempt_ledger_status)
    assert updated.blocked[@issue_id].error =~ "attempt ledger unavailable"
    assert RuntimeAttempt.terminal?(running_entry.runtime_attempt)
  end

  test "poll route change blocks issue when durable clear fails after RetryQueued" do
    identity = sample_identity("poll-clear-fail")
    route_change = %{previous: %{profile_name: "implementation"}, next: %{profile_name: "review"}}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :retry_queued),
      route: sample_route()
    }

    {ledger, _path, _project_id} = open_ledger_with_in_flight!()
    :ok = :dets.insert(ledger.table, {{:current, @issue_id}, :corrupt})

    state = %Orchestrator.State{
      attempt_ledger: ledger,
      attempt_ledger_status: :ready,
      claimed: MapSet.new([@issue_id])
    }

    updated =
      Orchestrator.schedule_poll_route_change_retry_for_test(
        state,
        issue,
        running_entry,
        1,
        route_change
      )

    refute Map.has_key?(updated.retry_attempts, @issue_id)
    refute Map.has_key?(updated.running, @issue_id)
    assert Map.has_key?(updated.blocked, @issue_id)
    assert MapSet.member?(updated.claimed, @issue_id)
    assert match?({:blocked, {:attempt_ledger_unavailable, _}}, updated.attempt_ledger_status)
  end

  test "route-change durable clear failure stays visible after ledger reconciliation" do
    identity = sample_identity("route-recovery")
    route_change = %{previous: %{profile_name: "implementation"}, next: %{profile_name: "review"}}

    issue = %Issue{
      id: @issue_id,
      identifier: "RT-1",
      state: "In Progress",
      url: "https://example.org/issues/rt-1"
    }

    running_entry = %{
      identifier: "RT-1",
      issue: issue,
      retry_attempt: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :retry_queued),
      route: sample_route(),
      route_change: route_change
    }

    {ledger, _path, project_id} = open_ledger_with_in_flight!()
    :ok = :dets.insert(ledger.table, {{:current, @issue_id}, :corrupt})

    blocked_state =
      Orchestrator.schedule_agent_route_change_retry_for_test(
        %Orchestrator.State{
          attempt_ledger: ledger,
          attempt_ledger_status: :ready,
          running: %{@issue_id => running_entry},
          claimed: MapSet.new([@issue_id])
        },
        @issue_id,
        running_entry,
        route_change
      )

    assert Map.has_key?(blocked_state.blocked, @issue_id)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    :ok = :dets.delete(ledger.table, {:current, @issue_id})

    assert {:ok, %{in_flight: true}} =
             AttemptLedger.begin_attempt(ledger, @issue_id, route_fingerprint: "fp-teardown")

    assert :ok = AttemptLedger.sync(ledger)

    recovered = Orchestrator.reconcile_blocked_ledger_for_test(blocked_state)

    assert recovered.attempt_ledger_status == :ready
    assert Map.has_key?(recovered.blocked, @issue_id)
    assert MapSet.member?(recovered.claimed, @issue_id)
    refute Map.has_key?(recovered.running, @issue_id)
    refute Map.has_key?(recovered.retry_attempts, @issue_id)
  end

  test "runtime unavailable teardown applies failed terminal transition before removal" do
    worker_pid = running_worker()
    running_entry = base_running_entry(worker_pid, :running)

    state = base_orchestrator_state(%{@issue_id => running_entry})

    updated =
      Orchestrator.terminate_running_issue_for_test(state, @issue_id, false, :runtime_unavailable)

    refute Process.alive?(worker_pid)
    refute Map.has_key?(updated.running, @issue_id)
  end
end
