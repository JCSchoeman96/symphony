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

  test "Finch accepts the local fixture only with its generated CA and matching hostname" do
    shared_trust_before = :public_key.cacerts_get()
    {fixture, ready} = start_local_fixture()
    on_exit(fn -> stop_local_fixture(fixture) end)
    ca_der = Base.decode64!(ready["ca_der_base64"])

    assert {:ok, response} = request_fixture(ready, "127.0.0.1", ca_der)
    assert response.status == 200
    assert {:LOCAL_TLS_RESULT, "TLSv1.2"} = await_fixture_result(fixture)
    assert :public_key.cacerts_get() == shared_trust_before
  end

  test "Finch rejects a locally trusted server when its CA is not trusted" do
    {fixture, ready} = start_local_fixture()
    on_exit(fn -> stop_local_fixture(fixture) end)
    {untrusted_fixture, untrusted_ready} = start_local_fixture()
    on_exit(fn -> stop_local_fixture(untrusted_fixture) end)

    untrusted_ca = Base.decode64!(untrusted_ready["ca_der_base64"])
    assert {:error, _transport_error} = request_fixture(ready, "127.0.0.1", untrusted_ca)
    assert {:LOCAL_TLS_ERROR, _stage} = await_fixture_result(fixture)
  end

  test "Finch rejects the trusted local certificate for a wrong hostname" do
    {fixture, ready} = start_local_fixture()
    on_exit(fn -> stop_local_fixture(fixture) end)
    ca_der = Base.decode64!(ready["ca_der_base64"])

    assert {:error, _transport_error} = request_fixture(ready, "wrong.invalid", ca_der)
    assert {:LOCAL_TLS_ERROR, _stage} = await_fixture_result(fixture)
  end

  test "ordinary TLS options continue using the existing shared trust source" do
    options = Client.tls_options("api.plane.so")

    assert options[:verify] == :verify_peer
    assert options[:versions] == [:"tlsv1.2"]
    assert options[:cacerts] == :public_key.cacerts_get()
    assert options[:server_name_indication] == ~c"api.plane.so"
  end

  defp request_fixture(ready, tls_hostname, ca_der) do
    name = String.to_atom("A4ProofTLSFinch#{System.unique_integer([:positive])}")
    tls_options = Client.proof_tls_options(tls_hostname, [ca_der])

    {:ok, finch} =
      Finch.start_link(
        name: name,
        pools: %{
          default: [
            protocols: [:http1],
            size: 1,
            count: 1,
            conn_opts: [transport_opts: tls_options]
          ]
        }
      )

    request =
      Finch.build(
        :patch,
        "https://#{ready["authority"]}/api/v1/work-items/work-1/",
        [{"x-api-key", "local-qualification-only"}],
        ~s({"state":"state-1"})
      )

    try do
      Finch.request(request, name, receive_timeout: 3_000, pool_timeout: 3_000)
    after
      Supervisor.stop(finch)
    end
  end

  defp start_local_fixture do
    python = System.find_executable("python3") || raise "python3 is required for the local TLS fixture"
    fixture_script = Path.expand("../../priv/h100/local_tls_fixture.py", __DIR__)
    directory = Path.join(System.tmp_dir!(), "h100-finch-trust-#{System.unique_integer([:positive])}")
    expected_path = "/api/v1/work-items/work-1/"

    port =
      Port.open(
        {:spawn_executable, python},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 16_384},
          {:args, ["-I", fixture_script, "--serve", "--directory", directory, "--expected-api-key", "local-qualification-only", "--expected-path", expected_path, "--timeout", "10"]}
        ]
      )

    receive do
      {^port, {:data, {:eol, line}}} ->
        ready = Jason.decode!(line)
        if ready["type"] != "LOCAL_TLS_READY", do: raise("local TLS fixture did not become ready")
        {port, ready}

      {^port, {:exit_status, status}} ->
        raise "local TLS fixture exited during startup with status #{status}"
    after
      8_000 -> raise "local TLS fixture did not become ready"
    end
  end

  defp await_fixture_result(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        result = Jason.decode!(line)

        case result["type"] do
          "LOCAL_TLS_RESULT" -> {:LOCAL_TLS_RESULT, result["tls_version"]}
          "LOCAL_TLS_ERROR" -> {:LOCAL_TLS_ERROR, result["stage"]}
          _ -> raise "local TLS fixture returned an unexpected status"
        end

      {^port, {:exit_status, status}} ->
        raise "local TLS fixture exited before reporting its result: #{status}"
    after
      8_000 -> raise "local TLS fixture did not finish"
    end
  end

  defp stop_local_fixture(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
