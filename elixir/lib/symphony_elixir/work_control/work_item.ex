defmodule SymphonyElixir.WorkControl.WorkItem do
  @moduledoc """
  Ephemeral provider-neutral canonical projection used by routed consumers.

  WorkItems are derived from current provider reads and trusted local context;
  they are not persisted and cannot recreate positive authority after restart.
  """

  alias SymphonyElixir.Tracker.Issue

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    LifecycleAssessment,
    ProviderObservation,
    SuspensionContext,
    WorkflowLifecycle
  }

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :branch_name,
    :url,
    :assignee_id,
    :labels,
    :created_at,
    :updated_at,
    :provider_observation,
    :lifecycle_assessment,
    :validated_lifecycle_state,
    :authority_disposition,
    :suspension_context,
    blocked_by: [],
    dependency_completeness: :complete
  ]

  @field_names [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :branch_name,
    :url,
    :assignee_id,
    :labels,
    :created_at,
    :updated_at,
    :provider_observation,
    :lifecycle_assessment,
    :validated_lifecycle_state,
    :authority_disposition,
    :suspension_context,
    :blocked_by,
    :dependency_completeness
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          provider_observation: ProviderObservation.t(),
          lifecycle_assessment: LifecycleAssessment.t(),
          validated_lifecycle_state: WorkflowLifecycle.state() | nil,
          authority_disposition: AuthorityDisposition.t(),
          suspension_context: SuspensionContext.t() | nil,
          blocked_by: [map()],
          dependency_completeness: term()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    cond do
      not valid_fields?(attrs) ->
        {:error, :invalid_work_item}

      not is_binary(Map.get(attrs, :id)) or String.trim(Map.get(attrs, :id)) == "" ->
        {:error, :missing_work_item_id}

      not match?(%ProviderObservation{}, Map.get(attrs, :provider_observation)) ->
        {:error, :missing_provider_observation}

      not match?(%LifecycleAssessment{}, Map.get(attrs, :lifecycle_assessment)) ->
        {:error, :missing_lifecycle_assessment}

      not match?(%AuthorityDisposition{}, Map.get(attrs, :authority_disposition)) ->
        {:error, :missing_authority_disposition}

      true ->
        {:ok, struct(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :invalid_work_item}

  @spec from_issue(Issue.t(), map()) :: {:ok, t()} | {:error, atom()}
  def from_issue(%Issue{} = issue, opts) when is_map(opts) do
    with {:ok, observation} <- ProviderObservation.from_issue(issue, opts) do
      prior_state = Map.get(opts, :prior_validated_lifecycle_state)
      evidence = Map.get(opts, :evidence, [])

      assessment =
        LifecycleAssessment.assess(
          observation,
          prior_state,
          evidence,
          lifecycle_assessment_context(opts)
        )

      previous_disposition = Map.get(opts, :prior_authority_disposition)
      disposition = AuthorityDisposition.derive(assessment, previous_disposition)

      new(%{
        id: issue.id,
        native_ref: issue.native_ref,
        identifier: issue.identifier,
        title: issue.title,
        description: issue.description,
        priority: issue.priority,
        branch_name: issue.branch_name,
        url: issue.url,
        assignee_id: issue.assignee_id,
        labels: issue.labels,
        created_at: issue.created_at,
        updated_at: issue.updated_at,
        provider_observation: observation,
        lifecycle_assessment: assessment,
        validated_lifecycle_state: assessment.validated_state,
        authority_disposition: disposition,
        suspension_context: Map.get(opts, :suspension_context),
        blocked_by: issue.blocked_by,
        dependency_completeness: issue.dependency_completeness
      })
    end
  end

  @spec canonical_state(t()) :: WorkflowLifecycle.state() | nil
  def canonical_state(%__MODULE__{validated_lifecycle_state: state}), do: state

  @spec dispatchable?(t()) :: boolean()
  def dispatchable?(%__MODULE__{
        validated_lifecycle_state: state,
        lifecycle_assessment: assessment,
        authority_disposition: disposition
      }) do
    WorkflowLifecycle.dispatchable?(state) and
      LifecycleAssessment.validated?(assessment) and
      AuthorityDisposition.eligible?(disposition)
  end

  @spec dependency_satisfying?(t()) :: boolean()
  def dependency_satisfying?(%__MODULE__{lifecycle_assessment: assessment}) do
    LifecycleAssessment.dependency_satisfying?(assessment)
  end

  @spec authority_available?(t()) :: boolean()
  def authority_available?(%__MODULE__{
        lifecycle_assessment: assessment,
        validated_lifecycle_state: state,
        authority_disposition: disposition
      }) do
    LifecycleAssessment.validated?(assessment) and
      WorkflowLifecycle.canonical?(state) and
      (AuthorityDisposition.eligible?(disposition) or AuthorityDisposition.active?(disposition))
  end

  @spec suspended?(t()) :: boolean()
  def suspended?(%__MODULE__{authority_disposition: disposition}) do
    AuthorityDisposition.suspended?(disposition)
  end

  defp valid_fields?(attrs) do
    Enum.all?(Map.keys(attrs), &(&1 in @field_names))
  end

  defp lifecycle_assessment_context(opts) do
    context =
      case Map.get(opts, :assessment_context, %{}) do
        context when is_map(context) -> context
        _invalid_context -> %{}
      end

    Enum.reduce([:runtime_attempt_id, :lineage_generation], context, fn key, context ->
      case Map.fetch(opts, key) do
        {:ok, value} -> Map.put(context, key, value)
        :error -> context
      end
    end)
  end
end
