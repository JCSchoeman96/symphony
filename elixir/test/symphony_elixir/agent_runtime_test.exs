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

defmodule SymphonyElixir.AgentRuntimePlaneCatalogueTestRuntime do
  alias SymphonyElixir.Tracker

  @spec start_session(Path.t(), keyword()) :: {:ok, map()}
  def start_session(workspace, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    context = Keyword.get(opts, :agent_tool_context, %{})
    %{tool_specs: tool_specs} = Tracker.bind_agent_tools(agent_tool_context: context)
    session = %{session_id: make_ref(), workspace: workspace, test_pid: test_pid}
    send(test_pid, {:plane_catalogue_runtime_started, session, tool_specs, context})
    {:ok, session}
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()}
  def run_turn(session, prompt, issue, opts) do
    send(session.test_pid, {:plane_catalogue_runtime_turn, session, prompt, issue, opts})
    {:ok, %{session_id: session.session_id, thread_id: "fake-thread", turn_id: "fake-turn"}}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) do
    send(session.test_pid, {:plane_catalogue_runtime_stopped, session})
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
  alias SymphonyElixir.AgentRuntime.{Codex, Router, RuntimeAttempt}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.WorkControl.{GuardClass, WorkItem}

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
        ownership_ledger: workspace_ownership_ledger(),
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
               ownership_ledger: workspace_ownership_ledger(),
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
               ownership_ledger: workspace_ownership_ledger(),
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
      AgentRunner.run(issue, self(),
        route: route,
        runtime: SymphonyElixir.AgentRuntimeTestFake,
        ownership_ledger: workspace_ownership_ledger()
      )
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
      AgentRunner.run(issue, self(),
        runtime: SymphonyElixir.AgentRuntimeTestFake,
        ownership_ledger: workspace_ownership_ledger()
      )
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
               ownership_ledger: workspace_ownership_ledger(),
               issue_state_fetcher: fn [_issue_id] -> {:ok, [issue]} end
             )

    assert_receive {:runtime_turn, _session, _first_prompt, %{state: "Ready"}}
    assert_receive {:runtime_turn, _session, _second_prompt, %{state: "Ready"}}
    refute_receive {:agent_route_changed, "same-route", _previous_route, _next_route}, 50
    assert_receive {:runtime_stopped, %{session_id: "fake-session"}}
  end

  test "routed AgentRunner passes the refreshed WorkItem to the next turn context" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "refreshed-work-item",
      identifier: "SYM-REFRESHED-WORK-ITEM",
      title: "Refreshed WorkItem",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}
    profiles = Config.settings!().agent.profiles
    work_item = trusted_work_item(issue)
    assert {:ok, route} = Router.resolve(work_item, profiles)

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.AgentRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               work_item: work_item,
               ownership_ledger: workspace_ownership_ledger(),
               guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
               issue_state_fetcher: fn [_issue_id] -> {:ok, [refreshed_issue]} end
             )

    assert_receive {:runtime_started, _workspace, start_opts}
    assert start_opts[:agent_tool_context].route == route
    refute Keyword.has_key?(start_opts, :route)
    assert_receive {:runtime_turn, _session, first_prompt, ^issue}
    refute first_prompt =~ route.fingerprint
    assert_receive {:runtime_turn_options, first_turn_opts}
    assert_receive {:runtime_turn_options, second_turn_opts}
    refute Keyword.has_key?(first_turn_opts, :route)
    assert first_turn_opts[:agent_tool_context].route == route
    assert first_turn_opts[:agent_tool_context].route.starting_state == "ready"
    refute Keyword.has_key?(second_turn_opts, :route)
    assert second_turn_opts[:agent_tool_context].route.starting_state == "in progress"
    assert second_turn_opts[:agent_tool_context].route.profile_name == route.profile_name
    assert second_turn_opts[:agent_tool_context].route.responsibility == route.responsibility
    assert first_turn_opts[:agent_tool_context].trusted_lifecycle_state == :ready
    assert second_turn_opts[:agent_tool_context].trusted_lifecycle_state == :in_progress
    assert second_turn_opts[:agent_tool_context].work_item.validated_lifecycle_state == :in_progress
    assert second_turn_opts[:agent_tool_context].work_item != work_item
  end

  test "routed Plane continuation starts a fresh catalogue for the refreshed route" do
    test_pid = self()
    previous_plane_api_key = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "test-plane-secret")

    workspace_root = Path.join(System.tmp_dir!(), "symphony-plane-catalogue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)
    write_plane_workflow_file!(Workflow.workflow_file_path(), workspace_root)

    issue = %Issue{
      id: "plane-catalogue-refresh",
      identifier: "SYM-PLANE-CATALOGUE",
      title: "Plane catalogue refresh",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :plane,
        observed_at: @work_control_now,
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)

    runtime_identity = RuntimeAttempt.Identity.allocate(issue.id, route, "lineage-catalogue-refresh")

    try do
      assert :ok =
               AgentRunner.run(issue, test_pid,
                 runtime: SymphonyElixir.AgentRuntimePlaneCatalogueTestRuntime,
                 test_pid: test_pid,
                 route: route,
                 work_item: work_item,
                 ownership_ledger: workspace_ownership_ledger(),
                 runtime_attempt_identity: runtime_identity,
                 guard_evidence: [GuardClass.requirement(:mechanical_guard, :dispatch_guard)],
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [refreshed_issue]} end
               )

      assert_receive {:plane_catalogue_runtime_started, first_session, first_specs, first_context}
      assert transition_target_enum(first_specs) == ["In Progress"]
      assert first_context.route.starting_state == "ready"

      assert_receive {:plane_catalogue_runtime_turn, ^first_session, first_prompt, ^issue, first_turn_opts}
      refute first_prompt =~ "new runtime thread"
      assert first_turn_opts[:runtime_attempt_identity] == runtime_identity
      assert first_turn_opts[:agent_tool_context].runtime_attempt_identity == runtime_identity
      assert first_turn_opts[:agent_tool_context].route.starting_state == "ready"
      assert_receive {:plane_catalogue_runtime_stopped, ^first_session}

      assert_receive {:plane_catalogue_runtime_started, second_session, second_specs, second_context}
      assert second_session.session_id != first_session.session_id
      assert transition_target_enum(second_specs) == ["In Review"]
      assert second_context.route.starting_state == "in progress"

      assert_receive {:plane_catalogue_runtime_turn, ^second_session, second_prompt, ^refreshed_issue, second_turn_opts}
      assert second_prompt =~ "new runtime thread"
      assert second_turn_opts[:runtime_attempt_identity] == runtime_identity
      assert second_turn_opts[:agent_tool_context].runtime_attempt_identity == runtime_identity
      assert second_turn_opts[:agent_tool_context].route.starting_state == "in progress"
      assert_receive {:plane_catalogue_runtime_stopped, ^second_session}
      refute_receive {:plane_catalogue_runtime_started, _session, _specs, _context}, 50
      refute_receive {:plane_catalogue_runtime_turn, _session, _prompt, _issue, _opts}, 50
      refute_receive {:plane_catalogue_runtime_stopped, _session}, 50
    after
      restore_env("PLANE_API_KEY", previous_plane_api_key)
      File.rm_rf(workspace_root)
    end
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
               ownership_ledger: workspace_ownership_ledger(),
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
      assert %WorkItem{} = turn_opts[:agent_tool_context].work_item
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

    assert first_turn_opts[:agent_tool_context].work_item == work_item
    assert second_turn_opts[:agent_tool_context].work_item != work_item
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
               ownership_ledger: workspace_ownership_ledger(),
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
               ownership_ledger: workspace_ownership_ledger(),
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
               ownership_ledger: workspace_ownership_ledger(),
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

  defp transition_target_enum(specs) do
    specs
    |> Enum.find(&(&1["name"] == "plane_request_lifecycle_transition"))
    |> get_in(["inputSchema", "properties", "targetState", "enum"])
  end

  defp write_plane_workflow_file!(path, workspace_root) do
    File.write!(path, """
    ---
    tracker:
      kind: "plane"
      active_states: ["Ready", "In Progress"]
      terminal_states: ["Done", "Cancelled"]
      provider:
        workspace_slug: "workspace-1"
        workspace_id: "workspace-stable-1"
        project_id: "project-1"
        api_key: "$PLANE_API_KEY"
    symphony:
      project_id: "symphony-plane"
    workspace:
      root: "#{workspace_root}"
    agent:
      routing: "routed"
      max_turns: 2
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
    codex:
      command: "codex app-server"
    ---
    You are a Plane test agent.
    """)

    SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end
end
