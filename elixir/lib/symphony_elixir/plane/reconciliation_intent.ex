defmodule SymphonyElixir.Plane.ReconciliationIntent do
  @moduledoc "Bounded host-owned metadata for one Plane webhook reconciliation."

  alias SymphonyElixir.Plane.WebhookDelivery
  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity

  @enforce_keys [
    :kind,
    :host_generation,
    :event_key,
    :config_fingerprint,
    :contract_fingerprint,
    :requested_at
  ]
  defstruct [
    :kind,
    :work_item_id,
    :event,
    :host_generation,
    :event_key,
    :config_fingerprint,
    :contract_fingerprint,
    :state,
    :requested_at,
    coalesced_count: 0
  ]

  @type state ::
          :queued
          | :reading_provider
          | :observation_built
          | :assessed
          | :applied
          | :superseded
          | :failed
          | :cancelled
  @type t :: %__MODULE__{
          kind: :work_item | :full_epoch | :project_contract,
          work_item_id: String.t() | nil,
          event: String.t() | nil,
          host_generation: non_neg_integer(),
          event_key: tuple(),
          config_fingerprint: term(),
          contract_fingerprint: term(),
          state: state() | nil,
          requested_at: DateTime.t(),
          coalesced_count: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_reconciliation_intent}
  def new(attrs) when is_map(attrs) do
    identity = Map.get(attrs, :identity)
    generation = Map.get(attrs, :host_generation)
    kind = Map.get(attrs, :kind)
    work_item_id = Map.get(attrs, :work_item_id)

    with true <- match?(%EventIdentity{}, identity),
         true <- is_integer(generation) and generation >= 0,
         true <- kind in [:work_item, :full_epoch, :project_contract],
         true <- kind != :work_item or (is_binary(work_item_id) and work_item_id != "") do
      {:ok,
       %__MODULE__{
         kind: kind,
         work_item_id: work_item_id,
         event: identity.event,
         host_generation: generation,
         event_key: WebhookDelivery.event_key(identity),
         config_fingerprint: Map.get(attrs, :config_fingerprint),
         contract_fingerprint: Map.get(attrs, :contract_fingerprint),
         state: :queued,
         requested_at: Map.get(attrs, :requested_at, DateTime.utc_now()),
         coalesced_count: Map.get(attrs, :coalesced_count, 0)
       }}
    else
      _invalid -> {:error, :invalid_reconciliation_intent}
    end
  end

  def new(_attrs), do: {:error, :invalid_reconciliation_intent}

  @spec covered_by?(t(), non_neg_integer()) :: boolean()
  def covered_by?(%__MODULE__{host_generation: generation}, coverage_generation),
    do: is_integer(coverage_generation) and coverage_generation >= generation
end
