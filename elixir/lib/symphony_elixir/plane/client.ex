defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Bounded Plane REST transport.

  Read operations remain scoped and bounded. The only mutation operation is a
  state-ID PATCH used by the host transition coordinator.
  """

  alias SymphonyElixir.Plane.ReadScheduler
  alias SymphonyElixir.Plane.ReqFinchErrorNormalizer
  alias SymphonyElixir.WorkControl.{A4Proof, ProviderDispatchWitness, ProviderMutationEnvelope}

  @default_base_url "https://api.plane.so"
  @default_read_scheduler SymphonyElixir.Plane.ReadScheduler
  @read_wait_timeout_ms 240_000
  @connect_timeout_ms 5_000
  @proof_finch_name SymphonyElixir.H100TransportProofFinch
  @receive_timeout_ms 15_000
  @page_size 100
  @max_pages 100
  @max_work_items 10_000
  @max_states 64
  @max_response_bytes 4_000_000
  @response_too_large_marker :symphony_plane_response_too_large
  @work_item_fields "id,name,description,priority,sequence_id,state,assignees,labels,created_at,updated_at,project,workspace"
  @state_fields "id,name,group,project,workspace"

  defmodule Error do
    @moduledoc "Safe Plane transport error without response bodies or headers."
    defstruct [:kind, :status, :retry_after]
    @type t :: %__MODULE__{kind: atom(), status: integer() | nil, retry_after: number() | nil}
  end

  @type config :: map()
  @type request :: map()
  @type request_fun ::
          (request() -> {:ok, map()} | {:error, term()})
          | (atom(), String.t(), map(), term() -> {:ok, map()} | {:error, term()})
          | (atom(), String.t(), map(), term(), config() -> {:ok, map()} | {:error, term()})

  @spec get_project(config(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_project(config, opts \\ []) when is_map(config) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, response} <- request(config, project_path(config), %{}, opts, :control) do
      successful_body(response, :object)
    end
  end

  @spec get_work_item(config(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_work_item(config, work_item_id, opts \\ [])
      when is_map(config) and is_binary(work_item_id) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, id} <- identifier(work_item_id),
         {:ok, response} <-
           request(config, work_item_path(config, id), state_expansion_params(), opts, :control) do
      successful_body(response, :object)
    end
  end

  @spec get_work_item_relations(config(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_work_item_relations(config, work_item_id, opts \\ [])
      when is_map(config) and is_binary(work_item_id) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, id} <- identifier(work_item_id),
         {:ok, response} <- request(config, relation_path(config, id), %{}, opts, :bulk) do
      successful_body(response, :object)
    end
  end

  @spec update_work_item_state(config(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_work_item_state(config, work_item_id, target_state_id, opts \\ [])
      when is_map(config) and is_binary(work_item_id) and is_binary(target_state_id) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts),
         {:ok, id} <- identifier(work_item_id),
         {:ok, state_id} <- identifier(target_state_id),
         :ok <- validate_witness_configuration(opts),
         :ok <- validate_mutation_envelope(opts, config, id, state_id),
         {:ok, response} <- mutation_request(config, work_item_path(config, id), %{"state" => state_id}, opts) do
      mutation_acknowledgement(response)
    end
  after
    release_proof_monitor(Keyword.get(opts, :a4_session))
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
        item_count: 0,
        total_results: nil,
        request_class: :bulk
      })
    end
  end

  @spec list_states(config(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_states(config, opts \\ []) when is_map(config) and is_list(opts) do
    with {:ok, config} <- normalize_config(config, opts) do
      paginate(%{
        config: config,
        path: states_path(config),
        params: state_params(),
        kind: :states,
        opts: opts,
        acc: [],
        cursors: [],
        page_count: 0,
        item_count: 0,
        total_results: nil,
        request_class: :bulk
      })
    end
  end

  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @spec tls_options(String.t()) :: keyword()
  def tls_options(host) when is_binary(host) do
    [
      verify: :verify_peer,
      versions: [:"tlsv1.2"],
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      timeout: @connect_timeout_ms
    ]
  end

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

  defp paginate_page(%{config: config, path: path, params: params, kind: kind, opts: opts, request_class: request_class} = context) do
    with {:ok, response} <- request(config, path, params, opts, request_class),
         {:ok, page, next_cursor, next?, page_total} <- decode_page(response, kind),
         {:ok, updated_acc} <- append_page(context.acc, page, kind, context.item_count) do
      advance_pagination(context, updated_acc, page, page_total, next_cursor, next?)
    end
  end

  defp advance_pagination(context, updated_acc, page, page_total, _next_cursor, false) do
    next_count = context.item_count + length(page)

    with {:ok, total_results} <- reconcile_total_results(context.total_results, page_total),
         :ok <- validate_terminal_count(next_count, total_results) do
      if next_count <= limit_for(context.kind), do: {:ok, Enum.reverse(updated_acc)}, else: {:error, :snapshot_incomplete}
    end
  end

  defp advance_pagination(_context, _updated_acc, _page, _page_total, next_cursor, true)
       when not is_binary(next_cursor) or next_cursor == "" do
    {:error, :snapshot_incomplete}
  end

  defp advance_pagination(context, updated_acc, page, page_total, next_cursor, true) do
    with {:ok, total_results} <- reconcile_total_results(context.total_results, page_total),
         :ok <- validate_running_count(context.item_count + length(page), total_results) do
      if next_cursor in context.cursors do
        {:error, :snapshot_incomplete}
      else
        next_context = %{
          config: context.config,
          path: context.path,
          params: Map.put(context.params, "cursor", next_cursor),
          kind: context.kind,
          request_class: context.request_class,
          opts: context.opts,
          acc: updated_acc,
          cursors: [next_cursor | context.cursors],
          page_count: context.page_count + 1,
          item_count: context.item_count + length(page),
          total_results: total_results
        }

        paginate(next_context)
      end
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
         {:ok, _page_count, total_results} <- page_counts(body, results) do
      next_cursor = raw_value(body, :next_cursor)

      if next? and not valid_cursor?(next_cursor) do
        {:error, :snapshot_incomplete}
      else
        _ = kind
        {:ok, results, next_cursor, next?, total_results}
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

      true ->
        {:ok, false}
    end
  end

  defp page_counts(body, results) do
    count = raw_value(body, :count)
    total_results = raw_value(body, :total_results)

    cond do
      is_nil(count) or is_nil(total_results) -> {:error, :snapshot_incomplete}
      not valid_page_count?(count) or not valid_page_count?(total_results) -> {:error, :provider_malformed}
      count != length(results) -> {:error, :provider_malformed}
      total_results < count -> {:error, :provider_malformed}
      true -> {:ok, count, total_results}
    end
  end

  defp reconcile_total_results(nil, total_results), do: {:ok, total_results}
  defp reconcile_total_results(total_results, total_results), do: {:ok, total_results}
  defp reconcile_total_results(_expected, nil), do: {:error, :snapshot_incomplete}
  defp reconcile_total_results(_expected, _observed), do: {:error, :snapshot_incomplete}

  defp validate_running_count(count, total_results) when is_integer(total_results) do
    if count <= total_results, do: :ok, else: {:error, :snapshot_incomplete}
  end

  defp validate_running_count(_count, _total_results), do: :ok

  defp validate_terminal_count(count, total_results) when is_integer(total_results) do
    if count == total_results, do: :ok, else: {:error, :snapshot_incomplete}
  end

  defp validate_terminal_count(_count, _total_results), do: :ok

  defp valid_page_count?(value), do: is_integer(value) and value >= 0

  defp request(config, path, params, opts, request_class) do
    request = %{
      method: :get,
      path: path,
      params: params,
      headers: [{"X-API-Key", config.api_key}, {"Accept", "application/json"}]
    }

    with :ok <- qualification_transport_guard(config, opts) do
      increment_request_metric(Keyword.get(opts, :request_metrics), 1)

      request_fun = Keyword.get(opts, :request_fun)
      scheduler = scheduler_option(opts, request_fun)

      result =
        if scheduler do
          ReadScheduler.execute(
            scheduler,
            request_class,
            fn ->
              increment_request_metric(Keyword.get(opts, :request_metrics), 2)
              raw_get_request(config, request, request_fun)
            end,
            wait_timeout: @read_wait_timeout_ms,
            epoch_id: Keyword.get(opts, :epoch_id),
            request_metrics: Keyword.get(opts, :request_metrics)
          )
        else
          raw_get_request(config, request, request_fun)
        end

      sanitize_get_result(result)
    end
  end

  defp scheduler_option(opts, request_fun) do
    explicit_scheduler =
      cond do
        Keyword.has_key?(opts, :scheduler) -> Keyword.get(opts, :scheduler)
        Keyword.has_key?(opts, :read_scheduler) -> Keyword.get(opts, :read_scheduler)
        true -> :not_given
      end

    cond do
      explicit_scheduler == :not_given and is_function(request_fun) -> nil
      explicit_scheduler == :not_given -> @default_read_scheduler
      true -> explicit_scheduler
    end
  end

  defp raw_get_request(config, request, request_fun) do
    result =
      case request_fun do
        fun when is_function(fun) -> invoke_request_fun(fun, request, config)
        nil -> perform_request(config, request)
        _invalid -> {:error, :provider_unavailable}
      end

    case result do
      {:ok, response} when is_map(response) -> normalize_response(response)
      {:error, _reason} = error -> error
      _invalid -> {:error, :provider_unavailable}
    end
  end

  defp sanitize_get_result({:ok, response}) when is_map(response), do: {:ok, response}

  defp sanitize_get_result({:error, {:rate_limited, metadata}}) do
    {:error, {:rate_limited, sanitize_rate_limit_metadata(metadata)}}
  end

  defp sanitize_get_result({:error, reason}) when reason in [:provider_malformed, :provider_response_too_large],
    do: {:error, reason}

  defp sanitize_get_result({:error, reason}), do: {:error, transport_error(reason)}
  defp sanitize_get_result(_invalid), do: {:error, :provider_unavailable}

  defp sanitize_rate_limit_metadata(metadata) when is_map(metadata) do
    headers = first_present_value(metadata, [:headers, "headers"])
    retry_after_header = header_value(headers, "retry-after")
    reset_header = header_value(headers, "x-ratelimit-reset")

    retry_after_seconds =
      first_present_value(metadata, [:retry_after_seconds, "retry_after_seconds", :retry_after, "retry_after"]) ||
        parse_seconds(retry_after_header)

    reset_at_unix =
      first_present_value(metadata, [:reset_at_unix, "reset_at_unix", :reset_at, "reset_at"]) ||
        parse_integer(reset_header)

    %{
      retry_after: parse_seconds(retry_after_seconds),
      retry_after_seconds: parse_seconds(retry_after_seconds),
      reset_at_unix: parse_integer(reset_at_unix)
    }
  end

  defp sanitize_rate_limit_metadata(_metadata), do: rate_limit_metadata(%{})

  defp first_present_value(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp increment_request_metric(nil, _index), do: :ok

  defp increment_request_metric(metrics, index) do
    :atomics.add(metrics, index, 1)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp mutation_request(config, path, body, opts) do
    request = %{
      method: :patch,
      path: path,
      params: %{},
      body: body,
      headers: [
        {"X-API-Key", config.api_key},
        {"Accept", "application/json"},
        {"Content-Type", "application/json"}
      ]
    }

    with :ok <- qualification_transport_guard(config, opts),
         :ok <- validate_request_transport(opts) do
      dispatch_mutation_request(config, request, opts)
    end
  end

  @doc false
  @spec qualification_transport_guard(config(), keyword()) :: :ok | {:error, atom()}
  def qualification_transport_guard(config, opts) do
    if Application.get_env(:symphony_elixir, :a4_qualification_local_only, false) do
      request_funs = Keyword.get_values(opts, :request_fun)
      base_url = Map.get(config, :base_url)
      uri = if is_binary(base_url), do: URI.parse(base_url), else: nil

      cond do
        length(request_funs) > 1 ->
          {:error, :qualification_transport_ambiguous}

        (uri && uri.host == "api.plane.so") and request_funs in [[], [nil]] and
            not local_req_test_transport?(opts) ->
          {:error, :qualification_live_plane_http_forbidden}

        true ->
          :ok
      end
    else
      :ok
    end
  rescue
    _error -> {:error, :qualification_transport_invalid}
  end

  defp local_req_test_transport?(opts) do
    Keyword.get(opts, :qualification_local_transport?, false) and
      Enum.any?(Keyword.take(Req.default_options(), [:adapter, :plug]), fn {_key, value} -> is_function(value) end)
  end

  defp validate_witness_configuration(opts) do
    witness_required? = Keyword.get(opts, :dispatch_witness_required?, false)
    timeout_ms = Keyword.get(opts, :dispatch_witness_timeout_ms, ProviderDispatchWitness.default_timeout_ms())

    cond do
      not is_boolean(witness_required?) ->
        {:error, {:dispatch_witness_failed, :invalid_dispatch_witness_configuration}}

      not ProviderDispatchWitness.valid_timeout?(timeout_ms) ->
        {:error, {:dispatch_witness_failed, :invalid_sink_timeout}}

      witness_required? and not provider_mutation_envelope?(Keyword.get(opts, :provider_mutation_envelope)) ->
        {:error, {:dispatch_witness_failed, :provider_mutation_envelope_required}}

      true ->
        :ok
    end
  end

  defp validate_mutation_envelope(opts, config, work_item_id, target_state_id) do
    case Keyword.get(opts, :provider_mutation_envelope) do
      nil ->
        :ok

      %ProviderMutationEnvelope{} = envelope ->
        if valid_mutation_binding?(envelope, config, work_item_id, target_state_id) do
          :ok
        else
          {:error, {:dispatch_witness_failed, :provider_mutation_binding_mismatch}}
        end

      _invalid ->
        {:error, {:dispatch_witness_failed, :invalid_provider_mutation_envelope}}
    end
  end

  defp valid_mutation_binding?(envelope, config, work_item_id, target_state_id) do
    ProviderMutationEnvelope.valid?(envelope) and
      envelope.provider == :plane and
      envelope.work_item_id == work_item_id and
      envelope.workspace_id == config.workspace_id and
      envelope.project_id == config.project_id and
      envelope.target_provider_state_id == target_state_id
  end

  @spec provider_mutation_envelope?(term()) :: boolean()
  defp provider_mutation_envelope?(%ProviderMutationEnvelope{}), do: true
  defp provider_mutation_envelope?(_envelope), do: false

  defp validate_request_transport(opts) do
    if Keyword.get(opts, :dispatch_witness_required?, false) and is_function(Keyword.get(opts, :request_fun)) and
         is_nil(Keyword.get(opts, :a4_session)) do
      {:error, {:dispatch_witness_failed, :request_fun_transport_not_supported}}
    else
      :ok
    end
  end

  defp dispatch_mutation_request(config, request, opts) do
    case Keyword.get(opts, :a4_session) do
      nil -> dispatch_ordinary_mutation_request(config, request, opts)
      token -> proof_mutation_request(config, request, opts, token)
    end
  end

  defp dispatch_ordinary_mutation_request(config, request, opts) do
    case Keyword.get(opts, :request_fun) do
      request_fun when is_function(request_fun) ->
        case invoke_mutation_request_fun(request_fun, request, config) do
          {:ok, response} when is_map(response) -> normalize_mutation_response(response)
          {:error, reason} -> {:error, mutation_transport_error(reason)}
          _invalid -> {:error, :provider_unavailable}
        end

      nil ->
        perform_mutation_request(config, request, opts)

      _invalid ->
        {:error, :provider_unavailable}
    end
  end

  defp proof_mutation_request(config, request, opts, token) do
    do_proof_mutation_request(config, request, opts, token)
  end

  defp do_proof_mutation_request(config, request, opts, token) do
    envelope = Keyword.get(opts, :provider_mutation_envelope)

    with true <- Keyword.get(opts, :dispatch_witness_required?, false),
         %ProviderMutationEnvelope{} <- envelope,
         :ok <- validate_proof_binding(config, request, envelope, token),
         nil <- Keyword.get(opts, :request_fun),
         {:ok, ready_token} <- A4Proof.ready(token),
         :ok <- validate_proof_ready(envelope, ready_token),
         :ok <- A4Proof.consume(ready_token, ready_token.bindings),
         {:ok, finch_pid} <- start_proof_finch(ready_token) do
      try do
        perform_mutation_request(config, request, Keyword.put(opts, :a4_proof_ready, ready_token))
      after
        stop_proof_finch(finch_pid)
      end
    else
      {:error, {:dispatch_witness_failed, _reason}} = error -> error
      false -> proof_failure(:witness_required)
      nil -> proof_failure(:request_fun_transport_not_supported)
      _ -> proof_failure(:invalid_proof_session)
    end
  end

  defp validate_proof_binding(config, request, envelope, token) do
    manifest = token.manifest
    base_url = config.base_url
    uri = URI.parse(base_url)
    authority = proof_authority(uri)
    body = Jason.encode!(request.body)
    path = request.path
    provider_request_id = envelope.provider_request_id

    checks =
      [
        {token.owner == self(), :proof_token_owner_mismatch}
      ] ++
        proof_origin_checks(token, manifest, base_url, authority) ++
        proof_identity_checks(manifest, envelope, request) ++
        proof_request_checks(token, request, path, body, provider_request_id)

    case Enum.find(checks, fn {valid?, _field} -> not valid? end) do
      nil -> :ok
      {_valid?, field} -> proof_failure({:proof_manifest_mismatch, field})
    end
  rescue
    _ -> proof_failure(:invalid_proof_session)
  end

  defp proof_origin_checks(token, manifest, base_url, authority) do
    origin_matches? =
      token.bindings.origin_base_url == base_url and manifest_value(manifest, :origin_base_url) == base_url

    [
      {origin_matches?, :origin_base_url},
      {manifest_value(manifest, :origin_authority) == authority, :origin_authority}
    ]
  end

  defp proof_identity_checks(manifest, envelope, request) do
    [
      {manifest_value(manifest, :method) == "PATCH" and request.method == :patch, :method},
      {manifest_value(manifest, :provider_request_id) == envelope.provider_request_id, :provider_request_id},
      {manifest_value(manifest, :work_item_id) == envelope.work_item_id, :work_item_id},
      {manifest_value(manifest, :workspace_id) == envelope.workspace_id, :workspace_id},
      {manifest_value(manifest, :project_id) == envelope.project_id, :project_id},
      {manifest_value(manifest, :target_state_id) == envelope.target_provider_state_id, :target_state_id},
      {manifest_value(manifest, :transition_attempt_id) == envelope.transition_attempt_id, :transition_attempt_id}
    ]
  end

  defp proof_request_checks(token, request, path, body, provider_request_id) do
    [
      {token.bindings.path == path and byte_size(path) <= 2048, :path_bytes},
      {token.bindings.path_bytes == byte_size(path), :path_bytes},
      {token.bindings.body_bytes == byte_size(body) and byte_size(body) <= 512, :body_bytes},
      {request_id_absent_from_request?(request, path, body, provider_request_id), :provider_request_id_origin_leak}
    ]
  end

  defp request_id_absent_from_request?(request, path, body, provider_request_id) do
    not String.contains?(path, provider_request_id) and
      not String.contains?(body, provider_request_id) and
      Enum.all?(request.headers, fn {name, value} ->
        not String.contains?(name, provider_request_id) and not String.contains?(value, provider_request_id)
      end)
  end

  defp validate_proof_ready(envelope, token) do
    manifest = token.manifest
    ready = token.ready
    request_id = envelope.provider_request_id

    valid? =
      ready_value(ready, :provider_request_id) == request_id and
        ready_value(ready, :listen_host) == "127.0.0.1" and
        is_integer(ready_value(ready, :bound_port)) and ready_value(ready, :bound_port) in 1..65_535 and
        (ready_value(ready, :script_blob_sha256) || ready_value(ready, :relay_script_blob_sha256)) ==
          manifest_value(manifest, :relay_script_blob_sha256)

    if valid?, do: :ok, else: proof_failure({:proof_manifest_mismatch, :ready})
  end

  defp start_proof_finch(token) do
    manifest = token.manifest
    ready = token.ready
    host = manifest_value(manifest, :origin_authority) |> String.split(":") |> hd()
    port = ready_value(ready, :bound_port)

    pools = %{
      default: [
        protocols: [:http1],
        size: 1,
        count: 1,
        conn_opts: [
          proxy: {:http, "127.0.0.1", port, []},
          proxy_headers: [{"x-symphony-provider-request-id", manifest_value(manifest, :provider_request_id)}],
          transport_opts: tls_options(host)
        ]
      ]
    }

    case Finch.start_link(name: @proof_finch_name, pools: pools) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> proof_failure({:proof_finch_start_failed, safe_finch_reason(reason)})
    end
  rescue
    _ -> proof_failure(:proof_finch_start_failed)
  end

  defp stop_proof_finch(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
    :ok
  catch
    _, _ -> :ok
  end

  defp proof_authority(%URI{host: host, port: port}) when is_binary(host) do
    default_port = if port == 443, do: 443, else: port
    "#{host}:#{default_port}"
  end

  defp proof_authority(_), do: nil

  defp manifest_value(manifest, key), do: Map.get(manifest, key) || Map.get(manifest, Atom.to_string(key))
  defp ready_value(ready, key), do: Map.get(ready, key) || Map.get(ready, Atom.to_string(key))
  defp proof_failure(reason), do: {:error, {:dispatch_witness_failed, reason}}
  defp safe_finch_reason({:already_started, _pid}), do: :already_started
  defp safe_finch_reason(_reason), do: :start_failed

  defp release_proof_monitor(token), do: A4Proof.release(token)

  defp invoke_mutation_request_fun(fun, request, config) do
    invoke_mutation_request_fun_by_arity(:erlang.fun_info(fun, :arity), fun, request, config)
  rescue
    _error -> {:error, :request_fun_failed}
  catch
    _kind, _reason -> {:error, :request_fun_failed}
  end

  defp invoke_mutation_request_fun_by_arity({:arity, 1}, fun, request, config),
    do: invoke_request_fun(fun, request, config)

  defp invoke_mutation_request_fun_by_arity({:arity, 5}, fun, request, config),
    do: fun.(request.method, request.path, request.params, request.body, config)

  defp invoke_mutation_request_fun_by_arity({:arity, 4}, fun, request, _config),
    do: fun.(request.method, request.path, request.params, request.body)

  defp invoke_mutation_request_fun_by_arity(_arity, _fun, _request, _config),
    do: {:error, :invalid_request_fun}

  defp perform_mutation_request(config, %{path: path, body: body, headers: headers} = request, opts) do
    envelope = Keyword.get(opts, :provider_mutation_envelope)
    witness_sink = Keyword.get(opts, :dispatch_witness_sink)
    witness_required? = Keyword.get(opts, :dispatch_witness_required?, false)
    witness_timeout_ms = Keyword.get(opts, :dispatch_witness_timeout_ms, ProviderDispatchWitness.default_timeout_ms())

    req_options = [
      method: :patch,
      url: config.base_url <> path,
      headers: headers,
      body: Jason.encode!(body),
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms,
      compressed: false,
      raw: true,
      retry: false,
      redirect: false,
      into: &bounded_response_body/2
    ]

    req_options =
      case Keyword.get(opts, :a4_proof_ready) do
        nil -> req_options
        _ready -> req_options |> Keyword.delete(:connect_options) |> Keyword.put(:finch, @proof_finch_name)
      end

    req_options = attach_request_correlation(req_options, envelope)

    req_options =
      attach_witness_hook(req_options, request, envelope, witness_sink, witness_required?, witness_timeout_ms)

    req_options = attach_witness_transport(req_options, witness_required?)

    case Req.request(req_options) do
      {:ok, %{status: status, headers: response_headers, body: response_body}} ->
        normalize_mutation_response(%{status: status, headers: response_headers, body: response_body})

      {:error, %ProviderDispatchWitness.DispatchError{reason: reason}} ->
        {:error, {:dispatch_witness_failed, reason}}

      {:error, reason} ->
        {:error, mutation_transport_error(reason)}
    end
  end

  defp attach_request_correlation(req_options, %ProviderMutationEnvelope{} = envelope) do
    Keyword.put(
      req_options,
      :finch_private,
      %{ProviderDispatchWitness.private_request_id_key() => envelope.provider_request_id}
    )
  end

  defp attach_request_correlation(req_options, _envelope), do: req_options

  defp attach_witness_hook(req_options, request, %ProviderMutationEnvelope{} = envelope, witness_sink, required?, timeout_ms) do
    Keyword.put(
      req_options,
      :finch_request,
      witnessed_finch_request(request, envelope, witness_sink, required?, timeout_ms)
    )
  end

  defp attach_witness_hook(req_options, _request, _envelope, _witness_sink, _required?, _timeout_ms), do: req_options

  defp attach_witness_transport(req_options, true) do
    req_options
    |> Keyword.put(:adapter, &Req.Steps.run_finch/1)
    |> Keyword.put(:plug, nil)
    |> Keyword.put(:params, [])
    |> Keyword.put(:plugins, [])
  end

  defp attach_witness_transport(req_options, false), do: req_options

  defp witnessed_finch_request(request, envelope, witness_sink, witness_required?, witness_timeout_ms) do
    fn req, finch_request, finch_name, finch_options ->
      transport_fun = fn final_request ->
        stream_bounded_response(req, final_request, finch_name, finch_options)
      end

      result =
        case validate_final_finch_request(request, envelope, finch_request) do
          :ok ->
            ProviderDispatchWitness.dispatch(
              envelope,
              finch_request,
              witness_sink,
              witness_required?,
              transport_fun,
              witness_timeout_ms
            )

          {:error, _reason} = error ->
            error
        end

      case result do
        {req, %Req.Response{} = response} ->
          {req, response}

        {req, %Req.TransportError{} = error} ->
          {req, error}

        {req, %Req.HTTPError{} = error} ->
          {req, error}

        {:error, {:dispatch_witness_failed, reason}} ->
          {req, %ProviderDispatchWitness.DispatchError{reason: reason}}

        {:error, exception} when is_exception(exception) ->
          {req, ReqFinchErrorNormalizer.normalize(exception)}

        _other ->
          {req, Req.TransportError.exception(reason: :provider_unavailable)}
      end
    end
  end

  @spec validate_final_finch_request(map(), ProviderMutationEnvelope.t(), Finch.Request.t()) ::
          :ok | {:error, {:dispatch_witness_failed, :request_identity_mismatch}}
  defp validate_final_finch_request(request, envelope, finch_request) do
    with true <- request.method == :patch,
         true <- finch_request.method in ["PATCH", :patch],
         true <- finch_request.path == request.path,
         true <- finch_request.query in [nil, ""],
         true <- finch_request.body == Jason.encode!(request.body),
         true <-
           Map.get(finch_request.private, ProviderDispatchWitness.private_request_id_key()) ==
             envelope.provider_request_id do
      :ok
    else
      _mismatch -> {:error, {:dispatch_witness_failed, :request_identity_mismatch}}
    end
  end

  defp stream_bounded_response(req, finch_request, finch_name, finch_options) do
    response = Req.Response.new()

    stream_fun = fn
      {:status, status}, {current_req, current_response} ->
        {:cont, {current_req, %{current_response | status: status}}}

      {:headers, fields}, {current_req, current_response} ->
        updated_response =
          Enum.reduce(fields, current_response, fn {name, value}, acc ->
            Req.Response.put_header(acc, name, value)
          end)

        {:cont, {current_req, updated_response}}

      {:data, data}, acc ->
        bounded_response_body({:data, data}, acc)

      {:trailers, fields}, {current_req, current_response} ->
        trailers = Enum.reduce(fields, %{}, fn {name, value}, acc -> Map.update(acc, name, [value], &(&1 ++ [value])) end)
        {:cont, {current_req, %{current_response | trailers: Map.merge(current_response.trailers, trailers)}}}
    end

    ReqFinchErrorNormalizer.normalize_stream_result(
      req,
      Finch.stream_while(finch_request, finch_name, {req, response}, stream_fun, finch_options)
    )
  end

  defp normalize_mutation_response(response) do
    status = Map.get(response, :status, Map.get(response, "status"))

    case valid_status(status) do
      {:ok, status} when status in 200..299 -> {:ok, %{status: status}}
      {:ok, 401} -> {:error, :unauthorized}
      {:ok, 403} -> {:error, :unauthorized}
      {:ok, 404} -> {:error, :not_found}
      {:ok, 429} -> {:error, :rate_limited}
      {:ok, status} when status in 500..599 -> {:error, :provider_unavailable}
      {:ok, status} -> {:error, {:provider_status, status}}
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  end

  defp mutation_acknowledgement(%{status: status}) when status in 200..299, do: :ok
  defp mutation_acknowledgement(_response), do: {:error, :provider_malformed}

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

    req_options = [
      method: :get,
      url: url,
      headers: headers,
      params: params,
      connect_options: [timeout: @connect_timeout_ms],
      receive_timeout: @receive_timeout_ms,
      compressed: false,
      raw: true,
      retry: false,
      redirect: false,
      into: &bounded_response_body/2
    ]

    case Req.request(req_options) do
      {:ok, %{status: status, headers: response_headers, body: body}} ->
        normalize_response(%{status: status, headers: response_headers, body: body})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded_response_body({:data, chunk}, {request, response}) when is_binary(chunk) do
    if byte_size(response.body || "") + byte_size(chunk) > @max_response_bytes,
      do: {:halt, {request, %{response | body: @response_too_large_marker}}},
      else: {:cont, {request, %{response | body: (response.body || "") <> chunk}}}
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

  defp decode_body(@response_too_large_marker), do: {:error, :provider_response_too_large}
  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    if byte_size(body) > @max_response_bytes do
      {:error, :provider_response_too_large}
    else
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _reason} -> {:error, :provider_malformed}
      end
    end
  end

  defp decode_body(_body), do: {:error, :provider_malformed}

  defp valid_status(status) when is_integer(status), do: {:ok, status}
  defp valid_status(_status), do: {:error, :provider_unavailable}

  defp normalize_config(config, opts) do
    base_url = Map.get(config, :base_url)
    base_url = if is_nil(base_url), do: Map.get(config, "base_url", @default_base_url), else: base_url

    workspace_slug = first_present(config, [:workspace_slug, "workspace_slug"])
    workspace_id = first_present(config, [:workspace_id, "workspace_id"])
    project_id = first_present(config, [:project_id, "project_id"])
    api_key = first_present(config, [:api_key, "api_key"])

    allow_test_or_proof_base? =
      Keyword.has_key?(opts, :request_fun) or valid_local_proof_base?(base_url, opts)

    cond do
      not present?(workspace_slug) or not present?(project_id) ->
        {:error, :invalid_scope}

      not present?(api_key) ->
        {:error, :missing_credential}

      validate_base_url(base_url, allow_test_or_proof_base?) != :ok ->
        {:error, :invalid_base_url}

      true ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           workspace_slug: workspace_slug,
           workspace_id: workspace_id,
           project_id: project_id,
           api_key: api_key
         }}
    end
  end

  defp validate_base_url(value, test_request?) when is_binary(value) do
    normalized = String.trim_trailing(value, "/")

    case parse_base_url_uri(normalized) do
      {:https, _} when normalized == @default_base_url or test_request? -> :ok
      {:https, _} -> :error
      {:http, _} when test_request? -> :ok
      {:http, _} -> :error
      :invalid -> :error
    end
  end

  defp validate_base_url(_value, _test_request?), do: :error

  defp valid_local_proof_base?(base_url, opts) do
    case Keyword.get(opts, :a4_session) do
      %{manifest: manifest} when is_map(manifest) ->
        uri = URI.parse(base_url)
        authority = proof_authority(uri)

        manifest_value(manifest, :origin_kind) in [:local_qualification, "local_qualification"] and
          manifest_value(manifest, :origin_base_url) == base_url and
          manifest_value(manifest, :origin_authority) == authority and
          uri.scheme == "https" and uri.host in ["127.0.0.1", "localhost", "::1"] and
          is_integer(uri.port) and uri.port in 1..65_535

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp parse_base_url_uri(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        {:https, host}

      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        {:http, host}

      _ ->
        :invalid
    end
  end

  defp project_path(config), do: "/api/v1/workspaces/#{encoded(config.workspace_slug)}/projects/#{encoded(config.project_id)}/"
  defp work_item_path(config, id), do: work_items_path(config) <> encoded(id) <> "/"
  defp relation_path(config, id), do: work_items_path(config) <> encoded(id) <> "/relations/"
  defp work_items_path(config), do: project_path(config) <> "work-items/"
  defp states_path(config), do: project_path(config) <> "states/"

  defp state_expansion_params, do: %{"expand" => "state,assignees"}

  defp work_item_params do
    state_expansion_params()
    |> Map.put("per_page", @page_size)
    |> Map.put("fields", @work_item_fields)
  end

  defp state_params, do: %{"per_page" => @page_size, "fields" => @state_fields}
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
    retry_after_seconds = header_value(headers, "retry-after") |> parse_seconds()
    reset_at_unix = header_value(headers, "x-ratelimit-reset") |> parse_integer()

    %{
      retry_after: retry_after_seconds,
      retry_after_seconds: retry_after_seconds,
      reset_at_unix: reset_at_unix
    }
  end

  defp header_value(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if header_name(key) == name, do: value
      _malformed -> nil
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if header_name(key) == name, do: value
      _malformed -> nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp header_name(key) when is_binary(key), do: String.downcase(key)
  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(_key), do: nil

  defp parse_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_integer([value | _rest]), do: parse_integer(value)

  defp parse_integer(_value), do: nil

  defp parse_seconds(value) when is_integer(value) and value >= 0, do: value
  defp parse_seconds(value) when is_float(value) and value >= 0, do: value

  defp parse_seconds(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} when integer >= 0 ->
        integer

      _ ->
        case Float.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds
          _ -> nil
        end
    end
  end

  defp parse_seconds([value | _rest]), do: parse_seconds(value)
  defp parse_seconds(_value), do: nil

  defp transport_error(%Error{kind: kind}), do: kind
  defp transport_error(_reason), do: :provider_unavailable

  defp mutation_transport_error(%Error{kind: kind}), do: kind
  defp mutation_transport_error(kind) when kind in [:econnrefused, :timeout, :closed], do: kind
  defp mutation_transport_error(%{reason: reason}) when reason in [:econnrefused, :timeout, :closed], do: reason
  defp mutation_transport_error(%{reason: %{reason: reason}}) when reason in [:econnrefused, :timeout, :closed], do: reason
  defp mutation_transport_error(_reason), do: :provider_unavailable
end
