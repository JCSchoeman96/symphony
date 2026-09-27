defmodule SymphonyElixir.Plane.WebhookIngressMetrics do
  @moduledoc """
  Holds bounded, node-local counters for events recorded before webhook authentication.

  Updates use atomics directly so rejected requests do not enqueue work on the Orchestrator.
  """

  @persistent_term_key {__MODULE__, :counters}
  @signature_rejected_index 1

  @doc false
  @spec initialize() :: :ok
  def initialize do
    counters = :atomics.new(1, signed: false)
    :persistent_term.put(@persistent_term_key, counters)
    :ok
  end

  @doc false
  @spec record_signature_rejected() :: :ok
  def record_signature_rejected do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil -> :ok
      counters -> :atomics.add(counters, @signature_rejected_index, 1)
    end

    :ok
  end

  @doc false
  @spec snapshot() :: %{signature_rejected: non_neg_integer()}
  def snapshot do
    rejected =
      case :persistent_term.get(@persistent_term_key, nil) do
        nil -> 0
        counters -> :atomics.get(counters, @signature_rejected_index)
      end

    %{signature_rejected: rejected}
  end
end
