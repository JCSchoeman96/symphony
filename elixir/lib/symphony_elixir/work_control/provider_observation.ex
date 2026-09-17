defmodule SymphonyElixir.WorkControl.ProviderObservation do
  @moduledoc """
  Immutable factual observation of a provider's current work-item report.

  This struct deliberately has no canonical lifecycle or authority field.
  Mapping the descriptive provider state is a separate operation from deciding
  whether that state is validated.
  """

  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle}

  defstruct [
    :provider,
    :work_item_id,
    :workspace_id,
    :project_id,
    :provider_state_id,
    :provider_state_group,
    :provider_state_name,
    :provider_updated_at,
    :observed_at,
    :snapshot_identity
  ]

  @legacy_state_aliases %{
    "todo" => :ready,
    "open" => :ready,
    "opened" => :ready,
    "pending" => :ready,
    "started" => :in_progress,
    "in development" => :in_progress,
    "human review" => :in_review,
    "rework" => :changes_requested,
    "closed" => :canceled,
    "cancelled" => :canceled,
    "duplicate" => :canceled
  }

  @type t :: %__MODULE__{
          provider: atom() | String.t() | nil,
          work_item_id: String.t(),
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          provider_state_id: String.t() | nil,
          provider_state_group: String.t() | atom() | nil,
          provider_state_name: String.t(),
          provider_updated_at: DateTime.t() | nil,
          observed_at: DateTime.t(),
          snapshot_identity: term()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    work_item_id = Map.get(attrs, :work_item_id)
    provider_state_name = Map.get(attrs, :provider_state_name)

    cond do
      not non_empty_binary?(work_item_id) ->
        {:error, :missing_work_item_id}

      not non_empty_binary?(provider_state_name) ->
        {:error, :missing_provider_state_name}

      true ->
        {:ok,
         %__MODULE__{
           provider: Map.get(attrs, :provider, :unknown),
           work_item_id: work_item_id,
           workspace_id: Map.get(attrs, :workspace_id),
           project_id: Map.get(attrs, :project_id),
           provider_state_id: Map.get(attrs, :provider_state_id),
           provider_state_group: Map.get(attrs, :provider_state_group),
           provider_state_name: provider_state_name,
           provider_updated_at: Map.get(attrs, :provider_updated_at),
           observed_at: Map.get(attrs, :observed_at, DateTime.utc_now()),
           snapshot_identity: Map.get(attrs, :snapshot_identity)
         }}
    end
  end

  def new(_attrs), do: {:error, :invalid_observation}

  @spec from_issue(Issue.t(), map()) :: {:ok, t()} | {:error, atom()}
  def from_issue(%Issue{} = issue, opts) when is_map(opts) do
    provider = Map.get(opts, :provider, :unknown)
    observed_at = Map.get(opts, :observed_at, DateTime.utc_now())

    new(%{
      provider: provider,
      work_item_id: issue.id,
      workspace_id: Map.get(opts, :workspace_id) || issue.workspace_id,
      project_id: Map.get(opts, :project_id) || issue.project_id,
      provider_state_id: Map.get(opts, :provider_state_id) || issue.provider_state_id,
      provider_state_group: Map.get(opts, :provider_state_group) || issue.provider_state_group,
      provider_state_name: Map.get(opts, :provider_state_name) || issue.state,
      provider_updated_at: Map.get(opts, :provider_updated_at) || issue.updated_at,
      observed_at: observed_at,
      snapshot_identity: Map.get(opts, :snapshot_identity) || default_snapshot_identity(provider, issue, observed_at)
    })
  end

  @spec map_state(t()) :: {:ok, WorkflowLifecycle.state()} | {:error, :unknown_provider_state}
  def map_state(%__MODULE__{provider_state_name: provider_state_name}) do
    case WorkflowLifecycle.parse(provider_state_name) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, :unknown_provider_state}
    end
  end

  @spec map_state(t(), ProviderProjectContract.t()) ::
          {:ok, WorkflowLifecycle.state()}
          | {:error, :unknown_state_mapping | :state_group_mismatch}
  def map_state(
        %__MODULE__{provider_state_id: provider_state_id, provider_state_group: provider_state_group},
        %ProviderProjectContract{} = contract
      ) do
    ProviderProjectContract.resolve_provider_state(contract, provider_state_id, provider_state_group)
  end

  @spec map_legacy_state(t()) :: {:ok, WorkflowLifecycle.state()} | {:error, :unknown_provider_state}
  def map_legacy_state(%__MODULE__{} = observation) do
    case map_state(observation) do
      {:ok, state} ->
        {:ok, state}

      {:error, :unknown_provider_state} ->
        normalized_state = normalize_state_name(observation.provider_state_name)

        case Map.fetch(@legacy_state_aliases, normalized_state) do
          {:ok, state} -> {:ok, state}
          :error -> {:error, :unknown_provider_state}
        end
    end
  end

  @spec stable_state_identity?(t()) :: boolean()
  def stable_state_identity?(%__MODULE__{provider_state_id: provider_state_id}) do
    non_empty_binary?(provider_state_id)
  end

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp default_snapshot_identity(provider, %Issue{} = issue, observed_at)
       when provider in [:plane, "plane"] do
    %{
      provider: :plane,
      workspace_id: issue.workspace_id,
      project_id: issue.project_id,
      work_item_id: issue.id,
      provider_updated_at: issue.updated_at,
      observed_at: observed_at
    }
  end

  defp default_snapshot_identity(_provider, _issue, _observed_at), do: nil

  defp normalize_state_name(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end
end
