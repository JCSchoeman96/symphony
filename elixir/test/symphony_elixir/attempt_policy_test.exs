defmodule SymphonyElixir.AttemptPolicyTest do
  use ExUnit.Case

  alias SymphonyElixir.AgentRuntime.AttemptPolicy

  test "allows three ordinary retries and stops the next failure" do
    counters = AttemptPolicy.new()

    counters =
      Enum.reduce(1..3, counters, fn retry_number, counters ->
        assert {:ok, counters} = AttemptPolicy.record(counters, :ordinary_failure)
        assert counters.ordinary_retries == retry_number
        counters
      end)

    assert {:stop, stopped_counters, :ordinary_retry_limit} =
             AttemptPolicy.record(counters, :ordinary_failure)

    assert stopped_counters.ordinary_retries == 3
    assert stopped_counters.ordinary_failures == 4
  end

  test "capacity waits do not consume ordinary retry budget" do
    counters = AttemptPolicy.new()
    assert {:ok, counters} = AttemptPolicy.record(counters, :ordinary_failure)
    assert {:ok, counters} = AttemptPolicy.record(counters, :capacity_wait)
    assert {:ok, counters} = AttemptPolicy.record(counters, :capacity_wait)

    assert counters.ordinary_failures == 1
    assert counters.ordinary_retries == 1
    assert counters.capacity_waits == 2
  end

  test "review correction cycles have their own three-cycle cap" do
    counters = AttemptPolicy.new()

    counters =
      Enum.reduce(1..3, counters, fn cycle_number, counters ->
        assert {:ok, counters} = AttemptPolicy.record(counters, :review_cycle)
        assert counters.review_cycles == cycle_number
        counters
      end)

    assert {:stop, stopped_counters, :review_cycle_limit} =
             AttemptPolicy.record(counters, :review_cycle)

    assert stopped_counters.review_cycles == 3
  end

  test "continuations and route changes are tracked without failure accounting" do
    counters = AttemptPolicy.new()
    assert {:ok, counters} = AttemptPolicy.record(counters, :continuation)
    assert {:ok, counters} = AttemptPolicy.record(counters, :route_change)
    assert {:ok, counters} = AttemptPolicy.record(counters, :route_change)

    assert counters.continuations == 1
    assert counters.route_changes == 2
    assert counters.ordinary_failures == 0
    assert counters.review_cycles == 0
  end

  test "CI retry policy is explicitly disabled" do
    assert AttemptPolicy.max_ordinary_retries() == 3
    assert AttemptPolicy.max_review_cycles() == 3
    assert AttemptPolicy.ci_retry_policy() == :disabled

    assert {:stop, _counters, :ci_retry_disabled} =
             AttemptPolicy.record(AttemptPolicy.new(), :ci_failure)
  end
end
