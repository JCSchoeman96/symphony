defmodule SymphonyElixir.WorkControl.SuspensionContext do
  @moduledoc """
  Pure policy shape for local lifecycle suspension and recovery.

  Durable suspension and recovery remain owned by H-060B; this value contains
  only the ephemeral context needed to make a local decision explicit.
  """

  alias SymphonyElixir.WorkControl.{ProviderObservation, WorkflowLifecycle}

  defstruct [
    :work_item_id,
    :last_validated_lifecycle_state,
    :provider_observation,
    :reason,
    :lineage_generation,
    :created_at,
    :recovery_policy,
    :required_evidence,
    :resume_target,
    :status
  ]

  @type status :: :open | :resolving | :resolved | :escalated
  @type t :: %__MODULE__{
          work_item_id: String.t(),
          last_validated_lifecycle_state: WorkflowLifecycle.state(),
          provider_observation: ProviderObservation.t(),
          reason: atom() | term(),
          lineage_generation: non_neg_integer() | nil,
          created_at: DateTime.t(),
          recovery_policy: atom() | term(),
          required_evidence: [term()],
          resume_target: WorkflowLifecycle.state() | nil,
          status: status()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_work_item_id(Map.get(attrs, :work_item_id)),
         :ok <- validate_last_state(Map.get(attrs, :last_validated_lifecycle_state)),
         :ok <- validate_observation(Map.get(attrs, :provider_observation)),
         :ok <- validate_reason(Map.get(attrs, :reason)),
         :ok <- validate_required_evidence(Map.get(attrs, :required_evidence, [])) do
      {:ok,
       %__MODULE__{
         work_item_id: Map.get(attrs, :work_item_id),
         last_validated_lifecycle_state: Map.get(attrs, :last_validated_lifecycle_state),
         provider_observation: Map.get(attrs, :provider_observation),
         reason: Map.get(attrs, :reason),
         lineage_generation: Map.get(attrs, :lineage_generation),
         created_at: Map.get(attrs, :created_at, DateTime.utc_now()),
         recovery_policy: Map.get(attrs, :recovery_policy, :fresh_reconciliation),
         required_evidence: Map.get(attrs, :required_evidence, []),
         resume_target: Map.get(attrs, :resume_target),
         status: Map.get(attrs, :status, :open)
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_suspension_context}

  @spec begin_resolution(t()) :: {:ok, t()} | {:error, atom()}
  def begin_resolution(%__MODULE__{status: :open} = context), do: {:ok, %{context | status: :resolving}}

  def begin_resolution(%__MODULE__{status: status}) when status in [:resolved, :escalated] do
    {:error, :terminal_suspension_context}
  end

  def begin_resolution(%__MODULE__{status: :resolving}), do: {:error, :already_resolving}

  @spec resolve(t(), map()) :: {:ok, t()} | {:error, atom()}
  def resolve(%__MODULE__{status: :resolving} = context, opts) when is_map(opts) do
    with :ok <- require_fresh_reconciliation(opts),
         :ok <- require_resume_target(opts),
         :ok <- require_evidence(context.required_evidence, Map.get(opts, :required_evidence, [])) do
      {:ok,
       %{
         context
         | status: :resolved,
           resume_target: Map.get(opts, :resume_target)
       }}
    end
  end

  def resolve(%__MODULE__{}, _opts), do: {:error, :context_not_resolving}

  @spec escalate(t(), term()) :: {:ok, t()} | {:error, atom()}
  def escalate(%__MODULE__{status: :resolving} = context, reason) do
    {:ok, %{context | status: :escalated, reason: reason}}
  end

  def escalate(%__MODULE__{}, _reason), do: {:error, :context_not_resolving}

  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: :open}), do: true
  def open?(_context), do: false

  @spec resolving?(t()) :: boolean()
  def resolving?(%__MODULE__{status: :resolving}), do: true
  def resolving?(_context), do: false

  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{status: :resolved}), do: true
  def resolved?(_context), do: false

  @spec escalated?(t()) :: boolean()
  def escalated?(%__MODULE__{status: :escalated}), do: true
  def escalated?(_context), do: false

  defp validate_work_item_id(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :missing_work_item_id}, else: :ok
  end

  defp validate_work_item_id(_value), do: {:error, :missing_work_item_id}

  defp validate_last_state(value) do
    if WorkflowLifecycle.canonical?(value), do: :ok, else: {:error, :invalid_last_validated_lifecycle_state}
  end

  defp validate_observation(%ProviderObservation{}), do: :ok
  defp validate_observation(_value), do: {:error, :invalid_provider_observation}

  defp validate_reason(nil), do: {:error, :missing_reason}
  defp validate_reason(_reason), do: :ok

  defp validate_required_evidence(value) when is_list(value), do: :ok
  defp validate_required_evidence(_value), do: {:error, :invalid_required_evidence}

  defp require_fresh_reconciliation(opts) do
    if Map.get(opts, :fresh_reconciliation, false), do: :ok, else: {:error, :fresh_reconciliation_required}
  end

  defp require_resume_target(opts) do
    if WorkflowLifecycle.canonical?(Map.get(opts, :resume_target)) do
      :ok
    else
      {:error, :trusted_resume_target_required}
    end
  end

  defp require_evidence(required, supplied) do
    if is_list(required) and is_list(supplied) and Enum.all?(required, &Enum.member?(supplied, &1)) do
      :ok
    else
      {:error, :required_evidence_missing}
    end
  end
end
