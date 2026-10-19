defmodule SymphonyElixir.Plane.ReqFinchErrorNormalizer do
  @moduledoc false

  @spec normalize(term()) :: term()
  def normalize(%Mint.TransportError{reason: reason}), do: %Req.TransportError{reason: reason}

  def normalize(%Mint.HTTPError{module: Mint.HTTP1, reason: reason}),
    do: %Req.HTTPError{protocol: :http1, reason: reason}

  def normalize(%Mint.HTTPError{module: Mint.HTTP2, reason: reason}),
    do: %Req.HTTPError{protocol: :http2, reason: reason}

  def normalize(error) when is_struct(error, Finch.Error),
    do: %Req.HTTPError{protocol: :http2, reason: error.reason}

  def normalize(error) when is_struct(error, Finch.TransportError),
    do: %Req.TransportError{reason: error.reason}

  def normalize(error) when is_struct(error, Finch.HTTPError) do
    protocol = if error.module == Mint.HTTP2, do: :http2, else: :http1
    %Req.HTTPError{protocol: protocol, reason: error.reason}
  end

  def normalize(error), do: error

  @spec normalize_stream_result(term(), term()) :: term()
  def normalize_stream_result(_req, {:ok, acc}), do: acc

  def normalize_stream_result(req, {:error, exception}),
    do: {req, normalize(exception)}

  def normalize_stream_result(req, {:error, exception, _acc}),
    do: {req, normalize(exception)}

  def normalize_stream_result(_req, result), do: result
end
