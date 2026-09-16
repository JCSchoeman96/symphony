defmodule SymphonyElixir.WorkControlWorkItemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    WorkItem
  }

  @now ~U[2026-09-16 00:00:00Z]

  defp issue(state) do
    %Issue{
      id: "issue-1",
      native_ref: %{provider: "memory"},
      identifier: "SYM-1",
      title: "Canonical work item",
      description: "description",
      priority: 1,
      state: state,
      branch_name: "sym-1",
      url: "https://example.test/SYM-1",
      assignee_id: "agent-1",
      blocked_by: [%{id: "issue-0"}],
      dependency_completeness: :complete,
      labels: ["dispatch"],
      dispatchable: true,
      created_at: @now,
      updated_at: @now
    }
  end

  test "work item composes raw observation, assessment, disposition, and issue metadata" do
    assert {:ok, work_item} =
             WorkItem.from_issue(issue("Ready"), %{provider: :memory, observed_at: @now})

    assert work_item.id == "issue-1"
    assert work_item.identifier == "SYM-1"
    assert work_item.provider_observation.provider_state_name == "Ready"
    assert work_item.lifecycle_assessment.status == :validation_required
    assert work_item.validated_lifecycle_state == nil
    assert work_item.authority_disposition.status == :suspended
    assert work_item.blocked_by == [%{id: "issue-0"}]
    refute WorkItem.dispatchable?(work_item)
    refute WorkItem.dependency_satisfying?(work_item)
  end

  test "trusted canonical ready state can produce eligible routed work without provider authority" do
    assert {:ok, work_item} =
             WorkItem.from_issue(issue("Ready"), %{
               provider: :memory,
               observed_at: @now,
               prior_validated_lifecycle_state: :ready
             })

    assert work_item.lifecycle_assessment.status == :validated
    assert work_item.validated_lifecycle_state == :ready
    assert work_item.authority_disposition.status == :eligible
    assert WorkItem.dispatchable?(work_item)
    assert WorkItem.canonical_state(work_item) == :ready
  end

  test "raw provider done and canceled never satisfy dependency completion" do
    assert {:ok, raw_done} = WorkItem.from_issue(issue("Done"), %{provider: :memory, observed_at: @now})
    refute WorkItem.dependency_satisfying?(raw_done)

    proof = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)

    assert {:ok, completed} =
             WorkItem.from_issue(issue("Done"), %{
               provider: :memory,
               observed_at: @now,
               prior_validated_lifecycle_state: :merging,
               evidence: [proof]
             })

    assert WorkItem.dependency_satisfying?(completed)

    assert {:ok, canceled} =
             WorkItem.from_issue(issue("Canceled"), %{
               provider: :memory,
               observed_at: @now,
               prior_validated_lifecycle_state: :in_progress
             })

    refute WorkItem.dependency_satisfying?(canceled)
    assert canceled.authority_disposition.status == :suspended
  end

  test "work item construction fails closed when canonical components are missing" do
    assert {:error, :invalid_work_item} = WorkItem.new(:not_a_map)
    assert {:error, :missing_work_item_id} = WorkItem.new(%{})
    assert {:error, :invalid_work_item} = WorkItem.new(%{unexpected: :field})

    assert {:ok, observation} =
             ProviderObservation.new(%{
               provider: :memory,
               work_item_id: "issue-1",
               provider_state_name: "Ready",
               observed_at: @now
             })

    assert {:error, :missing_provider_observation} = WorkItem.new(%{id: "issue-1"})

    assert {:error, :missing_lifecycle_assessment} =
             WorkItem.new(%{id: "issue-1", provider_observation: observation})

    assessment = LifecycleAssessment.new(observation)

    assert {:error, :missing_authority_disposition} =
             WorkItem.new(%{
               id: "issue-1",
               provider_observation: observation,
               lifecycle_assessment: assessment
             })

    assert {:ok, ready} =
             WorkItem.from_issue(issue("Ready"), %{
               provider: :memory,
               observed_at: @now,
               prior_validated_lifecycle_state: :ready
             })

    assert {:ok, reconstructed} = WorkItem.new(Map.from_struct(ready))
    assert reconstructed.id == ready.id
    assert WorkItem.authority_available?(reconstructed)
    refute WorkItem.suspended?(reconstructed)

    unassessed = %{
      reconstructed
      | lifecycle_assessment: LifecycleAssessment.new(reconstructed.provider_observation)
    }

    refute WorkItem.authority_available?(unassessed)

    active = %{
      reconstructed
      | authority_disposition: %AuthorityDisposition{status: :active, lifecycle_state: :ready}
    }

    assert WorkItem.authority_available?(active)
    refute WorkItem.dispatchable?(%{active | validated_lifecycle_state: :in_progress})

    suspended = %{
      reconstructed
      | authority_disposition: %AuthorityDisposition{status: :suspended, lifecycle_state: :ready}
    }

    refute WorkItem.authority_available?(suspended)
    assert WorkItem.suspended?(suspended)
    assert WorkItem.canonical_state(suspended) == :ready
  end
end
