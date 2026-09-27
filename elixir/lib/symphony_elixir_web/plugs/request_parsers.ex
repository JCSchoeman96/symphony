defmodule SymphonyElixirWeb.Plugs.RequestParsers do
  @moduledoc """
  Parses ordinary request bodies before method override while leaving Plane webhook
  POST bodies unread for raw-signature verification in the router.
  """

  @behaviour Plug

  alias Plug.Conn

  @plane_webhook_path "/api/v1/webhooks/plane"
  @parsers Plug.Parsers.init(
             parsers: [:urlencoded, :multipart, :json],
             pass: ["*/*"],
             json_decoder: Jason
           )
  @method_override Plug.MethodOverride.init([])

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{} = conn, _opts) do
    if raw_plane_webhook_post?(conn) do
      conn
    else
      conn
      |> Plug.Parsers.call(@parsers)
      |> Plug.MethodOverride.call(@method_override)
    end
  end

  defp raw_plane_webhook_post?(%Conn{method: "POST", request_path: request_path}) do
    request_path
    |> String.split("/", trim: true)
    |> Enum.map(&decode_path_segment/1)
    |> Kernel.==(@plane_webhook_path |> String.split("/", trim: true))
  end

  defp raw_plane_webhook_post?(_conn), do: false

  defp decode_path_segment(segment), do: URI.decode(segment)
end
