defmodule SymphonyElixir.TransitionAttemptLedgerTest do
  use ExUnit.Case

  alias SymphonyElixir.WorkControl.TransitionAttemptLedger

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
          {"submitted", :submitted},
          {"verifying", :verifying},
          {"conflict", :conflict},
          {"indeterminate", :indeterminate},
          {"verified", :verified},
          {"rejected", :rejected}
        ] do
      assert :ok = TransitionAttemptLedger.put_sync(ledger, attempt(id, id, status))
    end

    assert {:ok, candidates} = TransitionAttemptLedger.list_reconciliation_candidates(ledger)
    assert Enum.map(candidates, & &1.status) == [:submitted, :verifying, :conflict, :indeterminate]

    for candidate <- candidates do
      refute TransitionAttemptLedger.resubmit_allowed?(candidate)
    end

    assert TransitionAttemptLedger.resubmit_allowed?(attempt("new", "new", :prepared))
    assert :ok = TransitionAttemptLedger.close(ledger)
  end

  test "does not expose a deletion operation", %{path: path} do
    {:ok, ledger} = TransitionAttemptLedger.open("project-a", @identity, path: path)
    refute function_exported?(TransitionAttemptLedger, :delete, 2)
    refute function_exported?(TransitionAttemptLedger, :delete_all, 1)
    assert :ok = TransitionAttemptLedger.close(ledger)
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
      status: status,
      created_at: 1_700_000_000_000,
      updated_at: 1_700_000_000_000
    }
  end
end
