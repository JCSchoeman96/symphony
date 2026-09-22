defmodule SymphonyElixir.RuntimeAttemptTeardownTest do
  use SymphonyElixir.TestSupport, async: true

  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.{GuardClass, LifecycleAssessment, ProviderObservation, WorkItem}

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
