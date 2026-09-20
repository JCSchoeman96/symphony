defmodule SymphonyElixir.FullProofCodexRuntime do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(workspace, opts) do
    session_id = "codex-proof-#{System.unique_integer([:positive])}"
    test_pid = Keyword.fetch!(opts, :test_pid)

    send(test_pid, {:proof_session_started, session_id, workspace, opts})
    {:ok, %{session_id: session_id, test_pid: test_pid}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, issue, _opts) do
    send(session.test_pid, {:proof_turn, session.session_id, issue.state, prompt})

    {:ok,
     %{
       session_id: session.session_id,
       thread_id: session.session_id,
       turn_id: "turn-#{System.unique_integer([:positive])}"
     }}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, {:proof_session_stopped, session.session_id})
    :ok
  end
end

defmodule SymphonyElixir.FullProofDagRunner do
  alias SymphonyElixir.Tracker.Issue

  @capture_name :symphony_full_proof_dag_capture

  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(%Issue{} = issue, _recipient, opts) do
    capture = Process.whereis(@capture_name)
    issue_id = issue.id

    if is_pid(capture) do
      send(capture, {:dag_started, issue_id, issue.identifier, issue.state, opts, self()})
    end

    receive do
      {:dag_complete, ^issue_id} ->
        if is_pid(capture), do: send(capture, {:dag_finished, issue_id})
        :ok
    after
      30_000 ->
        if is_pid(capture), do: send(capture, {:dag_timeout, issue_id})
        :ok
    end
  end
end

