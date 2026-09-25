defmodule SymphonyElixir.OrchestratorPlaneEpochFakeTracker do
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Tracker.{Capabilities, Issue}
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  @scope %{workspace_slug: "workspace-1", workspace_id: "workspace-stable-1", project_id: "project-1"}

  @spec fetch_project_snapshot(keyword()) :: {:ok, map()}
  def fetch_project_snapshot(opts) do
    test_pid = Application.fetch_env!(:symphony_elixir, :plane_epoch_test_pid)
    send(test_pid, {:plane_project_snapshot, self(), opts})
    snapshot_call = :atomics.add_get(Application.fetch_env!(:symphony_elixir, :plane_epoch_snapshot_counter), 1, 1)

    case Application.get_env(:symphony_elixir, :plane_epoch_test_mode, :normal) do
      :block_project ->
        wait_for(:release_project)
        {:ok, snapshot()}

      :crash_project ->
        raise "fake Plane snapshot crash"

      :fail_project ->
        {:error, :project_snapshot_failed}

      :invalid_project ->
        :invalid_project_snapshot

      :incomplete_project ->
        {:ok, Map.put(snapshot(), :completeness, :incomplete)}

      :fail_closing_snapshot when snapshot_call == 2 ->
        {:error, :closing_project_snapshot_failed}

      _normal ->
        {:ok, snapshot()}
    end
  end

  @spec fetch_dependency_graph(keyword()) :: term()
  def fetch_dependency_graph(opts) do
    test_pid = Application.fetch_env!(:symphony_elixir, :plane_epoch_test_pid)
    send(test_pid, {:plane_dependency_graph, self(), opts})

    mode = Application.get_env(:symphony_elixir, :plane_epoch_test_mode, :normal)

    case mode do
      :block_graph -> wait_for(:release_graph)
      :crash_graph -> raise "fake Plane graph crash"
      _normal -> :ok
    end

    fake_graph_result(opts, mode)
  end

  defp fake_graph_result(_opts, :fail_graph), do: {:error, :dependency_graph_failed}
  defp fake_graph_result(_opts, :invalid_graph), do: {:ok, :invalid_graph}
  defp fake_graph_result(_opts, :malformed_graph_result), do: :malformed_graph_result
  defp fake_graph_result(_opts, :list_graph), do: {:ok, [%{build_issue() | dispatchable: false}]}

  defp fake_graph_result(opts, :incomplete_graph) do
    {:ok,
     Graph.build([build_issue()],
       source: :plane,
       scope: @scope,
       epoch: Keyword.get(opts, :epoch_id),
       completeness: {:incomplete, :test}
     )}
  end

  defp fake_graph_result(opts, mode) when mode in [:wrong_epoch_graph, :wrong_scope_graph] do
    {scope, epoch} =
      case mode do
        :wrong_epoch_graph -> {@scope, :wrong_epoch}
        :wrong_scope_graph -> {Map.put(@scope, :project_id, "other-project"), Keyword.get(opts, :epoch_id)}
      end

    {:ok, Graph.build([build_issue()], source: :plane, scope: scope, epoch: epoch, completeness: :complete)}
  end

  defp fake_graph_result(opts, _mode) do
    {:ok,
     Graph.build([build_issue()],
       source: :plane,
       scope: @scope,
       epoch: Keyword.get(opts, :epoch_id, :startup_epoch),
       completeness: :complete,
       on_scc: Keyword.get(opts, :on_scc)
     )}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_issues_by_states(_states) do
    test_pid = Application.fetch_env!(:symphony_elixir, :plane_epoch_test_pid)
    send(test_pid, {:unexpected_provider_state_read, self()})
    {:ok, [build_issue()]}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]}
  def fetch_issues_by_ids(ids) do
    test_pid = Application.fetch_env!(:symphony_elixir, :plane_epoch_test_pid)
    send(test_pid, {:unexpected_provider_id_read, self(), ids})

    case Application.get_env(:symphony_elixir, :plane_epoch_test_mode, :normal) do
      :fail_missing_ids -> {:error, :fresh_state_unavailable}
      :invalid_missing_ids -> :invalid_result
      _normal -> {:ok, Enum.map(ids, fn _id -> build_issue() end)}
    end
  end

  def fetch_issues_by_ids(ids, _opts), do: fetch_issues_by_ids(ids)

  @spec graph(term()) :: Graph.t()
  def graph(epoch) do
    Graph.build([build_issue()], source: :plane, scope: @scope, epoch: epoch, completeness: :complete)
  end

  def issue, do: build_issue()
  def project_snapshot, do: snapshot()

  defp wait_for(message) do
    receive do
      ^message -> :ok
    after
      5_000 -> exit({:fake_tracker_timeout, message})
    end
  end

  defp build_issue do
    %Issue{
      id: "plane-epoch-issue",
      identifier: "PLANE-1",
      title: "Plane epoch issue",
      description: "",
      state: "Ready",
      url: "https://example.test/PLANE-1",
      workspace_id: "workspace-stable-1",
      project_id: "project-1",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      blocked_by: [],
      dependency_completeness: :complete,
      labels: [],
      dispatchable: true
    }
  end

  defp snapshot do
    groups = %{
      backlog: :backlog,
      planning: :unstarted,
      ready: :unstarted,
      in_progress: :started,
      in_review: :started,
      changes_requested: :started,
      ready_to_merge: :started,
      merging: :started,
      blocked: :started,
      done: :completed,
      canceled: :cancelled
    }

    %{
      provider: :plane,
      workspace_id: "workspace-stable-1",
      project_id: "project-1",
      states:
        Enum.map(WorkflowLifecycle.states(), fn state ->
          %{id: "state-#{state}", group: Map.fetch!(groups, state), name: WorkflowLifecycle.display(state)}
        end),
      dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
      capability_statuses: Map.new(Capabilities.vocabulary(), &{&1, :supported}),
      completeness: :complete
    }
  end
