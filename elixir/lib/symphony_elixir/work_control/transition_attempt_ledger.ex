defmodule SymphonyElixir.WorkControl.TransitionAttemptLedger do
  @moduledoc """
  Separate DETS ledger for provider lifecycle mutation attempts.

  This table intentionally does not share the runtime retry lineage schema.
  Every safety-critical write is followed by an explicit DETS sync.
  """

  alias SymphonyElixir.WorkControl.{TransitionAttempt, WorkflowLifecycle}

  @schema_version 1
  @reconciliation_statuses [:submitted, :mutation_submitted, :verifying, :conflict, :indeterminate]
  @reconciliation_outcomes [:verified, :conflict, :provider_failed]
  @allowed_statuses [:requested, :intent_authorized, :fresh_context_loaded, :prepared] ++
                      @reconciliation_statuses ++ [:verified, :rejected, :provider_failed]

  defstruct [:table, :path, :project_id, :tracker_identity, :write_fun, :sync_fun]

  @type t :: %__MODULE__{
          table: term(),
          path: Path.t(),
          project_id: String.t(),
          tracker_identity: map(),
          write_fun: (term(), term() -> term()),
          sync_fun: (term() -> term())
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec path_for(String.t(), keyword()) :: Path.t()
  def path_for(project_id, opts \\ []) when is_binary(project_id) do
    root =
      Keyword.get(opts, :root) || Application.get_env(:symphony_elixir, :transition_attempt_ledger_root) ||
        default_root()

    case Keyword.get(opts, :path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> Path.join(Path.expand(root), project_id <> "-transition-ledger.dets")
    end
  end

  @spec open(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(project_id, tracker_identity, opts \\ [])
      when is_binary(project_id) and is_map(tracker_identity) and is_list(opts) do
    with :ok <- validate_project_id(project_id),
         :ok <- validate_tracker_identity(tracker_identity),
         path <- path_for(project_id, opts),
         :ok <- ensure_parent(path),
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
    else
      {:error, _reason} = error -> error
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{table: table}), do: close_table(table)

  @spec put_sync(t(), TransitionAttempt.t() | map()) :: :ok | {:error, term()}
  def put_sync(%__MODULE__{} = ledger, attempt) do
    with {:ok, record, attempt_id, work_item_id} <- validate_attempt(ledger, attempt),
         :ok <- persist(ledger, [{{:attempt, attempt_id}, record}, {{:latest, work_item_id}, attempt_id}]) do
      sync(ledger)
    end
  end

  def put_sync(_ledger, _attempt), do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  @spec get(t(), String.t()) :: {:ok, term()} | :not_found | {:error, term()}
  def get(%__MODULE__{} = ledger, attempt_id) when is_binary(attempt_id) do
    table = ledger.table

    case :dets.lookup(table, {:attempt, attempt_id}) do
      [{{:attempt, ^attempt_id}, attempt}] ->
        case validate_attempt(ledger, attempt) do
          {:ok, _record, _stored_attempt_id, _work_item_id} -> {:ok, attempt}
          {:error, _reason} = error -> error
        end

      [] ->
        :not_found

      _ ->
        {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  rescue
    _error -> {:error, {:corrupt_transition_attempt, :ledger_unavailable}}
  end

  def get(_ledger, _attempt_id), do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  @spec latest_for_work_item(t(), String.t()) :: {:ok, term()} | :not_found | {:error, term()}
  def latest_for_work_item(%__MODULE__{table: table} = ledger, work_item_id)
      when is_binary(work_item_id) do
    case :dets.lookup(table, {:latest, work_item_id}) do
      [{{:latest, ^work_item_id}, attempt_id}] -> get(ledger, attempt_id)
      [] -> :not_found
      _ -> {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  rescue
    _error -> {:error, {:corrupt_transition_attempt, :ledger_unavailable}}
  end

  def latest_for_work_item(_ledger, _work_item_id), do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  @spec reconcile_candidate(t(), term(), atom(), term()) :: {:ok, map()} | {:error, term()}
  def reconcile_candidate(ledger, candidate, outcome, evidence_identity) do
    reconcile_candidate(ledger, candidate, outcome, evidence_identity, DateTime.utc_now())
  end

  @spec reconcile_candidate(t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def reconcile_candidate(ledger, candidate, attrs) when is_map(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort([:outcome, :evidence_identity, :reconciled_at]) do
      reconcile_candidate(
        ledger,
        candidate,
        Map.fetch!(attrs, :outcome),
        Map.fetch!(attrs, :evidence_identity),
        Map.fetch!(attrs, :reconciled_at)
      )
    else
      {:error, {:reconciliation_marker, :invalid_marker_attributes}}
    end
  end

  def reconcile_candidate(_ledger, _candidate, _attrs),
    do: {:error, {:reconciliation_marker, :invalid_marker_attributes}}

  @spec reconcile_candidate(t(), term(), atom(), term(), DateTime.t() | non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_candidate(%__MODULE__{} = ledger, candidate, outcome, evidence_identity, reconciled_at) do
    with {:ok, candidate_record, attempt_id, work_item_id} <- candidate_record(ledger, candidate),
         {:ok, stored_attempt} <- stored_attempt(ledger, attempt_id),
         :ok <- same_candidate?(candidate_record, stored_attempt, work_item_id),
         :ok <- ensure_unresolved_candidate(stored_attempt),
         :ok <- ensure_no_marker(ledger, attempt_id),
         {:ok, marker} <- new_marker(ledger, attempt_id, work_item_id, outcome, evidence_identity, reconciled_at),
         :ok <- persist(ledger, [{{:reconciliation, attempt_id}, marker}]),
         :ok <- sync(ledger) do
      {:ok, marker}
    end
  rescue
    _error -> {:error, {:reconciliation_marker, :ledger_unavailable}}
  end

  def reconcile_candidate(_ledger, _candidate, _outcome, _evidence_identity, _reconciled_at),
    do: {:error, {:reconciliation_marker, :invalid_candidate}}

  @spec sync(t()) :: :ok | {:error, term()}
  def sync(%__MODULE__{} = ledger), do: sync_ledger(ledger)

  def sync(_ledger), do: {:error, {:ledger_sync_failed, :invalid_record}}

  @spec list_reconciliation_candidates(t()) :: {:ok, [term()]} | {:error, term()}
  def list_reconciliation_candidates(%__MODULE__{} = ledger) do
    list_reconciliation_candidates_from_durable_table(ledger)
  end

  def list_reconciliation_candidates(_ledger), do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  @spec reconciliation_marker_for_work_item(t(), String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def reconciliation_marker_for_work_item(%__MODULE__{} = ledger, work_item_id) when is_binary(work_item_id) do
    with :ok <- sync(ledger),
         {:ok, attempt} <- latest_for_work_item(ledger, work_item_id) do
      marker_for_latest_attempt(ledger, attempt, work_item_id)
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, {:corrupt_transition_attempt, :ledger_unavailable}}
  end

  def reconciliation_marker_for_work_item(_ledger, _work_item_id),
    do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  defp marker_for_latest_attempt(ledger, attempt, work_item_id) do
    case marker_for_attempt(ledger, attempt) do
      {:ok, marker} -> ensure_no_unresolved_candidates(ledger, work_item_id, marker)
      result -> result
    end
  end

  defp ensure_no_unresolved_candidates(ledger, work_item_id, marker) do
    case list_reconciliation_candidates_from_durable_table(ledger) do
      {:ok, candidates} ->
        if Enum.any?(candidates, &(Map.get(&1, :work_item_id) == work_item_id)) do
          {:error, {:reconciliation_candidate_unresolved, work_item_id}}
        else
          {:ok, marker}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp marker_for_attempt(ledger, attempt) do
    attempt_id = attempt_identifier(attempt)

    case :dets.lookup(ledger.table, {:reconciliation, attempt_id}) do
      [{{:reconciliation, ^attempt_id}, marker}] ->
        validate_reconciliation_marker(ledger, marker, attempt_id, attempt)

      [] ->
        :not_found

      _other ->
        {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}
    end
  end

  defp validate_reconciliation_marker(ledger, marker, attempt_id, attempt) do
    case validate_marker_map(ledger, marker, attempt_id, attempt) do
      :ok -> {:ok, marker}
      {:error, _reason} -> {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}
    end
  end

  defp list_reconciliation_candidates_from_durable_table(%__MODULE__{} = ledger) do
    result =
      :dets.foldl(
        fn
          _record, {:error, _reason} = error ->
            error

          {{:attempt, _attempt_id}, attempt}, {:ok, %{attempts: attempts} = result} ->
            case validate_attempt(ledger, attempt) do
              {:ok, record, _attempt_id, _work_item_id} ->
                {:ok, Map.put(result, :attempts, [record | attempts])}

              {:error, _reason} = error ->
                error
            end

          {{:latest, work_item_id}, attempt_id}, {:ok, %{pointers: pointers} = result}
          when is_binary(work_item_id) and is_binary(attempt_id) ->
            {:ok, Map.put(result, :pointers, [{work_item_id, attempt_id} | pointers])}

          {{:latest, _work_item_id}, _attempt_id}, _result ->
            {:error, {:corrupt_transition_attempt, :invalid_record}}

          {{:reconciliation, marker_id}, marker}, {:ok, %{markers: markers} = result}
          when is_binary(marker_id) ->
            if Map.has_key?(markers, marker_id) do
              {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}
            else
              {:ok, Map.put(result, :markers, Map.put(markers, marker_id, marker))}
            end

          {{:reconciliation, _marker_id}, _marker}, {:ok, _result} ->
            {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}

          {{:meta, _stored_project}, metadata}, {:ok, %{metadata_seen: false} = result} ->
            case validate_metadata(metadata, ledger) do
              :ok -> {:ok, Map.put(result, :metadata_seen, true)}
              {:error, _reason} = error -> error
            end

          {{:meta, _stored_project}, _metadata}, {:ok, _result} ->
            {:error, {:corrupt_transition_attempt, :metadata}}

          _other, _result ->
            {:error, {:corrupt_transition_attempt, :invalid_record}}
        end,
        {:ok, %{attempts: [], pointers: [], markers: %{}, metadata_seen: false}},
        ledger.table
      )

    with {:ok, %{attempts: attempts, pointers: pointers, markers: markers, metadata_seen: true}} <- result,
         :ok <- validate_latest_pointers(attempts, pointers),
         :ok <- validate_markers(ledger, attempts, markers) do
      candidates =
        Enum.filter(attempts, fn attempt ->
          reconciliation_candidate?(attempt) and
            not Map.has_key?(markers, attempt_identifier(attempt))
        end)

      rank = %{
        prepared: 0,
        submitted: 1,
        mutation_submitted: 1,
        verifying: 2,
        conflict: 3,
        indeterminate: 4
      }

      sorted =
        Enum.sort_by(candidates, fn attempt ->
          {
            Map.get(rank, Map.get(attempt, :status) || Map.get(attempt, :state), 99),
            Map.get(attempt, :updated_at, 0),
            attempt_identifier(attempt)
          }
        end)

      {:ok, sorted}
    end
  rescue
    _error -> {:error, {:corrupt_transition_attempt, :invalid_record}}
  end

  @spec resubmit_allowed?(term()) :: boolean()
  def resubmit_allowed?(%TransitionAttempt{}), do: false
  def resubmit_allowed?(%{status: :prepared}), do: false
  def resubmit_allowed?(%{state: :prepared}), do: false
  def resubmit_allowed?(_attempt), do: false

  defp candidate_record(ledger, %TransitionAttempt{} = candidate) do
    case validate_attempt(ledger, candidate) do
      {:ok, record, attempt_id, work_item_id} -> {:ok, record, attempt_id, work_item_id}
      {:error, _reason} -> {:error, {:reconciliation_marker, :invalid_candidate}}
    end
  end

  defp candidate_record(ledger, candidate) when is_map(candidate) do
    case validate_attempt(ledger, candidate) do
      {:ok, record, attempt_id, work_item_id} -> {:ok, record, attempt_id, work_item_id}
      {:error, _reason} -> {:error, {:reconciliation_marker, :invalid_candidate}}
    end
  end

  defp candidate_record(_ledger, _candidate), do: {:error, {:reconciliation_marker, :invalid_candidate}}

  defp stored_attempt(%__MODULE__{} = ledger, attempt_id) do
    case get(ledger, attempt_id) do
      {:ok, attempt} -> {:ok, attempt}
      :not_found -> {:error, {:reconciliation_marker, :candidate_not_found}}
      {:error, _reason} -> {:error, {:reconciliation_marker, :invalid_candidate}}
    end
  end

  defp same_candidate?(candidate, stored, work_item_id) do
    stored_attempt_id = attempt_identifier(stored)
    stored_work_item_id = Map.get(stored, :work_item_id)

    if attempt_identifier(candidate) == stored_attempt_id and work_item_id == stored_work_item_id do
      :ok
    else
      {:error, {:reconciliation_marker, :candidate_mismatch}}
    end
  end

  defp ensure_unresolved_candidate(candidate) do
    if reconciliation_candidate?(candidate),
      do: :ok,
      else: {:error, {:reconciliation_marker, :candidate_not_unresolved}}
  end

  defp ensure_no_marker(%__MODULE__{table: table}, attempt_id) do
    case :dets.lookup(table, {:reconciliation, attempt_id}) do
      [] -> :ok
      [_marker] -> {:error, {:reconciliation_marker, :already_reconciled}}
      _entries -> {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}
    end
  rescue
    _error -> {:error, {:reconciliation_marker, :ledger_unavailable}}
  end

  defp new_marker(ledger, attempt_id, work_item_id, outcome, evidence_identity, reconciled_at) do
    marker = %{
      schema_version: @schema_version,
      marker_type: :transition_reconciliation,
      project_namespace: ledger.project_id,
      attempt_id: attempt_id,
      work_item_id: work_item_id,
      outcome: outcome,
      evidence_identity: evidence_identity,
      reconciled_at: reconciled_at
    }

    case validate_marker_map(ledger, marker, attempt_id, %{
           status: :indeterminate,
           state: :indeterminate,
           work_item_id: work_item_id
         }) do
      :ok -> {:ok, marker}
      {:error, _reason} -> {:error, {:reconciliation_marker, :invalid_marker}}
    end
  end

  defp initialize_or_validate(%__MODULE__{} = ledger) do
    metadata_records = :dets.match_object(ledger.table, {{:meta, :_}, :_})

    case metadata_records do
      [] ->
        with :ok <- persist(ledger, [{{:meta, ledger.project_id}, metadata(ledger)}]) do
          sync(ledger)
        end

      [{{:meta, _stored_project}, metadata}] ->
        validate_metadata(metadata, ledger)

      _ ->
        {:error, {:corrupt_transition_attempt, :metadata}}
    end
  end

  defp metadata(ledger), do: %{schema_version: @schema_version, project_namespace: ledger.project_id, tracker_identity: ledger.tracker_identity}

  defp validate_metadata(%{schema_version: @schema_version, project_namespace: project_id, tracker_identity: identity}, ledger) do
    cond do
      project_id != ledger.project_id ->
        {:error, {:ledger_project_namespace_mismatch, project_id, ledger.project_id}}

      identity != ledger.tracker_identity ->
        {:error, {:ledger_tracker_identity_mismatch, identity, ledger.tracker_identity}}

      true ->
        :ok
    end
  end

  defp validate_metadata(%{project_namespace: project_id}, ledger),
    do: {:error, {:ledger_project_namespace_mismatch, project_id, ledger.project_id}}

  defp validate_metadata(_metadata, _ledger), do: {:error, {:corrupt_transition_attempt, :metadata}}

  defp validate_attempt(ledger, %TransitionAttempt{} = attempt) do
    record = Map.from_struct(attempt)
    validate_attempt_map(ledger, record, attempt)
  end

  defp validate_attempt(ledger, record) when is_map(record), do: validate_attempt_map(ledger, record, record)
  defp validate_attempt(_ledger, _attempt), do: {:error, {:corrupt_transition_attempt, :invalid_record}}

  defp validate_attempt_map(ledger, record, original) do
    attempt_id = Map.get(record, :attempt_id) || Map.get(record, :transition_attempt_id)
    work_item_id = Map.get(record, :work_item_id)
    status = Map.get(record, :status) || Map.get(record, :state)

    with :ok <- validate_schema_version(record),
         :ok <- validate_project_namespace(record, ledger),
         :ok <- validate_attempt_ids(attempt_id, work_item_id),
         :ok <- validate_state_pair(record),
         :ok <- validate_status(status),
         :ok <- validate_attempt_timestamps(record),
         :ok <- validate_record_keys(record, original) do
      {:ok, original, attempt_id, work_item_id}
    end
  end

  defp validate_schema_version(record) do
    if Map.get(record, :schema_version, @schema_version) == @schema_version do
      :ok
    else
      {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  end

  defp validate_project_namespace(record, ledger) do
    project_namespace = Map.get(record, :project_namespace, ledger.project_id)

    if project_namespace == ledger.project_id do
      :ok
    else
      {:error, {:ledger_project_namespace_mismatch, project_namespace, ledger.project_id}}
    end
  end

  defp validate_attempt_ids(attempt_id, work_item_id) do
    if valid_id?(attempt_id) and valid_id?(work_item_id) do
      :ok
    else
      {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  end

  defp validate_state_pair(record) do
    if valid_state_pair?(record), do: :ok, else: {:error, {:corrupt_transition_attempt, :invalid_record}}
  end

  defp validate_status(status) do
    if status in @allowed_statuses, do: :ok, else: {:error, {:corrupt_transition_attempt, :invalid_record}}
  end

  defp validate_attempt_timestamps(record) do
    if valid_timestamp?(Map.get(record, :created_at)) and valid_timestamp?(Map.get(record, :updated_at)) do
      :ok
    else
      {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  end

  defp validate_record_keys(record, original) do
    if unexpected_keys?(record, original), do: {:error, {:corrupt_transition_attempt, :invalid_record}}, else: :ok
  end

  defp unexpected_keys?(record, %TransitionAttempt{}), do: Enum.any?(Map.keys(record), &(&1 not in Map.keys(%TransitionAttempt{})))
  defp unexpected_keys?(record, _original), do: Enum.any?(Map.keys(record), &(&1 not in plain_record_keys()))

  defp plain_record_keys do
    Enum.uniq(
      Map.keys(%TransitionAttempt{}) ++
        [:project_namespace, :source_state, :target_state, :provider_observation_identity]
    )
  end

  defp reconciliation_candidate?(attempt) do
    status = Map.get(attempt, :status) || Map.get(attempt, :state)

    status in @reconciliation_statuses or status == :prepared
  end

  defp validate_markers(ledger, attempts, markers) do
    attempts_by_id = Map.new(attempts, &{attempt_identifier(&1), &1})

    Enum.reduce_while(markers, :ok, fn {marker_id, marker}, :ok ->
      case validate_marker_entry(ledger, attempts_by_id, marker_id, marker) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, {:corrupt_transition_attempt, :invalid_reconciliation_marker}}}
      end
    end)
  end

  defp validate_marker_entry(ledger, attempts_by_id, marker_id, marker) do
    case Map.fetch(attempts_by_id, marker_id) do
      {:ok, attempt} -> validate_marker_map(ledger, marker, marker_id, attempt)
      :error -> {:error, :missing_attempt}
    end
  end

  defp validate_marker_map(ledger, marker, marker_id, attempt) when is_map(marker) do
    marker_attempt_id = Map.get(marker, :attempt_id)
    marker_work_item_id = Map.get(marker, :work_item_id)
    attempt_work_item_id = Map.get(attempt, :work_item_id)

    with true <- Map.get(marker, :schema_version) == @schema_version,
         true <- Map.get(marker, :marker_type) == :transition_reconciliation,
         true <- Map.get(marker, :project_namespace) == ledger.project_id,
         true <- marker_attempt_id == marker_id,
         true <- valid_id?(marker_attempt_id),
         true <- marker_work_item_id == attempt_work_item_id and valid_id?(marker_work_item_id),
         true <- reconciliation_outcome?(Map.get(marker, :outcome)),
         true <- valid_evidence_identity?(Map.get(marker, :evidence_identity)),
         true <- valid_timestamp?(Map.get(marker, :reconciled_at)),
         true <- marker_keys_valid?(marker) do
      if reconciliation_candidate?(attempt), do: :ok, else: {:error, :candidate_not_unresolved}
    else
      _ -> {:error, :invalid_reconciliation_marker}
    end
  end

  defp validate_marker_map(_ledger, _marker, _marker_id, _attempt),
    do: {:error, :invalid_reconciliation_marker}

  defp marker_keys_valid?(marker) do
    marker_keys = [
      :schema_version,
      :marker_type,
      :project_namespace,
      :attempt_id,
      :work_item_id,
      :outcome,
      :evidence_identity,
      :reconciled_at
    ]

    Enum.sort(Map.keys(marker)) == Enum.sort(marker_keys)
  end

  defp reconciliation_outcome?(outcome), do: outcome in @reconciliation_outcomes

  defp valid_evidence_identity?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_evidence_identity?(value) when is_atom(value), do: not is_nil(value)
  defp valid_evidence_identity?(value) when is_integer(value), do: value >= 0
  defp valid_evidence_identity?(value) when is_map(value), do: map_size(value) > 0
  defp valid_evidence_identity?(_value), do: false

  defp validate_latest_pointers(attempts, pointers) do
    attempt_ids = MapSet.new(attempts, &attempt_identifier/1)

    if Enum.all?(pointers, fn {_work_item_id, attempt_id} -> MapSet.member?(attempt_ids, attempt_id) end) do
      :ok
    else
      {:error, {:corrupt_transition_attempt, :invalid_record}}
    end
  end

  defp attempt_identifier(attempt), do: Map.get(attempt, :attempt_id) || Map.get(attempt, :transition_attempt_id) || ""

  defp valid_state_pair?(record) do
    source = Map.get(record, :source_state) || Map.get(record, :requested_from)
    target = Map.get(record, :target_state) || Map.get(record, :requested_to)
    state = Map.get(record, :state)
    status = Map.get(record, :status)

    WorkflowLifecycle.canonical?(source) and WorkflowLifecycle.canonical?(target) and
      valid_state_status_pair(state, status)
  end

  defp valid_state_status_pair(:mutation_submitted, :submitted), do: true

  defp valid_state_status_pair(state, status)
       when state in [
              :requested,
              :intent_authorized,
              :fresh_context_loaded,
              :prepared,
              :verifying,
              :verified,
              :rejected,
              :conflict,
              :provider_failed,
              :indeterminate
            ],
       do: state == status

  defp valid_state_status_pair(_state, _status), do: false

  defp persist(%__MODULE__{table: table, write_fun: write_fun}, records) do
    case write_fun.(table, records) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
      other -> {:error, {:ledger_write_failed, other}}
    end
  rescue
    _error -> {:error, {:ledger_write_failed, :write_failed}}
  end

  defp sync_ledger(%__MODULE__{table: table, sync_fun: sync_fun}) do
    case sync_fun.(table) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_sync_failed, reason}}
      other -> {:error, {:ledger_sync_failed, other}}
    end
  rescue
    _error -> {:error, {:ledger_sync_failed, :sync_failed}}
  end

  defp build_ledger(table, path, project_id, identity, opts) do
    write_fun = Keyword.get(opts, :write_fun, &:dets.insert/2)
    sync_fun = Keyword.get(opts, :sync_fun, &:dets.sync/1)

    if is_function(write_fun, 2) and is_function(sync_fun, 1) do
      {:ok,
       %__MODULE__{
         table: table,
         path: path,
         project_id: project_id,
         tracker_identity: identity,
         write_fun: write_fun,
         sync_fun: sync_fun
       }}
    else
      {:error, :invalid_ledger_callbacks}
    end
  end

  defp open_table(path) do
    table = path

    case :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity) do
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
        {:error, reason}
    end
  end

  defp close_table(table) do
    case :dets.info(table) do
      :undefined ->
        :ok

      _ ->
        case :dets.close(table) do
          :ok -> :ok
          {:error, :not_owner} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _error -> :ok
  end

  defp ensure_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_directory_failed, reason}}
    end
  end

  defp default_root do
    state_root = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state_root, "symphony/transition-attempt-ledger")
  end

  defp validate_project_id(value) do
    if valid_id?(value), do: :ok, else: {:error, {:invalid_project_id, value}}
  end

  defp validate_tracker_identity(%{tracker_kind: kind, provider_scope: scope})
       when is_binary(kind) and is_map(scope), do: :ok

  defp validate_tracker_identity(_identity), do: {:error, :invalid_tracker_identity}

  defp valid_id?(value), do: is_binary(value) and String.trim(value) != ""
  defp valid_timestamp?(value), do: (is_integer(value) and value >= 0) or match?(%DateTime{}, value)
end
