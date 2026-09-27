defmodule SymphonyElixir.Plane.WebhookDedupRegistry do
  @moduledoc "Bounded, process-owned ETS retention for Plane delivery and event keys."

  alias SymphonyElixir.Plane.WebhookDelivery
  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity

  @default_ttl_ms 24 * 60 * 60 * 1_000
  @default_max_entries 20_000

  defstruct [:entries, :ordering, :owner, ttl_ms: @default_ttl_ms, max_entries: @default_max_entries, sequence: 0]

  @type t :: %__MODULE__{
          entries: :ets.tid(),
          ordering: :ets.tid(),
          owner: pid(),
          ttl_ms: pos_integer(),
          max_entries: pos_integer(),
          sequence: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      entries: :ets.new(__MODULE__, [:set, :private]),
      ordering: :ets.new(__MODULE__, [:ordered_set, :private]),
      owner: self(),
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      max_entries: Keyword.get(opts, :max_entries, @default_max_entries)
    }
  end

  @spec claim(t(), EventIdentity.t(), integer()) ::
          {:new_event | :duplicate_delivery | :duplicate_event, t()}
  def claim(%__MODULE__{} = registry, %EventIdentity{} = identity, now_ms) when is_integer(now_ms) do
    registry = purge_expired(registry, now_ms)
    delivery_key = WebhookDelivery.delivery_key(identity)
    event_key = WebhookDelivery.event_key(identity)

    cond do
      :ets.member(registry.entries, delivery_key) ->
        {:duplicate_delivery, registry}

      :ets.member(registry.entries, event_key) ->
        registry = ensure_capacity(registry, 1)
        {registry, _order_key} = insert_key(registry, delivery_key, now_ms)
        {:duplicate_event, registry}

      true ->
        registry = ensure_capacity(registry, 2)
        {registry, _delivery_order_key} = insert_key(registry, delivery_key, now_ms)
        {registry, _event_order_key} = insert_key(registry, event_key, now_ms)
        {:new_event, registry}
    end
  end

  @spec rollback(t(), EventIdentity.t()) :: t()
  def rollback(%__MODULE__{} = registry, %EventIdentity{} = identity) do
    registry
    |> delete_key(WebhookDelivery.delivery_key(identity))
    |> delete_key(WebhookDelivery.event_key(identity))
  end

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: :ets.info(entries, :size)

  @spec close(t()) :: :ok
  def close(%__MODULE__{owner: owner, entries: entries, ordering: ordering}) when owner == self() do
    :ets.delete(entries)
    :ets.delete(ordering)
    :ok
  end

  def close(%__MODULE__{}), do: :ok

  defp insert_key(registry, key, now_ms) do
    sequence = registry.sequence + 1
    order_key = {now_ms, sequence}
    true = :ets.insert_new(registry.entries, {key, now_ms, order_key})
    true = :ets.insert_new(registry.ordering, {order_key, key})
    {%{registry | sequence: sequence}, order_key}
  end

  defp ensure_capacity(registry, needed) do
    if size(registry) + needed <= registry.max_entries do
      registry
    else
      evict_oldest(registry, needed)
    end
  end

  defp evict_oldest(registry, needed) do
    case :ets.first(registry.ordering) do
      :"$end_of_table" ->
        registry

      order_key ->
        evict_order_key(registry, order_key)
        |> ensure_capacity(needed)
    end
  end

  defp evict_order_key(registry, order_key) do
    case :ets.take(registry.ordering, order_key) do
      [{^order_key, key}] -> :ets.delete(registry.entries, key)
      _missing -> :ok
    end

    registry
  end

  defp purge_expired(registry, now_ms) do
    case :ets.first(registry.ordering) do
      :"$end_of_table" ->
        registry

      {inserted_at, _sequence} = order_key when inserted_at + registry.ttl_ms <= now_ms ->
        case :ets.take(registry.ordering, order_key) do
          [{^order_key, key}] -> :ets.delete(registry.entries, key)
          _missing -> :ok
        end

        purge_expired(registry, now_ms)

      _unexpired ->
        registry
    end
  end

  defp delete_key(registry, key) do
    case :ets.take(registry.entries, key) do
      [{^key, _inserted_at, order_key}] -> :ets.delete(registry.ordering, order_key)
      _missing -> :ok
    end

    registry
  end
end
