defmodule SymphonyElixir.WorkControl.LifecycleAssessment do
  @moduledoc """
  Closed assessment of one provider observation against trusted lifecycle law.

  A new observation receives a new assessment. Mapping records which canonical
  state the provider name could represent; assessment records whether that
  observation is trusted for local authority.
  """

  alias SymphonyElixir.WorkControl.{GuardClass, ProviderObservation, WorkflowLifecycle}

  defstruct [
    :work_item_id,
    :provider_observation,
    :mapped_state,
    :validated_state,
    :status,
    :required_guards,
    :satisfied_guards,
    :missing_guards,
    :reason,
    :assessed_at
  ]

  @type status ::
          :unassessed
          | :mapping_resolved
          | :validated
          | :authority_reducing
          | :validation_required
          | :invalid

  @type t :: %__MODULE__{
          work_item_id: String.t(),
          provider_observation: ProviderObservation.t(),
          mapped_state: WorkflowLifecycle.state() | nil,
          validated_state: WorkflowLifecycle.state() | nil,
          status: status(),
          required_guards: [GuardClass.requirement()],
          satisfied_guards: [term()],
          missing_guards: [GuardClass.requirement()],
          reason: atom() | nil,
          assessed_at: DateTime.t() | nil
        }

  @spec new(ProviderObservation.t()) :: t()
  def new(%ProviderObservation{} = observation) do
    %__MODULE__{
      work_item_id: observation.work_item_id,
      provider_observation: observation,
      status: :unassessed,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      assessed_at: nil
    }
  end

  @spec resolve_mapping(t()) ::
          {:ok, t()} | {:error, t()} | {:error, :assessment_already_resolved}
  def resolve_mapping(%__MODULE__{status: :unassessed} = assessment) do
    case ProviderObservation.map_state(assessment.provider_observation) do
      {:ok, state} ->
        {:ok, %{assessment | status: :mapping_resolved, mapped_state: state}}

      {:error, :unknown_provider_state} ->
        {:error, finalize(assessment, :invalid, nil, nil, [], [], :unknown_mapping)}
    end
  end

  def resolve_mapping(%__MODULE__{}), do: {:error, :assessment_already_resolved}

  @spec assess(ProviderObservation.t(), WorkflowLifecycle.state() | nil, term()) :: t()
  def assess(%ProviderObservation{} = observation, prior_validated_state, evidence),
    do: assess(observation, prior_validated_state, evidence, %{})

  @spec assess(t(), WorkflowLifecycle.state() | nil, term()) :: t()
  def assess(%__MODULE__{} = assessment, prior_validated_state, evidence),
    do: assess(assessment, prior_validated_state, evidence, %{})

  @spec assess(ProviderObservation.t(), WorkflowLifecycle.state() | nil, term(), map()) :: t()
  def assess(%ProviderObservation{} = observation, prior_validated_state, evidence, context)
      when is_map(context) do
    observation
    |> new()
    |> assess(prior_validated_state, evidence, context)
  end

  @spec assess(t(), WorkflowLifecycle.state() | nil, term(), map()) :: t()
  def assess(%__MODULE__{} = assessment, prior_validated_state, evidence, context)
      when is_map(context) do
    evidence = normalize_evidence(evidence)

    case resolve_mapping(assessment) do
      {:ok, mapped_assessment} ->
        assess_mapped(
          mapped_assessment,
          normalize_prior_state(prior_validated_state),
          evidence,
          assessment_context(mapped_assessment, context)
        )

      {:error, %__MODULE__{} = invalid} ->
        %{invalid | assessed_at: DateTime.utc_now()}

      {:error, :assessment_already_resolved} ->
        finalize(
          assessment,
          :invalid,
          assessment.mapped_state,
          prior_validated_state,
          [],
          evidence,
          :assessment_reused
        )
    end
  end

  @spec validated?(t()) :: boolean()
  def validated?(%__MODULE__{status: :validated}), do: true
  def validated?(_assessment), do: false

  @spec authority_reducing?(t()) :: boolean()
  def authority_reducing?(%__MODULE__{status: :authority_reducing}), do: true
  def authority_reducing?(_assessment), do: false

  @spec validation_required?(t()) :: boolean()
  def validation_required?(%__MODULE__{status: :validation_required}), do: true
  def validation_required?(_assessment), do: false

  @spec invalid?(t()) :: boolean()
  def invalid?(%__MODULE__{status: :invalid}), do: true
  def invalid?(_assessment), do: false

  @spec completion_validated?(t()) :: boolean()
  def completion_validated?(%__MODULE__{status: :validated, validated_state: :done} = assessment) do
    completion_guard = GuardClass.requirement(:mechanical_guard, :completion_proof_verified)
    GuardClass.satisfied?(completion_guard, assessment.satisfied_guards)
  end

  def completion_validated?(_assessment), do: false

  @spec dependency_satisfying?(t()) :: boolean()
  def dependency_satisfying?(assessment), do: completion_validated?(assessment)

  defp assess_mapped(%__MODULE__{mapped_state: mapped_state} = assessment, nil, evidence, context) do
    cond do
      mapped_state == :backlog ->
        finalize(assessment, :validated, mapped_state, mapped_state, [], evidence, :initial_inactive_state)

      mapped_state == :canceled ->
        finalize(assessment, :authority_reducing, mapped_state, mapped_state, [], evidence, :canceled)

      mapped_state == :blocked ->
        finalize(assessment, :authority_reducing, mapped_state, mapped_state, [], evidence, :provider_blocked)

      mapped_state == :done ->
        assess_completion(assessment, nil, evidence, context)

      true ->
        finalize(assessment, :validation_required, mapped_state, nil, [], evidence, :initial_state_requires_validation)
    end
  end

  defp assess_mapped(%__MODULE__{mapped_state: mapped_state} = assessment, prior_state, evidence, context) do
    cond do
      mapped_state == :canceled ->
        finalize(assessment, :authority_reducing, mapped_state, mapped_state, [], evidence, :canceled)

      mapped_state == :blocked ->
        finalize(assessment, :authority_reducing, mapped_state, mapped_state, [], evidence, :provider_blocked)

      mapped_state == prior_state and mapped_state == :done ->
        require_completion_proof(assessment, prior_state, evidence, context)

      mapped_state == :done ->
        assess_completion(assessment, prior_state, evidence, context)

      mapped_state == prior_state ->
        finalize(assessment, :validated, mapped_state, mapped_state, [], evidence, :corroborated_state)

      true ->
        assess_transition(assessment, prior_state, mapped_state, evidence, context)
    end
  end

  defp assess_completion(assessment, prior_state, evidence, context) do
    cond do
      is_nil(prior_state) ->
        require_completion_proof(assessment, nil, [], context)

      prior_state == :merging ->
        require_completion_proof(assessment, prior_state, evidence, context)

      true ->
        assess_transition(assessment, prior_state, :done, evidence, context)
    end
  end

  defp assess_transition(assessment, prior_state, mapped_state, evidence, context) do
    case WorkflowLifecycle.transition(prior_state, mapped_state) do
      {:ok, metadata} ->
        required_guards = metadata.guard_requirements
        guard_context = Map.put(context, :responsibility, metadata.responsibility)
        missing_guards = GuardClass.missing(required_guards, evidence, guard_context)

        if missing_guards == [] do
          finalize(
            assessment,
            :validated,
            mapped_state,
            mapped_state,
            required_guards,
            evidence,
            :transition_validated,
            guard_context
          )
        else
          finalize(
            assessment,
            :validation_required,
            mapped_state,
            prior_state,
            required_guards,
            evidence,
            :required_evidence_missing,
            guard_context
          )
        end

      {:error, _reason} ->
        finalize(assessment, :invalid, mapped_state, prior_state, [], evidence, :impossible_transition)
    end
  end

  defp require_completion_proof(assessment, prior_state, evidence, context) do
    required_guards = [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
    missing_guards = GuardClass.missing(required_guards, evidence, context)

    if missing_guards == [] do
      finalize(
        assessment,
        :validated,
        :done,
        :done,
        required_guards,
        evidence,
        if(prior_state == :done, do: :corroborated_completion, else: :completion_proof_verified),
        context
      )
    else
      finalize(
        assessment,
        :validation_required,
        :done,
        prior_state,
        required_guards,
        evidence,
        :completion_proof_required,
        context
      )
    end
  end

  defp finalize(
         assessment,
         status,
         mapped_state,
         validated_state,
         required_guards,
         evidence,
         reason,
         context \\ %{}
       ) do
    %{
      assessment
      | status: status,
        mapped_state: mapped_state,
        validated_state: validated_state,
        required_guards: required_guards,
        satisfied_guards: satisfied_evidence(required_guards, evidence, context),
        missing_guards: GuardClass.missing(required_guards, evidence, context),
        reason: reason,
        assessed_at: DateTime.utc_now()
    }
  end

  defp assessment_context(%__MODULE__{work_item_id: work_item_id}, context) do
    Map.put(context, :subject, {:work_item, work_item_id})
  end

  defp satisfied_evidence(requirements, evidence, context) do
    evidence = normalize_evidence(evidence)

    Enum.filter(evidence, fn candidate ->
      Enum.any?(requirements, &GuardClass.satisfied?(&1, candidate, context))
    end)
  end

  defp normalize_prior_state(nil), do: nil

  defp normalize_prior_state(state) do
    case WorkflowLifecycle.parse(state) do
      {:ok, canonical_state} -> canonical_state
      {:error, _reason} -> :invalid_prior_state
    end
  end

  defp normalize_evidence(evidence) when is_list(evidence), do: evidence
  defp normalize_evidence(evidence) when is_map(evidence), do: [evidence]
  defp normalize_evidence(_evidence), do: []
end
