defmodule SymphonyElixir.WorkControlWorkflowLifecycleTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.{GuardClass, WorkflowLifecycle}

  @states [
    :backlog,
    :planning,
    :ready,
    :in_progress,
    :in_review,
    :changes_requested,
    :ready_to_merge,
    :merging,
    :blocked,
    :done,
    :canceled
  ]

  @display_names %{
    backlog: "Backlog",
    planning: "Planning",
    ready: "Ready",
    in_progress: "In Progress",
    in_review: "In Review",
    changes_requested: "Changes Requested",
    ready_to_merge: "Ready to Merge",
    merging: "Merging",
    blocked: "Blocked",
    done: "Done",
    canceled: "Canceled"
  }

  test "recognizes exactly the canonical states and their display names" do
    assert WorkflowLifecycle.states() == @states

    for state <- @states do
      display_name = Map.fetch!(@display_names, state)
      assert WorkflowLifecycle.display(state) == display_name
      assert WorkflowLifecycle.parse(display_name) == {:ok, state}
      assert WorkflowLifecycle.parse(String.downcase(display_name)) == {:ok, state}
    end

    for alias <- ["Todo", "Open", "Opened", "Started", "Pending", "Rework", "Closed", "Cancelled"] do
      assert {:error, {:unknown_state, _}} = WorkflowLifecycle.parse(alias)
    end
  end

  test "classifies canonical states exactly" do
    assert WorkflowLifecycle.classification(:backlog) == %{
             activity: :inactive,
             owner: :human,
             responsibility: "human",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:planning) == %{
             activity: :active,
             owner: :planner,
             responsibility: "planning",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:ready) == %{
             activity: :dispatchable,
             owner: :builder,
             responsibility: "implementation",
             dispatchable: true,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:in_progress) == %{
             activity: :active,
             owner: :builder,
             responsibility: "implementation",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:in_review) == %{
             activity: :active,
             owner: :reviewer,
             responsibility: "review",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:changes_requested) == %{
             activity: :active,
             owner: :fixer,
             responsibility: "correction",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:ready_to_merge) == %{
             activity: :gated,
             owner: :merge_gatekeeper,
             responsibility: "merge",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:merging) == %{
             activity: :gated,
             owner: :merge_gatekeeper,
             responsibility: "merge",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:blocked) == %{
             activity: :suspended,
             owner: :human_or_system,
             responsibility: "human",
             dispatchable: false,
             terminal: false,
             successful_terminal: false
           }

    assert WorkflowLifecycle.classification(:done) == %{
             activity: :terminal,
             owner: nil,
             responsibility: nil,
             dispatchable: false,
             terminal: true,
             successful_terminal: true
           }

    assert WorkflowLifecycle.classification(:canceled) == %{
             activity: :terminal,
             owner: nil,
             responsibility: nil,
             dispatchable: false,
             terminal: true,
             successful_terminal: false
           }

    assert WorkflowLifecycle.dispatchable?(:ready)
    refute WorkflowLifecycle.dispatchable?(:in_progress)
    refute WorkflowLifecycle.dispatchable?(:blocked)
    refute WorkflowLifecycle.dispatchable?(:done)
    assert WorkflowLifecycle.terminal?(:done)
    assert WorkflowLifecycle.terminal?(:canceled)
    assert WorkflowLifecycle.successful_terminal?(:done)
    refute WorkflowLifecycle.successful_terminal?(:canceled)
  end

  test "exposes the complete canonical transition graph" do
    valid_transitions = [
      {:backlog, :planning},
      {:planning, :ready},
      {:ready, :in_progress},
      {:in_progress, :in_review},
      {:in_review, :changes_requested},
      {:changes_requested, :in_review},
      {:in_review, :ready_to_merge},
      {:ready_to_merge, :merging},
      {:merging, :done}
    ]

    for {source, target} <- valid_transitions do
      assert {:ok, metadata} = WorkflowLifecycle.transition(source, target)
      assert metadata.source == source
      assert metadata.target == target
      assert WorkflowLifecycle.valid_transition?(source, target)
      assert metadata.guard_classes == Enum.map(metadata.guard_requirements, & &1.class) |> Enum.uniq()
    end

    for source <- Enum.reject(@states, &WorkflowLifecycle.terminal?/1) do
      assert {:ok, metadata} = WorkflowLifecycle.transition(source, :canceled)
      assert metadata.owner == :human
      assert metadata.side_effects.revoke_automation
      assert metadata.side_effects.dependency_effect == :invalidated
    end

    for source <- @states, target <- @states do
      allowed =
        {source, target} in valid_transitions or
          (target == :canceled and not WorkflowLifecycle.terminal?(source))

      if allowed do
        assert WorkflowLifecycle.valid_transition?(source, target)
      else
        refute WorkflowLifecycle.valid_transition?(source, target)
      end
    end

    refute WorkflowLifecycle.valid_transition?(:ready, :in_review)

    assert {:error, {:invalid_transition, :ready, :in_review}} =
             WorkflowLifecycle.transition(:ready, :in_review)
  end

  test "transition metadata preserves guard classes and safety side effects" do
    assert {:ok, merge_metadata} = WorkflowLifecycle.transition(:ready_to_merge, :merging)
    assert merge_metadata.owner == :human

    assert merge_metadata.guard_requirements == [
             GuardClass.requirement(:human_decision, :merge_approved),
             GuardClass.requirement(:mechanical_guard, :merge_guard_verified)
           ]

    refute merge_metadata.side_effects.autonomous_merge

    assert {:ok, completion_metadata} = WorkflowLifecycle.transition(:merging, :done)

    assert completion_metadata.guard_requirements == [
             GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
           ]

    assert completion_metadata.side_effects.completion_proof_required

    assert {:ok, review_metadata} = WorkflowLifecycle.transition(:in_review, :ready_to_merge)
    assert review_metadata.owner == :independent_reviewer

    assert Enum.map(review_metadata.guard_requirements, & &1.class) == [
             :mechanical_guard,
             :semantic_attestation
           ]
  end

  test "guard classes cannot substitute for one another" do
    mechanical = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
    semantic = GuardClass.requirement(:semantic_attestation, :completion_proof_verified)
    human = GuardClass.requirement(:human_decision, :completion_proof_verified)

    assert GuardClass.valid?(mechanical)
    assert GuardClass.valid?(semantic)
    assert GuardClass.valid?(human)
    refute GuardClass.satisfied?(mechanical, [semantic])
    refute GuardClass.satisfied?(mechanical, [%{name: :completion_proof_verified}])
    refute GuardClass.satisfied?(human, [mechanical])
    assert GuardClass.satisfied?(mechanical, [mechanical])
    assert GuardClass.all_satisfied?([mechanical], [mechanical])
    refute GuardClass.all_satisfied?([mechanical], [semantic])
  end

  test "guard requirements fail closed for malformed inputs and preserve their classes" do
    mechanical = GuardClass.requirement(:mechanical_guard, :dispatch_guard)
    semantic = GuardClass.requirement(:semantic_attestation, :dispatch_guard)

    assert GuardClass.classes() == [:mechanical_guard, :semantic_attestation, :human_decision]
    assert GuardClass.requirement(:not_a_guard, :proof) == nil
    assert GuardClass.requirement(:mechanical_guard, "proof") == nil
    refute GuardClass.valid?(%{class: :not_a_guard, name: :proof})
    refute GuardClass.valid?(%{class: :mechanical_guard, name: "proof"})
    refute GuardClass.valid?(:malformed)
    refute GuardClass.satisfied?(mechanical, :malformed)
    refute GuardClass.satisfied?(%{class: :not_a_guard, name: :proof}, [mechanical])
    refute GuardClass.all_satisfied?(%{class: :mechanical_guard}, [mechanical])
    assert GuardClass.missing(%{class: :mechanical_guard}, [mechanical]) == []

    assert GuardClass.satisfied?(mechanical, mechanical)
    assert GuardClass.satisfied?(mechanical, %{class: :mechanical_guard, name: :dispatch_guard})
    refute GuardClass.satisfied?(mechanical, semantic)

    assert GuardClass.classes_for([mechanical, semantic, %{class: :not_a_guard, name: :ignored}]) == [
             :mechanical_guard,
             :semantic_attestation
           ]

    assert GuardClass.classes_for(:malformed) == []
    refute GuardClass.all_satisfied?([mechanical, semantic], [mechanical])
  end

  test "workflow lifecycle exposes safe lookup failures" do
    assert WorkflowLifecycle.display(" ready ") == "Ready"
    assert WorkflowLifecycle.display("provider-open") == nil
    assert WorkflowLifecycle.display(:provider_open) == nil
    assert WorkflowLifecycle.display(42) == nil
    assert WorkflowLifecycle.parse(42) == {:error, {:unknown_state, 42}}
    refute WorkflowLifecycle.canonical?(:provider_open)
    assert WorkflowLifecycle.classification(:provider_open) == nil
    assert WorkflowLifecycle.owner(:provider_open) == nil
    assert WorkflowLifecycle.responsibility(:provider_open) == nil

    assert WorkflowLifecycle.guard_requirements(:ready, :in_progress) == [
             GuardClass.requirement(:mechanical_guard, :dispatch_guard)
           ]

    assert WorkflowLifecycle.guard_classes(:ready, :in_progress) == [:mechanical_guard]

    assert WorkflowLifecycle.side_effects(:ready, :in_progress) == %{
             autonomous_merge: false,
             completion_proof_required: false
           }

    assert WorkflowLifecycle.guard_requirements(:ready, :in_review) == nil
    assert WorkflowLifecycle.guard_classes(:ready, :in_review) == nil
    assert WorkflowLifecycle.side_effects(:ready, :in_review) == nil

    assert WorkflowLifecycle.transition(:ready, :provider_open) ==
             {:error, {:unknown_state, :provider_open}}
  end
end
