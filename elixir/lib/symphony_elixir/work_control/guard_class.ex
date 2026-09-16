defmodule SymphonyElixir.WorkControl.GuardClass do
  @moduledoc """
  Typed guard requirements used by canonical lifecycle transitions.

  Guard class is part of the requirement identity. Evidence from another class
  cannot satisfy the requirement, even when its name is the same.
  """

  @classes [:mechanical_guard, :semantic_attestation, :human_decision]

  @type class :: :mechanical_guard | :semantic_attestation | :human_decision
  @type requirement :: %{class: class(), name: atom()}
  @type semantic_attestation :: %{
          class: :semantic_attestation,
          name: atom(),
          responsibility: atom() | String.t(),
          runtime_attempt_id: term(),
          lineage_generation: non_neg_integer(),
          subject: {:work_item, String.t()},
          timestamp: DateTime.t()
        }
  @type evidence :: requirement() | semantic_attestation()

  @spec classes() :: [class()]
  def classes, do: @classes

  @spec valid?(term()) :: boolean()
  def valid?(%{class: class, name: name}) when class in @classes and is_atom(name), do: true
  def valid?(_requirement), do: false

  @spec requirement(term(), term()) :: requirement() | nil
  def requirement(class, name) when class in @classes and is_atom(name) do
    %{class: class, name: name}
  end

  def requirement(_class, _name), do: nil

  @spec semantic_attestation(atom(), map()) ::
          {:ok, semantic_attestation()} | {:error, atom()}
  def semantic_attestation(name, attrs) when is_atom(name) and is_map(attrs) do
    attrs
    |> Map.put(:class, :semantic_attestation)
    |> Map.put(:name, name)
    |> validate_semantic_attestation()
  end

  def semantic_attestation(_name, _attrs), do: {:error, :invalid_semantic_attestation}

  @spec valid_evidence?(term()) :: boolean()
  def valid_evidence?(%{class: :semantic_attestation} = evidence) do
    match?({:ok, _evidence}, validate_semantic_attestation(evidence))
  end

  def valid_evidence?(%{class: class, name: name} = evidence)
      when class in @classes and class != :semantic_attestation and is_atom(name) do
    valid?(evidence)
  end

  def valid_evidence?(_evidence), do: false

  @spec valid_evidence?(term(), map()) :: boolean()
  def valid_evidence?(%{class: :semantic_attestation} = evidence, context) when is_map(context) do
    valid_evidence?(evidence) and semantic_context_matches?(evidence, context)
  end

  def valid_evidence?(%{class: :semantic_attestation}, _context), do: false
  def valid_evidence?(evidence, _context), do: valid_evidence?(evidence)

  @spec satisfied?(requirement(), term()) :: boolean()
  def satisfied?(requirement, evidence), do: satisfied?(requirement, evidence, %{})

  @spec satisfied?(requirement(), term(), map()) :: boolean()
  def satisfied?(%{class: class, name: name} = requirement, evidence, context)
      when class in @classes and is_atom(name) and is_map(context) do
    valid?(requirement) and
      evidence
      |> normalize_evidence()
      |> Enum.any?(&evidence_satisfies?(class, name, &1, context))
  end

  def satisfied?(_requirement, _evidence, _context), do: false

  @spec all_satisfied?([requirement()], term()) :: boolean()
  def all_satisfied?(requirements, evidence), do: all_satisfied?(requirements, evidence, %{})

  @spec all_satisfied?([requirement()], term(), map()) :: boolean()
  def all_satisfied?(requirements, evidence, context) when is_list(requirements) and is_map(context) do
    Enum.all?(requirements, &satisfied?(&1, evidence, context))
  end

  def all_satisfied?(_requirements, _evidence, _context), do: false

  @spec missing([requirement()], term()) :: [requirement()]
  def missing(requirements, evidence), do: missing(requirements, evidence, %{})

  @spec missing([requirement()], term(), map()) :: [requirement()]
  def missing(requirements, evidence, context) when is_list(requirements) and is_map(context) do
    Enum.reject(requirements, &satisfied?(&1, evidence, context))
  end

  def missing(requirements, _evidence, _context) when is_list(requirements), do: requirements
  def missing(_requirements, _evidence, _context), do: []

  @spec classes_for([requirement()]) :: [class()]
  def classes_for(requirements) when is_list(requirements) do
    requirements
    |> Enum.filter(&valid?/1)
    |> Enum.map(& &1.class)
    |> Enum.uniq()
  end

  def classes_for(_requirements), do: []

  defp evidence_satisfies?(:semantic_attestation, name, evidence, context) do
    match?(%{class: :semantic_attestation, name: ^name}, evidence) and
      valid_evidence?(evidence, context)
  end

  defp evidence_satisfies?(class, name, evidence, _context) do
    match?(%{class: ^class, name: ^name}, evidence) and valid_evidence?(evidence)
  end

  defp validate_semantic_attestation(%{class: :semantic_attestation, name: name} = evidence)
       when is_atom(name) do
    with :ok <- validate_responsibility(Map.get(evidence, :responsibility)),
         :ok <- validate_runtime_attempt_id(Map.get(evidence, :runtime_attempt_id)),
         :ok <- validate_lineage_generation(Map.get(evidence, :lineage_generation)),
         {:ok, subject} <- normalize_subject(Map.get(evidence, :subject)),
         :ok <- validate_timestamp(Map.get(evidence, :timestamp)) do
      {:ok, Map.put(evidence, :subject, subject)}
    end
  end

  defp validate_semantic_attestation(_evidence), do: {:error, :invalid_semantic_attestation}

  defp semantic_context_matches?(evidence, context) do
    with {:ok, expected_subject} <- normalize_subject(Map.get(context, :subject)),
         :ok <- validate_responsibility(Map.get(context, :responsibility)),
         :ok <- validate_runtime_attempt_id(Map.get(context, :runtime_attempt_id)),
         :ok <- validate_lineage_generation(Map.get(context, :lineage_generation)),
         true <- normalize_responsibility(evidence.responsibility) == normalize_responsibility(Map.get(context, :responsibility)),
         true <- evidence.runtime_attempt_id == Map.get(context, :runtime_attempt_id),
         true <- evidence.lineage_generation == Map.get(context, :lineage_generation),
         true <- normalize_subject_value(evidence.subject) == expected_subject,
         true <- timestamp_matches?(evidence.timestamp, context) do
      true
    else
      _failure -> false
    end
  end

  defp timestamp_matches?(timestamp, context) do
    case Map.fetch(context, :timestamp) do
      {:ok, expected_timestamp} -> timestamp == expected_timestamp
      :error -> true
    end
  end

  defp normalize_subject_value(subject) do
    case normalize_subject(subject) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> nil
    end
  end

  defp normalize_subject({:work_item, work_item_id}) when is_binary(work_item_id) do
    if String.trim(work_item_id) == "" do
      {:error, :invalid_subject}
    else
      {:ok, {:work_item, String.trim(work_item_id)}}
    end
  end

  defp normalize_subject(%{work_item_id: work_item_id}),
    do: normalize_subject({:work_item, work_item_id})

  defp normalize_subject(work_item_id) when is_binary(work_item_id),
    do: normalize_subject({:work_item, work_item_id})

  defp normalize_subject(nil), do: {:error, :missing_subject}
  defp normalize_subject(_subject), do: {:error, :invalid_subject}

  defp validate_responsibility(nil), do: {:error, :missing_responsibility}

  defp validate_responsibility(value) when is_atom(value) and not is_nil(value), do: :ok

  defp validate_responsibility(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_responsibility}, else: :ok
  end

  defp validate_responsibility(_value), do: {:error, :invalid_responsibility}

  defp normalize_responsibility(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_responsibility(value) when is_binary(value), do: String.trim(value)
  defp normalize_responsibility(value), do: value

  defp validate_runtime_attempt_id(nil), do: {:error, :missing_runtime_attempt_id}

  defp validate_runtime_attempt_id(value)
       when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_runtime_attempt_id}, else: :ok
  end

  defp validate_runtime_attempt_id(value) when is_atom(value) and not is_nil(value), do: :ok
  defp validate_runtime_attempt_id(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_runtime_attempt_id(value) when is_reference(value), do: :ok
  defp validate_runtime_attempt_id(_value), do: {:error, :invalid_runtime_attempt_id}

  defp validate_lineage_generation(nil), do: {:error, :missing_lineage_generation}

  defp validate_lineage_generation(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_lineage_generation(_value), do: {:error, :invalid_lineage_generation}

  defp validate_timestamp(nil), do: {:error, :missing_timestamp}
  defp validate_timestamp(%DateTime{}), do: :ok
  defp validate_timestamp(_value), do: {:error, :invalid_timestamp}

  defp normalize_evidence(evidence) when is_list(evidence), do: evidence
  defp normalize_evidence(evidence) when is_map(evidence), do: [evidence]
  defp normalize_evidence(_evidence), do: []
end
