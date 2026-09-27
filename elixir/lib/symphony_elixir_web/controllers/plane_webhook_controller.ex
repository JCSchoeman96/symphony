defmodule SymphonyElixirWeb.PlaneWebhookController do
  @moduledoc "Handles the already-authenticated Plane webhook envelope."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Plane.WebhookDelivery.EventIdentity
  alias SymphonyElixir.WorkControl.ProviderProjectContract
  alias SymphonyElixirWeb.Endpoint

  @spec create(Conn.t(), map()) :: Conn.t()
  def create(%Conn{assigns: %{plane_webhook_event_identity: %EventIdentity{} = identity}} = conn, _params) do
    case Config.settings() do
      {:ok, %{tracker: %{kind: "plane"}, provider_project_contract: %ProviderProjectContract{} = contract}} ->
        admit(conn, identity, contract)

      _not_configured ->
        Conn.send_resp(conn, 503, "")
    end
  end

  def create(conn, _params), do: Conn.send_resp(conn, 400, "")

  defp admit(conn, identity, contract) do
    if identity.workspace_id != contract.workspace_id do
      record_metric(:scope_rejected)
      Conn.send_resp(conn, 403, "")
    else
      Orchestrator.accept_plane_webhook(orchestrator(), identity)
      |> respond_to_admission(conn)
    end
  end

  defp respond_to_admission({:ok, status}, conn) when status in [:scheduled, :coalesced],
    do: Conn.send_resp(conn, 202, "")

  defp respond_to_admission({:ok, status}, conn)
       when status in [:ignored, :other_project, :duplicate_delivery, :duplicate_event],
       do: Conn.send_resp(conn, 204, "")

  defp respond_to_admission({:error, :wrong_workspace}, conn) do
    record_metric(:scope_rejected)
    Conn.send_resp(conn, 403, "")
  end

  defp respond_to_admission(_failure, conn), do: Conn.send_resp(conn, 503, "")

  defp orchestrator do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:orchestrator, Orchestrator)
  end

  defp record_metric(metric) do
    _ = Orchestrator.record_plane_webhook_metric(orchestrator(), metric)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end
end
