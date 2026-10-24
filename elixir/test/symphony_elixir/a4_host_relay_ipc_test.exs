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

    assert {:ok, %{"verified" => true, "request_id" => "req-1"}} =
             A4HostRelayIPC.call(socket_path, %{"op" => "stage_a", "request_id" => "req-1"})

    assert Task.await(server) == %{"op" => "stage_a", "request_id" => "req-1"}
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
end
