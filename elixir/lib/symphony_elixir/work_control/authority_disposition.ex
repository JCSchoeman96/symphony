defmodule SymphonyElixir.WorkControl.AuthorityDisposition do
  @moduledoc """
  Ephemeral projection of the autonomous authority available for a WorkItem.

  This is a policy value, not a later durable runtime-authority implementation.
  """

  alias SymphonyElixir.WorkControl.{LifecycleAssessment, WorkflowLifecycle}

  defstruct status: :none, lifecycle_state: nil, reason: nil, resume_target: nil, updated_at: nil

  @type status :: :none | :eligible | :active | :suspended | :escalated
  @type t :: %__MODULE__{
          status: status(),
          lifecycle_state: WorkflowLifecycle.state() | nil,
          reason: atom() | nil,
          resume_target: WorkflowLifecycle.state() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec new(map()) :: t()
  def new(attrs \\ %{}) when is_map(attrs) do
    %__MODULE__{
      status: Map.get(attrs, :status, :none),
      lifecycle_state: Map.get(attrs, :lifecycle_state),
      reason: Map.get(attrs, :reason),
      resume_target: Map.get(attrs, :resume_target),
      updated_at: Map.get(attrs, :updated_at, DateTime.utc_now())
    }
  end

  @spec derive(LifecycleAssessment.t()) :: t()
  def derive(assessment, previous \\ nil)

  @spec derive(LifecycleAssessment.t(), t() | nil) :: t()
  def derive(%LifecycleAssessment{} = assessment, %__MODULE__{status: :escalated} = previous) do
    %{previous | lifecycle_state: assessment.validated_state, updated_at: DateTime.utc_now()}
  end

  def derive(%LifecycleAssessment{} = assessment, %__MODULE__{status: :suspended} = previous) do
    %{
      previous
      | lifecycle_state: previous.lifecycle_state || assessment.validated_state,
        updated_at: DateTime.utc_now()
    }
  end

  def derive(%LifecycleAssessment{} = assessment, previous) do
    case assessment.status do
      :authority_reducing -> suspended(assessment, assessment.reason)
      :validation_required -> suspended(assessment, assessment.reason)
      :invalid -> suspended(assessment, assessment.reason)
      :validated -> derive_validated(assessment.validated_state, previous)
      _status -> new(%{status: :none, lifecycle_state: assessment.validated_state})
    end
  end

  @spec transition(t(), status(), map()) :: {:ok, t()} | {:error, atom()}
  def transition(%__MODULE__{status: :escalated}, _target, _opts), do: {:error, :terminal_disposition}

  def transition(%__MODULE__{status: :none} = disposition, :eligible, opts)
      when is_map(opts) do
    if Map.get(opts, :lifecycle_eligible, false) do
      {:ok, %{disposition | status: :eligible, updated_at: DateTime.utc_now()}}
    else
      {:error, :lifecycle_not_eligible}
    end
  end

  def transition(%__MODULE__{status: :eligible} = disposition, :active, opts)
      when is_map(opts) do
    if Map.get(opts, :attempt_started, false) do
      {:ok, %{disposition | status: :active, updated_at: DateTime.utc_now()}}
    else
      {:error, :attempt_not_started}
    end
  end

  def transition(%__MODULE__{status: status} = disposition, :suspended, opts)
      when status in [:eligible, :active] and is_map(opts) do
    {:ok,
     %{
       disposition
       | status: :suspended,
         reason: Map.get(opts, :reason, :unsafe_condition),
         updated_at: DateTime.utc_now()
     }}
  end

  def transition(%__MODULE__{status: :suspended, lifecycle_state: :canceled}, target, _opts)
      when target in [:eligible, :active],
      do: {:error, :canceled_terminal}

  def transition(%__MODULE__{status: :suspended} = disposition, target, opts)
      when target in [:eligible, :active] and is_map(opts) do
    cond do
      not Map.get(opts, :fresh_reconciliation, false) ->
        {:error, :fresh_reconciliation_required}

      not WorkflowLifecycle.canonical?(Map.get(opts, :resume_target)) ->
        {:error, :trusted_resume_target_required}

      target == :active and not Map.get(opts, :attempt_started, false) ->
        {:error, :attempt_not_started}

      true ->
        {:ok,
         %{
           disposition
           | status: target,
             lifecycle_state: Map.get(opts, :resume_target),
             resume_target: Map.get(opts, :resume_target),
             reason: nil,
             updated_at: DateTime.utc_now()
         }}
    end
  end

  def transition(%__MODULE__{status: :suspended} = disposition, :escalated, opts)
      when is_map(opts) do
    if Map.get(opts, :human_decision, false) do
      {:ok,
       %{
         disposition
         | status: :escalated,
           reason: Map.get(opts, :reason, :human_decision_required),
           updated_at: DateTime.utc_now()
       }}
    else
      {:error, :human_decision_required}
    end
  end

  def transition(_disposition, _target, _opts), do: {:error, :invalid_disposition_transition}

  @spec suspend(t(), atom()) :: {:ok, t()} | {:error, atom()}
  def suspend(%__MODULE__{status: status} = disposition, reason)
      when status in [:eligible, :active] and is_atom(reason) do
    {:ok, %{disposition | status: :suspended, reason: reason, updated_at: DateTime.utc_now()}}
  end

  def suspend(%__MODULE__{status: :suspended} = disposition, reason) when is_atom(reason) do
    {:ok, %{disposition | reason: reason, updated_at: DateTime.utc_now()}}
  end

  def suspend(%__MODULE__{status: :escalated}, _reason), do: {:error, :terminal_disposition}
  def suspend(%__MODULE__{}, _reason), do: {:error, :authority_unavailable}

  @spec none?(t()) :: boolean()
  def none?(%__MODULE__{status: :none}), do: true
  def none?(_disposition), do: false

  @spec eligible?(t()) :: boolean()
  def eligible?(%__MODULE__{status: :eligible}), do: true
  def eligible?(_disposition), do: false

  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(_disposition), do: false

  @spec suspended?(t()) :: boolean()
  def suspended?(%__MODULE__{status: :suspended}), do: true
  def suspended?(_disposition), do: false

  @spec escalated?(t()) :: boolean()
  def escalated?(%__MODULE__{status: :escalated}), do: true
  def escalated?(_disposition), do: false

  defp derive_validated(:ready, previous), do: eligible_or_active(:ready, previous)

  defp derive_validated(state, previous) when state in [:planning, :in_progress, :in_review, :changes_requested] do
    eligible_or_active(state, previous)
  end

  defp derive_validated(state, _previous), do: new(%{status: :none, lifecycle_state: state})

  defp eligible_or_active(state, %__MODULE__{status: :active, lifecycle_state: lifecycle_state} = previous)
       when lifecycle_state == state do
    %{previous | updated_at: DateTime.utc_now()}
  end

  defp eligible_or_active(state, _previous), do: new(%{status: :eligible, lifecycle_state: state})

  defp suspended(assessment, reason) do
    new(%{status: :suspended, lifecycle_state: assessment.validated_state, reason: reason})
  end
end
