defmodule SymphonyElixir.A4QualificationTransportGuardTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.WorkControl.ProviderMutationEnvelope

  test "rejects a shadowed local request callback before selecting a transport" do
    parent = self()

    options = [
      request_fun: nil,
      provider_mutation_envelope: envelope(),
      dispatch_witness_required?: true,
      dispatch_witness_sink: fn witness -> {:ok, witness.provider_request_id} end,
      request_fun: fn _request ->
        send(parent, :fixture_callback_called)
        {:ok, %{status: 204}}
      end
    ]

    assert Keyword.get(options, :request_fun) == nil
    assert length(Keyword.get_values(options, :request_fun)) == 2

    assert {:error, :qualification_transport_ambiguous} =
             Client.qualification_transport_guard(client_config("https://api.plane.so"), options)

    assert {:error, :qualification_transport_ambiguous} =
             Client.update_work_item_state(client_config("http://127.0.0.1:1"), "work-1", "state-1", options)

    refute_received :fixture_callback_called
  end

  test "rejects an implicit Plane read transport during local qualification" do
    assert {:error, :qualification_live_plane_http_forbidden} =
             Client.qualification_transport_guard(client_config("https://api.plane.so"), [])
  end

  test "rejects a nil Plane mutation transport during local qualification" do
    assert {:error, :qualification_live_plane_http_forbidden} =
             Client.qualification_transport_guard(client_config("https://api.plane.so"), request_fun: nil)
  end

  test "allows one explicit local request transport for a Plane URL" do
    callback = fn _request -> {:ok, %{status: 204}} end

    assert :ok =
             Client.qualification_transport_guard(client_config("https://api.plane.so"), request_fun: callback)
  end

  test "stops read and mutation HTTP before a stubbed Req adapter" do
    parent = self()
    defaults = Req.default_options()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:unexpected_req, request.method})
        response = if request.method == :patch, do: Req.Response.new(status: 204), else: Req.Response.new(status: 200, body: "{}")
        {request, response}
      end
    )

    on_exit(fn -> Req.default_options(defaults) end)

    assert {:error, :qualification_live_plane_http_forbidden} =
             Client.get_project(client_config("https://api.plane.so"))

    assert {:error, :qualification_live_plane_http_forbidden} =
             Client.update_work_item_state(client_config("https://api.plane.so"), "work-1", "state-1")

    refute_received {:unexpected_req, _method}
  end

  test "allows the explicit Req.Test plug without opening a provider connection" do
    parent = self()
    defaults = Req.default_options()
    stub = {:a4_qualification_local, System.unique_integer([:positive])}

    :ok = Req.Test.set_req_test_to_shared()

    :ok =
      Req.Test.stub(stub, fn conn ->
        send(parent, {:local_req_test, conn.request_path})
        Req.Test.json(conn, %{"id" => "project"})
      end)

    Req.default_options(Keyword.put(defaults, :plug, {Req.Test, stub}))

    on_exit(fn ->
      Req.default_options(defaults)
      Req.Test.set_req_test_to_private()
    end)

    assert {:ok, %{"id" => "project"}} = Client.get_project(client_config("https://api.plane.so"))
    assert_received {:local_req_test, "/api/v1/workspaces/workspace/projects/project/"}
  end

  defp client_config(base_url) do
    %{
      base_url: base_url,
      workspace_slug: "workspace",
      workspace_id: "workspace-id",
      project_id: "project",
      api_key: "local-fixture"
    }
  end

  defp envelope do
    %ProviderMutationEnvelope{
      provider_request_id: "preq_00000000-0000-4000-8000-00000000a401",
      transition_attempt_id: "attempt-qualification-guard",
      work_item_id: "work-1",
      provider: :plane,
      workspace_id: "workspace-id",
      project_id: "project",
      requested_from: :ready,
      requested_to: :in_progress,
      target_provider_state_id: "state-1",
      target_provider_state_group: :started,
      provider_contract_fingerprint: "fixture-contract",
      submitted_at: DateTime.utc_now()
    }
  end
end
