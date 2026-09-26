defmodule SymphonyElixir.AgentRuntime.AttemptLedger do
  @moduledoc """
  Small disk-backed boundary for safety-relevant attempt lineage state.

  The ledger is deliberately not a scheduler or a source of current tracker
  truth. It stores only the counters and exhaustion state needed to preserve
  autonomous safety decisions across a process restart.
  """

  alias SymphonyElixir.AgentRuntime.AttemptPolicy
  alias SymphonyElixir.Config.Schema

  @schema_version 1
  @durable_counter_keys [:ordinary_failures, :ordinary_retries, :review_cycles]
  @base_record_keys [
    :schema_version,
    :project_namespace,
    :issue_id,
    :lineage_id,
    :safety_counters,
    :status,
    :stop_reason,
    :route_fingerprint,
    :in_flight,
    :close_pending,
    :updated_at
  ]
  @history_record_keys @base_record_keys ++ [:closed_reason, :rearm_reason, :rearmed_by, :rearmed_at]
  @allowed_identity_keys [:tracker_kind, :provider_scope]
  @allowed_scope_keys [:project_slug, :repo, :project_key, :project_gid, :workspace_slug, :workspace_id, :project_id]

  defstruct [:table, :path, :project_id, :tracker_identity, :write_fun, :sync_fun]

  @type t :: %__MODULE__{
          table: term(),
          path: Path.t(),
          project_id: String.t(),
          tracker_identity: map(),
          write_fun: (atom(), term() -> term()),
          sync_fun: (atom() -> term())
        }

  @type record :: %{atom() => term()}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec path_for(String.t(), keyword()) :: Path.t()
  def path_for(project_id, opts \\ []) when is_binary(project_id) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        Path.expand(path)

      _ ->
        root =
          Keyword.get(opts, :root) ||
            Application.get_env(:symphony_elixir, :attempt_ledger_root) ||
            default_root()

        Path.join(Path.expand(root), project_id <> ".dets")
    end
  end

  @spec open(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(project_id, tracker_identity, opts \\ [])
      when is_binary(project_id) and is_map(tracker_identity) do
    with :ok <- validate_project_id(project_id),
         :ok <- validate_tracker_identity(tracker_identity),
         path <- path_for(project_id, opts),
         :ok <- ensure_parent_directory(path),
         {:ok, table} <- open_table(path) do
      result =
        with {:ok, ledger} <- build_ledger(table, path, project_id, tracker_identity, opts),
             :ok <- initialize_or_validate(ledger) do
          {:ok, ledger}
        end

      case result do
        {:ok, _ledger} ->
          result

        {:error, _reason} = error ->
          _ = close_table(table)
          error
      end
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{table: table}) do
    close_table(table)
  end

  @spec current(t(), String.t()) :: {:ok, record()} | :not_found | {:error, term()}
  def current(%__MODULE__{table: table} = ledger, issue_id) when is_binary(issue_id) do
    case safe_lookup(table, {:current, issue_id}) do
      {:ok, [{_, record}]} ->
        case validate_record(record, ledger, issue_id, allowed_record_keys(record)) do
          :ok -> {:ok, record}
          {:error, reason} -> {:error, reason}
        end

      {:ok, []} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec open_lineages(t()) :: {:ok, [record()]} | {:error, term()}
  def open_lineages(%__MODULE__{} = ledger) do
    with {:ok, records} <- all_records(ledger) do
      records
      |> Enum.filter(fn {key, record} ->
        match?({:current, _issue_id}, key) and
          (Map.get(record, :status) in [:open, :exhausted] or Map.get(record, :close_pending, false))
      end)
      |> Enum.map(&elem(&1, 1))
      |> then(&{:ok, Enum.sort_by(&1, fn record -> record.issue_id end)})
    end
  end

  @spec history(t()) :: {:ok, [record()]} | {:error, term()}
  def history(%__MODULE__{} = ledger) do
    with {:ok, records} <- all_records(ledger) do
      records
      |> Enum.filter(&match?({{:history, _lineage_id}, _record}, &1))
      |> Enum.map(&elem(&1, 1))
      |> then(&{:ok, Enum.sort_by(&1, fn record -> record.updated_at end)})
    end
  end

  @spec put(t(), record()) :: :ok | {:error, term()}
  def put(%__MODULE__{} = ledger, record) when is_map(record) do
    with :ok <- validate_record(record, ledger, Map.get(record, :issue_id), @base_record_keys),
         issue_id when is_binary(issue_id) <- Map.get(record, :issue_id),
         :ok <- persist_status_allowed?(ledger, issue_id, Map.get(record, :status)) do
      persist_records(ledger, [{{:current, issue_id}, record}])
    else
      nil -> {:error, {:corrupt_attempt_record, :current, :invalid_record}}
      {:error, reason} -> {:error, reason}
    end
  end

  def put(_ledger, _record), do: {:error, {:corrupt_attempt_record, :current, :invalid_record}}

  @spec begin_attempt(t(), String.t()) :: {:ok, record()} | {:error, term()}
  def begin_attempt(ledger, issue_id), do: begin_attempt(ledger, issue_id, [])

  @spec begin_attempt(t(), String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def begin_attempt(%__MODULE__{} = ledger, issue_id, opts) when is_binary(issue_id) do
    case current(ledger, issue_id) do
      {:ok, %{status: :exhausted}} ->
        {:error, :lineage_exhausted}

      {:ok, %{status: :open, in_flight: true}} ->
        {:error, :attempt_in_flight}

      {:ok, %{status: :closed, close_pending: true}} ->
        {:error, :lineage_close_pending}

      {:ok, %{status: :open, safety_counters: counters}} ->
        persist_safety(ledger, issue_id, counters,
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      {:ok, %{status: :closed}} ->
        persist_safety(ledger, issue_id, durable_counter_defaults(),
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      :not_found ->
        persist_safety(ledger, issue_id, durable_counter_defaults(),
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def begin_attempt(_ledger, _issue_id, _opts), do: {:error, :invalid_attempt_arguments}

  @spec fence_attempt(t(), String.t()) :: {:ok, record()} | {:error, term()}
  def fence_attempt(ledger, issue_id), do: fence_attempt(ledger, issue_id, [])

  @spec fence_attempt(t(), String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def fence_attempt(%__MODULE__{} = ledger, issue_id, opts) when is_binary(issue_id) do
    case current(ledger, issue_id) do
      {:ok, %{status: :exhausted}} ->
        {:error, :lineage_exhausted}

      {:ok, %{status: :closed, close_pending: true}} ->
        {:error, :lineage_close_pending}

      {:ok, %{status: :open, safety_counters: counters} = record} ->
        persist_safety(ledger, issue_id, counters,
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint, Map.get(record, :route_fingerprint)),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      {:ok, %{status: :closed}} ->
        persist_safety(ledger, issue_id, durable_counter_defaults(),
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      :not_found ->
        persist_safety(ledger, issue_id, durable_counter_defaults(),
          status: :open,
          stop_reason: nil,
          route_fingerprint: Keyword.get(opts, :route_fingerprint),
          in_flight: true,
          updated_at: Keyword.get(opts, :updated_at, now_ms())
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fence_attempt(_ledger, _issue_id, _opts), do: {:error, :invalid_attempt_arguments}

  @spec clear_in_flight(t(), String.t()) :: :ok | {:error, term()}
  def clear_in_flight(ledger, issue_id), do: clear_in_flight(ledger, issue_id, [])

  @spec clear_in_flight(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def clear_in_flight(%__MODULE__{} = ledger, issue_id, opts) when is_binary(issue_id) do
    case current(ledger, issue_id) do
      :not_found ->
        :ok

      {:ok, %{status: :closed}} ->
        :ok

      {:ok, %{status: :open, in_flight: false}} ->
        :ok

      {:ok, record} ->
        record =
          record
          |> Map.put(:in_flight, false)
          |> Map.put(:updated_at, Keyword.get(opts, :updated_at, now_ms()))

        with :ok <- validate_record(record, ledger, issue_id, @base_record_keys) do
          persist_records(ledger, [{{:current, issue_id}, record}])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def clear_in_flight(_ledger, _issue_id, _opts), do: {:error, :invalid_attempt_arguments}

  @spec sync(t()) :: :ok | {:error, term()}
  def sync(%__MODULE__{table: table, sync_fun: sync_fun}), do: invoke_sync(sync_fun, table)

  @spec persist_safety(t(), String.t(), map(), keyword()) :: {:ok, record()} | {:error, term()}
  def persist_safety(%__MODULE__{} = ledger, issue_id, counters, opts \\ [])
      when is_binary(issue_id) and is_map(counters) do
    status = Keyword.get(opts, :status, :open)

    with :ok <- persist_status_allowed?(ledger, issue_id, status),
         {:ok, lineage_id} <- lineage_id_for(ledger, issue_id),
         {:ok, safety_counters} <- durable_counters(counters),
         stop_reason <- Keyword.get(opts, :stop_reason),
         record <- %{
           schema_version: @schema_version,
           project_namespace: ledger.project_id,
           issue_id: issue_id,
           lineage_id: lineage_id,
           safety_counters: safety_counters,
           status: status,
           stop_reason: stop_reason,
           route_fingerprint: Keyword.get(opts, :route_fingerprint),
           in_flight: Keyword.get(opts, :in_flight, false),
           close_pending: false,
           updated_at: Keyword.get(opts, :updated_at, now_ms())
         },
         :ok <- put(ledger, record) do
      {:ok, record}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close_lineage(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def close_lineage(%__MODULE__{} = ledger, issue_id, opts \\ []) when is_binary(issue_id) do
    case current(ledger, issue_id) do
      :not_found ->
        :ok

      {:ok, %{status: :closed, close_pending: true}} ->
        confirm_lineage_close(ledger, issue_id)

      {:ok, %{status: :closed}} ->
        :ok

      {:ok, record} ->
        record =
          record
          |> Map.put(:status, :closed)
          |> Map.put(:closed_reason, Keyword.get(opts, :reason, :terminal))
          |> Map.put(:in_flight, false)
          |> Map.put(:close_pending, true)
          |> Map.put(:updated_at, Keyword.get(opts, :updated_at, now_ms()))

        with :ok <- validate_record(record, ledger, issue_id, @history_record_keys),
             :ok <- persist_records(ledger, [{{:current, issue_id}, record}]) do
          finalize_closed_lineage(ledger, issue_id, record)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec confirm_lineage_close(t(), String.t()) :: :ok | {:error, term()}
  def confirm_lineage_close(%__MODULE__{} = ledger, issue_id) when is_binary(issue_id) do
    case current(ledger, issue_id) do
      {:ok, %{status: :closed}} ->
        with :ok <- sync(ledger),
             {:ok, confirmed} <- current(ledger, issue_id) do
          finalize_confirmed_close(ledger, issue_id, confirmed)
        end

      {:ok, _record} ->
        {:error, :lineage_not_closed}

      :not_found ->
        {:error, :lineage_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def confirm_lineage_close(_ledger, _issue_id), do: {:error, :invalid_attempt_arguments}

  @spec rearm(t(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, record()} | {:error, term()}
  def rearm(%__MODULE__{} = ledger, issue_id, reason, operator, timestamp)
      when is_binary(issue_id) and is_binary(reason) and is_binary(operator) and is_integer(timestamp) and
             timestamp >= 0 do
    with :ok <- validate_rearm_value(reason, :reason),
         :ok <- validate_rearm_value(operator, :operator),
         {:ok, exhausted} <- exhausted_current(ledger, issue_id) do
      old_lineage_id = exhausted.lineage_id

      history =
        exhausted
        |> Map.merge(%{
          status: :closed,
          closed_reason: :rearmed,
          close_pending: false,
          rearm_reason: String.trim(reason),
          rearmed_by: String.trim(operator),
          rearmed_at: timestamp,
          updated_at: timestamp
        })

      new_record =
        exhausted
        |> Map.take(@base_record_keys)
        |> Map.merge(%{
          schema_version: @schema_version,
          project_namespace: ledger.project_id,
          issue_id: issue_id,
          lineage_id: new_lineage_id(),
          safety_counters: durable_counter_defaults(),
          status: :open,
          stop_reason: nil,
          route_fingerprint: nil,
          in_flight: false,
          updated_at: timestamp
        })

      with :ok <- validate_record(history, ledger, issue_id, @history_record_keys),
           :ok <- validate_record(new_record, ledger, issue_id, @base_record_keys),
           :ok <-
             persist_records(ledger, [
               {{:history, old_lineage_id}, history},
               {{:current, issue_id}, new_record}
             ]) do
        {:ok,
         new_record
         |> Map.put(:rearm_reason, String.trim(reason))
         |> Map.put(:rearmed_by, String.trim(operator))
         |> Map.put(:rearmed_at, timestamp)}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def rearm(_ledger, _issue_id, _reason, _operator, _timestamp), do: {:error, :invalid_rearm_arguments}

  defp build_ledger(table, path, project_id, tracker_identity, opts) do
    write_fun = Keyword.get(opts, :write_fun, &:dets.insert/2)
    sync_fun = Keyword.get(opts, :sync_fun, &:dets.sync/1)

    if is_function(write_fun, 2) and is_function(sync_fun, 1) do
      {:ok,
       %__MODULE__{
         table: table,
         path: path,
         project_id: project_id,
         tracker_identity: tracker_identity,
         write_fun: write_fun,
         sync_fun: sync_fun
       }}
    else
      {:error, :invalid_ledger_callbacks}
    end
  end

  defp initialize_or_validate(%__MODULE__{} = ledger) do
    with {:ok, records} <- all_records(ledger) do
      initialize_records(records, ledger)
    end
  end

  defp initialize_records([], %__MODULE__{} = ledger) do
    persist_records(ledger, [{{:meta, ledger.project_id}, metadata(ledger)}])
  end

  defp initialize_records(records, %__MODULE__{} = ledger) do
    case metadata_record(records) do
      {:ok, metadata} ->
        case validate_metadata(metadata, ledger) do
          :ok -> validate_stored_records(records, ledger)
          {:error, reason} -> {:error, reason}
        end

      {:error, :missing_metadata} ->
        {:error, {:corrupt_attempt_record, :metadata, :missing_metadata}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp metadata_record(records) do
    metadata = Enum.filter(records, &match?({{:meta, _project_id}, _metadata}, &1))

    case metadata do
      [] -> {:error, :missing_metadata}
      [{key, value}] -> {:ok, {key, value}}
      _ -> {:error, {:corrupt_attempt_record, :metadata, :invalid_record}}
    end
  end

  defp validate_metadata({{:meta, project_id}, metadata}, ledger) when is_binary(project_id) and is_map(metadata) do
    cond do
      project_id != ledger.project_id ->
        {:error, {:ledger_project_namespace_mismatch, project_id, ledger.project_id}}

      Map.keys(metadata) |> Enum.sort() != [:project_namespace, :schema_version, :tracker_identity] ->
        {:error, {:corrupt_attempt_record, :metadata, :invalid_record}}

      true ->
        validate_metadata_values(metadata, ledger)
    end
  end

  defp validate_metadata(_metadata, _ledger), do: {:error, {:corrupt_attempt_record, :metadata, :invalid_record}}

  defp validate_metadata_values(metadata, ledger) do
    with :ok <- validate_schema_version(Map.get(metadata, :schema_version)),
         :ok <- validate_project_namespace(Map.get(metadata, :project_namespace), ledger.project_id),
         :ok <- validate_tracker_identity(Map.get(metadata, :tracker_identity)) do
      validate_tracker_identity_match(metadata.tracker_identity, ledger.tracker_identity)
    end
  end

  defp validate_tracker_identity_match(stored, expected) when stored == expected, do: :ok

  defp validate_tracker_identity_match(stored, expected),
    do: {:error, {:ledger_tracker_identity_mismatch, stored, expected}}

  defp validate_stored_records(records, ledger) do
    Enum.reduce_while(records, :ok, fn
      {{:meta, _project_id}, _metadata}, :ok ->
        {:cont, :ok}

      {{:current, issue_id}, record}, :ok ->
        case validate_record(record, ledger, issue_id, allowed_record_keys(record)) do
          :ok ->
            {:cont, :ok}

          {:error, {:ledger_schema_version_unsupported, version}} ->
            {:halt, {:error, {:ledger_schema_version_unsupported, version}}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_attempt_record, {:current, issue_id}, reason}}}
        end

      {{:history, lineage_id}, record}, :ok ->
        case validate_record(record, ledger, record_issue_id(record), @history_record_keys) do
          :ok when record.lineage_id == lineage_id ->
            {:cont, :ok}

          :ok ->
            {:halt, {:error, {:corrupt_attempt_record, {:history, lineage_id}, :invalid_record}}}

          {:error, {:ledger_schema_version_unsupported, version}} ->
            {:halt, {:error, {:ledger_schema_version_unsupported, version}}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_attempt_record, {:history, lineage_id}, reason}}}
        end

      {key, _record}, :ok ->
        {:halt, {:error, {:corrupt_attempt_record, key, :invalid_record}}}
    end)
  end

  defp allowed_record_keys(record) when is_map(record) do
    if Map.get(record, :status) == :closed, do: @history_record_keys, else: @base_record_keys
  end

  defp allowed_record_keys(_record), do: @base_record_keys

  defp record_issue_id(%{issue_id: issue_id}), do: issue_id
  defp record_issue_id(_record), do: nil

  defp validate_record(record, ledger, issue_id, allowed_keys)
       when is_map(record) and is_binary(issue_id) do
    with :ok <- validate_record_keys(record, allowed_keys),
         {:ok, in_flight, close_pending} <- fetch_safety_fields(record),
         :ok <- validate_schema_version(Map.get(record, :schema_version)),
         :ok <- validate_project_namespace(Map.get(record, :project_namespace), ledger.project_id),
         :ok <- validate_non_empty_string(Map.get(record, :issue_id), :issue_id),
         :ok <- validate_non_empty_string(Map.get(record, :lineage_id), :lineage_id),
         :ok <- validate_counters(Map.get(record, :safety_counters)),
         :ok <- validate_status(Map.get(record, :status)),
         :ok <- validate_stop_reason(Map.get(record, :stop_reason)),
         :ok <- validate_route_fingerprint(Map.get(record, :route_fingerprint)),
         :ok <- validate_in_flight(in_flight),
         :ok <- validate_close_pending(close_pending),
         :ok <- validate_timestamp(Map.get(record, :updated_at)) do
      if record.issue_id != issue_id do
        {:error, :invalid_record}
      else
        validate_safety_state(record)
      end
    end
  end

  defp validate_record(_record, _ledger, _issue_id, _allowed_keys), do: {:error, :invalid_record}

  defp validate_record_keys(record, allowed_keys) do
    if Enum.all?(Map.keys(record), &(&1 in allowed_keys)), do: :ok, else: {:error, :invalid_record}
  end

  defp fetch_safety_fields(record) do
    with {:ok, in_flight} <- Map.fetch(record, :in_flight),
         {:ok, close_pending} <- Map.fetch(record, :close_pending) do
      {:ok, in_flight, close_pending}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(version), do: {:error, {:ledger_schema_version_unsupported, version}}

  defp validate_project_namespace(project_id, project_id) when is_binary(project_id), do: :ok
  defp validate_project_namespace(_stored, _expected), do: {:error, :invalid_record}

  defp validate_project_id(project_id) do
    if Schema.valid_project_id?(project_id), do: :ok, else: {:error, {:invalid_symphony_project_id, project_id}}
  end

  defp validate_tracker_identity(identity) when is_map(identity) do
    cond do
      Enum.sort(Map.keys(identity)) != Enum.sort(@allowed_identity_keys) ->
        {:error, :invalid_tracker_identity}

      not is_binary(identity.tracker_kind) or String.trim(identity.tracker_kind) == "" ->
        {:error, :invalid_tracker_identity}

      not valid_scope?(identity.provider_scope) ->
        {:error, :invalid_tracker_identity}

      true ->
        :ok
    end
  end

  defp validate_tracker_identity(_identity), do: {:error, :invalid_tracker_identity}

  defp valid_scope?(scope) when is_map(scope) do
    Enum.all?(scope, fn {key, value} ->
      key in @allowed_scope_keys and is_binary(value) and String.trim(value) != ""
    end)
  end

  defp valid_scope?(_scope), do: false

  defp validate_counters(counters) when is_map(counters) do
    if Enum.sort(Map.keys(counters)) == Enum.sort(@durable_counter_keys) and
         Enum.all?(counters, fn {_key, value} -> is_integer(value) and value >= 0 end) do
      :ok
    else
      {:error, :invalid_record}
    end
  end

  defp validate_counters(_counters), do: {:error, :invalid_record}

  defp validate_status(status) when status in [:open, :exhausted, :closed], do: :ok
  defp validate_status(_status), do: {:error, :invalid_record}

  defp validate_stop_reason(nil), do: :ok
  defp validate_stop_reason(reason) when is_atom(reason), do: :ok
  defp validate_stop_reason(_reason), do: {:error, :invalid_record}

  defp validate_route_fingerprint(nil), do: :ok
  defp validate_route_fingerprint(value) when is_binary(value), do: :ok
  defp validate_route_fingerprint(_value), do: {:error, :invalid_record}

  defp validate_timestamp(timestamp) when is_integer(timestamp) and timestamp >= 0, do: :ok
  defp validate_timestamp(_timestamp), do: {:error, :invalid_record}

  defp validate_in_flight(value) when is_boolean(value), do: :ok
  defp validate_in_flight(_value), do: {:error, :invalid_record}

  defp validate_close_pending(value) when is_boolean(value), do: :ok
  defp validate_close_pending(_value), do: {:error, :invalid_record}

  defp validate_safety_state(%{status: status} = record) do
    if Map.get(record, :close_pending, false) and status != :closed do
      {:error, :invalid_record}
    else
      case status do
        :open -> validate_open_safety_state(record)
        :exhausted -> validate_exhausted_safety_state(record)
        :closed -> validate_closed_safety_state(record)
        _ -> {:error, :invalid_record}
      end
    end
  end

  defp validate_open_safety_state(%{safety_counters: counters, stop_reason: nil}),
    do: safety_state_result(open_counters?(counters))

  defp validate_open_safety_state(_record), do: {:error, :invalid_record}

  defp validate_exhausted_safety_state(%{safety_counters: counters, stop_reason: stop_reason} = record) do
    safety_state_result(not Map.get(record, :in_flight, false) and exhausted_counters?(counters, stop_reason))
  end

  defp validate_exhausted_safety_state(_record), do: {:error, :invalid_record}

  defp validate_closed_safety_state(%{safety_counters: counters, stop_reason: stop_reason} = record) do
    safety_state_result(not Map.get(record, :in_flight, false) and closed_counters?(counters, stop_reason))
  end

  defp validate_closed_safety_state(_record), do: {:error, :invalid_record}

  defp safety_state_result(true), do: :ok
  defp safety_state_result(false), do: {:error, :invalid_record}

  defp open_counters?(%{
         ordinary_failures: ordinary_failures,
         ordinary_retries: ordinary_retries,
         review_cycles: review_cycles
       }) do
    ordinary_failures in 0..AttemptPolicy.max_ordinary_retries() and
      ordinary_retries == ordinary_failures and
      review_cycles in 0..AttemptPolicy.max_review_cycles()
  end

  defp open_counters?(_counters), do: false

  defp exhausted_counters?(counters, :ordinary_retry_limit) do
    review_cycles_valid?(counters) and
      counters.ordinary_failures == AttemptPolicy.max_ordinary_retries() + 1 and
      counters.ordinary_retries == AttemptPolicy.max_ordinary_retries()
  end

  defp exhausted_counters?(counters, :review_cycle_limit) do
    ordinary_counters_open?(counters) and
      counters.review_cycles == AttemptPolicy.max_review_cycles()
  end

  defp exhausted_counters?(counters, :ci_retry_disabled), do: open_counters?(counters)
  defp exhausted_counters?(_counters, _reason), do: false

  defp closed_counters?(counters, nil), do: open_counters?(counters)
  defp closed_counters?(counters, stop_reason), do: exhausted_counters?(counters, stop_reason)

  defp ordinary_counters_open?(%{ordinary_failures: ordinary_failures, ordinary_retries: ordinary_retries}) do
    ordinary_failures in 0..AttemptPolicy.max_ordinary_retries() and
      ordinary_retries == ordinary_failures
  end

  defp ordinary_counters_open?(_counters), do: false

  defp review_cycles_valid?(%{review_cycles: review_cycles}),
    do: review_cycles in 0..AttemptPolicy.max_review_cycles()

  defp review_cycles_valid?(_counters), do: false

  defp validate_non_empty_string(value, _field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_record}, else: :ok
  end

  defp validate_non_empty_string(_value, _field), do: {:error, :invalid_record}

  defp lineage_id_for(ledger, issue_id) do
    case current(ledger, issue_id) do
      {:ok, %{lineage_id: lineage_id, status: status}} when status in [:open, :exhausted] ->
        {:ok, lineage_id}

      :not_found ->
        {:ok, new_lineage_id()}

      {:ok, _closed} ->
        {:ok, new_lineage_id()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_status_allowed?(ledger, issue_id, status) do
    case current(ledger, issue_id) do
      {:ok, %{status: :closed, close_pending: true}} -> {:error, :lineage_close_pending}
      {:ok, %{status: :exhausted}} when status != :exhausted -> {:error, :lineage_exhausted}
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp durable_counters(counters) do
    if Enum.all?(@durable_counter_keys, &(is_integer(Map.get(counters, &1)) and Map.get(counters, &1) >= 0)) do
      {:ok, Map.take(counters, @durable_counter_keys)}
    else
      {:error, :invalid_safety_counters}
    end
  end

  defp durable_counter_defaults, do: Map.take(AttemptPolicy.new(), @durable_counter_keys)

  defp exhausted_current(ledger, issue_id) do
    case current(ledger, issue_id) do
      {:ok, %{status: :exhausted} = record} -> {:ok, record}
      {:ok, _record} -> {:error, :lineage_not_exhausted}
      :not_found -> {:error, :lineage_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_rearm_value(value, _field) do
    if String.trim(value) == "", do: {:error, :invalid_rearm_arguments}, else: :ok
  end

  defp finalize_closed_lineage(%__MODULE__{} = ledger, issue_id, record) do
    finalized_record = Map.put(record, :close_pending, false)

    with :ok <- validate_record(finalized_record, ledger, issue_id, @history_record_keys) do
      persist_records(ledger, [{{:current, issue_id}, finalized_record}])
    end
  end

  defp finalize_confirmed_close(%__MODULE__{} = ledger, issue_id, record) do
    if Map.get(record, :close_pending, false) do
      finalize_closed_lineage(ledger, issue_id, record)
    else
      :ok
    end
  end

  defp persist_records(%__MODULE__{table: table, write_fun: write_fun, sync_fun: sync_fun}, records) do
    case invoke_write(write_fun, table, records) do
      :ok -> invoke_sync(sync_fun, table)
      {:error, _reason} = error -> error
    end
  end

  defp invoke_write(write_fun, table, records) do
    case write_fun.(table, records) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
      other -> {:error, {:ledger_write_failed, other}}
    end
  rescue
    error -> {:error, {:ledger_write_failed, error}}
  catch
    kind, reason -> {:error, {:ledger_write_failed, {kind, reason}}}
  end

  defp invoke_sync(sync_fun, table) do
    case sync_fun.(table) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_sync_failed, reason}}
      other -> {:error, {:ledger_sync_failed, other}}
    end
  rescue
    error -> {:error, {:ledger_sync_failed, error}}
  catch
    kind, reason -> {:error, {:ledger_sync_failed, {kind, reason}}}
  end

  defp all_records(%__MODULE__{table: table}) do
    {:ok, :dets.foldl(fn record, records -> [record | records] end, [], table)}
  catch
    kind, reason -> {:error, {:ledger_read_failed, {kind, reason}}}
  end

  defp safe_lookup(table, key) do
    {:ok, :dets.lookup(table, key)}
  catch
    kind, reason -> {:error, {:ledger_read_failed, {kind, reason}}}
  end

  defp open_table(path) do
    table = path

    case :dets.open_file(table, type: :set, file: String.to_charlist(path), auto_save: :infinity) do
      {:ok, ^table} ->
        case File.chmod(path, 0o600) do
          :ok ->
            {:ok, table}

          {:error, reason} ->
            _ = close_table(table)
            {:error, {:ledger_permissions_failed, reason}}
        end

      {:error, {:already_started, _pid}} ->
        {:error, {:ledger_already_open, path}}

      {:error, reason} ->
        {:error, {:ledger_open_failed, reason}}
    end
  end

  defp close_table(table) do
    case :dets.info(table) do
      :undefined -> :ok
      _ -> :dets.close(table)
    end
  catch
    :exit, reason -> {:error, {:ledger_close_failed, reason}}
  end

  defp ensure_parent_directory(path), do: path |> Path.dirname() |> File.mkdir_p()

  defp metadata(%__MODULE__{} = ledger) do
    %{
      schema_version: @schema_version,
      project_namespace: ledger.project_id,
      tracker_identity: ledger.tracker_identity
    }
  end

  defp default_root do
    state_root = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state_root, "symphony/attempt-ledger")
  end

  defp new_lineage_id do
    "lineage-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp now_ms, do: System.system_time(:millisecond)
end
