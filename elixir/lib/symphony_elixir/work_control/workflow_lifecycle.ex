defmodule SymphonyElixir.WorkControl.WorkflowLifecycle do
  @moduledoc """
  Canonical V4.1 workflow state and transition law.

  Provider state names are observations and are intentionally not included in
  this vocabulary. This module describes policy and metadata only; it does not
  execute provider or runtime side effects.
  """

  alias SymphonyElixir.WorkControl.GuardClass

  @states [
    :backlog,
    :planning,
    :ready,
    :in_progress,
    :in_review,
    :changes_requested,
    :ready_to_merge,
    :merging,
    :blocked,
    :done,
    :canceled
  ]

  @display_names %{
    backlog: "Backlog",
    planning: "Planning",
    ready: "Ready",
    in_progress: "In Progress",
    in_review: "In Review",
    changes_requested: "Changes Requested",
    ready_to_merge: "Ready to Merge",
    merging: "Merging",
    blocked: "Blocked",
    done: "Done",
    canceled: "Canceled"
  }

  @state_by_display Enum.into(@display_names, %{}, fn {state, display_name} ->
                      normalized =
                        display_name
                        |> String.trim()
                        |> String.downcase()
                        |> String.split(~r/\s+/, trim: true)
                        |> Enum.join(" ")

                      {normalized, state}
                    end)

  @classifications %{
    backlog: %{
      activity: :inactive,
      owner: :human,
      responsibility: "human",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    planning: %{
      activity: :active,
      owner: :planner,
      responsibility: "planning",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    ready: %{
      activity: :dispatchable,
      owner: :builder,
      responsibility: "implementation",
      dispatchable: true,
      terminal: false,
      successful_terminal: false
    },
    in_progress: %{
      activity: :active,
      owner: :builder,
      responsibility: "implementation",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    in_review: %{
      activity: :active,
      owner: :reviewer,
      responsibility: "review",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    changes_requested: %{
      activity: :active,
      owner: :fixer,
      responsibility: "correction",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    ready_to_merge: %{
      activity: :gated,
      owner: :merge_gatekeeper,
      responsibility: "merge",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    merging: %{
      activity: :gated,
      owner: :merge_gatekeeper,
      responsibility: "merge",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    blocked: %{
      activity: :suspended,
      owner: :human_or_system,
      responsibility: "human",
      dispatchable: false,
      terminal: false,
      successful_terminal: false
    },
    done: %{
      activity: :terminal,
      owner: nil,
      responsibility: nil,
      dispatchable: false,
      terminal: true,
      successful_terminal: true
    },
    canceled: %{
      activity: :terminal,
      owner: nil,
      responsibility: nil,
      dispatchable: false,
      terminal: true,
      successful_terminal: false
    }
  }

  @transitions %{
    {:backlog, :planning} => %{
      owner: :human,
      responsibility: "human",
      guard_requirements: [GuardClass.requirement(:human_decision, :planning_started)],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:planning, :ready} => %{
      owner: :planner,
      responsibility: "planning",
      guard_requirements: [
        GuardClass.requirement(:semantic_attestation, :plan_attested),
        GuardClass.requirement(:mechanical_guard, :planning_requirements_verified)
      ],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:ready, :in_progress} => %{
      owner: :symphony,
      responsibility: "implementation",
      guard_requirements: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:in_progress, :in_review} => %{
      owner: :builder,
      responsibility: "implementation",
      guard_requirements: [
        GuardClass.requirement(:semantic_attestation, :implementation_attested),
        GuardClass.requirement(:mechanical_guard, :implementation_checks_verified),
        GuardClass.requirement(:mechanical_guard, :candidate_state_verified)
      ],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:in_review, :changes_requested} => %{
      owner: :independent_reviewer,
      responsibility: "review",
      guard_requirements: [GuardClass.requirement(:semantic_attestation, :review_changes_requested)],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:changes_requested, :in_review} => %{
      owner: :fixer,
      responsibility: "correction",
      guard_requirements: [
        GuardClass.requirement(:semantic_attestation, :correction_attested),
        GuardClass.requirement(:mechanical_guard, :correction_checks_verified),
        GuardClass.requirement(:mechanical_guard, :candidate_state_verified)
      ],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:in_review, :ready_to_merge} => %{
      owner: :independent_reviewer,
      responsibility: "review",
      guard_requirements: [
        GuardClass.requirement(:mechanical_guard, :review_acceptance_verified),
        GuardClass.requirement(:semantic_attestation, :review_accepted)
      ],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:ready_to_merge, :merging} => %{
      owner: :human,
      responsibility: "merge",
      guard_requirements: [
        GuardClass.requirement(:human_decision, :merge_approved),
        GuardClass.requirement(:mechanical_guard, :merge_guard_verified)
      ],
      side_effects: %{autonomous_merge: false, completion_proof_required: false}
    },
    {:merging, :done} => %{
      owner: :system,
      responsibility: "completion",
      guard_requirements: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)],
      side_effects: %{autonomous_merge: false, completion_proof_required: true}
    }
  }

  @type state ::
          :backlog
          | :planning
          | :ready
          | :in_progress
          | :in_review
          | :changes_requested
          | :ready_to_merge
          | :merging
          | :blocked
          | :done
          | :canceled

  @type classification :: %{
          activity: :inactive | :active | :dispatchable | :gated | :suspended | :terminal,
          owner: atom() | nil,
          responsibility: String.t() | nil,
          dispatchable: boolean(),
          terminal: boolean(),
          successful_terminal: boolean()
        }

  @type transition_metadata :: %{
          source: state(),
          target: state(),
          owner: atom(),
          responsibility: String.t(),
          guard_requirements: [GuardClass.requirement()],
          guard_classes: [GuardClass.class()],
          side_effects: map()
        }

  @spec states() :: [state()]
  def states, do: @states

  @spec display(term()) :: String.t() | nil
  def display(state) when is_atom(state), do: Map.get(@display_names, state)

  def display(state) when is_binary(state) do
    case parse(state) do
      {:ok, canonical_state} -> Map.get(@display_names, canonical_state)
      {:error, _reason} -> nil
    end
  end

  def display(_state), do: nil

  @spec parse(term()) :: {:ok, state()} | {:error, {:unknown_state, term()}}
  def parse(state) when is_atom(state) do
    if state in @states, do: {:ok, state}, else: {:error, {:unknown_state, state}}
  end

  def parse(state) when is_binary(state) do
    normalized = normalize_display(state)

    case Map.fetch(@state_by_display, normalized) do
      {:ok, canonical_state} -> {:ok, canonical_state}
      :error -> {:error, {:unknown_state, normalized}}
    end
  end

  def parse(state), do: {:error, {:unknown_state, state}}

  @spec canonical?(term()) :: boolean()
  def canonical?(state) do
    match?({:ok, _state}, parse(state))
  end

  @spec classification(term()) :: classification() | nil
  def classification(state) do
    case parse(state) do
      {:ok, canonical_state} -> Map.fetch!(@classifications, canonical_state)
      {:error, _reason} -> nil
    end
  end

  @spec owner(term()) :: atom() | nil
  def owner(state), do: state |> classification() |> get_in([:owner])

  @spec responsibility(term()) :: String.t() | nil
  def responsibility(state), do: state |> classification() |> get_in([:responsibility])

  @spec dispatchable?(term()) :: boolean()
  def dispatchable?(state), do: state |> classification() |> get_in([:dispatchable]) == true

  @spec terminal?(term()) :: boolean()
  def terminal?(state), do: state |> classification() |> get_in([:terminal]) == true

  @spec successful_terminal?(term()) :: boolean()
  def successful_terminal?(state), do: state |> classification() |> get_in([:successful_terminal]) == true

  @spec transition(term(), term()) :: {:ok, transition_metadata()} | {:error, term()}
  def transition(source, target) do
    with {:ok, canonical_source} <- parse(source),
         {:ok, canonical_target} <- parse(target) do
      transition_for(canonical_source, canonical_target)
    end
  end

  @spec valid_transition?(term(), term()) :: boolean()
  def valid_transition?(source, target), do: match?({:ok, _metadata}, transition(source, target))

  @spec guard_requirements(term(), term()) :: [GuardClass.requirement()] | nil
  def guard_requirements(source, target) do
    case transition(source, target) do
      {:ok, metadata} -> metadata.guard_requirements
      {:error, _reason} -> nil
    end
  end

  @spec guard_classes(term(), term()) :: [GuardClass.class()] | nil
  def guard_classes(source, target) do
    case transition(source, target) do
      {:ok, metadata} -> metadata.guard_classes
      {:error, _reason} -> nil
    end
  end

  @spec side_effects(term(), term()) :: map() | nil
  def side_effects(source, target) do
    case transition(source, target) do
      {:ok, metadata} -> metadata.side_effects
      {:error, _reason} -> nil
    end
  end

  defp transition_for(source, target) when source == target do
    {:error, {:invalid_transition, source, target}}
  end

  defp transition_for(source, :canceled) do
    if terminal?(source) do
      {:error, {:invalid_transition, source, :canceled}}
    else
      {:ok,
       transition_metadata(source, :canceled, %{
         owner: :human,
         responsibility: "cancellation",
         guard_requirements: [GuardClass.requirement(:human_decision, :cancellation_authorized)],
         side_effects: %{
           autonomous_merge: false,
           completion_proof_required: false,
           revoke_automation: true,
           dependency_effect: :invalidated
         }
       })}
    end
  end

  defp transition_for(source, target) do
    case Map.fetch(@transitions, {source, target}) do
      {:ok, metadata} -> {:ok, transition_metadata(source, target, metadata)}
      :error -> {:error, {:invalid_transition, source, target}}
    end
  end

  defp transition_metadata(source, target, metadata) do
    requirements = metadata.guard_requirements

    Map.merge(metadata, %{
      source: source,
      target: target,
      guard_classes: GuardClass.classes_for(requirements)
    })
  end

  defp normalize_display(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end
end
