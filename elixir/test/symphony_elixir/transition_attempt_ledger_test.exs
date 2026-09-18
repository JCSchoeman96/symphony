defmodule SymphonyElixir.TransitionAttemptLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.WorkControl.{TransitionAttempt, TransitionAttemptLedger}

  @identity %{tracker_kind: "plane", provider_scope: %{project_id: "project-a"}}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-transition-ledger-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, path: Path.join(root, "transition-attempts.dets")}
  end

  test "persists attempts and the latest work-item pointer across reopen", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    attempt = attempt("attempt-a", "work-a", :prepared)

    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    assert :ok = TransitionAttemptLedger.put_sync(ledger, attempt)
    assert {:ok, ^attempt} = TransitionAttemptLedger.get(ledger, "attempt-a")
    assert {:ok, ^attempt} = TransitionAttemptLedger.latest_for_work_item(ledger, "work-a")
    assert :ok = TransitionAttemptLedger.close(ledger)

    {:ok, reopened} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert {:ok, ^attempt} = TransitionAttemptLedger.get(reopened, "attempt-a")
    assert {:ok, ^attempt} = TransitionAttemptLedger.latest_for_work_item(reopened, "work-a")
    assert :ok = TransitionAttemptLedger.close(reopened)
  end

  test "rejects invalid ledger identities and malformed lookups", %{path: path} do
    assert {:error, {:invalid_project_id, ""}} = TransitionAttemptLedger.open("", @identity, path: path)
    assert {:error, :invalid_tracker_identity} = TransitionAttemptLedger.open("project-a", %{}, path: path)

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.put_sync(nil, :invalid)

    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = :dets.insert(ledger.table, {{:attempt, "bad"}, :invalid})
    assert {:error, {:corrupt_transition_attempt, :invalid_record}} = TransitionAttemptLedger.get(ledger, "bad")

    assert :ok = :dets.insert(ledger.table, {{:latest, "work-a"}, :invalid})

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.latest_for_work_item(ledger, "work-a")

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "covers ledger defaults, unreadable tables, and malformed table entries", %{path: path} do
    assert TransitionAttemptLedger.schema_version() == 1
    assert String.ends_with?(TransitionAttemptLedger.path_for("project-a"), "project-a-transition-ledger.dets")

    unreadable = %TransitionAttemptLedger{table: make_ref(), project_id: "project-a", tracker_identity: @identity}

    assert {:error, {:corrupt_transition_attempt, :ledger_unavailable}} =
             TransitionAttemptLedger.get(unreadable, "attempt")

    assert {:error, {:corrupt_transition_attempt, :ledger_unavailable}} =
             TransitionAttemptLedger.latest_for_work_item(unreadable, "work")

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.list_reconciliation_candidates(unreadable)

    assert :ok = TransitionAttemptLedger.close(unreadable)
    assert TransitionAttemptLedger.resubmit_allowed?(%TransitionAttempt{}) == false

    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = :dets.insert(ledger.table, {{:latest, 123}, "attempt"})
    assert :ok = :dets.insert(ledger.table, {{:other, "key"}, :ignored})

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.list_reconciliation_candidates(ledger)

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "opens using the configured default ledger root", %{root: root} do
    previous_root = Application.get_env(:symphony_elixir, :transition_attempt_ledger_root)
    Application.put_env(:symphony_elixir, :transition_attempt_ledger_root, root)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:symphony_elixir, :transition_attempt_ledger_root)
      else
        Application.put_env(:symphony_elixir, :transition_attempt_ledger_root, previous_root)
      end
    end)

    assert {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity)
    assert ledger.path == Path.join(root, "project-a-transition-ledger.dets")
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "binds a table to its project and tracker identity", %{path: path, root: root} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(ledger)

    assert {:error, {:ledger_project_namespace_mismatch, "project-a", "project-b"}} =
             TransitionAttemptLedger.open("project-b", @identity, path: path)

    assert {:error, {:ledger_tracker_identity_mismatch, @identity, _}} =
             TransitionAttemptLedger.open(
               "project-a",
               %{tracker_kind: "plane", provider_scope: %{project_id: "other-project"}},
               path: path
             )

    path_a = TransitionAttemptLedger.path_for("project-a", root: root)
    path_b = TransitionAttemptLedger.path_for("project-b", root: root)
    refute path_a == path_b
    refute String.contains?(path_a, "attempts.dets")
  end

  test "writes the attempt and latest pointer in one callback, then syncs", %{path: path} do
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(initialized)

    parent = self()

    {:ok, ledger} =
      TransitionAttemptLedger.open("project-a", @identity,
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

    attempt = attempt("attempt-a", "work-a", :prepared)
    assert :ok = TransitionAttemptLedger.put_sync(ledger, attempt)

    assert_receive {:write, records}
    assert Enum.any?(records, &match?({{:attempt, "attempt-a"}, ^attempt}, &1))
    assert Enum.any?(records, &match?({{:latest, "work-a"}, "attempt-a"}, &1))
    assert_receive :sync
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "returns injected write and sync failures", %{path: path} do
    {:ok, initialized} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(initialized)

    {:ok, write_failed} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        write_fun: fn _table, _records -> {:error, :disk_full} end
      )

    assert {:error, {:ledger_write_failed, :disk_full}} =
             TransitionAttemptLedger.put_sync(write_failed, attempt("attempt-a", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(write_failed)

    {:ok, sync_failed} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        sync_fun: fn _table -> {:error, :sync_failed} end
      )

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             TransitionAttemptLedger.put_sync(sync_failed, attempt("attempt-a", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(sync_failed)
  end

  test "validates attempt envelopes and status values", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    valid = attempt("attempt-a", "work-a", :prepared)

    invalid = [
      Map.put(valid, :schema_version, 999),
      Map.put(valid, :project_namespace, "other-project"),
      Map.put(valid, :attempt_id, ""),
      Map.put(valid, :work_item_id, ""),
      Map.put(valid, :status, :unknown),
      Map.put(valid, :status, :verified),
      Map.put(valid, :updated_at, -1),
      Map.put(valid, :unexpected, true),
      Map.put(valid, :source_state, :unknown_state)
    ]

    for record <- invalid do
      assert {:error, _reason} = TransitionAttemptLedger.put_sync(ledger, record)
    end

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.put_sync(ledger, :invalid)

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "lists only durable reconciliation candidates and never authorizes resubmission", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)

    for {id, status} <- [
          {"prepared", :prepared},
          {"submitted", :submitted},
          {"verifying", :verifying},
          {"conflict", :conflict},
          {"indeterminate", :indeterminate},
          {"verified", :verified},
          {"rejected", :rejected}
        ] do
      record = attempt(id, id, status)

      assert :ok = TransitionAttemptLedger.put_sync(ledger, record)
    end

    assert {:ok, candidates} = TransitionAttemptLedger.list_reconciliation_candidates(ledger)
    assert Enum.map(candidates, & &1.status) == [:prepared, :submitted, :verifying, :conflict, :indeterminate]

    for candidate <- candidates do
      refute TransitionAttemptLedger.resubmit_allowed?(candidate)
    end

    refute TransitionAttemptLedger.resubmit_allowed?(attempt("new", "new", :prepared))
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "rejects a corrupt persisted attempt instead of treating the ledger as empty", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = :dets.insert(ledger.table, {{:attempt, "corrupt"}, %{status: :indeterminate}})
    assert :ok = :dets.sync(ledger.table)

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.list_reconciliation_candidates(ledger)

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "rejects inconsistent state and status records and unknown table entries", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    mismatched = Map.merge(attempt("mismatched", "work-a", :prepared), %{state: :mutation_submitted})
    assert :ok = :dets.insert(ledger.table, {{:attempt, "mismatched"}, mismatched})
    assert :ok = :dets.insert(ledger.table, {{:unknown, "record"}, :unexpected})
    assert :ok = :dets.sync(ledger.table)

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.list_reconciliation_candidates(ledger)

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "rejects latest pointers that do not reference a persisted attempt", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = :dets.insert(ledger.table, {{:latest, "work-a"}, "missing-attempt"})
    assert :ok = :dets.sync(ledger.table)

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.list_reconciliation_candidates(ledger)

    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "does not expose a deletion operation", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    refute function_exported?(TransitionAttemptLedger, :delete, 2)
    refute function_exported?(TransitionAttemptLedger, :delete_all, 1)
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "normalizes missing records and permanently disallows resubmission", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :not_found = TransitionAttemptLedger.get(ledger, "missing")
    assert :not_found = TransitionAttemptLedger.latest_for_work_item(ledger, "missing")
    assert {:error, {:corrupt_transition_attempt, :invalid_record}} = TransitionAttemptLedger.get(ledger, :invalid)

    assert {:error, {:corrupt_transition_attempt, :invalid_record}} =
             TransitionAttemptLedger.latest_for_work_item(ledger, :invalid)

    assert TransitionAttemptLedger.resubmit_allowed?(%{state: :prepared}) == false
    assert TransitionAttemptLedger.resubmit_allowed?(%{status: :prepared}) == false
    assert TransitionAttemptLedger.resubmit_allowed?(:invalid) == false
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "rejects invalid callbacks, unexpected callback results, and callback exceptions", %{path: path} do
    assert {:error, :invalid_ledger_callbacks} =
             TransitionAttemptLedger.open("project-a", @identity, path: path, write_fun: :invalid)

    {:ok, initialized} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(initialized)

    {:ok, unexpected_write} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        write_fun: fn _table, _records -> :unexpected end
      )

    assert {:error, {:ledger_write_failed, :unexpected}} =
             TransitionAttemptLedger.put_sync(unexpected_write, attempt("unexpected", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(unexpected_write)

    {:ok, raising_write} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        write_fun: fn _table, _records -> raise "write failed" end
      )

    assert {:error, {:ledger_write_failed, :write_failed}} =
             TransitionAttemptLedger.put_sync(raising_write, attempt("raising", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(raising_write)

    {:ok, unexpected_sync} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        sync_fun: fn _table -> :unexpected end
      )

    assert {:error, {:ledger_sync_failed, :unexpected}} =
             TransitionAttemptLedger.put_sync(unexpected_sync, attempt("sync", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(unexpected_sync)

    {:ok, raising_sync} =
      TransitionAttemptLedger.open("project-a", @identity,
        path: path,
        sync_fun: fn _table -> raise "sync failed" end
      )

    assert {:error, {:ledger_sync_failed, :sync_failed}} =
             TransitionAttemptLedger.put_sync(raising_sync, attempt("sync-raise", "work-a", :prepared))

    assert :ok = TransitionAttemptLedger.close(raising_sync)
  end

  test "fails closed when a ledger path cannot be created", %{root: root} do
    blocker = Path.join(root, "not-a-directory")
    File.write!(blocker, "blocker")

    assert {:error, {:ledger_directory_failed, _reason}} =
             TransitionAttemptLedger.open("project-a", @identity, path: Path.join(blocker, "attempts.dets"))
  end

  test "rejects a second opener and malformed metadata", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)

    assert :ok = TransitionAttemptLedger.close(ledger)

    table = String.to_atom(path)
    {:ok, _} = :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.insert(table, {{:meta, "project-a"}, %{schema_version: 999}})
    assert :ok = :dets.sync(table)
    assert :ok = :dets.close(table)

    assert {:error, {:corrupt_transition_attempt, :metadata}} =
             TransitionAttemptLedger.open("project-a", @identity, path: path)
  end

  test "rejects a ledger with multiple metadata records", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(ledger)

    table = String.to_atom(path)
    {:ok, _} = :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity)

    metadata = %{
      schema_version: TransitionAttemptLedger.schema_version(),
      project_namespace: "project-a",
      tracker_identity: @identity
    }

    assert :ok = :dets.insert(table, {{:meta, "project-a"}, metadata})
    assert :ok = :dets.insert(table, {{:meta, "other"}, metadata})
    assert :ok = :dets.sync(table)
    assert :ok = :dets.close(table)

    assert {:error, {:corrupt_transition_attempt, :metadata}} =
             TransitionAttemptLedger.open("project-a", @identity, path: path)
  end

  test "rejects legacy metadata from another project namespace", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    assert :ok = TransitionAttemptLedger.close(ledger)

    table = String.to_atom(path)
    {:ok, _} = :dets.open_file(table, file: String.to_charlist(path), type: :set, auto_save: :infinity)
    assert :ok = :dets.insert(table, {{:meta, "project-a"}, %{project_namespace: "other-project"}})
    assert :ok = :dets.sync(table)
    assert :ok = :dets.close(table)

    assert {:error, {:ledger_project_namespace_mismatch, "other-project", "project-a"}} =
             TransitionAttemptLedger.open("project-a", @identity, path: path)
  end

  test "returns the DETS open error for a directory path", %{root: root} do
    assert {:error, _reason} =
             TransitionAttemptLedger.open("project-a", @identity, path: root)
  end

  test "closes malformed table handles fail closed" do
    assert :ok =
             TransitionAttemptLedger.close(%TransitionAttemptLedger{table: %{not_a_table: true}})
  end

  defp attempt(attempt_id, work_item_id, status) do
    %{
      schema_version: 1,
      project_namespace: "project-a",
      attempt_id: attempt_id,
      work_item_id: work_item_id,
      runtime_attempt_id: "runtime-#{work_item_id}",
      lineage_generation: 1,
      responsibility: "implementation",
      source_state: :ready,
      target_state: :in_progress,
      provider_observation_identity: "observation-#{work_item_id}",
      transition_identity: "transition-#{attempt_id}",
      state: if(status == :submitted, do: :mutation_submitted, else: status),
      status: status,
      created_at: 1_700_000_000_000,
      updated_at: 1_700_000_000_000
    }
  end
end
