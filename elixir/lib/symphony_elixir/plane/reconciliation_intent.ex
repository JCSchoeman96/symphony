defmodule SymphonyElixir.Plane.ReconciliationIntent do
  @moduledoc """
  Metadata retained for one queued targeted Plane webhook read.

  Presence in the Orchestrator's pending map represents the queued phase. When
  a read starts, the Orchestrator copies these fields into its task entry; the
  task result handler and work-control assessment represent the remaining flow.
  """

  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity

  @enforce_keys [
    :identity,
    :work_item_id,
    :event,
    :host_generation,
    :config_fingerprint,
    :contract_fingerprint,
    :requested_at
  ]
  defstruct [
    :identity,
    :work_item_id,
    :event,
    :host_generation,
    :config_fingerprint,
    :contract_fingerprint,
    :requested_at,
    coalesced_count: 0
  ]

  @type t :: %__MODULE__{
          identity: EventIdentity.t(),
          work_item_id: String.t(),
          event: String.t(),
          host_generation: non_neg_integer(),
          config_fingerprint: term(),
          contract_fingerprint: term(),
          requested_at: DateTime.t(),
          coalesced_count: non_neg_integer()
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_reconciliation_intent}
  def new(attrs) when is_map(attrs) do
    identity = Map.get(attrs, :identity)
    generation = Map.get(attrs, :host_generation)
    work_item_id = Map.get(attrs, :work_item_id)

    with true <- match?(%EventIdentity{}, identity),
         true <- is_integer(generation) and generation >= 0,
         true <- is_binary(work_item_id) and work_item_id != "" do
      {:ok,
       %__MODULE__{
         identity: identity,
         work_item_id: work_item_id,
         event: identity.event,
         host_generation: generation,
         config_fingerprint: Map.get(attrs, :config_fingerprint),
         contract_fingerprint: Map.get(attrs, :contract_fingerprint),
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
