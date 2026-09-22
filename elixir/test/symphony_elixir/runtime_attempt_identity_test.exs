defmodule SymphonyElixir.RuntimeAttemptIdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.GuardClass
  alias SymphonyElixir.WorkControl.WorkItem

  @issue_id "work-stale-1"
  @issue_b "work-stale-2"
  @lineage "lineage-abc"

  defp sample_route do
    %Route{
      issue_id: @issue_id,
      starting_state: "In Progress",
      profile_name: "implementation",
      runtime_name: "codex",
      responsibility: "implementation",
      fingerprint: "fp",
      starting_state_fingerprint: "sfp"
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

  test "Identity validation and equality cover host fencing fields" do
    left = sample_identity("attempt-a")
    right = sample_identity("attempt-b")

    assert Identity.valid?(left)
    refute Identity.valid?(%Identity{})
    refute Identity.same?(left, right)
    refute Identity.same?(left, %{left | lineage_generation: "other"})
    refute Identity.same?(left, %{left | responsibility: "review"})
    refute Identity.same?(left, %{left | runtime_profile: "review"})
    refute Identity.valid?(%{left | runtime_attempt_id: "  "})
    refute Identity.valid?(%{left | lineage_generation: ""})
    assert Identity.same?(left, %{left | responsibility: :implementation})
  end

  test "RuntimeAttempt lifecycle allows starting to running and rejects terminal resurrection" do
    identity = Identity.allocate(@issue_id, sample_route(), @lineage)
    attempt = RuntimeAttempt.new(identity, :starting)

    assert {:ok, running} = RuntimeAttempt.mark_running(attempt)
    assert running.state == :running

    assert {:ok, completed} = RuntimeAttempt.transition(running, :completed)

    for terminal <- [:completed, :retry_queued, :blocked, :failed, :cancelled] do
      terminal_attempt = if terminal == :completed, do: completed, else: RuntimeAttempt.new(identity, terminal)
      assert {:error, :invalid_transition} = RuntimeAttempt.mark_running(terminal_attempt)
      assert {:error, :invalid_transition} = RuntimeAttempt.transition(terminal_attempt, :running)
    end

    assert RuntimeAttempt.transition_allowed?(:queued, :starting)
    refute RuntimeAttempt.transition_allowed?(:completed, :running)
    assert RuntimeAttempt.terminal?(:failed)
    refute RuntimeAttempt.terminal?(:running)
  end

  test "host-generated runtime attempt ids differ between allocations" do
    left = Identity.allocate(@issue_id, sample_route(), @lineage)
    right = Identity.allocate(@issue_id, sample_route(), @lineage)
    refute left.runtime_attempt_id == right.runtime_attempt_id
  end

  test "GuardClass accepts opaque binary lineage_generation tokens" do
    assert {:ok, evidence} =
             GuardClass.semantic_attestation(:plan_attested, %{
               responsibility: "implementation",
               runtime_attempt_id: "attempt-1",
               lineage_generation: @lineage,
               subject: {:work_item, @issue_id},
               timestamp: DateTime.utc_now()
             })

    context = %{
      responsibility: "implementation",
      runtime_attempt_id: "attempt-1",
      lineage_generation: @lineage,
      subject: {:work_item, @issue_id}
    }

    assert GuardClass.valid_evidence?(evidence, context)
  end

  test "envelope work item mismatch fails closed before worker, codex, route, lifecycle, and dependency effects" do
    identity_a = sample_identity("attempt-a")
    identity_b = %{identity_a | work_item_id: @issue_b, runtime_attempt_id: "attempt-b"}

    state =
      dual_running_state(
        {@issue_id, identity_a, "host-a", "/workspace-a"},
        {@issue_b, identity_b, "host-b", "/workspace-b"}
      )

    assert {:noreply, unchanged} =
             Orchestrator.handle_info(
               {:worker_runtime_info, @issue_b, identity_a, %{worker_host: "evil", workspace_path: "/evil"}},
               state
             )

    assert unchanged.running[@issue_id].worker_host == "host-a"
    assert unchanged.running[@issue_b].worker_host == "host-b"

    codex_state = %{
      state
      | codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    update = %{event: :session_started, session_id: "evil", timestamp: DateTime.utc_now()}

    assert {:noreply, codex_unchanged} =
             Orchestrator.handle_info({:codex_worker_update, @issue_b, identity_a, update}, codex_state)

    assert is_nil(get_in(codex_unchanged.running, [@issue_b, :session_id]))

    previous_route = sample_route()
    next_route = %{previous_route | profile_name: "review", responsibility: "review"}

    assert {:noreply, route_unchanged} =
             Orchestrator.handle_info(
               {:agent_route_changed, @issue_b, identity_a, previous_route, next_route},
               state
             )

    refute get_in(route_unchanged.running, [@issue_id, :route_change_termination])
    refute get_in(route_unchanged.running, [@issue_b, :route_change_termination])

    assessment = %{status: :suspended}

    assert {:noreply, lifecycle_unchanged} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, @issue_b, identity_a, assessment},
               state
             )

    refute get_in(lifecycle_unchanged.running, [@issue_id, :lifecycle_suspension])
    refute get_in(lifecycle_unchanged.running, [@issue_b, :lifecycle_suspension])

    assert {:noreply, dependency_unchanged} =
             Orchestrator.handle_info(
               {:agent_dependency_blocked, @issue_b, identity_a, %{allowed?: false, reason: :blocked}},
               state
             )

    refute Map.has_key?(dependency_unchanged.blocked || %{}, @issue_id)
    refute Map.has_key?(dependency_unchanged.blocked || %{}, @issue_b)
  end

  test "wrong responsibility in identity fails closed even when envelope work item matches" do
    identity = sample_identity("attempt-a")
    forged = %{identity | responsibility: "review", runtime_profile: "review"}

    state =
      dual_running_state(
        {@issue_id, identity, "host-a", "/workspace-a"},
        {@issue_b, %{identity | work_item_id: @issue_b, runtime_attempt_id: "attempt-b"}, "host-b", "/workspace-b"}
      )

    assert {:noreply, unchanged} =
             Orchestrator.handle_info(
               {:worker_runtime_info, @issue_id, forged, %{worker_host: "evil", workspace_path: "/evil"}},
               state
             )

    assert unchanged.running[@issue_id].worker_host == "host-a"
  end

  test "stale worker runtime metadata cannot overwrite the current running entry" do
    current = sample_identity("current")
    stale = sample_identity("stale")

    running_entry = %{
      identifier: "SYM-1",
      worker_host: "host-a",
      workspace_path: "/current",
      runtime_attempt: RuntimeAttempt.new(current, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    assert {:noreply, unchanged} =
             Orchestrator.handle_info(
               {:worker_runtime_info, @issue_id, stale, %{worker_host: "host-b", workspace_path: "/stale"}},
               state
             )

    assert unchanged.running[@issue_id].worker_host == "host-a"
    assert unchanged.running[@issue_id].workspace_path == "/current"
  end

  test "current exact identity updates worker runtime metadata" do
    identity = sample_identity("current")

    running_entry = %{
      identifier: "SYM-1",
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    assert {:noreply, updated} =
             Orchestrator.handle_info(
               {:worker_runtime_info, @issue_id, identity, %{worker_host: "host-b", workspace_path: "/fresh"}},
               state
             )

    assert updated.running[@issue_id].worker_host == "host-b"
    assert updated.running[@issue_id].workspace_path == "/fresh"
  end

  test "current codex update mutates authoritative attempt state" do
    identity = sample_identity("current")
    now = DateTime.utc_now()

    running_entry = %{
      identifier: "SYM-1",
      turn_count: 0,
      session_id: nil,
      last_codex_event: nil,
      last_codex_timestamp: nil,
      last_codex_message: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }

    state = %Orchestrator.State{
      running: %{@issue_id => running_entry},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    update = %{event: :session_started, session_id: "session-1", timestamp: now}

    assert {:noreply, updated} =
             Orchestrator.handle_info({:codex_worker_update, @issue_id, identity, update}, state)

    assert updated.running[@issue_id].session_id == "session-1"
    assert updated.running[@issue_id].last_codex_event == :session_started
  end

  test "stale codex update cannot mutate current authoritative attempt state" do
    current = sample_identity("current")
    stale = sample_identity("stale")

    running_entry = %{
      identifier: "SYM-1",
      last_codex_event: :turn_completed,
      codex_total_tokens: 10,
      runtime_attempt: RuntimeAttempt.new(current, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    update = %{event: :turn_completed, timestamp: DateTime.utc_now(), total_tokens: 999}

    assert {:noreply, unchanged} =
             Orchestrator.handle_info({:codex_worker_update, @issue_id, stale, update}, state)

    assert unchanged.running[@issue_id].codex_total_tokens == 10
  end

  test "current lifecycle suspension is recorded for the matching runtime identity" do
    identity = sample_identity("current")
    assessment = %{status: :suspended, reason: :lifecycle_observation}

    running_entry = %{
      identifier: "SYM-1",
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    assert {:noreply, updated} =
             Orchestrator.handle_info(
               {:agent_lifecycle_suspended, @issue_id, identity, assessment},
               state
             )

    assert updated.running[@issue_id].lifecycle_suspension == assessment
  end

  test "current route change marks termination for the matching runtime identity" do
    identity = sample_identity("current")
    previous_route = sample_route()
    next_route = %{previous_route | responsibility: "review", profile_name: "review"}

    running_entry = %{
      identifier: "SYM-1",
      route_change_termination: false,
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    assert {:noreply, updated} =
             Orchestrator.handle_info(
               {:agent_route_changed, @issue_id, identity, previous_route, next_route},
               state
             )

    assert updated.running[@issue_id].route_change_termination
    assert updated.running[@issue_id].route_change != nil
  end

  test "stale route change and dependency stop are ignored for the current attempt" do
    current = sample_identity("current")
    stale = sample_identity("stale")
    previous_route = sample_route()
    next_route = %{previous_route | responsibility: "review", profile_name: "review"}

    running_entry = %{
      identifier: "SYM-1",
      route_change_termination: false,
      runtime_attempt: RuntimeAttempt.new(current, :running)
    }

    state = %Orchestrator.State{running: %{@issue_id => running_entry}}

    assert {:noreply, unchanged} =
             Orchestrator.handle_info(
               {:agent_route_changed, @issue_id, stale, previous_route, next_route},
               state
             )

    refute Map.get(unchanged.running[@issue_id], :route_change_termination)

    assert {:noreply, still_unchanged} =
             Orchestrator.handle_info(
               {:agent_dependency_blocked, @issue_id, stale, %{allowed?: false, reason: :blocked}},
               unchanged
             )

    assert still_unchanged.running[@issue_id].runtime_attempt.identity.runtime_attempt_id == "current"
  end

  test "transition context enforces expected runtime identity" do
    identity = sample_identity("live")
    state = orchestrator_handoff_state(identity)
    from = {self(), make_ref()}

    assert {:reply, {:ok, context}, _} =
             Orchestrator.handle_call(
               {:transition_context, @issue_id, [expected_runtime_identity: identity]},
               from,
               state
             )

    assert context.runtime_attempt_id == "live"
    assert context.lineage_generation == @lineage

    assert {:reply, {:error, :stale_runtime_attempt}, _} =
             Orchestrator.handle_call(
               {:transition_context, @issue_id, [expected_runtime_identity: sample_identity("stale")]},
               from,
               state
             )

    assert {:reply, {:ok, _context}, _} =
             Orchestrator.handle_call(
               {:transition_context, @issue_id,
                [
                  expected_runtime_identity: %{
                    runtime_attempt_id: "live",
                    lineage_generation: @lineage,
                    work_item_id: @issue_id,
                    responsibility: "implementation",
                    runtime_profile: "implementation"
                  }
                ]},
               from,
               state
             )
  end

  defp dual_running_state({id_a, identity_a, host_a, path_a}, {id_b, identity_b, host_b, path_b}) do
    %Orchestrator.State{
      running: %{
        id_a => running_entry(id_a, identity_a, host_a, path_a),
        id_b => running_entry(id_b, identity_b, host_b, path_b)
      }
    }
  end

  defp running_entry(issue_id, identity, host, path) do
    %{
      identifier: issue_id,
      worker_host: host,
      workspace_path: path,
      pid: nil,
      ref: make_ref(),
      route_change_termination: false,
      runtime_attempt: RuntimeAttempt.new(identity, :running)
    }
  end

  defp orchestrator_handoff_state(identity) do
    issue = %Issue{
      id: @issue_id,
      identifier: "SYM-1",
      title: "Runtime identity",
      state: "Ready",
      dependency_completeness: :complete
    }

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: :ready
      })

    %Orchestrator.State{
      work_control: %{issue.id => work_item},
      dependency_diagnostics: %{issue.id => %{allowed?: true}},
      dependency_graph: Graph.build([issue]),
      running: %{
        issue.id => %{
          profile_name: "implementation",
          runtime_attempt: RuntimeAttempt.new(identity, :running)
        }
      }
    }
  end
end
