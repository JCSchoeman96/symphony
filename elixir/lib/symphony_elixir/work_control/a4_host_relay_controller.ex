defmodule SymphonyElixir.WorkControl.A4HostRelayController do
  @moduledoc """
  Local A4 callback proxy that returns the frozen READY fields only after
  the launcher confirms Stage B for the proof PID and relay port.
  """

  use GenServer

  @ready_fields ~w(type provider_request_id listen_host bound_port python_version script_blob_sha256 environment_names)
  @max_message_bytes 16_384

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    backend = Keyword.fetch!(opts, :backend)

    case invoke(backend, :verify_stage_a, []) do
      :ok -> {:ok, %{backend: backend, ref: Keyword.fetch!(opts, :ref)}}
      {:error, reason} -> {:stop, {:stage_a_failed, reason}}
      _ -> {:stop, :stage_a_failed}
    end
  rescue
    _ -> {:stop, :stage_a_failed}
  end

  @impl true
  def handle_info({:a4_manifest_request, reply_to, ref, request_id, request}, %{ref: ref} = state)
      when is_pid(reply_to) and is_reference(request_id) and is_map(request) do
    response = invoke(state.backend, :manifest, [request])

    case response do
      {:ok, manifest} when is_map(manifest) ->
        if bounded?(manifest),
          do: reply(reply_to, :a4_manifest_response, ref, request_id, manifest),
          else: reply(reply_to, :a4_manifest_response, ref, request_id, {:error, :invalid_manifest})

      _ ->
        reply(reply_to, :a4_manifest_response, ref, request_id, {:error, :invalid_manifest})
    end

    {:noreply, state}
  rescue
    _ ->
      reply(reply_to, :a4_manifest_response, ref, request_id, {:error, :controller_failed})
      {:noreply, state}
  end

  def handle_info({:a4_ready_request, reply_to, ref, request_id, request}, %{ref: ref} = state)
      when is_pid(reply_to) and is_reference(request_id) and is_map(request) do
    response = invoke(state.backend, :ready, [request])

    case response do
      {:ok, ready} when is_map(ready) ->
        if valid_ready?(ready, request, state.backend),
          do: reply(reply_to, :a4_ready_response, ref, request_id, ready),
          else: reply(reply_to, :a4_ready_response, ref, request_id, {:error, :policy_not_verified})

      _ ->
        reply(reply_to, :a4_ready_response, ref, request_id, {:error, :policy_not_verified})
    end

    {:noreply, state}
  rescue
    _ ->
      reply(reply_to, :a4_ready_response, ref, request_id, {:error, :controller_failed})
      {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp invoke(backend, name, args) when is_map(backend) do
    case Map.fetch(backend, name) do
      {:ok, fun} when is_function(fun) -> apply(fun, args)
      _ -> {:error, :backend_unavailable}
    end
  end

  defp bounded?(term), do: byte_size(:erlang.term_to_binary(term)) <= @max_message_bytes

  defp valid_ready?(ready, request, backend) do
    keys = Enum.map(Map.keys(ready), &to_string/1) |> Enum.sort()

    bounded?(ready) and keys == Enum.sort(@ready_fields) and
      value(ready, :type) == "READY" and
      value(ready, :provider_request_id) == value(request, :provider_request_id) and
      value(ready, :listen_host) == "127.0.0.1" and
      is_integer(value(ready, :bound_port)) and value(ready, :bound_port) in 1..65_535 and
      invoke(backend, :stage_b_verified?, [request, ready]) == true
  rescue
    _ -> false
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp reply(pid, type, ref, request_id, response),
    do: send(pid, {type, self(), ref, request_id, response})
end
