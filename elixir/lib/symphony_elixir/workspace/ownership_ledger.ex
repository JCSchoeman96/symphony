defmodule SymphonyElixir.Workspace.OwnershipLedger do
  @moduledoc """
  Disk-backed records for trusted workspace ownership.

  The ledger stores only ownership facts. Runtime attempts, sessions,
  preservation policy, and transition history belong to other boundaries.
  Every mutation writes to DETS and then synchronizes the table before it
  reports success.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workspace.Ownership

  @schema_version 1
  @metadata_keys [:schema_version, :project_namespace, :tracker_identity]
  @record_keys [
    :schema_version,
    :project_namespace,
    :tracker_identity,
    :issue_identifier,
    :work_item_id,
    :workspace_key,
    :workspace_ownership_id,
    :location,
    :worker_host,
    :trusted_host_identity,
    :configured_root,
    :configured_root_identity,
    :canonical_root,
    :canonical_workspace_path,
    :top_level_filesystem_identity,
    :release_origin,
    :state,
    :created_at,
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

  defstruct [
    :table,
    :path,
    :root,
    :host_identity_path,
    :host_identity,
    :project_id,
    :tracker_identity,
    :write_fun,
    :sync_fun
  ]

  @type record :: %{atom() => term()}

  @type t :: %__MODULE__{
          table: term(),
          path: Path.t(),
          root: Path.t(),
          host_identity_path: Path.t(),
          host_identity: String.t(),
          project_id: String.t(),
          tracker_identity: map(),
          write_fun: (term(), term() -> term()),
          sync_fun: (term() -> term())
        }

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec path_for(String.t(), keyword()) :: Path.t()
  def path_for(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    case Keyword.get(opts, :path) || Keyword.get(opts, :ledger_path) do
      path when is_binary(path) ->
        Path.expand(path)

      _ ->
        root = root_for(opts)
        Path.join(Path.expand(root), project_id <> ".dets")
    end
  end

  @spec host_identity_path(keyword()) :: Path.t()
  def host_identity_path(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :host_identity_path) do
      path when is_binary(path) -> Path.expand(path)
      _ -> Path.join(Path.expand(root_for(opts)), "host.identity")
    end
  end

  @spec open(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(project_id, tracker_identity, opts \\ [])
      when is_binary(project_id) and is_map(tracker_identity) and is_list(opts) do
    with :ok <- validate_project_id(project_id),
         :ok <- validate_tracker_identity(tracker_identity),
         path <- path_for(project_id, opts),
         root <- Path.expand(root_for(opts)),
         identity_path <- host_identity_path(Keyword.put_new(opts, :root, root)),
         :ok <- validate_host_identity_path(path, identity_path),
         :ok <- validate_storage_outside_workspace(path, identity_path, root, Keyword.get(opts, :workspace_root)),
         :ok <- ensure_private_directory(root),
         :ok <- ensure_private_directory(Path.dirname(path)),
         :ok <- ensure_private_directory(Path.dirname(identity_path)),
         {:ok, host_identity} <- ensure_local_host_identity(identity_path),
         {:ok, path_preexisted} <- ledger_path_status(path),
         {:ok, table} <- open_table(path) do
      result =
        with {:ok, ledger} <-
               build_ledger(
                 table,
                 path,
                 root,
                 identity_path,
                 host_identity,
                 project_id,
                 tracker_identity,
                 opts
               ),
             :ok <- initialize_or_validate(ledger, not path_preexisted) do
          {:ok, ledger}
        end

      case result do
        {:ok, _ledger} ->
          result

        {:error, _reason} = error ->
          cleanup_new_table(table, path, path_preexisted)
          _ = close_table(table)
          error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{table: table}), do: close_table(table)

  def close(_ledger), do: {:error, {:ledger_close_failed, :invalid_record}}

  @spec local_host_identity(keyword()) :: {:ok, String.t()} | {:error, term()}
  def local_host_identity(opts \\ []) when is_list(opts) do
    path = host_identity_path(opts)
    workspace_path = Keyword.get(opts, :workspace_path)

    with :ok <- validate_local_host_identity_path(path, workspace_path),
         :ok <- ensure_private_directory(Path.dirname(path)) do
      ensure_local_host_identity(path)
    end
  end

  @spec filesystem_identity(Path.t()) :: {:ok, Ownership.filesystem_identity()} | {:error, term()}
  def filesystem_identity(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        stat_filesystem_identity(path)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:filesystem_identity_failed, {:not_directory, type}}}

      {:error, reason} ->
        {:error, {:filesystem_identity_failed, reason}}
    end
  rescue
    error -> {:error, {:filesystem_identity_failed, error}}
  end

  def filesystem_identity(_path), do: {:error, {:filesystem_identity_failed, :invalid_path}}

  defp stat_filesystem_identity(path) do
    {args, birth_identity_kind} = filesystem_identity_stat_command(path, :os.type())

    case System.cmd("stat", args, stderr_to_stdout: true) do
      {output, 0} ->
        parse_stat_filesystem_identity(output, birth_identity_kind)

      {output, status} ->
        {:error, {:filesystem_identity_failed, {:stat_failed, status, String.trim(output)}}}
    end
  end

  @doc false
  @spec filesystem_identity_stat_command(Path.t(), term()) ::
          {nonempty_list(String.t()), :birth_time | :generation}
  def filesystem_identity_stat_command(path, {:unix, :darwin}),
    do: {["-f", "%Xp|%d|%i|%v", "--", path], :generation}

  def filesystem_identity_stat_command(path, _os_type),
    do: {["-c", "%f|%d|%i|%w", "--", path], :birth_time}

  @doc false
  @spec parse_stat_filesystem_identity(binary(), :birth_time | :generation) ::
          {:ok, Ownership.filesystem_identity()} | {:error, term()}
  def parse_stat_filesystem_identity(output, birth_identity_kind) do
    with [mode, device, inode, birth_time] <- String.trim(output) |> String.split("|", parts: 4),
         {mode, ""} <- Integer.parse(mode, 16),
         true <- Bitwise.band(mode, 0xF000) == 0x4000,
         {device, ""} <- Integer.parse(device),
         {inode, ""} <- Integer.parse(inode),
         {:ok, birth_identity} <- filesystem_birth_identity(birth_time, birth_identity_kind) do
      {:ok, Map.merge(%{device: device, inode: inode}, birth_identity)}
    else
      false -> {:error, {:filesystem_identity_failed, {:not_directory, :unknown}}}
      {:error, _reason} = error -> error
      _other -> {:error, {:filesystem_identity_failed, :invalid_stat_output}}
    end
  end

  defp filesystem_birth_identity("-", :birth_time) do
    {:error, {:filesystem_identity_failed, :birth_time_unavailable}}
  end

  defp filesystem_birth_identity(generation, :generation) do
    case Integer.parse(generation) do
      {value, ""} when value > 0 -> {:ok, %{generation: value}}
      {0, ""} -> {:error, {:filesystem_identity_failed, :generation_unavailable}}
      _other -> {:error, {:filesystem_identity_failed, :invalid_generation}}
    end
  end

  defp filesystem_birth_identity(birth_time, :birth_time) do
    case System.cmd("date", ["-d", birth_time, "+%s%N"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {value, ""} -> {:ok, %{birth_time_ns: value}}
          _other -> {:error, {:filesystem_identity_failed, :invalid_birth_time}}
        end

      {_output, _status} ->
        {:error, {:filesystem_identity_failed, :invalid_birth_time}}
    end
  end

  @spec root_identity(Path.t()) :: {:ok, Ownership.filesystem_identity()} | {:error, term()}
  def root_identity(path), do: filesystem_identity(path)

  @spec reserve(t(), map()) :: {:ok, record()} | {:error, term()}
  def reserve(ledger, attrs), do: reserve_sync(ledger, attrs)

  @spec reserve_sync(t(), map()) :: {:ok, record()} | {:error, term()}
  def reserve_sync(%__MODULE__{} = ledger, attrs) when is_map(attrs) do
    serialize_mutation(ledger, fn -> reserve_sync_unlocked(ledger, attrs) end)
  end

  def reserve_sync(_ledger, _attrs), do: {:error, {:corrupt_ownership_record, :invalid_record}}

  defp reserve_sync_unlocked(%__MODULE__{} = ledger, attrs) do
    with {:ok, records} <- validated_records(ledger),
         {:ok, record} <- build_reserved_record(ledger, attrs),
         :ok <- ensure_ownership_id_available(records, record),
         :ok <- ensure_resource_identity_available(records, record),
         :ok <- persist_records(ledger, [{{:ownership, record.workspace_ownership_id}, record}]) do
      {:ok, record}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec put_sync(t(), map()) :: {:ok, record()} | {:error, term()}
  def put_sync(ledger, attrs), do: reserve_sync(ledger, attrs)

  @spec get(t(), String.t()) :: {:ok, record()} | :not_found | {:error, term()}
  def get(%__MODULE__{} = ledger, ownership_id) when is_binary(ownership_id) do
    if String.trim(ownership_id) == "" do
      {:error, {:corrupt_ownership_record, :invalid_record}}
    else
      with {:ok, records} <- validated_records(ledger) do
        find_ownership(records, ownership_id)
      end
    end
  end

  def get(_ledger, _ownership_id), do: {:error, {:corrupt_ownership_record, :invalid_record}}

  @spec lookup(t(), String.t()) :: {:ok, record()} | :not_found | {:error, term()}
  def lookup(ledger, ownership_id), do: get(ledger, ownership_id)

  @spec current(t(), String.t()) :: {:ok, record()} | :not_found | {:error, term()}
  def current(ledger, ownership_id), do: get(ledger, ownership_id)

  @spec list(t()) :: {:ok, [record()]} | {:error, term()}
  def list(%__MODULE__{} = ledger) do
    with {:ok, records} <- validated_records(ledger) do
      records
      |> ownership_records()
      |> Enum.sort_by(& &1.workspace_ownership_id)
      |> then(&{:ok, &1})
    end
  end

  def list(_ledger), do: {:error, {:corrupt_ownership_record, :invalid_record}}

  @spec list_for_work_item(t(), String.t()) :: {:ok, [record()]} | {:error, term()}
  def list_for_work_item(%__MODULE__{} = ledger, work_item_id) when is_binary(work_item_id) do
    if String.trim(work_item_id) == "" do
      {:error, {:corrupt_ownership_record, :invalid_record}}
    else
      with {:ok, records} <- validated_records(ledger) do
        records
        |> ownership_records()
        |> Enum.filter(&(&1.work_item_id == work_item_id))
        |> Enum.sort_by(& &1.workspace_ownership_id)
        |> then(&{:ok, &1})
      end
    end
  end

  def list_for_work_item(_ledger, _work_item_id),
    do: {:error, {:corrupt_ownership_record, :invalid_record}}

  @spec list_for_host(t(), String.t() | nil) :: {:ok, [record()]} | {:error, term()}
  def list_for_host(%__MODULE__{} = ledger, worker_host) when is_nil(worker_host) or is_binary(worker_host) do
    if is_binary(worker_host) and String.trim(worker_host) == "" do
      {:error, {:corrupt_ownership_record, :invalid_record}}
    else
      with {:ok, records} <- validated_records(ledger) do
        records
        |> ownership_records()
        |> Enum.filter(&(&1.worker_host == worker_host))
        |> Enum.sort_by(& &1.workspace_ownership_id)
        |> then(&{:ok, &1})
      end
    end
  end

  def list_for_host(_ledger, _worker_host),
    do: {:error, {:corrupt_ownership_record, :invalid_record}}

  @spec list_for_worker_host(t(), String.t() | nil) :: {:ok, [record()]} | {:error, term()}
  def list_for_worker_host(ledger, worker_host), do: list_for_host(ledger, worker_host)

  @spec transition(t(), String.t(), term()) :: {:ok, record()} | {:error, term()}
  def transition(ledger, ownership_id, state),
    do: transition_sync(ledger, ownership_id, state, [])

  @spec transition(t(), String.t(), term(), map() | keyword() | Ownership.filesystem_identity()) ::
          {:ok, record()} | {:error, term()}
  def transition(ledger, ownership_id, state, attrs),
    do: transition_sync(ledger, ownership_id, state, attrs)

  @spec transition_sync(t(), String.t(), term()) :: {:ok, record()} | {:error, term()}
  def transition_sync(ledger, ownership_id, state),
    do: transition_sync(ledger, ownership_id, state, [])

  @spec transition_sync(t(), String.t(), term(), map() | keyword() | Ownership.filesystem_identity()) ::
          {:ok, record()} | {:error, term()}
  def transition_sync(%__MODULE__{} = ledger, ownership_id, state, attrs)
      when is_binary(ownership_id) and
             (is_map(attrs) or is_list(attrs) or is_binary(attrs) or is_tuple(attrs)) do
    serialize_mutation(ledger, fn -> transition_sync_unlocked(ledger, ownership_id, state, attrs) end)
  end

  def transition_sync(_ledger, _ownership_id, _state, _attrs),
    do: {:error, {:corrupt_ownership_record, :invalid_record}}

  defp transition_sync_unlocked(ledger, ownership_id, state, attrs) do
    with {:ok, transition_attrs} <- normalize_transition_attrs(attrs),
         {:ok, records} <- validated_records(ledger),
         {:ok, current} <- current_ownership(records, ownership_id),
         {:ok, next_state} <- Ownership.transition(current.state, state),
         :ok <- validate_transition_attrs(next_state, current, transition_attrs),
         {:ok, updated} <- updated_record(current, next_state, transition_attrs),
         :ok <- validate_record(updated, ledger, ownership_id),
         :ok <- ensure_transition_resource_identity_available(records, updated),
         :ok <- persist_records(ledger, [{{:ownership, ownership_id}, updated}]) do
      {:ok, updated}
    end
  end

  @spec sync(t()) :: :ok | {:error, term()}
  def sync(%__MODULE__{table: table, sync_fun: sync_fun}), do: invoke_sync(sync_fun, table)

  def sync(_ledger), do: {:error, {:ledger_sync_failed, :invalid_record}}

  defp root_for(opts) do
    Keyword.get(opts, :root) ||
      Application.get_env(:symphony_elixir, :workspace_ownership_ledger_root) ||
      Application.get_env(:symphony_elixir, :workspace_ownership_root) ||
      attempt_ledger_root() ||
      default_root()
  end

  defp attempt_ledger_root do
    case Application.get_env(:symphony_elixir, :attempt_ledger_root) do
      root when is_binary(root) -> Path.join(root, "workspace-ownership")
      _ -> nil
    end
  end

  defp default_root do
    state_root = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(state_root, "symphony/workspace-ownership")
  end

  defp build_ledger(
         table,
         path,
         root,
         identity_path,
         host_identity,
         project_id,
         tracker_identity,
         opts
       ) do
    write_fun = Keyword.get(opts, :write_fun, &:dets.insert/2)
    sync_fun = Keyword.get(opts, :sync_fun, &:dets.sync/1)

    if is_function(write_fun, 2) and is_function(sync_fun, 1) do
      {:ok,
       %__MODULE__{
         table: table,
         path: path,
         root: root,
         host_identity_path: identity_path,
         host_identity: host_identity,
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
      initialize_records(ledger, records, fresh?)
    end
  end

  defp initialize_records(ledger, [], true),
    do: persist_records(ledger, [{{:meta, ledger.project_id}, metadata(ledger)}])

  defp initialize_records(_ledger, [], false),
    do: {:error, {:corrupt_ownership_record, :metadata, :missing_metadata}}

  defp initialize_records(ledger, records, _fresh?),
    do: validate_existing_records(ledger, records)

  defp validate_existing_records(ledger, records) do
    with :ok <- validate_table_records(records, ledger) do
      sync_existing_table(ledger.table)
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
      validate_ownership_records(records, ledger)
    end
  end

  defp validate_metadata_records([], _ledger),
    do: {:error, {:corrupt_ownership_record, :metadata, :missing_metadata}}

  defp validate_metadata_records([{{:meta, project_id}, metadata}], ledger) do
    with :ok <- validate_metadata_project(project_id, ledger.project_id),
         :ok <- validate_metadata(metadata, ledger) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_metadata_records(_records, _ledger),
    do: {:error, {:corrupt_ownership_record, :metadata, :invalid_record}}

  defp validate_metadata(metadata, ledger) when is_map(metadata) do
    validate_metadata_values(metadata, ledger)
  end

  defp validate_metadata(_metadata, _ledger),
    do: {:error, {:corrupt_ownership_record, :metadata, :invalid_record}}

  defp validate_metadata_values(metadata, ledger) do
    if Enum.sort(Map.keys(metadata)) != Enum.sort(@metadata_keys) do
      {:error, {:corrupt_ownership_record, :metadata, :invalid_record}}
    else
      with :ok <- validate_schema_version(Map.get(metadata, :schema_version)),
           :ok <- validate_project_namespace(Map.get(metadata, :project_namespace), ledger.project_id),
           :ok <- validate_tracker_identity(Map.get(metadata, :tracker_identity)) do
        validate_tracker_identity_match(metadata.tracker_identity, ledger.tracker_identity)
      end
    end
  end

  defp validate_metadata_project(stored, expected) when stored == expected and is_binary(stored), do: :ok

  defp validate_metadata_project(stored, expected),
    do: {:error, {:ledger_project_namespace_mismatch, stored, expected}}

  defp validate_ownership_records(records, ledger) do
    Enum.reduce_while(records, :ok, fn
      {{:meta, _project_id}, _metadata}, :ok ->
        {:cont, :ok}

      {{:ownership, ownership_id}, record}, :ok when is_binary(ownership_id) ->
        case validate_record(record, ledger, ownership_id) do
          :ok ->
            {:cont, :ok}

          {:error, {:ledger_schema_version_unsupported, version}} ->
            {:halt, {:error, {:ledger_schema_version_unsupported, version}}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_ownership_record, {:ownership, ownership_id}, reason}}}
        end

      {key, _record}, :ok ->
        {:halt, {:error, {:corrupt_ownership_record, key, :invalid_record}}}
    end)
  end

  defp build_reserved_record(ledger, attrs) do
    with :ok <- validate_reserved_input(attrs),
         {:ok, attrs} <- derive_workspace_key(attrs),
         {:ok, attrs} <- normalize_configured_root(attrs),
         attrs <- Map.delete(attrs, :identifier),
         record <-
           attrs
           |> Map.put_new(:schema_version, @schema_version)
           |> Map.put_new(:project_namespace, ledger.project_id)
           |> Map.put_new(:tracker_identity, ledger.tracker_identity)
           |> Map.put_new(:location, :local)
           |> Map.put_new(:worker_host, nil)
           |> Map.put_new(:trusted_host_identity, default_trusted_host_identity(ledger, attrs))
           |> Map.put_new(:configured_root_identity, nil)
           |> Map.put_new(:top_level_filesystem_identity, nil)
           |> Map.put_new(:release_origin, nil)
           |> Map.put_new(:state, :reserved)
           |> Map.put_new(:created_at, now_ms())
           |> Map.put_new(:updated_at, now_ms()),
         :ok <- validate_record(record, ledger, nil) do
      {:ok, record}
    end
  end

  defp ensure_ownership_id_available(records, record) do
    case find_ownership(records, record.workspace_ownership_id) do
      :not_found -> :ok
      {:ok, _existing} -> {:error, {:ownership_id_already_exists, record.workspace_ownership_id}}
    end
  end

  defp ensure_resource_identity_available(records, record) do
    case Enum.find(ownership_records(records), fn existing ->
           existing.state != :released and resource_identity(existing) == resource_identity(record)
         end) do
      nil ->
        :ok

      existing ->
        {:error, {:resource_identity_already_claimed, resource_identity(existing)}}
    end
  end

  defp ensure_transition_resource_identity_available(records, record) do
    if record.state == :released do
      :ok
    else
      transition_resource_identity_result(records, record)
    end
  end

  defp transition_resource_identity_result(records, record) do
    case Enum.find(ownership_records(records), fn existing ->
           existing.workspace_ownership_id != record.workspace_ownership_id and
             existing.state != :released and
             resource_identity(existing) == resource_identity(record)
         end) do
      nil ->
        :ok

      existing ->
        {:error, {:resource_identity_already_claimed, resource_identity(existing)}}
    end
  end

  defp resource_identity(%{location: :local} = record) do
    configured_root = record.configured_root
    root_identity = record.configured_root_identity
    root = record.canonical_root
    workspace = record.canonical_workspace_path

    {:local, configured_root, root_identity, root, workspace}
  end

  defp resource_identity(%{location: :remote} = record) do
    host = record.worker_host
    identity = record.trusted_host_identity
    root_identity = record.configured_root_identity
    configured_root = record.configured_root
    root = record.canonical_root
    workspace = record.canonical_workspace_path

    {:remote, host, identity, configured_root, root_identity, root, workspace}
  end

  defp validate_reserved_input(attrs) do
    case Map.fetch(attrs, :state) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, :reserved} -> :ok
      {:ok, state} -> {:error, {:invalid_ownership_state, state}}
    end
  end

  defp derive_workspace_key(attrs) do
    with {:ok, issue_identifier} <- issue_identifier_input(attrs),
         :ok <- validate_non_empty_string(issue_identifier),
         derived <- Ownership.workspace_key(issue_identifier),
         {:ok, attrs} <- workspace_key_input(attrs, derived) do
      {:ok, Map.put(attrs, :issue_identifier, issue_identifier)}
    end
  end

  defp normalize_configured_root(attrs) do
    case Map.fetch(attrs, :configured_root) do
      {:ok, configured_root} when is_binary(configured_root) ->
        with :ok <- validate_non_empty_string(configured_root) do
          normalized_root = configured_root |> String.trim_trailing("/") |> normalize_root_slash()
          {:ok, Map.put(attrs, :configured_root, normalized_root)}
        end

      _ ->
        {:error, {:corrupt_ownership_record, :invalid_record}}
    end
  end

  defp issue_identifier_input(attrs) do
    case {Map.fetch(attrs, :issue_identifier), Map.fetch(attrs, :identifier)} do
      {{:ok, issue_identifier}, :error} ->
        {:ok, issue_identifier}

      {:error, {:ok, identifier}} ->
        {:ok, identifier}

      {{:ok, issue_identifier}, {:ok, issue_identifier}} ->
        {:ok, issue_identifier}

      {{:ok, _issue_identifier}, {:ok, _identifier}} ->
        {:error, {:issue_identifier_mismatch, Map.get(attrs, :issue_identifier), Map.get(attrs, :identifier)}}

      _ ->
        {:error, {:corrupt_ownership_record, :invalid_record}}
    end
  end

  defp workspace_key_input(attrs, derived) do
    case Map.fetch(attrs, :workspace_key) do
      :error -> {:ok, Map.put(attrs, :workspace_key, derived)}
      {:ok, ^derived} -> {:ok, attrs}
      {:ok, workspace_key} -> {:error, {:workspace_key_mismatch, workspace_key, derived}}
    end
  end

  defp default_trusted_host_identity(ledger, attrs) do
    case Map.get(attrs, :location, :local) do
      :local -> ledger.host_identity
      _remote -> nil
    end
  end

  defp find_ownership(records, ownership_id) do
    case Enum.find(records, fn
           {{:ownership, ^ownership_id}, _record} -> true
           _other -> false
         end) do
      {{:ownership, ^ownership_id}, record} -> {:ok, record}
      nil -> :not_found
    end
  end

  defp current_ownership(records, ownership_id) do
    case find_ownership(records, ownership_id) do
      {:ok, record} -> {:ok, record}
      :not_found -> :not_found
    end
  end

  defp ownership_records(records) do
    records
    |> Enum.filter(&match?({{:ownership, _ownership_id}, _record}, &1))
    |> Enum.map(&elem(&1, 1))
  end

  defp normalize_transition_attrs(attrs) when is_map(attrs) do
    if filesystem_identity_map?(attrs) do
      {:ok, %{top_level_filesystem_identity: attrs}}
    else
      {:ok, attrs}
    end
  end

  defp normalize_transition_attrs(identity) when is_binary(identity),
    do: {:ok, %{top_level_filesystem_identity: identity}}

  defp normalize_transition_attrs(identity) when is_tuple(identity) and tuple_size(identity) in [2, 3],
    do: {:ok, %{top_level_filesystem_identity: identity}}

  defp normalize_transition_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs), do: {:ok, Map.new(attrs)}, else: {:error, :invalid_transition_attributes}
  end

  defp normalize_transition_attrs(_attrs), do: {:error, :invalid_transition_attributes}

  defp filesystem_identity_map?(%{device: _device, inode: _inode, birth_time_ns: _birth_time_ns} = identity) do
    Enum.sort(Map.keys(identity)) == [:birth_time_ns, :device, :inode]
  end

  defp filesystem_identity_map?(%{device: _device, inode: _inode, generation: _generation} = identity) do
    Enum.sort(Map.keys(identity)) == [:device, :generation, :inode]
  end

  defp filesystem_identity_map?(%{device: _device, inode: _inode} = identity) do
    Enum.sort(Map.keys(identity)) == [:device, :inode]
  end

  defp filesystem_identity_map?(%{major_device: _major, minor_device: _minor, inode: _inode} = identity) do
    Enum.sort(Map.keys(identity)) == [:inode, :major_device, :minor_device]
  end

  defp filesystem_identity_map?(_identity), do: false

  defp validate_transition_attrs(next_state, current, attrs) do
    filesystem_identity = Map.get(attrs, :top_level_filesystem_identity, current.top_level_filesystem_identity)
    release_origin = Map.get(attrs, :release_origin, :authorized_cleanup)

    with :ok <- validate_transition_attribute_keys(attrs),
         :ok <- validate_transition_release_origin(next_state, attrs, release_origin),
         :ok <- validate_transition_filesystem_identity(next_state, filesystem_identity),
         do: validate_transition_filesystem_identity_change(next_state, current, attrs)
  end

  defp validate_transition_attribute_keys(attrs) do
    allowed = [:configured_root_identity, :top_level_filesystem_identity, :release_origin, :updated_at]

    if Enum.any?(Map.keys(attrs), &(&1 not in allowed)),
      do: {:error, :invalid_transition_attributes},
      else: :ok
  end

  defp validate_transition_release_origin(:release_pending, _attrs, release_origin)
       when release_origin in [:authorized_cleanup, :failed_provisioning],
       do: :ok

  defp validate_transition_release_origin(:release_pending, _attrs, release_origin),
    do: {:error, {:invalid_workspace_release_origin, release_origin}}

  defp validate_transition_release_origin(_next_state, attrs, _release_origin) do
    if Map.has_key?(attrs, :release_origin),
      do: {:error, :invalid_transition_attributes},
      else: :ok
  end

  defp validate_transition_filesystem_identity(next_state, nil)
       when next_state in [:provisioning, :owned, :release_pending],
       do: {:error, :missing_top_level_filesystem_identity}

  defp validate_transition_filesystem_identity(_next_state, _identity), do: :ok

  defp validate_transition_filesystem_identity_change(next_state, current, attrs) do
    if top_level_filesystem_identity_changed?(next_state, current, attrs),
      do: top_level_filesystem_identity_mismatch(current, attrs),
      else: :ok
  end

  defp top_level_filesystem_identity_mismatch(current, attrs) do
    current_identity = current.top_level_filesystem_identity
    requested_identity = attrs.top_level_filesystem_identity

    {:error, {:top_level_filesystem_identity_mismatch, current_identity, requested_identity}}
  end

  defp top_level_filesystem_identity_changed?(next_state, current, attrs) do
    next_state in [:owned, :release_pending] and
      Map.has_key?(attrs, :top_level_filesystem_identity) and
      not is_nil(current.top_level_filesystem_identity) and
      attrs.top_level_filesystem_identity != current.top_level_filesystem_identity
  end

  defp updated_record(record, state, attrs) do
    updated_at = Map.get(attrs, :updated_at, now_ms())

    updated =
      record
      |> Map.put(:state, state)
      |> Map.put(:updated_at, updated_at)

    updated =
      if Map.has_key?(attrs, :top_level_filesystem_identity) do
        Map.put(updated, :top_level_filesystem_identity, attrs.top_level_filesystem_identity)
      else
        updated
      end

    updated =
      case state do
        :release_pending -> Map.put(updated, :release_origin, Map.get(attrs, :release_origin, :authorized_cleanup))
        :owned -> Map.put(updated, :release_origin, nil)
        :released -> updated
        _ -> Map.put(updated, :release_origin, nil)
      end

    if Map.has_key?(attrs, :configured_root_identity) do
      {:ok, Map.put(updated, :configured_root_identity, attrs.configured_root_identity)}
    else
      {:ok, updated}
    end
  end

  defp validate_record(record, ledger, expected_ownership_id)
       when is_map(record) do
    with :ok <- validate_record_keys(record),
         :ok <- validate_schema_version(Map.get(record, :schema_version)),
         :ok <- validate_project_namespace(Map.get(record, :project_namespace), ledger.project_id),
         :ok <- validate_tracker_identity(Map.get(record, :tracker_identity)),
         :ok <- validate_tracker_identity_match(record.tracker_identity, ledger.tracker_identity),
         :ok <- validate_non_empty_string(Map.get(record, :issue_identifier)),
         :ok <- validate_non_empty_string(Map.get(record, :work_item_id)),
         :ok <- validate_workspace_key(Map.get(record, :workspace_key)),
         :ok <- validate_workspace_key_for_issue(record),
         :ok <- validate_non_empty_string(Map.get(record, :workspace_ownership_id)),
         :ok <- validate_expected_ownership_id(record.workspace_ownership_id, expected_ownership_id),
         :ok <- validate_location(record),
         :ok <- validate_trusted_host_identity(record, ledger.host_identity),
         :ok <- validate_configured_root(Map.get(record, :configured_root)),
         :ok <- validate_root_identity(record),
         :ok <- validate_canonical_root(Map.get(record, :canonical_root)),
         :ok <- validate_canonical_workspace_path(record),
         :ok <- validate_record_filesystem_identities(record),
         :ok <- validate_state(record),
         :ok <- validate_timestamp(Map.get(record, :created_at)),
         :ok <- validate_timestamp(Map.get(record, :updated_at)),
         :ok <- validate_host_identity_outside_workspace(record, ledger.host_identity_path) do
      validate_ledger_path_outside_workspace(record, ledger.path)
    end
  end

  defp validate_record(_record, _ledger, _expected_ownership_id), do: {:error, :invalid_record}

  defp validate_record_keys(record) do
    if Enum.sort(Map.keys(record)) == Enum.sort(@record_keys), do: :ok, else: {:error, :invalid_record}
  end

  defp validate_expected_ownership_id(_stored, nil), do: :ok
  defp validate_expected_ownership_id(stored, expected) when stored == expected, do: :ok
  defp validate_expected_ownership_id(_stored, _expected), do: {:error, :invalid_record}

  defp validate_location(%{location: :local, worker_host: nil}), do: :ok

  defp validate_location(%{location: :remote, worker_host: host}) when is_binary(host) do
    validate_non_empty_string(host)
  end

  defp validate_location(_record), do: {:error, :invalid_record}

  defp validate_trusted_host_identity(
         %{location: :local, trusted_host_identity: identity},
         local_identity
       )
       when identity == local_identity do
    validate_non_empty_string(identity)
  end

  defp validate_trusted_host_identity(%{location: :local}, _local_identity),
    do: {:error, :invalid_record}

  defp validate_trusted_host_identity(%{location: :remote, trusted_host_identity: identity}, _local_identity),
    do: validate_non_empty_string(identity)

  defp validate_trusted_host_identity(_record, _local_identity), do: {:error, :invalid_record}

  defp validate_workspace_key(value) do
    with :ok <- validate_non_empty_string(value) do
      if Ownership.workspace_key(value) == value, do: :ok, else: {:error, :invalid_record}
    end
  end

  defp validate_workspace_key_for_issue(%{issue_identifier: issue_identifier, workspace_key: workspace_key}) do
    if Ownership.workspace_key(issue_identifier) == workspace_key,
      do: :ok,
      else: {:error, :invalid_record}
  end

  defp validate_workspace_key_for_issue(_record), do: {:error, :invalid_record}

  defp validate_canonical_root(value), do: validate_canonical_path(value)

  defp validate_configured_root(value) when is_binary(value) do
    if value == normalize_configured_root_value(value) and
         not String.contains?(value, [<<0>>, "\n", "\r", "\t"]) do
      :ok
    else
      {:error, :invalid_record}
    end
  end

  defp validate_configured_root(_value), do: {:error, :invalid_record}

  defp normalize_configured_root_value(value) do
    value |> String.trim_trailing("/") |> normalize_root_slash()
  end

  defp normalize_root_slash(""), do: "/"
  defp normalize_root_slash(root), do: root

  defp validate_canonical_workspace_path(%{
         canonical_root: root,
         canonical_workspace_path: path,
         workspace_key: workspace_key
       }) do
    with :ok <- validate_canonical_path(path) do
      if path_under?(path, root) and Path.basename(path) == workspace_key,
        do: :ok,
        else: {:error, :invalid_record}
    end
  end

  defp validate_canonical_workspace_path(_record), do: {:error, :invalid_record}

  defp validate_canonical_path(value) when is_binary(value) do
    cond do
      Path.type(value) != :absolute -> {:error, :invalid_record}
      String.contains?(value, <<0>>) -> {:error, :invalid_record}
      Path.expand(value) != value -> {:error, :invalid_record}
      true -> :ok
    end
  end

  defp validate_canonical_path(_value), do: {:error, :invalid_record}

  defp validate_state(%{state: state, top_level_filesystem_identity: identity} = record) do
    release_origin = Map.get(record, :release_origin)

    with :ok <- validate_persisted_ownership_state(state),
         :ok <- validate_persisted_root_identity(record),
         :ok <- validate_persisted_workspace_identity(state, identity),
         :ok <- validate_persisted_release_pending_origin(state, release_origin),
         :ok <- validate_persisted_released_origin(state, release_origin),
         do: validate_absent_release_origin_before_cleanup(state, release_origin)
  end

  defp validate_state(_record), do: {:error, :invalid_record}

  defp validate_persisted_ownership_state(state) do
    if Ownership.valid_state?(state), do: :ok, else: {:error, :invalid_record}
  end

  defp validate_persisted_root_identity(record) do
    if is_nil(Map.get(record, :configured_root_identity)),
      do: {:error, :missing_configured_root_identity},
      else: :ok
  end

  defp validate_persisted_workspace_identity(state, nil)
       when state in [:provisioning, :owned, :release_pending, :released],
       do: {:error, :missing_top_level_filesystem_identity}

  defp validate_persisted_workspace_identity(_state, _identity), do: :ok

  defp validate_persisted_release_pending_origin(:release_pending, release_origin)
       when release_origin in [:authorized_cleanup, :failed_provisioning],
       do: :ok

  defp validate_persisted_release_pending_origin(:release_pending, _release_origin),
    do: {:error, :invalid_record}

  defp validate_persisted_release_pending_origin(_state, _release_origin), do: :ok

  defp validate_persisted_released_origin(:released, release_origin)
       when release_origin in [nil, :authorized_cleanup, :failed_provisioning],
       do: :ok

  defp validate_persisted_released_origin(:released, _release_origin), do: {:error, :invalid_record}
  defp validate_persisted_released_origin(_state, _release_origin), do: :ok

  defp validate_absent_release_origin_before_cleanup(state, release_origin)
       when state in [:reserved, :provisioning, :owned] and not is_nil(release_origin),
       do: {:error, :invalid_record}

  defp validate_absent_release_origin_before_cleanup(_state, _release_origin), do: :ok

  defp validate_record_filesystem_identities(%{location: :local} = record) do
    with :ok <- validate_local_filesystem_identity(record.configured_root_identity) do
      validate_local_filesystem_identity(record.top_level_filesystem_identity)
    end
  end

  defp validate_record_filesystem_identities(%{location: :remote} = record) do
    with :ok <- validate_filesystem_identity(record.configured_root_identity) do
      validate_filesystem_identity(record.top_level_filesystem_identity)
    end
  end

  defp validate_record_filesystem_identities(_record), do: {:error, :invalid_record}

  defp validate_local_filesystem_identity(nil), do: :ok

  defp validate_local_filesystem_identity(value) do
    case value do
      %{device: _device, inode: _inode} ->
        validate_structured_filesystem_identity(value)

      %{major_device: _major, minor_device: _minor, inode: _inode} ->
        validate_structured_filesystem_identity(value)

      {_, _} ->
        validate_structured_filesystem_identity(value)

      {_, _, _} ->
        validate_structured_filesystem_identity(value)

      _ ->
        {:error, :invalid_record}
    end
  end

  defp validate_filesystem_identity(nil), do: :ok

  defp validate_filesystem_identity(value) when is_binary(value),
    do: validate_non_empty_string(value)

  defp validate_filesystem_identity(value) when is_map(value) or is_tuple(value),
    do: validate_structured_filesystem_identity(value)

  defp validate_filesystem_identity(_value), do: {:error, :invalid_record}

  defp validate_structured_filesystem_identity(%{device: device, inode: inode, birth_time_ns: birth_time_ns} = value)
       when is_integer(device) and is_integer(inode) and is_integer(birth_time_ns) and device >= 0 and
              inode >= 0 do
    if Enum.sort(Map.keys(value)) == [:birth_time_ns, :device, :inode],
      do: :ok,
      else: {:error, :invalid_record}
  end

  defp validate_structured_filesystem_identity(%{device: device, inode: inode, generation: generation} = value)
       when is_integer(device) and is_integer(inode) and is_integer(generation) and device >= 0 and
              inode >= 0 and generation > 0 do
    if Enum.sort(Map.keys(value)) == [:device, :generation, :inode],
      do: :ok,
      else: {:error, :invalid_record}
  end

  defp validate_structured_filesystem_identity(%{device: device, inode: inode} = value)
       when is_integer(device) and is_integer(inode) and device >= 0 and inode >= 0 do
    if Enum.sort(Map.keys(value)) == [:device, :inode], do: :ok, else: {:error, :invalid_record}
  end

  defp validate_structured_filesystem_identity(%{major_device: major, minor_device: minor, inode: inode} = value)
       when is_integer(major) and is_integer(minor) and is_integer(inode) and major >= 0 and
              minor >= 0 and inode >= 0 do
    if Enum.sort(Map.keys(value)) == [:inode, :major_device, :minor_device],
      do: :ok,
      else: {:error, :invalid_record}
  end

  defp validate_structured_filesystem_identity({device, inode})
       when is_integer(device) and is_integer(inode) and device >= 0 and inode >= 0,
       do: :ok

  defp validate_structured_filesystem_identity({major, minor, inode})
       when is_integer(major) and is_integer(minor) and is_integer(inode) and major >= 0 and
              minor >= 0 and inode >= 0,
       do: :ok

  defp validate_structured_filesystem_identity(_value), do: {:error, :invalid_record}

  defp validate_root_identity(%{configured_root_identity: value}),
    do: validate_filesystem_identity(value)

  defp validate_root_identity(_record), do: {:error, :invalid_record}

  defp validate_host_identity_outside_workspace(record, identity_path) do
    if path_inside_or_equal?(Path.expand(identity_path), record.canonical_workspace_path) do
      {:error, :host_identity_inside_workspace}
    else
      :ok
    end
  end

  defp validate_ledger_path_outside_workspace(record, ledger_path) do
    if path_inside_or_equal?(Path.expand(ledger_path), record.canonical_workspace_path) do
      {:error, :ledger_inside_workspace}
    else
      :ok
    end
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

  defp validate_tracker_identity_match(stored, expected) when stored == expected, do: :ok

  defp validate_tracker_identity_match(stored, expected),
    do: {:error, {:ledger_tracker_identity_mismatch, stored, expected}}

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

  defp validate_non_empty_string(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_record}, else: :ok
  end

  defp validate_non_empty_string(_value), do: {:error, :invalid_record}

  defp validate_timestamp(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_timestamp(%DateTime{} = value) do
    case DateTime.to_iso8601(value) do
      iso when is_binary(iso) -> :ok
    end
  rescue
    _error -> {:error, :invalid_record}
  end

  defp validate_timestamp(_value), do: {:error, :invalid_record}

  defp validate_host_identity_path(path, path) do
    {:error, {:host_identity_path_conflict, path}}
  end

  defp validate_host_identity_path(_ledger_path, _identity_path), do: :ok

  defp validate_storage_outside_workspace(_path, _identity_path, _root, nil), do: :ok

  defp validate_storage_outside_workspace(path, identity_path, root, workspace_root)
       when is_binary(workspace_root) do
    with {:ok, workspace_root} <- PathSafety.canonicalize(workspace_root),
         {:ok, canonical_paths} <- canonicalize_storage_paths([path, identity_path, root]) do
      if Enum.any?(canonical_paths, &path_inside_or_equal?(&1, workspace_root)) do
        {:error, :ledger_inside_workspace_root}
      else
        :ok
      end
    else
      {:error, reason} -> {:error, {:ledger_workspace_root_validation_failed, reason}}
    end
  end

  defp validate_storage_outside_workspace(_path, _identity_path, _root, _workspace_root),
    do: {:error, :invalid_workspace_root}

  defp canonicalize_storage_paths(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, canonical_paths} ->
      case PathSafety.canonicalize(path) do
        {:ok, canonical_path} -> {:cont, {:ok, [canonical_path | canonical_paths]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, canonical_paths} -> {:ok, Enum.reverse(canonical_paths)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_local_host_identity_path(path, workspace_path)
       when is_binary(workspace_path) do
    if path_inside_or_equal?(Path.expand(path), Path.expand(workspace_path)) do
      {:error, :host_identity_inside_workspace}
    else
      :ok
    end
  end

  defp validate_local_host_identity_path(_path, _workspace_path), do: :ok

  defp path_under?(child, parent) when is_binary(child) and is_binary(parent) do
    child = Path.expand(child)
    parent = Path.expand(parent)
    prefix = if parent == "/", do: "/", else: parent <> "/"
    child != parent and String.starts_with?(child, prefix)
  end

  defp path_under?(_child, _parent), do: false

  defp path_inside_or_equal?(child, parent) when is_binary(child) and is_binary(parent) do
    child == Path.expand(parent) or path_under?(child, parent)
  end

  defp path_inside_or_equal?(_child, _parent), do: false

  defp persist_records(%__MODULE__{table: table, write_fun: write_fun} = ledger, records) do
    with :ok <- invoke_write(write_fun, table, records) do
      invoke_sync(ledger.sync_fun, table)
    end
  end

  defp serialize_mutation(%__MODULE__{path: path}, fun) when is_function(fun, 0) do
    case :global.trans({path, self()}, fun) do
      :aborted -> {:error, {:ledger_mutation_lock_failed, :aborted}}
      {:aborted, reason} -> {:error, {:ledger_mutation_lock_failed, reason}}
      result -> result
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

  defp ledger_path_status(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, true}
      {:ok, %File.Stat{type: type}} -> {:error, {:ledger_path_invalid, {:not_regular, type}}}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, {:ledger_path_invalid, reason}}
    end
  end

  defp all_records(%__MODULE__{table: table}) do
    {:ok, :dets.foldl(fn record, records -> [record | records] end, [], table)}
  catch
    kind, reason -> {:error, {:ledger_read_failed, {kind, reason}}}
  end

  defp open_table(path) do
    table = path

    with {:ok, _preexisting} <- ledger_path_status(path),
         result <- :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity) do
      handle_open_table_result(result, table, path)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_open_table_result({:ok, table}, table, path) do
    case protect_regular_file(path) do
      :ok ->
        {:ok, table}

      {:error, reason} ->
        _ = close_table(table)
        {:error, {:ledger_permissions_failed, reason}}
    end
  end

  defp handle_open_table_result({:error, {:already_started, _pid}}, _table, path),
    do: {:error, {:ledger_already_open, path}}

  defp handle_open_table_result({:error, reason}, _table, _path),
    do: {:error, {:ledger_open_failed, reason}}

  defp close_table(table) do
    case :dets.info(table) do
      :undefined -> :ok
      _ -> :dets.close(table)
    end
  catch
    :exit, reason -> {:error, {:ledger_close_failed, reason}}
  end

  defp cleanup_new_table(table, path, false) do
    if :dets.info(table, :size) == 0 do
      _ = close_table(table)
      _ = File.rm(path)
    end
  catch
    _kind, _reason -> :ok
  end

  defp cleanup_new_table(_table, _path, _path_preexisted), do: :ok

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

  defp ensure_private_directory(path) when is_binary(path) do
    path = Path.expand(path)

    with false <- path == "/",
         :ok <- ensure_directory_components(path),
         :ok <- File.chmod(path, 0o700),
         :ok <- verify_private_directory(path) do
      :ok
    else
      true -> {:error, {:ledger_directory_failed, :unsafe_root}}
      {:error, reason} -> {:error, {:ledger_directory_failed, reason}}
    end
  end

  defp ensure_directory_components(path) do
    path
    |> absolute_path_components()
    |> Enum.reduce_while(:ok, fn component, :ok ->
      case ensure_directory_component(component) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_directory_component(component) do
    case File.lstat(component) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_directory, component, type}}

      {:error, :enoent} ->
        create_directory_component(component)

      {:error, reason} ->
        {:error, {component, reason}}
    end
  end

  defp create_directory_component(component) do
    case File.mkdir(component) do
      :ok ->
        verify_directory_component(component)

      {:error, :eexist} ->
        verify_directory_component(component)

      {:error, reason} ->
        {:error, {component, reason}}
    end
  end

  defp verify_directory_component(component) do
    case File.lstat(component) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_directory, component, type}}

      {:error, reason} ->
        {:error, {component, reason}}
    end
  end

  defp absolute_path_components(path) do
    segments = String.split(path, "/", trim: true)
    Enum.scan(segments, "/", &Path.join(&2, &1))
  end

  defp verify_private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_directory, path, type}}

      {:error, reason} ->
        {:error, {path, reason}}
    end
  end

  defp protect_regular_file(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o777) == 0o600 do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
      false -> {:error, :unsafe_permissions}
    end
  end

  defp ensure_local_host_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        read_local_host_identity(path)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:host_identity_failed, {:not_regular, type}}}

      {:error, :enoent} ->
        create_local_host_identity(path)

      {:error, reason} ->
        {:error, {:host_identity_read_failed, reason}}
    end
  end

  defp read_local_host_identity(path) do
    with :ok <- protect_regular_file(path),
         {:ok, identity} <- File.read(path),
         :ok <- validate_non_empty_string(identity) do
      {:ok, identity}
    else
      {:error, reason} -> {:error, {:host_identity_failed, reason}}
    end
  end

  defp create_local_host_identity(path) do
    identity = "host-" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    case File.write(path, identity, [:binary, :exclusive]) do
      :ok ->
        protect_created_host_identity(path, identity)

      {:error, :eexist} ->
        ensure_local_host_identity(path)

      {:error, reason} ->
        {:error, {:host_identity_write_failed, reason}}
    end
  end

  defp protect_created_host_identity(path, identity) do
    case protect_regular_file(path) do
      :ok ->
        {:ok, identity}

      {:error, reason} ->
        {:error, {:host_identity_permissions_failed, reason}}
    end
  end

  defp metadata(%__MODULE__{} = ledger) do
    %{
      schema_version: @schema_version,
      project_namespace: ledger.project_id,
      tracker_identity: ledger.tracker_identity
    }
  end

  defp now_ms, do: System.system_time(:millisecond)
end
