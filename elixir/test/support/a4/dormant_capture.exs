defmodule SymphonyElixir.A4DormantCapture do
  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.WorkControl.ProviderMutationEnvelope

  @proof_finch_name SymphonyElixir.H100TransportProofFinch
  @provider_request_id "preq_00000000-0000-4000-8000-00000000a400"
  @work_item_id "work-1"
  @workspace_id "workspace-id"
  @project_id "project"
  @target_state_id "state-1"

  def run! do
    cases = [
      witnessed_case("accepted", 204),
      witnessed_case("provider_error", 422),
      request_fun_timeout_case(),
      witness_rejection_case()
    ]

    validate_capture!(cases)

    %{
      manifest_present: false,
      cases: cases
    }
  end

  defp witnessed_case(name, status) do
    parent = self()
    {listener, port} = listener!()
    ack_table = :ets.new(:a4_dormant_witness_ack, [:set, :public])
    server = spawn(fn -> serve_witnessed_request(listener, port, parent, ack_table, status) end)
    config = client_config("http://127.0.0.1:#{port}")
    envelope = envelope()

    sink = fn witness ->
      :ets.insert(ack_table, {:ack, witness.provider_request_id})
      {:ok, witness.provider_request_id}
    end

    try do
      result =
        Client.update_work_item_state(config, @work_item_id, @target_state_id,
          request_fun: nil,
          provider_mutation_envelope: envelope,
          dispatch_witness_required?: true,
          dispatch_witness_sink: sink
        )

      request_evidence = receive_witnessed_request(result, server)
      send(server, {:inspect_witnessed_server, parent})
      transport_count = receive_witnessed_server_count()
      common_case(name, result, envelope, Map.put(request_evidence, :transport_count, transport_count))
    after
      :ets.delete(ack_table)
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end
  end

  defp request_fun_timeout_case do
    parent = self()
    {listener, port} = listener!()
    ack_table = :ets.new(:a4_dormant_timeout_witness_ack, [:set, :public])
    server = spawn(fn -> serve_witnessed_request(listener, port, parent, ack_table, :timeout) end)
    config = client_config("http://127.0.0.1:#{port}")
    envelope = envelope()

    sink = fn witness ->
      :ets.insert(ack_table, {:ack, witness.provider_request_id})
      {:ok, witness.provider_request_id}
    end

    try do
      result =
        Client.update_work_item_state(config, @work_item_id, @target_state_id,
          request_fun: nil,
          provider_mutation_envelope: envelope,
          dispatch_witness_required?: true,
          dispatch_witness_sink: sink
        )

      request_evidence = receive_witnessed_request(result, server)
      send(server, {:inspect_witnessed_server, parent})
      transport_count = receive_witnessed_server_count()
      common_case("timeout", result, envelope, Map.put(request_evidence, :transport_count, transport_count))
    after
      :ets.delete(ack_table)
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end
  end

  defp witness_rejection_case do
    {listener, port} = listener!()
    config = client_config("http://127.0.0.1:#{port}")
    envelope = envelope()
    sink = fn _witness -> {:error, :sink_rejected} end

    result =
      Client.update_work_item_state(config, @work_item_id, @target_state_id,
        request_fun: nil,
        provider_mutation_envelope: envelope,
        dispatch_witness_required?: true,
        dispatch_witness_sink: sink
      )

    try do
      transport_count =
        case :gen_tcp.accept(listener, 100) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            1

          {:error, :timeout} ->
            0
        end

      common_case("witness_rejection", result, envelope, %{
        request: nil,
        witness_ack_before_transport: false,
        transport_count: transport_count
      })
    after
      :gen_tcp.close(listener)
    end
  end

  defp common_case(name, result, envelope, evidence) do
    request = evidence.request

    %{
      name: name,
      result: result_record(result),
      method: request && request.method,
      url: request && request.url,
      headers: request && request.headers,
      encoded_body: request && request.encoded_body,
      provider_request_id: envelope.provider_request_id,
      witness_ack_before_transport: evidence.witness_ack_before_transport,
      transport_count: evidence.transport_count,
      request_id_in_origin: request && request.request_id_in_origin,
      proof_finch_started: not is_nil(Process.whereis(@proof_finch_name)),
      proof_helper_started: false
    }
  end

  defp serve_witnessed_request(listener, port, parent, ack_table, status) do
    {:ok, socket} = :gen_tcp.accept(listener)
    raw_request = receive_http_request(socket, <<>>)
    acked? = :ets.lookup(ack_table, :ack) == [{:ack, @provider_request_id}]
    send(parent, {:first_witnessed_request, normalize_wire_request(raw_request, port), acked?})

    if status == :timeout do
      await_witnessed_server_inspection(listener, socket, parent, true)
    else
      :ok = :gen_tcp.send(socket, response_bytes(status))
      :ok = :gen_tcp.close(socket)
      await_witnessed_server_inspection(listener, nil, parent, false)
    end
  end

  defp await_witnessed_server_inspection(listener, socket, parent, close_socket?) do
    receive do
      {:inspect_witnessed_server, ^parent} ->
        if close_socket?, do: :gen_tcp.close(socket)
        extra_connections = accept_extra_connections(listener)
        send(parent, {:witnessed_server_count, 1 + extra_connections})
    after
      20_000 ->
        if close_socket?, do: :gen_tcp.close(socket)
        send(parent, {:witnessed_server_count, 1})
    end
  end

  defp receive_witnessed_request(result, server) do
    receive do
      {:first_witnessed_request, request, acked?} ->
        %{request: request, witness_ack_before_transport: acked?}
    after
      2_000 -> raise "local Plane fixture did not receive the PATCH: #{inspect(result)}, server=#{inspect(Process.info(server, :status))}"
    end
  end

  defp receive_witnessed_server_count do
    receive do
      {:witnessed_server_count, count} -> count
    after
      1_000 -> raise "local Plane fixture did not report its connection count"
    end
  end

  defp accept_extra_connections(listener) do
    case :gen_tcp.accept(listener, 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        1 + accept_extra_connections(listener)

      {:error, :timeout} ->
        0
    end
  end

  defp receive_http_request(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {header_end, 4} ->
        body_start = header_end + 4
        headers = binary_part(acc, 0, header_end) |> IO.iodata_to_binary()
        body = binary_part(acc, body_start, byte_size(acc) - body_start)
        expected = content_length(headers)

        if byte_size(body) >= expected do
          binary_part(acc, 0, body_start + expected)
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
          receive_http_request(socket, acc <> data)
        end

      :nomatch ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        receive_http_request(socket, acc <> data)
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/(?:\r\n|^)content-length:\s*(\d+)/i, headers) do
      [_, value] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp normalize_wire_request(raw_request, port) do
    [header_block, body] = String.split(raw_request, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(header_block, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      header_lines
      |> Enum.map(fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        key = String.downcase(String.trim(key))
        value = String.trim(value)
        value = if key == "host", do: String.replace(value, Integer.to_string(port), "<fixture-port>"), else: value
        {key, value}
      end)
      |> Enum.sort()

    normalize_request(%{method: String.upcase(method), path: path, headers: headers, body: body}, "http://127.0.0.1:<fixture-port>")
  end

  defp normalize_request(request, base_url) do
    body = request.body

    %{
      method: request.method |> to_string() |> String.upcase(),
      url: base_url <> request.path,
      headers: normalize_headers(request.headers),
      encoded_body: if(is_binary(body), do: body, else: Jason.encode!(body)),
      request_id_in_origin: request_contains_id?(request, body)
    }
  end

  defp normalize_headers(headers) do
    headers
    |> Enum.map(fn {key, value} ->
      normalized_value = if String.downcase(key) == "host", do: Regex.replace(~r/:\d+$/, value, ":<fixture-port>"), else: value
      [String.downcase(key), normalized_value]
    end)
    |> Enum.sort()
  end

  defp request_contains_id?(request, body) do
    id = @provider_request_id

    String.contains?(request.path, id) or String.contains?(if(is_binary(body), do: body, else: Jason.encode!(body)), id) or
      Enum.any?(request.headers, fn {key, value} -> String.contains?(key, id) or String.contains?(value, id) end)
  end

  defp result_record(:ok), do: %{status: "accepted"}

  defp result_record({:error, %Client.Error{kind: kind, status: status}}),
    do: %{error_kind: Atom.to_string(kind), status: status}

  defp result_record({:error, {:dispatch_witness_failed, reason}}),
    do: %{error_kind: "dispatch_witness_failed", reason: inspect(reason)}

  defp result_record({:error, {:provider_status, status}}),
    do: %{error_kind: "provider_status", status: status}

  defp result_record({:error, reason}), do: %{error_kind: "transport", reason: inspect(reason)}
  defp result_record(other), do: %{result: inspect(other)}

  defp validate_capture!(cases) do
    by_name = Map.new(cases, &{&1.name, &1})
    validate_capture_results!(by_name)
    expected_request = validate_request_equivalence!(by_name)
    validate_expected_request!(expected_request)
    :ok
  end

  defp validate_capture_results!(by_name) do
    accepted = Map.fetch!(by_name, "accepted")
    provider_error = Map.fetch!(by_name, "provider_error")
    timeout = Map.fetch!(by_name, "timeout")
    witness_rejection = Map.fetch!(by_name, "witness_rejection")

    unless accepted.result == %{status: "accepted"}, do: raise("accepted fixture did not succeed")
    unless provider_error.result == %{error_kind: "provider_status", status: 422}, do: raise("provider error fixture did not return 422")
    unless timeout.result == %{error_kind: "transport", reason: ":timeout"}, do: raise("timeout fixture did not time out")

    unless witness_rejection.result == %{error_kind: "dispatch_witness_failed", reason: ":sink_rejected"} and
             witness_rejection.transport_count == 0 do
      raise "witness rejection reached transport"
    end

    :ok
  end

  defp validate_request_equivalence!(by_name) do
    accepted = Map.fetch!(by_name, "accepted")

    request_fields = [
      :method,
      :url,
      :headers,
      :encoded_body,
      :provider_request_id,
      :witness_ack_before_transport,
      :transport_count,
      :request_id_in_origin,
      :proof_finch_started,
      :proof_helper_started
    ]

    expected_request = Map.take(accepted, request_fields)

    for case_name <- ["provider_error", "timeout"] do
      observed_request = Map.take(Map.fetch!(by_name, case_name), request_fields)
      unless observed_request == expected_request, do: raise("#{case_name} request differed from accepted request")
    end

    expected_request
  end

  defp validate_expected_request!(expected_request) do
    unless expected_request.method == "PATCH" and expected_request.witness_ack_before_transport and
             expected_request.transport_count == 1 and expected_request.request_id_in_origin == false and
             expected_request.proof_finch_started == false and expected_request.proof_helper_started == false do
      raise "dormant request proof invariants failed"
    end

    :ok
  end

  defp response_bytes(204), do: "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

  defp response_bytes(status) do
    body = ~s({"detail":"local fixture"})

    "HTTP/1.1 #{status} Fixture Error\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
  end

  defp client_config(base_url) do
    %{
      base_url: base_url,
      workspace_slug: "workspace",
      workspace_id: @workspace_id,
      project_id: @project_id,
      api_key: "local-fixture"
    }
  end

  defp envelope do
    %ProviderMutationEnvelope{
      provider_request_id: @provider_request_id,
      transition_attempt_id: "attempt-dormant-capture",
      work_item_id: @work_item_id,
      provider: :plane,
      workspace_id: @workspace_id,
      project_id: @project_id,
      requested_from: :ready,
      requested_to: :in_progress,
      target_provider_state_id: @target_state_id,
      target_provider_state_group: :started,
      provider_contract_fingerprint: "fixture-contract",
      submitted_at: DateTime.utc_now()
    }
  end

  defp listener! do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {listener, port}
  end
end

Application.put_env(:symphony_elixir, :a4_qualification_local_only, true)
{:ok, _started_apps} = Application.ensure_all_started(:req)
IO.puts(Jason.encode!(SymphonyElixir.A4DormantCapture.run!()))
