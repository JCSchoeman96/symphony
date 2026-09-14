defmodule SymphonyElixir.AttemptLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.AgentRuntime.AttemptLedger

  @identity %{tracker_kind: "memory", provider_scope: %{project_slug: "test-project"}}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-attempt-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, path: Path.join(root, "attempts.dets")}
  end

  test "persists safety snapshots across a real DETS close and reopen", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)

    snapshot = snapshot("project-a", "issue-a", "lineage-a", %{ordinary_failures: 2, ordinary_retries: 2})
    assert :ok = AttemptLedger.put(ledger, snapshot)
    assert {:ok, ^snapshot} = AttemptLedger.current(ledger, "issue-a")
    assert {:ok, [^snapshot]} = AttemptLedger.open_lineages(ledger)
    assert :ok = AttemptLedger.close(ledger)

    {:ok, reopened} = AttemptLedger.open("project-a", @identity, path: path)
    assert {:ok, ^snapshot} = AttemptLedger.current(reopened, "issue-a")
    assert :ok = AttemptLedger.close(reopened)
  end

  test "isolates namespaces and rejects provider identity drift", %{path: path, root: root} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)
    assert :ok = AttemptLedger.close(ledger)

    assert {:error, {:ledger_project_namespace_mismatch, "project-a", "project-b"}} =
             AttemptLedger.open("project-b", @identity, path: path)

    assert {:error, {:ledger_tracker_identity_mismatch, @identity, _other_identity}} =
             AttemptLedger.open(
               "project-a",
               %{tracker_kind: "memory", provider_scope: %{project_slug: "other-project"}},
               path: path
             )

    path_a = AttemptLedger.path_for("project-a", root: root)
    path_b = AttemptLedger.path_for("project-b", root: root)
    refute path_a == path_b
    refute String.contains?(path_a, File.cwd!())

    default_path = AttemptLedger.path_for("project-a")
    refute String.starts_with?(default_path, System.tmp_dir!())
  end

  test "keeps independent ledger paths open concurrently", %{root: root} do
    path_a = Path.join(root, "project-a.dets")
    path_b = Path.join(root, "project-b.dets")

    {:ok, ledger_a} = AttemptLedger.open("project-a", @identity, path: path_a)
    {:ok, ledger_b} = AttemptLedger.open("project-b", @identity, path: path_b)

    assert ledger_a.table != ledger_b.table
    assert :ok = AttemptLedger.close(ledger_a)
    assert :ok = AttemptLedger.close(ledger_b)
  end

  test "rejects newer schema records and corrupt snapshots", %{path: path} do
    seed(path, [{{:meta, "project-a"}, metadata("project-a", @identity, 999)}])

    assert {:error, {:ledger_schema_version_unsupported, 999}} =
             AttemptLedger.open("project-a", @identity, path: path)

    seed(path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:current, "issue-a"}, :corrupt}
    ])

    assert {:error, {:corrupt_attempt_record, {:current, "issue-a"}, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: path)
  end

  test "a failed write or sync is returned to the caller", %{path: path} do
    seed(path, [{{:meta, "project-a"}, metadata("project-a", @identity)}])

    {:ok, write_failed} =
      AttemptLedger.open("project-a", @identity,
        path: path,
        write_fun: fn _table, _records -> {:error, :disk_full} end
      )

    assert {:error, {:ledger_write_failed, :disk_full}} =
             AttemptLedger.put(write_failed, snapshot("project-a", "issue-a", "lineage-a", %{}))

    assert :ok = AttemptLedger.close(write_failed)

    seed(path, [{{:meta, "project-a"}, metadata("project-a", @identity)}])

    {:ok, sync_failed} =
      AttemptLedger.open("project-a", @identity,
        path: path,
        sync_fun: fn _table -> {:error, :sync_failed} end
      )

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             AttemptLedger.put(sync_failed, snapshot("project-a", "issue-a", "lineage-a", %{}))

    assert :ok = AttemptLedger.close(sync_failed)
  end

  test "rearm preserves exhausted history and creates a new lineage", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)
    exhausted = snapshot("project-a", "issue-a", "lineage-a", %{ordinary_failures: 4, ordinary_retries: 3})
    exhausted = %{exhausted | status: :exhausted, stop_reason: :ordinary_retry_limit}
    assert :ok = AttemptLedger.put(ledger, exhausted)

    assert {:ok, rearmed} =
             AttemptLedger.rearm(ledger, "issue-a", "verified provider state", "operator@example.com", 1_700_000_000_000)

    assert rearmed.status == :open
    assert rearmed.lineage_id != exhausted.lineage_id
    assert rearmed.safety_counters == %{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0}
    assert rearmed.rearm_reason == "verified provider state"
    assert rearmed.rearmed_by == "operator@example.com"
    assert rearmed.rearmed_at == 1_700_000_000_000

    assert {:ok, current} = AttemptLedger.current(ledger, "issue-a")
    assert current.lineage_id == rearmed.lineage_id

    assert {:ok, [history]} = AttemptLedger.history(ledger)
    assert history.status == :closed
    assert history.lineage_id == exhausted.lineage_id
    assert history.safety_counters == exhausted.safety_counters
    assert history.rearm_reason == "verified provider state"
    assert :ok = AttemptLedger.close(ledger)
  end

  test "rearm requires an exhausted current lineage", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)
    assert :ok = AttemptLedger.put(ledger, snapshot("project-a", "issue-a", "lineage-a", %{}))

    assert {:error, :lineage_not_exhausted} =
             AttemptLedger.rearm(ledger, "issue-a", "not allowed", "operator", 1_700_000_000_000)

    assert :ok = AttemptLedger.close(ledger)
  end

  test "does not reset an exhausted lineage through a normal safety write", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)

    exhausted = snapshot("project-a", "issue-a", "lineage-a", %{ordinary_failures: 4, ordinary_retries: 3})
    exhausted = %{exhausted | status: :exhausted, stop_reason: :ordinary_retry_limit}
    assert :ok = AttemptLedger.put(ledger, exhausted)

    assert {:error, :lineage_exhausted} =
             AttemptLedger.persist_safety(ledger, "issue-a", %{
               ordinary_failures: 1,
               ordinary_retries: 1,
               review_cycles: 0
             })

    assert {:error, :lineage_exhausted} = AttemptLedger.put(ledger, %{exhausted | status: :open})

    assert {:ok, ^exhausted} = AttemptLedger.current(ledger, "issue-a")
    assert :ok = AttemptLedger.close(ledger)
  end

  test "exposes the schema version and fails closed for malformed public records", %{path: path} do
    assert AttemptLedger.schema_version() == 1

    assert AttemptLedger.path_for("project-a", path: "relative/ledger.dets") ==
             Path.expand("relative/ledger.dets")

    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)
    valid = snapshot("project-a", "issue-a", "lineage-a", %{})

    invalid_records = [
      Map.put(valid, :unexpected, true),
      Map.put(valid, :schema_version, 999),
      Map.put(valid, :project_namespace, "other-project"),
      Map.put(valid, :issue_id, ""),
      Map.put(valid, :lineage_id, ""),
      Map.put(valid, :lineage_id, nil),
      Map.put(valid, :safety_counters, %{}),
      Map.put(valid, :safety_counters, nil),
      Map.put(valid, :status, :invalid),
      Map.put(valid, :stop_reason, "not-an-atom"),
      Map.put(valid, :route_fingerprint, 123),
      Map.put(valid, :updated_at, -1)
    ]

    for record <- invalid_records do
      assert {:error, _reason} = AttemptLedger.put(ledger, record)
    end

    assert {:error, {:corrupt_attempt_record, :current, :invalid_record}} =
             AttemptLedger.put(ledger, :invalid)

    :ok = :dets.insert(ledger.table, {{:current, "issue-a"}, :corrupt})
    assert {:error, :invalid_record} = AttemptLedger.current(ledger, "issue-a")

    assert :ok = AttemptLedger.close(ledger)
    assert {:error, {:ledger_read_failed, _}} = AttemptLedger.open_lineages(ledger)
    assert {:error, {:ledger_read_failed, _}} = AttemptLedger.current(ledger, "issue-a")
    assert {:error, {:ledger_read_failed, _}} = AttemptLedger.close_lineage(ledger, "issue-a")

    assert {:error, {:ledger_read_failed, _}} =
             AttemptLedger.persist_safety(ledger, "issue-a", %{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0})

    assert {:error, {:ledger_read_failed, _}} =
             AttemptLedger.rearm(ledger, "issue-a", "reason", "operator", 1_700_000_000_000)
  end

  test "closes missing and active lineages, and keeps closed writes separate", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)

    assert :ok = AttemptLedger.close_lineage(ledger, "missing")

    active = snapshot("project-a", "issue-a", "lineage-a", %{})
    assert :ok = AttemptLedger.put(ledger, active)
    assert :ok = AttemptLedger.close_lineage(ledger, "issue-a", reason: :terminal, updated_at: 1_700_000_000_001)
    assert {:ok, %{status: :closed, closed_reason: :terminal}} = AttemptLedger.current(ledger, "issue-a")
    assert :ok = AttemptLedger.close_lineage(ledger, "issue-a")

    assert {:ok, reopened_lineage} =
             AttemptLedger.persist_safety(ledger, "issue-a", %{
               ordinary_failures: 1,
               ordinary_retries: 0,
               review_cycles: 0
             })

    assert reopened_lineage.lineage_id != active.lineage_id
    assert :ok = AttemptLedger.close(ledger)
  end

  test "rejects invalid project and tracker identities before opening a table", %{root: root} do
    assert {:error, {:invalid_symphony_project_id, "../unsafe"}} =
             AttemptLedger.open("../unsafe", @identity, path: Path.join(root, "unsafe.dets"))

    invalid_identities = [
      %{},
      %{tracker_kind: "memory"},
      %{tracker_kind: "", provider_scope: %{}},
      %{tracker_kind: "memory", provider_scope: nil},
      %{tracker_kind: "memory", provider_scope: %{secret: "value"}},
      %{tracker_kind: "memory", provider_scope: %{project_slug: 123}}
    ]

    for {identity, index} <- Enum.with_index(invalid_identities) do
      assert {:error, :invalid_tracker_identity} =
               AttemptLedger.open("project-#{index}", identity, path: Path.join(root, "invalid-#{index}.dets"))
    end
  end

  test "rejects malformed metadata and stored lineage envelopes", %{root: root} do
    missing_metadata_path = Path.join(root, "missing-metadata.dets")
    seed(missing_metadata_path, [{{:current, "issue-a"}, snapshot("project-a", "issue-a", "lineage-a", %{})}])

    assert {:error, {:corrupt_attempt_record, :metadata, :missing_metadata}} =
             AttemptLedger.open("project-a", @identity, path: missing_metadata_path)

    duplicate_metadata_path = Path.join(root, "duplicate-metadata.dets")

    seed(duplicate_metadata_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:meta, "other-project"}, metadata("other-project", @identity)}
    ])

    assert {:error, {:corrupt_attempt_record, :metadata, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: duplicate_metadata_path)

    invalid_metadata_path = Path.join(root, "invalid-metadata.dets")
    seed(invalid_metadata_path, [{{:meta, "project-a"}, :corrupt}])

    assert {:error, {:corrupt_attempt_record, :metadata, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: invalid_metadata_path)

    extra_metadata_path = Path.join(root, "extra-metadata.dets")

    seed(extra_metadata_path, [
      {{:meta, "project-a"}, Map.put(metadata("project-a", @identity), :unexpected, true)}
    ])

    assert {:error, {:corrupt_attempt_record, :metadata, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: extra_metadata_path)

    current_schema_path = Path.join(root, "current-schema.dets")

    seed(current_schema_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:current, "issue-a"}, Map.put(snapshot("project-a", "issue-a", "lineage-a", %{}), :schema_version, 999)}
    ])

    assert {:error, {:ledger_schema_version_unsupported, 999}} =
             AttemptLedger.open("project-a", @identity, path: current_schema_path)

    history =
      snapshot("project-a", "issue-a", "lineage-a", %{})
      |> Map.merge(%{
        status: :closed,
        closed_reason: :rearmed,
        rearm_reason: "verified",
        rearmed_by: "operator",
        rearmed_at: 1_700_000_000_000
      })

    valid_history_path = Path.join(root, "valid-history.dets")

    seed(valid_history_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:history, "lineage-a"}, history}
    ])

    {:ok, valid_history_ledger} = AttemptLedger.open("project-a", @identity, path: valid_history_path)
    assert {:ok, [^history]} = AttemptLedger.history(valid_history_ledger)
    assert :ok = AttemptLedger.close(valid_history_ledger)

    mismatched_history_path = Path.join(root, "mismatched-history.dets")

    seed(mismatched_history_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:history, "other-lineage"}, history}
    ])

    assert {:error, {:corrupt_attempt_record, {:history, "other-lineage"}, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: mismatched_history_path)

    malformed_history_path = Path.join(root, "malformed-history.dets")

    seed(malformed_history_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:history, "lineage-a"}, :corrupt}
    ])

    assert {:error, {:corrupt_attempt_record, {:history, "lineage-a"}, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: malformed_history_path)

    history_schema_path = Path.join(root, "history-schema.dets")

    seed(history_schema_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:history, "lineage-a"}, Map.put(history, :schema_version, 999)}
    ])

    assert {:error, {:ledger_schema_version_unsupported, 999}} =
             AttemptLedger.open("project-a", @identity, path: history_schema_path)

    unknown_record_path = Path.join(root, "unknown-record.dets")

    seed(unknown_record_path, [
      {{:meta, "project-a"}, metadata("project-a", @identity)},
      {{:unexpected, "record"}, :corrupt}
    ])

    assert {:error, {:corrupt_attempt_record, {:unexpected, "record"}, :invalid_record}} =
             AttemptLedger.open("project-a", @identity, path: unknown_record_path)
  end

  test "returns injected write and sync callback failures", %{root: root} do
    write_raise = fn _table, _records -> raise "write boom" end
    write_throw = fn _table, _records -> throw(:write_boom) end
    sync_raise = fn _table -> raise "sync boom" end
    sync_throw = fn _table -> throw(:sync_boom) end

    callback_cases = [
      {:write_other, [write_fun: fn _table, _records -> :unexpected end], {:ledger_write_failed, :unexpected}},
      {:write_raise, [write_fun: write_raise], {:ledger_write_failed, %RuntimeError{message: "write boom"}}},
      {:write_throw, [write_fun: write_throw], {:ledger_write_failed, {:throw, :write_boom}}},
      {:sync_other, [sync_fun: fn _table -> :unexpected end], {:ledger_sync_failed, :unexpected}},
      {:sync_raise, [sync_fun: sync_raise], {:ledger_sync_failed, %RuntimeError{message: "sync boom"}}},
      {:sync_throw, [sync_fun: sync_throw], {:ledger_sync_failed, {:throw, :sync_boom}}}
    ]

    for {name, opts, expected} <- callback_cases do
      path = Path.join(root, "callback-#{name}.dets")
      {:ok, initialized} = AttemptLedger.open("project-a", @identity, path: path)
      assert :ok = AttemptLedger.close(initialized)
      {:ok, ledger} = AttemptLedger.open("project-a", @identity, Keyword.merge([path: path], opts))
      assert {:error, ^expected} = AttemptLedger.put(ledger, snapshot("project-a", "issue-a", "lineage-a", %{}))
      assert :ok = AttemptLedger.close(ledger)
    end
  end

  test "rejects invalid rearm arguments and missing lineages", %{path: path} do
    {:ok, ledger} = AttemptLedger.open("project-a", @identity, path: path)

    assert {:error, :invalid_rearm_arguments} =
             AttemptLedger.rearm(ledger, "issue-a", " ", "operator", 1_700_000_000_000)

    assert {:error, :invalid_rearm_arguments} =
             AttemptLedger.rearm(ledger, "issue-a", "reason", " ", 1_700_000_000_000)

    assert {:error, :invalid_rearm_arguments} =
             AttemptLedger.rearm(ledger, "issue-a", "reason", "operator", -1)

    assert {:error, :lineage_not_found} =
             AttemptLedger.rearm(ledger, "missing", "reason", "operator", 1_700_000_000_000)

    assert {:error, :invalid_rearm_arguments} = AttemptLedger.rearm(:invalid, "issue-a", "reason", "operator", 1)
    assert :ok = AttemptLedger.close(ledger)
  end

  test "handles detached ledgers and invalid callback configuration", %{root: root} do
    assert :ok = AttemptLedger.close(%AttemptLedger{table: :symphony_missing_attempt_ledger})

    assert {:error, :invalid_ledger_callbacks} =
             AttemptLedger.open("project-a", @identity,
               path: Path.join(root, "invalid-callbacks.dets"),
               write_fun: :not_a_function
             )
  end

  defp snapshot(project_id, issue_id, lineage_id, overrides) do
    %{
      schema_version: 1,
      project_namespace: project_id,
      issue_id: issue_id,
      lineage_id: lineage_id,
      safety_counters: Map.merge(%{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0}, overrides),
      status: :open,
      stop_reason: nil,
      route_fingerprint: "sha256:test",
      updated_at: 1_700_000_000_000
    }
  end

  defp metadata(project_id, identity, schema_version \\ 1) do
    %{
      schema_version: schema_version,
      project_namespace: project_id,
      tracker_identity: identity
    }
  end

  defp seed(path, records) do
    {:ok, table} = :dets.open_file(path, type: :set, file: String.to_charlist(path))
    :ok = :dets.delete_all_objects(table)
    :ok = :dets.insert(table, records)
    :ok = :dets.sync(table)
    :ok = :dets.close(table)
  end
end
