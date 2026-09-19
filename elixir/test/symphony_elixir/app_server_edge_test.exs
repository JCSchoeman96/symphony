defmodule SymphonyElixir.AppServerEdgeTest do
  use SymphonyElixir.TestSupport

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
      [tracker_kind: "memory"],
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

  defp json_line(payload), do: "            printf '%s\\n' '#{Jason.encode!(payload)}'"
end
