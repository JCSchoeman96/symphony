defmodule SymphonyElixir.WorkspaceOwnershipLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.Workspace.{Ownership, OwnershipLedger}

  @identity %{
    tracker_kind: "linear",
    provider_scope: %{project_slug: "project-a"}
  }

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-workspace-ownership-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, path: Path.join(root, "ownership.dets")}
  end

  test "opens a private ledger and round-trips reserved records by id, work item, and host", %{
    root: root,
    path: path
  } do
    assert Ownership.valid_transition?(:reserved, :provisioning)
    assert Ownership.workspace_key(%{identifier: "MT-123"}) == Ownership.workspace_key("MT-123")
    assert Ownership.workspace_key(nil) == "issue"

    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert OwnershipLedger.schema_version() == 1

    record = ownership("ownership-a", "work-a", root)
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)
    assert reserved.workspace_ownership_id == "ownership-a"
    assert reserved.issue_identifier == "work-a"
    assert reserved.state == :reserved
    assert reserved.schema_version == OwnershipLedger.schema_version()
    assert reserved.project_namespace == "project-a"
    assert reserved.tracker_identity == @identity
    assert Enum.sort(Map.keys(reserved)) == Enum.sort(Ownership.record_keys())
    refute Map.has_key?(reserved, :ownership_generation)
    refute Map.has_key?(reserved, :runtime_attempt_id)

    assert {:ok, ^reserved} = OwnershipLedger.get(ledger, "ownership-a")
    assert {:ok, [^reserved]} = OwnershipLedger.list_for_work_item(ledger, "work-a")
    assert {:ok, [^reserved]} = OwnershipLedger.list_for_host(ledger, nil)
    assert :ok = OwnershipLedger.close(ledger)

    {:ok, reopened} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert {:ok, ^reserved} = OwnershipLedger.get(reopened, "ownership-a")
    assert :ok = OwnershipLedger.close(reopened)
  end

  test "lists local and remote ownerships for a work item", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    local = ownership("ownership-local", "work-a", root)

    remote =
      ownership("ownership-remote", "work-a", root)
      |> Map.put(:location, :remote)
      |> Map.put(:worker_host, "worker-a")
      |> Map.put(:trusted_host_identity, "host-remote")

    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, local)
    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, remote)
    assert {:ok, records} = OwnershipLedger.list_for_work_item(ledger, "work-a")
    assert Enum.map(records, & &1.workspace_ownership_id) == ["ownership-local", "ownership-remote"]
    assert {:ok, [remote_record]} = OwnershipLedger.list_for_host(ledger, "worker-a")
    assert remote_record.workspace_ownership_id == remote.workspace_ownership_id
    assert remote_record.state == :reserved
    assert {:ok, []} = OwnershipLedger.list_for_host(ledger, "worker-b")
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "transitions an ownership and attaches the post-mkdir filesystem identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-a", "work-a", root)
    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, record)

    filesystem_identity = %{device: 1, inode: 2}
    provisioning_attrs = [top_level_filesystem_identity: filesystem_identity]

    assert {:ok, provisioning} =
             OwnershipLedger.transition_sync(ledger, "ownership-a", :provisioning, provisioning_attrs)

    assert provisioning.state == :provisioning

    assert {:ok, owned} =
             OwnershipLedger.transition_sync(ledger, "ownership-a", :owned, top_level_filesystem_identity: filesystem_identity)

    assert owned.state == :owned
    assert owned.top_level_filesystem_identity == filesystem_identity

    assert {:error, {:invalid_workspace_release_origin, :untrusted}} =
             OwnershipLedger.transition_sync(ledger, "ownership-a", :release_pending, release_origin: :untrusted)

    assert {:ok, pending_before_cancel} =
             OwnershipLedger.transition_sync(ledger, "ownership-a", :release_pending)

    assert pending_before_cancel.state == :release_pending
    assert pending_before_cancel.release_origin == :authorized_cleanup
    assert {:ok, cancelled} = OwnershipLedger.transition_sync(ledger, "ownership-a", :owned)
    assert cancelled.state == :owned
    assert cancelled.release_origin == nil
    assert {:ok, pending} = OwnershipLedger.transition_sync(ledger, "ownership-a", :release_pending)
    assert {:ok, released} = OwnershipLedger.transition_sync(ledger, "ownership-a", :released)
    assert released.state == :released
    assert released.release_origin == :authorized_cleanup

    assert {:error, {:invalid_transition, :released, :owned}} =
             OwnershipLedger.transition_sync(ledger, "ownership-a", :owned)

    assert pending.state == :release_pending
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "serializes concurrent ownership transitions to prevent stale state resurrection", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-transition-race", "work-transition-race", root)
    {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)
    filesystem_identity = local_identity(root)

    {:ok, _provisioning} =
      OwnershipLedger.transition_sync(
        ledger,
        reserved.workspace_ownership_id,
        :provisioning,
        top_level_filesystem_identity: filesystem_identity
      )

    {:ok, _owned} = OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)
    {:ok, pending} = OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :release_pending)
    assert :ok = OwnershipLedger.close(ledger)

    parent = self()

    write_fun = fn table, records ->
      case records do
        [{{:ownership, "ownership-transition-race"}, %{state: :released}}] ->
          send(parent, {:release_write_started, self()})

          receive do
            :allow_release_write -> :dets.insert(table, records)
          end

        _ ->
          :dets.insert(table, records)
      end
    end

    {:ok, ledger} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: write_fun
      )

    release_task =
      Task.async(fn ->
        OwnershipLedger.transition_sync(ledger, pending.workspace_ownership_id, :released)
      end)

    assert_receive {:release_write_started, release_writer}, 1_000

    cancel_task =
      Task.async(fn ->
        OwnershipLedger.transition_sync(ledger, pending.workspace_ownership_id, :owned)
      end)

    refute_receive {:release_write_started, _other_writer}, 100
    send(release_writer, :allow_release_write)

    assert {:ok, released} = Task.await(release_task, 1_000)
    assert {:error, {:invalid_transition, :released, :owned}} = Task.await(cancel_task, 1_000)
    assert {:ok, current} = OwnershipLedger.get(ledger, pending.workspace_ownership_id)
    assert current == released
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "requires the root identity in the reservation before provisioning", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-identities", "work-identities", root)
    record = %{record | configured_root_identity: nil, top_level_filesystem_identity: nil}

    assert {:error, :missing_configured_root_identity} = OwnershipLedger.reserve_sync(ledger, record)

    record = %{record | configured_root_identity: local_identity(root)}
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)
    assert reserved.configured_root_identity == local_identity(root)
    assert reserved.top_level_filesystem_identity == nil
    filesystem_identity = %{device: 1, inode: 2}
    provisioning_attrs = [top_level_filesystem_identity: filesystem_identity]

    assert {:ok, provisioning} =
             OwnershipLedger.transition_sync(ledger, "ownership-identities", :provisioning, provisioning_attrs)

    top_level_filesystem_identity = filesystem_identity

    assert {:ok, owned} =
             OwnershipLedger.transition_sync(ledger, "ownership-identities", :owned, top_level_filesystem_identity)

    assert provisioning.configured_root_identity == local_identity(root)
    assert owned.top_level_filesystem_identity == top_level_filesystem_identity
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "persists and validates the issue identifier against the workspace key and path", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-identifier", "ABC/123", root)

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)
    assert reserved.issue_identifier == "ABC/123"
    assert reserved.workspace_key == Ownership.workspace_key(reserved.issue_identifier)
    assert Path.basename(reserved.canonical_workspace_path) == reserved.workspace_key

    mismatched_key = %{record | workspace_key: "other-key"}
    assert {:error, _reason} = OwnershipLedger.reserve_sync(ledger, mismatched_key)

    mismatched_path = %{record | canonical_workspace_path: Path.join(record.canonical_root, "other-key")}
    assert {:error, _reason} = OwnershipLedger.reserve_sync(ledger, mismatched_path)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects an active local claim for an already claimed resource identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    first = ownership("ownership-local-one", "work-one", root)
    second = %{first | workspace_ownership_id: "ownership-local-two", work_item_id: "work-two"}

    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, first)

    assert {:error, {:resource_identity_already_claimed, _identity}} =
             OwnershipLedger.reserve_sync(ledger, second)

    filesystem_identity = %{device: 1, inode: 2}
    provisioning_attrs = [top_level_filesystem_identity: filesystem_identity]

    assert {:ok, _} =
             OwnershipLedger.transition_sync(ledger, first.workspace_ownership_id, :provisioning, provisioning_attrs)

    assert {:ok, _} = OwnershipLedger.transition_sync(ledger, first.workspace_ownership_id, :release_pending)

    assert {:error, {:resource_identity_already_claimed, _identity}} =
             OwnershipLedger.reserve_sync(ledger, second)

    assert {:ok, _} = OwnershipLedger.transition_sync(ledger, first.workspace_ownership_id, :released)
    assert {:ok, released_claim} = OwnershipLedger.reserve_sync(ledger, second)
    assert released_claim.workspace_ownership_id == second.workspace_ownership_id
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects transitions that collide with an injected active resource record", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    first = ownership("ownership-collision-first", "work-collision", root)
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, first)
    filesystem_identity = %{device: 1, inode: 2}

    assert {:ok, _provisioning} =
             OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :provisioning,
               top_level_filesystem_identity: filesystem_identity
             )

    assert {:ok, _owned} = OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)

    duplicate = %{
      reserved
      | workspace_ownership_id: "ownership-collision-second",
        work_item_id: "work-collision-second",
        state: :reserved,
        top_level_filesystem_identity: nil
    }

    assert :ok = :dets.insert(ledger.table, {{:ownership, duplicate.workspace_ownership_id}, duplicate})

    assert {:error, {:resource_identity_already_claimed, _identity}} =
             OwnershipLedger.transition_sync(
               ledger,
               duplicate.workspace_ownership_id,
               :provisioning,
               top_level_filesystem_identity: filesystem_identity
             )

    bad_key = {:unexpected, "ownership-record"}
    assert :ok = :dets.insert(ledger.table, {bad_key, %{malformed: true}})
    assert {:error, {:corrupt_ownership_record, ^bad_key, :invalid_record}} = OwnershipLedger.list(ledger)
    assert :ok = :dets.delete(ledger.table, bad_key)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "normalizes identifier aliases and remote filesystem roots", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    identifier_only =
      ownership("ownership-identifier-only", "work-identifier-only", root)
      |> Map.delete(:issue_identifier)
      |> Map.put(:identifier, "work-identifier-only")

    assert {:ok, from_identifier} = OwnershipLedger.reserve_sync(ledger, identifier_only)
    assert from_identifier.issue_identifier == "work-identifier-only"

    matching_alias =
      ownership("ownership-matching-alias", "work-matching-alias", root)
      |> Map.put(:identifier, "work-matching-alias")

    assert {:ok, from_matching_alias} = OwnershipLedger.reserve_sync(ledger, matching_alias)
    assert from_matching_alias.issue_identifier == "work-matching-alias"

    missing_identifier =
      Map.drop(ownership("ownership-missing-alias", "work-missing-alias", root), [:issue_identifier])
      |> Map.delete(:identifier)

    assert {:error, {:corrupt_ownership_record, :invalid_record}} =
             OwnershipLedger.reserve_sync(ledger, missing_identifier)

    remote_root_record = %{
      work_item_id: "work-root-normalization",
      issue_identifier: "MT-ROOT-NORMALIZATION",
      workspace_key: "MT-ROOT-NORMALIZATION",
      workspace_ownership_id: "ownership-root-normalization",
      location: :remote,
      worker_host: "worker-root-normalization",
      trusted_host_identity: "remote-host-root-normalization",
      configured_root: "/",
      configured_root_identity: "1:2",
      canonical_root: "/",
      canonical_workspace_path: "/MT-ROOT-NORMALIZATION",
      top_level_filesystem_identity: nil
    }

    assert {:ok, normalized_root} = OwnershipLedger.reserve_sync(ledger, remote_root_record)
    assert normalized_root.configured_root == "/"
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "serializes concurrent reservations before checking resource identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert :ok = OwnershipLedger.close(ledger)

    parent = self()

    write_fun = fn table, records ->
      send(parent, {:reserve_write_started, self(), records})

      receive do
        :allow_reserve_write -> :dets.insert(table, records)
      end
    end

    {:ok, ledger} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: write_fun
      )

    first = ownership("ownership-concurrent-one", "work-concurrent-one", root)
    second = %{first | workspace_ownership_id: "ownership-concurrent-two", work_item_id: "work-concurrent-two"}

    first_task = Task.async(fn -> OwnershipLedger.reserve_sync(ledger, first) end)
    assert_receive {:reserve_write_started, first_writer, _records}, 1_000

    second_task =
      Task.async(fn ->
        send(parent, :second_reservation_started)
        OwnershipLedger.reserve_sync(ledger, second)
      end)

    assert_receive :second_reservation_started, 1_000
    refute_receive {:reserve_write_started, _second_writer, _records}, 100

    send(first_writer, :allow_reserve_write)

    assert {:ok, _reserved} = Task.await(first_task, 1_000)
    assert {:error, {:resource_identity_already_claimed, _identity}} = Task.await(second_task, 1_000)
    refute_receive {:reserve_write_started, _second_writer, _records}, 100
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "requires a top-level identity before provisioning, release pending, or release", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-transition-identity", "work-transition-identity", root)
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)

    assert {:error, {:invalid_transition, :reserved, :release_pending}} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :release_pending)

    assert {:error, :missing_top_level_filesystem_identity} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :provisioning)

    filesystem_identity = %{major_device: 1, minor_device: 0, inode: 2}
    filesystem_identity_attrs = [top_level_filesystem_identity: filesystem_identity]
    ownership_id = reserved.workspace_ownership_id

    assert {:ok, _provisioning} =
             OwnershipLedger.transition_sync(ledger, ownership_id, :provisioning, filesystem_identity_attrs)

    assert {:ok, pending} =
             OwnershipLedger.transition_sync(ledger, ownership_id, :release_pending)

    assert {:ok, released} =
             OwnershipLedger.transition_sync(ledger, ownership_id, :released)

    assert released.state == :released
    assert released.top_level_filesystem_identity == filesystem_identity
    assert pending.top_level_filesystem_identity == filesystem_identity
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "fails closed when a stored lifecycle record lacks its filesystem identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-missing-filesystem-identity", "work-missing-identity", root)
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)

    invalid_pending = %{reserved | state: :release_pending}
    assert :ok = :dets.insert(ledger.table, {{:ownership, reserved.workspace_ownership_id}, invalid_pending})
    assert :ok = :dets.sync(ledger.table)

    assert {:error, {:corrupt_ownership_record, {:ownership, "ownership-missing-filesystem-identity"}, :missing_top_level_filesystem_identity}} = OwnershipLedger.list(ledger)

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects an ownership ledger stored inside its workspace", %{root: root} do
    workspace_key = Ownership.workspace_key("work-ledger-inside")
    canonical_root = Path.expand(Path.join(root, "workspaces"))
    workspace_path = Path.join(canonical_root, workspace_key)
    ledger_path = Path.join(workspace_path, "ownership.dets")

    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: ledger_path)

    record =
      ownership("ownership-ledger-inside", "work-ledger-inside", root)
      |> Map.put(:canonical_root, canonical_root)
      |> Map.put(:canonical_workspace_path, workspace_path)

    assert {:error, :ledger_inside_workspace} = OwnershipLedger.reserve_sync(ledger, record)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects host ledger storage under the configured workspace root", %{root: root} do
    workspace_root = Path.join(root, "agent-workspaces")
    state_root = Path.join(root, "host-state")
    File.mkdir_p!(workspace_root)
    unsafe_ledger_path = Path.join(workspace_root, "workspace-ownership.dets")

    assert {:error, :ledger_inside_workspace_root} =
             OwnershipLedger.open("project-a", @identity,
               root: state_root,
               path: unsafe_ledger_path,
               workspace_root: workspace_root
             )
  end

  test "rejects host ledger storage under a symlinked workspace root", %{root: root} do
    canonical_workspace_root = Path.join(root, "canonical-workspaces")
    configured_workspace_root = Path.join(root, "workspace-alias")
    ledger_root = Path.join(canonical_workspace_root, "host-state")

    File.mkdir_p!(canonical_workspace_root)
    File.ln_s!(canonical_workspace_root, configured_workspace_root)

    assert {:error, :ledger_inside_workspace_root} =
             OwnershipLedger.open("project-a", @identity,
               root: ledger_root,
               workspace_root: configured_workspace_root
             )

    refute File.exists?(ledger_root)
  end

  test "rejects an active remote claim for an already claimed resource identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    first =
      ownership("ownership-remote-one", "work-one", root)
      |> Map.merge(%{location: :remote, worker_host: "worker-a", trusted_host_identity: "host-a"})

    second = %{first | workspace_ownership_id: "ownership-remote-two", work_item_id: "work-two"}

    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, first)

    assert {:error, {:resource_identity_already_claimed, _identity}} =
             OwnershipLedger.reserve_sync(ledger, second)

    distinct_host = %{second | worker_host: "worker-b"}
    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, distinct_host)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects invalid records and duplicate ownership ids", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-a", "work-a", root)
    assert {:ok, _} = OwnershipLedger.reserve_sync(ledger, record)

    assert {:error, {:ownership_id_already_exists, "ownership-a"}} =
             OwnershipLedger.reserve_sync(ledger, record)

    assert {:error, _} = OwnershipLedger.reserve_sync(ledger, Map.put(record, :runtime_attempt_id, "forbidden"))
    assert {:error, _} = OwnershipLedger.reserve_sync(ledger, %{record | location: :remote, worker_host: nil})
    assert {:error, _} = OwnershipLedger.reserve_sync(ledger, %{record | canonical_workspace_path: root})

    assert {:error, _} =
             OwnershipLedger.reserve_sync(ledger, Map.put(record, :trusted_host_identity, "foreign-host"))

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "binds metadata to the project namespace and exact tracker identity", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert :ok = OwnershipLedger.close(ledger)

    assert {:error, {:ledger_project_namespace_mismatch, "project-a", "project-b"}} =
             OwnershipLedger.open("project-b", @identity, root: root, path: path)

    assert {:error, {:ledger_tracker_identity_mismatch, @identity, _}} =
             OwnershipLedger.open("project-a", %{tracker_kind: "linear", provider_scope: %{}},
               root: root,
               path: path
             )
  end

  test "writes before syncing and returns injected failures", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert :ok = OwnershipLedger.close(ledger)

    parent = self()

    {:ok, instrumented} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: fn _table, records ->
          send(parent, {:write, records})
          :ok
        end,
        sync_fun: fn _table ->
          send(parent, :sync)
          :ok
        end
      )

    record = ownership("ownership-write", "work-write", root)
    assert {:ok, _} = OwnershipLedger.reserve_sync(instrumented, record)
    assert_receive {:write, [{{:ownership, "ownership-write"}, written}]}
    assert written.workspace_ownership_id == record.workspace_ownership_id
    assert written.state == :reserved
    assert_receive :sync
    assert :ok = OwnershipLedger.close(instrumented)

    {:ok, write_failed} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: fn _table, _records -> {:error, :disk_full} end
      )

    assert {:error, {:ledger_write_failed, :disk_full}} =
             OwnershipLedger.reserve_sync(write_failed, ownership("ownership-fail", "work-fail", root))

    assert :ok = OwnershipLedger.close(write_failed)

    {:ok, sync_failed} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        sync_fun: fn _table -> {:error, :sync_failed} end
      )

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             OwnershipLedger.reserve_sync(sync_failed, ownership("ownership-sync", "work-sync", root))

    assert :ok = OwnershipLedger.close(sync_failed)
  end

  test "fails closed on corrupt tables instead of treating them as empty", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert :ok = OwnershipLedger.close(ledger)

    {:ok, _table} = :dets.open_file(path, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.insert(path, {{:ownership, "corrupt"}, :corrupt})
    assert :ok = :dets.sync(path)
    assert :ok = :dets.close(path)

    assert {:error, {:corrupt_ownership_record, {:ownership, "corrupt"}, :invalid_record}} =
             OwnershipLedger.open("project-a", @identity, root: root, path: path)
  end

  test "creates a private local host identity outside workspace content", %{root: root} do
    workspace = Path.join(root, "workspaces/work-a")
    File.mkdir_p!(workspace)

    assert {:ok, identity} = OwnershipLedger.local_host_identity(root: root)
    assert is_binary(identity) and byte_size(identity) > 0

    assert {:ok, filesystem_identity} = OwnershipLedger.filesystem_identity(workspace)

    case :os.type() do
      {:unix, :darwin} -> assert Enum.sort(Map.keys(filesystem_identity)) == [:device, :generation, :inode]
      _other -> assert Enum.sort(Map.keys(filesystem_identity)) == [:birth_time_ns, :device, :inode]
    end

    path = OwnershipLedger.host_identity_path(root: root)
    assert Path.relative_to(path, workspace) == path
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert stat.type == :regular
    assert {:ok, ^identity} = OwnershipLedger.local_host_identity(root: root)
  end

  test "fails closed when the filesystem does not report a birth time", %{root: root} do
    workspace = Path.join(root, "unknown-birth-time")
    stat_wrapper = Path.join(root, "stat")
    previous_path = System.get_env("PATH")
    previous_stat_path = System.get_env("SYMP_TEST_STAT_PATH")

    on_exit(fn ->
      if is_nil(previous_path), do: System.delete_env("PATH"), else: System.put_env("PATH", previous_path)

      if is_nil(previous_stat_path),
        do: System.delete_env("SYMP_TEST_STAT_PATH"),
        else: System.put_env("SYMP_TEST_STAT_PATH", previous_stat_path)
    end)

    File.mkdir!(workspace)

    File.write!(stat_wrapper, """
    #!/bin/sh
    if { [ "${2:-}" = "%f|%d|%i|%w" ] || [ "${2:-}" = "%Xp|%d|%i|%v" ]; } && [ "${4:-}" = "$SYMP_TEST_STAT_PATH" ]; then
      if [ "${2:-}" = "%Xp|%d|%i|%v" ]; then
        printf '41ED|39|999|0\\n'
        exit 0
      fi
      printf '41ed|39|999|-\\n'
    else
      exec /usr/bin/stat "$@"
    fi
    """)

    File.chmod!(stat_wrapper, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    System.put_env("SYMP_TEST_STAT_PATH", workspace)

    case :os.type() do
      {:unix, :darwin} ->
        assert {:error, {:filesystem_identity_failed, :generation_unavailable}} =
                 OwnershipLedger.filesystem_identity(workspace)

      _other ->
        assert {:error, {:filesystem_identity_failed, :birth_time_unavailable}} =
                 OwnershipLedger.filesystem_identity(workspace)
    end
  end

  test "rejects invalid stat and date output when building a filesystem identity", %{root: root} do
    workspace = Path.join(root, "invalid-stat-output")
    stat_wrapper = Path.join(root, "stat")
    date_wrapper = Path.join(root, "date")
    previous_path = System.get_env("PATH")
    previous_stat_path = System.get_env("SYMP_TEST_STAT_PATH")
    previous_stat_mode = System.get_env("SYMP_TEST_STAT_MODE")
    previous_date_mode = System.get_env("SYMP_TEST_DATE_MODE")

    on_exit(fn ->
      if is_nil(previous_path), do: System.delete_env("PATH"), else: System.put_env("PATH", previous_path)

      if is_nil(previous_stat_path),
        do: System.delete_env("SYMP_TEST_STAT_PATH"),
        else: System.put_env("SYMP_TEST_STAT_PATH", previous_stat_path)

      if is_nil(previous_stat_mode),
        do: System.delete_env("SYMP_TEST_STAT_MODE"),
        else: System.put_env("SYMP_TEST_STAT_MODE", previous_stat_mode)

      if is_nil(previous_date_mode),
        do: System.delete_env("SYMP_TEST_DATE_MODE"),
        else: System.put_env("SYMP_TEST_DATE_MODE", previous_date_mode)
    end)

    File.mkdir!(workspace)

    File.write!(stat_wrapper, """
    #!/bin/sh
    if { [ "${2:-}" = "%f|%d|%i|%w" ] || [ "${2:-}" = "%Xp|%d|%i|%v" ]; } && [ "${4:-}" = "$SYMP_TEST_STAT_PATH" ]; then
      case "$SYMP_TEST_STAT_MODE" in
        stat-failure) printf 'stat failed\\n'; exit 9 ;;
        regular-file)
          if [ "${2:-}" = "%Xp|%d|%i|%v" ]; then printf '81ED|39|999|100\\n'; else printf '81ed|39|999|2024-01-01 00:00:00.000000001 +0000\\n'; fi
          ;;
        malformed) printf 'invalid-output\\n' ;;
        invalid-birth)
          if [ "${2:-}" = "%Xp|%d|%i|%v" ]; then printf '41ED|39|999|0\\n'; else printf '41ed|39|999|not-a-date\\n'; fi
          ;;
        *)
          if [ "${2:-}" = "%Xp|%d|%i|%v" ]; then printf '41ED|39|999|100\\n'; else printf '41ed|39|999|2024-01-01 00:00:00.000000001 +0000\\n'; fi
          ;;
      esac
    else
      exec /usr/bin/stat "$@"
    fi
    """)

    File.write!(date_wrapper, """
    #!/bin/sh
    if [ "${SYMP_TEST_DATE_MODE:-}" = "nonnumeric" ] && [ "${1:-}" = "-d" ]; then
      printf 'not-nanoseconds\\n'
    else
      exec /usr/bin/date "$@"
    fi
    """)

    File.chmod!(stat_wrapper, 0o755)
    File.chmod!(date_wrapper, 0o755)
    System.put_env("PATH", root <> ":" <> (previous_path || ""))
    System.put_env("SYMP_TEST_STAT_PATH", workspace)

    System.put_env("SYMP_TEST_STAT_MODE", "stat-failure")

    assert {:error, {:filesystem_identity_failed, {:stat_failed, 9, "stat failed"}}} =
             OwnershipLedger.filesystem_identity(workspace)

    System.put_env("SYMP_TEST_STAT_MODE", "regular-file")

    assert {:error, {:filesystem_identity_failed, {:not_directory, :unknown}}} =
             OwnershipLedger.filesystem_identity(workspace)

    System.put_env("SYMP_TEST_STAT_MODE", "malformed")

    assert {:error, {:filesystem_identity_failed, :invalid_stat_output}} =
             OwnershipLedger.filesystem_identity(workspace)

    System.put_env("SYMP_TEST_STAT_MODE", "invalid-birth")

    case :os.type() do
      {:unix, :darwin} ->
        assert {:error, {:filesystem_identity_failed, :generation_unavailable}} =
                 OwnershipLedger.filesystem_identity(workspace)

      _other ->
        assert {:error, {:filesystem_identity_failed, :invalid_birth_time}} =
                 OwnershipLedger.filesystem_identity(workspace)

        System.put_env("SYMP_TEST_STAT_MODE", "valid")
        System.put_env("SYMP_TEST_DATE_MODE", "nonnumeric")

        assert {:error, {:filesystem_identity_failed, :invalid_birth_time}} =
                 OwnershipLedger.filesystem_identity(workspace)
    end
  end

  test "filesystem identity supports macOS inode generations and rejects missing generations", %{
    root: root,
    path: ledger_path
  } do
    path = Path.join(root, "generation-identity")

    assert {darwin_args, :generation} =
             OwnershipLedger.filesystem_identity_stat_command(path, {:unix, :darwin})

    assert darwin_args == ["-f", "%Xp|%d|%i|%v", "--", path]

    assert {linux_args, :birth_time} =
             OwnershipLedger.filesystem_identity_stat_command(path, {:unix, :linux})

    assert linux_args == ["-c", "%f|%d|%i|%w", "--", path]

    assert {:ok, %{device: 39, inode: 999, generation: 42}} =
             OwnershipLedger.parse_stat_filesystem_identity("41ED|39|999|42\n", :generation)

    assert {:error, {:filesystem_identity_failed, :generation_unavailable}} =
             OwnershipLedger.parse_stat_filesystem_identity("41ED|39|999|0\n", :generation)

    assert {:error, {:filesystem_identity_failed, :invalid_generation}} =
             OwnershipLedger.parse_stat_filesystem_identity("41ED|39|999|unknown\n", :generation)

    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: ledger_path)
    record = ownership("ownership-generation", "work-generation", root)
    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)
    generation_identity = %{device: 39, inode: 999, generation: 42}

    assert {:ok, provisioning} =
             OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :provisioning,
               generation_identity
             )

    assert provisioning.top_level_filesystem_identity == generation_identity

    assert {:ok, _owned} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "fails closed when the local host identity is corrupt", %{root: root} do
    assert {:ok, _identity} = OwnershipLedger.local_host_identity(root: root)
    path = OwnershipLedger.host_identity_path(root: root)
    File.write!(path, "")

    assert {:error, {:host_identity_failed, :invalid_record}} =
             OwnershipLedger.local_host_identity(root: root)
  end

  test "rejects a local reservation with a foreign trusted host identity", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-foreign-host", "work-foreign-host", root)
    record = Map.put(record, :trusted_host_identity, "foreign-host")

    assert {:error, _reason} = OwnershipLedger.reserve_sync(ledger, record)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "rejects symlink substitution for local host identity and ledger paths", %{root: root, path: path} do
    host_path = OwnershipLedger.host_identity_path(root: root)
    outside_host = Path.join(System.tmp_dir!(), "symphony-host-target-#{System.unique_integer([:positive])}")
    File.write!(outside_host, "trusted-host")
    File.ln_s!(outside_host, host_path)

    assert {:error, _reason} = OwnershipLedger.local_host_identity(root: root)
    File.rm!(host_path)
    File.rm!(outside_host)

    outside_ledger = Path.join(System.tmp_dir!(), "symphony-ledger-target-#{System.unique_integer([:positive])}")
    File.write!(outside_ledger, "not-a-ledger")
    File.ln_s!(outside_ledger, path)

    assert {:error, _reason} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    File.rm!(path)
    File.rm!(outside_ledger)
  end

  test "filesystem identity does not follow a symlinked directory", %{root: root} do
    real_root = Path.join(root, "real-root")
    alias_root = Path.join(root, "alias-root")
    File.mkdir_p!(real_root)
    File.ln_s!(real_root, alias_root)

    assert {:error, _reason} = OwnershipLedger.filesystem_identity(alias_root)
    assert {:error, _reason} = OwnershipLedger.root_identity(alias_root)
  end

  test "rejects negative local filesystem identities", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-negative", "work-negative", root)
    invalid_major = %{major_device: -1, minor_device: 0, inode: 1}
    invalid_inode = %{major_device: 0, minor_device: 0, inode: -1}

    assert {:error, _reason} =
             OwnershipLedger.reserve_sync(ledger, %{record | configured_root_identity: invalid_major})

    assert {:error, _reason} =
             OwnershipLedger.reserve_sync(ledger, %{record | configured_root_identity: invalid_inode})

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "requires structured root and workspace identities for local records", %{
    root: root,
    path: path
  } do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-local-opaque", "work-local-opaque", root)

    assert {:error, _reason} =
             OwnershipLedger.reserve_sync(ledger, %{record | configured_root_identity: "opaque-root"})

    assert {:error, _reason} =
             OwnershipLedger.reserve_sync(ledger, %{record | top_level_filesystem_identity: "opaque-workspace"})

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "allows opaque remote filesystem identities", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    record =
      ownership("ownership-remote-opaque", "work-remote-opaque", root)
      |> Map.merge(%{
        location: :remote,
        worker_host: "worker-a",
        trusted_host_identity: "opaque-host",
        configured_root_identity: "opaque-root",
        top_level_filesystem_identity: "opaque-workspace"
      })

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, record)

    assert {:ok, _owned} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :provisioning)

    assert {:ok, owned} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)

    assert owned.top_level_filesystem_identity == "opaque-workspace"
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "public operations reject invalid handles and identifiers", %{root: root, path: path} do
    assert {:error, {:ledger_close_failed, :invalid_record}} = OwnershipLedger.close(nil)
    assert {:error, {:filesystem_identity_failed, :invalid_path}} = OwnershipLedger.filesystem_identity(nil)

    assert {:error, {:filesystem_identity_failed, :enoent}} =
             OwnershipLedger.filesystem_identity(Path.join(root, "missing-workspace"))

    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.reserve_sync(nil, %{})
    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.get(nil, "ownership-a")
    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.list(nil)

    assert {:error, {:corrupt_ownership_record, :invalid_record}} =
             OwnershipLedger.list_for_work_item(nil, "work-a")

    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.list_for_host(nil, nil)
    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.transition_sync(nil, "ownership-a", :owned, [])
    assert {:error, {:ledger_sync_failed, :invalid_record}} = OwnershipLedger.sync(nil)
    assert {:error, {:invalid_symphony_project_id, ""}} = OwnershipLedger.open("", @identity, root: root, path: path)

    invalid_callbacks_path = Path.join(root, "invalid-callbacks.dets")

    assert {:error, :invalid_ledger_callbacks} =
             OwnershipLedger.open("project-a", @identity,
               root: root,
               path: invalid_callbacks_path,
               write_fun: :invalid
             )

    refute File.exists?(invalid_callbacks_path)

    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)

    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.get(ledger, " ")
    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.list_for_work_item(ledger, " ")
    assert {:error, {:corrupt_ownership_record, :invalid_record}} = OwnershipLedger.list_for_host(ledger, " ")
    assert :not_found = OwnershipLedger.get(ledger, "missing")
    assert :not_found = OwnershipLedger.lookup(ledger, "missing")
    assert :not_found = OwnershipLedger.current(ledger, "missing")
    assert :not_found = OwnershipLedger.transition_sync(ledger, "missing", :owned, [])

    assert {:error, :invalid_transition_attributes} =
             OwnershipLedger.transition_sync(ledger, "missing", :owned, [:invalid])

    assert :ok = OwnershipLedger.close(ledger)
  end

  test "ledger creation rejects unsafe roots and non-directory parent components", %{root: root} do
    blocker = Path.join(root, "root-component-file")
    File.write!(blocker, "operator-owned")

    ledger_root = Path.join(blocker, "workspace-ledger")
    ledger_path = Path.join(ledger_root, "project-a.dets")

    assert {:error, {:ledger_directory_failed, {:not_directory, ^blocker, :regular}}} =
             OwnershipLedger.open("project-a", @identity, root: ledger_root, path: ledger_path)

    assert {:error, {:ledger_directory_failed, :unsafe_root}} =
             OwnershipLedger.open("project-root", @identity, root: "/", path: "/project-root.dets")
  end

  test "validates every persisted ownership binding before returning records", %{root: root, path: path} do
    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    attrs = ownership("ownership-validation", "work-validation", root)
    {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, attrs)
    filesystem_identity = %{major_device: 1, minor_device: 0, inode: 2}

    {:ok, _provisioning} =
      OwnershipLedger.transition_sync(
        ledger,
        reserved.workspace_ownership_id,
        :provisioning,
        top_level_filesystem_identity: filesystem_identity
      )

    {:ok, owned} = OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)

    invalid_records = [
      Map.put(owned, :unexpected_field, true),
      %{owned | schema_version: 99},
      %{owned | project_namespace: "other-project"},
      %{owned | tracker_identity: :invalid},
      %{owned | tracker_identity: %{tracker_kind: "linear", provider_scope: []}},
      %{owned | tracker_identity: %{tracker_kind: "linear", provider_scope: %{project_slug: "other"}}},
      %{owned | issue_identifier: ""},
      %{owned | issue_identifier: nil},
      %{owned | work_item_id: ""},
      %{owned | work_item_id: nil},
      %{owned | workspace_key: ""},
      %{owned | workspace_key: "other"},
      %{owned | workspace_key: nil},
      %{owned | workspace_ownership_id: ""},
      %{owned | workspace_ownership_id: "different-id"},
      %{owned | location: :invalid},
      %{owned | trusted_host_identity: "foreign-host"},
      %{owned | configured_root: owned.configured_root <> "/"},
      %{owned | configured_root: nil},
      %{owned | configured_root_identity: nil},
      %{owned | canonical_root: "relative-root"},
      %{owned | canonical_root: nil},
      %{owned | canonical_workspace_path: Path.join(root, "outside")},
      %{owned | canonical_workspace_path: nil},
      %{owned | top_level_filesystem_identity: %{unexpected: 1}},
      %{owned | top_level_filesystem_identity: %{major_device: -1, minor_device: 0, inode: 2}},
      %{owned | state: :invalid},
      %{owned | top_level_filesystem_identity: nil},
      %{owned | state: :release_pending, release_origin: :untrusted},
      %{owned | state: :released, release_origin: :untrusted},
      %{owned | state: :owned, release_origin: :untrusted},
      %{owned | created_at: -1},
      %{owned | updated_at: "invalid"}
    ]

    Enum.each(invalid_records, fn record ->
      assert :ok = :dets.insert(ledger.table, {{:ownership, owned.workspace_ownership_id}, record})
      assert {:error, _reason} = OwnershipLedger.list(ledger)
      assert :ok = :dets.insert(ledger.table, {{:ownership, owned.workspace_ownership_id}, owned})
      assert {:ok, [^owned]} = OwnershipLedger.list(ledger)
    end)

    datetime_record = %{owned | created_at: DateTime.utc_now()}
    assert :ok = :dets.insert(ledger.table, {{:ownership, owned.workspace_ownership_id}, datetime_record})
    assert {:ok, [^datetime_record]} = OwnershipLedger.list(ledger)
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "supports public transition aliases and exact filesystem identity forms", %{root: root, path: path} do
    assert Path.expand(path) == OwnershipLedger.path_for("project-a", path: path)
    assert Path.join(root, "project-a.dets") == OwnershipLedger.path_for("project-a", root: root)

    assert Path.join(root, "identity.custom") ==
             OwnershipLedger.host_identity_path(root: root, host_identity_path: Path.join(root, "identity.custom"))

    assert Path.join(root, "host.identity") == OwnershipLedger.host_identity_path(root: root)

    non_directory = Path.join(root, "not-a-directory")
    File.write!(non_directory, "file")

    assert {:error, {:filesystem_identity_failed, {:not_directory, :regular}}} =
             OwnershipLedger.filesystem_identity(non_directory)

    assert {:error, :invalid_tracker_identity} = OwnershipLedger.open("project-a", %{}, root: root, path: path)

    identity_path = OwnershipLedger.host_identity_path(root: root)

    assert {:error, :host_identity_inside_workspace} =
             OwnershipLedger.local_host_identity(root: root, workspace_path: identity_path)

    assert {:error, {:host_identity_path_conflict, ^path}} =
             OwnershipLedger.open("project-a", @identity, root: root, path: path, host_identity_path: path)

    assert {:error, :invalid_workspace_root} =
             OwnershipLedger.open("project-a", @identity, root: root, path: path <> ".invalid-root", workspace_root: 123)

    {:ok, ledger} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    record = ownership("ownership-api-aliases", "work-api-aliases", root)
    assert {:ok, reserved} = OwnershipLedger.reserve(ledger, record)

    derived_record = ownership("ownership-derived-key", "work-derived-key", root) |> Map.delete(:workspace_key)
    assert {:ok, derived} = OwnershipLedger.put_sync(ledger, derived_record)
    assert derived.workspace_key == Ownership.workspace_key("work-derived-key")

    mismatch =
      ownership("ownership-identifier-mismatch", "work-identifier-mismatch", root)
      |> Map.put(:identifier, "another-identifier")

    assert {:error, {:issue_identifier_mismatch, "work-identifier-mismatch", "another-identifier"}} =
             OwnershipLedger.reserve_sync(ledger, mismatch)

    assert {:ok, listed_local_records} = OwnershipLedger.list_for_worker_host(ledger, nil)
    assert Enum.map(listed_local_records, & &1.workspace_ownership_id) == [reserved.workspace_ownership_id, derived.workspace_ownership_id]
    assert :ok = OwnershipLedger.sync(ledger)

    assert {:error, {:invalid_ownership_state, :owned}} =
             OwnershipLedger.reserve_sync(
               ledger,
               Map.put(ownership("ownership-invalid-state", "work-invalid-state", root), :state, :owned)
             )

    assert {:error, :invalid_transition_attributes} =
             OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :provisioning, [:invalid])

    assert {:error, :invalid_transition_attributes} =
             OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :provisioning,
               %{device: 1, inode: 2, extra: true}
             )

    assert {:ok, provisioning} =
             OwnershipLedger.transition(ledger, reserved.workspace_ownership_id, :provisioning, {1, 0, 2})

    assert {:error, {:top_level_filesystem_identity_mismatch, _, _}} =
             OwnershipLedger.transition(ledger, reserved.workspace_ownership_id, :owned, {1, 0, 3})

    assert {:ok, owned} = OwnershipLedger.transition(ledger, reserved.workspace_ownership_id, :owned)
    assert owned.top_level_filesystem_identity == provisioning.top_level_filesystem_identity

    binary_identity =
      ownership("ownership-binary-identity", "work-binary-identity", root)
      |> Map.merge(%{
        location: :remote,
        worker_host: "worker-binary-identity",
        trusted_host_identity: "opaque-host-identity",
        configured_root_identity: "opaque-root-identity"
      })

    assert {:ok, binary_reserved} = OwnershipLedger.reserve_sync(ledger, binary_identity)

    assert {:ok, binary_provisioning} =
             OwnershipLedger.transition_sync(ledger, binary_reserved.workspace_ownership_id, :provisioning, "opaque-filesystem-id")

    assert binary_provisioning.top_level_filesystem_identity == "opaque-filesystem-id"
    assert :ok = OwnershipLedger.close(ledger)
  end

  test "fails closed for empty or ambiguous metadata tables", %{root: root} do
    empty_path = Path.join(root, "empty-metadata.dets")
    {:ok, empty_table} = :dets.open_file(empty_path, file: String.to_charlist(empty_path), type: :set)
    assert :ok = :dets.close(empty_table)

    assert {:error, {:corrupt_ownership_record, :metadata, :missing_metadata}} =
             OwnershipLedger.open("project-a", @identity, root: root, path: empty_path)

    duplicate_path = Path.join(root, "duplicate-metadata.dets")
    {:ok, duplicate_table} = :dets.open_file(duplicate_path, file: String.to_charlist(duplicate_path), type: :set)
    metadata = %{schema_version: 1, project_namespace: "project-a", tracker_identity: @identity}
    assert :ok = :dets.insert(duplicate_table, [{{:meta, "project-a"}, metadata}, {{:meta, "other-project"}, metadata}])
    assert :ok = :dets.close(duplicate_table)

    assert {:error, {:corrupt_ownership_record, :metadata, :invalid_record}} =
             OwnershipLedger.open("project-a", @identity, root: root, path: duplicate_path)
  end

  test "rejects persisted metadata with invalid shape, schema, namespace, or tracker scope", %{root: root} do
    metadata = %{schema_version: 1, project_namespace: "project-a", tracker_identity: @identity}

    invalid_metadata = [
      {:not_a_map, {:corrupt_ownership_record, :metadata, :invalid_record}},
      {%{metadata | schema_version: 2}, {:ledger_schema_version_unsupported, 2}},
      {%{metadata | project_namespace: "other-project"}, {:ledger_project_namespace_mismatch, "other-project", "project-a"}},
      {%{metadata | tracker_identity: %{tracker_kind: "unknown", provider_scope: %{}}}, :invalid_tracker_identity},
      {Map.put(metadata, :unexpected, true), {:corrupt_ownership_record, :metadata, :invalid_record}}
    ]

    for {invalid, expected_reason} <- invalid_metadata do
      path = Path.join(root, "invalid-metadata-#{System.unique_integer([:positive])}.dets")
      {:ok, table} = :dets.open_file(path, file: String.to_charlist(path), type: :set)
      assert :ok = :dets.insert(table, {{:meta, "project-a"}, invalid})
      assert :ok = :dets.close(table)

      assert {:error, ^expected_reason} =
               OwnershipLedger.open("project-a", @identity, root: root, path: path)
    end
  end

  test "propagates write callback and existing ledger sync failures", %{root: root, path: path} do
    {:ok, initial} = OwnershipLedger.open("project-a", @identity, root: root, path: path)
    assert :ok = OwnershipLedger.close(initial)

    {:ok, unexpected_write} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: fn _table, _records -> :unexpected end
      )

    assert {:error, {:ledger_write_failed, :unexpected}} =
             OwnershipLedger.reserve_sync(unexpected_write, ownership("ownership-unexpected-write", "work-unexpected-write", root))

    assert :ok = OwnershipLedger.close(unexpected_write)

    {:ok, raised_write} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: fn _table, _records -> raise ArgumentError, "injected write failure" end
      )

    assert {:error, {:ledger_write_failed, %ArgumentError{}}} =
             OwnershipLedger.reserve_sync(raised_write, ownership("ownership-raised-write", "work-raised-write", root))

    assert :ok = OwnershipLedger.close(raised_write)

    {:ok, unexpected_sync} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        sync_fun: fn _table -> :unexpected end
      )

    assert {:error, {:ledger_sync_failed, :unexpected}} = OwnershipLedger.sync(unexpected_sync)
    assert :ok = OwnershipLedger.close(unexpected_sync)

    {:ok, thrown_write} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        write_fun: fn _table, _records -> throw(:write_interrupted) end
      )

    assert {:error, {:ledger_write_failed, {:throw, :write_interrupted}}} =
             OwnershipLedger.reserve_sync(
               thrown_write,
               ownership("ownership-thrown-write", "work-thrown-write", root)
             )

    assert :ok = OwnershipLedger.close(thrown_write)

    {:ok, thrown_sync} =
      OwnershipLedger.open("project-a", @identity,
        root: root,
        path: path,
        sync_fun: fn _table -> exit(:sync_interrupted) end
      )

    assert {:error, {:ledger_sync_failed, {:exit, :sync_interrupted}}} =
             OwnershipLedger.reserve_sync(
               thrown_sync,
               ownership("ownership-thrown-sync", "work-thrown-sync", root)
             )

    assert :ok = OwnershipLedger.close(thrown_sync)
  end

  test "rejects a directory used as the ledger file path", %{root: root} do
    directory_path = Path.join(root, "ledger-directory")
    File.mkdir_p!(directory_path)

    assert {:error, {:ledger_path_invalid, {:not_regular, :directory}}} =
             OwnershipLedger.open("project-a", @identity,
               root: root,
               path: directory_path
             )
  end

  defp ownership(ownership_id, work_item_id, root) do
    workspace_key = Ownership.workspace_key(work_item_id)
    canonical_root = Path.expand(Path.join(root, "workspaces"))
    File.mkdir_p!(canonical_root)

    %{
      workspace_ownership_id: ownership_id,
      issue_identifier: work_item_id,
      work_item_id: work_item_id,
      workspace_key: workspace_key,
      location: :local,
      worker_host: nil,
      configured_root: canonical_root,
      configured_root_identity: local_identity(root),
      canonical_root: canonical_root,
      canonical_workspace_path: Path.join(canonical_root, workspace_key),
      top_level_filesystem_identity: nil,
      created_at: 1,
      updated_at: 1
    }
  end

  defp local_identity(root) do
    canonical_root = Path.expand(Path.join(root, "workspaces"))
    File.mkdir_p!(canonical_root)
    {:ok, identity} = OwnershipLedger.filesystem_identity(canonical_root)
    identity
  end
end
