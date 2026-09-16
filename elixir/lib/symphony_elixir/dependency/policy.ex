defmodule SymphonyElixir.Dependency.Policy do
  @moduledoc """
  Pure lifecycle-aware classification and responsibility policy for hard blockers.

  A raw provider `done` state is unresolved. A dependency is successful only
  when its WorkItem carries a validated canonical completion assessment. Other
  known terminal outcomes are invalidated rather than treated as successful.
  """

  alias SymphonyElixir.WorkControl.WorkItem

  @responsibilities ~w(planning implementation review correction merge)
  @default_active_states [
    "backlog",
    "planning",
    "ready",
    "todo",
    "in progress",
    "in review",
    "human review",
    "changes requested",
    "rework",
    "ready to merge",
    "merging",
    "blocked"
  ]
  @default_terminal_states ["closed", "cancelled", "canceled", "duplicate", "done"]
  @default_invalidated_states ["closed", "cancelled", "canceled", "duplicate"]

  @type classification :: :satisfied | :unresolved | :invalidated
  @type decision :: %{
          allowed?: boolean(),
          dependency_status: :none | classification(),
          dependent_state: String.t(),
          responsibility: String.t(),
          reason: atom(),
          merge_permitted?: boolean(),
          blockers: [map()],
          unresolved_blockers: [map()],
          invalidated_blockers: [map()],
          diagnostic: term() | nil
        }

  @spec classify_state(term(), keyword()) :: classification() | {:error, term()}
  def classify_state(state, opts \\ []) do
    with {:ok, normalized_state} <- normalize_state(state),
         {:ok, known_states} <- known_states(opts) do
      cond do
        normalized_state == "done" ->
          :unresolved

        MapSet.member?(invalidated_states(opts), normalized_state) ->
          :invalidated

        MapSet.member?(known_states, normalized_state) ->
          :unresolved

        true ->
          {:error, {:unknown_blocker_state, normalized_state}}
      end
    end
  end

  @spec classify_blocker(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify_blocker(blocker, opts \\ [])

  @spec classify_blocker(WorkItem.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def classify_blocker(%WorkItem{} = work_item, _opts) do
    {:ok, %{blocker: blocker_from_work_item(work_item), status: work_item_classification(work_item)}}
  end

  def classify_blocker(blocker, opts) when is_list(opts) do
    with {:ok, normalized_blocker} <- normalize_blocker(blocker),
         classification <- classify_blocker_state(normalized_blocker, opts),
         {:ok, classification} <- ensure_classification(classification) do
      {:ok, %{blocker: normalized_blocker, status: classification}}
    end
  end

  @spec evaluate(String.t(), String.t(), list()) ::
          {:ok, decision()} | {:error, term()}
  def evaluate(dependent_state, responsibility, blockers),
    do: evaluate(dependent_state, responsibility, blockers, [])

  @spec evaluate(String.t(), String.t(), list(), keyword()) ::
          {:ok, decision()} | {:error, term()}
  def evaluate(dependent_state, responsibility, blockers, opts) when is_list(blockers) do
    with {:ok, normalized_state} <- normalize_state(dependent_state),
         {:ok, normalized_responsibility} <- normalize_responsibility(responsibility),
         {:ok, known_states} <- known_states(opts),
         :ok <- ensure_dependent_state(normalized_state, known_states),
         {:ok, classified_blockers} <- classify_blockers(blockers, opts) do
      build_decision(
        normalized_state,
        normalized_responsibility,
        classified_blockers
      )
    end
  end

  def evaluate(_dependent_state, _responsibility, _blockers, _opts),
    do: {:error, :invalid_blockers}

  @doc false
  @spec policy_for(String.t(), String.t()) :: :allow | :allow_review_only | :block
  def policy_for(_dependent_state, "planning"), do: :allow
  def policy_for(_dependent_state, "review"), do: :allow_review_only
  def policy_for(_dependent_state, _responsibility), do: :block

  defp build_decision(dependent_state, responsibility, classified_blockers) do
    blockers = Enum.map(classified_blockers, & &1.blocker)
    unresolved_blockers = filter_by_status(classified_blockers, :unresolved)
    invalidated_blockers = filter_by_status(classified_blockers, :invalidated)

    cond do
      invalidated_blockers != [] ->
        {:ok,
         decision(
           dependent_state,
           responsibility,
           :invalidated,
           :invalidated_dependency,
           false,
           blockers,
           unresolved_blockers,
           invalidated_blockers
         )}

      unresolved_blockers == [] ->
        {:ok,
         decision(
           dependent_state,
           responsibility,
           dependency_status(classified_blockers),
           if(blockers == [], do: :no_hard_dependencies, else: :dependencies_satisfied),
           true,
           blockers,
           [],
           []
         )}

      policy_for(dependent_state, responsibility) == :allow ->
        {:ok,
         decision(
           dependent_state,
           responsibility,
           :unresolved,
           :planning_allowed_with_unresolved_dependencies,
           true,
           blockers,
           unresolved_blockers,
           []
         )}

      policy_for(dependent_state, responsibility) == :allow_review_only ->
        {:ok,
         decision(
           dependent_state,
           responsibility,
           :unresolved,
           :review_allowed_with_unresolved_dependencies,
           true,
           blockers,
           unresolved_blockers,
           []
         )}

      true ->
        {:ok,
         decision(
           dependent_state,
           responsibility,
           :unresolved,
           :unresolved_hard_dependency,
           false,
           blockers,
           unresolved_blockers,
           []
         )}
    end
  end

  defp decision(
         dependent_state,
         responsibility,
         dependency_status,
         reason,
         allowed?,
         blockers,
         unresolved_blockers,
         invalidated_blockers
       ) do
    %{
      allowed?: allowed?,
      dependency_status: dependency_status,
      dependent_state: dependent_state,
      responsibility: responsibility,
      reason: reason,
      merge_permitted?: allowed? and dependency_status in [:none, :satisfied],
      blockers: blockers,
      unresolved_blockers: unresolved_blockers,
      invalidated_blockers: invalidated_blockers,
      diagnostic: nil
    }
  end

  defp classify_blockers(blockers, opts) do
    Enum.reduce_while(blockers, {:ok, []}, fn blocker, {:ok, acc} ->
      case classify_blocker(blocker, opts) do
        {:ok, classified} -> {:cont, {:ok, [classified | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, classified} -> {:ok, Enum.reverse(classified)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp filter_by_status(classified_blockers, status) do
    classified_blockers
    |> Enum.filter(&(&1.status == status))
    |> Enum.map(& &1.blocker)
  end

  defp classify_blocker_state(%{id: blocker_id, state: state}, opts) do
    case work_item_for(opts, blocker_id) do
      %WorkItem{} = work_item -> work_item_classification(work_item)
      _missing -> classify_state(state, opts)
    end
  end

  defp work_item_for(opts, blocker_id) do
    case Keyword.get(opts, :work_control, %{}) do
      work_control when is_map(work_control) ->
        Map.get(work_control, blocker_id) || Map.get(work_control, to_string(blocker_id))

      _invalid ->
        nil
    end
  end

  defp work_item_classification(%WorkItem{} = work_item) do
    cond do
      WorkItem.dependency_satisfying?(work_item) -> :satisfied
      WorkItem.canonical_state(work_item) == :canceled -> :invalidated
      true -> :unresolved
    end
  end

  defp blocker_from_work_item(%WorkItem{} = work_item) do
    %{
      id: work_item.id,
      identifier: work_item.identifier,
      state: work_item.provider_observation.provider_state_name
    }
  end

  defp dependency_status([]), do: :none
  defp dependency_status(_classified_blockers), do: :satisfied

  defp normalize_blocker(%{} = blocker) do
    id = Map.get(blocker, :id) || Map.get(blocker, "id")
    identifier = Map.get(blocker, :identifier) || Map.get(blocker, "identifier")
    state = Map.get(blocker, :state) || Map.get(blocker, "state")

    if present_string?(id) and present_string?(state) do
      {:ok,
       %{
         id: id,
         identifier: if(present_string?(identifier), do: identifier, else: nil),
         state: normalize_state_value(state)
       }}
    else
      {:error, {:malformed_blocker, blocker}}
    end
  end

  defp normalize_blocker(blocker), do: {:error, {:malformed_blocker, blocker}}

  defp normalize_state(state) when is_binary(state) do
    normalized = normalize_state_value(state)

    if normalized == "", do: {:error, :blank_state}, else: {:ok, normalized}
  end

  defp normalize_state(state), do: {:error, {:invalid_state, state}}

  defp normalize_state_value(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp normalize_responsibility(responsibility) when is_binary(responsibility) do
    normalized = normalize_state_value(responsibility)

    if normalized in @responsibilities do
      {:ok, normalized}
    else
      {:error, {:unknown_responsibility, normalized}}
    end
  end

  defp normalize_responsibility(responsibility),
    do: {:error, {:unknown_responsibility, responsibility}}

  defp ensure_classification(classification)
       when classification in [:satisfied, :unresolved, :invalidated],
       do: {:ok, classification}

  defp ensure_classification({:error, reason}), do: {:error, reason}

  defp ensure_dependent_state(state, known_states) do
    if MapSet.member?(known_states, state) or state == "done" do
      :ok
    else
      {:error, {:unknown_dependent_state, state}}
    end
  end

  defp known_states(opts) do
    active_states = Keyword.get(opts, :active_states, @default_active_states)
    terminal_states = Keyword.get(opts, :terminal_states, @default_terminal_states)

    with {:ok, active_states} <-
           normalize_state_list(active_states, :active_states),
         {:ok, terminal_states} <-
           normalize_state_list(terminal_states, :terminal_states) do
      default_states = MapSet.new(@default_active_states ++ @default_terminal_states)
      {:ok, default_states |> MapSet.union(active_states) |> MapSet.union(terminal_states)}
    end
  end

  defp invalidated_states(opts) do
    opts
    |> Keyword.get(:terminal_states, @default_terminal_states)
    |> Enum.map(&normalize_state_value/1)
    |> Enum.filter(&(&1 != "done"))
    |> Kernel.++(@default_invalidated_states)
    |> MapSet.new()
  end

  defp normalize_state_list(states, key) when is_list(states) do
    normalized =
      states
      |> Enum.map(fn
        state when is_binary(state) -> normalize_state_value(state)
        _ -> ""
      end)

    if Enum.any?(normalized, &(&1 == "")) do
      {:error, {:invalid_state_list, key}}
    else
      {:ok, MapSet.new(normalized)}
    end
  end

  defp normalize_state_list(_states, key), do: {:error, {:invalid_state_list, key}}

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
