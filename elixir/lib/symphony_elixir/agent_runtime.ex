defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Contract for a bounded agent session used by `SymphonyElixir.AgentRunner`.

  Runtime adapters own transport details only. Tracker lifecycle, dependency
  policy, scheduling, and merge decisions remain outside this boundary. Session
  handles are opaque, and runtime metadata is for observation only.
  """

  alias SymphonyElixir.Tracker.Issue

  @typedoc "Opaque handle for one active runtime session."
  @opaque session :: {reference(), term()}

  @typedoc "Capabilities implemented by a runtime, expressed as stable atoms."
  @type capabilities :: [atom()]

  @typedoc "Non-secret runtime information used for observation."
  @type runtime_metadata :: %{optional(atom()) => term()}

  @typedoc "Successful completion of one turn. Turn events travel through callbacks."
  @type turn_result :: :completed

  @type session_state :: :not_started | :active | :stopped
  @type start_error :: {:start_failed, term()}
  @type session_error ::
          {:invalid_session, term()}
          | {:session_not_active, session_state()}
  @type turn_error :: session_error() | {:turn_failed, term()}
  @type stop_error :: session_error() | {:stop_failed, term()}

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, start_error()}

  @callback run_turn(session(), String.t(), Issue.t(), keyword()) ::
              {:ok, turn_result()} | {:error, turn_error()}

  @callback stop_session(session()) :: :ok | {:error, stop_error()}
  @callback capabilities() :: capabilities()
  @callback runtime_metadata() :: runtime_metadata()
end
