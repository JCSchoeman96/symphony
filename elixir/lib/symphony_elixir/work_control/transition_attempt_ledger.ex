defmodule SymphonyElixir.WorkControl.TransitionAttemptLedger do
  @moduledoc """
  Separate DETS ledger for provider lifecycle mutation attempts.

  This table intentionally does not share the runtime retry lineage schema.
  Every safety-critical write is followed by an explicit DETS sync.
  """

  alias SymphonyElixir.WorkControl.{TransitionAttempt, WorkflowLifecycle}

  @schema_version 1
  @reconciliation_statuses [:submitted, :mutation_submitted, :verifying, :conflict, :indeterminate]
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
  def get(%__MODULE__{table: table}, attempt_id) when is_binary(attempt_id) do
    case :dets.lookup(table, {:attempt, attempt_id}) do
      [{{:attempt, ^attempt_id}, attempt}] -> {:ok, attempt}
      [] -> :not_found
      _ -> {:error, {:corrupt_transition_attempt, :invalid_record}}
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

  @spec list_reconciliation_candidates(t()) :: {:ok, [term()]} | {:error, term()}
  def list_reconciliation_candidates(%__MODULE__{table: table}) do
    candidates =
      :dets.foldl(
        fn
          {{:attempt, _attempt_id}, attempt}, acc ->
            if reconciliation_candidate?(attempt), do: [attempt | acc], else: acc

          _other, acc ->
            acc
        end,
        [],
        table
      )

    rank = %{submitted: 0, mutation_submitted: 0, verifying: 1, conflict: 2, indeterminate: 3}

    sorted =
      Enum.sort_by(candidates, fn attempt ->
        {
          Map.get(rank, Map.get(attempt, :status) || Map.get(attempt, :state), 99),
          Map.get(attempt, :updated_at, 0),
          attempt_identifier(attempt)
        }
      end)

    {:ok, sorted}
  rescue
    _error -> {:error, {:corrupt_transition_attempt, :invalid_record}}
  end

  @spec resubmit_allowed?(term()) :: boolean()
  def resubmit_allowed?(%TransitionAttempt{} = attempt), do: TransitionAttempt.automatic_mutation_allowed?(attempt)
  def resubmit_allowed?(%{status: :prepared}), do: true
  def resubmit_allowed?(%{state: :prepared}), do: true
  def resubmit_allowed?(_attempt), do: false

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
    status in @reconciliation_statuses
  end

  defp attempt_identifier(attempt), do: Map.get(attempt, :attempt_id) || Map.get(attempt, :transition_attempt_id) || ""

  defp valid_state_pair?(record) do
    source = Map.get(record, :source_state) || Map.get(record, :requested_from)
    target = Map.get(record, :target_state) || Map.get(record, :requested_to)

    WorkflowLifecycle.canonical?(source) and WorkflowLifecycle.canonical?(target)
  end

  defp persist(%__MODULE__{table: table, write_fun: write_fun}, records) do
    case write_fun.(table, records) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_write_failed, reason}}
      other -> {:error, {:ledger_write_failed, other}}
    end
  rescue
    _error -> {:error, {:ledger_write_failed, :write_failed}}
  end

  defp sync(%__MODULE__{table: table, sync_fun: sync_fun}) do
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
