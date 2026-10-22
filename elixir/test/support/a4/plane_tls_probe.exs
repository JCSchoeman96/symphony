# Run with a cleared environment. This opens and closes TLS only; it sends no HTTP request.

alias SymphonyElixir.Plane.Client

host = "api.plane.so"

if System.get_env("PLANE_API_KEY") || System.get_env("PLANE_WEBHOOK_SECRET") do
  raise "Plane credentials are present in the probe environment"
end

connect_result =
  Mint.HTTP.connect(:https, host, 443,
    protocols: [:http1],
    transport_opts: Client.tls_options(host)
  )

case connect_result do
  {:ok, connection} ->
    try do
      socket = Mint.HTTP.get_socket(connection)
      {:ok, info} = :ssl.connection_information(socket, [:protocol])
      tls_version = info[:protocol]
      {:ok, _closed_connection} = Mint.HTTP.close(connection)

      record = %{
        result: "PASS",
        peer: "api.plane.so:443",
        configured_tls_versions: ["tlsv1.2"],
        negotiated_tls_version: Atom.to_string(tls_version),
        verification: "verify_peer",
        http_request_sent: "NO",
        plane_credential_loaded: "NO",
        erlang_otp: List.to_string(:erlang.system_info(:otp_release)),
        erts: :erlang.system_info(:version) |> List.to_string(),
        elixir: System.version(),
        req: Application.spec(:req, :vsn) |> to_string(),
        finch: Application.spec(:finch, :vsn) |> to_string(),
        mint: Application.spec(:mint, :vsn) |> to_string(),
        nimble_pool: Application.spec(:nimble_pool, :vsn) |> to_string()
      }

      IO.puts(Jason.encode!(record))
    rescue
      error ->
        _ = Mint.HTTP.close(connection)
        reraise error, __STACKTRACE__
    end

  {:error, reason} ->
    raise "verified TLS probe failed: #{inspect(reason)}"
end
