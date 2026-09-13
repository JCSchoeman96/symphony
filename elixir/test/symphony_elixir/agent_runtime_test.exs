defmodule SymphonyElixir.AgentRuntimeTestFake do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(workspace, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_started, workspace, opts})
    {:ok, %{session_id: "fake-session", workspace: workspace, test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, issue, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_turn, session, prompt, issue})
    {:ok, %{session_id: session.session_id, thread_id: "fake-thread", turn_id: "fake-turn"}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, {:runtime_stopped, session})
    :ok
  end
end

defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Codex, Router}

  test "Codex runtime delegates invalid startup and turn calls to AppServer" do
    assert {:error, _reason} =
             Codex.start_session(Path.join(System.tmp_dir!(), "symphony-runtime-outside-default-#{System.unique_integer()}"))

    assert {:error, _reason} =
             Codex.start_session(
               Path.join(System.tmp_dir!(), "symphony-runtime-outside-#{System.unique_integer()}"),
               worker_host: nil
             )

    assert_raise FunctionClauseError, fn ->
      Codex.run_turn(%{}, "prompt", %Issue{})
    end
  end

  test "AgentRunner executes an injected runtime through the runtime contract" do
    test_pid = self()
    issue = %Issue{id: "runtime-contract", identifier: "SYM-RUNTIME", title: "Runtime contract", state: "In Progress"}

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               max_turns: 1,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
             )

    assert_receive {:runtime_started, workspace, opts}
    assert is_binary(workspace)
    assert opts[:test_pid] == test_pid
    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
  end

  test "AgentRunner terminates a session when the refreshed state changes its route" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Planning", "Ready"],
      max_turns: 2
    )

    issue = %Issue{
      id: "route-change",
      identifier: "SYM-ROUTE",
      title: "Route change",
      state: "Planning",
      dispatchable: true
    }

    profiles = Config.settings!().agent.profiles
    assert {:ok, initial_route} = Router.resolve(issue, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: initial_route,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Ready"}]} end
             )

    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:agent_route_changed, "route-change", ^initial_route, new_route}
    assert new_route.profile_name == "builder"
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
  end

  test "AgentRunner continues when a state refresh keeps the same route" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "same-route",
      identifier: "SYM-SAME",
      title: "Same route",
      state: "Ready",
      dispatchable: true
    }

    profiles = Config.settings!().agent.profiles
    assert {:ok, initial_route} = Router.resolve(issue, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: initial_route,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Progress"}]} end
             )

    assert_receive {:runtime_turn, _session, _first_prompt, %{state: "Ready"}}
    assert_receive {:runtime_turn, _session, _second_prompt, %{state: "In Progress"}}
    refute_receive {:agent_route_changed, "same-route", _previous_route, _next_route}, 50
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
  end

  test "AgentRunner stops when a refreshed implementation becomes dependency-blocked" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "dependency-change",
      identifier: "SYM-DEPENDENCY",
      title: "Dependency change",
      state: "In Progress",
      dispatchable: true
    }

    profiles = Config.settings!().agent.profiles
    assert {:ok, route} = Router.resolve(issue, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               issue_state_fetcher: fn [_issue_id] ->
                 {:ok,
                  [
                    %{
                      issue
                      | blocked_by: [%{id: "new-blocker", identifier: "SYM-BLOCKER", state: "Ready"}]
                    }
                  ]}
               end
             )

    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:agent_dependency_blocked, "dependency-change", decision}
    assert decision.reason == :unresolved_hard_dependency
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
  end
end
