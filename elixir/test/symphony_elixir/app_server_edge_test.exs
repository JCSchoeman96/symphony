defmodule SymphonyElixir.AppServerEdgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.Route
  alias SymphonyElixir.Tracker.Memory

  test "the default start-session API still enforces the local workspace boundary" do
    test_root = Path.join(System.tmp_dir!(), "symphony-app-server-default-start-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(workspace_root)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
               AppServer.start_session(workspace_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "startup returns protocol errors and closes the child when initialize fails" do
    with_fixture(
      [
        [json_line(%{"id" => 1, "error" => %{"code" => -32_600, "message" => "bad initialize"}})]
      ],
      fn workspace, binary, _issue ->
        assert {:error, {:response_error, %{"message" => "bad initialize"}}} =
                 AppServer.start_session(workspace, command: "#{binary} app-server")
      end
    )
  end

  test "startup rejects a thread response without a thread id" do
    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{}}})]
      ],
      fn workspace, binary, _issue ->
        assert {:error, {:invalid_thread_payload, %{}}} =
                 AppServer.start_session(workspace, command: "#{binary} app-server")
      end
    )
  end

  test "the default run-turn API completes an active session and permits an explicit stop" do
    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-default"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-default"}}}),
          json_line(%{"method" => "turn/completed"})
        ]
      ],
      fn workspace, binary, issue ->
        assert {:ok, session} =
                 AppServer.start_session(workspace, command: "#{binary} app-server")

        assert {:ok, %{session_id: "thread-default-turn-default", result: :turn_completed}} =
                 AppServer.run_turn(session, "synthetic prompt", issue)

        assert :ok = AppServer.stop_session(session)
      end
    )
  end

  test "turn-start protocol failures emit startup_failed without changing the runtime" do
    test_pid = self()

    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-turn-error"}}})],
        [json_line(%{"id" => 3, "error" => %{"message" => "turn rejected"}})]
      ],
      fn workspace, binary, issue ->
        on_message = fn message -> send(test_pid, {:app_server_edge_message, message}) end

        assert {:error, {:response_error, %{"message" => "turn rejected"}}} =
                 AppServer.run(workspace, "rejected turn", issue,
                   command: "#{binary} app-server",
                   on_message: on_message
                 )

        assert_received {:app_server_edge_message, %{event: :startup_failed, reason: {:response_error, _}}}
      end
    )
  end

  test "turn cancellation is a hard failure and remains observable" do
    test_pid = self()

    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-cancel"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-cancel"}}}),
          json_line(%{"method" => "turn/cancelled", "params" => %{"reason" => "operator"}})
        ]
      ],
      fn workspace, binary, issue ->
        on_message = fn message -> send(test_pid, {:app_server_edge_message, message}) end

        assert {:error, {:turn_cancelled, %{"reason" => "operator"}}} =
                 AppServer.run(workspace, "cancelled turn", issue,
                   command: "#{binary} app-server",
                   on_message: on_message
                 )

        assert_received {:app_server_edge_message, %{event: :turn_cancelled}}
      end
    )
  end

  test "other protocol messages and malformed tool calls do not stall the turn" do
    test_pid = self()

    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-shape"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-shape"}}}),
          json_line(%{"id" => 9, "result" => %{"diagnostic" => "ignored"}}),
          json_line(%{"id" => 10, "method" => "item/tool/call", "params" => %{"arguments" => %{}}}),
          json_line(%{"method" => "turn/completed"})
        ]
      ],
      fn workspace, binary, issue ->
        on_message = fn message -> send(test_pid, {:app_server_edge_message, message}) end

        assert {:ok, %{result: :turn_completed}} =
                 AppServer.run(workspace, "malformed tool call", issue,
                   command: "#{binary} app-server",
                   on_message: on_message
                 )

        assert_received {:app_server_edge_message, %{event: :other_message}}
        assert_received {:app_server_edge_message, %{event: :unsupported_tool_call}}
        assert_received {:app_server_edge_message, %{event: :turn_completed}}
      end
    )
  end

  test "all supported approval request methods auto-approve only under the explicit never policy" do
    test_pid = self()

    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-approval"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-approval"}}}),
          json_line(%{"id" => 10, "method" => "execCommandApproval", "params" => %{}}),
          json_line(%{"id" => 11, "method" => "applyPatchApproval", "params" => %{}}),
          json_line(%{"id" => 12, "method" => "item/fileChange/requestApproval", "params" => %{}}),
          json_line(%{"method" => "turn/completed"})
        ]
      ],
      [codex_approval_policy: "never"],
      fn workspace, binary, issue ->
        on_message = fn message -> send(test_pid, {:app_server_edge_message, message}) end

        assert {:ok, %{result: :turn_completed}} =
                 AppServer.run(workspace, "approval methods", issue,
                   command: "#{binary} app-server",
                   on_message: on_message
                 )

        assert_received {:app_server_edge_message, %{event: :approval_auto_approved, decision: "approved_for_session"}}
        assert_received {:app_server_edge_message, %{event: :approval_auto_approved, decision: "approved_for_session"}}
        assert_received {:app_server_edge_message, %{event: :approval_auto_approved, decision: "acceptForSession"}}
      end
    )
  end

  test "routed profile sandbox disables never-policy auto approval at session start" do
    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-routed-sandbox"}}})]
      ],
      [codex_approval_policy: "never"],
      fn workspace, binary, _issue ->
        assert {:ok, session} =
                 AppServer.start_session(workspace,
                   command: "#{binary} app-server",
                   sandbox: "read-only"
                 )

        refute session.auto_approve_requests
        assert :ok = AppServer.stop_session(session)
      end
    )
  end

  test "tool results are normalized into safe JSON-RPC response shapes" do
    test_pid = self()

    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-normalize"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-normalize"}}}),
          json_line(%{"id" => 20, "method" => "item/tool/call", "params" => %{"tool" => "successful", "arguments" => %{}}}),
          json_line(%{"id" => 21, "method" => "item/tool/call", "params" => %{"tool" => "raw", "arguments" => %{}}}),
          json_line(%{"method" => "turn/completed"})
        ]
      ],
      fn workspace, binary, issue ->
        on_message = fn message -> send(test_pid, {:app_server_edge_message, message}) end

        tool_executor = fn
          "successful", %{} -> %{"success" => true, "value" => "synthetic"}
          "raw", %{} -> :unexpected_tool_result
        end

        assert {:ok, %{result: :turn_completed}} =
                 AppServer.run(workspace, "normalize tool result", issue,
                   command: "#{binary} app-server",
                   on_message: on_message,
                   tool_executor: tool_executor
                 )

        assert_received {:app_server_edge_message, %{event: :tool_call_completed}}
        assert_received {:app_server_edge_message, %{event: :tool_call_failed}}
        assert_received {:app_server_edge_message, %{event: :turn_completed}}
      end
    )
  end

  defp with_fixture(cases, test_fun) when is_function(test_fun), do: with_fixture(cases, [], test_fun)

  defp with_fixture(cases, workflow_overrides, test_fun) do
    test_root = Path.join(System.tmp_dir!(), "symphony-app-server-edge-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SYNTHETIC")
    binary = Path.join(test_root, "fake-codex")
    File.mkdir_p!(workspace)
    write_fake_codex!(binary, cases)

    try do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge([workspace_root: workspace_root, codex_command: "#{binary} app-server"], workflow_overrides)
      )

      issue = %Issue{id: "synthetic-issue", identifier: "SYNTHETIC", title: "Synthetic issue", state: "In Progress"}
      test_fun.(workspace, binary, issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "each turn overlays trusted context without rebinding session tools" do
    with_fixture(
      [
        [json_line(%{"id" => 1, "result" => %{}})],
        [],
        [json_line(%{"id" => 2, "result" => %{"thread" => %{"id" => "thread-overlay"}}})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-overlay-1"}}}),
          json_line(%{
            "id" => 10,
            "method" => "item/tool/call",
            "params" => %{
              "name" => "memory_transition",
              "arguments" => %{"targetState" => "In Review"}
            }
          })
        ],
        [json_line(%{"method" => "turn/completed"})],
        [
          json_line(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-overlay-2"}}}),
          json_line(%{
            "id" => 11,
            "method" => "item/tool/call",
            "params" => %{
              "name" => "memory_transition",
              "arguments" => %{
                "targetState" => "In Review",
                "agent_tool_context" => %{"trusted_lifecycle_state" => "Ready"}
              }
            }
          })
        ],
        [json_line(%{"method" => "turn/completed"})]
      ],
      [tracker_kind: "memory", agent_routing: "legacy"],
      fn workspace, binary, issue ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

        initial_context = %{
          issue_id: issue.id,
          trusted_lifecycle_state: :ready,
          responsibility: "implementation",
          dependency_decision: %{
            allowed?: true,
            dependency_completeness: :complete,
            dependency_status: :none
          }
        }

        refreshed_context = %{initial_context | trusted_lifecycle_state: :in_progress}

        assert {:ok, session} =
                 AppServer.start_session(workspace,
                   command: "#{binary} app-server",
                   agent_tool_context: initial_context
                 )

        binding = session.dynamic_tool_binding
        tracker_settings = binding.tracker_settings
        transition_guard = binding.transition_guard
        assert binding.adapter == Memory
        assert binding.agent_tool_context == initial_context
        assert binding.secret_environment_names == []
        assert Enum.map(binding.tool_specs, &Map.fetch!(&1, "name")) == ["memory_read", "memory_transition"]

        assert {:ok, _first_turn} =
                 AppServer.run_turn(session, "first turn", issue, agent_tool_context: initial_context)

        assert {:ok, [^issue]} = Memory.fetch_issues_by_ids([issue.id])

        assert {:ok, _second_turn} =
                 AppServer.run_turn(session, "second turn", issue, agent_tool_context: refreshed_context)

        assert {:ok, [%{state: "In Review"}]} = Memory.fetch_issues_by_ids([issue.id])
        assert session.dynamic_tool_binding == binding
        assert session.dynamic_tool_binding.tracker_settings == tracker_settings
        assert session.dynamic_tool_binding.transition_guard == transition_guard
        assert :ok = AppServer.stop_session(session)
      end
    )
  end

  test "a refreshed Plane route gets a new thread catalogue after a session boundary" do
    test_root = Path.join(System.tmp_dir!(), "symphony-plane-thread-catalogue-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "SYNTHETIC")
    binary = Path.join(test_root, "fake-codex")
    trace = Path.join(test_root, "codex-trace.jsonl")
    previous_plane_api_key = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "test-plane-secret")
    File.mkdir_p!(workspace)
    write_plane_workflow!(Workflow.workflow_file_path(), workspace_root)
    write_tracing_fake_codex!(binary, trace)

    try do
      profile = Config.settings!().agent.profiles["builder"]
      ready_route = Route.new(%Issue{id: "plane-thread-catalogue", state: "Ready"}, profile)
      in_progress_route = Route.new(%Issue{id: "plane-thread-catalogue", state: "In Progress"}, profile)

      ready_context = %{
        issue_id: "plane-thread-catalogue",
        current_issue_state: "Ready",
        route: ready_route,
        responsibility: "implementation",
        trusted_lifecycle_state: :ready
      }

      in_progress_context = %{
        ready_context
        | current_issue_state: "In Progress",
          route: in_progress_route,
          trusted_lifecycle_state: :in_progress
      }

      assert {:ok, ready_session} =
               AppServer.start_session(workspace,
                 command: "#{binary} app-server",
                 agent_tool_context: ready_context
               )

      assert transition_target_enum(ready_session.dynamic_tool_binding.tool_specs) == ["In Progress"]
      assert :ok = AppServer.stop_session(ready_session)

      assert {:ok, in_progress_session} =
               AppServer.start_session(workspace,
                 command: "#{binary} app-server",
                 agent_tool_context: in_progress_context
               )

      assert transition_target_enum(in_progress_session.dynamic_tool_binding.tool_specs) == ["In Review"]
      assert :ok = AppServer.stop_session(in_progress_session)

      thread_starts =
        trace
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "thread/start"))

      assert Enum.map(thread_starts, &transition_target_enum(&1["params"]["dynamicTools"])) == [
               ["In Progress"],
               ["In Review"]
             ]
    after
      restore_env("PLANE_API_KEY", previous_plane_api_key)
      File.rm_rf(test_root)
    end
  end

  defp write_fake_codex!(path, cases) do
    case_clauses =
      cases
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {commands, count} ->
        commands = List.wrap(commands)
        "          #{count})\n" <> Enum.join(commands, "\n") <> "\n            ;;"
      end)

    script = """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
    #{case_clauses}
          *) exit 0 ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp transition_target_enum(specs) do
    specs
    |> Enum.find(&(&1["name"] == "plane_request_lifecycle_transition"))
    |> get_in(["inputSchema", "properties", "targetState", "enum"])
  end

  defp write_plane_workflow!(path, workspace_root) do
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

  defp write_tracing_fake_codex!(path, trace) do
    trace = String.replace(trace, "'", "'\\''")

    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\\n' "$line" >> '#{trace}'
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-plane"}}}'
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp json_line(payload), do: "            printf '%s\\n' '#{Jason.encode!(payload)}'"
end
