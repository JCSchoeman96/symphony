defmodule Mix.Tasks.Symphony.AttemptRearmTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.AttemptRearm
  alias SymphonyElixir.AgentRuntime.AttemptLedger

  test "requires explicit project, issue, reason, and operator" do
    assert_raise Mix.Error, ~r/Missing required option --project-id/, fn ->
      AttemptRearm.run([])
    end

    assert_raise Mix.Error, ~r/Missing required option --issue-id/, fn ->
      AttemptRearm.run(["--project-id", "project-a"])
    end

    assert_raise Mix.Error, ~r/Missing required option --reason/, fn ->
      AttemptRearm.run(["--project-id", "project-a", "--issue-id", "issue-a"])
    end

    assert_raise Mix.Error, ~r/Missing required option --operator/, fn ->
      AttemptRearm.run([
        "--project-id",
        "project-a",
        "--issue-id",
        "issue-a",
        "--reason",
        "verified"
      ])
    end

    assert_raise Mix.Error, ~r/Missing required option --timestamp/, fn ->
      AttemptRearm.run([
        "--project-id",
        "project-a",
        "--issue-id",
        "issue-a",
        "--reason",
        "verified",
        "--operator",
        "operator"
      ])
    end
  end

  test "rearms an exhausted lineage and preserves the old history" do
    project_id = "task-project-#{System.unique_integer([:positive])}"
    workflow_path = Workflow.workflow_file_path()
    ledger_root = Path.join(Path.dirname(workflow_path), "attempt-ledger")
    ledger_path = Path.join(ledger_root, "task.dets")
    File.mkdir_p!(ledger_root)

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      symphony_project_id: project_id,
      agent_routing: "routed"
    )

    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: ledger_path)

    {:ok, exhausted} =
      AttemptLedger.persist_safety(ledger, "issue-a", %{ordinary_failures: 4, ordinary_retries: 3, review_cycles: 0},
        status: :exhausted,
        stop_reason: :ordinary_retry_limit,
        updated_at: 1_700_000_000_000
      )

    :ok = AttemptLedger.close(ledger)

    output =
      capture_io(fn ->
        assert :ok =
                 AttemptRearm.run([
                   "--project-id",
                   project_id,
                   "--issue-id",
                   "issue-a",
                   "--reason",
                   "provider state verified",
                   "--operator",
                   "operator@example.com",
                   "--timestamp",
                   "1700000001000",
                   "--ledger-path",
                   ledger_path,
                   "--workflow",
                   workflow_path
                 ])
      end)

    assert output =~ "Rearmed issue issue-a in project #{project_id}"

    {:ok, reopened} = AttemptLedger.open(project_id, identity, path: ledger_path)
    assert {:ok, current} = AttemptLedger.current(reopened, "issue-a")
    assert current.status == :open
    assert current.lineage_id != exhausted.lineage_id
    assert {:ok, [history]} = AttemptLedger.history(reopened)
    assert history.lineage_id == exhausted.lineage_id
    assert history.rearm_reason == "provider state verified"
    assert :ok = AttemptLedger.close(reopened)
  end

  test "rejects a non-exhausted lineage" do
    project_id = "task-active-#{System.unique_integer([:positive])}"
    workflow_path = Workflow.workflow_file_path()
    ledger_path = Path.join(System.tmp_dir!(), "symphony-task-active-#{System.unique_integer([:positive])}.dets")

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      symphony_project_id: project_id,
      agent_routing: "routed"
    )

    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: ledger_path)

    {:ok, _record} =
      AttemptLedger.persist_safety(ledger, "issue-a", %{ordinary_failures: 1, ordinary_retries: 1, review_cycles: 0})

    :ok = AttemptLedger.close(ledger)

    assert_raise Mix.Error, ~r/lineage_not_exhausted/, fn ->
      AttemptRearm.run([
        "--project-id",
        project_id,
        "--issue-id",
        "issue-a",
        "--reason",
        "not allowed",
        "--operator",
        "operator",
        "--timestamp",
        "1700000000000",
        "--ledger-path",
        ledger_path,
        "--workflow",
        workflow_path
      ])
    end

    File.rm(ledger_path)
    File.rm(ledger_path <> ".dat")
  end

  test "supports help, and rejects invalid or unexpected arguments" do
    help = capture_io(fn -> assert :ok = AttemptRearm.run(["--help"]) end)
    assert help =~ "Rearms one exhausted attempt lineage"

    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      AttemptRearm.run(["--unknown"])
    end

    assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
      AttemptRearm.run(["unexpected"])
    end

    assert_raise Mix.Error, ~r/Missing required option --project-id/, fn ->
      AttemptRearm.run(["--project-id", "", "--issue-id", "issue", "--reason", "reason", "--operator", "operator"])
    end
  end

  test "rejects an invalid project id before loading workflow state" do
    assert_raise Mix.Error, ~r/invalid_symphony_project_id/, fn ->
      AttemptRearm.run([
        "--project-id",
        "../unsafe",
        "--issue-id",
        "issue-a",
        "--reason",
        "verified",
        "--operator",
        "operator",
        "--timestamp",
        "1700000000000"
      ])
    end
  end

  test "loads the configured legacy workflow when no workflow path is supplied" do
    project_id = "task-legacy-#{System.unique_integer([:positive])}"
    ledger_path = Path.join(System.tmp_dir!(), "symphony-task-legacy-#{System.unique_integer([:positive])}.dets")
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: ledger_path)

    {:ok, exhausted} =
      AttemptLedger.persist_safety(ledger, "issue-a", %{ordinary_failures: 4, ordinary_retries: 3, review_cycles: 0},
        status: :exhausted,
        stop_reason: :ordinary_retry_limit,
        updated_at: 1_700_000_000_000
      )

    :ok = AttemptLedger.close(ledger)

    output =
      capture_io(fn ->
        assert :ok =
                 AttemptRearm.run([
                   "--project-id",
                   project_id,
                   "--issue-id",
                   "issue-a",
                   "--reason",
                   "legacy workflow verified",
                   "--operator",
                   "operator",
                   "--timestamp",
                   "1700000001000",
                   "--ledger-path",
                   ledger_path
                 ])
      end)

    assert output =~ "Rearmed issue issue-a in project #{project_id}"
    {:ok, reopened} = AttemptLedger.open(project_id, identity, path: ledger_path)
    assert {:ok, current} = AttemptLedger.current(reopened, "issue-a")
    assert current.lineage_id != exhausted.lineage_id
    assert :ok = AttemptLedger.close(reopened)
    File.rm(ledger_path)
    File.rm(ledger_path <> ".dat")
  end

  test "reports workflow identity and workflow loading failures" do
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      symphony_project_id: "configured-project",
      agent_routing: "routed"
    )

    assert_raise Mix.Error, ~r/does not match requested project/, fn ->
      AttemptRearm.run([
        "--project-id",
        "requested-project",
        "--issue-id",
        "issue-a",
        "--reason",
        "verified",
        "--operator",
        "operator",
        "--timestamp",
        "1700000000000",
        "--workflow",
        workflow_path
      ])
    end

    assert_raise Mix.Error, ~r/Unable to load workflow configuration/, fn ->
      AttemptRearm.run([
        "--project-id",
        "requested-project",
        "--issue-id",
        "issue-a",
        "--reason",
        "verified",
        "--operator",
        "operator",
        "--timestamp",
        "1700000000000",
        "--workflow",
        Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}")
      ])
    end
  end

  test "reports ledger open failures" do
    project_id = "task-ledger-error-#{System.unique_integer([:positive])}"
    workflow_path = Workflow.workflow_file_path()

    write_workflow_file!(workflow_path,
      tracker_kind: "memory",
      symphony_project_id: project_id,
      agent_routing: "routed"
    )

    parent = Path.join(System.tmp_dir!(), "symphony-ledger-file-#{System.unique_integer([:positive])}")
    File.write!(parent, "not a directory")
    on_exit(fn -> File.rm(parent) end)

    assert_raise Mix.Error, ~r/Unable to open attempt ledger/, fn ->
      AttemptRearm.run([
        "--project-id",
        project_id,
        "--issue-id",
        "issue-a",
        "--reason",
        "verified",
        "--operator",
        "operator",
        "--timestamp",
        "1700000000000",
        "--workflow",
        workflow_path,
        "--ledger-path",
        Path.join(parent, "ledger.dets")
      ])
    end
  end
end
