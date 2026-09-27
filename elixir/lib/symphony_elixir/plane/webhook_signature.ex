defmodule SymphonyElixir.Plane.WebhookSignature do
  @moduledoc "Verifies Plane webhook signatures over the original request bytes."

  @secret_env "PLANE_WEBHOOK_SECRET"
  @signature_bytes 32

  def verify(raw_body, signature, opts \\ [])

  @spec verify(binary(), binary() | nil) ::
          :ok | {:error, :invalid_signature | :secret_unavailable}
  @spec verify(binary(), binary() | nil, keyword()) ::
          :ok | {:error, :invalid_signature | :secret_unavailable}

  def verify(raw_body, signature, opts) when is_binary(raw_body) and is_list(opts) do
    secret = Keyword.get_lazy(opts, :secret, fn -> System.get_env(@secret_env) end)

    cond do
      not is_binary(secret) or secret == "" ->
        {:error, :secret_unavailable}

      not is_binary(signature) or byte_size(signature) != @signature_bytes * 2 ->
        {:error, :invalid_signature}

      true ->
        compare_signature(raw_body, secret, signature)
    end
  end

  def verify(_raw_body, _signature, _opts), do: {:error, :invalid_signature}

  defp compare_signature(raw_body, secret, signature) do
    case Base.decode16(signature, case: :mixed) do
      {:ok, provided} -> verify_digest(raw_body, secret, provided)
      :error -> {:error, :invalid_signature}
    end
  end

  defp verify_digest(raw_body, secret, provided) do
    expected = :crypto.mac(:hmac, :sha256, secret, raw_body)

    if Plug.Crypto.secure_compare(expected, provided),
      do: :ok,
      else: {:error, :invalid_signature}
  end
end
