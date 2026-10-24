defmodule SymphonyElixir.WorkControl.A4HostRelayControllerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkControl.A4HostRelayController

  @ready %{
    type: "READY",
    provider_request_id: "req-1",
    listen_host: "127.0.0.1",
    bound_port: 43_210,
    python_version: "3.12.0",
    script_blob_sha256: String.duplicate("a", 64),
    environment_names: []
  }

  test "performs Stage A before start_link returns and exposes READY after Stage B" do
    parent = self()
    ready = @ready
    backend = backend(parent, stage_a: :ok, ready: {:ok, @ready}, stage_b: true)
    ref = make_ref()
    assert {:ok, controller} = A4HostRelayController.start_link(backend: backend, ref: ref)
    assert_receive {:backend, :stage_a}

    manifest_req = make_ref()
    send(controller, {:a4_manifest_request, self(), ref, manifest_req, %{provider_request_id: "req-1"}})
    assert_receive {:backend, :manifest, %{provider_request_id: "req-1"}}
    assert_receive {:a4_manifest_response, ^controller, ^ref, ^manifest_req, %{schema: 1}}

    ready_req = make_ref()
    send(controller, {:a4_ready_request, self(), ref, ready_req, %{provider_request_id: "req-1"}})
    assert_receive {:backend, :ready, %{provider_request_id: "req-1"}}
    assert_receive {:backend, :stage_b, ^ready}
    assert_receive {:a4_ready_response, ^controller, ^ref, ^ready_req, @ready}
    refute Process.whereis(SymphonyElixir.H100TransportProofFinch)
  end

  test "Stage A failure prevents controller startup" do
    Process.flag(:trap_exit, true)
    backend = backend(self(), stage_a: {:error, :deny_all_missing})

    assert {:error, {:stage_a_failed, :deny_all_missing}} =
             A4HostRelayController.start_link(backend: backend, ref: make_ref())

    assert_receive {:backend, :stage_a}
    refute_receive {:backend, :manifest, _}
  end

  test "Stage B failure withholds READY" do
    ready = @ready
    backend = backend(self(), stage_a: :ok, ready: {:ok, @ready}, stage_b: false)
    ref = make_ref()
    assert {:ok, controller} = A4HostRelayController.start_link(backend: backend, ref: ref)
    ready_req = make_ref()
    send(controller, {:a4_ready_request, self(), ref, ready_req, %{provider_request_id: "req-1"}})
    assert_receive {:backend, :ready, _}
    assert_receive {:backend, :stage_b, ^ready}
    assert_receive {:a4_ready_response, ^controller, ^ref, ^ready_req, {:error, :policy_not_verified}}
  end

  defp backend(parent, opts) do
    stage_a = Keyword.fetch!(opts, :stage_a)
    ready = Keyword.get(opts, :ready, {:error, :unavailable})
    stage_b = Keyword.get(opts, :stage_b, false)

    %{
      verify_stage_a: fn ->
        send(parent, {:backend, :stage_a})
        stage_a
      end,
      manifest: fn request ->
        send(parent, {:backend, :manifest, request})
        {:ok, %{schema: 1}}
      end,
      ready: fn request ->
        send(parent, {:backend, :ready, request})
        ready
      end,
      stage_b_verified?: fn _request, value ->
        send(parent, {:backend, :stage_b, value})
        stage_b
      end
    }
  end
end
