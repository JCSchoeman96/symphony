defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, CredentialBoundary, PathSafety, SSH, Tracker}
  alias SymphonyElixir.Workspace.OwnershipLedger

  @remote_workspace_marker "__SYMPHONY_WORKSPACE_PREPARE__"
  @default_remote_host_identity "~/.local/state/symphony/workspace-ownership/host.identity"

  @type worker_host :: String.t() | nil
  @type workspace_options :: keyword()
  @type ownership_record :: map()

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier), do: create_for_issue(issue_or_identifier, nil)

  @spec create_for_issue(map() | String.t() | nil, worker_host() | OwnershipLedger.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, %OwnershipLedger{} = ledger) do
    create_for_issue(issue_or_identifier, nil, ledger)
  end

  def create_for_issue(issue_or_identifier, worker_host)
      when is_binary(worker_host) or is_nil(worker_host) do
    create_for_issue(issue_or_identifier, worker_host, [])
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host(), OwnershipLedger.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host, %OwnershipLedger{} = ledger) do
    create_for_issue(issue_or_identifier, worker_host, ledger: ledger)
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host(), workspace_options()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host, opts)
      when (is_binary(worker_host) or is_nil(worker_host)) and is_list(opts) do
    issue_context = issue_context(issue_or_identifier)

    try do
      with_ledger(opts, fn ledger ->
        with {:ok, identity} <- issue_identity(issue_or_identifier),
             safe_id <- workspace_key(identity.identifier),
             {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
             :ok <- validate_workspace_path(workspace, worker_host) do
          prepare_workspace(ledger, identity, workspace, worker_host, opts)
        end
      end)
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp prepare_workspace(ledger, identity, workspace, nil, opts),
    do: prepare_local_workspace(ledger, identity, workspace, opts)

  defp prepare_workspace(ledger, identity, workspace, worker_host, opts),
    do: prepare_remote_workspace(ledger, identity, workspace, worker_host, opts)

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil, [])

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host), do: remove(workspace, worker_host, [])

  @spec remove(Path.t(), worker_host(), OwnershipLedger.t() | workspace_options()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host, %OwnershipLedger{} = ledger),
    do: remove(workspace, worker_host, ledger: ledger)

  def remove(workspace, worker_host, opts) when is_list(opts) do
    remove_recorded(workspace, worker_host, opts)
  end

  @spec remove(Path.t(), worker_host(), OwnershipLedger.t(), workspace_options()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host, %OwnershipLedger{} = ledger, opts) when is_list(opts),
    do: remove(workspace, worker_host, Keyword.put(opts, :ledger, ledger))

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, worker_host), do: remove_recorded(workspace, worker_host, [])

  @doc false
  @spec remove_recorded(Path.t(), worker_host(), OwnershipLedger.t() | workspace_options()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, worker_host, %OwnershipLedger{} = ledger),
    do: remove_recorded(workspace, worker_host, ledger: ledger)

  def remove_recorded(workspace, worker_host, opts)
      when is_binary(workspace) and (is_binary(worker_host) or is_nil(worker_host)) and is_list(opts) do
    if cleanup_authorized?(opts) do
      try do
        with_ledger(opts, fn ledger ->
          remove_recorded_with_ledger(workspace, worker_host, ledger, opts)
        end)
        |> normalize_removal_result()
      rescue
        error in [ArgumentError, ErlangError, File.Error] ->
          {:error, error, ""}
      end
    else
      {:error, :workspace_cleanup_authorization_required, ""}
    end
  end

  def remove_recorded(workspace, _worker_host, _opts),
    do: {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}

  @spec remove_recorded(Path.t(), worker_host(), OwnershipLedger.t(), workspace_options()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, worker_host, %OwnershipLedger{} = ledger, opts) when is_list(opts),
    do: remove_recorded(workspace, worker_host, Keyword.put(opts, :ledger, ledger))

  @doc """
  Cancels a durable pending release after revalidating the current workspace binding.
  """
  @spec cancel_pending_release_if_current(map(), OwnershipLedger.t()) :: :ok | {:error, term()}
  def cancel_pending_release_if_current(record, %OwnershipLedger{} = ledger) when is_map(record) do
    with ownership_id when is_binary(ownership_id) <- Map.get(record, :workspace_ownership_id),
         {:ok, current} <- OwnershipLedger.get(ledger, ownership_id),
         true <- current == record,
         :release_pending <- current.state,
         :authorized_cleanup <- current.release_origin,
         :ok <- validate_pending_release_current(current, ledger),
         {:ok, _owned} <-
           OwnershipLedger.transition_sync(ledger, ownership_id, :owned,
             configured_root_identity: current.configured_root_identity,
             top_level_filesystem_identity: current.top_level_filesystem_identity
           ) do
      :ok
    else
      nil -> {:error, :workspace_ownership_not_found}
      false -> {:error, :workspace_ownership_changed}
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :workspace_ownership_not_found}
      :failed_provisioning -> {:error, :failed_provisioning_release_cannot_be_cancelled}
      state when is_atom(state) -> {:error, {:invalid_pending_release_state, state}}
    end
  end

  def cancel_pending_release_if_current(_record, _ledger),
    do: {:error, :workspace_ownership_not_found}

  @spec remove_issue_workspaces(term()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil, [])

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier, worker_host),
    do: remove_issue_workspaces(identifier, worker_host, [])

  @spec remove_issue_workspaces(term(), worker_host(), OwnershipLedger.t() | workspace_options()) ::
          :ok | {:error, term()}
  def remove_issue_workspaces(identifier, worker_host, %OwnershipLedger{} = ledger),
    do: remove_issue_workspaces(identifier, worker_host, ledger: ledger)

  def remove_issue_workspaces(identifier, worker_host, opts)
      when (is_binary(worker_host) or is_nil(worker_host)) and is_list(opts) do
    case cleanup_authorized?(opts) do
      true -> remove_authorized_issue_workspaces(identifier, worker_host, opts)
      false -> {:error, :workspace_cleanup_authorization_required}
    end
  end

  def remove_issue_workspaces(_identifier, _worker_host, _opts), do: {:error, :invalid_worker_host}

  defp remove_authorized_issue_workspaces(identifier, worker_host, opts) do
    with {:ok, identity} <- issue_identity(identifier) do
      with_ledger(opts, &remove_issue_records(&1, identity, worker_host, opts))
      |> normalize_issue_removal_result()
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] -> {:error, error}
  end

  defp remove_issue_records(ledger, identity, worker_host, opts) do
    with {:ok, records} <- OwnershipLedger.list_for_work_item(ledger, identity.id) do
      remove_matching_issue_records(records, identity, worker_host, ledger, opts)
    end
  end

  defp remove_matching_issue_records(records, identity, worker_host, ledger, opts) do
    matching_records = Enum.filter(records, &issue_workspace_record?(&1, identity, worker_host))

    if matching_records == [] do
      {:error, :workspace_ownership_not_found}
    else
      releasable_records = Enum.filter(matching_records, &(&1.state in [:owned, :release_pending]))
      unresolved_records = Enum.reject(matching_records, &(&1.state in [:owned, :release_pending, :released]))

      case remove_records(releasable_records, ledger, opts) do
        {:ok, _removed} when unresolved_records == [] -> {:ok, []}
        {:ok, _removed} -> {:error, {:workspace_ownership_not_releasable, unresolved_records}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp issue_workspace_record?(record, identity, worker_host) do
    record.work_item_id == identity.id and record.issue_identifier == identity.identifier and
      (is_nil(worker_host) or record.worker_host == worker_host)
  end

  defp normalize_issue_removal_result({:ok, _removed}), do: :ok
  defp normalize_issue_removal_result({:error, reason}), do: {:error, reason}

  @spec remove_issue_workspaces(term(), worker_host(), OwnershipLedger.t(), workspace_options()) ::
          :ok | {:error, term()}
  def remove_issue_workspaces(identifier, worker_host, %OwnershipLedger{} = ledger, opts)
      when is_list(opts) do
    remove_issue_workspaces(identifier, worker_host, Keyword.put(opts, :ledger, ledger))
  end

  defp with_ledger(opts, fun) when is_list(opts) and is_function(fun, 1) do
    case Keyword.get(opts, :ledger) do
      %OwnershipLedger{} = ledger ->
        fun.(ledger)

      _ ->
        settings = Config.settings!()
        project_id = Keyword.get(opts, :project_id) || settings.symphony.project_id || "legacy-default"
        tracker_identity = Keyword.get(opts, :tracker_identity, Tracker.identity(settings.tracker))
        ledger_opts = ledger_options(opts)

        with {:ok, ledger} <- OwnershipLedger.open(project_id, tracker_identity, ledger_opts) do
          try do
            fun.(ledger)
          after
            _ = OwnershipLedger.close(ledger)
          end
        end
    end
  end

  defp ledger_options(opts) do
    opts
    |> Keyword.get(:ledger_opts, [])
    |> Keyword.merge(Keyword.take(opts, [:root, :path, :ledger_path, :host_identity_path]))
    |> Keyword.put(:workspace_root, Config.local_workspace_root())
  end

  defp issue_identity(%{id: id, identifier: identifier})
       when is_binary(id) and is_binary(identifier) and id != "" and identifier != "" do
    {:ok, %{id: id, identifier: identifier}}
  end

  defp issue_identity(identifier) when is_binary(identifier) and identifier != "" do
    {:ok, %{id: identifier, identifier: identifier}}
  end

  defp issue_identity(_issue), do: {:error, :invalid_issue_identity}

  defp normalize_removal_result({:ok, removed}), do: {:ok, removed}
  defp normalize_removal_result({:error, reason}), do: {:error, reason, ""}

  defp remove_records([], _ledger, _opts), do: {:ok, []}

  defp remove_records(records, ledger, opts) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, removed} ->
      case remove_recorded_with_ledger(
             record.canonical_workspace_path,
             record.worker_host,
             ledger,
             opts,
             ownership_id: record.workspace_ownership_id
           ) do
        {:ok, paths} -> {:cont, {:ok, removed ++ paths}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_local_workspace(ledger, identity, workspace, _opts) do
    root = Config.local_workspace_root()

    with :ok <- File.mkdir_p(root),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         {:ok, root_identity} <- OwnershipLedger.root_identity(canonical_root),
         :ok <- validate_local_root(canonical_root, root_identity),
         {:ok, records} <- OwnershipLedger.list_for_work_item(ledger, identity.id) do
      local_workspace_result(
        ledger,
        identity,
        workspace,
        configured_root_binding(nil),
        canonical_root,
        root_identity,
        records
      )
    end
  end

  defp validate_local_root(root, _identity) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:workspace_root_not_directory, root, type}}
      {:error, reason} -> {:error, {:workspace_root_unreadable, root, reason}}
    end
  end

  defp local_workspace_result(
         ledger,
         identity,
         workspace,
         configured_root,
         canonical_root,
         root_identity,
         records
       ) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:workspace_symlink, workspace}}

      {:ok, %File.Stat{type: :directory}} ->
        local_reuse_or_reject(
          ledger,
          identity,
          workspace,
          configured_root,
          canonical_root,
          root_identity,
          records
        )

      {:ok, %File.Stat{type: type}} ->
        {:error, {:workspace_path_exists, workspace, type}}

      {:error, :enoent} ->
        create_local_workspace(
          ledger,
          identity,
          workspace,
          configured_root,
          canonical_root,
          root_identity,
          records
        )

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp local_reuse_or_reject(
         ledger,
         identity,
         workspace,
         configured_root,
         canonical_root,
         root_identity,
         records
       ) do
    with {:ok, filesystem_identity} <- OwnershipLedger.filesystem_identity(workspace),
         {:ok, record} <-
           exact_owned_record(
             records,
             identity,
             workspace,
             configured_root,
             canonical_root,
             root_identity,
             nil,
             ledger.host_identity
           ),
         true <- record.top_level_filesystem_identity == filesystem_identity do
      {:ok, workspace}
    else
      {:error, :workspace_ownership_not_found} ->
        {:error, {:workspace_ownership_required, workspace}}

      {:error, reason} ->
        {:error, reason}

      false ->
        {:error, {:workspace_identity_mismatch, workspace}}
    end
  end

  defp exact_owned_record(
         records,
         identity,
         workspace,
         configured_root,
         canonical_root,
         root_identity,
         worker_host,
         trusted_host_identity
       ) do
    case Enum.find(records, fn record ->
           record.state == :owned and
             exact_record_binding?(
               record,
               identity,
               workspace,
               configured_root,
               canonical_root,
               root_identity,
               worker_host,
               trusted_host_identity
             )
         end) do
      nil -> {:error, :workspace_ownership_not_found}
      record -> {:ok, record}
    end
  end

  defp exact_record_binding?(
         record,
         identity,
         workspace,
         configured_root,
         canonical_root,
         root_identity,
         worker_host,
         trusted_host_identity
       ) do
    expected_binding =
      {identity.identifier, identity.id, workspace_key(identity.identifier), workspace_location(worker_host), worker_host, configured_root, canonical_root, workspace, root_identity,
       trusted_host_identity}

    record_binding(record) == expected_binding
  end

  defp workspace_location(nil), do: :local
  defp workspace_location(_worker_host), do: :remote

  defp record_binding(record) do
    {
      record.issue_identifier,
      record.work_item_id,
      record.workspace_key,
      record.location,
      record.worker_host,
      record.configured_root,
      record.canonical_root,
      record.canonical_workspace_path,
      record.configured_root_identity,
      record.trusted_host_identity
    }
  end

  defp reserved_record(
         ledger,
         identity,
         workspace,
         root_binding,
         location,
         worker_host,
         host_identity
       ) do
    now = System.system_time(:millisecond)
    configured_root = root_binding.configured_root
    canonical_root = root_binding.canonical_root
    root_identity = root_binding.configured_root_identity

    %{
      schema_version: OwnershipLedger.schema_version(),
      project_namespace: ledger.project_id,
      tracker_identity: ledger.tracker_identity,
      issue_identifier: identity.identifier,
      work_item_id: identity.id,
      workspace_key: workspace_key(identity.identifier),
      workspace_ownership_id: new_workspace_ownership_id(),
      location: location,
      worker_host: worker_host,
      trusted_host_identity: host_identity,
      configured_root: configured_root,
      configured_root_identity: root_identity,
      canonical_root: canonical_root,
      canonical_workspace_path: workspace,
      top_level_filesystem_identity: nil,
      state: :reserved,
      created_at: now,
      updated_at: now
    }
  end

  defp new_workspace_ownership_id do
    "workspace-" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
  end

  defp create_local_workspace(
         ledger,
         identity,
         workspace,
         configured_root,
         canonical_root,
         root_identity,
         records
       ) do
    attrs =
      reserved_record(
        ledger,
        identity,
        workspace,
        %{
          configured_root: configured_root,
          canonical_root: canonical_root,
          configured_root_identity: root_identity
        },
        :local,
        nil,
        ledger.host_identity
      )

    with {:ok, reserved} <- reserve_or_reuse_local(ledger, attrs, records),
         :ok <- atomic_mkdir(workspace),
         {:ok, filesystem_identity} <- OwnershipLedger.filesystem_identity(workspace),
         :ok <- after_create_and_own(ledger, reserved, identity, workspace, root_identity, filesystem_identity) do
      {:ok, workspace}
    else
      {:error, {:after_create_failed, ownership_id, hook_reason}} ->
        {:error, cleanup_failed_create(ledger, ownership_id, workspace, hook_reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve_or_reuse_local(ledger, attrs, records) do
    records
    |> Enum.filter(&reservation_record?(&1, attrs, :local, nil))
    |> reserve_or_reuse_record(ledger, attrs)
  end

  defp reservation_record?(record, attrs, location, worker_host) do
    expected_binding = %{attrs | location: location, worker_host: worker_host}

    record_binding(record) == record_binding(expected_binding) and
      record.state in [:reserved, :provisioning, :release_pending, :owned]
  end

  defp reserve_or_reuse_record(active, ledger, attrs) do
    case Enum.find(active, &(&1.state == :reserved)) do
      %{} = reserved -> {:ok, reserved}
      nil when active == [] -> OwnershipLedger.reserve_sync(ledger, attrs)
      nil -> {:error, {:workspace_ownership_inconsistent, attrs.canonical_workspace_path}}
    end
  end

  defp after_create_and_own(ledger, reserved, identity, workspace, root_identity, filesystem_identity) do
    case persist_local_provisioning(ledger, reserved, root_identity, filesystem_identity) do
      {:error, reason} ->
        {:error, {:provisioning_sync_failed, reason}}

      {:ok, _provisioning} ->
        run_local_after_create(ledger, reserved, identity, workspace, root_identity, filesystem_identity)
    end
  end

  defp persist_local_provisioning(ledger, reserved, root_identity, filesystem_identity) do
    OwnershipLedger.transition_sync(
      ledger,
      reserved.workspace_ownership_id,
      :provisioning,
      configured_root_identity: root_identity,
      top_level_filesystem_identity: filesystem_identity
    )
  end

  defp run_local_after_create(ledger, reserved, identity, workspace, root_identity, filesystem_identity) do
    case maybe_run_after_create_hook(workspace, issue_context(identity), nil) do
      {:error, reason} -> {:error, {:after_create_failed, reserved.workspace_ownership_id, reason}}
      :ok -> validate_and_own_local_workspace(ledger, reserved, workspace, root_identity, filesystem_identity)
    end
  end

  defp validate_and_own_local_workspace(ledger, reserved, workspace, root_identity, filesystem_identity) do
    case validate_local_cleanup_identity(
           workspace,
           root_identity,
           filesystem_identity,
           reserved.canonical_root,
           reserved.configured_root
         ) do
      :ok ->
        case OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :owned,
               top_level_filesystem_identity: filesystem_identity
             ) do
          {:ok, _owned} -> :ok
          {:error, reason} -> {:error, {:owned_sync_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:owned_identity_mismatch, reason}}
    end
  end

  defp atomic_mkdir(workspace) do
    case File.mkdir(workspace) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:workspace_path_exists, workspace}}
      {:error, reason} -> {:error, {:workspace_create_failed, workspace, reason}}
    end
  end

  defp cleanup_failed_create(_ledger, nil, _workspace, reason), do: reason

  defp cleanup_failed_create(ledger, ownership_id, _workspace, reason) do
    with {:ok, pending} <-
           OwnershipLedger.transition_sync(
             ledger,
             ownership_id,
             :release_pending,
             release_origin: :failed_provisioning
           ),
         {:ok, _removed} <- remove_local_owned_path(pending, ledger, []) do
      reason
    else
      {:error, cleanup_reason} -> {:after_create_cleanup_failed, reason, cleanup_reason}
    end
  end

  defp validate_local_cleanup_identity(
         workspace,
         root_identity,
         expected_filesystem_identity,
         expected_root,
         expected_configured_root
       ) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace),
         {:ok, filesystem_identity} <- OwnershipLedger.filesystem_identity(workspace),
         true <- filesystem_identity == expected_filesystem_identity do
      with :ok <- validate_current_configured_root(expected_configured_root),
           {:ok, canonical_root} <- PathSafety.canonicalize(Config.local_workspace_root()),
           true <- is_nil(expected_root) or canonical_root == expected_root,
           {:ok, ^root_identity} <- OwnershipLedger.root_identity(canonical_root) do
        :ok
      else
        false -> {:error, {:workspace_root_path_mismatch, expected_root}}
        {:ok, actual} -> {:error, {:workspace_root_identity_mismatch, root_identity, actual}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:workspace_identity_mismatch, workspace, type}}
      {:error, reason} -> {:error, {:workspace_identity_mismatch, workspace, reason}}
      false -> {:error, {:workspace_identity_mismatch, workspace}}
    end
  end

  defp validate_current_configured_root(expected) do
    current = configured_root_binding(nil)

    if current == expected do
      :ok
    else
      {:error, {:workspace_configured_root_mismatch, expected, current}}
    end
  end

  defp configured_root_binding(nil), do: Config.local_workspace_root() |> Path.expand()

  defp configured_root_binding(_worker_host) do
    Config.settings!().workspace.root
    |> String.trim_trailing("/")
    |> normalize_root_slash()
  end

  defp normalize_root_slash(""), do: "/"
  defp normalize_root_slash(root), do: root

  defp cleanup_authorized?(opts) when is_list(opts) do
    Keyword.get(opts, :cleanup_authorized) == true or
      Keyword.get(opts, :cleanup_authorized?) == true or
      Keyword.get(opts, :cleanup_authorization) == true or
      match?(%{authorized: true}, Keyword.get(opts, :cleanup_authorization))
  end

  defp cleanup_authorized?(_opts), do: false

  defp remove_recorded_with_ledger(workspace, worker_host, ledger, opts, extra \\ []) do
    with {:ok, requested_path} <- requested_workspace_path(workspace, worker_host),
         {:ok, records} <- OwnershipLedger.list_for_host(ledger, worker_host),
         {:ok, record} <- find_record_for_path(records, requested_path, extra),
         :ok <- validate_cleanup_authorization(record, opts),
         {:ok, pending} <- ensure_release_pending(ledger, record) do
      remove_owned_path(pending, worker_host, ledger, opts)
    end
  end

  defp requested_workspace_path(workspace, nil) do
    with :ok <- validate_workspace_path(workspace, nil),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      case File.lstat(workspace) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:error, {:workspace_symlink_escape, Path.expand(workspace), Path.expand(Config.local_workspace_root())}}

        _ ->
          {:ok, canonical_workspace}
      end
    end
  end

  defp requested_workspace_path(workspace, worker_host) when is_binary(worker_host) do
    if String.trim(workspace) == "" or String.contains?(workspace, ["\n", "\r", <<0>>]) do
      {:error, {:workspace_path_unreadable, workspace, :invalid}}
    else
      {:ok, Path.expand(workspace)}
    end
  end

  defp find_record_for_path(records, requested_path, extra) do
    requested_ownership_id = Keyword.get(extra, :ownership_id)

    case Enum.find(records, fn record ->
           record.canonical_workspace_path == requested_path and
             (is_nil(requested_ownership_id) or record.workspace_ownership_id == requested_ownership_id) and
             record.state in [:owned, :release_pending]
         end) do
      nil -> {:error, :workspace_ownership_not_found}
      record -> {:ok, record}
    end
  end

  defp validate_cleanup_authorization(record, opts) do
    case Keyword.get(opts, :cleanup_authorization) do
      authorization when is_map(authorization) ->
        if cleanup_authorization_matches?(authorization, record) do
          :ok
        else
          {:error, :workspace_cleanup_authorization_mismatch}
        end

      _ ->
        :ok
    end
  end

  defp cleanup_authorization_matches?(authorization, record) do
    fields = [:workspace_ownership_id, :canonical_workspace_path, :worker_host]

    Enum.all?(fields, fn field ->
      not Map.has_key?(authorization, field) or Map.get(authorization, field) == Map.get(record, field)
    end)
  end

  defp ensure_release_pending(_ledger, %{state: :release_pending} = record), do: {:ok, record}

  defp ensure_release_pending(ledger, %{state: :owned} = record) do
    OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :release_pending)
  end

  defp remove_owned_path(%{location: :local} = record, nil, ledger, opts),
    do: remove_local_owned_path(record, ledger, opts)

  defp remove_owned_path(%{location: :remote} = record, worker_host, ledger, opts)
       when is_binary(worker_host),
       do: remove_remote_owned_path(record, worker_host, ledger, opts)

  defp remove_owned_path(_record, _worker_host, _ledger, _opts),
    do: {:error, :workspace_ownership_not_found}

  defp remove_remote_owned_path(record, worker_host, ledger, _opts) do
    with :ok <- validate_remote_configured_root(worker_host, record.configured_root) do
      remove_configured_remote_workspace(record, worker_host, ledger)
    end
  end

  defp remove_configured_remote_workspace(record, worker_host, ledger) do
    script = remote_remove_guard_script(record)

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        case OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :released) do
          {:ok, _released} -> {:ok, [record.canonical_workspace_path]}
          {:error, reason} -> {:error, reason}
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_remove_guard_script(record) do
    root = Config.settings!().workspace.root
    expected_root = record.canonical_root
    workspace = record.canonical_workspace_path
    host_identity_path = @default_remote_host_identity
    quarantine_dir = workspace_quarantine_dir(record)
    quarantine_workspace = Path.join(quarantine_dir, "workspace")
    hook = Config.settings!().hooks.before_remove

    hook_commands =
      cond do
        is_nil(hook) -> []
        CredentialBoundary.routed_workspace_shell_hook_skipped?("before_remove") -> []
        true -> [hook]
      end

    root_binding_checks = [
      "if [ -L \"$root\" ] || [ ! -d \"$root\" ]; then exit 92; fi",
      "if [ \"$(cd \"$root\" && pwd -P)\" != #{shell_escape(expected_root)} ]; then exit 93; fi",
      "if [ \"$(symphony_filesystem_identity \"$root\")\" != #{shell_escape(record.configured_root_identity)} ]; then exit 94; fi"
    ]

    host_identity_checks = [
      "host_identity_dir=$(dirname \"$host_identity_path\")",
      "check_dir=\"$host_identity_dir\"",
      "while [ \"$check_dir\" != \"/\" ] && [ \"$check_dir\" != \".\" ]; do if [ -L \"$check_dir\" ] || [ ! -d \"$check_dir\" ]; then exit 95; fi; check_dir=$(dirname \"$check_dir\"); done",
      "if [ \"$(stat -c '%a' -- \"$host_identity_dir\")\" != 700 ]; then exit 95; fi",
      "if [ -L \"$host_identity_path\" ] || [ ! -f \"$host_identity_path\" ] || [ \"$(stat -c '%a' -- \"$host_identity_path\")\" != 600 ]; then exit 95; fi",
      "if [ \"$(cat \"$host_identity_path\")\" != #{shell_escape(record.trusted_host_identity)} ]; then exit 96; fi"
    ]

    quarantine_checks = [
      "case \"$quarantine_dir\" in \"$root\"/*) ;; *) exit 103 ;; esac",
      "if [ -L \"$quarantine_dir\" ]; then exit 103; fi",
      "if [ ! -e \"$quarantine_dir\" ]; then (umask 077; mkdir -- \"$quarantine_dir\") || exit 103; fi",
      "if [ ! -d \"$quarantine_dir\" ] || [ \"$(stat -c '%a' -- \"$quarantine_dir\")\" != 700 ]; then exit 103; fi",
      "if [ \"$(cd \"$quarantine_dir\" && pwd -P)\" != \"$quarantine_dir\" ]; then exit 103; fi",
      "if [ \"$(stat -c '%d' -- \"$quarantine_dir\")\" != \"$(stat -c '%d' -- \"$root\")\" ]; then exit 103; fi",
      "if [ -L \"$quarantined_workspace\" ]; then exit 104; fi"
    ]

    source_validation = [
      "if [ -L \"$workspace\" ] || [ ! -d \"$workspace\" ]; then exit 97; fi",
      "if [ \"$(cd \"$workspace\" && pwd -P)\" != #{shell_escape(workspace)} ]; then exit 98; fi",
      "if [ \"$(symphony_filesystem_identity \"$workspace\")\" != #{shell_escape(record.top_level_filesystem_identity)} ]; then exit 99; fi"
    ]

    source_hook_and_detach = [
      "cd \"$workspace\"",
      CredentialBoundary.unset_shell_command(CredentialBoundary.configured_secret_environment_names()),
      Enum.join(hook_commands, "\n"),
      "if [ \"$(cd \"$root\" && pwd -P)\" != #{shell_escape(expected_root)} ] || [ \"$(symphony_filesystem_identity \"$root\")\" != #{shell_escape(record.configured_root_identity)} ]; then exit 100; fi",
      "if [ -L \"$workspace\" ] || [ \"$(cd \"$workspace\" && pwd -P)\" != #{shell_escape(workspace)} ]; then exit 101; fi",
      "if [ \"$(symphony_filesystem_identity \"$workspace\")\" != #{shell_escape(record.top_level_filesystem_identity)} ]; then exit 102; fi",
      "if [ -e \"$quarantined_workspace\" ] || [ -L \"$quarantined_workspace\" ]; then exit 104; fi",
      "mv -- \"$workspace\" \"$quarantined_workspace\""
    ]

    quarantined_workspace_validation = [
      "if [ -L \"$quarantined_workspace\" ] || [ ! -d \"$quarantined_workspace\" ]; then exit 104; fi",
      "if [ \"$(cd \"$quarantined_workspace\" && pwd -P)\" != \"$quarantined_workspace\" ]; then exit 104; fi",
      "if [ \"$(symphony_filesystem_identity \"$quarantined_workspace\")\" != #{shell_escape(record.top_level_filesystem_identity)} ]; then exit 104; fi"
    ]

    [
      "set -eu",
      remote_filesystem_identity_function(),
      remote_shell_assign("workspace", workspace),
      remote_shell_assign("root", root),
      remote_shell_assign("host_identity_path", host_identity_path),
      remote_shell_assign("quarantine_dir", quarantine_dir),
      remote_shell_assign("quarantined_workspace", quarantine_workspace),
      "case \"$workspace\" in \"$root\"/*) ;; *) exit 91 ;; esac",
      root_binding_checks,
      host_identity_checks,
      quarantine_checks,
      "if [ -e \"$quarantined_workspace\" ]; then quarantined=1; else quarantined=0; fi",
      "if [ \"$quarantined\" = 0 ]; then",
      "  if [ -n \"$(find \"$quarantine_dir\" -mindepth 1 -maxdepth 1 -print -quit)\" ]; then exit 103; fi",
      "  if [ ! -e \"$workspace\" ] && [ ! -L \"$workspace\" ]; then rmdir -- \"$quarantine_dir\"; exit 0; fi",
      source_validation,
      source_hook_and_detach,
      "fi",
      root_binding_checks,
      host_identity_checks,
      quarantine_checks,
      quarantined_workspace_validation,
      "rm -rf -- \"$quarantined_workspace\"",
      "rmdir -- \"$quarantine_dir\""
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp remove_local_owned_path(record, ledger, opts) do
    with :ok <- validate_local_root_binding(record),
         {:ok, quarantine_state} <- local_quarantine_state(record) do
      remove_local_workspace_or_quarantine(record, ledger, opts, quarantine_state)
    end
  end

  defp remove_local_workspace_or_quarantine(record, ledger, opts, {:workspace, quarantine_identity}) do
    remove_local_quarantined_workspace(record, ledger, opts, quarantine_identity)
  end

  defp remove_local_workspace_or_quarantine(record, ledger, opts, quarantine_state) do
    case File.lstat(record.canonical_workspace_path) do
      {:error, :enoent} -> release_missing_local_workspace(record, ledger, quarantine_state)
      {:ok, _stat} -> remove_local_existing_workspace(record, ledger, opts, quarantine_state)
      {:error, reason} -> {:error, {:workspace_identity_mismatch, record.canonical_workspace_path, reason}}
    end
  end

  defp release_missing_local_workspace(record, ledger, :absent) do
    with :ok <- validate_local_root_binding(record),
         {:ok, _released} <-
           OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :released) do
      {:ok, [record.canonical_workspace_path]}
    end
  end

  defp release_missing_local_workspace(record, ledger, {:empty, quarantine_identity}) do
    quarantine_dir = local_quarantine_dir(record)

    with :ok <- validate_local_quarantine_directory(record, quarantine_dir, quarantine_identity),
         :ok <- File.rmdir(quarantine_dir),
         {:ok, _released} <-
           OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :released) do
      {:ok, [record.canonical_workspace_path]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_local_existing_workspace(record, ledger, opts, quarantine_state) do
    workspace = record.canonical_workspace_path

    with :ok <-
           validate_local_cleanup_identity(
             workspace,
             record.configured_root_identity,
             record.top_level_filesystem_identity,
             record.canonical_root,
             record.configured_root
           ),
         :ok <- run_before_remove_hook(workspace, record, nil),
         :ok <-
           validate_local_cleanup_identity(
             workspace,
             record.configured_root_identity,
             record.top_level_filesystem_identity,
             record.canonical_root,
             record.configured_root
           ),
         {:ok, quarantine_identity} <- ensure_local_quarantine_directory(record, quarantine_state),
         quarantine_workspace <- local_quarantine_workspace(record),
         :ok <- ensure_local_quarantine_workspace_absent(quarantine_workspace),
         :ok <- rename_local_workspace_to_quarantine(workspace, quarantine_workspace),
         :ok <-
           validate_local_quarantined_workspace(
             record,
             local_quarantine_dir(record),
             quarantine_workspace,
             quarantine_identity
           ) do
      remove_local_quarantined_workspace(record, ledger, opts, quarantine_identity)
    end
  end

  defp remove_local_quarantined_workspace(record, ledger, opts, quarantine_identity) do
    quarantine_dir = local_quarantine_dir(record)
    quarantine_workspace = local_quarantine_workspace(record)

    with :ok <-
           validate_local_quarantined_workspace(
             record,
             quarantine_dir,
             quarantine_workspace,
             quarantine_identity
           ),
         {:ok, _removed} <- remove_local_workspace_tree(quarantine_workspace, opts),
         :ok <- ensure_local_quarantine_workspace_absent(quarantine_workspace),
         :ok <- File.rmdir(quarantine_dir),
         {:ok, _released} <-
           OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :released) do
      {:ok, [record.canonical_workspace_path]}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp local_quarantine_state(record) do
    quarantine_dir = local_quarantine_dir(record)

    case File.lstat(quarantine_dir) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o777) == 0o700 ->
        local_quarantine_directory_state(record, quarantine_dir)

      {:ok, %File.Stat{type: :directory}} ->
        {:error, {:workspace_quarantine_permissions_mismatch, quarantine_dir}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:workspace_quarantine_type_mismatch, quarantine_dir, type}}

      {:error, reason} ->
        {:error, {:workspace_quarantine_unavailable, quarantine_dir, reason}}
    end
  end

  defp local_quarantine_directory_state(record, quarantine_dir) do
    with {:ok, quarantine_identity} <- OwnershipLedger.filesystem_identity(quarantine_dir),
         :ok <- validate_local_quarantine_directory(record, quarantine_dir, quarantine_identity),
         {:ok, entries} <- File.ls(quarantine_dir) do
      classify_local_quarantine_entries(entries, quarantine_dir, quarantine_identity)
    end
  end

  defp classify_local_quarantine_entries([], _quarantine_dir, quarantine_identity),
    do: {:ok, {:empty, quarantine_identity}}

  defp classify_local_quarantine_entries(["workspace"], _quarantine_dir, quarantine_identity),
    do: {:ok, {:workspace, quarantine_identity}}

  defp classify_local_quarantine_entries(entries, quarantine_dir, _quarantine_identity),
    do: {:error, {:workspace_quarantine_contents_unexpected, quarantine_dir, entries}}

  defp ensure_local_quarantine_directory(record, {:empty, identity}) do
    with :ok <- validate_local_quarantine_directory(record, local_quarantine_dir(record), identity) do
      {:ok, identity}
    end
  end

  defp ensure_local_quarantine_directory(record, :absent) do
    quarantine_dir = local_quarantine_dir(record)

    with :ok <- validate_local_root_binding(record),
         :ok <- create_local_quarantine_directory(quarantine_dir),
         {:ok, quarantine_identity} <- OwnershipLedger.filesystem_identity(quarantine_dir),
         :ok <- validate_local_quarantine_directory(record, quarantine_dir, quarantine_identity) do
      {:ok, quarantine_identity}
    end
  end

  defp create_local_quarantine_directory(quarantine_dir) do
    case File.mkdir(quarantine_dir) do
      :ok ->
        with {:ok, before_chmod} <- OwnershipLedger.filesystem_identity(quarantine_dir),
             :ok <- File.chmod(quarantine_dir, 0o700),
             {:ok, after_chmod} <- OwnershipLedger.filesystem_identity(quarantine_dir),
             true <- before_chmod == after_chmod do
          :ok
        else
          false -> {:error, {:workspace_quarantine_changed, quarantine_dir}}
          {:error, reason} -> {:error, {:workspace_quarantine_create_failed, quarantine_dir, reason}}
        end

      {:error, :eexist} ->
        {:error, {:workspace_quarantine_already_exists, quarantine_dir}}

      {:error, reason} ->
        {:error, {:workspace_quarantine_create_failed, quarantine_dir, reason}}
    end
  end

  defp validate_local_quarantine_directory(record, quarantine_dir, expected_identity) do
    with :ok <- validate_local_root_binding(record),
         {:ok, %File.Stat{type: :directory, mode: mode}} <- File.lstat(quarantine_dir),
         true <- Bitwise.band(mode, 0o777) == 0o700,
         {:ok, ^quarantine_dir} <- PathSafety.canonicalize(quarantine_dir),
         {:ok, actual_identity} <- OwnershipLedger.filesystem_identity(quarantine_dir),
         true <- actual_identity == expected_identity,
         {:ok, root_identity} <- OwnershipLedger.root_identity(record.canonical_root),
         true <- same_filesystem?(root_identity, actual_identity) do
      :ok
    else
      false -> {:error, {:workspace_quarantine_identity_mismatch, quarantine_dir}}
      {:ok, %File.Stat{type: type}} -> {:error, {:workspace_quarantine_type_mismatch, quarantine_dir, type}}
      {:ok, actual} -> {:error, {:workspace_quarantine_path_mismatch, quarantine_dir, actual}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_local_quarantined_workspace(record, quarantine_dir, quarantine_workspace, quarantine_identity) do
    with :ok <- validate_local_quarantine_directory(record, quarantine_dir, quarantine_identity),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(quarantine_workspace),
         {:ok, ^quarantine_workspace} <- PathSafety.canonicalize(quarantine_workspace),
         {:ok, filesystem_identity} <- OwnershipLedger.filesystem_identity(quarantine_workspace),
         true <- filesystem_identity == record.top_level_filesystem_identity do
      :ok
    else
      false -> {:error, {:workspace_identity_mismatch, quarantine_workspace}}
      {:ok, %File.Stat{type: type}} -> {:error, {:workspace_identity_mismatch, quarantine_workspace, type}}
      {:ok, actual} -> {:error, {:workspace_quarantine_path_mismatch, quarantine_workspace, actual}}
      {:error, reason} -> {:error, {:workspace_identity_mismatch, quarantine_workspace, reason}}
    end
  end

  defp ensure_local_quarantine_workspace_absent(quarantine_workspace) do
    case File.lstat(quarantine_workspace) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:workspace_quarantine_path_exists, quarantine_workspace}}
      {:error, reason} -> {:error, {:workspace_quarantine_path_unavailable, quarantine_workspace, reason}}
    end
  end

  defp rename_local_workspace_to_quarantine(workspace, quarantine_workspace) do
    case File.rename(workspace, quarantine_workspace) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_quarantine_detach_failed, workspace, quarantine_workspace, reason}}
    end
  end

  defp remove_local_workspace_tree(quarantine_workspace, opts) do
    case Keyword.get(opts, :workspace_tree_remover) do
      nil -> File.rm_rf(quarantine_workspace)
      remover when is_function(remover, 1) -> remover.(quarantine_workspace)
      _ -> {:error, {:invalid_workspace_tree_remover, quarantine_workspace}}
    end
  end

  defp workspace_quarantine_dir(record) do
    Path.join(record.canonical_root, ".symphony-workspace-release-#{quarantine_token(record)}")
  end

  defp local_quarantine_dir(record), do: workspace_quarantine_dir(record)

  defp local_quarantine_workspace(record), do: Path.join(local_quarantine_dir(record), "workspace")

  defp quarantine_token(record) do
    :crypto.hash(:sha256, record.workspace_ownership_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp same_filesystem?(%{device: expected_device}, %{device: actual_device}),
    do: expected_device == actual_device

  defp validate_local_root_binding(record) do
    expected_root_identity = record.configured_root_identity

    with :ok <- validate_current_configured_root(record.configured_root),
         {:ok, canonical_root} <- PathSafety.canonicalize(Config.local_workspace_root()),
         true <- canonical_root == record.canonical_root,
         {:ok, ^expected_root_identity} <- OwnershipLedger.root_identity(canonical_root) do
      :ok
    else
      false ->
        {:error, {:workspace_root_path_mismatch, record.canonical_root}}

      {:ok, actual} ->
        {:error, {:workspace_root_identity_mismatch, record.configured_root_identity, actual}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_pending_release_current(
         %{location: :local, worker_host: nil, trusted_host_identity: trusted} = record,
         ledger
       ) do
    if trusted == ledger.host_identity do
      validate_local_cleanup_identity(
        record.canonical_workspace_path,
        record.configured_root_identity,
        record.top_level_filesystem_identity,
        record.canonical_root,
        record.configured_root
      )
    else
      {:error, :workspace_host_identity_mismatch}
    end
  end

  defp validate_pending_release_current(
         %{location: :remote, worker_host: worker_host} = record,
         _ledger
       )
       when is_binary(worker_host) do
    validate_remote_pending_release(record, worker_host)
  end

  defp validate_pending_release_current(_record, _ledger),
    do: {:error, :workspace_ownership_not_found}

  defp validate_remote_pending_release(record, worker_host) do
    with :ok <- validate_remote_configured_root(worker_host, record.configured_root),
         {:ok, fresh} <- remote_prepare(worker_host, record.canonical_workspace_path),
         true <- remote_binding_matches?(fresh, record) do
      :ok
    else
      false -> {:error, {:workspace_identity_mismatch, record.canonical_workspace_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_binding_matches?(fresh, record) do
    fresh.present? and fresh.host_identity == record.trusted_host_identity and
      fresh.root == record.canonical_root and
      fresh.root_identity == record.configured_root_identity and
      fresh.workspace == record.canonical_workspace_path and
      fresh.workspace_identity == record.top_level_filesystem_identity
  end

  defp validate_remote_configured_root(worker_host, expected) do
    current_root = configured_root_binding(worker_host)

    cond do
      worker_host in Config.settings!().worker.ssh_hosts and current_root == expected ->
        :ok

      worker_host in Config.settings!().worker.ssh_hosts ->
        {:error, {:workspace_configured_root_mismatch, expected, current_root}}

      true ->
        {:error, {:workspace_worker_host_not_configured, worker_host}}
    end
  end

  defp run_before_remove_hook(workspace, record, worker_host) do
    hooks = Config.settings!().hooks
    issue = %{id: record.work_item_id, identifier: record.issue_identifier}

    case hooks.before_remove do
      nil -> :ok
      command -> run_hook(command, workspace, issue_context(issue), "before_remove", worker_host)
    end
  end

  defp prepare_remote_workspace(ledger, identity, workspace, worker_host, _opts) do
    with :ok <- validate_remote_configured_root(worker_host, configured_root_binding(worker_host)),
         {:ok, remote} <- remote_prepare(worker_host, workspace),
         {:ok, records} <- OwnershipLedger.list_for_work_item(ledger, identity.id) do
      remote_workspace_result(ledger, identity, remote, records, worker_host)
    end
  end

  defp remote_workspace_result(ledger, identity, remote, records, worker_host) do
    case remote.present? do
      true ->
        exact_remote_workspace_record(ledger, identity, remote, records, worker_host)

      false ->
        create_remote_workspace(ledger, identity, remote, worker_host)
    end
  end

  defp exact_remote_workspace_record(_ledger, identity, remote, records, worker_host) do
    configured_root = configured_root_binding(worker_host)

    case Enum.find(records, fn record ->
           record.state == :owned and
             exact_record_binding?(
               record,
               identity,
               remote.workspace,
               configured_root,
               remote.root,
               remote.root_identity,
               worker_host,
               remote.host_identity
             ) and
             record.top_level_filesystem_identity == remote.workspace_identity
         end) do
      nil -> {:error, {:workspace_ownership_required, remote.workspace}}
      _record -> {:ok, remote.workspace}
    end
  end

  defp create_remote_workspace(ledger, identity, remote, worker_host) do
    configured_root = configured_root_binding(worker_host)

    attrs =
      reserved_record(
        ledger,
        identity,
        remote.workspace,
        %{
          configured_root: configured_root,
          canonical_root: remote.root,
          configured_root_identity: remote.root_identity
        },
        :remote,
        worker_host,
        remote.host_identity
      )

    with {:ok, reserved} <- reserve_or_reuse_remote(ledger, attrs),
         {:ok, created} <- remote_mkdir(worker_host, remote) do
      created
      |> Map.put(:configured_root, configured_root)
      |> provision_and_own_remote_workspace(ledger, reserved, identity, worker_host)
    end
  end

  defp provision_and_own_remote_workspace(created, ledger, reserved, identity, worker_host) do
    case OwnershipLedger.transition_sync(
           ledger,
           reserved.workspace_ownership_id,
           :provisioning,
           configured_root_identity: created.root_identity,
           top_level_filesystem_identity: created.workspace_identity
         ) do
      {:ok, _provisioning} ->
        run_remote_after_create(ledger, reserved, identity, worker_host, created)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_remote_after_create(ledger, reserved, identity, worker_host, created) do
    case maybe_run_after_create_hook(
           created.workspace,
           issue_context(identity),
           worker_host
         ) do
      :ok ->
        own_remote_workspace(ledger, reserved, worker_host, created)

      {:error, reason} ->
        case remote_after_create_failure(ledger, reserved, worker_host) do
          :ok -> {:error, reason}
          {:error, cleanup_reason} -> {:error, {:after_create_cleanup_failed, reason, cleanup_reason}}
        end
    end
  end

  defp own_remote_workspace(ledger, reserved, worker_host, created) do
    case validate_remote_after_create(worker_host, created) do
      :ok ->
        case OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :owned,
               top_level_filesystem_identity: created.workspace_identity
             ) do
          {:ok, _owned} -> {:ok, created.workspace}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:owned_identity_mismatch, reason}}
    end
  end

  defp validate_remote_after_create(worker_host, created) do
    with :ok <- validate_remote_configured_root(worker_host, created.configured_root),
         {:ok, fresh} <- remote_prepare(worker_host, created.workspace),
         true <- remote_created_binding_matches?(fresh, created) do
      :ok
    else
      false -> {:error, {:workspace_identity_mismatch, created.workspace}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_created_binding_matches?(fresh, created) do
    fresh.present? and fresh.host_identity == created.host_identity and
      fresh.root == created.root and fresh.root_identity == created.root_identity and
      fresh.workspace == created.workspace and fresh.workspace_identity == created.workspace_identity
  end

  defp reserve_or_reuse_remote(ledger, attrs) do
    case OwnershipLedger.list_for_work_item(ledger, attrs.work_item_id) do
      {:ok, records} ->
        records
        |> Enum.filter(&reservation_record?(&1, attrs, :remote, attrs.worker_host))
        |> reserve_or_reuse_record(ledger, attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remote_after_create_failure(ledger, reserved, worker_host) do
    with {:ok, pending} <-
           OwnershipLedger.transition_sync(
             ledger,
             reserved.workspace_ownership_id,
             :release_pending,
             release_origin: :failed_provisioning
           ),
         :ok <- validate_remote_configured_root(worker_host, pending.configured_root),
         {:ok, {output, 0}} <-
           run_remote_command(
             worker_host,
             remote_remove_guard_script(pending),
             Config.settings!().hooks.timeout_ms
           ),
         {:ok, _released} <-
           OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :released) do
      _ = output
      :ok
    else
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :workspace_ownership_not_found}
    end
  end

  defp remote_prepare(worker_host, workspace) do
    script = remote_prepare_script(workspace)

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_workspace_output(output)
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remote_filesystem_identity_function do
    """
    symphony_filesystem_identity() {
      local stat_record mode device inode birth_time birth_time_ns mode_value
      stat_record=$(stat -c '%f|%d|%i|%w' -- "$1") || return 1
      IFS='|' read -r mode device inode birth_time <<< "$stat_record"
      [[ "$mode" =~ ^[0-9a-fA-F]+$ ]] || return 1
      [[ "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ ]] || return 1
      mode_value=$((16#$mode))
      [ $((mode_value & 61440)) -eq 16384 ] || return 1
      [ -n "$birth_time" ] && [ "$birth_time" != "-" ] || return 1
      birth_time_ns=$(date -d "$birth_time" +%s%N 2>/dev/null) || return 1
      [[ "$birth_time_ns" =~ ^-?[0-9]+$ ]] || return 1
      printf '%s:%s:%s' "$device" "$inode" "$birth_time_ns"
    }
    """
  end

  defp remote_prepare_script(workspace) do
    root = Config.settings!().workspace.root
    host_identity_path = @default_remote_host_identity

    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      remote_shell_assign("root", root),
      remote_shell_assign("host_identity_path", host_identity_path),
      "case \"$root\" in \"$workspace\"|\"$workspace\"/*) exit 71 ;; esac",
      "case \"$host_identity_path\" in \"$root\"|\"$root\"/*|\"$workspace\"|\"$workspace\"/*) exit 71 ;; esac",
      "if [ -L \"$root\" ] || [ ! -d \"$root\" ]; then exit 72; fi",
      remote_filesystem_identity_function(),
      "host_identity_dir=$(dirname \"$host_identity_path\")",
      "umask 077",
      "mkdir -p \"$host_identity_dir\"",
      "check_dir=\"$host_identity_dir\"",
      "while [ \"$check_dir\" != \"/\" ] && [ \"$check_dir\" != \".\" ]; do if [ -L \"$check_dir\" ] || [ ! -d \"$check_dir\" ]; then exit 73; fi; check_dir=$(dirname \"$check_dir\"); done",
      "if [ \"$(stat -c '%a' -- \"$host_identity_dir\")\" != 700 ]; then exit 73; fi",
      "if [ -L \"$host_identity_path\" ]; then exit 73; fi",
      "if [ ! -e \"$host_identity_path\" ]; then identity_tmp=\"$host_identity_path.$$.$RANDOM\"; (umask 077; printf 'host-%s\\n' \"$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')\" > \"$identity_tmp\"); chmod 600 \"$identity_tmp\"; if ln \"$identity_tmp\" \"$host_identity_path\" 2>/dev/null; then :; fi; rm -f \"$identity_tmp\"; fi",
      "if [ ! -f \"$host_identity_path\" ] || [ \"$(stat -c '%a' -- \"$host_identity_path\")\" != 600 ]; then exit 74; fi",
      "host_identity=$(cat \"$host_identity_path\")",
      "root_identity=$(symphony_filesystem_identity \"$root\")",
      "present=0",
      "workspace_identity=-",
      "if [ -L \"$workspace\" ]; then exit 75; fi",
      "if [ -e \"$workspace\" ]; then",
      "  if [ ! -d \"$workspace\" ]; then exit 76; fi",
      "  present=1",
      "  workspace_identity=$(symphony_filesystem_identity \"$workspace\")",
      "fi",
      "workspace=$(if [ -e \"$workspace\" ]; then cd \"$workspace\" && pwd -P; else printf '%s' \"$workspace\"; fi)",
      "root=$(cd \"$root\" && pwd -P)",
      "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$present\" \"$workspace\" \"$root\" \"$host_identity\" \"$root_identity\" \"$workspace_identity\" \"$host_identity_path\""
    ]
    |> Enum.join("\n")
  end

  defp remote_mkdir(worker_host, remote) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", remote.workspace),
        remote_shell_assign("root", remote.root),
        remote_shell_assign("host_identity_path", remote.host_identity_path),
        remote_filesystem_identity_function(),
        "if [ -L \"$root\" ] || [ ! -d \"$root\" ]; then exit 81; fi",
        "if [ \"$(symphony_filesystem_identity \"$root\")\" != #{shell_escape(remote.root_identity)} ]; then exit 82; fi",
        "host_identity_dir=$(dirname \"$host_identity_path\")",
        "check_dir=\"$host_identity_dir\"",
        "while [ \"$check_dir\" != \"/\" ] && [ \"$check_dir\" != \".\" ]; do if [ -L \"$check_dir\" ] || [ ! -d \"$check_dir\" ]; then exit 83; fi; check_dir=$(dirname \"$check_dir\"); done",
        "if [ \"$(stat -c '%a' -- \"$host_identity_dir\")\" != 700 ]; then exit 83; fi",
        "if [ -L \"$host_identity_path\" ] || [ ! -f \"$host_identity_path\" ] || [ \"$(stat -c '%a' -- \"$host_identity_path\")\" != 600 ]; then exit 83; fi",
        "if [ \"$(cat \"$host_identity_path\")\" != #{shell_escape(remote.host_identity)} ]; then exit 83; fi",
        "if [ -e \"$workspace\" ]; then exit 84; fi",
        "mkdir \"$workspace\"",
        "workspace=$(cd \"$workspace\" && pwd -P)",
        "printf '%s\\t%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$workspace\" \"$(symphony_filesystem_identity \"$workspace\")\" \"$(symphony_filesystem_identity \"$root\")\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} -> parse_remote_mkdir_output(output, remote)
      {:ok, {output, status}} -> {:error, {:workspace_prepare_failed, worker_host, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_remote_mkdir_output(output, remote) do
    line =
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn value ->
        case String.split(value, "\t", parts: 4) do
          [@remote_workspace_marker, workspace, workspace_identity, root_identity]
          when workspace != "" and workspace_identity != "" and root_identity != "" ->
            %{remote | workspace: workspace, workspace_identity: workspace_identity, root_identity: root_identity}

          _ ->
            nil
        end
      end)

    if is_map(line), do: {:ok, line}, else: {:error, {:workspace_prepare_failed, :invalid_output, output}}
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, worker_host) do
    case Config.settings!().hooks.after_create do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_create", worker_host)
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    if CredentialBoundary.routed_workspace_shell_hook_skipped?(hook_name) do
      Logger.info("Skipping workspace hook in routed mode hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

      :ok
    else
      run_local_hook(command, workspace, issue_context, hook_name)
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    if CredentialBoundary.routed_workspace_shell_hook_skipped?(hook_name) do
      Logger.info("Skipping workspace hook in routed mode hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

      :ok
    else
      run_remote_hook(command, workspace, issue_context, hook_name, worker_host)
    end
  end

  defp run_local_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    hook_env = hook_process_env()

    cmd_opts =
      [cd: workspace, stderr_to_stdout: true]
      |> maybe_put_hook_env(hook_env)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cmd_opts)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_remote_hook(command, workspace, issue_context, hook_name, worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    remote_command =
      [
        CredentialBoundary.unset_shell_command(CredentialBoundary.configured_secret_environment_names()),
        "cd #{shell_escape(workspace)}",
        command
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" && ")

    case run_remote_command(worker_host, remote_command, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, _command, timeout_ms}} ->
        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output =
      output
      |> IO.iodata_to_binary()
      |> CredentialBoundary.redact(CredentialBoundary.configured_secret_environment_names())

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp hook_process_env do
    CredentialBoundary.hook_process_env(CredentialBoundary.configured_secret_environment_names())
  end

  defp maybe_put_hook_env(opts, hook_env), do: Keyword.put(opts, :env, hook_env)

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    payload =
      output
      |> IO.iodata_to_binary()
      |> String.split("\n", trim: true)
      |> Enum.find_value(&parse_remote_workspace_line/1)

    case payload do
      %{present?: present?} = remote when is_boolean(present?) ->
        {:ok, remote}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp parse_remote_workspace_line(line) do
    case String.split(line, "\t", parts: 8) do
      [
        @remote_workspace_marker,
        present,
        workspace,
        root,
        host_identity,
        root_identity,
        workspace_identity,
        host_identity_path
      ] ->
        remote_workspace_payload(
          present,
          workspace,
          root,
          host_identity,
          root_identity,
          workspace_identity,
          host_identity_path
        )

      _ ->
        nil
    end
  end

  defp remote_workspace_payload(
         present,
         workspace,
         root,
         host_identity,
         root_identity,
         workspace_identity,
         host_identity_path
       ) do
    valid_fields = [
      present in ["0", "1"],
      workspace != "",
      root != "",
      host_identity != "",
      root_identity not in ["", "-"],
      host_identity_path != "",
      Path.type(workspace) == :absolute,
      Path.type(root) == :absolute,
      Path.type(host_identity_path) == :absolute,
      workspace != root,
      String.starts_with?(workspace, root <> "/"),
      remote_workspace_presence_valid?(present, workspace_identity)
    ]

    if Enum.all?(valid_fields) do
      %{
        present?: present == "1",
        workspace: workspace,
        root: root,
        host_identity: host_identity,
        root_identity: root_identity,
        workspace_identity: workspace_identity,
        host_identity_path: host_identity_path
      }
    end
  end

  defp remote_workspace_presence_valid?("1", identity), do: identity not in ["", "-"]
  defp remote_workspace_presence_valid?("0", "-"), do: true
  defp remote_workspace_presence_valid?(_present, _identity), do: false

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
