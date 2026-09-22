defmodule SymphonyElixir.AgentRuntime.RuntimeAttempt do
  @moduledoc """
  Host-owned identity for one bounded runtime attempt on the routed authority path.

  Not persisted; authoritative state lives in the orchestrator running map.
  """

  alias SymphonyElixir.AgentRuntime.Route

  defmodule Identity do
    @moduledoc false

    defstruct [
      :runtime_attempt_id,
      :work_item_id,
      :lineage_generation,
      :responsibility,
      :runtime_profile
    ]

    @type t :: %__MODULE__{
            runtime_attempt_id: String.t(),
            work_item_id: String.t(),
            lineage_generation: String.t(),
            responsibility: String.t(),
            runtime_profile: String.t()
          }

    @spec allocate(String.t(), Route.t(), String.t()) :: t()
    def allocate(work_item_id, %Route{} = route, lineage_generation)
        when is_binary(work_item_id) and is_binary(lineage_generation) do
      %__MODULE__{
        runtime_attempt_id: generate_runtime_attempt_id(),
        work_item_id: work_item_id,
        lineage_generation: lineage_generation,
        responsibility: route.responsibility,
        runtime_profile: route.profile_name
      }
    end

    @spec same?(t(), t()) :: boolean()
    def same?(%__MODULE__{} = left, %__MODULE__{} = right) do
      left.runtime_attempt_id == right.runtime_attempt_id and
        left.work_item_id == right.work_item_id and
        left.lineage_generation == right.lineage_generation and
        normalize_responsibility(left.responsibility) ==
          normalize_responsibility(right.responsibility) and
        left.runtime_profile == right.runtime_profile
    end

    @spec valid?(term()) :: boolean()
    def valid?(%__MODULE__{
          runtime_attempt_id: id,
          work_item_id: work_item_id,
          lineage_generation: generation,
          responsibility: responsibility,
          runtime_profile: profile
        })
        when is_binary(id) and is_binary(work_item_id) and is_binary(generation) and
               is_binary(responsibility) and is_binary(profile) do
      String.trim(id) != "" and String.trim(work_item_id) != "" and String.trim(generation) != "" and
        String.trim(responsibility) != "" and String.trim(profile) != ""
    end

    def valid?(_identity), do: false

    defp normalize_responsibility(value) when is_atom(value), do: Atom.to_string(value)
    defp normalize_responsibility(value) when is_binary(value), do: String.trim(value)
    defp normalize_responsibility(value), do: value

    defp generate_runtime_attempt_id do
      16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    end
  end

  @terminal_states [:completed, :retry_queued, :blocked, :failed, :cancelled]

  @allowed_transitions %{
    queued: [:starting],
    starting: [:running, :retry_queued, :blocked, :failed, :cancelled, :completed],
    running: [:completed, :retry_queued, :blocked, :failed, :cancelled],
    completed: [],
    retry_queued: [],
    blocked: [],
    failed: [],
    cancelled: []
  }

  defstruct [:identity, :state]

  @type state ::
          :queued
          | :starting
          | :running
          | :completed
          | :retry_queued
          | :blocked
          | :failed
          | :cancelled

  @type t :: %__MODULE__{
          identity: Identity.t(),
          state: state()
        }

  @spec new(Identity.t(), state()) :: t()
  def new(%Identity{} = identity, state)
      when state in [:queued, :starting, :running, :completed, :retry_queued, :blocked, :failed, :cancelled] do
    %__MODULE__{identity: identity, state: state}
  end

  @spec mark_running(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def mark_running(%__MODULE__{} = attempt), do: transition(attempt, :running)

  @spec terminal?(state() | t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: terminal?(state)
  def terminal?(state) when state in @terminal_states, do: true
  def terminal?(_state), do: false

  @spec transition_allowed?(state(), state()) :: boolean()
  def transition_allowed?(from, to) do
    Map.get(@allowed_transitions, from, []) |> Enum.member?(to)
  end

  @spec transition(t(), state()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{state: from} = attempt, to) do
    if transition_allowed?(from, to) do
      {:ok, %{attempt | state: to}}
    else
      {:error, :invalid_transition}
    end
  end
end
