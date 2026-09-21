defmodule SymphonyElixir.GuardClassSourceControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.GuardClass

  test "source-control mechanical guards require verified outcome" do
    candidate_guard = GuardClass.requirement(:mechanical_guard, :candidate_state_verified)
    review_guard = GuardClass.requirement(:mechanical_guard, :review_acceptance_verified)

    refute GuardClass.satisfied?(candidate_guard, [
             %{class: :mechanical_guard, name: :candidate_state_verified, outcome: :not_applicable}
           ])

    assert GuardClass.satisfied?(candidate_guard, [
             %{class: :mechanical_guard, name: :candidate_state_verified, outcome: :verified}
           ])

    refute GuardClass.satisfied?(review_guard, [
             %{class: :mechanical_guard, name: :review_acceptance_verified, outcome: :stale}
           ])

    assert GuardClass.satisfied?(review_guard, [
             %{class: :mechanical_guard, name: :review_acceptance_verified, outcome: :verified}
           ])
  end
end
