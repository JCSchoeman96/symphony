defmodule SymphonyElixir.A4ProofTLSTrustTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.Client

  test "proof TLS options use only the supplied qualification CA" do
    generated_ca = <<48, 3, 2, 1, 7>>
    system_cacerts_before = :public_key.cacerts_get()

    options = Client.proof_tls_options("127.0.0.1", [generated_ca])

    assert options[:verify] == :verify_peer
    assert options[:versions] == [:"tlsv1.2"]
    assert options[:cacerts] == [generated_ca]
    assert options[:server_name_indication] == ~c"127.0.0.1"
    assert :public_key.cacerts_get() == system_cacerts_before
  end

  test "proof TLS options reject an empty or malformed isolated CA bundle" do
    assert_raise ArgumentError, fn -> Client.proof_tls_options("127.0.0.1", []) end
    assert_raise ArgumentError, fn -> Client.proof_tls_options("127.0.0.1", [:not_der]) end
  end

  test "ordinary TLS options continue using the existing shared trust source" do
    options = Client.tls_options("api.plane.so")

    assert options[:verify] == :verify_peer
    assert options[:versions] == [:"tlsv1.2"]
    assert options[:cacerts] == :public_key.cacerts_get()
    assert options[:server_name_indication] == ~c"api.plane.so"
  end
end
