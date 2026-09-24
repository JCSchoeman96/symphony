defmodule SymphonyElixir.RuntimeAttemptHoldRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok
  def run(issue, recipient, opts) do
    identity = Keyword.get(opts, :runtime_attempt_identity)

    if capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid) do
      send(capture, {:runtime_attempt_runner_started, issue.id, opts})
    end

    notify_runtime_session_started(recipient, issue.id, identity)

    receive do
      :release_runtime_attempt_runner -> :ok
    end
  end

  defp notify_runtime_session_started(recipient, issue_id, identity)
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:runtime_attempt_session_started, issue_id, identity})
    :ok
  end

  defp notify_runtime_session_started(_recipient, _issue_id, _identity), do: :ok
end

defmodule SymphonyElixir.RuntimeAttemptSequenceRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, recipient, opts) do
    capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid)
    count = :persistent_term.get({__MODULE__, :count}, 0) + 1
    :persistent_term.put({__MODULE__, :count}, count)

    if capture do
      send(capture, {:runtime_attempt_sequence_started, count, issue.id, opts})
    end

    if count == 1 do
      exit(:first_attempt_failure)
    end

    identity = Keyword.get(opts, :runtime_attempt_identity)

    if is_pid(recipient) and identity do
      send(recipient, {:runtime_attempt_session_started, issue.id, identity})
    end

    if capture do
      send(capture, {:runtime_attempt_sequence_session_started, count, issue.id})
    end

    receive do
      :release_runtime_attempt_runner -> :ok
    end
  end
end

