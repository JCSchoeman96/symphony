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
    for responsibility <- ["implementation", "correction"] do
      assert {:error, %{code: :dependency_transition_denied}} =
               TransitionPolicy.authorize(%{
                 responsibility: responsibility,
                 current_state: if(responsibility == "implementation", do: "Ready", else: "Changes Requested"),
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
               "current_issue_state" => "In Review",
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

  defp allowed_dependency do
    %{
      allowed?: true,
      merge_permitted?: true,
      dependency_status: :none,
      dependency_completeness: :complete
    }
  end
end
