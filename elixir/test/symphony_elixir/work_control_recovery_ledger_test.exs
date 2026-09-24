defmodule SymphonyElixir.WorkControlRecoveryLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.WorkControl.{ProviderObservation, RecoveryLedger, SuspensionContext}

  @identity %{
    tracker_kind: "plane",
    provider_scope: %{
      workspace_slug: "workspace-a",
      workspace_id: "workspace-a-id",
      project_id: "project-a"
    }
  }

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, path: Path.join(root, "recovery.dets")}
  end

  test "opens a private DETS table and round-trips one current checkpoint", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert RecoveryLedger.schema_version() == 1

    checkpoint = checkpoint("work-a")
    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    assert {:ok, ^checkpoint} = RecoveryLedger.current(ledger, "work-a")
    assert {:ok, [^checkpoint]} = RecoveryLedger.list(ledger)
    assert :ok = RecoveryLedger.close(ledger)

    {:ok, reopened} = RecoveryLedger.open("project-a", @identity, path: path)
    assert {:ok, ^checkpoint} = RecoveryLedger.current(reopened, "work-a")
    assert :ok = RecoveryLedger.close(reopened)
  end

  test "uses the configured recovery root", %{root: root} do
    previous_root = Application.get_env(:symphony_elixir, :recovery_ledger_root)
    Application.put_env(:symphony_elixir, :recovery_ledger_root, root)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:symphony_elixir, :recovery_ledger_root)
      else
        Application.put_env(:symphony_elixir, :recovery_ledger_root, previous_root)
      end
    end)

    assert RecoveryLedger.path_for("project-a") == Path.join(root, "project-a.dets")
  end

  test "binds the table to the project namespace and exact tracker identity", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(ledger)

    assert {:error, {:ledger_project_namespace_mismatch, "project-a", "project-b"}} =
             RecoveryLedger.open("project-b", @identity, path: path)

    assert {:error, {:ledger_tracker_identity_mismatch, @identity, _}} =
             RecoveryLedger.open(
               "project-a",
               %{
                 tracker_kind: "plane",
                 provider_scope: %{
                   workspace_slug: "other-workspace",
                   workspace_id: "other-workspace-id",
                   project_id: "other-project"
                 }
               },
               path: path
             )

    assert {:error, :invalid_tracker_identity} = RecoveryLedger.open("project-a", %{}, path: path)

    assert {:error, {:invalid_symphony_project_id, "../project"}} =
             RecoveryLedger.open("../project", @identity, path: path)
  end

  test "accepts only supported tracker scope shapes", %{path: path} do
    assert {:ok, memory} =
             RecoveryLedger.open("project-a", %{tracker_kind: "memory", provider_scope: %{}}, path: path <> "-memory")

    assert :ok = RecoveryLedger.close(memory)

    assert {:ok, linear} =
             RecoveryLedger.open("project-a", %{tracker_kind: "linear", provider_scope: %{}}, path: path <> "-linear")

    assert :ok = RecoveryLedger.close(linear)

    assert {:ok, linear_scoped} =
             RecoveryLedger.open(
               "project-a",
               %{tracker_kind: "linear", provider_scope: %{project_slug: "project-a"}},
               path: path <> "-linear-scoped"
             )

    assert :ok = RecoveryLedger.close(linear_scoped)

    invalid_identities = [
      %{tracker_kind: "future-tracker", provider_scope: %{}},
      %{tracker_kind: "linear", provider_scope: :invalid},
      %{tracker_kind: "memory", provider_scope: %{project_slug: "project-a"}},
      %{tracker_kind: "linear", provider_scope: %{repo: "octo/repo"}},
      %{tracker_kind: "plane", provider_scope: %{}},
      %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}},
      %{tracker_kind: "plane", provider_scope: %{workspace_slug: "workspace-a", workspace_id: "workspace-a-id"}}
    ]

    for {identity, index} <- Enum.with_index(invalid_identities) do
      assert {:error, :invalid_tracker_identity} =
               RecoveryLedger.open("project-a", identity, path: path <> "-invalid-#{index}")
    end
  end

  test "writes a checkpoint before syncing it", %{path: path} do
    {:ok, initialized} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(initialized)

    parent = self()

    {:ok, ledger} =
      RecoveryLedger.open("project-a", @identity,
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

    checkpoint = checkpoint("work-a")
    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    assert_receive {:write, [{{:current, "work-a"}, ^checkpoint}]}
    assert_receive :sync
    assert :ok = RecoveryLedger.close(ledger)
  end

  test "returns injected write and sync failures", %{path: path} do
    {:ok, initialized} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(initialized)

    {:ok, write_failed} =
      RecoveryLedger.open("project-a", @identity,
        path: path,
        write_fun: fn _table, _records -> {:error, :disk_full} end
      )

    assert {:error, {:ledger_write_failed, :disk_full}} =
             RecoveryLedger.put_sync(write_failed, checkpoint("write"))

    assert :ok = RecoveryLedger.close(write_failed)

    {:ok, sync_failed} =
      RecoveryLedger.open("project-a", @identity,
        path: path,
        sync_fun: fn _table -> {:error, :sync_failed} end
      )

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             RecoveryLedger.put_sync(sync_failed, checkpoint("sync"))

    assert :ok = RecoveryLedger.close(sync_failed)
  end

  test "wraps unexpected callback results, exceptions, and throws", %{path: path} do
    {:ok, initialized} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(initialized)

    for {write_fun, expected} <- [
          {fn _table, _records -> :unexpected end, :unexpected},
          {fn _table, _records -> raise "write failed" end, :exception},
          {fn _table, _records -> throw(:write_thrown) end, :throw}
        ] do
      {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path, write_fun: write_fun)
      assert_write_failure(ledger, expected)
      assert :ok = RecoveryLedger.close(ledger)
    end

    for {sync_fun, expected} <- [
          {fn _table -> :unexpected end, :unexpected},
          {fn _table -> raise "sync failed" end, :exception},
          {fn _table -> throw(:sync_thrown) end, :throw}
        ] do
      {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path, sync_fun: sync_fun)
      assert_sync_failure(ledger, expected)
      assert :ok = RecoveryLedger.close(ledger)
    end
  end

  test "can retry initialization after a failed metadata write or sync", %{path: path} do
    assert {:error, {:ledger_write_failed, :disk_full}} =
             RecoveryLedger.open("project-a", @identity,
               path: path,
               write_fun: fn _table, _records -> {:error, :disk_full} end
             )

    refute File.exists?(path)
    assert {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(ledger)

    second_path = path <> "-sync"

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             RecoveryLedger.open("project-a", @identity,
               path: second_path,
               sync_fun: fn _table -> {:error, :sync_failed} end
             )

    assert File.exists?(second_path)
    assert {:ok, resynced} = RecoveryLedger.open("project-a", @identity, path: second_path)
    assert :ok = RecoveryLedger.close(resynced)
  end

  test "rejects invalid API values and rereads only open ledger handles", %{path: path} do
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.current(nil, "work-a")
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.list(nil)
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.put_sync(nil, %{})
    assert {:error, {:ledger_sync_failed, :invalid_record}} = RecoveryLedger.sync(nil)
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.current(%RecoveryLedger{}, :invalid)

    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.current(ledger, " ")
    assert {:error, {:corrupt_recovery_record, :invalid_record}} = RecoveryLedger.current(ledger, :invalid)
    assert :ok = RecoveryLedger.sync(ledger)
    assert :ok = RecoveryLedger.close(ledger)

    assert {:error, {:ledger_read_failed, _reason}} = RecoveryLedger.list(ledger)
  end

  test "retains only the bounded active and terminal suspension contexts", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)

    active = suspension_context("work-a", :open)
    terminal = suspension_context("work-a", :resolved)

    checkpoint =
      checkpoint("work-a")
      |> Map.put(:active_suspension_context, active)
      |> Map.put(:last_terminal_suspension_context, terminal)

    assert :ok = RecoveryLedger.put_sync(ledger, checkpoint)
    assert {:ok, ^checkpoint} = RecoveryLedger.current(ledger, "work-a")
    assert {:ok, [^checkpoint]} = RecoveryLedger.list(ledger)
    assert :ok = RecoveryLedger.close(ledger)
  end

  test "validates every recovery field before storing suspension evidence", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    context = suspension_context("work-a", :open)

    valid_context = %{
      context
      | required_evidence: [
          :fresh_reconciliation,
          %{class: :mechanical_guard, name: :dispatch_guard}
        ],
        resume_target: nil
    }

    assert :ok =
             RecoveryLedger.put_sync(
               ledger,
               checkpoint("work-a") |> Map.put(:active_suspension_context, valid_context)
             )

    assert :ok = RecoveryLedger.put_sync(ledger, Map.put(checkpoint("integer-time"), :updated_at, 0))

    invalid_contexts = [
      %{},
      :invalid,
      %{context | provider_observation: :invalid},
      %{context | reason: nil},
      %{context | recovery_policy: nil},
      %{context | required_evidence: :invalid},
      %{context | lineage_generation: 7},
      %{context | resume_target: "ready"},
      %{context | last_validated_lifecycle_state: "ready"},
      %{context | provider_observation: %{context.provider_observation | provider_state_name: :ready}},
      %{context | provider_observation: %{context.provider_observation | observed_at: :invalid}},
      %{
        context
        | provider_observation: %{
            context.provider_observation
            | provider_updated_at: %{context.provider_observation.provider_updated_at | month: :invalid}
          }
      }
    ]

    for {invalid_context, index} <- Enum.with_index(invalid_contexts) do
      result =
        RecoveryLedger.put_sync(
          ledger,
          checkpoint("work-a") |> Map.put(:active_suspension_context, invalid_context)
        )

      assert match?({:error, _reason}, result),
             "invalid context #{index} was accepted: #{inspect(result)}"
    end

    assert {:error, _reason} =
             RecoveryLedger.put_sync(ledger, checkpoint("work-a") |> Map.put(:updated_at, 0.5))

    assert :ok = RecoveryLedger.close(ledger)
  end

  test "rejects ledger initialization paths and callback configurations that are not writable", %{path: path} do
    assert {:error, {:invalid_symphony_project_id, ""}} = RecoveryLedger.open("", @identity, root: path <> "-empty")
    assert {:error, :invalid_ledger_callbacks} = RecoveryLedger.open("project-a", @identity, path: path, write_fun: :invalid)

    parent_file = path <> "-parent-file"
    File.write!(parent_file, "not a directory")

    assert {:error, {:ledger_directory_failed, _reason}} =
             RecoveryLedger.open("project-a", @identity, path: Path.join(parent_file, "recovery.dets"))

    corrupt_path = path <> "-corrupt-file"
    File.write!(corrupt_path, "not a DETS table")
    assert {:error, {:ledger_open_failed, _reason}} = RecoveryLedger.open("project-a", @identity, path: corrupt_path)

    assert {:ok, open} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(open)
  end

  test "normalizes every public recovery-ledger sync failure", %{path: path} do
    {:ok, initialized} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(initialized)

    failures = [
      {fn _table -> {:error, :sync_failed} end, {:ledger_sync_failed, :sync_failed}},
      {fn _table -> :unexpected end, {:ledger_sync_failed, :unexpected}},
      {fn _table -> raise "sync failed" end, {:ledger_sync_failed, %RuntimeError{message: "sync failed"}}},
      {fn _table -> throw(:sync_thrown) end, {:ledger_sync_failed, {:throw, :sync_thrown}}}
    ]

    for {sync_fun, expected} <- failures do
      {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path, sync_fun: sync_fun)
      assert {:error, ^expected} = RecoveryLedger.sync(ledger)
      assert :ok = RecoveryLedger.close(ledger)
    end
  end

  test "rejects incomplete, unsupported, and forbidden checkpoint records", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    valid = checkpoint("work-a")

    invalid = [
      Map.delete(valid, :schema_version),
      Map.put(valid, :schema_version, 999),
      Map.put(valid, :project_namespace, "other-project"),
      Map.put(valid, :work_item_id, ""),
      Map.put(valid, :last_validated_lifecycle_state, :provider_open),
      Map.put(valid, :durable_guard_evidence, [%{class: :semantic_attestation, name: :attested}]),
      Map.put(valid, :durable_guard_evidence, :malformed),
      Map.put(valid, :active_suspension_context, suspension_context("other-work", :open)),
      Map.put(valid, :active_suspension_context, suspension_context("work-a", :resolved)),
      Map.put(
        valid,
        :active_suspension_context,
        %{suspension_context("work-a", :open) | last_validated_lifecycle_state: :in_progress}
      ),
      Map.put(valid, :last_terminal_suspension_context, suspension_context("work-a", :open)),
      Map.put(valid, :active_suspension_context, %{suspension_context("work-a", :open) | reason: "drift"}),
      Map.put(valid, :active_suspension_context, %{suspension_context("work-a", :open) | recovery_policy: %{name: :fresh}}),
      Map.put(valid, :active_suspension_context, %{suspension_context("work-a", :open) | required_evidence: [%{class: :mechanical_guard}]}),
      Map.put(valid, :active_suspension_context, %{suspension_context("work-a", :open) | required_evidence: [%{class: :mechanical_guard, name: :dispatch_guard, extra: true}]}),
      Map.put(
        valid,
        :durable_guard_evidence,
        [%{class: :mechanical_guard, name: :dispatch_guard, pid: self()}]
      ),
      Map.put(
        valid,
        :durable_guard_evidence,
        [Map.put(%{class: :mechanical_guard, name: :dispatch_guard}, self(), true)]
      ),
      Map.put(
        valid,
        :durable_guard_evidence,
        [Map.put(%{class: :mechanical_guard, name: :dispatch_guard}, fn -> :ok end, true)]
      ),
      Map.put(
        valid,
        :active_suspension_context,
        %{
          suspension_context("work-a", :open)
          | provider_observation: %{
              suspension_context("work-a", :open).provider_observation
              | snapshot_identity: {:nested, [%{"token" => "secret"}]}
            }
        }
      ),
      Map.put(valid, :runtime_attempt, %{runtime_attempt_id: "must-not-persist"}),
      Map.put(valid, :updated_at, -1)
    ]

    for record <- invalid do
      assert {:error, _reason} = RecoveryLedger.put_sync(ledger, record)
    end

    assert :not_found = RecoveryLedger.current(ledger, "work-a")
    assert :ok = RecoveryLedger.close(ledger)
  end

  test "fails closed when an existing table contains corrupt records", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(ledger)

    table = path
    {:ok, _} = :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.insert(table, {{:current, "bad"}, :corrupt})
    assert :ok = :dets.sync(table)
    assert :ok = :dets.close(table)

    assert {:error, {:corrupt_recovery_record, {:current, "bad"}, :invalid_record}} =
             RecoveryLedger.open("project-a", @identity, path: path)
  end

  test "rejects malformed metadata instead of treating it as an empty table", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)
    assert :ok = RecoveryLedger.close(ledger)

    table = path
    {:ok, _} = :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.delete(table, {:meta, "project-a"})
    assert :ok = :dets.insert(table, {{:unknown, "record"}, %{schema_version: 1}})
    assert :ok = :dets.sync(table)
    assert :ok = :dets.close(table)

    assert {:error, {:corrupt_recovery_record, :metadata, :missing_metadata}} =
             RecoveryLedger.open("project-a", @identity, path: path)
  end

  test "rejects malformed metadata variants and orphaned records", %{path: path} do
    valid_metadata = %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: "project-a",
      tracker_identity: @identity
    }

    cases = [
      {
        "metadata-version",
        [{{:meta, "project-a"}, %{valid_metadata | schema_version: 999}}],
        {:ledger_schema_version_unsupported, 999}
      },
      {
        "metadata-identity",
        [{{:meta, "project-a"}, %{valid_metadata | tracker_identity: :invalid}}],
        :invalid_tracker_identity
      },
      {
        "metadata-namespace",
        [{{:meta, "project-a"}, %{valid_metadata | project_namespace: "other-project"}}],
        {:ledger_project_namespace_mismatch, "other-project", "project-a"}
      },
      {
        "metadata-value",
        [{{:meta, "project-a"}, :invalid}],
        {:corrupt_recovery_record, :metadata, :invalid_record}
      },
      {
        "metadata-keys",
        [{{:meta, "project-a"}, Map.put(valid_metadata, :runtime_attempt, :forbidden)}],
        {:corrupt_recovery_record, :metadata, :invalid_record}
      },
      {
        "metadata-duplicate",
        [{{:meta, "project-a"}, valid_metadata}, {{:meta, "other-project"}, valid_metadata}],
        {:corrupt_recovery_record, :metadata, :invalid_record}
      },
      {
        "orphan-record",
        [{{:meta, "project-a"}, valid_metadata}, {{:orphan, "record"}, :invalid}],
        {:corrupt_recovery_record, {:orphan, "record"}, :invalid_record}
      },
      {
        "checkpoint-version",
        [{{:meta, "project-a"}, valid_metadata}, {{:current, "work-a"}, %{checkpoint("work-a") | schema_version: 999}}],
        {:ledger_schema_version_unsupported, 999}
      },
      {
        "checkpoint-namespace",
        [{{:meta, "project-a"}, valid_metadata}, {{:current, "work-a"}, %{checkpoint("work-a") | project_namespace: "other-project"}}],
        {:ledger_project_namespace_mismatch, "other-project", "project-a"}
      }
    ]

    for {suffix, records, expected} <- cases do
      case_path = path <> "-" <> suffix
      seed_dets_table!(case_path, records)
      assert {:error, ^expected} = RecoveryLedger.open("project-a", @identity, path: case_path)
    end
  end

  test "rejects an existing empty DETS table instead of initializing over missing metadata", %{path: path} do
    {:ok, _} = :dets.open_file(path, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.close(path)

    assert {:error, {:corrupt_recovery_record, :metadata, :missing_metadata}} =
             RecoveryLedger.open("project-a", @identity, path: path)
  end

  test "does not expose runtime or authority persistence helpers", %{path: path} do
    {:ok, ledger} = RecoveryLedger.open("project-a", @identity, path: path)

    refute function_exported?(RecoveryLedger, :persist_runtime_attempt, 2)
    refute function_exported?(RecoveryLedger, :persist_authority, 2)
    refute function_exported?(RecoveryLedger, :delete_all, 1)

    assert :ok = RecoveryLedger.close(ledger)
  end

  test "rejects invalid close terms" do
    assert {:error, :invalid_recovery_ledger} = RecoveryLedger.close(nil)
    assert {:error, :invalid_recovery_ledger} = RecoveryLedger.close(:not_a_ledger)
  end

  defp seed_dets_table!(path, records) do
    {:ok, _table} = :dets.open_file(path, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.insert(path, records)
    assert :ok = :dets.sync(path)
    assert :ok = :dets.close(path)
  end

  defp checkpoint(work_item_id) do
    %{
      schema_version: RecoveryLedger.schema_version(),
      project_namespace: "project-a",
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :ready,
      durable_guard_evidence: [%{class: :mechanical_guard, name: :dispatch_guard}],
      active_suspension_context: nil,
      last_terminal_suspension_context: nil,
      updated_at: ~U[2026-09-23 00:00:00Z]
    }
  end

  defp suspension_context(work_item_id, status) do
    %SuspensionContext{
      work_item_id: work_item_id,
      last_validated_lifecycle_state: :ready,
      provider_observation: %ProviderObservation{
        provider: :plane,
        work_item_id: work_item_id,
        workspace_id: "workspace-a",
        project_id: "project-a",
        provider_state_id: "state-ready",
        provider_state_group: "active",
        provider_state_name: "Ready",
        provider_updated_at: ~U[2026-09-23 00:00:00Z],
        observed_at: ~U[2026-09-23 00:00:00Z],
        snapshot_identity: %{snapshot: "one"}
      },
      reason: :fresh_reconciliation,
      lineage_generation: "lineage-a",
      created_at: ~U[2026-09-23 00:00:00Z],
      recovery_policy: :fresh_reconciliation,
      required_evidence: [],
      resume_target: :ready,
      status: status
    }
  end

  defp assert_write_failure(ledger, :unexpected) do
    assert {:error, {:ledger_write_failed, :unexpected}} = RecoveryLedger.put_sync(ledger, checkpoint("write-failure"))
  end

  defp assert_write_failure(ledger, :exception) do
    assert {:error, {:ledger_write_failed, %RuntimeError{}}} = RecoveryLedger.put_sync(ledger, checkpoint("write-failure"))
  end

  defp assert_write_failure(ledger, :throw) do
    assert {:error, {:ledger_write_failed, {:throw, :write_thrown}}} = RecoveryLedger.put_sync(ledger, checkpoint("write-failure"))
  end

  defp assert_sync_failure(ledger, :unexpected) do
    assert {:error, {:ledger_sync_failed, :unexpected}} = RecoveryLedger.put_sync(ledger, checkpoint("sync-failure"))
  end

  defp assert_sync_failure(ledger, :exception) do
    assert {:error, {:ledger_sync_failed, %RuntimeError{}}} = RecoveryLedger.put_sync(ledger, checkpoint("sync-failure"))
  end

  defp assert_sync_failure(ledger, :throw) do
    assert {:error, {:ledger_sync_failed, {:throw, :sync_thrown}}} = RecoveryLedger.put_sync(ledger, checkpoint("sync-failure"))
  end
end