end

defmodule SymphonyElixir.OrchestratorPlaneEpochFakeRunner do
  @spec run(map(), pid(), keyword()) :: :ok
  def run(issue, _recipient, _opts) do
    test_pid = Application.fetch_env!(:symphony_elixir, :plane_epoch_test_pid)
    send(test_pid, {:fake_plane_agent_started, self(), issue.id})

    receive do
      :release_agent -> :ok
    after
      5_000 -> :ok
    end
  end
end

defmodule SymphonyElixir.OrchestratorPlaneEpochLegacyTracker do
  def fetch_project_snapshot, do: {:ok, SymphonyElixir.OrchestratorPlaneEpochFakeTracker.project_snapshot()}
  def fetch_dependency_graph, do: {:error, :legacy_graph_unavailable}
end

defmodule SymphonyElixir.OrchestratorPlaneEpochSnapshotOnlyTracker do
  def fetch_project_snapshot, do: {:ok, SymphonyElixir.OrchestratorPlaneEpochFakeTracker.project_snapshot()}
  def fetch_issues_by_ids(ids), do: {:ok, ids}
end

defmodule SymphonyElixir.OrchestratorPlaneEpochNoSnapshotTracker do
  def fetch_issues_by_ids(ids), do: {:ok, ids}
end

defmodule SymphonyElixir.OrchestratorPlaneEpochTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.OrchestratorPlaneEpochFakeTracker
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.WorkControl.RecoveryLedger

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    LifecycleAssessment,
    ProviderObservation,
    WorkflowLifecycle,
    WorkItem
  }

  setup do
    System.put_env("PLANE_API_KEY", "plane-epoch-test-secret")
    plane_workflow!("project-1")
    Application.put_env(:symphony_elixir, :plane_epoch_test_pid, self())
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :normal)
    Application.put_env(:symphony_elixir, :plane_epoch_snapshot_counter, :atomics.new(1, []))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :plane_epoch_test_pid)
      Application.delete_env(:symphony_elixir, :plane_epoch_test_mode)
      Application.delete_env(:symphony_elixir, :plane_epoch_snapshot_counter)
      System.delete_env("PLANE_API_KEY")
    end)

    :ok
  end

  test "startup stays fenced while the initial Plane graph task is incomplete" do
    assert Config.settings!().tracker.kind == "plane"
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_project)
    {pid, task_supervisor} = start_orchestrator()

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, task_pid, _opts}, 1_000

    state = :sys.get_state(pid)
    assert state.startup_reconciliation == :pending
    assert state.plane_epoch_status == :refreshing
    assert is_map(state.plane_epoch_task)
    assert Orchestrator.snapshot(pid, 250).plane_epoch.status == :refreshing

    :sys.replace_state(pid, fn state ->
      %{state | plane_epoch_task: Map.put(state.plane_epoch_task, :monitor_ref, nil)}
    end)

    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :normal)
    send(task_pid, :release_project)
    assert_receive {:plane_dependency_graph, _graph_task_pid, _graph_opts}, 1_000
    assert_receive {:plane_project_snapshot, _closing_task_pid, _closing_opts}, 1_000
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)
    assert is_nil(:sys.get_state(pid).plane_epoch_task)
    stop_orchestrator(pid, task_supervisor)
  end

  test "supports legacy zero-arity tracker reads and records a graph failure" do
    {pid, task_supervisor} = start_orchestrator(tracker: SymphonyElixir.OrchestratorPlaneEpochLegacyTracker)

    send(pid, :run_poll_cycle)

    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :failed end)

    stop_orchestrator(pid, task_supervisor)
  end

  test "fails an epoch cleanly when a tracker has no legacy graph callback" do
    {pid, task_supervisor} = start_orchestrator(tracker: SymphonyElixir.OrchestratorPlaneEpochSnapshotOnlyTracker)
    send(pid, :run_poll_cycle)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             state.plane_epoch_status == :failed and
               state.plane_epoch_error == {:dependency_graph_unavailable, :dependency_graph_unsupported}
           end)

    stop_orchestrator(pid, task_supervisor)
  end

  test "fails an epoch cleanly when a tracker has no project snapshot callback" do
    {pid, task_supervisor} = start_orchestrator(tracker: SymphonyElixir.OrchestratorPlaneEpochNoSnapshotTracker)
    send(pid, :run_poll_cycle)

    assert eventually(fn ->
             state = :sys.get_state(pid)

             state.plane_epoch_status == :failed and
               state.plane_epoch_error == {:project_snapshot_unavailable, :project_snapshot_unsupported}
           end)

    stop_orchestrator(pid, task_supervisor)
  end

  test "ignores stale epoch results and stale task exits after publication" do
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    send(pid, :run_poll_cycle)
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)

    state = :sys.get_state(pid)
    assert is_reference(state.plane_epoch_id)

    send(pid, {:plane_epoch_result, self(), make_ref(), make_ref(), nil, nil, %{status: :complete}})
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)

    monitor_ref = make_ref()
    :sys.replace_state(pid, fn state -> %{state | plane_epoch_task: %{monitor_ref: monitor_ref}} end)
    send(pid, {:DOWN, monitor_ref, :process, self(), :normal})
    assert eventually(fn -> is_nil(:sys.get_state(pid).plane_epoch_task) end)
    assert :sys.get_state(pid).plane_epoch_status == :current

    stop_orchestrator(pid, task_supervisor)
  end

  test "keeps malformed epoch metrics safe in dashboard snapshots" do
    {pid, task_supervisor} = start_orchestrator()

    :sys.replace_state(pid, fn state ->
      %{state | read_scheduler: nil, plane_epoch_metrics: %{epoch_id: :epoch_atom, logical_requests: -1, attempts: "bad"}}
    end)

    snapshot = Orchestrator.snapshot(pid, 1_000)
    assert snapshot.plane_epoch.metrics.epoch_id == "epoch_atom"
    assert snapshot.plane_epoch.metrics.logical_requests == 0
    assert snapshot.plane_epoch.metrics.attempts == 0
    assert is_nil(snapshot.plane_epoch.read_scheduler)

    :sys.replace_state(pid, fn state ->
      %{state | plane_epoch_metrics: %{epoch_id: {:opaque, :value}, finished_at: :invalid}}
    end)

    snapshot = Orchestrator.snapshot(pid, 1_000)
    assert snapshot.plane_epoch.metrics.epoch_id =~ "opaque"
    assert snapshot.plane_epoch.metrics.finished_at == "n/a"

    stop_orchestrator(pid, task_supervisor)
  end

  test "publishes epoch metrics when scheduler stats are unavailable" do
    for scheduler <- [nil, :missing_plane_read_scheduler] do
      {pid, task_supervisor} = start_orchestrator(startup_ready: true, read_scheduler: scheduler)
      send(pid, :run_poll_cycle)
      assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)

      snapshot = Orchestrator.snapshot(pid, 1_000)
      assert snapshot.plane_epoch.status == :current
      assert is_nil(snapshot.plane_epoch.read_scheduler)

      stop_orchestrator(pid, task_supervisor)
    end
  end

  test "defers Plane retries while an epoch is refreshing or lacks the retried node" do
    {pid, task_supervisor} = start_orchestrator()
    issue = OrchestratorPlaneEpochFakeTracker.issue()
    base_state = :sys.get_state(pid)

    refreshing_state = %{base_state | plane_epoch_status: :refreshing, dependency_graph: nil, work_control: %{}}

    deferred = Orchestrator.handle_retry_issue_lookup_for_test(issue, refreshing_state, issue.id, 1, %{})
    assert deferred.plane_epoch_status == :refreshing

    epoch = make_ref()
    complete_graph = Graph.build([], source: :plane, scope: %{project_id: "project-1"}, epoch: epoch, completeness: :complete)

    missing_node_state = %{
      base_state
      | plane_epoch_status: :current,
        plane_epoch_id: epoch,
        plane_epoch_task: nil,
        dependency_graph: complete_graph,
        work_control: %{}
    }

    deferred = Orchestrator.handle_retry_issue_lookup_for_test(issue, missing_node_state, issue.id, 1, %{})
    assert deferred.plane_epoch_id == epoch

    stop_orchestrator(pid, task_supervisor)
  end

  test "keeps active running work when missing issue confirmations fail" do
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    send(pid, :run_poll_cycle)
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"missing-running" => %{}}}
    end)

    for mode <- [:normal, :fail_missing_ids, :invalid_missing_ids] do
      previous_epoch = :sys.get_state(pid).plane_epoch_id
      Application.put_env(:symphony_elixir, :plane_epoch_test_mode, mode)
      send(pid, :run_poll_cycle)

      assert_receive {:unexpected_provider_id_read, _task, ["missing-running"]}, 2_000

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.plane_epoch_status == :current and state.plane_epoch_id != previous_epoch
             end)
    end

    state = :sys.get_state(pid)
    assert Map.has_key?(state.running, "missing-running")

    stop_orchestrator(pid, task_supervisor)
  end

  test "coalesces a blocked Plane epoch task and keeps snapshot calls responsive" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_project)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, task_pid, opts}, 1_000
    assert is_reference(Keyword.fetch!(opts, :epoch_id))
    assert Keyword.has_key?(opts, :request_metrics)

    send(pid, :tick)
    assert Orchestrator.snapshot(pid, 250).plane_epoch.status == :refreshing
    refute_receive {:plane_project_snapshot, _second_task, _second_opts}, 100

    send(task_pid, :release_project)
    stop_orchestrator(pid, task_supervisor)
  end

  test "rejects a config obsolete epoch and keeps the last graph" do
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    old_graph = OrchestratorPlaneEpochFakeTracker.graph(:old_epoch)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | dependency_graph: old_graph,
          plane_epoch_id: :old_epoch,
          plane_epoch_status: :current,
          plane_epoch_config_fingerprint: "old-config"
      }
    end)

    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_graph)
    send(pid, :tick)
    assert_receive {:plane_project_snapshot, _task_pid, _opts}, 1_000
    assert_receive {:plane_dependency_graph, task_pid, _opts}, 1_000

    plane_workflow!("project-2")
    send(task_pid, :release_graph)

    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :failed end)
    state = :sys.get_state(pid)
    assert state.dependency_graph == old_graph
    refute_receive {:fake_plane_agent_started, _agent_pid, _issue_id}, 100

    stop_orchestrator(pid, task_supervisor)
  end

  test "cancels an epoch task when only the provider contract changes" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_graph)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    old_graph = OrchestratorPlaneEpochFakeTracker.graph(:old_epoch)

    :sys.replace_state(pid, fn state ->
      %{state | dependency_graph: old_graph, plane_epoch_id: :old_epoch, plane_epoch_status: :current}
    end)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, _task_pid, _opts}, 1_000
    assert_receive {:plane_dependency_graph, graph_task_pid, _opts}, 1_000
    old_contract_fingerprint = :sys.get_state(pid).plane_epoch_task.contract_fingerprint

    plane_workflow!("project-1", " revised")
    send(pid, :tick)

    assert_receive {:plane_project_snapshot, _new_task_pid, _new_opts}, 1_000
    assert_receive {:plane_dependency_graph, new_graph_task_pid, _new_graph_opts}, 1_000

    state = :sys.get_state(pid)
    assert state.plane_epoch_task.contract_fingerprint != old_contract_fingerprint
    refute Process.alive?(graph_task_pid)

    send(new_graph_task_pid, :release_graph)
    assert_receive {:plane_project_snapshot, _closing_task, _opts}, 1_000
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :failed end)
    assert :sys.get_state(pid).dependency_graph == old_graph
    assert :sys.get_state(pid).plane_epoch_error == :provider_contract_not_validated
    stop_orchestrator(pid, task_supervisor)
  end

  test "does not publish the graph if the closing project snapshot fails" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :fail_closing_snapshot)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    old_graph = OrchestratorPlaneEpochFakeTracker.graph(:old_epoch)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | dependency_graph: old_graph,
          plane_epoch_id: :old_epoch,
          plane_epoch_status: :current
      }
    end)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, _opening_task, _opening_opts}, 1_000
    assert_receive {:plane_dependency_graph, _graph_task, _graph_opts}, 1_000
    assert_receive {:plane_project_snapshot, _closing_task, _closing_opts}, 1_000

    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :failed end)
    state = :sys.get_state(pid)
    assert state.dependency_graph == old_graph
    assert state.plane_epoch_error == {:project_snapshot_unavailable, :closing_project_snapshot_failed}
    stop_orchestrator(pid, task_supervisor)
  end

  test "clears a crashed Plane epoch task and fences dispatch" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :crash_project)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)

    assert eventually(fn ->
             state = :sys.get_state(pid)
             state.plane_epoch_status == :failed and is_nil(state.plane_epoch_task)
           end)

    refute Orchestrator.snapshot(pid, 250).plane_epoch.status == :current
    stop_orchestrator(pid, task_supervisor)
  end

  test "does not acquire a graph after a failed Plane project snapshot" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :fail_project)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, _snapshot_task, _snapshot_opts}, 1_000
    refute_receive {:plane_dependency_graph, _graph_task, _graph_opts}, 150

    assert eventually(fn ->
             state = :sys.get_state(pid)
             state.plane_epoch_status == :failed and is_nil(state.plane_epoch_task)
           end)

    stop_orchestrator(pid, task_supervisor)
  end

  test "rejects malformed and incomplete snapshots and invalid graph results" do
    cases = [
      {:invalid_project, :invalid_project_snapshot},
      {:incomplete_project, :project_snapshot_incomplete},
      {:fail_graph, {:dependency_graph_unavailable, :dependency_graph_failed}},
      {:invalid_graph, :invalid_dependency_graph},
      {:malformed_graph_result, :invalid_dependency_graph},
      {:incomplete_graph, :dependency_graph_incomplete},
      {:wrong_epoch_graph, :dependency_graph_epoch_mismatch},
      {:wrong_scope_graph, :dependency_graph_scope_mismatch}
    ]

    for {mode, expected_error} <- cases do
      Application.put_env(:symphony_elixir, :plane_epoch_test_mode, mode)
      Application.put_env(:symphony_elixir, :plane_epoch_snapshot_counter, :atomics.new(1, []))
      {pid, task_supervisor} = start_orchestrator(startup_ready: true)

      send(pid, :tick)

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.plane_epoch_status == :failed and is_nil(state.plane_epoch_task)
             end),
             "#{mode} state: #{inspect(Map.take(:sys.get_state(pid), [:plane_epoch_status, :plane_epoch_error]))}"

      assert :sys.get_state(pid).plane_epoch_error == expected_error
      stop_orchestrator(pid, task_supervisor)
    end
  end

  test "builds list-returning graph adapters once and records their SCC pass" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :list_graph)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)

    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)
    metrics = Orchestrator.snapshot(pid, 250).plane_epoch.metrics
    assert metrics.scc_pass_count == 1
    assert metrics.item_count == 1

    stop_orchestrator(pid, task_supervisor)
  end

  test "rejects malformed and failed task result envelopes" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_project)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, task_pid, _opts}, 1_000

    state = :sys.get_state(pid)
    task = state.plane_epoch_task
    cancelled_result = %{status: :cancelled, reason: :injected_cancel}

    results = [
      {%{status: :failed, reason: :injected_failure}, :injected_failure},
      {cancelled_result, {:invalid_result, cancelled_result}},
      {:malformed_result, {:invalid_result, :malformed_result}}
    ]

    for {result, expected_error} <- results do
      assert {:noreply, rejected_state} =
               Orchestrator.handle_info(
                 {:plane_epoch_result, task.pid, task.task_ref, task.epoch_id, task.config_fingerprint, task.contract_fingerprint, result},
                 state
               )

      assert rejected_state.plane_epoch_status == :failed
      assert rejected_state.plane_epoch_error == expected_error
    end

    send(task_pid, :release_project)
    assert_receive {:plane_dependency_graph, _graph_task_pid, _graph_opts}, 1_000
    assert_receive {:plane_project_snapshot, closing_task_pid, _closing_opts}, 1_000
    send(closing_task_pid, :release_project)
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)
    stop_orchestrator(pid, task_supervisor)
  end

  test "rejects incomplete and malformed published epoch candidates" do
    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :block_project)
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    send(pid, :tick)
    assert_receive {:plane_project_snapshot, task_pid, _opts}, 1_000
    state = :sys.get_state(pid)
    task = state.plane_epoch_task
    config = Config.settings!()
    complete_snapshot = {:ok, OrchestratorPlaneEpochFakeTracker.project_snapshot()}

    complete_graph =
      Graph.build([OrchestratorPlaneEpochFakeTracker.issue()],
        source: :plane,
        scope: Tracker.identity(config.tracker).provider_scope,
        epoch: task.epoch_id,
        completeness: :complete
      )

    incomplete_graph = %{complete_graph | completeness: {:incomplete, :test}}
    incomplete_snapshot = {:ok, %{completeness: :incomplete}}

    cases = [
      {%{project_snapshot: incomplete_snapshot, dependency_graph: {:ok, complete_graph}}, :project_snapshot_incomplete},
      {%{project_snapshot: :invalid, dependency_graph: {:ok, complete_graph}}, :invalid_project_snapshot},
      {%{project_snapshot: complete_snapshot, dependency_graph: {:ok, incomplete_graph}}, :dependency_graph_incomplete},
      {%{project_snapshot: complete_snapshot, dependency_graph: {:ok, :invalid}}, :invalid_dependency_graph},
      {%{project_snapshot: complete_snapshot, dependency_graph: :invalid}, :invalid_dependency_graph}
    ]

    for {candidate, expected_error} <- cases do
      result =
        Map.merge(candidate, %{
          status: :complete,
          request_metrics: task.request_metrics,
          metrics: %{epoch_id: task.epoch_id, started_at: task.started_at}
        })

      assert {:noreply, rejected_state} = deliver_epoch_result(state, task, result)
      assert rejected_state.plane_epoch_error == expected_error
    end

    state_without_contract = %{state | project_contract_evidence: nil}

    valid_result =
      Map.merge(
        %{project_snapshot: complete_snapshot, dependency_graph: {:ok, complete_graph}},
        %{status: :complete, request_metrics: task.request_metrics, metrics: %{epoch_id: task.epoch_id}}
      )

    assert {:noreply, rejected_state} =
             deliver_epoch_result(state_without_contract, task, valid_result)

    assert rejected_state.plane_epoch_error == :provider_contract_not_validated

    Application.put_env(:symphony_elixir, :plane_epoch_test_mode, :normal)
    send(task_pid, :release_project)
    assert eventually(fn -> :sys.get_state(pid).plane_epoch_status == :current end)
    stop_orchestrator(pid, task_supervisor)
  end

  defp deliver_epoch_result(state, task, result) do
    Orchestrator.handle_info(
      {:plane_epoch_result, task.pid, task.task_ref, task.epoch_id, task.config_fingerprint, task.contract_fingerprint, result},
      state
    )
  end

  test "dispatches from closing graph nodes without an extra Plane issue GET" do
    {pid, task_supervisor} = start_orchestrator(startup_ready: true)
    send(pid, :tick)

    assert_receive {:plane_project_snapshot, _snapshot_task, _snapshot_opts}, 1_000
    assert_receive {:plane_dependency_graph, _graph_task, _graph_opts}, 1_000
    assert_receive {:plane_project_snapshot, _closing_snapshot_task, _closing_snapshot_opts}, 1_000

    assert eventually(fn -> Map.has_key?(:sys.get_state(pid).running, "plane-epoch-issue") end, 100),
           "epoch dispatch state: #{inspect(Map.take(:sys.get_state(pid), [:startup_reconciliation, :plane_epoch_status, :plane_epoch_error, :attempt_ledger_status, :recovery_ledger_status, :workspace_ownership_ledger_status, :project_contract_evidence, :dependency_diagnostics, :work_control, :running, :blocked]))}"

    assert_receive {:fake_plane_agent_started, agent_pid, "plane-epoch-issue"},
                   2_000,
                   "epoch dispatch state: #{inspect(Map.take(:sys.get_state(pid), [:startup_reconciliation, :plane_epoch_status, :plane_epoch_error, :attempt_ledger_status, :recovery_ledger_status, :workspace_ownership_ledger_status, :project_contract_evidence, :dependency_diagnostics, :work_control, :running, :blocked]))}"

    refute_receive {:unexpected_provider_state_read, _provider_pid}, 100
    refute_receive {:unexpected_provider_id_read, _provider_pid, _ids}, 100

    epoch_metrics = Orchestrator.snapshot(pid, 250).plane_epoch.metrics
    assert epoch_metrics.scc_pass_count == 1
    assert epoch_metrics.epoch_id != "n/a"
    assert is_binary(epoch_metrics.started_at)
    assert is_binary(epoch_metrics.finished_at)

    send(agent_pid, :release_agent)
    stop_orchestrator(pid, task_supervisor)
  end

  @tag timeout: 120_000
  test "measures 1,000-item work-control publication with the recovery ledger enabled" do
    root = Path.join(System.tmp_dir!(), "symphony-plane-epoch-recovery-#{System.unique_integer([:positive])}")
    path = Path.join(root, "recovery.dets")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    config = Config.settings!()

    {:ok, recovery_ledger} =
      RecoveryLedger.open(
        config.symphony.project_id,
        Tracker.identity(config.tracker),
        path: path
      )

    {pid, task_supervisor} = start_orchestrator(startup_ready: true)

    :sys.replace_state(pid, fn state ->
      %{state | recovery_ledger: recovery_ledger, recovery_ledger_status: :ready, recovery_checkpoints: %{}}
    end)

    issues =
      Enum.map(1..1_000, fn index ->
        issue = OrchestratorPlaneEpochFakeTracker.issue()

        %{
          issue
          | id: "plane-scale-#{index}",
            identifier: "PLANE-#{index}",
            state: "Backlog",
            provider_state_id: "state-backlog",
            provider_state_group: :backlog
        }
      end)

    started_at_ms = System.monotonic_time(:millisecond)

    state =
      :sys.replace_state(
        pid,
        fn state -> Orchestrator.refresh_work_control_for_test(state, issues) end,
        120_000
      )

    elapsed_ms = max(System.monotonic_time(:millisecond) - started_at_ms, 0)
    assert state.recovery_ledger_status == :ready
    assert {:ok, checkpoints} = RecoveryLedger.list(recovery_ledger)
    assert length(checkpoints) == 1_000

    IO.puts("H-070A recovery ledger publication items=1000 checkpoints=1000 elapsed_ms=#{elapsed_ms}")

    stop_orchestrator(pid, task_supervisor)
  end

  defp start_orchestrator(opts \\ []) do
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    name = Module.concat(__MODULE__, "Orchestrator#{System.unique_integer([:positive])}")

    start_opts = [
      name: name,
      start_quiesced: true,
      tracker: Keyword.get(opts, :tracker, OrchestratorPlaneEpochFakeTracker),
      read_scheduler: Keyword.get(opts, :read_scheduler, SymphonyElixir.Plane.ReadScheduler),
      agent_runner: SymphonyElixir.OrchestratorPlaneEpochFakeRunner,
      task_supervisor: task_supervisor,
      work_control: %{"plane-epoch-issue" => valid_work_item()},
      attempt_ledger_status: :disabled,
      recovery_ledger_status: :disabled
    ]

    {:ok, pid} = Orchestrator.start_link(start_opts)

    :sys.replace_state(pid, fn state ->
      %{state | attempt_ledger_status: :disabled, recovery_ledger_status: :disabled}
    end)

    if Keyword.get(opts, :startup_ready, false) do
      :sys.replace_state(pid, fn state -> %{state | startup_reconciliation: :ready} end)
    end

    on_exit(fn -> stop_orchestrator(pid, task_supervisor) end)

    {pid, task_supervisor}
  end

  defp valid_work_item do
    issue = OrchestratorPlaneEpochFakeTracker.issue()
    {:ok, observation} = ProviderObservation.from_issue(issue, %{provider: "plane"})

    assessment = %LifecycleAssessment{
      work_item_id: issue.id,
      provider_observation: observation,
      mapped_state: :ready,
      validated_state: :ready,
      status: :validated,
      required_guards: [],
      satisfied_guards: [],
      missing_guards: [],
      reason: nil,
      assessed_at: DateTime.utc_now()
    }

    %WorkItem{
      id: issue.id,
      native_ref: issue.native_ref,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description,
      priority: issue.priority,
      branch_name: issue.branch_name,
      url: issue.url,
      assignee_id: issue.assignee_id,
      labels: issue.labels,
      created_at: issue.created_at,
      updated_at: issue.updated_at,
      provider_observation: observation,
      lifecycle_assessment: assessment,
      validated_lifecycle_state: :ready,
      authority_disposition: AuthorityDisposition.derive(assessment),
      suspension_context: nil,
      blocked_by: issue.blocked_by,
      dependency_completeness: issue.dependency_completeness
    }
  end

  defp stop_orchestrator(pid, task_supervisor) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    if Process.alive?(task_supervisor), do: GenServer.stop(task_supervisor)
  end

  defp plane_workflow!(project_id, contract_state_id_suffix \\ "") do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-plane-epoch-workspaces")

    provider = %{
      "workspace_slug" => "workspace-1",
      "workspace_id" => "workspace-stable-1",
      "project_id" => project_id,
      "api_key" => "$PLANE_API_KEY"
    }

    contract = %{
      "schema_version" => 1,
      "provider" => "plane",
      "workspace_id" => "workspace-stable-1",
      "project_id" => project_id,
      "state_mappings" =>
        Map.new(WorkflowLifecycle.states(), fn state ->
          {Atom.to_string(state), %{"state_id" => "state-#{state}#{contract_state_id_suffix}", "name" => WorkflowLifecycle.display(state)}}
        end)
    }

    workflow = """
    ---
    provider_project_contract: #{Jason.encode!(contract)}
    tracker:
      kind: "plane"
      provider: #{Jason.encode!(provider)}
      active_states: ["Ready"]
      terminal_states: ["Done"]
    symphony:
      project_id: "plane-epoch-test"
    polling:
      interval_ms: 30000
    workspace:
      root: #{inspect(workspace_root)}
    agent:
      routing: "routed"
      max_concurrent_agents: 1
      max_turns: 1
    source_control:
      kind: "github"
      repository: "octo/symphony"
      repository_id: 1368436395
      base_branch: "main"
      token_env: "GITHUB_TOKEN"
      required_checks:
        - context: "make-all"
          app_id: 15368
          subject: "head"
    ---
    You are an agent for this repository.
    """

    File.write!(Workflow.workflow_file_path(), workflow)
    WorkflowStore.force_reload()
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
