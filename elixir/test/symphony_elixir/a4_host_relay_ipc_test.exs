defmodule SymphonyElixir.WorkControl.A4HostRelayIPCTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.A4HostRelayIPC

  test "exchanges bounded JSON over a local Unix socket" do
    socket_path = Path.join(System.tmp_dir!(), "h100-ipc-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(socket_path)}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(socket_path)
    end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        request = Jason.decode!(line)
        :ok = :gen_tcp.send(socket, Jason.encode!(%{"verified" => true, "request_id" => request["request_id"]}) <> "\n")
        :gen_tcp.close(socket)
        request
      end)

    message = %{"op" => "stage_a", "request_id" => "req-1", "items" => ["safe", true, nil]}

    assert {:ok, %{"verified" => true, "request_id" => "req-1"}} =
             A4HostRelayIPC.call(socket_path, message)

    assert Task.await(server) == message
  end

  test "rejects oversized requests before connecting" do
    assert {:error, :message_too_large} =
             A4HostRelayIPC.call("/tmp/not-created.sock", %{"data" => String.duplicate("x", 16_384)})
  end

  test "permits the frozen nonsecret operator authorization reference in manifest IPC" do
    socket_path = Path.join(System.tmp_dir!(), "h100-ipc-manifest-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(socket_path)}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(socket_path)
    end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
        request = Jason.decode!(line)

        response = %{"manifest" => %{"operator_authorization_ref" => "local-test-only"}}
        :ok = :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
        :gen_tcp.close(socket)
        request
      end)

    message = %{
      "op" => "manifest",
      "request" => %{"operator_authorization_ref" => "local-test-only"}
    }

    assert {:ok, %{"manifest" => %{"operator_authorization_ref" => "local-test-only"}}} =
             A4HostRelayIPC.call(socket_path, message)

    assert Task.await(server) == message
  end

  test "still rejects authorization headers in local IPC" do
    assert {:error, :unsafe_controller_message} =
             A4HostRelayIPC.call("/tmp/not-created.sock", %{"authorization_header" => "fixture-sentinel"})
  end

  test "rejects malformed IPC inputs before connecting" do
    assert {:error, :invalid_controller_ipc_request} = A4HostRelayIPC.call(:not_a_path, %{}, 100)
    assert {:error, :invalid_controller_ipc_request} = A4HostRelayIPC.call("/tmp/not-created.sock", %{}, 30_001)

    assert {:error, :unsafe_controller_message} =
             A4HostRelayIPC.call("/tmp/not-created.sock", %{not_a_string_key: "value"})

    assert {:error, :unsafe_controller_message} =
             A4HostRelayIPC.call("/tmp/not-created.sock", %{"nested" => ["safe", {:unsupported, :tuple}]})

    assert {:error, :invalid_controller_ipc_message} =
             A4HostRelayIPC.call("/tmp/not-created.sock", %{"invalid_utf8" => <<255>>})
  end

  test "reports missing sockets and fails closed on malformed or oversized responses" do
    missing_socket = Path.join(System.tmp_dir!(), "h100-missing-#{System.unique_integer([:positive])}.sock")
    assert {:error, :controller_socket_unavailable} = A4HostRelayIPC.call(missing_socket, %{"op" => "probe"}, 100)

    assert {:error, :malformed_controller_response} = ipc_response("not-json\n")
    assert {:error, :unsafe_controller_response} = ipc_response(~S({"token":"fixture-sentinel"}) <> "\n")
    assert {:error, :message_too_large} = ipc_response("\n")
    assert {:error, :controller_ipc_failed} = ipc_response(:close)
  end

  defp ipc_response(response) do
    socket_path = Path.join(System.tmp_dir!(), "h100-ipc-response-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, String.to_charlist(socket_path)}])

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        if response != :close, do: :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end)

    result = A4HostRelayIPC.call(socket_path, %{"op" => "probe"}, 1_000)
    Task.await(server)
    :gen_tcp.close(listener)
    File.rm(socket_path)
    result
  end
end
