defmodule SymphonyElixir.WorkControl.ProviderObservation do
  @moduledoc """
  Immutable factual observation of a provider's current work-item report.

  This struct deliberately has no canonical lifecycle or authority field.
  Mapping the descriptive provider state is a separate operation from deciding
  whether that state is validated.
  """

  alias SymphonyElixir.Config
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
    :snapshot_identity,
    :tracker_read_signature,
    presence: :present
  ]

  @tracker_read_fields [
    :provider,
    :presence,
    :work_item_id,
    :workspace_id,
    :project_id,
    :provider_state_id,
    :provider_state_group,
    :provider_state_name,
    :provider_updated_at,
    :observed_at
  ]

  @max_tracker_read_age_ms 300_000

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
          provider_state_name: String.t() | nil,
          provider_updated_at: DateTime.t() | nil,
          observed_at: DateTime.t(),
          snapshot_identity: term(),
          tracker_read_signature: String.t() | nil,
          presence: :present | :not_found
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    work_item_id = Map.get(attrs, :work_item_id)
    provider_state_name = Map.get(attrs, :provider_state_name)
    presence = Map.get(attrs, :presence, :present)

    cond do
      not non_empty_binary?(work_item_id) ->
        {:error, :missing_work_item_id}

      not non_empty_binary?(provider_state_name) ->
        {:error, :missing_provider_state_name}

      presence != :present ->
        {:error, :invalid_presence}

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
           snapshot_identity: Map.get(attrs, :snapshot_identity),
           presence: :present
         }}
    end
  end

  def new(_attrs), do: {:error, :invalid_observation}

  @spec new_not_found(map()) :: {:ok, t()} | {:error, :invalid_not_found_observation}
  def new_not_found(attrs) when is_map(attrs) do
    work_item_id = Map.get(attrs, :work_item_id)
    workspace_id = Map.get(attrs, :workspace_id)
    project_id = Map.get(attrs, :project_id)

    if Map.get(attrs, :provider) in [:plane, "plane"] and non_empty_binary?(work_item_id) and
         non_empty_binary?(workspace_id) and non_empty_binary?(project_id) do
      {:ok,
       %__MODULE__{
         provider: :plane,
         work_item_id: work_item_id,
         workspace_id: workspace_id,
         project_id: project_id,
         provider_state_id: nil,
         provider_state_group: nil,
         provider_state_name: nil,
         provider_updated_at: nil,
         observed_at: Map.get(attrs, :observed_at, DateTime.utc_now()),
         snapshot_identity: Map.get(attrs, :snapshot_identity),
         presence: :not_found
       }}
    else
      {:error, :invalid_not_found_observation}
    end
  end

  def new_not_found(_attrs), do: {:error, :invalid_not_found_observation}

  @doc false
  @spec new_plane_not_found(String.t(), ProviderProjectContract.t(), term()) :: t()
  def new_plane_not_found(work_item_id, %ProviderProjectContract{} = contract, snapshot_identity) do
    %__MODULE__{
      provider: :plane,
      work_item_id: work_item_id,
      workspace_id: contract.workspace_id,
      project_id: contract.project_id,
      provider_state_id: nil,
      provider_state_group: nil,
      provider_state_name: nil,
      provider_updated_at: nil,
      observed_at: DateTime.utc_now(),
      snapshot_identity: snapshot_identity,
      presence: :not_found
    }
  end

  @spec from_issue(Issue.t(), map()) :: {:ok, t()} | {:error, atom()}
  def from_issue(%Issue{} = issue, opts) when is_map(opts) do
    case signed_observation_from_issue(issue, opts) do
      {:ok, observation} ->
        {:ok, observation}

      :absent ->
        unsigned_observation_from_issue(issue, opts)

      :mismatch ->
        {:error, :provider_observation_mismatch}
    end
  end

  @doc false
  @spec tracker_read_payload(map()) :: binary()
  def tracker_read_payload(observation) when is_map(observation) do
    fields = Map.new(@tracker_read_fields, &{&1, Map.get(observation, &1)})
    :erlang.term_to_binary(fields)
  end

  @doc false
  @spec valid_tracker_read?(term()) :: boolean()
  def valid_tracker_read?(observation) when is_map(observation) do
    with signature when is_binary(signature) <- Map.get(observation, :tracker_read_signature),
         {:ok, key} <- tracker_read_signing_key(),
         {:ok, supplied} <- decode_tracker_read_signature(signature) do
      expected = :crypto.mac(:hmac, :sha256, key, tracker_read_payload(observation))
      :crypto.hash_equals(supplied, expected)
    else
      _failure -> false
    end
  rescue
    _error -> false
  end

  def valid_tracker_read?(_observation), do: false

  @doc false
  @spec fresh_tracker_read?(term()) :: boolean()
  def fresh_tracker_read?(%{observed_at: %DateTime{} = observed_at}) do
    age_ms = DateTime.diff(DateTime.utc_now(), observed_at, :millisecond)
    age_ms >= 0 and age_ms <= @max_tracker_read_age_ms
  rescue
    _error -> false
  end

  def fresh_tracker_read?(_observation), do: false

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
        %__MODULE__{
          provider_state_id: provider_state_id,
          provider_state_group: provider_state_group
        },
        %ProviderProjectContract{} = contract
      ) do
    ProviderProjectContract.resolve_provider_state(
      contract,
      provider_state_id,
      provider_state_group
    )
  end

  @spec map_legacy_state(t()) ::
          {:ok, WorkflowLifecycle.state()} | {:error, :unknown_provider_state}
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
  def stable_state_identity?(%__MODULE__{
        presence: :present,
        provider_state_id: provider_state_id
      }) do
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

  defp tracker_observation_matches_issue?(observation, issue) do
    observation.work_item_id == issue.id and observation.presence == :present and
      observation.workspace_id == issue.workspace_id and
      observation.project_id == issue.project_id and
      observation.provider_state_id == issue.provider_state_id and
      observation.provider_state_group == issue.provider_state_group and
      observation.provider_state_name == issue.state and
      observation.provider_updated_at == issue.updated_at
  end

  defp signed_observation_from_issue(issue, opts) do
    case Map.get(issue, :tracker_read_observation) do
      %__MODULE__{} = observation ->
        if tracker_observation_matches_issue?(observation, issue) and
             provider_matches?(
               Map.get(opts, :provider, observation.provider),
               observation.provider
             ) do
          {:ok, observation}
        else
          :mismatch
        end

      _missing ->
        :absent
    end
  end

  defp unsigned_observation_from_issue(issue, opts) do
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
      snapshot_identity:
        Map.get(opts, :snapshot_identity) ||
          default_snapshot_identity(provider, issue, observed_at)
    })
  end

  defp provider_matches?(provider, observed_provider)
       when provider in [:plane, "plane"] and observed_provider in [:plane, "plane"],
       do: true

  defp provider_matches?(provider, provider), do: true
  defp provider_matches?(_provider, _observed_provider), do: false

  defp normalize_state_name(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp tracker_read_signing_key do
    case Application.get_env(:symphony_elixir, :completion_proof_signing_key) do
      key when is_binary(key) and byte_size(key) >= 32 ->
        {:ok, derive_tracker_read_signing_key(key)}

      _missing ->
        plane_api_key_signing_key()
    end
  end

  defp plane_api_key_signing_key do
    case Config.settings() do
      {:ok, %{tracker: %{kind: kind, api_key: api_key}}}
      when kind in [:plane, "plane"] and is_binary(api_key) and api_key != "" ->
        {:ok, derive_tracker_read_signing_key(api_key)}

      _missing ->
        {:error, :tracker_read_signing_key_required}
    end
  end

  defp derive_tracker_read_signing_key(key) do
    :crypto.hash(:sha256, "symphony-tracker-read-v1:" <> key)
  end

  defp decode_tracker_read_signature("sha256:" <> encoded) do
    case Base.decode16(encoded, case: :lower) do
      {:ok, signature} when byte_size(signature) == 32 -> {:ok, signature}
      _ -> :error
    end
  end

  defp decode_tracker_read_signature(_signature), do: :error
end
