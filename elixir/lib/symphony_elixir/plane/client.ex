defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Bounded, read-only Plane REST transport.

  This module performs only scoped GET requests. It does not retry, mutate
  provider state, follow relations, or expose response bodies in errors.
  """

  @default_base_url "https://api.plane.so"
  @connect_timeout_ms 5_000
  @receive_timeout_ms 15_000
  @page_size 100
  @max_pages 100
  @max_work_items 10_000
  @max_states 64

  defmodule Error do
    @moduledoc "Safe Plane transport error without response bodies or headers."
    defstruct [:kind, :status, :retry_after]
    @type t :: %__MODULE__{kind: atom(), status: integer() | nil, retry_after: integer() | nil}
  end

  @type config :: map()
  @type request :: %{method: :get, path: String.t(), params: map(), headers: [{String.t(), String.t()}]}
  @type request_fun :: (request() -> {:ok, map()} | {:error, term()})

  @spec get_project(config(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_project(config, opts \\ []) when is_map(config) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, response} <- request(config, project_path(config), %{}, opts) do
      successful_body(response, :object)
    end
  end

  @spec get_work_item(config(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_work_item(config, work_item_id, opts \\ [])
      when is_map(config) and is_binary(work_item_id) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, id} <- identifier(work_item_id),
         {:ok, response} <- request(config, work_item_path(config, id), state_expansion_params(), opts) do
      successful_body(response, :object)
    end
  end

  @spec list_work_items(config(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_work_items(config, opts \\ []) when is_map(config) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts) do
      paginate(%{
        config: config,
        path: work_items_path(config),
        params: work_item_params(),
        kind: :work_items,
        opts: opts,
        acc: [],
        cursors: [],
        page_count: 0,
        item_count: 0
      })
    end
  end

  @spec list_states(config(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_states(config, opts \\ []) when is_map(config) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts) do
      paginate(%{
        config: config,
        path: states_path(config),
        params: %{"per_page" => @page_size},
        kind: :states,
        opts: opts,
        acc: [],
        cursors: [],
        page_count: 0,
        item_count: 0
      })
    end
  end

  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @spec validate_config(config()) :: :ok | {:error, term()}
  def validate_config(config) when is_map(config) do
    case normalize_config(config, []) do
      {:ok, _normalized} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_config(_config), do: {:error, :invalid_configuration}

  defp paginate(%{page_count: page_count}) when page_count >= @max_pages do
    {:error, :snapshot_incomplete}
  end

  defp paginate(%{kind: kind, item_count: item_count} = context) do
    if item_count >= limit_for(kind) do
      {:error, :snapshot_incomplete}
    else
      paginate_page(context)
    end
  end

  defp paginate_page(%{config: config, path: path, params: params, kind: kind, opts: opts} = context) do
    with {:ok, response} <- request(config, path, params, opts),
         {:ok, page, next_cursor, next?} <- decode_page(response, kind),
         {:ok, updated_acc} <- append_page(context.acc, page, kind, context.item_count) do
      advance_pagination(context, updated_acc, page, next_cursor, next?)
    end
  end

  defp advance_pagination(context, updated_acc, page, _next_cursor, false) do
    next_count = context.item_count + length(page)

    if next_count <= limit_for(context.kind), do: {:ok, Enum.reverse(updated_acc)}, else: {:error, :snapshot_incomplete}
  end

  defp advance_pagination(_context, _updated_acc, _page, next_cursor, true)
       when not is_binary(next_cursor) or next_cursor == "" do
    {:error, :snapshot_incomplete}
  end

  defp advance_pagination(context, updated_acc, page, next_cursor, true) do
    if next_cursor in context.cursors do
      {:error, :snapshot_incomplete}
    else
      next_context = %{
        config: context.config,
        path: context.path,
        params: Map.put(context.params, "cursor", next_cursor),
        kind: context.kind,
        opts: context.opts,
        acc: updated_acc,
        cursors: [next_cursor | context.cursors],
        page_count: context.page_count + 1,
        item_count: context.item_count + length(page)
      }

      paginate(next_context)
    end
  end

  defp append_page(acc, page, :work_items, item_count) when is_list(page) do
    cond do
      not Enum.all?(page, &is_map/1) -> {:error, :provider_malformed}
      item_count + length(page) <= @max_work_items -> {:ok, Enum.reduce(page, acc, &[&1 | &2])}
      true -> {:error, :snapshot_incomplete}
    end
  end

  defp append_page(acc, page, :states, item_count) when is_list(page) do
    cond do
      not Enum.all?(page, &is_map/1) -> {:error, :provider_malformed}
      item_count + length(page) <= @max_states -> {:ok, Enum.reduce(page, acc, &[&1 | &2])}
      true -> {:error, :snapshot_incomplete}
    end
  end

  defp append_page(_acc, _page, _kind, _item_count), do: {:error, :provider_malformed}

  defp decode_page(response, kind) do
    with {:ok, body} <- successful_body(response, :page),
         {:ok, results} <- page_results(body),
         {:ok, next?} <- page_next(body),
         :ok <- page_counts(body) do
      next_cursor = raw_value(body, :next_cursor)

      if next? and not valid_cursor?(next_cursor) do
        {:error, :snapshot_incomplete}
      else
        _ = kind
        {:ok, results, next_cursor, next?}
      end
    end
  end

  defp page_results(body) do
    case raw_value(body, :results) do
      results when is_list(results) -> {:ok, results}
      _value -> {:error, :provider_malformed}
    end
  end

  defp page_next(body) do
    next? = raw_value(body, :next_page_results)
    next_cursor = raw_value(body, :next_cursor)

    cond do
      not is_boolean(next?) ->
        {:error, :snapshot_incomplete}

      next? and valid_cursor?(next_cursor) ->
        {:ok, true}

      next? ->
        {:error, :snapshot_incomplete}

      is_nil(next_cursor) or next_cursor == "" ->
        {:ok, false}

      true ->
        {:error, :snapshot_incomplete}
    end
  end

  defp page_counts(body) do
    if valid_page_count?(raw_value(body, :count)) and valid_page_count?(raw_value(body, :total_results)) do
      :ok
    else
      {:error, :provider_malformed}
    end
  end

  defp valid_page_count?(nil), do: true
  defp valid_page_count?(value), do: is_integer(value) and value >= 0

  defp request(config, path, params, opts) do
    request = %{
      method: :get,
      path: path,
      params: params,
      headers: [{"X-API-Key", config.api_key}, {"Accept", "application/json"}]
    }

    case Keyword.get(opts, :request_fun) do
      fun when is_function(fun) ->
        case invoke_request_fun(fun, request, config) do
          {:ok, response} when is_map(response) -> normalize_response(response)
          {:error, reason} -> {:error, transport_error(reason)}
          _invalid -> {:error, :provider_unavailable}
        end

      nil ->
        perform_request(config, request)

      _invalid ->
        {:error, :provider_unavailable}
    end
  end

  defp invoke_request_fun(fun, request, config) do
    do_invoke_request_fun(fun, request, config)
  rescue
    _error -> {:error, :request_fun_failed}
  catch
    _kind, _reason -> {:error, :request_fun_failed}
  end

  defp do_invoke_request_fun(fun, request, _config) when is_function(fun, 1), do: fun.(request)

  defp do_invoke_request_fun(fun, request, _config) when is_function(fun, 4) do
    fun.(request.method, request.path, request.params, request.headers)
  end

  defp do_invoke_request_fun(fun, request, config) when is_function(fun, 5) do
    fun.(request.method, request.path, request.params, nil, config)
  end

  defp do_invoke_request_fun(_fun, _request, _config), do: {:error, :invalid_request_fun}

  defp perform_request(config, %{path: path, params: params, headers: headers}) do
    url = config.base_url <> path

    case Req.request(
           method: :get,
           url: url,
           headers: headers,
           params: params,
           connect_options: [timeout: @connect_timeout_ms],
           receive_timeout: @receive_timeout_ms,
           retry: false
         ) do
      {:ok, response} -> normalize_response(%{status: response.status, headers: response.headers, body: response.body})
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp normalize_response(response) do
    status = Map.get(response, :status, Map.get(response, "status"))
    headers = Map.get(response, :headers, Map.get(response, "headers", %{}))
    body = Map.get(response, :body, Map.get(response, "body"))

    case valid_status(status) do
      {:ok, status} when status in 200..299 ->
        case decode_body(body) do
          {:ok, decoded} -> {:ok, %{status: status, headers: headers, body: decoded}}
          {:error, reason} -> {:error, reason}
        end

      {:ok, status} ->
        {:ok, %{status: status, headers: headers, body: nil}}

      {:error, _reason} = error ->
        error
    end
  end

  defp successful_body(%{status: status, body: body}, expected) when status in 200..299 do
    case {expected, body} do
      {:object, value} when is_map(value) -> {:ok, value}
      {:page, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :provider_malformed}
    end
  end

  defp successful_body(%{status: 401}, _expected), do: {:error, :unauthorized}
  defp successful_body(%{status: 403}, _expected), do: {:error, :unauthorized}
  defp successful_body(%{status: 404}, _expected), do: {:error, :not_found}

  defp successful_body(%{status: 429, headers: headers}, _expected) do
    {:error, {:rate_limited, rate_limit_metadata(headers)}}
  end

  defp successful_body(%{status: status}, _expected) when status in 500..599,
    do: {:error, :provider_unavailable}

  defp successful_body(_response, _expected), do: {:error, :provider_malformed}

  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :provider_malformed}
    end
  end

  defp decode_body(_body), do: {:error, :provider_malformed}

  defp valid_status(status) when is_integer(status), do: {:ok, status}
  defp valid_status(_status), do: {:error, :provider_unavailable}

  defp normalize_config(config, opts) do
    base_url = Map.get(config, :base_url)
    base_url = if is_nil(base_url), do: Map.get(config, "base_url", @default_base_url), else: base_url

    workspace_id = first_present(config, [:workspace_id, "workspace_id", :workspace_slug, "workspace_slug"])
    project_id = first_present(config, [:project_id, "project_id"])
    api_key = first_present(config, [:api_key, "api_key"])

    cond do
      not present?(workspace_id) or not present?(project_id) ->
        {:error, :invalid_scope}

      not present?(api_key) ->
        {:error, :missing_credential}

      validate_base_url(base_url, Keyword.has_key?(opts, :request_fun)) != :ok ->
        {:error, :invalid_base_url}

      true ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           workspace_id: workspace_id,
           project_id: project_id,
           api_key: api_key
         }}
    end
  end

  defp validate_base_url(value, test_request?) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        :ok

      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when test_request? and is_binary(host) and host != "" and path in [nil, "", "/"] ->
        :ok

      _ ->
        :error
    end
  end

  defp validate_base_url(_value, _test_request?), do: :error

  defp project_path(config), do: "/api/v1/workspaces/#{encoded(config.workspace_id)}/projects/#{encoded(config.project_id)}/"
  defp work_item_path(config, id), do: work_items_path(config) <> encoded(id) <> "/"
  defp work_items_path(config), do: project_path(config) <> "work-items/"
  defp states_path(config), do: project_path(config) <> "states/"

  defp state_expansion_params, do: %{"fields" => "state", "expand" => "state"}
  defp work_item_params, do: Map.put(state_expansion_params(), "per_page", @page_size)
  defp limit_for(:work_items), do: @max_work_items
  defp limit_for(:states), do: @max_states

  defp identifier(value) do
    if present?(value), do: {:ok, String.trim(value)}, else: {:error, :invalid_scope}
  end

  defp encoded(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
  defp valid_cursor?(value), do: is_binary(value) and String.trim(value) != ""
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp raw_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, &present_value(Map.get(map, &1)))
  end

  defp present_value(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_value(_value), do: nil

  defp rate_limit_metadata(headers) do
    retry_after = header_value(headers, "retry-after") |> parse_integer()
    reset = header_value(headers, "x-ratelimit-reset") |> parse_integer()
    %{retry_after: retry_after || reset}
  end

  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(to_string(key)) == name, do: value end)
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(to_string(key)) == name, do: value end)
  end

  defp header_value(_headers, _name), do: nil

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_integer([value | _rest]), do: parse_integer(value)

  defp parse_integer(_value), do: nil

  defp transport_error(%Error{kind: kind}), do: kind
  defp transport_error(_reason), do: :provider_unavailable
end
