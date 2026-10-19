defmodule SymphonyElixir.PlaneClientReqPolicyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.{Client, ReadScheduler}
  alias SymphonyElixir.WorkControl.ProviderMutationEnvelope

  @config %{
    base_url: "https://api.plane.so",
    workspace_slug: "workspace-1",
    workspace_id: "workspace-id-1",
    project_id: "project-1",
    api_key: "secret"
  }

  setup do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    :ok
  end

  test "uses an explicit raw, bounded and non-redirecting Req policy" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})

        response =
          Req.Response.new(
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: ~s({"id":"project-1"})
          )

        {request, response}
      end
    )

    assert {:ok, %{"id" => "project-1"}} = Client.get_project(@config)
    assert_receive {:request, request}
    assert request.method == :get
    assert request.options[:compressed] == false
    assert request.options[:raw] == true
    assert request.options[:retry] == false
    assert request.options[:redirect] == false
    assert is_function(request.into, 2)
  end

  test "retries a transient provider failure once with Req retries disabled" do
    parent = self()
    {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)

    request_fun = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 503, headers: %{}, body: %{}}}
    end

    assert {:error, :provider_unavailable} =
             Client.get_project(@config, request_fun: request_fun, scheduler: scheduler)

    assert_receive {:request, _request}
    assert_receive {:request, _request}
    refute_receive {:request, _request}
  end

  test "does not retry a raw Req failure when the shared scheduler is bypassed" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})
        {request, Req.Response.new(status: 503, body: "{}")}
      end
    )

    assert {:error, :provider_unavailable} = Client.get_project(@config, scheduler: nil)
    assert_receive {:request, request}
    assert request.options[:retry] == false
    refute_receive {:request, _request}
  end

  test "does not follow provider redirects" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})

        response =
          Req.Response.new(
            status: 302,
            headers: [{"location", "https://attacker.invalid"}],
            body: "{}"
          )

        {request, response}
      end
    )

    assert {:error, :provider_malformed} = Client.get_project(@config)
    assert_receive {:request, request}
    refute_receive {:request, _request}
    assert request.options[:redirect] == false
  end

  test "retains the bounded response accumulator with the real Req adapter" do
    Req.default_options(
      adapter: fn request ->
        response = Req.Response.new(status: 200, body: String.duplicate("x", 4_000_001))
        {request, response}
      end
    )

    assert {:error, :provider_response_too_large} = Client.get_project(@config)
  end

  test "required witness mode pins Finch over a global Req adapter" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, :global_req_adapter_called)
        {request, Req.Response.new(status: 204, body: "")}
      end
    )

    assert_witnessed_mutation_uses_local_finch(parent)
    refute_received :global_req_adapter_called
  end

  test "required witness mode disables a global Req plug" do
    parent = self()

    Req.default_options(
      plug: fn conn ->
        send(parent, :global_req_plug_called)
        Plug.Conn.send_resp(conn, 204, "")
      end,
      params: [unbound: "true"]
    )

    assert_witnessed_mutation_uses_local_finch(parent)
    refute_received :global_req_plug_called
  end

  defp assert_witnessed_mutation_uses_local_finch(parent) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    on_exit(fn -> :gen_tcp.close(listener) end)

    spawn(fn ->
      case :gen_tcp.accept(listener, 5_000) do
        {:ok, socket} ->
          result = :gen_tcp.recv(socket, 0, 5_000)
          send(parent, {:local_finch_request, result})
          :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          :gen_tcp.close(socket)

        {:error, reason} ->
          send(parent, {:local_finch_error, reason})
      end
    end)

    request_id = "preq_00000000-0000-4000-8000-000000000021"

    sink = fn witness ->
      send(parent, {:witness_acknowledged, witness.provider_request_id})
      {:ok, witness.provider_request_id}
    end

    assert :ok =
             Client.update_work_item_state(%{@config | base_url: "http://127.0.0.1:#{port}"}, "item-1", "state-done",
               request_fun: nil,
               provider_mutation_envelope: mutation_envelope(request_id),
               dispatch_witness_required?: true,
               dispatch_witness_sink: sink
             )

    assert_receive {:witness_acknowledged, ^request_id}
    assert_receive {:local_finch_request, {:ok, request}}

    assert String.starts_with?(
             request,
             "PATCH /api/v1/workspaces/workspace-1/projects/project-1/work-items/item-1/ HTTP/1.1"
           )
  end

  defp mutation_envelope(request_id) do
    %ProviderMutationEnvelope{
      provider_request_id: request_id,
      transition_attempt_id: "transition-1",
      work_item_id: "item-1",
      provider: :plane,
      workspace_id: "workspace-id-1",
      project_id: "project-1",
      requested_from: :merging,
      requested_to: :done,
      target_provider_state_id: "state-done",
      target_provider_state_group: :completed,
      provider_contract_fingerprint: "sha256:contract",
      submitted_at: ~U[2026-10-19 09:00:00Z]
    }
  end
end
