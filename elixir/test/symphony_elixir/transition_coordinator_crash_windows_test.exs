defmodule SymphonyElixir.TransitionCoordinatorCrashWindowsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.TransitionCoordinator

  alias SymphonyElixir.WorkControl.{
    SemanticTransitionIntent,
    TransitionAttempt,
    TransitionAttemptLedger
  }

  @identity %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}
  @now ~U[2026-10-19 09:00:00Z]

  test "W1-W6 restart snapshots never dispatch a recovered candidate" do
    windows = [
      {:w1_fenced_prepared_before_submitted, :prepared, 0},
      {:w2_submitted_before_witness, :mutation_submitted, 0},
      {:w3_witness_acknowledged_before_finch, :mutation_submitted, 0},
      {:w4_request_may_have_been_sent, :mutation_submitted, 1},
      {:w5_response_before_verifying_sync, :mutation_submitted, 1},
      {:w6_verifying_during_fresh_reread, :verifying, 1}
    ]

    for {window, state, prior_provider_calls} <- windows do
      root = Path.join(System.tmp_dir!(), "symphony-transition-#{window}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      path = Path.join(root, "attempts.dets")

      {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
      candidate = attempt_at_state(window, state)
      assert :ok = TransitionAttemptLedger.put_sync(ledger, candidate)
      assert :ok = TransitionAttemptLedger.close(ledger)

      {:ok, reopened} = TransitionAttemptLedger.open("project-a", @identity, path: path)
      assert {:ok, [recovered]} = TransitionAttemptLedger.list_reconciliation_candidates(reopened)
      assert recovered.state == state
      assert recovered.attempt_id == candidate.attempt_id
      refute TransitionAttemptLedger.resubmit_allowed?(recovered)

      {:ok, calls} = Agent.start_link(fn -> prior_provider_calls end)

      {:ok, coordinator} =
        TransitionCoordinator.start_link(
          name: nil,
          ledger: reopened,
          load_context: fn _intent -> flunk("a recovered candidate must fence before fresh submission context") end,
          submit: fn _attempt, _context ->
            Agent.update(calls, &(&1 + 1))
            :ok
          end,
          verify: fn _attempt, _context -> flunk("restart must not invent a provider response") end
        )

      assert {:error, :transition_fenced} = TransitionCoordinator.request_transition(coordinator, intent())
      assert Agent.get(calls, & &1) == prior_provider_calls
      assert {:ok, ^recovered} = TransitionAttemptLedger.latest_for_work_item(reopened, "work-1")

      GenServer.stop(coordinator)
      Agent.stop(calls)
      File.rm_rf(root)
    end
  end

  defp attempt_at_state(window, requested_state) do
    attempt_id = "attempt-#{window}"
    transition_id = "transition-#{window}"

    attrs = %{
      attempt_id: attempt_id,
      transition_attempt_id: transition_id,
      work_item_id: "work-1",
      requested_from: :ready,
      requested_to: :in_progress,
      responsibility: "implementation",
      guard_evidence: [],
      requested_at: @now
    }

    {:ok, attempt} = TransitionAttempt.new(attrs)
    {:ok, authorized} = TransitionAttempt.authorize_intent(attempt, intent())

    fresh_context = %{
      provider: :plane,
      workspace_id: "workspace-a",
      project_id: "project-a",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      provider_contract_fingerprint: "sha256:contract",
      dependency_epoch_evidence: %{complete?: true}
    }

    {:ok, loaded} = TransitionAttempt.fresh_context_loaded(authorized, fresh_context)

    prepare_context = %{
      target_provider_state_id: "state-in-progress",
      target_provider_state_group: :started,
      provider_contract_fingerprint: "sha256:contract",
      dependency_epoch_evidence: %{complete?: true}
    }

    {:ok, prepared} = TransitionAttempt.prepare(loaded, prepare_context)
    {:ok, fenced} = TransitionAttempt.arm_submission_fence(prepared, %{at: @now})

    if requested_state in [:mutation_submitted, :verifying] do
      {:ok, submitted} =
        TransitionAttempt.mark_mutation_submitted(fenced, %{
          at: @now,
          provider_request_id: "preq_00000000-0000-4000-8000-000000000001"
        })

      if requested_state == :verifying do
        {:ok, verifying} = TransitionAttempt.begin_verification(submitted, %{at: @now})
        verifying
      else
        submitted
      end
    else
      fenced
    end
  end

  defp intent do
    {:ok, value} =
      SemanticTransitionIntent.new(%{
        work_item_id: "work-1",
        requested_from: :ready,
        requested_to: :in_progress,
        responsibility: "implementation",
        guard_evidence: [],
        requested_at: @now
      })

    value
  end
end
