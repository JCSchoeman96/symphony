defmodule SymphonyElixir.Tracker.TransitionPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.TransitionPolicy

  test "allows only the handoff owned by each executable responsibility" do
    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "planning",
               current_state: "Planning",
               target_state: "Ready",
               dependency_decision: allowed_dependency()
             })

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "implementation",
               current_state: "In Progress",
               target_state: "In Review",
               dependency_decision: allowed_dependency()
             })

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "correction",
               current_state: "Changes Requested",
               target_state: "In Review",
               dependency_decision: allowed_dependency()
             })

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "review",
               current_state: "In Review",
               target_state: "Changes Requested",
               dependency_decision: allowed_dependency()
             })
  end

  test "rejects planner, reviewer, and merge attempts outside their scoped handoffs" do
    for {responsibility, current_state, target_state} <- [
          {"planning", "Planning", "In Review"},
          {"review", "In Review", "In Progress"},
          {"merge", "Ready to Merge", "Done"}
        ] do
      assert {:error, %{code: :unauthorized_transition}} =
               TransitionPolicy.authorize(%{
                 responsibility: responsibility,
                 current_state: current_state,
                 target_state: target_state,
                 dependency_decision: allowed_dependency()
               })
    end
  end

  test "delegates canonical transition metadata and guard classes to WorkflowLifecycle" do
    assert {:ok, metadata} =
             TransitionPolicy.transition_metadata(%{
               current_state: "Merging",
               target_state: "Done"
             })

    assert metadata.source == :merging
    assert metadata.target == :done
    assert metadata.guard_classes == [:mechanical_guard]
    assert Enum.any?(metadata.guard_requirements, &(&1.name == :completion_proof_verified))

    assert {:error, %{code: :unauthorized_transition}} =
             TransitionPolicy.authorize(%{
               responsibility: "implementation",
               current_state: "Ready",
               target_state: "In Review",
               dependency_decision: allowed_dependency()
             })
  end

  test "merge handoff requires an allowed, complete dependency decision" do
    for decision <- [
          %{allowed?: true, dependency_status: :unresolved, dependency_completeness: :complete},
          %{
            allowed?: true,
            merge_permitted?: false,
            dependency_status: :none,
            dependency_completeness: {:incomplete, :missing_page_info}
          },
          %{
            allowed?: false,
            merge_permitted?: false,
            dependency_status: :unresolved,
            dependency_completeness: :complete
          }
        ] do
      assert {:error, %{code: :dependency_transition_denied}} =
               TransitionPolicy.authorize(%{
                 responsibility: "review",
                 current_state: "In Review",
                 target_state: "Ready to Merge",
                 dependency_decision: decision
               })
    end

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "review",
               current_state: "In Review",
               target_state: "Ready to Merge",
               dependency_decision: allowed_dependency()
             })
  end

  test "implementation and correction fail closed when dependency data is not dispatchable" do
    for {responsibility, current_state} <- [
          {"implementation", "In Progress"},
          {"correction", "Changes Requested"}
        ] do
      assert {:error, %{code: :dependency_transition_denied}} =
               TransitionPolicy.authorize(%{
                 responsibility: responsibility,
                 current_state: current_state,
                 target_state: "In Review",
                 dependency_decision: %{
                   allowed?: false,
                   dependency_status: :unavailable,
                   dependency_completeness: {:unavailable, :provider_error}
                 }
               })
    end
  end

  test "missing session context is denied without echoing provider input" do
    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.authorize(%{
               responsibility: "implementation",
               current_state: "In Progress",
               target_state: "In Review"
             })
  end

  test "accepts normalized string-key context while failing closed for missing tokens" do
    assert :ok =
             TransitionPolicy.authorize(%{
               "responsibility" => "review",
               "current_state" => "In Review",
               "target_state" => "Ready to Merge",
               "dependency_decision" => %{
                 "allowed?" => "true",
                 "merge_permitted?" => "true",
                 "dependency_status" => "satisfied",
                 "dependency_completeness" => :complete
               }
             })

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: "implementation",
               current_state: "In Progress",
               target_state: "In Review",
               dependency_decision: %{
                 allowed?: true,
                 dependency_status: "none",
                 dependency_completeness: :complete
               }
             })

    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.authorize(%{
               responsibility: nil,
               current_state: "Planning",
               target_state: "Ready",
               dependency_decision: allowed_dependency()
             })

    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.authorize(:not_a_context)
  end

  test "raw provider issue state is not a canonical transition source" do
    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.authorize(%{
               responsibility: "review",
               current_issue_state: "In Review",
               target_state: "Ready to Merge",
               dependency_decision: allowed_dependency()
             })
  end

  test "exposes guard metadata and accepts canonical owner atoms for non-agent transitions" do
    assert {:ok, requirements} =
             TransitionPolicy.guard_requirements(%{
               current_state: "Ready",
               target_state: "In Progress"
             })

    assert Enum.map(requirements, & &1.name) == [:dispatch_guard]

    assert :ok =
             TransitionPolicy.authorize_intent(%{
               responsibility: :symphony,
               current_state: "Ready",
               target_state: "In Progress"
             })

    assert :ok =
             TransitionPolicy.authorize_intent(%{
               responsibility: :human,
               current_state: "Planning",
               target_state: "Canceled"
             })

    assert :ok =
             TransitionPolicy.authorize_intent(%{
               responsibility: :system,
               current_state: "Merging",
               target_state: "Done"
             })

    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.transition_metadata(:invalid)

    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.authorize_intent(:invalid)

    assert {:error, %{code: :invalid_transition_context}} =
             TransitionPolicy.guard_requirements(%{current_state: "Mystery", target_state: "Ready"})

    assert {:ok, metadata} =
             TransitionPolicy.transition_metadata(%{
               "current_lifecycle_state" => "Merging",
               "target_state" => "Done"
             })

    assert metadata.source == :merging
  end

  defp allowed_dependency do
    %{
      allowed?: true,
      merge_permitted?: true,
      dependency_status: :none,
      dependency_completeness: :complete
    }
  end
end
