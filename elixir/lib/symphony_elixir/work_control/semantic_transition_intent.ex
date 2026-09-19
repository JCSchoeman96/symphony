defmodule SymphonyElixir.WorkControl.SemanticTransitionIntent do
  @moduledoc """
  Bounded, provider-neutral request to move one work item between canonical states.

  This value is a host-side input. It deliberately has no provider state ID,
  endpoint, credential, or request-body field.
  """

  alias SymphonyElixir.WorkControl.{GuardClass, WorkflowLifecycle}

  @fields [
    :work_item_id,
    :requested_from,
    :requested_to,
    :responsibility,
    :guard_evidence,
    :requested_at,
    :runtime_attempt_id,
    :lineage_id,
    :lineage_generation
  ]

  defstruct [
    :work_item_id,
    :requested_from,
    :requested_to,
    :responsibility,
    :guard_evidence,
    :requested_at,
    :runtime_attempt_id,
    :lineage_id,
    :lineage_generation
  ]

  @type t :: %__MODULE__{
          work_item_id: String.t(),
          requested_from: WorkflowLifecycle.state(),
          requested_to: WorkflowLifecycle.state(),
          responsibility: String.t(),
          guard_evidence: [GuardClass.evidence()],
          requested_at: DateTime.t(),
          runtime_attempt_id: term(),
          lineage_id: String.t() | nil,
          lineage_generation: non_neg_integer() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         {:ok, from} <- canonical_atom(Map.get(attrs, :requested_from), :invalid_requested_from),
         {:ok, to} <- canonical_atom(Map.get(attrs, :requested_to), :invalid_requested_to),
         :ok <- validate_transition(from, to),
         :ok <- validate_work_item_id(Map.get(attrs, :work_item_id)),
         {:ok, responsibility} <- validate_responsibility(Map.get(attrs, :responsibility)),
         {:ok, evidence} <- validate_evidence(Map.get(attrs, :guard_evidence, [])),
         {:ok, requested_at} <- validate_timestamp(Map.get(attrs, :requested_at, DateTime.utc_now())),
         :ok <- validate_optional_lineage(attrs) do
      {:ok,
       %__MODULE__{
         work_item_id: String.trim(attrs.work_item_id),
         requested_from: from,
         requested_to: to,
         responsibility: responsibility,
         guard_evidence: evidence,
         requested_at: requested_at,
         runtime_attempt_id: Map.get(attrs, :runtime_attempt_id),
         lineage_id: normalize_optional_string(Map.get(attrs, :lineage_id)),
         lineage_generation: Map.get(attrs, :lineage_generation)
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_intent}

  @spec validate(t()) :: :ok | {:ok, t()} | {:error, atom()}
  def validate(%__MODULE__{} = intent) do
    case new(Map.from_struct(intent)) do
      {:ok, ^intent} -> :ok
      {:ok, _normalized} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_intent), do: {:error, :invalid_intent}

  defp validate_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @fields)), do: :ok, else: {:error, :invalid_intent_field}
  end

  defp canonical_atom(value, reason) when not is_atom(value), do: {:error, reason}

  defp canonical_atom(value, reason) do
    if WorkflowLifecycle.canonical?(value), do: {:ok, value}, else: {:error, reason}
  end

  defp validate_transition(from, to) do
    if WorkflowLifecycle.valid_transition?(from, to), do: :ok, else: {:error, :invalid_transition}
  end

  defp validate_work_item_id(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :missing_work_item_id}, else: :ok
  end

  defp validate_work_item_id(_value), do: {:error, :missing_work_item_id}

  defp validate_responsibility(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  defp validate_responsibility(value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: {:error, :missing_responsibility}, else: {:ok, normalized}
  end

  defp validate_responsibility(_value), do: {:error, :missing_responsibility}

  defp validate_evidence(evidence) when is_map(evidence), do: validate_evidence([evidence])

  defp validate_evidence(evidence) when is_list(evidence) do
    if Enum.all?(evidence, &GuardClass.valid_evidence?/1), do: {:ok, evidence}, else: {:error, :invalid_guard_evidence}
  end

  defp validate_evidence(_evidence), do: {:error, :invalid_guard_evidence}

  defp validate_timestamp(%DateTime{} = timestamp), do: {:ok, timestamp}
  defp validate_timestamp(_timestamp), do: {:error, :invalid_requested_at}

  defp validate_optional_lineage(attrs) do
    generation = Map.get(attrs, :lineage_generation)
    lineage_id = Map.get(attrs, :lineage_id)

    cond do
      not is_nil(generation) and (not is_integer(generation) or generation < 0) ->
        {:error, :invalid_lineage_generation}

      not is_nil(lineage_id) and (not is_binary(lineage_id) or String.trim(lineage_id) == "") ->
        {:error, :invalid_lineage_id}

      true ->
        :ok
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value
end
