defmodule SymphonyElixir.AgentRuntime.AttemptPolicy do
  @moduledoc """
  Pure accounting and termination policy for one issue attempt lineage.

  The orchestrator owns the counters. This module only classifies an event,
  updates its independent counter, and says whether automatic work may
  continue.
  """

  @max_ordinary_retries 3
  @max_review_cycles 3

  @type counters :: %{
          ordinary_failures: non_neg_integer(),
          ordinary_retries: non_neg_integer(),
          review_cycles: non_neg_integer(),
          capacity_waits: non_neg_integer(),
          continuations: non_neg_integer(),
          route_changes: non_neg_integer()
        }

  @type event ::
          :ordinary_failure
          | :review_cycle
          | :capacity_wait
          | :continuation
          | :route_change
          | :ci_failure

  @type stop_reason :: :ordinary_retry_limit | :review_cycle_limit | :ci_retry_disabled

  @spec new() :: counters()
  def new do
    %{
      ordinary_failures: 0,
      ordinary_retries: 0,
      review_cycles: 0,
      capacity_waits: 0,
      continuations: 0,
      route_changes: 0
    }
  end

  @spec ci_retry_policy() :: :disabled
  def ci_retry_policy, do: :disabled

  @spec max_ordinary_retries() :: pos_integer()
  def max_ordinary_retries, do: @max_ordinary_retries

  @spec max_review_cycles() :: pos_integer()
  def max_review_cycles, do: @max_review_cycles

  @spec record(counters(), event()) :: {:ok, counters()} | {:stop, counters(), stop_reason()}
  def record(counters, :ordinary_failure) do
    counters = increment(counters, :ordinary_failures)

    if counters.ordinary_failures <= @max_ordinary_retries do
      {:ok, %{counters | ordinary_retries: counters.ordinary_failures}}
    else
      {:stop, counters, :ordinary_retry_limit}
    end
  end

  def record(counters, :review_cycle) do
    counters = increment(counters, :review_cycles)

    if counters.review_cycles <= @max_review_cycles do
      {:ok, counters}
    else
      {:stop, %{counters | review_cycles: @max_review_cycles}, :review_cycle_limit}
    end
  end

  def record(counters, :capacity_wait), do: {:ok, increment(counters, :capacity_waits)}
  def record(counters, :continuation), do: {:ok, increment(counters, :continuations)}
  def record(counters, :route_change), do: {:ok, increment(counters, :route_changes)}
  def record(counters, :ci_failure), do: {:stop, counters, :ci_retry_disabled}

  defp increment(counters, key) do
    Map.update!(counters, key, &(&1 + 1))
  end
end
