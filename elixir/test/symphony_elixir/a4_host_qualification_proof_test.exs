Code.require_file("../support/a4/host_qualification_proof.ex", __DIR__)

defmodule SymphonyElixir.A4HostQualificationProofTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.A4HostQualificationProof

  test "canary verification requires both live IPv4 and IPv6 listeners to be blocked" do
    assert :ok = A4HostQualificationProof.validate_canary_results(%{ipv4: :blocked, ipv6: :blocked})

    assert {:error, :direct_egress_not_denied} =
             A4HostQualificationProof.validate_canary_results(%{ipv4: :reachable, ipv6: :blocked})

    assert {:error, :canary_probe_failed} =
             A4HostQualificationProof.validate_canary_results(%{ipv4: :blocked, ipv6: :failed})
  end

  test "transport classification does not stringify error terms" do
    assert :transport_failure = A4HostQualificationProof.classify_transport({:error, :some_transport_error})
    assert :unexpected_success = A4HostQualificationProof.classify_transport(:ok)
  end

  test "canary evidence written by the isolated witness process is visible to its parent" do
    evidence = A4HostQualificationProof.new_canary_evidence()

    writer =
      spawn(fn ->
        :ok = A4HostQualificationProof.record_canary_probes(evidence, %{ipv4: :blocked, ipv6: :failed})
        :ok = A4HostQualificationProof.record_canary_policy(evidence, false, 0)
        :ok = A4HostQualificationProof.record_finch_started(evidence, true)
      end)

    monitor = Process.monitor(writer)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}

    assert %{ipv4: :blocked, ipv6: :failed, policy_verified?: false, drop_packets: 0, finch_started?: true} =
             A4HostQualificationProof.read_canary_evidence(evidence)
  end
end
