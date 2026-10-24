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
    fixture_identity = local_fixture_identity(fixture)
    on_exit(fn -> stop_local_fixture(fixture_identity) end)
    ca_der = Base.decode64!(ready["ca_der_base64"])

    assert {:ok, response} = request_fixture(ready, "127.0.0.1", ca_der)
    assert response.status == 200
    assert {:LOCAL_TLS_RESULT, "TLSv1.2"} = await_fixture_result(fixture)
    assert :public_key.cacerts_get() == shared_trust_before
  end

  test "trust fixture teardown stops the child process" do
    {fixture, _ready} = start_local_fixture()
    identity = local_fixture_identity(fixture)
    pid = identity.pid

    try do
      stop_local_fixture(identity)
      assert wait_for_fixture_exit(pid, 1_000)
    after
      terminate_fixture(identity)
    end
  end

  test "trust fixture teardown uses its captured PID after the port owner exits" do
    {fixture, _ready} = start_local_fixture()
    identity = local_fixture_identity(fixture)

    try do
      Port.close(fixture)
      stop_local_fixture(identity)
      assert wait_for_fixture_exit(identity.pid, 1_000)
    after
      terminate_fixture(identity)
    end
  end

  test "trust fixture teardown stops each concurrently running fixture" do
    {first, _first_ready} = start_local_fixture()
    {second, _second_ready} = start_local_fixture()
    first_identity = local_fixture_identity(first)
    second_identity = local_fixture_identity(second)

    try do
      stop_local_fixture(first_identity)
      stop_local_fixture(second_identity)
      assert wait_for_fixture_exit(first_identity.pid, 1_000)
      assert wait_for_fixture_exit(second_identity.pid, 1_000)
    after
      terminate_fixture(first_identity)
      terminate_fixture(second_identity)
    end
  end

  test "Finch rejects a locally trusted server when its CA is not trusted" do
    {fixture, ready} = start_local_fixture()
    fixture_identity = local_fixture_identity(fixture)
    on_exit(fn -> stop_local_fixture(fixture_identity) end)
    {untrusted_fixture, untrusted_ready} = start_local_fixture()
    untrusted_fixture_identity = local_fixture_identity(untrusted_fixture)

    try do
      untrusted_ca = Base.decode64!(untrusted_ready["ca_der_base64"])
      assert {:error, _transport_error} = request_fixture(ready, "127.0.0.1", untrusted_ca)
      assert {:LOCAL_TLS_ERROR, _stage} = await_fixture_result(fixture)
      stop_local_fixture(untrusted_fixture_identity)
      stop_local_fixture(fixture_identity)
      assert wait_for_fixture_exit(untrusted_fixture_identity.pid, 1_000)
      assert wait_for_fixture_exit(fixture_identity.pid, 1_000)
    after
      terminate_fixture(untrusted_fixture_identity)
      terminate_fixture(fixture_identity)
    end
  end

  test "Finch rejects the trusted local certificate for a wrong hostname" do
    {fixture, ready} = start_local_fixture()
    fixture_identity = local_fixture_identity(fixture)
    on_exit(fn -> stop_local_fixture(fixture_identity) end)
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
    env = System.find_executable("env") || raise "env is required for the local TLS fixture"
    fixture_script = Path.expand("../../priv/h100/local_tls_fixture.py", __DIR__)
    directory = Path.join(System.tmp_dir!(), "h100-finch-trust-#{System.unique_integer([:positive])}")
    expected_path = "/api/v1/work-items/work-1/"

    port =
      Port.open(
        {:spawn_executable, env},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:line, 16_384},
          {:args,
           [
             "-i",
             "PATH=/usr/bin:/bin",
             "LANG=C.UTF-8",
             "LC_ALL=C.UTF-8",
             "HOME=#{System.tmp_dir!()}",
             python,
             "-I",
             fixture_script,
             "--serve",
             "--directory",
             directory,
             "--expected-api-key",
             "local-qualification-only",
             "--expected-path",
             expected_path,
             "--timeout",
             "10"
           ]}
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

  defp local_fixture_identity(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        case fixture_process_start_time(pid) do
          start_time when is_integer(start_time) -> %{pid: pid, start_time: start_time}
          _ -> raise "local TLS fixture process identity is unavailable"
        end

      nil ->
        raise "local TLS fixture port closed before process identity was captured"
    end
  end

  defp fixture_process_start_time(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        fields = stat |> String.split(")", parts: 2) |> List.last() |> String.trim_leading() |> String.split()

        fields |> Enum.at(19) |> parse_fixture_start_time()

      {:error, _reason} ->
        nil
    end
  end

  defp parse_fixture_start_time(nil), do: nil

  defp parse_fixture_start_time(value) do
    case Integer.parse(value) do
      {start_time, ""} -> start_time
      _ -> nil
    end
  end

  defp stop_local_fixture(%{pid: pid, start_time: expected_start_time}) do
    case fixture_process_start_time(pid) do
      ^expected_start_time ->
        signal_fixture(pid)
        unless wait_for_fixture_exit(pid, 3_000), do: raise("local TLS fixture did not stop during test teardown")

      _ ->
        :ok
    end
  end

  defp wait_for_fixture_exit(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_fixture_exit_until(pid, deadline)
  end

  defp wait_for_fixture_exit_until(pid, deadline) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(")", parts: 2) |> List.last() |> String.trim_leading() |> String.first()
        if state in ["Z", "X"], do: true, else: wait_again(pid, deadline)

      {:error, :enoent} ->
        true

      {:error, _reason} ->
        false
    end
  end

  defp wait_again(pid, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      Process.sleep(10)
      wait_for_fixture_exit_until(pid, deadline)
    end
  end

  defp terminate_fixture(identity) do
    stop_local_fixture(identity)
  end

  defp signal_fixture(pid) do
    env = System.find_executable("env") || raise "env is required to stop the local TLS fixture"
    kill = System.find_executable("kill") || "/bin/kill"
    args = ["-i", "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "LC_ALL=C.UTF-8", kill, "-TERM", Integer.to_string(pid)]
    {_output, status} = System.cmd(env, args, stderr_to_stdout: true)
    if status not in [0, 1], do: raise("local TLS fixture could not be signaled")
  end
end
