defmodule SymphonyElixir.RuntimeAttemptHoldRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, _recipient, opts) do
    if capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid) do
      send(capture, {:runtime_attempt_runner_started, issue.id, opts})
    end

    receive do
      :release_runtime_attempt_runner -> :ok
    end
  end
end

defmodule SymphonyElixir.RuntimeAttemptSequenceRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, _recipient, opts) do
    capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid)
    count = :persistent_term.get({__MODULE__, :count}, 0) + 1
    :persistent_term.put({__MODULE__, :count}, count)

    if capture do
      send(capture, {:runtime_attempt_sequence_started, count, issue.id, opts})
    end

    if count == 1 do
      exit(:first_attempt_failure)
    end

    receive do
      :release_runtime_attempt_runner -> :ok
    end
  end
end

defmodule SymphonyElixir.RuntimeAttemptProductionPathTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{AttemptLedger, RuntimeAttempt}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.WorkItem

  setup do
    :persistent_term.put({SymphonyElixir.RuntimeAttemptSequenceRunner, :count}, 0)
    :ok
  end

  test "dispatch and retry allocate distinct runtime identities bound to the same durable lineage" do
    project_id = "runtime-identity-retry-#{System.unique_integer([:positive])}"
    issue = active_issue("runtime-identity-retry")
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    name = Module.concat(__MODULE__, "Retry#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        agent_runner: SymphonyElixir.RuntimeAttemptSequenceRunner,
        work_control: trusted_work_control([issue]),
        attempt_ledger_opts: [path: path]
      )

    on_exit(fn ->
      if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    issue_id = issue.id

    assert_receive {:runtime_attempt_sequence_started, 1, ^issue_id, first_opts}, 5_000
    identity_a = first_opts[:runtime_attempt_identity]
    assert %Identity{} = identity_a

    assert eventually(fn ->
             map_size(:sys.get_state(orchestrator).retry_attempts) > 0
           end)

    retry_entry = :sys.get_state(orchestrator).retry_attempts[issue_id]
    send(orchestrator, {:retry_issue, issue_id, retry_entry.retry_token})

    assert_receive {:runtime_attempt_sequence_started, 2, ^issue_id, second_opts}, 5_000
    identity_b = second_opts[:runtime_attempt_identity]
    assert %Identity{} = identity_b
    refute identity_a.runtime_attempt_id == identity_b.runtime_attempt_id
    assert identity_a.lineage_generation == identity_b.lineage_generation

    state = :sys.get_state(orchestrator)
    current = get_in(state.running, [issue_id, Access.key(:runtime_attempt)])
    assert %RuntimeAttempt{identity: current_identity} = current
    assert current_identity.runtime_attempt_id == identity_b.runtime_attempt_id

    stale_update = %{event: :session_started, session_id: "stale", timestamp: DateTime.utc_now()}

    send(
      orchestrator,
      {:codex_worker_update, issue_id, identity_a, stale_update}
    )

    Process.sleep(50)
    refreshed = :sys.get_state(orchestrator)
    assert refreshed.running[issue_id].session_id != "stale"

    assert refreshed.running[issue_id].runtime_attempt.identity.runtime_attempt_id ==
             identity_b.runtime_attempt_id

    worker_pid = Map.get(refreshed.running[issue_id], :pid)
    if is_pid(worker_pid), do: send(worker_pid, :release_runtime_attempt_runner)
  end

  test "rearm installs a new lineage generation before the next dispatch accepts runtime events" do
    project_id = "runtime-identity-rearm-#{System.unique_integer([:positive])}"
    issue = active_issue("runtime-identity-rearm")
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    seed_snapshot(path, project_id, issue.id, %{ordinary_failures: 4, ordinary_retries: 3}, :exhausted)

    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    assert {:ok, rearmed} = AttemptLedger.rearm(ledger, issue.id, "verified", "operator", 1_700_000_000_000)
    :ok = AttemptLedger.close(ledger)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    name = Module.concat(__MODULE__, "Rearm#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        agent_runner: SymphonyElixir.RuntimeAttemptHoldRunner,
        work_control: trusted_work_control([issue]),
        attempt_ledger_opts: [path: path]
      )

    on_exit(fn ->
      if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    issue_id = issue.id
    assert_receive {:runtime_attempt_runner_started, ^issue_id, first_opts}, 5_000
    identity_current = first_opts[:runtime_attempt_identity]
    assert identity_current.lineage_generation == rearmed.lineage_id

    old_identity = %{identity_current | lineage_generation: "lineage-before-rearm", runtime_attempt_id: "old-attempt"}

    send(
      orchestrator,
      {:worker_runtime_info, issue_id, old_identity, %{worker_host: "stale-host", workspace_path: "/stale"}}
    )

    Process.sleep(50)
    state = :sys.get_state(orchestrator)
    entry = state.running[issue_id]
    refute entry.workspace_path == "/stale"
    refute entry.worker_host == "stale-host"

    worker_pid = Map.get(entry, :pid)
    if is_pid(worker_pid), do: send(worker_pid, :release_runtime_attempt_runner)
  end

  defp active_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: String.upcase(issue_id),
      title: "Runtime attempt production path",
      state: "In Progress",
      dispatchable: true
    }
  end

  defp temporary_ledger_root do
    root = Path.join(System.tmp_dir!(), "symphony-runtime-attempt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp seed_snapshot(path, project_id, issue_id, counters, status \\ :open) do
    identity = Tracker.identity(Config.settings!().tracker)
    {:ok, ledger} = AttemptLedger.open(project_id, identity, path: path)
    counters = Map.merge(%{ordinary_failures: 0, ordinary_retries: 0, review_cycles: 0}, counters)

    assert {:ok, _snapshot} =
             AttemptLedger.persist_safety(ledger, issue_id, counters,
               status: status,
               stop_reason: if(status == :exhausted, do: :ordinary_retry_limit, else: nil),
               updated_at: 1_700_000_000_000
             )

    assert :ok = AttemptLedger.close(ledger)
  end

  defp eventually(fun, attempts \\ 200)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp trusted_work_control(issues) when is_list(issues) do
    Enum.reduce(issues, %{}, fn %Issue{id: issue_id} = issue, acc ->
      {:ok, work_item} =
        WorkItem.from_issue(issue, %{
          provider: :memory,
          observed_at: DateTime.utc_now(),
          prior_validated_lifecycle_state: :in_progress
        })

      Map.put(acc, issue_id, work_item)
    end)
  end
end
