defmodule SymphonyElixir.AgentRuntimeTestFake do
  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(workspace, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_started, workspace, opts})
    {:ok, %{session_id: "fake-session", workspace: workspace, test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, issue, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:runtime_turn, session, prompt, issue})
    send(Keyword.fetch!(opts, :test_pid), {:runtime_turn_options, opts})
    {:ok, %{session_id: session.session_id, thread_id: "fake-thread", turn_id: "fake-turn"}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, {:runtime_stopped, session})
    :ok
  end
end

defmodule SymphonyElixir.AgentRuntimeStopFailureTestRuntime do
  @behaviour SymphonyElixir.AgentRuntime

  def capabilities, do: []
  def runtime_metadata, do: %{name: :test}

  def start_session(_workspace, _opts), do: {:ok, :test_session}
  def run_turn(_session, _prompt, _issue, _opts), do: {:ok, :completed}
  def stop_session(_session), do: {:error, {:stop_failed, :test_failure}}
end

defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.AgentRuntime.{Codex, Router}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.WorkControl.WorkItem

  @work_control_now ~U[2026-09-16 00:00:00Z]

  defp trusted_work_item(%Issue{} = issue) do
    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: @work_control_now,
        prior_validated_lifecycle_state: issue.state
      })

    work_item
  end

  test "the runtime contract includes lifecycle and observational callbacks" do
    assert Enum.sort(AgentRuntime.behaviour_info(:callbacks)) ==
             Enum.sort(
               capabilities: 0,
               runtime_metadata: 0,
               run_turn: 4,
               start_session: 2,
               stop_session: 1
             )

    assert Codex.capabilities() == [:streaming, :tool_calls]
    assert Codex.runtime_metadata() == %{name: :codex}
  end

  test "Codex runtime delegates invalid startup and turn calls to AppServer" do
    assert {:error, {:start_failed, _reason}} =
             Codex.start_session(Path.join(System.tmp_dir!(), "symphony-runtime-outside-default-#{System.unique_integer()}"))

    assert {:error, {:start_failed, _reason}} =
             Codex.start_session(
               Path.join(System.tmp_dir!(), "symphony-runtime-outside-#{System.unique_integer()}"),
               worker_host: nil
             )

    assert {:error, {:turn_failed, {:invalid_session, :not_started}}} =
             Codex.run_turn(%{}, "prompt", %Issue{})

    assert {:error, {:invalid_session, :not_started}} = Codex.stop_session(%{})
  end

  test "Codex reports a stopped session instead of treating stop as idempotent success" do
    executable = System.find_executable("cat")
    assert is_binary(executable)

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary])

    session =
      {make_ref(),
       %{
         port: port,
         metadata: %{},
         approval_policy: "never",
         auto_approve_requests: true,
         turn_sandbox_policy: %{},
         thread_id: "thread-test",
         workspace: "/tmp",
         dynamic_tool_binding: %{}
       }}

    assert :ok = Codex.stop_session(session)
    assert {:error, {:stop_failed, :session_stopped}} = AppServer.stop_session(%{port: port})
    assert {:error, {:session_not_active, :stopped}} = Codex.stop_session(session)

    assert {:error, {:turn_failed, {:session_not_active, :stopped}}} =
             Codex.run_turn(session, "prompt", %Issue{})
  end

  test "Codex preserves a runtime turn failure as an explicit error" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-turn-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "SYM-TURN-FAILURE")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-failure\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-failure\"}}}'
            printf '%s\\n' '{\"method\":\"turn/failed\",\"params\":{\"message\":\"runtime failed\"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "runtime-turn-failure",
        identifier: "SYM-TURN-FAILURE",
        title: "Turn failure",
        state: "In Progress"
      }

      assert {:ok, session} = Codex.start_session(workspace)

      assert {:error, {:turn_failed, {:turn_failed, %{"message" => "runtime failed"}}}} =
               Codex.run_turn(session, "prompt", issue)

      assert :ok = Codex.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "AgentRunner surfaces a runtime stop failure" do
    test_pid = self()
    issue = %Issue{id: "runtime-stop-failure", identifier: "SYM-STOP", title: "Stop failure", state: "In Progress"}

    assert_raise RuntimeError, ~r/stop/i, fn ->
      AgentRunner.run(issue, test_pid,
        runtime: SymphonyElixir.AgentRuntimeStopFailureTestRuntime,
        max_turns: 1,
        issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
      )
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
    work_item = trusted_work_item(issue)
    assert {:ok, initial_route} = Router.resolve(work_item, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: initial_route,
               work_item: work_item,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Ready"}]} end
             )

    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:agent_route_changed, "route-change", ^initial_route, _new_route}, 50
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
  end

  test "routed AgentRunner refuses a route without a validated WorkItem" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready"]
    )

    issue = %Issue{
      id: "missing-work-item",
      identifier: "SYM-MISSING-WORK-ITEM",
      title: "Missing WorkItem",
      state: "Ready",
      dispatchable: true
    }

    assert {:ok, route} = Router.resolve_legacy(issue, Config.settings!().agent.profiles)

    assert_raise RuntimeError, ~r/canonical_work_item_required/, fn ->
      AgentRunner.run(issue, self(), route: route, runtime: SymphonyElixir.AgentRuntimeTestFake)
    end
  end

  test "routed AgentRunner refuses to resolve a raw provider issue into a route" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready"]
    )

    issue = %Issue{
      id: "raw-route-resolution",
      identifier: "SYM-RAW-ROUTE",
      title: "Raw route resolution",
      state: "Ready",
      dispatchable: true
    }

    assert_raise RuntimeError, ~r/route authority validation failed.*canonical_work_item_required/, fn ->
      AgentRunner.run(issue, self(), runtime: SymphonyElixir.AgentRuntimeTestFake)
    end
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
    work_item = trusted_work_item(issue)
    assert {:ok, initial_route} = Router.resolve(work_item, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: initial_route,
               work_item: work_item,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end
             )

    assert_receive {:runtime_turn, _session, _first_prompt, %{state: "Ready"}}
    assert_receive {:runtime_turn, _session, _second_prompt, %{state: "Ready"}}
    refute_receive {:agent_route_changed, "same-route", _previous_route, _next_route}, 50
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
  end

  test "AgentRunner keeps effective profile options on continuation turns" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In Progress"],
      agent_profiles: %{"builder" => %{"model" => "selected-model"}},
      max_turns: 2
    )

    issue = %Issue{
      id: "runtime-options-continuation",
      identifier: "SYM-RUNTIME-OPTIONS",
      title: "Keep runtime options",
      state: "Ready",
      dispatchable: true
    }

    profiles = Config.settings!().agent.profiles
    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end
             )

    assert_receive {:runtime_turn_options, first_turn_opts}
    assert_receive {:runtime_turn_options, second_turn_opts}

    for turn_opts <- [first_turn_opts, second_turn_opts] do
      assert turn_opts[:model] == "selected-model"
      assert turn_opts[:sandbox] == "workspace-write"
      assert turn_opts[:profile] == route.profile

      assert turn_opts[:agent_tool_context].issue_id == "runtime-options-continuation"
      assert turn_opts[:agent_tool_context].current_issue_state == "Ready"
      assert turn_opts[:agent_tool_context].trusted_lifecycle_state == :ready
      assert turn_opts[:agent_tool_context].work_item == work_item
      assert turn_opts[:agent_tool_context].responsibility == "implementation"

      assert turn_opts[:agent_tool_context].dependency_decision == %{
               allowed?: true,
               dependency_status: :none,
               dependency_completeness: :complete,
               dependent_state: "ready",
               responsibility: "implementation",
               reason: :no_hard_dependencies,
               merge_permitted?: true,
               blockers: [],
               unresolved_blockers: [],
               invalidated_blockers: [],
               diagnostic: nil,
               issue_id: "runtime-options-continuation",
               identifier: "SYM-RUNTIME-OPTIONS"
             }
    end
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
    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
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
    assert decision.allowed? == false
    assert decision.dependency_completeness == :complete
    assert decision.merge_permitted? == false
    assert decision.reason == :unresolved_hard_dependency
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
  end

  test "routed AgentRunner suspends instead of rerouting after an unsafe forward observation" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In Review"],
      max_turns: 2
    )

    issue = %Issue{
      id: "runner-lifecycle-suspension",
      identifier: "SYM-LIFECYCLE-SUSPENSION",
      title: "Lifecycle suspension",
      state: "Ready",
      dispatchable: true
    }

    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
               issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "In Review"}]} end
             )

    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:agent_lifecycle_suspended, "runner-lifecycle-suspension", assessment}
    assert assessment.status == :invalid
    assert assessment.reason == :impossible_transition
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
    refute_receive {:agent_route_changed, "runner-lifecycle-suspension", _previous, _next}, 50
  end

  test "routed AgentRunner suspends for a provider Blocked observation" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready"],
      max_turns: 2
    )

    issue = %Issue{
      id: "runner-provider-blocked",
      identifier: "SYM-PROVIDER-BLOCKED",
      title: "Provider blocked",
      state: "Ready",
      dispatchable: true
    }

    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
               issue_state_fetcher: fn [_issue_id] ->
                 {:ok, [%{issue | state: "Blocked", dispatchable: false}]}
               end
             )

    assert_receive {:runtime_turn, _session, _prompt, ^issue}
    assert_receive {:agent_lifecycle_suspended, "runner-provider-blocked", assessment}
    assert assessment.status == :authority_reducing
    assert assessment.reason == :provider_blocked
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
    refute_receive {:runtime_turn, _session, _prompt, _issue}, 50
  end
end
