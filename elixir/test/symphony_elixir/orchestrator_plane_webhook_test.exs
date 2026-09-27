defmodule SymphonyElixir.OrchestratorPlaneWebhookTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity

  test "webhook status exposes fixed counters without event identities or payloads" do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    name = Module.concat(__MODULE__, "Isolated#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(name: name, task_supervisor: task_supervisor, start_quiesced: true)

    on_exit(fn ->
      safely_stop(orchestrator)
      safely_stop(task_supervisor)
    end)

    assert :ok = Orchestrator.record_plane_webhook_metric(orchestrator, :received)
    assert :ok = Orchestrator.record_plane_webhook_metric(orchestrator, :malformed)
    assert {:error, :invalid_metric} = Orchestrator.record_plane_webhook_metric(orchestrator, :body)
    assert :unavailable = Orchestrator.record_plane_webhook_metric(:missing_webhook_orchestrator, :received)
    assert {:error, :invalid_webhook_identity} = Orchestrator.accept_plane_webhook(orchestrator, :invalid)

    identity = %EventIdentity{
      version: "v2",
      workspace_id: "00000000-0000-4000-8000-000000000001",
      webhook_id: "00000000-0000-4000-8000-000000000002",
      delivery_id: "00000000-0000-4000-8000-000000000003",
      event_id: "00000000-0000-4000-8000-000000000004",
      event: "workitem.updated",
      entity_id: "00000000-0000-4000-8000-000000000005",
      entity_type: "issue",
      project_hint: "00000000-0000-4000-8000-000000000006"
    }

    assert :unavailable = Orchestrator.accept_plane_webhook(:missing_webhook_orchestrator, identity)
    assert {:error, :plane_webhook_unavailable} = Orchestrator.accept_plane_webhook(orchestrator, identity)

    assert %{
             received: 1,
             signature_rejected: 0,
             malformed: 1,
             scope_rejected: 0,
             duplicate_delivery: 0,
             duplicate_event: 0,
             scheduled: 0,
             coalesced: 0,
             reconciliation_failed: 0,
             last_accepted_at: nil,
             dedup_entry_count: 0,
             pending_count: 0,
             in_flight_count: 0,
             full_epoch_dirty?: false
           } = Orchestrator.snapshot(orchestrator, 1_000).plane_webhook
  end

  defp safely_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
