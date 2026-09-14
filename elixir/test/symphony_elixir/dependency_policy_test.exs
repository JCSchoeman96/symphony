defmodule SymphonyElixir.DependencyPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dependency.{Guard, Policy}

  test "classifies only Done as satisfied" do
    assert Policy.classify_state("Done") == :satisfied
    assert Policy.classify_state("In Progress") == :unresolved
    assert Policy.classify_state("Ready to Merge") == :unresolved
    assert Policy.classify_state("Canceled") == :invalidated
    assert Policy.classify_state("Cancelled") == :invalidated
    assert Policy.classify_state("Closed") == :invalidated
    assert Policy.classify_state("Duplicate") == :invalidated
  end

  test "classifies configured custom active and terminal states" do
    opts = [active_states: ["Queued"], terminal_states: ["Done", "Abandoned"]]

    assert Policy.classify_state("queued", opts) == :unresolved
    assert Policy.classify_state("abandoned", opts) == :invalidated
  end

  test "refuses unknown or malformed blocker state" do
    assert {:error, {:unknown_blocker_state, "mystery"}} =
             Policy.classify_state("Mystery")

    assert {:error, {:malformed_blocker, %{id: "blocker-1"}}} =
             Policy.classify_blocker(%{id: "blocker-1"})
  end

  test "planning is allowed while an active hard blocker remains unresolved" do
    decision =
      Guard.evaluate(
        %Issue{
          id: "dependent-planning",
          identifier: "SYM-PLAN",
          state: "Planning",
          blocked_by: [%{id: "blocker-1", identifier: "SYM-BLOCKER", state: "In Progress"}]
        },
        "planning"
      )

    assert decision.allowed?
    assert decision.dependency_status == :unresolved
    assert decision.reason == :planning_allowed_with_unresolved_dependencies
    assert ["SYM-BLOCKER"] = Enum.map(decision.unresolved_blockers, & &1.identifier)
  end

  test "implementation and correction are blocked until every hard blocker is Done" do
    blockers = [
      %{id: "blocker-1", identifier: "SYM-DONE", state: "Done"},
      %{id: "blocker-2", identifier: "SYM-ACTIVE", state: "Ready"}
    ]

    implementation =
      Guard.evaluate(%Issue{id: "dependent", state: "Ready", blocked_by: blockers}, "implementation")

    correction =
      Guard.evaluate(
        %Issue{id: "dependent", state: "Changes Requested", blocked_by: blockers},
        "correction"
      )

    refute implementation.allowed?
    refute correction.allowed?
    assert implementation.reason == :unresolved_hard_dependency
    assert correction.dependency_status == :unresolved
  end

  test "review may inspect existing work but never grants merge authority" do
    review =
      Guard.evaluate(
        %Issue{
          id: "dependent-review",
          state: "In Review",
          blocked_by: [%{id: "blocker-1", state: "Planning"}]
        },
        "review"
      )

    merge =
      Guard.evaluate(
        %Issue{
          id: "dependent-merge",
          state: "Ready to Merge",
          blocked_by: [%{id: "blocker-1", state: "Planning"}]
        },
        "merge"
      )

    assert review.allowed?
    refute review.merge_permitted?
    refute merge.allowed?
    refute merge.merge_permitted?
  end

  test "canceled or malformed blockers fail closed for every responsibility" do
    canceled = [%{id: "blocker-1", identifier: "SYM-CANCELED", state: "Canceled"}]

    for responsibility <- ["planning", "implementation", "review", "correction", "merge"] do
      decision = Guard.evaluate(%Issue{id: "dependent", state: "Planning", blocked_by: canceled}, responsibility)
      refute decision.allowed?
      assert decision.reason == :invalidated_dependency
    end

    malformed = Guard.evaluate(%Issue{id: "dependent", state: "Ready", blocked_by: [%{id: "blocker-1"}]}, "implementation")
    refute malformed.allowed?
    assert malformed.reason == :dependency_data_invalid
    assert malformed.diagnostic != nil
  end

  test "empty dependencies permit the responsibility" do
    decision = Guard.evaluate(%Issue{id: "unblocked", state: "Ready", blocked_by: []}, "implementation")

    assert decision.allowed?
    assert decision.dependency_status == :none
    assert decision.reason == :no_hard_dependencies
    assert decision.merge_permitted?
  end

  test "guard exposes the boolean helper and fails closed for invalid issue data" do
    issue = %Issue{id: "guard-helper", state: "Ready", blocked_by: []}

    assert Guard.allowed?(issue, "implementation")

    invalid_issue = Guard.evaluate(:not_an_issue, "implementation", [])
    refute invalid_issue.allowed?
    assert invalid_issue.diagnostic == {:invalid_issue, :not_an_issue}

    unknown_blocker =
      Guard.evaluate(
        %Issue{id: "unknown", state: "Ready", blocked_by: [%{id: "b", state: "Mystery"}]},
        "implementation"
      )

    assert unknown_blocker.reason == :dependency_data_invalid

    invalid_blockers = Guard.evaluate(%Issue{id: "invalid-list", state: "Ready", blocked_by: nil}, "implementation")
    assert invalid_blockers.reason == :dependency_data_invalid

    invalid_policy = Guard.evaluate(%Issue{id: "invalid-state", state: nil, blocked_by: []}, "implementation")
    assert invalid_policy.reason == :dependency_policy_invalid
    assert invalid_policy.dependent_state == nil
  end

  test "policy supports its direct arities and rejects malformed inputs" do
    assert {:ok, %{dependency_status: :none}} = Policy.evaluate("Ready", "implementation", [])
    assert {:error, :invalid_blockers} = Policy.evaluate("Ready", "implementation", :not_a_list, [])
    assert {:error, {:malformed_blocker, :not_a_blocker}} = Policy.classify_blocker(:not_a_blocker)

    assert {:error, {:invalid_state, nil}} = Policy.classify_state(nil)

    assert {:error, {:unknown_responsibility, :implementation}} =
             Policy.evaluate("Ready", :implementation, [])

    assert {:error, {:unknown_blocker_state, "mystery"}} =
             Policy.classify_blocker(%{id: "b", state: "Mystery"})

    assert {:error, {:invalid_state_list, :active_states}} =
             Policy.evaluate("Ready", "implementation", [], active_states: nil)

    assert {:error, {:invalid_state_list, :active_states}} =
             Policy.evaluate("Ready", "implementation", [], active_states: [nil])
  end
end
