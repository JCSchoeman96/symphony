defmodule SymphonyElixir.Plane.ReadScheduler do
  @moduledoc """
  Operational coordination for bounded Plane GET work.

  The scheduler owns permits, pacing, retry and throttle observations. It has
  no lifecycle authority and never resubmits a mutation.
  """

  use GenServer
  require Logger

  @default_max_concurrency 4
  @default_queue_limit 64
  @default_start_limit 60
  @default_start_window_ms 60_000
  @default_backoff_base_ms 250
  @default_max_backoff_ms 60_000
  @default_throttle_fallback_ms 60_000
  @remaining_safety_floor 4
  @minimum_delay_ms 1
  @default_wait_timeout_ms 240_000
  @max_wait_timeout_ms 240_000
  @max_admission_timeout_ms 5_000

  @transient_transport_reasons [
    :closed,
    :econnrefused,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :nxdomain,
    :timeout,
    :timedout
  ]

  @type server :: GenServer.server()
  @type request_class :: :control | :bulk | :dependency
  @type request_fun :: (-> {:ok, term()} | {:error, term()})
  @type result :: {:ok, term()} | {:error, term()}
  @type stats :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    start_opts = if Keyword.has_key?(opts, :name), do: [name: opts[:name]], else: []

    case normalize_server_opts(opts) do
      {:ok, _config} -> GenServer.start_link(__MODULE__, opts, start_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec execute(server(), request_class(), request_fun(), keyword()) :: result()
  def execute(server, class, fun, opts \\ []) when is_function(fun, 0) and is_list(opts) do
    with {:ok, class} <- normalize_class(class),
         {:ok, request_opts} <- normalize_request_opts(opts),
         {:ok, scheduler_monitor} <- monitor_server(server) do
      request_ref = make_ref()
      result = submit_and_wait(server, request_ref, class, fun, request_opts, scheduler_monitor)
      Process.demonitor(scheduler_monitor, [:flush])
      result
    end
  end

  defp submit_and_wait(server, request_ref, class, fun, opts, scheduler_monitor) do
    case admit(server, request_ref, class, fun, opts) do
      {:ok, ^request_ref} ->
        await_result(server, request_ref, scheduler_monitor, opts[:wait_timeout])

      {:error, _reason} = error ->
        error
    end
  end

  @spec stats(server()) :: stats()
  def stats(server), do: GenServer.call(server, :stats)

  @impl GenServer
  @spec init(keyword()) :: {:ok, map()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)

    case normalize_server_opts(opts) do
      {:ok, config} ->
        {:ok,
         Map.merge(config, %{
           queue: [],
           backoff: %{},
           in_flight: %{},
           caller_monitors: %{},
           starts: [],
           throttle_until: nil,
           throttle_token: nil,
           pacing_token: nil,
           metrics: initial_metrics()
         })}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:submit, caller, request_ref, class, fun, request_opts}, _from, state) do
    if admission_available?(state) do
      caller_monitor = Process.monitor(caller)

      entry = %{
        ref: request_ref,
        caller: caller,
        caller_monitor: caller_monitor,
        class: class,
        fun: fun,
        epoch_id: request_opts[:epoch_id],
        request_metrics: request_opts[:request_metrics],
        retry?: request_opts[:retry?],
        attempt: 0
      }

      state =
        state
        |> Map.update!(:queue, &(&1 ++ [entry]))
        |> put_in([:caller_monitors, caller_monitor], request_ref)
        |> update_in([:metrics, :logical_requests], &(&1 + 1))
        |> dispatch()

      {:reply, {:ok, request_ref}, state}
    else
      {:reply, {:error, :at_capacity}, state}
    end
  end

  def handle_call({:cancel, request_ref, caller}, _from, state) do
    case find_request(state, request_ref) do
      {:ok, entry, location} when entry.caller == caller ->
        {:reply, :ok, state |> remove_request(entry, location) |> dispatch()}

      _missing ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, stats_snapshot(state), state}

  @impl GenServer
  def handle_info({:attempt_result, request_ref, task_pid, attempt, result}, state) do
    case Map.get(state.in_flight, request_ref) do
      %{task_pid: ^task_pid, attempt: ^attempt} = entry ->
        state
        |> finish_attempt(entry)
        |> handle_result(entry, result)
        |> dispatch()
        |> then(&{:noreply, &1})

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_ready, request_ref, token}, state) do
    case Map.get(state.backoff, request_ref) do
      %{retry_token: ^token} = entry ->
        state = %{state | backoff: Map.delete(state.backoff, request_ref)}
        {:noreply, dispatch(%{state | queue: state.queue ++ [entry]})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:throttle_expired, token}, %{throttle_token: token} = state) do
    {:noreply, dispatch(%{state | throttle_until: nil, throttle_token: nil})}
  end

  def handle_info({:throttle_expired, _stale}, state), do: {:noreply, state}

  def handle_info({:pacing_expired, token}, %{pacing_token: token} = state) do
    {:noreply, dispatch(%{state | pacing_token: nil})}
  end

  def handle_info({:pacing_expired, _stale}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Map.pop(state.caller_monitors, monitor) do
      {request_ref, caller_monitors} when is_reference(request_ref) ->
        state = %{state | caller_monitors: caller_monitors}

        case find_request(state, request_ref) do
          {:ok, entry, location} ->
            {:noreply, state |> remove_request(entry, location) |> dispatch()}

          :missing ->
            {:noreply, state}
        end

      {nil, _caller_monitors} ->
        handle_task_down(monitor, reason, state)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(all_entries(state), fn entry ->
      if Process.alive?(entry.caller), do: send_result(entry.caller, entry.ref, {:error, :scheduler_terminated})
      if Map.has_key?(entry, :task_pid), do: Process.exit(entry.task_pid, :kill)
      if Map.has_key?(entry, :task_pid), do: decrement_epoch_concurrency(entry)
    end)

    Enum.each(state.in_flight, fn {_ref, entry} -> Process.demonitor(entry.task_monitor, [:flush]) end)
    Enum.each(state.caller_monitors, fn {monitor, _ref} -> Process.demonitor(monitor, [:flush]) end)
    :ok
  end

  defp admit(server, request_ref, class, fun, opts) do
    GenServer.call(server, {:submit, self(), request_ref, class, fun, opts}, opts[:admission_timeout])
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  defp await_result(server, request_ref, scheduler_monitor, timeout) do
    receive do
      {:plane_read_scheduler, ^request_ref, result} -> result
      {:DOWN, ^scheduler_monitor, :process, _pid, _reason} -> {:error, :scheduler_terminated}
    after
      timeout ->
        _ = cancel(server, request_ref, self())
        flush_result(request_ref)
        {:error, :wait_timeout}
    end
  end

  defp cancel(server, request_ref, caller) do
    GenServer.call(server, {:cancel, request_ref, caller}, 5_000)
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  defp monitor_server(server) do
    case scheduler_pid(server) do
      pid when is_pid(pid) -> {:ok, Process.monitor(pid)}
      _missing -> {:error, :scheduler_unavailable}
    end
  catch
    :exit, _reason -> {:error, :scheduler_unavailable}
  end

  defp scheduler_pid(server) when is_pid(server), do: server
  defp scheduler_pid(server), do: GenServer.whereis(server)

  defp flush_result(request_ref) do
    receive do
      {:plane_read_scheduler, ^request_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp normalize_class(class) when class in [:control, :bulk, :dependency], do: {:ok, class}
  defp normalize_class(_class), do: {:error, :invalid_read_class}

  defp normalize_request_opts(opts) do
    retry? = Keyword.get(opts, :retry?, Keyword.get(opts, :retry, true))
    wait_timeout = Keyword.get(opts, :wait_timeout, @default_wait_timeout_ms)
    admission_timeout = Keyword.get(opts, :admission_timeout, 5_000)

    if is_boolean(retry?) and valid_wait_timeout?(wait_timeout) and valid_admission_timeout?(admission_timeout) do
      {:ok,
       Keyword.merge(opts,
         retry?: retry?,
         wait_timeout: wait_timeout,
         admission_timeout: admission_timeout
       )}
    else
      {:error, :invalid_request_options}
    end
  end

  defp valid_wait_timeout?(timeout), do: is_integer(timeout) and timeout >= 0 and timeout <= @max_wait_timeout_ms
  defp valid_admission_timeout?(timeout), do: is_integer(timeout) and timeout >= 0 and timeout <= @max_admission_timeout_ms

  defp normalize_server_opts(opts) do
    values = %{
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      queue_limit: Keyword.get(opts, :queue_limit, @default_queue_limit),
      start_limit: Keyword.get(opts, :start_limit, Keyword.get(opts, :starts_per_minute, @default_start_limit)),
      start_window_ms: Keyword.get(opts, :start_window_ms, @default_start_window_ms),
      backoff_base_ms: Keyword.get(opts, :backoff_base_ms, @default_backoff_base_ms),
      max_backoff_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms),
      throttle_fallback_ms: Keyword.get(opts, :throttle_fallback_ms, @default_throttle_fallback_ms)
    }

    with :ok <- validate_server_options(values) do
      {:ok, %{values | throttle_fallback_ms: min(values.throttle_fallback_ms, values.max_backoff_ms)}}
    end
  end

  defp validate_server_options(values) do
    with :ok <- validate_nonnegative_options(values),
         :ok <- validate_max_concurrency(values.max_concurrency),
         :ok <- validate_start_limit(values.start_limit),
         :ok <- validate_start_window(values.start_window_ms) do
      validate_backoff_limit(values.max_backoff_ms)
    end
  end

  defp validate_nonnegative_options(values) do
    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: :ok,
      else: {:error, :invalid_scheduler_options}
  end

  defp validate_max_concurrency(value) when value in 1..4, do: :ok
  defp validate_max_concurrency(_value), do: {:error, :invalid_concurrency_limit}

  defp validate_start_limit(value) when value in 1..60, do: :ok
  defp validate_start_limit(_value), do: {:error, :invalid_start_limit}

  defp validate_start_window(value) when value >= 1, do: :ok
  defp validate_start_window(_value), do: {:error, :invalid_start_window}

  defp validate_backoff_limit(value) when value in 1..60_000, do: :ok
  defp validate_backoff_limit(_value), do: {:error, :invalid_backoff_limit}

  defp admission_available?(state) do
    waiting = length(state.queue) + map_size(state.backoff)
    waiting < state.queue_limit or can_start_now?(state)
  end

  defp can_start_now?(state) do
    map_size(state.in_flight) < state.max_concurrency and
      not throttle_active?(state, now_ms()) and
      not pacing_exhausted?(state)
  end

  defp dispatch(state) do
    state = clear_expired_throttle(purge_starts(state, now_ms()))

    cond do
      state.queue == [] ->
        state

      map_size(state.in_flight) >= state.max_concurrency ->
        state

      throttle_active?(state, now_ms()) ->
        schedule_throttle_timer(state)

      pacing_exhausted?(state) ->
        schedule_pacing_timer(state)

      true ->
        {entry, queue} = pop_next(state.queue)
        dispatch(start_attempt(%{state | queue: queue}, entry))
    end
  end

  defp pop_next(queue) do
    case Enum.split_while(queue, &(&1.class != :control)) do
      {before, [entry | after_entry]} -> {entry, before ++ after_entry}
      {_bulk, []} -> {hd(queue), tl(queue)}
    end
  end

  defp start_attempt(state, entry) do
    attempt = entry.attempt + 1
    scheduler = self()

    {task_pid, task_monitor} =
      :erlang.spawn_opt(
        fn ->
          result = invoke(entry.fun)
          send(scheduler, {:attempt_result, entry.ref, self(), attempt, result})
        end,
        [:link, :monitor]
      )

    entry = Map.merge(entry, %{attempt: attempt, task_pid: task_pid, task_monitor: task_monitor})
    epoch_concurrency = increment_epoch_concurrency(entry)
    update_epoch_peak(entry, epoch_concurrency)

    state
    |> Map.put(:in_flight, Map.put(state.in_flight, entry.ref, entry))
    |> Map.update!(:starts, &[now_ms() | &1])
    |> update_in([:metrics, :attempts], &(&1 + 1))
    |> update_in([:metrics, :peak_concurrency], &max(&1, map_size(state.in_flight) + 1))
  end

  defp invoke(fun) do
    fun.()
  catch
    kind, reason -> {:error, {:request_failed, kind, reason}}
  end

  defp finish_attempt(state, entry) do
    Process.demonitor(entry.task_monitor, [:flush])
    decrement_epoch_concurrency(entry)
    %{state | in_flight: Map.delete(state.in_flight, entry.ref)}
  end

  defp handle_result(state, entry, result) do
    metadata = response_metadata(result)
    outcome = classify(result)
    state = observe(state, metadata, outcome)

    if outcome == :throttle do
      increment_epoch_metric(entry.request_metrics, 6, 1)

      Logger.warning("Plane GET received HTTP 429",
        epoch_id: entry.epoch_id,
        request_class: entry.class,
        attempt: entry.attempt,
        retry_after_seconds: metadata.retry_after_seconds,
        rate_limit_reset_at: metadata.reset_at_unix,
        rate_limit_remaining: metadata.remaining
      )
    end

    if entry.retry? and entry.attempt == 1 and outcome in [:throttle, :transient] do
      delay = retry_delay(state, metadata, outcome)
      increment_epoch_metric(entry.request_metrics, 7, 1)
      increment_epoch_metric(entry.request_metrics, 8, delay)
      retry_entry(state, entry, delay)
    else
      send_result(entry.caller, entry.ref, result)
      remove_caller_monitor(state, entry)
    end
  end

  defp retry_entry(state, entry, delay) do
    token = make_ref()
    Process.send_after(self(), {:retry_ready, entry.ref, token}, delay)

    state
    |> put_in([:backoff, entry.ref], Map.put(entry, :retry_token, token))
    |> update_in([:metrics, :retries], &(&1 + 1))
    |> update_in([:metrics, :backoff_count], &(&1 + 1))
    |> update_in([:metrics, :total_backoff_ms], &(&1 + delay))
    |> update_in([:metrics, :max_backoff_ms], &max(&1, delay))
  end

  defp retry_delay(state, metadata, outcome) do
    hinted = Enum.max([metadata.retry_after_ms || 0, metadata.reset_delay_ms || 0])
    fallback = if outcome == :throttle, do: state.throttle_fallback_ms, else: state.backoff_base_ms
    min(Enum.max([hinted, fallback, @minimum_delay_ms]), state.max_backoff_ms)
  end

  defp observe(state, metadata, outcome) do
    state =
      update_in(state, [:metrics], fn metrics ->
        metrics
        |> put_if_present(:last_retry_after_seconds, metadata.retry_after_seconds)
        |> put_if_present(:last_retry_after_ms, metadata.retry_after_ms)
        |> put_if_present(:last_rate_limit_reset_at, metadata.reset_at_unix)
        |> put_if_present(:last_rate_limit_remaining, metadata.remaining)
      end)

    pause_for_safety_floor? = is_integer(metadata.remaining) and metadata.remaining <= @remaining_safety_floor

    state =
      if pause_for_safety_floor? and not metadata.throttle? do
        update_in(state, [:metrics, :safety_pause_count], &(&1 + 1))
      else
        state
      end

    if outcome == :throttle or pause_for_safety_floor?, do: throttle(state, metadata), else: state
  end

  defp throttle(state, metadata) do
    delay =
      Enum.max([
        metadata.retry_after_ms || 0,
        metadata.reset_delay_ms || 0,
        state.throttle_fallback_ms,
        @minimum_delay_ms
      ])
      |> min(state.max_backoff_ms)

    until = now_ms() + delay
    until = if state.throttle_until, do: max(state.throttle_until, until), else: until
    token = make_ref()
    Process.send_after(self(), {:throttle_expired, token}, max(until - now_ms(), 1))

    state
    |> Map.merge(%{throttle_until: until, throttle_token: token})
    |> update_in([:metrics, :throttle_count], &(&1 + if(metadata.throttle?, do: 1, else: 0)))
  end

  defp classify(result) do
    status = status_from(result)

    cond do
      status == 429 or rate_limited?(result) -> :throttle
      is_integer(status) and status in 500..599 -> :transient
      provider_unavailable?(result) -> :transient
      known_transport?(result) -> :transient
      true -> :final
    end
  end

  defp status_from({:ok, value}), do: status_from(value)
  defp status_from({:error, value}), do: status_from(value)
  defp status_from(%{status: value}) when is_integer(value), do: value
  defp status_from(%{"status" => value}) when is_integer(value), do: value
  defp status_from({:provider_status, value}) when is_integer(value), do: value
  defp status_from({:http_error, value, _details}) when is_integer(value), do: value
  defp status_from(_value), do: nil

  defp rate_limited?({:error, :rate_limited}), do: true
  defp rate_limited?({:error, {:rate_limited, _metadata}}), do: true
  defp rate_limited?(_value), do: false

  defp provider_unavailable?({:error, :provider_unavailable}), do: true
  defp provider_unavailable?(_value), do: false

  defp known_transport?({:error, reason}), do: known_transport_reason?(reason)
  defp known_transport?(_value), do: false

  defp known_transport_reason?(reason) when reason in @transient_transport_reasons, do: true
  defp known_transport_reason?({:transport_error, reason}), do: known_transport_reason?(reason)
  defp known_transport_reason?(%{reason: reason}), do: known_transport_reason?(reason)
  defp known_transport_reason?(%{kind: kind}), do: known_transport_reason?(kind)
  defp known_transport_reason?(_reason), do: false

  defp response_metadata(result) do
    source = response_source(result)
    headers = response_headers(source)
    retry_value = rate_limit_value(headers, source, "retry-after", [:retry_after_seconds, :retry_after])
    reset_value = rate_limit_value(headers, source, "x-ratelimit-reset", [:reset_at_unix, :reset_at])
    remaining_value = rate_limit_value(headers, source, "x-ratelimit-remaining", [:remaining])
    retry_after_seconds = parse_seconds(retry_value)
    reset_at_unix = parse_integer(reset_value)
    remaining = parse_integer(remaining_value)

    %{
      retry_after_seconds: retry_after_seconds,
      retry_after_ms: if(is_number(retry_after_seconds), do: round(retry_after_seconds * 1_000)),
      reset_at_unix: reset_at_unix,
      reset_delay_ms: reset_delay_ms(reset_at_unix),
      remaining: remaining,
      throttle?: throttled_result?(result)
    }
  end

  defp response_source({:ok, value}), do: value
  defp response_source({:error, {:rate_limited, value}}), do: value
  defp response_source({:error, value}), do: value
  defp response_source(_result), do: nil

  defp response_headers(source) when is_map(source), do: Map.get(source, :headers, Map.get(source, "headers", %{}))
  defp response_headers(_source), do: %{}

  defp rate_limit_value(headers, source, header, keys) do
    header_value(headers, header) || map_value(source, keys ++ Enum.map(keys, &Atom.to_string/1))
  end

  defp reset_delay_ms(reset_at_unix) when is_integer(reset_at_unix) do
    max(reset_at_unix * 1_000 - System.system_time(:millisecond), @minimum_delay_ms)
  end

  defp reset_delay_ms(_reset_at_unix), do: nil

  defp throttled_result?(result), do: status_from(result) == 429 or rate_limited?(result)

  defp header_value(headers, name) when is_map(headers) or is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} ->
        if header_name(key) == name, do: first_header_value(value)

      _malformed ->
        nil
    end)
  end

  defp header_value(_headers, _name), do: nil

  defp header_name(key) when is_binary(key), do: String.downcase(key)

  defp header_name(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.replace("_", "-") |> String.downcase()

  defp header_name(_key), do: nil
  defp first_header_value([value | _rest]) when is_binary(value) or is_integer(value) or is_float(value), do: value
  defp first_header_value(value), do: value

  defp map_value(source, keys) when is_map(source), do: Enum.find_value(keys, &Map.get(source, &1))
  defp map_value(_source, _keys), do: nil

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

  defp parse_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_integer([value | _rest]), do: parse_integer(value)
  defp parse_integer(_value), do: nil

  defp handle_task_down(monitor, reason, state) do
    case Enum.find(state.in_flight, fn {_ref, entry} -> entry.task_monitor == monitor end) do
      {request_ref, entry} ->
        Process.demonitor(entry.caller_monitor, [:flush])
        decrement_epoch_concurrency(entry)
        state = %{state | in_flight: Map.delete(state.in_flight, request_ref), caller_monitors: Map.delete(state.caller_monitors, entry.caller_monitor)}
        if Process.alive?(entry.caller), do: send_result(entry.caller, entry.ref, {:error, {:request_terminated, reason}})
        {:noreply, dispatch(state)}

      nil ->
        {:noreply, state}
    end
  end

  defp find_request(state, ref) do
    cond do
      entry = Enum.find(state.queue, &(&1.ref == ref)) -> {:ok, entry, :queue}
      entry = Map.get(state.backoff, ref) -> {:ok, entry, :backoff}
      entry = Map.get(state.in_flight, ref) -> {:ok, entry, :in_flight}
      true -> :missing
    end
  end

  defp remove_request(state, entry, :queue), do: demonitor_caller(state, entry, %{state | queue: Enum.reject(state.queue, &(&1.ref == entry.ref))})
  defp remove_request(state, entry, :backoff), do: demonitor_caller(state, entry, %{state | backoff: Map.delete(state.backoff, entry.ref)})

  defp remove_request(state, entry, :in_flight) do
    Process.exit(entry.task_pid, :kill)
    Process.demonitor(entry.task_monitor, [:flush])
    decrement_epoch_concurrency(entry)
    demonitor_caller(state, entry, %{state | in_flight: Map.delete(state.in_flight, entry.ref)})
  end

  defp demonitor_caller(_state, entry, state) do
    Process.demonitor(entry.caller_monitor, [:flush])
    update_in(state, [:caller_monitors], &Map.delete(&1, entry.caller_monitor))
  end

  defp remove_caller_monitor(state, entry) do
    Process.demonitor(entry.caller_monitor, [:flush])
    update_in(state, [:caller_monitors], &Map.delete(&1, entry.caller_monitor))
  end

  defp send_result(caller, ref, result), do: send(caller, {:plane_read_scheduler, ref, result})
  defp all_entries(state), do: state.queue ++ Map.values(state.backoff) ++ Map.values(state.in_flight)

  defp clear_expired_throttle(%{throttle_until: until} = state) when is_integer(until) do
    if until <= now_ms(), do: %{state | throttle_until: nil, throttle_token: nil}, else: state
  end

  defp clear_expired_throttle(state), do: state
  defp purge_starts(state, now), do: %{state | starts: Enum.filter(state.starts, &(now - &1 < state.start_window_ms))}
  defp pacing_exhausted?(state), do: length(state.starts) >= state.start_limit
  defp throttle_active?(state, now), do: is_integer(state.throttle_until) and state.throttle_until > now

  defp schedule_throttle_timer(state) do
    if is_nil(state.throttle_token) do
      token = make_ref()
      Process.send_after(self(), {:throttle_expired, token}, max(state.throttle_until - now_ms(), 1))
      %{state | throttle_token: token}
    else
      state
    end
  end

  defp schedule_pacing_timer(%{pacing_token: nil} = state) do
    delay = max(Enum.min(state.starts) + state.start_window_ms - now_ms(), 1)
    token = make_ref()
    Process.send_after(self(), {:pacing_expired, token}, delay)
    %{state | pacing_token: token}
  end

  defp schedule_pacing_timer(state), do: state

  defp stats_snapshot(state) do
    now = now_ms()
    metrics = state.metrics
    queued = state.queue ++ Map.values(state.backoff)
    queued_control = Enum.count(queued, &(&1.class == :control))

    metrics
    |> Map.put(:current_concurrency, map_size(state.in_flight))
    |> Map.put(:queue_length, length(queued))
    |> Map.put(:queued_control, queued_control)
    |> Map.put(:queued_bulk, length(queued) - queued_control)
    |> Map.put(:throttled, throttle_active?(state, now))
    |> Map.put(:throttle_until_ms, state.throttle_until)
    |> Map.put(:starts_in_window, Enum.count(state.starts, &(now - &1 < state.start_window_ms)))
    |> Map.put(:logical_read_count, metrics.logical_requests)
    |> Map.put(:request_attempt_count, metrics.attempts)
    |> Map.put(:retry_count, metrics.retries)
  end

  defp initial_metrics do
    %{
      logical_requests: 0,
      attempts: 0,
      retries: 0,
      current_concurrency: 0,
      peak_concurrency: 0,
      throttle_count: 0,
      safety_pause_count: 0,
      backoff_count: 0,
      total_backoff_ms: 0,
      max_backoff_ms: 0,
      queue_length: 0,
      queued_control: 0,
      queued_bulk: 0,
      throttled: false,
      throttle_until_ms: nil,
      last_retry_after_seconds: nil,
      last_retry_after_ms: nil,
      last_rate_limit_reset_at: nil,
      last_rate_limit_remaining: nil,
      starts_in_window: 0,
      logical_read_count: 0,
      request_attempt_count: 0,
      retry_count: 0
    }
  end

  defp increment_epoch_concurrency(%{request_metrics: metrics}) do
    case atomics_size(metrics) do
      size when size >= 4 -> :atomics.add_get(metrics, 3, 1)
      _small_or_missing -> nil
    end
  end

  defp update_epoch_peak(%{request_metrics: metrics}, current) when is_integer(current) do
    if atomics_size(metrics) >= 4, do: update_atomic_max(metrics, 4, current)
  end

  defp update_epoch_peak(_entry, _current), do: :ok

  defp decrement_epoch_concurrency(%{request_metrics: metrics}) do
    if atomics_size(metrics) >= 4, do: :atomics.sub(metrics, 3, 1)
  end

  defp increment_epoch_metric(metrics, index, value) when is_integer(value) and value >= 0 do
    if atomics_size(metrics) >= index, do: :atomics.add(metrics, index, value)
  end

  defp atomics_size(metrics) when is_reference(metrics) do
    case :erlang.apply(:atomics, :info, [metrics]) do
      %{size: size} when is_integer(size) -> size
      _unknown -> 0
    end
  rescue
    _error -> 0
  end

  defp atomics_size(_metrics), do: 0

  defp update_atomic_max(metrics, index, value) do
    current = :atomics.get(metrics, index)

    if current < value do
      case :atomics.compare_exchange(metrics, index, current, value) do
        :ok -> :ok
        ^current -> update_atomic_max(metrics, index, value)
        _other -> update_atomic_max(metrics, index, value)
      end
    else
      :ok
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
