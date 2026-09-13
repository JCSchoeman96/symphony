defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Contract for a bounded agent session used by `SymphonyElixir.AgentRunner`.

  Runtime adapters own transport details only. Tracker lifecycle, dependency
  policy, scheduling, and merge decisions remain outside this boundary.
  """

  alias SymphonyElixir.Tracker.Issue

  @type session :: term()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok
end
