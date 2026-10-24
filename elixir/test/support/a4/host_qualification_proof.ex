defmodule SymphonyElixir.A4HostQualificationProof do
  @moduledoc false

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
end