defmodule SymphonyElixir.AgentRouterDependencyProofTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.Dependency.{Graph, Guard}
  alias SymphonyElixir.WorkControl.{GuardClass, WorkflowLifecycle, WorkItem}

  @dag_capture :symphony_full_proof_dag_capture

  test "SYM-14 proves the complete Codex role lifecycle with fresh sessions" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: [
        "Planning",
        "Ready",
        "In Progress",
        "In Review",
        "Changes Requested",
        "Ready to Merge"
      ],
      max_turns: 2
    )

    issue = %Issue{
      id: "lifecycle-proof",
      identifier: "SYM-LIFECYCLE-PROOF",
      title: "Disposable lifecycle proof",
      description: "Prove the role boundaries without enabling automatic merge.",
      dispatchable: true
    }

    stages = [
      {"Planning", "planner", "planning", "read-only", ["Ready"], :plan_recorded},
      {"Ready", "builder", "implementation", "workspace-write", ["In Progress", "In Review"], :pull_request_updated},
      {"In Review", "reviewer", "review", "read-only", ["Changes Requested"], :review_verdict_recorded},
      {"Changes Requested", "fixer", "correction", "workspace-write", ["In Review"], :review_findings_applied},
      {"In Review", "reviewer", "review", "read-only", ["Ready to Merge"], :updated_head_re_reviewed}
    ]

    stage_evidence =
      Enum.map(stages, fn {state, profile_name, responsibility, sandbox, refreshed_states, evidence} ->
        stage_issue = %{issue | state: state}

        {:ok, work_item} =
          WorkItem.from_issue(stage_issue, %{
            provider: :memory,
            observed_at: DateTime.utc_now(),
            prior_validated_lifecycle_state: state
          })

        assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)
        assert route.profile_name == profile_name
        assert route.responsibility == responsibility
        assert route.runtime_name == "codex"

        assert :ok =
                 AgentRunner.run(stage_issue, test_pid,
                   runtime: SymphonyElixir.FullProofCodexRuntime,
                   test_pid: test_pid,
                   route: route,
                   work_item: work_item,
                   guard_evidence: transition_evidence([state | refreshed_states], stage_issue.id),
                   assessment_context: %{
                     runtime_attempt_id: "attempt-#{stage_issue.id}",
                     lineage_generation: 1
                   },
                   issue_state_fetcher: sequence_fetcher(stage_issue, refreshed_states)
                 )

        assert_receive {:proof_session_started, session_id, workspace, start_opts}, 1_000
        assert is_binary(workspace)
        assert start_opts[:profile].name == profile_name
        assert start_opts[:sandbox] == sandbox
        assert_receive {:worker_runtime_info, "lifecycle-proof", _runtime_info}, 1_000

        turn_states = [state | Enum.take(refreshed_states, max(length(refreshed_states) - 1, 0))]

        {session_id, turns, session_ids} =
          Enum.reduce(turn_states, {session_id, [], [session_id]}, fn expected_state, {current_session, turns, session_ids} ->
            {next_session, refreshed_state, prompt} =
              receive_proof_turn(current_session, expected_state)

            assert is_binary(prompt)

            next_session_ids =
              if next_session == current_session,
                do: session_ids,
                else: session_ids ++ [next_session]

            {next_session, turns ++ [{refreshed_state, prompt}], next_session_ids}
          end)

        if List.last(refreshed_states) == "Ready to Merge" do
          assert_receive {:agent_lifecycle_suspended, "lifecycle-proof", assessment}, 1_000
          assert assessment.status == :validated
          refute_receive {:agent_route_changed, "lifecycle-proof", _previous_route, _next_route}, 100
        else
          assert_receive {:agent_route_changed, "lifecycle-proof", previous_route, next_route}, 1_000
          assert previous_route.fingerprint == route.fingerprint
          assert next_route.starting_state == List.last(refreshed_states) |> String.downcase()
        end

        assert_receive {:proof_session_stopped, ^session_id}, 1_000

        %{
          state: state,
          profile: profile_name,
          responsibility: responsibility,
          sandbox: sandbox,
          session_ids: session_ids,
          turns: turns,
          route_fingerprint: route.fingerprint,
          evidence: evidence
        }
      end)

    assert Enum.map(stage_evidence, & &1.profile) == [
             "planner",
             "builder",
             "reviewer",
             "fixer",
             "reviewer"
           ]

    assert Enum.map(stage_evidence, & &1.responsibility) == [
             "planning",
             "implementation",
             "review",
             "correction",
             "review"
           ]

    assert Enum.map(stage_evidence, & &1.sandbox) == [
             "read-only",
             "workspace-write",
             "read-only",
             "workspace-write",
             "read-only"
           ]

    assert Enum.map(stage_evidence, &length(&1.session_ids)) == [1, 2, 1, 1, 1]
    assert length(Enum.uniq(Enum.flat_map(stage_evidence, & &1.session_ids))) == 6
    assert Enum.at(stage_evidence, 1).turns |> length() == 2
    assert Enum.count(stage_evidence, &(&1.profile == "reviewer")) <= 3

    assert Enum.map(stage_evidence, & &1.evidence) == [
             :plan_recorded,
             :pull_request_updated,
             :review_verdict_recorded,
             :review_findings_applied,
             :updated_head_re_reviewed
           ]

    Enum.each(stage_evidence, fn %{profile: profile, turns: turns} ->
      assert Enum.all?(turns, fn {_state, prompt} ->
               String.contains?(prompt, "Role policy: #{profile}")
             end)
    end)

    planner_prompt = stage_evidence |> Enum.at(0) |> Map.fetch!(:turns) |> List.first() |> elem(1)
    builder_prompt = stage_evidence |> Enum.at(1) |> Map.fetch!(:turns) |> List.first() |> elem(1)

    reviewer_prompt =
      stage_evidence |> Enum.at(2) |> Map.fetch!(:turns) |> List.first() |> elem(1)

    fixer_prompt = stage_evidence |> Enum.at(3) |> Map.fetch!(:turns) |> List.first() |> elem(1)

    assert planner_prompt =~ "Do not modify production source"
    assert builder_prompt =~ "Do not self-review, approve, or merge"
    assert reviewer_prompt =~ "Do not modify source, push fixes, approve work, or merge"
    assert fixer_prompt =~ "Do not approve your own changes or merge"

    merge_issue = %{issue | state: "Ready to Merge"}

    {:ok, merge_work_item} =
      WorkItem.from_issue(merge_issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: merge_issue.state
      })

    assert {:error, :authority_unavailable} = Router.resolve(merge_work_item, Config.settings!().agent.profiles)
    refute Config.settings!().agent.profiles["merge_gatekeeper"].command
    refute Map.has_key?(Map.from_struct(Config.settings!().agent), :auto_merge)
  end

  defp receive_proof_turn(session_id, expected_state) do
    receive do
      {:proof_turn, ^session_id, ^expected_state, prompt} ->
        {session_id, expected_state, prompt}

      {:proof_session_stopped, ^session_id} ->
        assert_receive {:proof_session_started, next_session, _workspace, _start_opts}, 1_000
        assert_receive {:proof_turn, ^next_session, ^expected_state, prompt}, 1_000
        {next_session, expected_state, prompt}
    after
      1_000 ->
        flunk("timed out waiting for proof turn #{expected_state}")
    end
  end

  test "SYM-15 proves the dependency frontier, unlocks, cancellation safety, and cycle refusal" do
    test_pid = self()
    Process.register(test_pid, @dag_capture)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      max_concurrent_agents: 10,
      poll_interval_ms: 60_000
    )

    issues = dag_issues()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)

    orchestrator_name =
      Module.concat(__MODULE__, "DagOrchestrator#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        agent_runner: SymphonyElixir.FullProofDagRunner,
        work_control: trusted_work_control(issues)
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if Process.whereis(@dag_capture) == test_pid, do: Process.unregister(@dag_capture)
    end)

    initial = receive_dispatches(2)
    assert Enum.map(initial, &elem(&1, 0)) == ["dag-a", "dag-independent"]

    assert Enum.all?(initial, fn {_id, _identifier, _state, opts, _worker_pid} ->
             opts[:route].profile_name == "builder"
           end)

    refute_receive {:dag_started, "dag-b", _identifier, _state, _opts, _worker_pid}, 100
    refute_receive {:dag_started, "dag-c", _identifier, _state, _opts, _worker_pid}, 100

    refute_receive {:dag_started, "dag-canceled-dependent", _identifier, _state, _opts, _worker_pid},
                   100

    refute_receive {:dag_started, "dag-cycle-a", _identifier, _state, _opts, _worker_pid}, 100

    updated_issues = put_dag_issues(issues, a: "Done", independent: "Done", a_blocker: "Done")
    put_completed_work_items!(pid, updated_issues)
    finish_dispatched!(pid, initial)
    trigger_poll!(pid)

    second = receive_dispatches(2)
    assert Enum.map(second, &elem(&1, 0)) == ["dag-b", "dag-c"]

    updated_issues =
      put_dag_issues(
        issues,
        a: "Done",
        independent: "Done",
        b: "Done",
        c: "Done",
        a_blocker: "Done",
        b_blocker: "Done",
        c_blocker: "Done"
      )

    put_completed_work_items!(pid, updated_issues)

    finish_dispatched!(pid, second)
    trigger_poll!(pid)

    third = receive_dispatches(4)
    assert Enum.map(third, &elem(&1, 0)) == ["dag-d", "dag-e", "dag-f", "dag-g"]

    updated_issues =
      put_dag_issues(
        issues,
        a: "Done",
        independent: "Done",
        b: "Done",
        c: "Done",
        d: "Done",
        e: "Done",
        f: "Done",
        a_blocker: "Done",
        b_blocker: "Done",
        c_blocker: "Done",
        f_blocker: "Done"
      )

    put_completed_work_items!(pid, updated_issues)

    finish_dispatched!(pid, Enum.take(third, 3))
    trigger_poll!(pid)

    refute_receive {:dag_started, "dag-h", _identifier, _state, _opts, _worker_pid}, 100

    updated_issues =
      put_dag_issues(
        issues,
        a: "Done",
        independent: "Done",
        b: "Done",
        c: "Done",
        d: "Done",
        e: "Done",
        f: "Done",
        g: "Done",
        a_blocker: "Done",
        b_blocker: "Done",
        c_blocker: "Done",
        f_blocker: "Done",
        g_blocker: "Done"
      )

    put_completed_work_items!(pid, updated_issues)

    finish_dispatched!(pid, [List.last(third)])
    trigger_poll!(pid)

    [final] = receive_dispatches(1)
    assert elem(final, 0) == "dag-h"

    updated_issues =
      put_dag_issues(
        issues,
        a: "Done",
        independent: "Done",
        b: "Done",
        c: "Done",
        d: "Done",
        e: "Done",
        f: "Done",
        g: "Done",
        h: "Done",
        a_blocker: "Done",
        b_blocker: "Done",
        c_blocker: "Done",
        f_blocker: "Done",
        g_blocker: "Done"
      )

    put_completed_work_items!(pid, updated_issues)

    finish_dispatched!(pid, [final])

    assert_eventually(fn ->
      snapshot = GenServer.call(pid, :snapshot, 100)
      snapshot.running == [] and snapshot.retrying == []
    end)

    snapshot = GenServer.call(pid, :snapshot, 100)
    assert snapshot.dependency_graph.cycles == [["dag-cycle-a", "dag-cycle-b", "dag-cycle-c"]]

    diagnostics = Map.new(snapshot.dependency_diagnostics, &{&1.identifier, &1})
    assert diagnostics["SYM-CANCELED-DEPENDENT"].reason == :invalidated_dependency
    assert diagnostics["SYM-CYCLE-A"].reason == :dependency_cycle
    assert diagnostics["SYM-CYCLE-B"].reason == :dependency_cycle
    assert diagnostics["SYM-CYCLE-C"].reason == :dependency_cycle

    all_dispatches = initial ++ second ++ third ++ [final]
    dispatch_ids = Enum.map(all_dispatches, &elem(&1, 0))
    assert dispatch_ids == Enum.uniq(dispatch_ids)

    assert dispatch_ids == [
             "dag-a",
             "dag-independent",
             "dag-b",
             "dag-c",
             "dag-d",
             "dag-e",
             "dag-f",
             "dag-g",
             "dag-h"
           ]

    assert Guard.evaluate(
             %Issue{
               id: "proof",
               identifier: "SYM-PROOF",
               state: "Ready",
               blocked_by: [%{id: "canceled", state: "Canceled"}]
             },
             "implementation"
           ).allowed? == false

    graph = Graph.build(issues)
    assert Graph.cycles(graph) == [["dag-cycle-a", "dag-cycle-b", "dag-cycle-c"]]
  end

  defp sequence_fetcher(issue, states) do
    {:ok, agent} = Agent.start_link(fn -> states end)

    fn [_issue_id] ->
      Agent.get_and_update(agent, fn
        [next_state | remaining] ->
          {{:ok, [%{issue | state: next_state}]}, remaining}

        [] ->
          {{:ok, [%{issue | state: List.last(states)}]}, []}
      end)
    end
  end

  defp transition_evidence(states, work_item_id) do
    states
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [source, target] ->
      {:ok, metadata} = WorkflowLifecycle.transition(source, target)

      Enum.map(metadata.guard_requirements, fn
        %{class: :semantic_attestation, name: name} ->
          {:ok, evidence} =
            GuardClass.semantic_attestation(name, %{
              responsibility: metadata.responsibility,
              runtime_attempt_id: "attempt-#{work_item_id}",
              lineage_generation: 1,
              subject: {:work_item, work_item_id},
              timestamp: DateTime.utc_now()
            })

          evidence

        requirement ->
          requirement
      end)
    end)
  end

  defp trusted_work_control(issues) when is_list(issues) do
    Map.new(issues, fn issue -> {issue.id, trusted_work_item(issue)} end)
  end

  defp trusted_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    work_item
  end

  defp put_completed_work_items!(pid, issues) when is_pid(pid) and is_list(issues) do
    completed =
      issues
      |> Enum.filter(&(&1.state == "Done"))
      |> Map.new(fn issue -> {issue.id, completed_work_item(issue)} end)

    :sys.replace_state(pid, fn state ->
      %{state | work_control: Map.merge(state.work_control, completed)}
    end)
  end

  defp completed_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: "Merging",
        evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
      })

    work_item
  end

  defp dag_issues do
    issue = fn {id, identifier, blockers} ->
      %Issue{
        id: id,
        identifier: identifier,
        title: identifier,
        state: "Ready",
        dispatchable: true,
        blocked_by: blockers
      }
    end

    [
      issue.({"dag-a", "SYM-A", []}),
      issue.({"dag-b", "SYM-B", [%{id: "dag-a", identifier: "SYM-A", state: "Ready"}]}),
      issue.({"dag-c", "SYM-C", [%{id: "dag-a", identifier: "SYM-A", state: "Ready"}]}),
      issue.({"dag-d", "SYM-D", [%{id: "dag-b", identifier: "SYM-B", state: "Ready"}]}),
      issue.({"dag-e", "SYM-E", [%{id: "dag-b", identifier: "SYM-B", state: "Ready"}]}),
      issue.({"dag-f", "SYM-F", [%{id: "dag-c", identifier: "SYM-C", state: "Ready"}]}),
      issue.({"dag-g", "SYM-G", [%{id: "dag-c", identifier: "SYM-C", state: "Ready"}]}),
      issue.(
        {"dag-h", "SYM-H",
         [
           %{id: "dag-f", identifier: "SYM-F", state: "Ready"},
           %{id: "dag-g", identifier: "SYM-G", state: "Ready"}
         ]}
      ),
      issue.({"dag-independent", "SYM-INDEPENDENT", []}),
      %{issue.({"dag-canceled", "SYM-CANCELED", []}) | state: "Canceled", dispatchable: false},
      issue.({"dag-canceled-dependent", "SYM-CANCELED-DEPENDENT", [%{id: "dag-canceled", identifier: "SYM-CANCELED", state: "Canceled"}]}),
      issue.({"dag-cycle-a", "SYM-CYCLE-A", [%{id: "dag-cycle-b", identifier: "SYM-CYCLE-B", state: "Ready"}]}),
      issue.({"dag-cycle-b", "SYM-CYCLE-B", [%{id: "dag-cycle-c", identifier: "SYM-CYCLE-C", state: "Ready"}]}),
      issue.({"dag-cycle-c", "SYM-CYCLE-C", [%{id: "dag-cycle-a", identifier: "SYM-CYCLE-A", state: "Ready"}]})
    ]
  end

  defp put_dag_issues(issues, changes) do
    updated_issues =
      Enum.map(issues, fn issue ->
        state = dag_state_override(issue.id, changes)
        blockers = update_dag_blocker_states(issue.blocked_by, changes)
        %{issue | state: state, blocked_by: blockers}
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated_issues)
    updated_issues
  end

  defp dag_state_override("dag-a", changes), do: Keyword.get(changes, :a, "Ready")
  defp dag_state_override("dag-b", changes), do: Keyword.get(changes, :b, "Ready")
  defp dag_state_override("dag-c", changes), do: Keyword.get(changes, :c, "Ready")
  defp dag_state_override("dag-d", changes), do: Keyword.get(changes, :d, "Ready")
  defp dag_state_override("dag-e", changes), do: Keyword.get(changes, :e, "Ready")
  defp dag_state_override("dag-f", changes), do: Keyword.get(changes, :f, "Ready")
  defp dag_state_override("dag-g", changes), do: Keyword.get(changes, :g, "Ready")
  defp dag_state_override("dag-h", changes), do: Keyword.get(changes, :h, "Ready")

  defp dag_state_override("dag-independent", changes),
    do: Keyword.get(changes, :independent, "Ready")

  defp dag_state_override(_issue_id, _changes), do: "Ready"

  defp update_dag_blocker_states(blockers, changes) do
    Enum.map(blockers, fn blocker ->
      state_key = blocker_state_key(blocker.id)
      Map.put(blocker, :state, Keyword.get(changes, state_key, blocker.state))
    end)
  end

  defp blocker_state_key("dag-a"), do: :a_blocker
  defp blocker_state_key("dag-b"), do: :b_blocker
  defp blocker_state_key("dag-c"), do: :c_blocker
  defp blocker_state_key("dag-d"), do: :d_blocker
  defp blocker_state_key("dag-e"), do: :e_blocker
  defp blocker_state_key("dag-f"), do: :f_blocker
  defp blocker_state_key("dag-g"), do: :g_blocker
  defp blocker_state_key("dag-canceled"), do: :canceled_blocker
  defp blocker_state_key("dag-cycle-a"), do: :cycle_a_blocker
  defp blocker_state_key("dag-cycle-b"), do: :cycle_b_blocker
  defp blocker_state_key("dag-cycle-c"), do: :cycle_c_blocker
  defp blocker_state_key(_blocker_id), do: :unknown_blocker

  defp receive_dispatches(count), do: Enum.map(1..count, fn _ -> receive_dispatch() end)

  defp receive_dispatch do
    assert_receive {:dag_started, issue_id, identifier, state, opts, worker_pid}, 1_000
    {issue_id, identifier, state, opts, worker_pid}
  end

  defp finish_dispatched!(orchestrator_pid, dispatches) do
    Enum.each(dispatches, fn {issue_id, _identifier, _state, _opts, worker_pid} ->
      send(worker_pid, {:dag_complete, issue_id})
    end)

    Enum.each(dispatches, fn {issue_id, _identifier, _state, _opts, _worker_pid} ->
      assert_receive {:dag_finished, ^issue_id}, 1_000
    end)

    Enum.each(dispatches, fn {issue_id, _identifier, _state, _opts, _worker_pid} ->
      trigger_retry!(orchestrator_pid, issue_id)
    end)
  end

  defp trigger_poll!(pid) do
    send(pid, :run_poll_cycle)

    assert_eventually(fn ->
      state = :sys.get_state(pid)
      state.poll_check_in_progress == false
    end)
  end

  defp trigger_retry!(pid, issue_id) do
    assert_eventually(fn ->
      state = :sys.get_state(pid)
      is_map(Map.get(state.retry_attempts, issue_id))
    end)

    retry_token = :sys.get_state(pid).retry_attempts[issue_id].retry_token
    send(pid, {:retry_issue, issue_id, retry_token})

    assert_eventually(fn ->
      state = :sys.get_state(pid)

      not Map.has_key?(state.retry_attempts, issue_id) and
        not MapSet.member?(state.claimed, issue_id)
    end)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in proof window")
end
