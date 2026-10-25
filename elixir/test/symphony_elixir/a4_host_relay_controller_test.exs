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

  test "rejects non-ok and raising Stage A backends" do
    Process.flag(:trap_exit, true)

    assert {:error, :stage_a_failed} =
             A4HostRelayController.start_link(backend: backend(self(), stage_a: :unexpected), ref: make_ref())

    assert {:error, :stage_a_failed} =
             A4HostRelayController.start_link(
               backend: %{verify_stage_a: fn -> raise "fixture backend failure" end},
               ref: make_ref()
             )
  end

  test "fails closed on malformed manifest and READY backend responses" do
    parent = self()
    ref = make_ref()

    manifest_backend =
      backend(parent, stage_a: :ok)
      |> Map.put(:manifest, fn _request -> {:ok, %{value: String.duplicate("x", 17_000)}} end)

    assert {:ok, manifest_controller} =
             A4HostRelayController.start_link(backend: manifest_backend, ref: ref)

    manifest_request_id = make_ref()

    send(
      manifest_controller,
      {:a4_manifest_request, self(), ref, manifest_request_id, %{provider_request_id: "req-1"}}
    )

    assert_controller_response(
      :a4_manifest_response,
      manifest_controller,
      ref,
      manifest_request_id,
      :invalid_manifest
    )

    unavailable_manifest_backend =
      backend(parent, stage_a: :ok)
      |> Map.delete(:manifest)

    assert {:ok, unavailable_manifest_controller} =
             A4HostRelayController.start_link(backend: unavailable_manifest_backend, ref: ref)

    unavailable_manifest_request_id = make_ref()

    send(
      unavailable_manifest_controller,
      {:a4_manifest_request, self(), ref, unavailable_manifest_request_id, %{provider_request_id: "req-1"}}
    )

    assert_controller_response(
      :a4_manifest_response,
      unavailable_manifest_controller,
      ref,
      unavailable_manifest_request_id,
      :invalid_manifest
    )

    ready_backend =
      backend(parent, stage_a: :ok)
      |> Map.put(:ready, fn _request -> {:error, :not_ready} end)

    assert {:ok, ready_controller} = A4HostRelayController.start_link(backend: ready_backend, ref: ref)
    ready_request_id = make_ref()

    send(
      ready_controller,
      {:a4_ready_request, self(), ref, ready_request_id, %{provider_request_id: "req-1"}}
    )

    assert_receive {:a4_ready_response, ^ready_controller, ^ref, ^ready_request_id, {:error, :policy_not_verified}}

    raising_ready_backend =
      backend(parent, stage_a: :ok)
      |> Map.put(:ready, fn _request -> raise "fixture READY failure" end)

    assert {:ok, raising_ready_controller} =
             A4HostRelayController.start_link(backend: raising_ready_backend, ref: ref)

    raising_ready_request_id = make_ref()

    send(
      raising_ready_controller,
      {:a4_ready_request, self(), ref, raising_ready_request_id, %{provider_request_id: "req-1"}}
    )

    assert_controller_response(
      :a4_ready_response,
      raising_ready_controller,
      ref,
      raising_ready_request_id,
      :controller_failed
    )
  end

  test "contains callback exceptions and ignores messages outside the A4 protocol" do
    parent = self()
    ref = make_ref()

    manifest_backend =
      backend(parent, stage_a: :ok)
      |> Map.put(:manifest, fn _request -> raise "fixture manifest failure" end)

    assert {:ok, manifest_controller} =
             A4HostRelayController.start_link(backend: manifest_backend, ref: ref)

    manifest_request_id = make_ref()

    send(
      manifest_controller,
      {:a4_manifest_request, self(), ref, manifest_request_id, %{provider_request_id: "req-1"}}
    )

    assert_controller_response(
      :a4_manifest_response,
      manifest_controller,
      ref,
      manifest_request_id,
      :controller_failed
    )

    ready_backend =
      backend(parent, stage_a: :ok, ready: {:ok, @ready})
      |> Map.put(:stage_b_verified?, fn _request, _ready -> raise "fixture verifier failure" end)

    assert {:ok, ready_controller} = A4HostRelayController.start_link(backend: ready_backend, ref: ref)
    ready_request_id = make_ref()
    send(ready_controller, :unrelated_message)

    send(
      ready_controller,
      {:a4_ready_request, self(), ref, ready_request_id, %{provider_request_id: "req-1"}}
    )

    assert_receive {:a4_ready_response, ^ready_controller, ^ref, ^ready_request_id, {:error, :policy_not_verified}}
    assert Process.alive?(ready_controller)
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

  defp assert_controller_response(type, controller, ref, request_id, error) do
    assert_receive {^type, ^controller, ^ref, ^request_id, response}
    assert response == {:error, error}
  end
end
