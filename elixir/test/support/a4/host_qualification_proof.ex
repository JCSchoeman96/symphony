defmodule SymphonyElixir.A4HostQualificationProof do
  @moduledoc false

  @evidence_size 5
  @dispatch_timeout_ms 5_000
  @ipc_timeout_ms 4_000

  def dispatch_timeouts, do: %{dispatch_ms: @dispatch_timeout_ms, ipc_ms: @ipc_timeout_ms}

  def new_canary_evidence, do: :atomics.new(@evidence_size, signed: false)

  def record_canary_probes(evidence, %{ipv4: ipv4, ipv6: ipv6}) do
    with true <- valid_evidence?(evidence),
         {:ok, ipv4_code} <- canary_code(ipv4),
         {:ok, ipv6_code} <- canary_code(ipv6) do
      :atomics.put(evidence, 1, ipv4_code)
      :atomics.put(evidence, 2, ipv6_code)
      :ok
    else
      _ -> {:error, :invalid_canary_evidence}
    end
  end

  def record_canary_probes(_evidence, _results), do: {:error, :invalid_canary_evidence}

  def record_finch_started(evidence, started?) when is_boolean(started?) do
    if valid_evidence?(evidence) do
      :atomics.put(evidence, 5, if(started?, do: 1, else: 2))
      :ok
    else
      {:error, :invalid_canary_evidence}
    end
  end

  def record_finch_started(_evidence, _started?), do: {:error, :invalid_canary_evidence}

  def record_canary_policy(evidence, verified?, drop_packets)
      when is_boolean(verified?) and is_integer(drop_packets) and drop_packets in 0..1_000_000 do
    if valid_evidence?(evidence) do
      :atomics.put(evidence, 3, if(verified?, do: 1, else: 2))
      :atomics.put(evidence, 4, drop_packets)
      :ok
    else
      {:error, :invalid_canary_evidence}
    end
  end

  def record_canary_policy(_evidence, _verified?, _drop_packets),
    do: {:error, :invalid_canary_evidence}

  def read_canary_evidence(evidence) do
    if valid_evidence?(evidence) do
      %{
        ipv4: canary_value(:atomics.get(evidence, 1)),
        ipv6: canary_value(:atomics.get(evidence, 2)),
        policy_verified?: :atomics.get(evidence, 3) == 1,
        drop_packets: :atomics.get(evidence, 4),
        finch_started?: :atomics.get(evidence, 5) == 1
      }
    else
      %{ipv4: :failed, ipv6: :failed, policy_verified?: false, drop_packets: 0, finch_started?: false}
    end
  end

  def validate_canary_results(%{ipv4: :blocked, ipv6: :blocked}), do: :ok

  def validate_canary_results(%{ipv4: ipv4, ipv6: ipv6})
      when ipv4 in [:blocked, :reachable, :failed] and ipv6 in [:blocked, :reachable, :failed] do
    if ipv4 == :reachable or ipv6 == :reachable,
      do: {:error, :direct_egress_not_denied},
      else: {:error, :canary_probe_failed}
  end

  def validate_canary_results(_results), do: {:error, :canary_probe_failed}

  def classify_transport({:error, _error}), do: :transport_failure
  def classify_transport(_result), do: :unexpected_success

  defp valid_evidence?(evidence) do
    :atomics.info(evidence)[:size] == @evidence_size
  rescue
    _ -> false
  end

  defp canary_code(:blocked), do: {:ok, 1}
  defp canary_code(:reachable), do: {:ok, 2}
  defp canary_code(:failed), do: {:ok, 3}
  defp canary_code(_), do: {:error, :invalid_canary_status}

  defp canary_value(0), do: :not_observed
  defp canary_value(1), do: :blocked
  defp canary_value(2), do: :reachable
  defp canary_value(_), do: :failed
end
