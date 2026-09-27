defmodule SymphonyElixir.PlaneWebhookTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.{
    ReconciliationIntent,
    WebhookDedupRegistry,
    WebhookDelivery,
    WebhookSignature
  }

  alias SymphonyElixir.WorkControl.{LifecycleAssessment, ProviderObservation}
  alias SymphonyElixir.Workflow
  alias SymphonyElixirWeb.PlaneWebhookController
  alias SymphonyElixirWeb.Plugs.PlaneWebhookIngress
  alias SymphonyElixirWeb.Router

  @secret "plane-wh_test-secret"
  @event_id "0afa042d-92a9-4326-bdca-5ff5490dbf09"
  @delivery_id "01ab9316-f978-4449-bad6-dce958be8454"
  @webhook_id "285f087b-e1e0-4f90-b9f4-0b720acfac04"
  @workspace_id "d250cd44-fa71-42c2-b2b5-3c73227288fc"
  @project_id "45b87d89-0ce0-4d6f-8903-4070f1c67f1b"
  @entity_id "088a83b9-a53f-4dda-b2bc-c860cf455997"

  test "verifies the HMAC over the exact raw body bytes" do
    body = ~s({"version":"v2","event":"workitem.updated"})
    signature = signature(body, @secret)

    assert :ok = WebhookSignature.verify(body, signature, secret: @secret)
    assert {:error, :invalid_signature} = WebhookSignature.verify(body <> " ", signature, secret: @secret)

    signed_json = Jason.encode!(payload())
    reserialized_json = Jason.encode!(Jason.decode!(signed_json), pretty: true)

    assert {:error, :invalid_signature} =
             WebhookSignature.verify(reserialized_json, signature(signed_json, @secret), secret: @secret)
  end

  test "rejects a missing signature and an unavailable host secret" do
    assert {:error, :invalid_signature} = WebhookSignature.verify("{}", nil, secret: @secret)
    assert {:error, :secret_unavailable} = WebhookSignature.verify("{}", signature("{}", @secret), secret: nil)
    assert {:error, :invalid_signature} = WebhookSignature.verify("{}", String.duplicate("z", 64), secret: @secret)
    assert {:error, :invalid_signature} = WebhookSignature.verify(:not_a_body, "signature", secret: @secret)
  end

  test "validates a v2 event and requires matching Plane headers" do
    payload = put_in(payload()["data"]["state"], "Done")
    headers = %{"x-plane-delivery" => @delivery_id, "x-plane-event" => "workitem.updated"}

    assert {:ok, identity} = WebhookDelivery.validate_envelope(payload, headers)
    assert identity.event_id == @event_id
    assert identity.delivery_id == @delivery_id
    assert identity.workspace_id == @workspace_id
    assert identity.project_hint == @project_id
    refute Map.has_key?(identity, :data)
    refute Map.has_key?(identity, :state)

    assert {:error, :delivery_header_mismatch} =
             WebhookDelivery.validate_envelope(payload, %{headers | "x-plane-delivery" => @event_id})

    assert {:error, :event_header_mismatch} =
             WebhookDelivery.validate_envelope(payload, %{headers | "x-plane-event" => "workitem.deleted"})
  end

  test "rejects v1 payloads and missing logical event identity" do
    headers = %{"x-plane-delivery" => @delivery_id, "x-plane-event" => "workitem.updated"}
    assert {:error, :unsupported_version} = WebhookDelivery.validate_envelope(%{payload() | "version" => "v1"}, headers)
    assert {:error, :missing_version} = WebhookDelivery.validate_envelope(Map.delete(payload(), "version"), headers)
    assert {:error, :malformed_envelope} = WebhookDelivery.validate_envelope([], headers)
    assert {:error, :missing_event_id} = WebhookDelivery.validate_envelope(Map.delete(payload(), "event_id"), headers)
    assert {:error, :missing_event} = WebhookDelivery.validate_envelope(Map.delete(payload(), "event"), headers)
    assert {:error, :missing_entity_type} = WebhookDelivery.validate_envelope(Map.delete(payload(), "entity_type"), headers)

    mismatched_entity = Map.put(payload(), "entity_type", "project")
    assert {:error, :entity_type_mismatch} = WebhookDelivery.validate_envelope(mismatched_entity, headers)

    project_event = %{
      payload()
      | "event" => "project.updated",
        "entity_id" => @project_id,
        "entity_type" => "project"
    }

    assert {:ok, %{project_hint: @project_id}} =
             WebhookDelivery.validate_envelope(project_event, %{headers | "x-plane-event" => "project.updated"})

    assert {:error, :invalid_data} =
             WebhookDelivery.validate_envelope(Map.put(payload(), "data", nil), headers)
  end

  test "classifies item updates, graph events, and unknown events without lifecycle meaning" do
    update = identity("workitem.updated")
    graph_change = identity("workitem.dependency.created")
    unknown = identity("workitem.comment.created")

    assert %{kind: :targeted, work_item_id: @entity_id} = WebhookDelivery.classify(update, @project_id)
    assert %{kind: :full_epoch} = WebhookDelivery.classify(graph_change, @project_id)
    assert %{kind: :ignore} = WebhookDelivery.classify(unknown, @project_id)
    assert %{kind: :other_project} = WebhookDelivery.classify(update, "another-project")
    assert %{kind: :other_project} = WebhookDelivery.classify(graph_change, "another-project")
    assert %{kind: :ignore} = WebhookDelivery.classify(update, nil)
    assert %{kind: :full_epoch} = WebhookDelivery.classify(%{update | project_hint: nil}, @project_id)
    assert %{kind: :full_epoch} = WebhookDelivery.classify(%{update | project_hint: 17}, @project_id)

    invalid_project_hint_payload = Map.put(payload(), "data", %{"project_id" => 17})

    assert {:ok, %{project_hint: nil}} =
             WebhookDelivery.validate_envelope(invalid_project_hint_payload, %{
               "x-plane-delivery" => @delivery_id,
               "x-plane-event" => "workitem.updated"
             })

    deleted_payload = %{
      payload()
      | "event" => "workitem.deleted",
        "data" => %{},
        "previous_attributes" => %{"project_id" => @project_id}
    }

    assert {:ok, deleted} =
             WebhookDelivery.validate_envelope(deleted_payload, %{
               "x-plane-delivery" => @delivery_id,
               "x-plane-event" => "workitem.deleted"
             })

    assert deleted.project_hint == @project_id
    assert %{kind: :targeted, work_item_id: @entity_id} = WebhookDelivery.classify(deleted, @project_id)
  end

  test "deduplicates both delivery attempts and logical events, retaining retry deliveries" do
    registry = WebhookDedupRegistry.new(max_entries: 10)
    first = identity("workitem.updated")

    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, first, 100)
    assert {:duplicate_delivery, registry} = WebhookDedupRegistry.claim(registry, first, 101)

    retry = %{first | delivery_id: "616d98fe-35a7-4431-a233-db40936c8339"}
    assert {:duplicate_event, registry} = WebhookDedupRegistry.claim(registry, retry, 102)
    assert WebhookDedupRegistry.size(registry) == 3

    WebhookDedupRegistry.close(registry)

    foreign_owner_registry = WebhookDedupRegistry.new()
    assert :ok = Task.async(fn -> WebhookDedupRegistry.close(foreign_owner_registry) end) |> Task.await()
    WebhookDedupRegistry.close(foreign_owner_registry)
  end

  test "expires dedup keys, evicts the oldest entries, and starts empty after registry restart" do
    registry = WebhookDedupRegistry.new(ttl_ms: 10, max_entries: 4)
    first = identity("workitem.updated")
    second = %{first | event_id: "7b3c1e2a-8f94-4b12-a781-2c5e9d4f6a03", delivery_id: "2a0d0510-9052-446e-a1c7-a704bbd68cba"}

    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, first, 100)
    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, second, 105)
    assert WebhookDedupRegistry.size(registry) == 4

    third = %{first | event_id: "8944ed18-1331-4eae-b9bb-7c40864b8abd", delivery_id: "45b87d89-0ce0-4d6f-8903-4070f1c67f1b"}
    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, third, 106)
    assert WebhookDedupRegistry.size(registry) == 4

    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, first, 111)
    assert WebhookDedupRegistry.size(registry) == 4

    restarted = WebhookDedupRegistry.new(max_entries: 4)
    assert WebhookDedupRegistry.size(restarted) == 0

    WebhookDedupRegistry.close(registry)
    WebhookDedupRegistry.close(restarted)
  end

  test "retry delivery retention stays inside the total key bound" do
    registry = WebhookDedupRegistry.new(max_entries: 2)
    first = identity("workitem.updated")
    retry = %{first | delivery_id: "616d98fe-35a7-4431-a233-db40936c8339"}

    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, first, 100)
    assert {:duplicate_event, registry} = WebhookDedupRegistry.claim(registry, retry, 101)
    assert WebhookDedupRegistry.size(registry) == 2

    WebhookDedupRegistry.close(registry)
  end

  test "rolls back a newly claimed event when scheduling admission fails" do
    registry = WebhookDedupRegistry.new()
    event = identity("workitem.updated")

    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, event, 100)
    registry = WebhookDedupRegistry.rollback(registry, event)
    assert WebhookDedupRegistry.size(registry) == 0
    assert WebhookDedupRegistry.rollback(registry, event) == registry
    assert {:new_event, registry} = WebhookDedupRegistry.claim(registry, event, 101)

    WebhookDedupRegistry.close(registry)
  end

  test "reconciliation intents model queued metadata and require complete epoch coverage" do
    event = identity("workitem.updated")

    assert {:ok, intent} =
             ReconciliationIntent.new(%{
               identity: event,
               host_generation: 7,
               work_item_id: @entity_id,
               config_fingerprint: :config,
               contract_fingerprint: :contract
             })

    refute Map.has_key?(intent, :state)
    refute ReconciliationIntent.covered_by?(intent, 6)
    assert ReconciliationIntent.covered_by?(intent, 7)
    assert {:error, :invalid_reconciliation_intent} = ReconciliationIntent.new(%{identity: event})
    assert {:error, :invalid_reconciliation_intent} = ReconciliationIntent.new(:invalid)
  end

  test "verified Plane absence is authority reducing and cannot satisfy dependencies" do
    assert {:ok, observation} =
             ProviderObservation.new_not_found(%{
               provider: :plane,
               work_item_id: @entity_id,
               workspace_id: @workspace_id,
               project_id: @project_id,
               snapshot_identity: %{source: :targeted_webhook_read}
             })

    assert observation.presence == :not_found
    assert observation.provider_state_name == nil

    assert {:error, :invalid_presence} =
             ProviderObservation.new(%{
               provider: :plane,
               work_item_id: @entity_id,
               provider_state_name: "Ready",
               presence: :not_found
             })

    assessment = LifecycleAssessment.assess(observation, :in_progress, [])
    assert LifecycleAssessment.authority_reducing?(assessment)
    assert assessment.validated_state == :in_progress
    assert assessment.reason == :provider_not_found
    refute LifecycleAssessment.dependency_satisfying?(assessment)

    assert {:error, :invalid_not_found_observation} =
             ProviderObservation.new_not_found(%{
               provider: :plane,
               work_item_id: @entity_id,
               workspace_id: @workspace_id,
               project_id: nil
             })

    assert {:error, :invalid_not_found_observation} = ProviderObservation.new_not_found(:invalid)
  end

  test "raw ingress verifies exact bytes before exposing a decoded envelope" do
    body = Jason.encode!(payload())
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body, @secret))
      |> Plug.Conn.put_req_header("x-plane-delivery", @delivery_id)
      |> Plug.Conn.put_req_header("x-plane-event", "workitem.updated")
      |> PlaneWebhookIngress.call([])

    assert conn.halted == false
    assert conn.assigns.plane_webhook_event_identity.event_id == @event_id
    assert match?(%Plug.Conn.Unfetched{}, conn.body_params)
  end

  test "raw ingress rejects invalid signatures, media types, and oversized bodies" do
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    invalid =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature("{} ", @secret))
      |> PlaneWebhookIngress.call([])

    assert invalid.status == 401

    wrong_media =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> PlaneWebhookIngress.call([])

    assert wrong_media.status == 415

    oversized =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("content-length", "1048577")
      |> PlaneWebhookIngress.call([])

    assert oversized.status == 413
  end

  test "pre-authentication failures do not call the Orchestrator" do
    {:ok, orchestrator_probe} = SymphonyElixir.PlaneWebhookOrchestratorProbe.start_link(self())
    previous_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_secret = System.get_env("PLANE_WEBHOOK_SECRET")
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, orchestrator: orchestrator_probe)
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)

    on_exit(fn ->
      if Process.alive?(orchestrator_probe), do: GenServer.stop(orchestrator_probe)
      restore_env("PLANE_WEBHOOK_SECRET", previous_secret)
      restore_application_env(SymphonyElixirWeb.Endpoint, previous_endpoint_config)
    end)

    body = Jason.encode!(payload())

    requests = [
      {router_post(body, [
         {"content-type", "application/json"},
         {"x-plane-signature", signature(body <> "tampered", @secret)}
       ]), 401},
      {router_post(body, [{"content-type", "application/json"}]), 401},
      {router_post(body, [{"content-type", "text/plain"}]), 415},
      {router_post("{}", [
         {"content-type", "application/json"},
         {"content-length", "2bytes"}
       ]), 400}
    ]

    for {conn, expected_status} <- requests do
      assert conn.status == expected_status
      refute_receive {:plane_webhook_orchestrator_call, _request}, 0
    end
  end

  test "signature rejections appear in the webhook snapshot without calling the Orchestrator" do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    name = Module.concat(__MODULE__, "IngressMetrics#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      SymphonyElixir.Orchestrator.start_link(
        name: name,
        task_supervisor: task_supervisor,
        start_quiesced: true
      )

    previous_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_secret = System.get_env("PLANE_WEBHOOK_SECRET")
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, orchestrator: orchestrator)
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)

    on_exit(fn ->
      safely_stop(orchestrator)
      safely_stop(task_supervisor)
      restore_env("PLANE_WEBHOOK_SECRET", previous_secret)
      restore_application_env(SymphonyElixirWeb.Endpoint, previous_endpoint_config)
    end)

    body = "{}"
    before = SymphonyElixir.Orchestrator.snapshot(orchestrator, 1_000).plane_webhook.signature_rejected

    rejected =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body <> "tampered", @secret))
      |> PlaneWebhookIngress.call([])

    assert rejected.status == 401
    assert SymphonyElixir.Orchestrator.snapshot(orchestrator, 1_000).plane_webhook.signature_rejected == before + 1
  end

  test "valid signature returns 503 when the host secret is unavailable" do
    {:ok, orchestrator_probe} = SymphonyElixir.PlaneWebhookOrchestratorProbe.start_link(self())
    previous_endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint)
    previous_secret = System.get_env("PLANE_WEBHOOK_SECRET")
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, orchestrator: orchestrator_probe)

    on_exit(fn ->
      if Process.alive?(orchestrator_probe), do: GenServer.stop(orchestrator_probe)
      restore_env("PLANE_WEBHOOK_SECRET", previous_secret)
      restore_application_env(SymphonyElixirWeb.Endpoint, previous_endpoint_config)
    end)

    body = Jason.encode!(payload())
    System.delete_env("PLANE_WEBHOOK_SECRET")

    conn =
      router_post(body, [
        {"content-type", "application/json"},
        {"x-plane-signature", signature(body, @secret)}
      ])

    assert conn.status == 503
    refute_receive {:plane_webhook_orchestrator_call, _request}, 0
  end

  test "raw ingress rejects chunked bodies that exceed the byte limit" do
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    oversized_body = "{" <> String.duplicate(" ", 1_065_000)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", oversized_body)
      |> Plug.Conn.delete_req_header("content-length")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> use_chunked_adapter(oversized_body)
      |> PlaneWebhookIngress.call([])

    assert conn.status == 413
  end

  test "raw ingress joins bounded chunks before signature and envelope validation" do
    body = Jason.encode!(payload())
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.delete_req_header("content-length")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body, @secret))
      |> Plug.Conn.put_req_header("x-plane-delivery", @delivery_id)
      |> Plug.Conn.put_req_header("x-plane-event", "workitem.updated")
      |> use_chunked_adapter(body)
      |> PlaneWebhookIngress.call(PlaneWebhookIngress.init([]))

    assert conn.halted == false
    assert conn.assigns.plane_webhook_event_identity.event_id == @event_id
  end

  test "raw ingress preserves byte order across multiple body chunks" do
    body = Jason.encode!(Map.put(payload(), "padding", String.duplicate("x", 40_000)))
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.delete_req_header("content-length")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body, @secret))
      |> Plug.Conn.put_req_header("x-plane-delivery", @delivery_id)
      |> Plug.Conn.put_req_header("x-plane-event", "workitem.updated")
      |> use_chunked_adapter(body)
      |> PlaneWebhookIngress.call(PlaneWebhookIngress.init([]))

    assert conn.halted == false
    assert conn.assigns.plane_webhook_event_identity.event_id == @event_id
  end

  test "raw ingress rejects invalid and ambiguous content lengths and missing signatures" do
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    invalid_length =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("content-length", "2bytes")
      |> PlaneWebhookIngress.call([])

    assert invalid_length.status == 400

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    req_headers = Enum.reject(conn.req_headers, &(elem(&1, 0) == "content-length"))
    ambiguous_length = %{conn | req_headers: req_headers ++ [{"content-length", "2"}, {"content-length", "2"}]}
    assert PlaneWebhookIngress.call(ambiguous_length, []).status == 400

    missing_signature =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> PlaneWebhookIngress.call([])

    assert missing_signature.status == 401

    missing_content_type =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> PlaneWebhookIngress.call([])

    assert missing_content_type.status == 415

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("content-length", "2")
      |> Plug.Conn.put_req_header("x-plane-signature", signature("{}", @secret))
      |> PlaneWebhookIngress.call([])

    assert conn.status == 400
  end

  test "controller rejects requests without an authenticated identity" do
    conn = Plug.Test.conn(:post, "/api/v1/webhooks/plane", "")
    assert PlaneWebhookController.create(conn, %{}).status == 400
  end

  test "controller disables webhook admission when the configured tracker is not Plane" do
    previous_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    root = Path.join(System.tmp_dir!(), "symphony-webhook-controller-#{System.unique_integer([:positive])}")
    path = Path.join(root, "WORKFLOW.md")
    File.mkdir_p!(root)
    SymphonyElixir.TestSupport.write_workflow_file!(path)
    Workflow.set_workflow_file_path(path)

    on_exit(fn ->
      case previous_path do
        path when is_binary(path) -> Workflow.set_workflow_file_path(path)
        _missing -> Workflow.clear_workflow_file_path()
      end

      File.rm_rf(root)
    end)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "")
      |> Plug.Conn.assign(:plane_webhook_event_identity, identity("workitem.updated"))

    assert PlaneWebhookController.create(conn, %{}).status == 503
  end

  test "raw ingress maps provider body-read errors to a malformed request" do
    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    failing_adapter = %{conn | adapter: {SymphonyElixir.PlaneWebhookFailingAdapter, nil}}

    assert PlaneWebhookIngress.call(failing_adapter, []).status == 400
  end

  test "a valid signature does not let malformed JSON reach envelope processing" do
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    body = "{not-json}"

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body, @secret))
      |> PlaneWebhookIngress.call([])

    assert conn.status == 400
  end

  test "raw ingress rejects a signed envelope with mismatched headers" do
    body = Jason.encode!(payload())
    System.put_env("PLANE_WEBHOOK_SECRET", @secret)
    on_exit(fn -> System.delete_env("PLANE_WEBHOOK_SECRET") end)

    conn =
      Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-plane-signature", signature(body, @secret))
      |> Plug.Conn.put_req_header("x-plane-delivery", "616d98fe-35a7-4431-a233-db40936c8339")
      |> Plug.Conn.put_req_header("x-plane-event", "workitem.updated")
      |> PlaneWebhookIngress.call([])

    assert conn.status == 400
  end

  defp payload do
    %{
      "version" => "v2",
      "delivery_id" => @delivery_id,
      "event_id" => @event_id,
      "entity_id" => @entity_id,
      "entity_type" => "issue",
      "event" => "workitem.updated",
      "webhook_id" => @webhook_id,
      "workspace_id" => @workspace_id,
      "data" => %{"project_id" => @project_id},
      "previous_attributes" => %{}
    }
  end

  defp identity(event) do
    struct!(WebhookDelivery.EventIdentity,
      version: "v2",
      workspace_id: @workspace_id,
      webhook_id: @webhook_id,
      delivery_id: @delivery_id,
      event_id: @event_id,
      event: event,
      entity_id: @entity_id,
      entity_type: "issue",
      project_hint: @project_id
    )
  end

  defp signature(body, secret) do
    :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  end

  defp router_post(body, headers) do
    conn = Plug.Test.conn(:post, "/api/v1/webhooks/plane", body)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        Plug.Conn.put_req_header(acc, name, value)
      end)

    Router.call(conn, Router.init([]))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:symphony_elixir, key, value)

  defp safely_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp use_chunked_adapter(conn, body) do
    %{conn | adapter: {SymphonyElixir.PlaneWebhookChunkedAdapter, chunk_body(body, 16_384)}}
  end

  defp chunk_body(<<>>, _size), do: []

  defp chunk_body(body, size) do
    chunk_size = min(byte_size(body), size)
    <<chunk::binary-size(chunk_size), rest::binary>> = body
    [chunk | chunk_body(rest, size)]
  end
end

defmodule SymphonyElixir.PlaneWebhookOrchestratorProbe do
  use GenServer

  def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_call(request, _from, test_pid) do
    send(test_pid, {:plane_webhook_orchestrator_call, request})
    {:reply, :ok, test_pid}
  end
end

defmodule SymphonyElixir.PlaneWebhookChunkedAdapter do
  @moduledoc false

  def read_req_body([chunk | rest], opts) do
    limit = Keyword.get(opts, :read_length, byte_size(chunk))

    if byte_size(chunk) > limit do
      <<part::binary-size(limit), remainder::binary>> = chunk
      {:more, part, [remainder | rest]}
    else
      if rest == [], do: {:ok, chunk, []}, else: {:more, chunk, rest}
    end
  end

  def read_req_body([], _opts), do: {:ok, "", []}
end

defmodule SymphonyElixir.PlaneWebhookFailingAdapter do
  @moduledoc false

  def read_req_body(_state, _opts), do: {:error, :injected_body_read_failure}
end
