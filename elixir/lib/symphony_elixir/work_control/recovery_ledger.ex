defmodule SymphonyElixir.WorkControl.RecoveryLedger do
  @moduledoc """
  Small disk-backed boundary for work-control recovery facts.

  The ledger stores the last validated lifecycle checkpoint and the bounded
  suspension context needed for a fresh reconciliation. It does not restore
  runtime attempts or grant authority.
  """

  alias SymphonyElixir.Config.Schema

  alias SymphonyElixir.WorkControl.{
    GuardClass,
    ProviderObservation,
    SuspensionContext,
    WorkflowLifecycle
  }

  @schema_version 1
  @metadata_keys [:schema_version, :project_namespace, :tracker_identity]
  @checkpoint_keys [
    :schema_version,
    :project_namespace,
    :work_item_id,
    :last_validated_lifecycle_state,
    :durable_guard_evidence,
    :active_suspension_context,
    :last_terminal_suspension_context,
    :updated_at
  ]
  @identity_keys [:tracker_kind, :provider_scope]
  @tracker_scope_keys %{
    "memory" => [],
    "linear" => [:project_slug],
    "github" => [:repo],
    "gitlab" => [:repo],
    "jira" => [:project_key],
    "asana" => [:project_gid],
    "plane" => [:workspace_slug, :workspace_id, :project_id]
  }
  @empty_scope_kinds ["memory", "linear"]
  @suspension_context_keys [
    :work_item_id,
    :last_validated_lifecycle_state,
    :provider_observation,
    :reason,
    :lineage_generation,
    :created_at,
    :recovery_policy,
    :required_evidence,
    :resume_target,
    :status
  ]
  @provider_observation_keys [
    :provider,
    :work_item_id,
    :workspace_id,
    :project_id,
    :provider_state_id,
    :provider_state_group,
    :provider_state_name,
    :provider_updated_at,
    :observed_at,
    :snapshot_identity
  ]
  @forbidden_keys [
    :api_key,
    :authority_disposition,
    :credentials,
    :password,
    :pid,
    :prompt,
    :runtime_attempt,
    :runtime_attempt_id,
    :secret,
    :session,
    :thread,
    :timer,
    :token,
    :transcript,
    :workspace,
    :workspace_ownership,
    :workspace_path
  ]
  @forbidden_string_keys Enum.map(@forbidden_keys, &Atom.to_string/1)

  defstruct [:table, :path, :project_id, :tracker_identity, :write_fun, :sync_fun]

  @type checkpoint :: %{
          required(:schema_version) => pos_integer(),
          required(:project_namespace) => String.t(),
          required(:work_item_id) => String.t(),
          required(:last_validated_lifecycle_state) => WorkflowLifecycle.state(),
          required(:durable_guard_evidence) => [map()],
          required(:active_suspension_context) => SuspensionContext.t() | nil,
          required(:last_terminal_suspension_context) => SuspensionContext.t() | nil,
          required(:updated_at) => DateTime.t() | non_neg_integer()
        }

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
  def path_for(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    root =
      Keyword.get(opts, :root) ||
        Application.get_env(:symphony_elixir, :recovery_ledger_root) ||
        Application.get_env(:symphony_elixir, :work_control_recovery_ledger_root) ||
        default_root()

    case Keyword.get(opts, :path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> Path.join(Path.expand(root), project_id <> ".dets")
    end
  end

  @spec open(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(project_id, tracker_identity, opts \\ [])
      when is_binary(project_id) and is_map(tracker_identity) and is_list(opts) do
    with :ok <- validate_project_id(project_id),
         :ok <- validate_tracker_identity(tracker_identity),
         path <- path_for(project_id, opts),
         path_preexisted <- File.exists?(path),
         :ok <- ensure_parent_directory(path),
         {:ok, table} <- open_table(path) do
      result =
        with {:ok, ledger} <- build_ledger(table, path, project_id, tracker_identity, opts),
             :ok <- initialize_or_validate(ledger, not path_preexisted) do
          {:ok, ledger}
        end

      case result do
        {:ok, _ledger} ->
          result

        {:error, _reason} = error ->
          cleanup_new_empty_table(table, path, path_preexisted)
          _ = close_table(table)
          error
      end
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{table: table}), do: close_table(table)

  def close(_ledger), do: {:error, :invalid_recovery_ledger}

  @spec current(t(), String.t()) :: {:ok, checkpoint()} | :not_found | {:error, term()}
  def current(%__MODULE__{} = ledger, work_item_id) when is_binary(work_item_id) do
    if String.trim(work_item_id) == "" do
      {:error, {:corrupt_recovery_record, :invalid_record}}
    else
      current_record(ledger, work_item_id)
    end
  end

  def current(%__MODULE__{}, _work_item_id), do: {:error, {:corrupt_recovery_record, :invalid_record}}

  def current(_ledger, _work_item_id), do: {:error, {:corrupt_recovery_record, :invalid_record}}

  defp current_record(ledger, work_item_id) do
    with {:ok, records} <- validated_records(ledger) do
      find_current_record(records, work_item_id)
    end
  end

  defp find_current_record(records, work_item_id) do
    case Enum.find(records, fn
           {{:current, ^work_item_id}, _record} -> true
           _other -> false
         end) do
      {{:current, ^work_item_id}, record} -> {:ok, record}
      nil -> :not_found
    end
  end

  @spec list(t()) :: {:ok, [checkpoint()]} | {:error, term()}
  def list(%__MODULE__{} = ledger) do
    with {:ok, records} <- validated_records(ledger) do
      checkpoints =
        records
        |> Enum.filter(&match?({{:current, _work_item_id}, _record}, &1))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sort_by(& &1.work_item_id)

      {:ok, checkpoints}
    end
  end

  def list(_ledger), do: {:error, {:corrupt_recovery_record, :invalid_record}}

  @spec put_sync(t(), checkpoint() | map()) :: :ok | {:error, term()}
  def put_sync(%__MODULE__{} = ledger, checkpoint) when is_map(checkpoint) do
    with {:ok, _records} <- validated_records(ledger),
         {:ok, work_item_id} <- validate_checkpoint_for_write(checkpoint, ledger) do
      persist_records(ledger, [{{:current, work_item_id}, checkpoint}])
    end
  end

  def put_sync(_ledger, _checkpoint),
    do: {:error, {:corrupt_recovery_record, :invalid_record}}

  @spec sync(t()) :: :ok | {:error, term()}
  def sync(%__MODULE__{table: table, sync_fun: sync_fun}), do: invoke_sync(sync_fun, table)

  def sync(_ledger), do: {:error, {:ledger_sync_failed, :invalid_record}}

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

  defp initialize_or_validate(%__MODULE__{} = ledger, fresh?) do
    with {:ok, records} <- all_records(ledger) do
      case records do
        [] when fresh? ->
          persist_records(ledger, [{{:meta, ledger.project_id}, metadata(ledger)}])

        [] ->
          {:error, {:corrupt_recovery_record, :metadata, :missing_metadata}}

        _records ->
          validate_existing_table(ledger, records)
      end
    end
  end

  defp validate_existing_table(ledger, records) do
    case validate_table_records(records, ledger) do
      :ok -> sync_existing_table(ledger.table)
      {:error, _reason} = error -> error
    end
  end

  defp validated_records(%__MODULE__{} = ledger) do
    with {:ok, records} <- all_records(ledger),
         :ok <- validate_table_records(records, ledger) do
      {:ok, records}
    end
  end

  defp validate_table_records(records, ledger) do
    metadata_records = Enum.filter(records, &match?({{:meta, _project_id}, _metadata}, &1))

    with :ok <- validate_metadata_records(metadata_records, ledger) do
      validate_recovery_records(records, ledger)
    end
  end

  defp validate_metadata_records([], _ledger),
    do: {:error, {:corrupt_recovery_record, :metadata, :missing_metadata}}

  defp validate_metadata_records([{{:meta, stored_project}, metadata}], ledger) do
    with :ok <- validate_project_namespace(stored_project, ledger.project_id) do
      validate_metadata(metadata, ledger)
    end
  end

  defp validate_metadata_records(_records, _ledger),
    do: {:error, {:corrupt_recovery_record, :metadata, :invalid_record}}

  defp validate_metadata(metadata, ledger) when is_map(metadata) do
    with :ok <- validate_exact_keys(metadata, @metadata_keys),
         :ok <- validate_schema_version(Map.get(metadata, :schema_version)),
         :ok <- validate_project_namespace(Map.get(metadata, :project_namespace), ledger.project_id),
         :ok <- validate_tracker_identity(Map.get(metadata, :tracker_identity)) do
      if metadata.tracker_identity == ledger.tracker_identity do
        :ok
      else
        {:error, {:ledger_tracker_identity_mismatch, metadata.tracker_identity, ledger.tracker_identity}}
      end
    else
      {:error, {:ledger_project_namespace_mismatch, _stored, _expected} = error} -> {:error, error}
      {:error, {:ledger_schema_version_unsupported, _version} = error} -> {:error, error}
      {:error, :invalid_tracker_identity} -> {:error, :invalid_tracker_identity}
      {:error, _reason} -> {:error, {:corrupt_recovery_record, :metadata, :invalid_record}}
    end
  end

  defp validate_metadata(_metadata, _ledger),
    do: {:error, {:corrupt_recovery_record, :metadata, :invalid_record}}

  defp validate_recovery_records(records, ledger) do
    Enum.reduce_while(records, :ok, fn
      {{:meta, _project_id}, _metadata}, :ok ->
        {:cont, :ok}

      {{:current, work_item_id}, record}, :ok ->
        case validate_checkpoint(record, ledger, work_item_id) do
          :ok ->
            {:cont, :ok}

          {:error, {:ledger_schema_version_unsupported, _version} = error} ->
            {:halt, {:error, error}}

          {:error, {:ledger_project_namespace_mismatch, _stored, _expected} = error} ->
            {:halt, {:error, error}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_recovery_record, {:current, work_item_id}, reason}}}
        end

      {key, _record}, :ok ->
        {:halt, {:error, {:corrupt_recovery_record, key, :invalid_record}}}
    end)
  end

  defp validate_checkpoint_for_write(checkpoint, ledger) do
    work_item_id = Map.get(checkpoint, :work_item_id)

    case validate_checkpoint(checkpoint, ledger, work_item_id) do
      :ok -> {:ok, work_item_id}
      {:error, {:ledger_schema_version_unsupported, _version} = error} -> {:error, error}
      {:error, {:ledger_project_namespace_mismatch, _stored, _expected} = error} -> {:error, error}
      {:error, reason} -> {:error, {:corrupt_recovery_record, {:current, work_item_id}, reason}}
    end
  end

  defp validate_checkpoint(record, ledger, key)
       when is_map(record) and is_binary(key) do
    with :ok <- validate_exact_keys(record, @checkpoint_keys),
         :ok <- validate_schema_version(Map.get(record, :schema_version)),
         :ok <- validate_project_namespace(Map.get(record, :project_namespace), ledger.project_id),
         :ok <- validate_work_item_id(Map.get(record, :work_item_id)),
         :ok <- validate_matching_work_item_id(Map.get(record, :work_item_id), key),
         :ok <- validate_canonical_state(Map.get(record, :last_validated_lifecycle_state)),
         :ok <- validate_durable_guard_evidence(Map.get(record, :durable_guard_evidence)),
         :ok <-
           validate_suspension_context(
             Map.get(record, :active_suspension_context),
             :active,
             Map.get(record, :work_item_id),
             Map.get(record, :last_validated_lifecycle_state)
           ),
         :ok <-
           validate_suspension_context(
             Map.get(record, :last_terminal_suspension_context),
             :terminal,
             Map.get(record, :work_item_id),
             Map.get(record, :last_validated_lifecycle_state)
           ) do
      validate_updated_at(Map.get(record, :updated_at))
    end
  end

  defp validate_checkpoint(_record, _ledger, _key), do: {:error, :invalid_record}

  defp validate_suspension_context(nil, _kind, _work_item_id, _state), do: :ok

  defp validate_suspension_context(
         %SuspensionContext{} = context,
         kind,
         work_item_id,
         state
       ) do
    context_record = Map.from_struct(context)

    with :ok <- validate_exact_keys(context_record, @suspension_context_keys),
         :ok <- validate_matching_work_item_id(context.work_item_id, work_item_id),
         :ok <- validate_canonical_state(context.last_validated_lifecycle_state),
         :ok <- validate_context_state(context.last_validated_lifecycle_state, state, kind),
         :ok <- validate_provider_observation(context.provider_observation, work_item_id),
         :ok <- validate_reason(context.reason),
         :ok <- validate_lineage_generation(context.lineage_generation),
         :ok <- validate_datetime(context.created_at),
         :ok <- validate_recovery_policy(context.recovery_policy),
         :ok <- validate_required_evidence(context.required_evidence),
         :ok <- validate_resume_target(context.resume_target) do
      validate_context_status(context.status, kind)
    end
  end

  defp validate_suspension_context(_context, _kind, _work_item_id, _state),
    do: {:error, :invalid_suspension_context}

  defp validate_context_state(_context_state, _checkpoint_state, :terminal), do: :ok

  defp validate_context_state(context_state, checkpoint_state, :active)
       when context_state == checkpoint_state,
       do: :ok

  defp validate_context_state(_context_state, _checkpoint_state, :active),
    do: {:error, :invalid_suspension_context}

  defp validate_provider_observation(%ProviderObservation{} = observation, work_item_id) do
    with :ok <- validate_exact_keys(Map.from_struct(observation), @provider_observation_keys),
         :ok <- validate_work_item_id(observation.work_item_id),
         :ok <- validate_matching_work_item_id(observation.work_item_id, work_item_id),
         :ok <- validate_safe_term(observation.provider),
         :ok <- validate_non_empty_optional_string(observation.workspace_id),
         :ok <- validate_non_empty_optional_string(observation.project_id),
         :ok <- validate_non_empty_optional_string(observation.provider_state_id),
         :ok <- validate_safe_term(observation.provider_state_group),
         :ok <- validate_non_empty_string(observation.provider_state_name),
         :ok <- validate_datetime(observation.observed_at),
         :ok <- validate_optional_datetime(observation.provider_updated_at) do
      validate_safe_term(observation.snapshot_identity)
    end
  end

  defp validate_provider_observation(_observation, _work_item_id),
    do: {:error, :invalid_provider_observation}

  defp validate_context_status(status, :active) when status in [:open, :resolving], do: :ok
  defp validate_context_status(status, :terminal) when status in [:resolved, :escalated], do: :ok
  defp validate_context_status(_status, _kind), do: {:error, :invalid_suspension_status}

  defp validate_durable_guard_evidence(evidence) when is_list(evidence) do
    if Enum.all?(evidence, &valid_durable_guard_evidence?/1), do: :ok, else: {:error, :invalid_guard_evidence}
  end

  defp validate_durable_guard_evidence(_evidence), do: {:error, :invalid_guard_evidence}

  defp valid_durable_guard_evidence?(%{class: :mechanical_guard, name: name} = evidence)
       when is_atom(name) do
    GuardClass.valid_evidence?(evidence) and validate_safe_term(evidence) == :ok
  end

  defp valid_durable_guard_evidence?(_evidence), do: false

  defp validate_required_evidence(value) when is_list(value) do
    if Enum.all?(value, &valid_required_evidence?/1), do: :ok, else: {:error, :invalid_required_evidence}
  end

  defp validate_required_evidence(_value), do: {:error, :invalid_required_evidence}

  defp validate_reason(nil), do: {:error, :missing_reason}
  defp validate_reason(reason) when is_atom(reason), do: :ok
  defp validate_reason(_reason), do: {:error, :invalid_suspension_reason}

  defp validate_recovery_policy(nil), do: {:error, :invalid_recovery_policy}
  defp validate_recovery_policy(policy) when is_atom(policy), do: :ok
  defp validate_recovery_policy(_policy), do: {:error, :invalid_recovery_policy}

  defp valid_required_evidence?(value) when is_atom(value) and not is_nil(value), do: true

  defp valid_required_evidence?(%{class: class, name: name} = requirement)
       when is_atom(class) and is_atom(name) do
    validate_exact_keys(requirement, [:class, :name]) == :ok and
      GuardClass.valid?(requirement) and validate_safe_term(requirement) == :ok
  end

  defp valid_required_evidence?(_value), do: false

  defp validate_lineage_generation(nil), do: :ok

  defp validate_lineage_generation(value) when is_binary(value) do
    validate_non_empty_string(value)
  end

  defp validate_lineage_generation(_value), do: {:error, :invalid_lineage_generation}

  defp validate_resume_target(nil), do: :ok
  defp validate_resume_target(value) when is_atom(value), do: validate_canonical_state(value)
  defp validate_resume_target(_value), do: {:error, :invalid_resume_target}

  defp validate_matching_work_item_id(value, value) when is_binary(value), do: :ok
  defp validate_matching_work_item_id(_value, _expected), do: {:error, :invalid_record}

  defp validate_work_item_id(value), do: validate_non_empty_string(value)

  defp validate_canonical_state(value) when is_atom(value) do
    if WorkflowLifecycle.canonical?(value), do: :ok, else: {:error, :invalid_last_validated_lifecycle_state}
  end

  defp validate_canonical_state(_value), do: {:error, :invalid_last_validated_lifecycle_state}

  defp validate_updated_at(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_updated_at(value), do: validate_datetime(value)

  defp validate_optional_datetime(nil), do: :ok
  defp validate_optional_datetime(value), do: validate_datetime(value)

  defp validate_datetime(%DateTime{} = value) do
    case DateTime.to_iso8601(value) do
      iso when is_binary(iso) -> :ok
    end
  rescue
    _error -> {:error, :invalid_timestamp}
  end

  defp validate_datetime(_value), do: {:error, :invalid_timestamp}

  defp validate_non_empty_optional_string(nil), do: :ok
  defp validate_non_empty_optional_string(value), do: validate_non_empty_string(value)

  defp validate_non_empty_string(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_record}, else: :ok
  end

  defp validate_non_empty_string(_value), do: {:error, :invalid_record}

  defp validate_exact_keys(map, expected_keys) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(expected_keys), do: :ok, else: {:error, :invalid_record}
  end

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(version), do: {:error, {:ledger_schema_version_unsupported, version}}

  defp validate_project_namespace(stored, expected) when stored == expected and is_binary(stored), do: :ok

  defp validate_project_namespace(stored, expected),
    do: {:error, {:ledger_project_namespace_mismatch, stored, expected}}

  defp validate_project_id(project_id) do
    if Schema.valid_project_id?(project_id), do: :ok, else: {:error, {:invalid_symphony_project_id, project_id}}
  end

  defp validate_tracker_identity(identity) when is_map(identity) do
    cond do
      Enum.sort(Map.keys(identity)) != Enum.sort(@identity_keys) ->
        {:error, :invalid_tracker_identity}

      not is_binary(identity.tracker_kind) or String.trim(identity.tracker_kind) == "" ->
        {:error, :invalid_tracker_identity}

      not valid_scope?(identity.tracker_kind, identity.provider_scope) ->
        {:error, :invalid_tracker_identity}

      true ->
        :ok
    end
  end

  defp validate_tracker_identity(_identity), do: {:error, :invalid_tracker_identity}

  defp valid_scope?(kind, scope) when is_binary(kind) and is_map(scope) do
    case Map.fetch(@tracker_scope_keys, kind) do
      {:ok, expected_keys} ->
        keys_valid? =
          (map_size(scope) == 0 and kind in @empty_scope_kinds) or
            Enum.sort(Map.keys(scope)) == Enum.sort(expected_keys)

        keys_valid? and
          Enum.all?(scope, fn {key, value} ->
            key in expected_keys and is_binary(value) and String.trim(value) != ""
          end)

      :error ->
        false
    end
  end

  defp valid_scope?(_kind, _scope), do: false

  defp validate_safe_term(term), do: if(contains_forbidden_term?(term), do: {:error, :unsafe_record}, else: :ok)

  defp contains_forbidden_term?(term) when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
    do: true

  defp contains_forbidden_term?(term) when is_map(term) do
    Enum.any?(term, fn {key, value} ->
      forbidden_key?(key) or contains_forbidden_term?(key) or contains_forbidden_term?(value)
    end)
  end

  defp contains_forbidden_term?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&contains_forbidden_term?/1)

  defp contains_forbidden_term?(term) when is_list(term),
    do: Enum.any?(term, &contains_forbidden_term?/1)

  defp contains_forbidden_term?(_term), do: false

  defp forbidden_key?(key) when is_atom(key), do: key in @forbidden_keys
  defp forbidden_key?(key) when is_binary(key), do: key in @forbidden_string_keys
  defp forbidden_key?(_key), do: false

  defp persist_records(%__MODULE__{table: table, write_fun: write_fun} = ledger, records) do
    with :ok <- invoke_write(write_fun, table, records) do
      invoke_sync(ledger.sync_fun, table)
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

  defp cleanup_new_empty_table(table, path, false) do
    if :dets.info(table, :size) == 0 do
      _ = close_table(table)
      _ = File.rm(path)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_new_empty_table(_table, _path, _path_preexisted), do: :ok

  defp sync_existing_table(table) do
    case :dets.sync(table) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_sync_failed, reason}}
    end
  rescue
    error -> {:error, {:ledger_sync_failed, error}}
  catch
    kind, reason -> {:error, {:ledger_sync_failed, {kind, reason}}}
  end

  defp ensure_parent_directory(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:ledger_directory_failed, reason}}
    end
  end

  defp metadata(%__MODULE__{} = ledger) do
    %{
      schema_version: @schema_version,
      project_namespace: ledger.project_id,
      tracker_identity: ledger.tracker_identity
    }
  end

  defp default_root do
    state_root = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state_root, "symphony/work-control-recovery")
  end
end