defmodule SymphonyElixir.RuntimeAttemptDownReplayRunner do
  @moduledoc false

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, recipient, opts) do
    capture = Application.get_env(:symphony_elixir, :attempt_ledger_test_pid)
    phase = :persistent_term.get({__MODULE__, :phase}, :first)

    case phase do
      :first ->
        if capture do
          send(capture, {:down_replay_attempt, :first, issue.id, opts})
        end

        receive do
          :exit_down_replay_first -> exit(:shutdown)
        end

      :second ->
        identity = Keyword.get(opts, :runtime_attempt_identity)

        if is_pid(recipient) and identity do
          send(recipient, {:runtime_attempt_session_started, issue.id, identity})
        end

        if capture do
          send(capture, {:down_replay_attempt, :second, issue.id, opts})
        end

        receive do
          :release_runtime_attempt_runner -> :ok
        end
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
    :persistent_term.put({SymphonyElixir.RuntimeAttemptDownReplayRunner, :phase}, :first)
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
    seed_recovery_checkpoint!(issue)
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
    assert_receive {:runtime_attempt_sequence_session_started, 2, ^issue_id}, 5_000

    identity_b = second_opts[:runtime_attempt_identity]
    assert %Identity{} = identity_b
    refute identity_a.runtime_attempt_id == identity_b.runtime_attempt_id
    assert identity_a.lineage_generation == identity_b.lineage_generation

    assert eventually(fn ->
             case get_in(:sys.get_state(orchestrator).running, [issue_id, Access.key(:runtime_attempt)]) do
               %RuntimeAttempt{state: :running, identity: current_identity} ->
                 current_identity.runtime_attempt_id == identity_b.runtime_attempt_id

               _ ->
                 false
             end
           end)

    stale_update = %{event: :session_started, session_id: "stale", timestamp: DateTime.utc_now()}

    send(
      orchestrator,
      {:codex_worker_update, issue_id, identity_a, stale_update}
    )

    assert eventually(fn ->
             refreshed = :sys.get_state(orchestrator)
             entry = refreshed.running[issue_id]

             entry.session_id != "stale" and
               entry.runtime_attempt.identity.runtime_attempt_id == identity_b.runtime_attempt_id
           end)

    worker_pid = Map.get(:sys.get_state(orchestrator).running[issue_id], :pid)
    if is_pid(worker_pid), do: send(worker_pid, :release_runtime_attempt_runner)
  end

  test "delayed and duplicate terminal DOWN from a prior attempt cannot affect the replacement attempt" do
    project_id = "runtime-identity-down-#{System.unique_integer([:positive])}"
    issue = active_issue("runtime-identity-down")
    ledger_root = temporary_ledger_root()
    path = AttemptLedger.path_for(project_id, root: ledger_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      symphony_project_id: project_id,
      tracker_active_states: ["In Progress"],
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_recovery_checkpoint!(issue)
    Application.put_env(:symphony_elixir, :attempt_ledger_test_pid, self())

    name = Module.concat(__MODULE__, "Down#{System.unique_integer([:positive])}")

    {:ok, orchestrator} =
      Orchestrator.start_link(
        name: name,
        agent_runner: SymphonyElixir.RuntimeAttemptDownReplayRunner,
        work_control: trusted_work_control([issue]),
        attempt_ledger_opts: [path: path]
      )

    on_exit(fn ->
      if Process.alive?(orchestrator), do: GenServer.stop(orchestrator)
      Application.delete_env(:symphony_elixir, :attempt_ledger_test_pid)
    end)

    issue_id = issue.id

    assert_receive {:down_replay_attempt, :first, ^issue_id, first_opts}, 5_000

    first_entry =
      eventually_value(fn ->
        case :sys.get_state(orchestrator).running[issue_id] do
          %{ref: ref, pid: pid, runtime_attempt: %RuntimeAttempt{}} = entry when is_reference(ref) and is_pid(pid) ->
            entry

          _ ->
            nil
        end
      end)

    ref_a = first_entry.ref
    pid_a = first_entry.pid
    identity_a = first_opts[:runtime_attempt_identity]

    send(pid_a, :exit_down_replay_first)

    assert eventually(fn ->
             map_size(:sys.get_state(orchestrator).retry_attempts) > 0
           end)

    retry_entry = :sys.get_state(orchestrator).retry_attempts[issue_id]
    :persistent_term.put({SymphonyElixir.RuntimeAttemptDownReplayRunner, :phase}, :second)
    send(orchestrator, {:retry_issue, issue_id, retry_entry.retry_token})

    assert_receive {:down_replay_attempt, :second, ^issue_id, second_opts}, 5_000
    identity_b = second_opts[:runtime_attempt_identity]
    refute identity_a.runtime_attempt_id == identity_b.runtime_attempt_id

    assert eventually(fn ->
             case get_in(:sys.get_state(orchestrator).running, [issue_id, Access.key(:runtime_attempt)]) do
               %RuntimeAttempt{state: :running, identity: current_identity} ->
                 current_identity.runtime_attempt_id == identity_b.runtime_attempt_id

               _ ->
                 false
             end
           end)

    baseline = :sys.get_state(orchestrator)
    baseline_entry = baseline.running[issue_id]
    baseline_retry = baseline.retry_attempts
    baseline_blocked = baseline.blocked
    baseline_claimed = baseline.claimed
    baseline_counters = attempt_counter_snapshot(orchestrator, issue_id)

    send(orchestrator, {:DOWN, ref_a, :process, pid_a, :normal})
    send(orchestrator, {:DOWN, ref_a, :process, pid_a, :normal})

    assert eventually(fn ->
             after_state = :sys.get_state(orchestrator)
             entry = after_state.running[issue_id]

             entry.ref == baseline_entry.ref and
               entry.pid == baseline_entry.pid and
               entry.runtime_attempt.identity.runtime_attempt_id == identity_b.runtime_attempt_id and
               after_state.retry_attempts == baseline_retry and
               after_state.blocked == baseline_blocked and
               after_state.claimed == baseline_claimed and
               attempt_counter_snapshot(orchestrator, issue_id) == baseline_counters
           end)

    worker_pid = Map.get(baseline_entry, :pid)
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
    {:ok, exhausted_record} = AttemptLedger.current(ledger, issue.id)
    pre_rearm_lineage = exhausted_record.lineage_id
    assert {:ok, rearmed} = AttemptLedger.rearm(ledger, issue.id, "verified", "operator", 1_700_000_000_000)
    :ok = AttemptLedger.close(ledger)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    seed_recovery_checkpoint!(issue)
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
    refute pre_rearm_lineage == rearmed.lineage_id

    stale_identity = %{
      identity_current
      | lineage_generation: pre_rearm_lineage,
        runtime_attempt_id: "stale-pre-rearm-attempt"
    }

    send(
      orchestrator,
      {:worker_runtime_info, issue_id, stale_identity, %{worker_host: "stale-host", workspace_path: "/stale"}}
    )

    assert eventually(fn ->
             state = :sys.get_state(orchestrator)
             entry = state.running[issue_id]

             entry.workspace_path != "/stale" and entry.worker_host != "stale-host" and
               entry.runtime_attempt.identity.lineage_generation == rearmed.lineage_id
           end)

    worker_pid = Map.get(:sys.get_state(orchestrator).running[issue_id], :pid)
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

  defp attempt_counter_snapshot(orchestrator, issue_id) do
    state = :sys.get_state(orchestrator)

    case state.attempt_ledger do
      %AttemptLedger{} = ledger ->
        case AttemptLedger.current(ledger, issue_id) do
          {:ok, record} -> Map.take(record.safety_counters, [:ordinary_failures, :ordinary_retries, :review_cycles])
          _ -> nil
        end

      _ ->
        nil
    end
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

  defp eventually_value(fun, attempts \\ 200)

  defp eventually_value(fun, attempts) when attempts > 0 do
    case fun.() do
      nil -> Process.sleep(20) && eventually_value(fun, attempts - 1)
      value -> value
    end
  end

  defp eventually_value(_fun, 0), do: nil

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
