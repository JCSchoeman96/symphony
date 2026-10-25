defmodule SymphonyElixir.WorkControl.A4HostRelayIPC do
  @moduledoc false

  @max_message_bytes 16_384
  @max_timeout_ms 30_000
  @forbidden_keys ~w(api_key authorization authorization_header body payload secret token tls_plaintext)

  @spec call(binary(), map()) :: {:ok, map()} | {:error, atom()}
  def call(socket_path, message), do: call(socket_path, message, @max_timeout_ms)

  @spec call(binary(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def call(socket_path, message, timeout_ms)
      when is_binary(socket_path) and is_map(message) and is_integer(timeout_ms) and
             timeout_ms in 1..@max_timeout_ms do
    with :ok <- validate_socket_path(socket_path),
         :ok <- validate_message(message),
         {:ok, encoded} <- encode_message(message),
         {:ok, socket} <- connect(socket_path, timeout_ms) do
      exchange(socket, encoded, timeout_ms)
    end
  rescue
    _ -> {:error, :controller_ipc_failed}
  end

  def call(_socket_path, _message, _timeout_ms), do: {:error, :invalid_controller_ipc_request}

  defp validate_socket_path(path) do
    if String.starts_with?(path, "/") and byte_size(path) <= 100 and not String.contains?(path, <<0>>),
      do: :ok,
      else: {:error, :invalid_controller_socket}
  end

  defp validate_message(message) do
    if safe_term?(message), do: :ok, else: {:error, :unsafe_controller_message}
  end

  defp safe_term?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} ->
      safe_key?(key) and safe_term?(value)
    end)
  end

  defp safe_term?(term) when is_list(term), do: Enum.all?(term, &safe_term?/1)
  defp safe_term?(term) when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term), do: true
  defp safe_term?(_term), do: false

  defp safe_key?(key) when is_binary(key) do
    lowered = String.downcase(key)

    lowered not in @forbidden_keys and
      (lowered == "operator_authorization_ref" or not String.contains?(lowered, "authorization"))
  end

  defp safe_key?(_key), do: false

  defp encode_message(message) do
    case Jason.encode(message) do
      {:ok, encoded} when byte_size(encoded) + 1 <= @max_message_bytes -> {:ok, encoded <> "\n"}
      {:ok, _encoded} -> {:error, :message_too_large}
      {:error, _reason} -> {:error, :invalid_controller_ipc_message}
    end
  end

  defp connect(path, timeout_ms) do
    options = [:binary, active: false, packet: :line, packet_size: @max_message_bytes]

    case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:error, :controller_socket_unavailable}
    end
  end

  defp exchange(socket, encoded, timeout_ms) do
    # Close the socket even when encoding or response validation raises.
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      with :ok <- :gen_tcp.send(socket, encoded),
           {:ok, response} <- receive_response(socket, timeout_ms) do
        case Jason.decode(response) do
          {:ok, decoded} when is_map(decoded) ->
            if safe_term?(decoded), do: {:ok, decoded}, else: {:error, :unsafe_controller_response}

          _ ->
            {:error, :malformed_controller_response}
        end
      else
        {:error, :message_too_large} = error -> error
        {:error, _reason} -> {:error, :controller_ipc_failed}
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_response(socket, timeout_ms) do
    case :gen_tcp.recv(socket, 0, timeout_ms) do
      {:ok, line} when byte_size(line) <= @max_message_bytes and byte_size(line) > 1 ->
        if String.ends_with?(line, "\n"), do: {:ok, String.trim_trailing(line, "\n")}, else: {:error, :malformed_response}

      {:ok, _line} ->
        {:error, :message_too_large}

      {:error, _reason} ->
        {:error, :controller_ipc_failed}
    end
  end
end
