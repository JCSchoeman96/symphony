defmodule SymphonyElixirWeb.Plugs.PlaneWebhookIngress do
  @moduledoc "Verifies the bounded raw Plane webhook body before JSON decoding."

  @behaviour Plug

  alias Plug.Conn
  alias SymphonyElixir.Plane.{WebhookDelivery, WebhookSignature}
  alias SymphonyElixirWeb.Endpoint

  @max_body_bytes 1_048_576
  @body_read_length 16_384
  @body_read_timeout_ms 15_000
  @ingress_telemetry_event [:symphony_elixir, :plane_webhook, :ingress]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{} = conn, _opts) do
    record_ingress_telemetry(:received, :none)

    case process_request(conn) do
      {:ok, conn} ->
        conn

      {:error, status, conn, metric} ->
        record_ingress_telemetry(:rejected, metric)
        conn |> Conn.resp(status, "") |> Conn.halt()
    end
  end

  defp process_request(conn) do
    case json_content_type(conn) do
      :ok -> process_declared_body(conn)
      {:error, reason} -> ingress_error(reason, conn)
    end
  end

  defp process_declared_body(conn) do
    case declared_body_size(conn) do
      :ok ->
        case read_raw_body(conn) do
          {:ok, raw_body, body_conn} -> process_signed_body(raw_body, body_conn)
          {:error, reason, body_conn} -> ingress_error(reason, body_conn)
        end

      {:error, reason} ->
        ingress_error(reason, conn)
    end
  end

  defp process_signed_body(raw_body, conn) do
    case verify_signature(raw_body, conn) do
      :ok ->
        record_authenticated_metric(:received)

        with {:ok, payload} <- decode_payload(raw_body),
             {:ok, identity} <- WebhookDelivery.validate_envelope(payload, signature_headers(conn)) do
          {:ok, Conn.assign(conn, :plane_webhook_event_identity, identity)}
        else
          {:error, reason} ->
            record_authenticated_metric(:malformed)
            ingress_error(reason, conn)
        end

      {:error, reason} ->
        ingress_error(reason, conn)
    end
  end

  defp ingress_error(:unsupported_media_type, conn), do: {:error, 415, conn, :unsupported_media_type}
  defp ingress_error(:body_too_large, conn), do: {:error, 413, conn, :body_too_large}

  defp ingress_error(reason, conn) when reason in [:invalid_content_length, :body_read_failed, :invalid_json],
    do: {:error, 400, conn, :malformed}

  defp ingress_error(:secret_unavailable, conn), do: {:error, 503, conn, :verification_unavailable}
  defp ingress_error(:invalid_signature, conn), do: {:error, 401, conn, :signature_rejected}

  defp ingress_error(_reason, conn), do: {:error, 400, conn, :malformed}

  defp json_content_type(conn) do
    case Conn.get_req_header(conn, "content-type") do
      [value] ->
        [media_type | _parameters] = String.split(value, ";", parts: 2)
        if String.downcase(String.trim(media_type)) == "application/json", do: :ok, else: {:error, :unsupported_media_type}

      _missing_or_ambiguous ->
        {:error, :unsupported_media_type}
    end
  end

  defp declared_body_size(conn) do
    case Conn.get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 and size <= @max_body_bytes -> :ok
          {size, ""} when size > @max_body_bytes -> {:error, :body_too_large}
          _invalid -> {:error, :invalid_content_length}
        end

      _ambiguous ->
        {:error, :invalid_content_length}
    end
  end

  defp read_raw_body(conn), do: read_raw_body(conn, [], 0)

  defp read_raw_body(conn, chunks, total) do
    read_length = min(@body_read_length, @max_body_bytes + 1 - total)

    case Conn.read_body(conn,
           length: @max_body_bytes + 1,
           read_length: read_length,
           read_timeout: @body_read_timeout_ms
         ) do
      {:ok, chunk, next_conn} ->
        case append_body_chunk(next_conn, chunk, chunks, total, :done) do
          {:ok, raw_body, body_conn} -> {:ok, raw_body, body_conn}
          {:error, reason} -> {:error, reason, next_conn}
        end

      {:more, chunk, next_conn} ->
        case append_body_chunk(next_conn, chunk, chunks, total, :more) do
          {:ok, next_chunks, next_total} -> read_raw_body(next_conn, next_chunks, next_total)
          {:error, reason} -> {:error, reason, next_conn}
        end

      {:error, _reason} ->
        {:error, :body_read_failed, conn}
    end
  rescue
    _error -> {:error, :body_read_failed, conn}
  catch
    _kind, _reason -> {:error, :body_read_failed, conn}
  end

  defp append_body_chunk(conn, chunk, chunks, total, completion) do
    next_total = total + byte_size(chunk)

    cond do
      next_total > @max_body_bytes ->
        {:error, :body_too_large}

      completion == :done ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}

      true ->
        {:ok, [chunk | chunks], next_total}
    end
  end

  defp verify_signature(raw_body, conn) do
    signature = single_header(conn, "x-plane-signature")
    WebhookSignature.verify(raw_body, signature)
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _invalid -> {:error, :invalid_json}
    end
  end

  defp signature_headers(conn) do
    %{
      "x-plane-delivery" => single_header(conn, "x-plane-delivery"),
      "x-plane-event" => single_header(conn, "x-plane-event")
    }
  end

  defp single_header(conn, name) do
    case Conn.get_req_header(conn, name) do
      [value] -> value
      _missing_or_ambiguous -> nil
    end
  end

  defp record_authenticated_metric(metric) do
    if metric in [:received, :malformed] do
      server =
        :symphony_elixir
        |> Application.get_env(Endpoint, [])
        |> Keyword.get(:orchestrator, SymphonyElixir.Orchestrator)

      _ = SymphonyElixir.Orchestrator.record_plane_webhook_metric(server, metric)
    end

    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp record_ingress_telemetry(event, reason) do
    :telemetry.execute(@ingress_telemetry_event, %{count: 1}, %{event: event, reason: reason})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
