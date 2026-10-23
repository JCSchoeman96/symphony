Code.require_file("../support/a4/transport_fixture.exs", __DIR__)

defmodule SymphonyElixir.A4TransportProofTest do
  use ExUnit.Case, async: false

  test "suppresses the first Plane response after one complete PATCH over verified TLS 1.2" do
    evidence = SymphonyElixir.A4TransportProofFixture.run!(:suppressed_tls12)

    assert {:error, _transport_error} = evidence.result
    assert evidence.origin.patch_count == 1
    assert evidence.origin.complete_request?
    assert evidence.origin.method == "PATCH"
    assert evidence.origin.path == "/api/v1/workspaces/workspace/projects/project-1/work-items/work-1/"
    assert evidence.origin.body == ~s({"state":"state-1"})
    assert evidence.helper.connect_count == 1
    assert evidence.helper.upstream_connection_count == 1
    assert evidence.helper.client_application_data_record_count == 1
    assert evidence.helper.server_application_data_observed
    refute evidence.helper.server_application_data_forwarded
    assert evidence.helper.close_reason == "RESPONSE_SUPPRESSED"
    assert evidence.finch_stopped?
    assert evidence.helper_exit_status == 0
    assert evidence.client_tls_version == :"tlsv1.2"
    refute evidence.origin.response_bytes_received_by_client?
    assert evidence.ordering.ready_response_sent_at < evidence.ordering.witness_ack_at
    assert evidence.ordering.witness_ack_at < evidence.ordering.origin_patch_at
    assert evidence.ordering.proof_finch_started_at_ack?
  end
end
