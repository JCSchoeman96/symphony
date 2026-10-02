defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, RuntimeIsolation}

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "turn timeout resets on stream updates and fires after silence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-turn-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TIMEOUT")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"one"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"item/updated","params":{"item":{"id":"two"}}}'
            sleep 0.15
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 250
      )

      issue = %Issue{
        id: "issue-turn-timeout",
        identifier: "MT-TIMEOUT",
        title: "Stream timeout",
        description: "Keep active streams alive",
        state: "In Progress",
        url: "https://example.org/issues/MT-TIMEOUT",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "stream updates", issue)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-silent"}}}' ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-silent"}}}'
            sleep 0.4
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_turn_timeout_ms: 100
      )

      assert {:error, :turn_timeout} = AppServer.run(workspace, "silent turn", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server passes explicit turn sandbox policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy passthrough",
        description: "Ensure runtime startup forwards configured turn sandbox policies unchanged",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        %{"type" => "dangerFullAccess"},
        %{"type" => "externalSandbox", "profile" => "remote-ci"},
        %{
          "type" => "workspaceWrite",
          "writableRoots" => ["relative/path"],
          "networkAccess" => true
        },
        %{"type" => "futureSandbox", "nested" => %{"flag" => true}}
      ]

      Enum.each(policy_cases, fn configured_policy ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == configured_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"resp-1\",\"params\":{\"requiresInput\":true,\"reason\":\"blocked\"}}'
            ;;
          *)
            exit 0
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
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: "Cannot satisfy codex input",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs input", issue)

      assert payload["method"] == "turn/input_required"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
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
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload["method"] == "mcpServer/elicitation/request"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"gh pr view","cwd":"/tmp","reason":"need approval"}}'
            ;;
          *)
            sleep 1
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
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: "Ensure safer defaults do not auto approve requests",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:error, {:approval_required, payload}} =
               AppServer.run(workspace, "Handle approval request", issue)

      assert payload["method"] == "item/commandExecution/requestApproval"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves command execution approval requests when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Auto approve request",
        description: "Ensure app-server approval requests are handled automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   Enum.any?(get_in(payload, ["params", "dynamicTools"]) || [], fn
                     %{
                       "description" => description,
                       "inputSchema" => %{"required" => ["query"]},
                       "name" => "linear_graphql"
                     } ->
                       description =~ "Linear"

                     _ ->
                       false
                   end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and
                   get_in(payload, ["result", "decision"]) == "acceptForSession"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server auto-approves MCP tool approval prompts when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Auto approve MCP tool request user input",
        description: "Ensure app tool approval prompts continue automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle tool approval prompt", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110 and
                   get_in(payload, [
                     "result",
                     "answers",
                     "mcp_tool_call_approval_call-717",
                     "answers"
                   ]) ==
                     ["Approve this Session"]
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks freeform tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts receive a generic answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle generic tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks option-based tool input prompts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Proceed with the requested action.\",\"label\":\"Allow\"},{\"description\":\"Do not proceed.\",\"label\":\"Deny\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input block",
        description: "Ensure option prompts require operator input",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload["method"] == "item/tool/requestUserInput"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"some_tool\",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Reject unsupported tool calls", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   String.contains?(
                     get_in(payload, ["result", "output"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"name\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => true,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   get_in(payload, ["result", "output"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\"}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", %{"query" => "query Viewer { viewer { id } }"}}

      assert_received {:app_server_message,
                       %{
                         event: :tool_call_failed,
                         payload: %{"params" => %{"tool" => "linear_graphql"}}
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{},"padding":"%s"}\\n' "$padding"
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server captures codex side output and logs it through Logger" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            ;;
          4)
            printf '%s\\n' 'warning: this is stderr noise' >&2
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)
        end)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
      assert log =~ "Codex turn stream output: warning: this is stderr noise"
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits malformed events for JSON-like protocol lines that fail to decode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
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
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :malformed, payload: "{\"method\":\"turn/completed\""}}

      assert_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server does not pass tracker credentials to the local Codex child" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-secret-env-#{System.unique_integer([:positive])}"
      )

    custom_secret_env = "SYMP_CUSTOM_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    profile_marker_env = "SYMP_TEST_BASH_PROFILE_LOADED_#{System.unique_integer([:positive])}"
    previous_secret = System.get_env("LINEAR_API_KEY")
    previous_custom_secret = System.get_env(custom_secret_env)
    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_secret)
      restore_env(custom_secret_env, previous_custom_secret)
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-SECRET")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-secret-env.trace")

      File.mkdir_p!(bash_home)
      File.mkdir_p!(workspace)

      File.write!(Path.join(bash_home, ".bash_profile"), """
      export LINEAR_API_KEY='profile-canonical-secret-that-must-not-reach-child'
      export #{custom_secret_env}='profile-custom-secret-that-must-not-reach-child'
      export #{profile_marker_env}=1
      """)

      System.put_env("LINEAR_API_KEY", "canonical-secret-that-must-not-reach-child")
      System.put_env(custom_secret_env, "custom-secret-that-must-not-reach-child")
      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="$SYMP_TEST_CODEx_TRACE"
      printf 'PROFILE_LOADED:%s\n' "$#{profile_marker_env}" >> "$trace_file"
      printf 'CANONICAL_SECRET:%s\n' "$LINEAR_API_KEY" >> "$trace_file"
      printf 'CUSTOM_SECRET:%s\n' "$#{custom_secret_env}" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-secret"}}}'
            ;;
          3)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-secret"}}}'
            ;;
          4)
            printf '%s\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        tracker_api_token: "$#{custom_secret_env}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-secret-env",
        identifier: "MT-SECRET",
        title: "Keep tracker auth in Symphony",
        description: "Ensure the child cannot bypass the centrally-authenticated tool boundary",
        state: "In Progress",
        url: "https://example.org/issues/MT-SECRET",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Do not inherit tracker auth", issue)
      assert File.read!(trace_file) =~ "PROFILE_LOADED:1\n"
      assert File.read!(trace_file) =~ "CANONICAL_SECRET:\n"
      assert File.read!(trace_file) =~ "CUSTOM_SECRET:\n"
      refute File.read!(trace_file) =~ "secret-that-must-not-reach-child"
    after
      File.rm_rf(test_root)
    end
  end

  test "routed sandbox uses an ephemeral HOME so login profiles are not sourced" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-routed-home-#{System.unique_integer([:positive])}"
      )

    profile_marker_env = "SYMP_TEST_BASH_PROFILE_LOADED_#{System.unique_integer([:positive])}"
    previous_home = System.get_env("HOME")
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      bash_home = Path.join(test_root, "bash-home")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-routed-home.trace")

      File.mkdir_p!(bash_home)

      File.write!(Path.join(bash_home, ".bash_profile"), """
      export #{profile_marker_env}=1
      export LINEAR_API_KEY='profile-secret'
      """)

      System.put_env("HOME", bash_home)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(trace_file)}
      printf 'PROFILE_LOADED:%s\\n' "$#{profile_marker_env}" >> "$trace_file"
      printf 'HOME:%s\\n' "$HOME" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-routed-home"}}}' ;;
          *) sleep 3600 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      workspace_root = Config.settings!().workspace.root
      workspace = Path.join(workspace_root, "MT-ROUTED-HOME")
      File.mkdir_p!(workspace)

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 command: "#{codex_binary} app-server",
                 sandbox: "read-only"
               )

      trace = File.read!(trace_file)
      refute trace =~ "PROFILE_LOADED:1"
      assert trace =~ "HOME:"
      refute String.contains?(trace, bash_home)
      assert trace =~ "symphony-routed-home"
      assert :ok = AppServer.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed sessions launch the resolved executable with named profile protocol fields" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-routed-direct-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ROUTED-DIRECT")
    codex_binary = Path.join(test_root, "codex")
    trace_file = Path.join(test_root, "codex-routed-direct.trace")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    thread_result = %{
      "thread" => %{"id" => "thread-routed-direct"},
      "activePermissionProfile" => %{"id" => "symphony_builder_write"},
      "runtimeWorkspaceRoots" => [Path.expand(workspace)],
      "cwd" => Path.expand(workspace)
    }

    try do
      File.write!(codex_binary, """
      #!/bin/sh
      trace_file=#{inspect(trace_file)}
      printf 'ARGV0:%s\\n' "$0" >> "$trace_file"
      printf 'HOME:%s\\n' "$HOME" >> "$trace_file"
      printf 'CODEX_HOME:%s\\n' "$CODEX_HOME" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1) printf '%s\\n' '#{Jason.encode!(%{"id" => 1, "result" => %{}})}' ;;
          2) ;;
          3) printf '%s\\n' '#{Jason.encode!(%{"id" => 2, "result" => thread_result})}' ;;
          4)
            printf '%s\\n' '#{Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-routed-direct"}, "activePermissionProfile" => %{"id" => "symphony_builder_write"}, "runtimeWorkspaceRoots" => [Path.expand(workspace)], "cwd" => Path.expand(workspace)}})}'
            printf '%s\\n' '#{Jason.encode!(%{"method" => "turn/completed"})}'
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      issue = %Issue{
        id: "issue-routed-direct",
        identifier: "MT-ROUTED-DIRECT",
        title: "Direct launch"
      }

      admission = fn nil, executable, _opts ->
        send(self(), {:routed_runtime_admitted, executable})
        {:ok, :test_admitted}
      end

      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: admission
                   ]
               )

      assert_received {:routed_runtime_admitted, ^codex_binary}
      assert session.routed
      assert session.permission_profile == "symphony_builder_write"
      assert session.runtime_workspace_roots == [Path.expand(workspace)]
      assert {:ok, %{result: :turn_completed}} = AppServer.run_turn(session, "Run direct", issue)
      assert :ok = AppServer.stop_session(session)

      trace = File.read!(trace_file)
      assert trace =~ "ARGV0:#{codex_binary}"
      assert trace =~ "HOME:#{Path.join(session_root, "home")}"
      assert trace =~ "CODEX_HOME:#{Path.join(session_root, "codex")}"

      payloads =
        trace
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&(&1 |> String.trim_leading("JSON:") |> Jason.decode!()))

      thread_start = Enum.find(payloads, &(&1["method"] == "thread/start"))
      assert thread_start["params"]["permissions"] == "symphony_builder_write"
      assert thread_start["params"]["runtimeWorkspaceRoots"] == [Path.expand(workspace)]
      assert thread_start["params"]["cwd"] == Path.expand(workspace)
      refute Map.has_key?(thread_start["params"], "sandbox")

      turn_start = Enum.find(payloads, &(&1["method"] == "turn/start"))
      assert turn_start["params"]["permissions"] == "symphony_builder_write"
      assert turn_start["params"]["runtimeWorkspaceRoots"] == [Path.expand(workspace)]
      refute Map.has_key?(turn_start["params"], "sandboxPolicy")
      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed admission checks workspace ownership before runtime proof and session-home setup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-admission-order-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ADMISSION-ORDER")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      workspace_admit = fn _issue, _workspace ->
        send(self(), :workspace_admission_checked)
        {:error, :stale_ownership}
      end

      runtime_admit = fn _issue, _executable, _opts ->
        send(self(), :runtime_admission_started)
        {:ok, :admitted}
      end

      assert {:error, {:runtime_isolation_unavailable, {:workspace_identity_unproven, :stale_ownership}}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert_received :workspace_admission_checked
      refute_received :runtime_admission_started
      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed admission revalidates the workspace before launch and cleans its prepared home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-revalidation-race-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-REVALIDATION-RACE")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    launch_marker = Path.join(test_root, "codex-launched")
    File.mkdir_p!(workspace)

    try do
      File.write!(codex_binary, "#!/bin/sh\ntouch #{launch_marker}\nexit 0\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_workspace_revalidation_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)

        if invocation == 1 do
          :ok
        else
          {:error, :workspace_changed_after_runtime_proof}
        end
      end

      runtime_admit = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

      admission_reason = {:workspace_identity_unproven, :workspace_changed_after_runtime_proof}
      expected_admission_error = {:error, {:runtime_isolation_unavailable, admission_reason}}

      assert ^expected_admission_error =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert Process.get(admission_key) == 2
      refute File.exists?(launch_marker)
      refute File.exists?(session_root)
    after
      Process.delete(:h080b_workspace_revalidation_count)
      File.rm_rf(test_root)
    end
  end

  test "routed admission returns a session-home cleanup failure after workspace revalidation fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-revalidation-cleanup-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-REVALIDATION-CLEANUP")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_workspace_cleanup_revalidation_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)

        if invocation == 1 do
          :ok
        else
          File.chmod!(session_root, 0o000)
          {:error, :workspace_changed_after_runtime_proof}
        end
      end

      runtime_admit = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

      assert {:error, {:runtime_isolation_cleanup_failed, reason, "session"}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert reason in [:eacces, :eexist, :eperm, :enotempty]
      assert Process.get(admission_key) == 2
      assert File.dir?(session_root)
    after
      if File.dir?(session_root), do: File.chmod(session_root, 0o700)
      Process.delete(:h080b_workspace_cleanup_revalidation_count)
      File.rm_rf(test_root)
    end
  end

  test "routed launch cleans its prepared home when the admitted Codex executable disappears" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-executable-race-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-EXECUTABLE-RACE")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_workspace_executable_revalidation_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)
        if invocation == 2, do: File.rm!(codex_binary)
        :ok
      end

      runtime_admit = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

      assert {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert Process.get(admission_key) == 2
      refute File.exists?(codex_binary)
      refute File.exists?(session_root)
    after
      Process.delete(:h080b_workspace_executable_revalidation_count)
      File.rm_rf(test_root)
    end
  end

  test "routed launch rejects a replacement executable at the admitted path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-executable-replacement-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-EXECUTABLE-REPLACEMENT")
    codex_binary = Path.join(test_root, "codex")
    replacement_binary = Path.join(test_root, "codex.replacement")
    launch_marker = Path.join(test_root, "replacement-launched")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_workspace_executable_replacement_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)

        if invocation == 2 do
          File.write!(replacement_binary, "#!/bin/sh\ntouch #{launch_marker}\nexit 0\n")
          File.chmod!(replacement_binary, 0o755)
          File.rename!(replacement_binary, codex_binary)
        end

        :ok
      end

      runtime_admit = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

      assert {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert Process.get(admission_key) == 2
      assert File.regular?(codex_binary)
      refute File.exists?(replacement_binary)
      refute File.exists?(launch_marker)
      refute File.exists?(session_root)
    after
      Process.delete(:h080b_workspace_executable_replacement_count)
      File.rm_rf(test_root)
    end
  end

  test "routed launch cleans its prepared home when the namespace exits before app-server startup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-namespace-spawn-failure-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-NAMESPACE-SPAWN-FAILURE")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)
    File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex_binary, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_workspace_namespace_spawn_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)
        if invocation == 2, do: File.rm_rf!(workspace)
        :ok
      end

      runtime_admit = fn _worker_host, _executable, _opts -> {:ok, :admitted} end

      assert {:error, {:port_exit, 2}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      assert Process.get(admission_key) == 2
      refute File.exists?(session_root)
    after
      Process.delete(:h080b_workspace_namespace_spawn_count)
      File.rm_rf(test_root)
    end
  end

  test "routed admission blocks missing ownership context and credential-bearing Git state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-boundary-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    missing_context_workspace = Path.join(workspace_root, "MT-MISSING-CONTEXT")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(missing_context_workspace)
    File.mkdir_p!(Path.dirname(codex_binary))
    File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex_binary, 0o700)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      runtime_admit = fn _worker_host, _executable, _opts ->
        send(self(), :runtime_admitted)
        {:ok, :admitted}
      end

      assert {:error, {:runtime_isolation_unavailable, :workspace_identity_unproven}} =
               AppServer.start_session(
                 missing_context_workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      refute_received :runtime_admitted
      refute File.exists?(session_root)

      issue = %Issue{
        id: "app-server-credential-residue",
        identifier: "MT-CREDENTIAL-RESIDUE",
        title: "Credential residue admission",
        state: "In Progress"
      }

      ledger = workspace_ownership_ledger()

      assert {:ok, owned_workspace} =
               SymphonyElixir.Workspace.create_for_issue(issue, nil, ledger)

      File.mkdir_p!(Path.join(owned_workspace, ".git"))
      File.write!(Path.join(owned_workspace, ".git/config"), "[credential]\n  helper = store\n")

      assert {:error, {:runtime_isolation_unavailable, :workspace_scm_boundary_unproven}} =
               AppServer.start_session(
                 owned_workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_issue: issue,
                     ownership_ledger: ledger,
                     runtime_session_root: session_root,
                     test_runtime_isolation_admit: runtime_admit
                   ]
               )

      refute_received :runtime_admitted
      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed admission rejects invalid workspace and runtime verifier callback results" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-callbacks-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ADMISSION-CALLBACKS")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)
    File.write!(codex_binary, "#!/bin/sh\nexit 0\n")
    File.chmod!(codex_binary, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      workspace_admission_results = [
        {:error, :stale_ownership},
        :invalid_workspace_admission
      ]

      Enum.each(workspace_admission_results, fn admission_result ->
        workspace_admission = fn _issue, _workspace -> admission_result end

        assert {:error, {:runtime_isolation_unavailable, reason}} =
                 AppServer.start_session(
                   workspace,
                   Profile.runtime_options(profile) ++
                     [test_runtime_workspace_admit: workspace_admission]
                 )

        expected_reason =
          case admission_result do
            {:error, detail} -> {:workspace_identity_unproven, detail}
            invalid -> {:workspace_admission_invalid, invalid}
          end

        assert reason == expected_reason
      end)

      workspace_admission = fn issue, admitted_workspace, ledger ->
        send(self(), {:workspace_admission_arity_three, issue, admitted_workspace, ledger})
        :ok
      end

      isolation_admission_results = [
        {:not_a_callback, {:runtime_isolation_admission_invalid, :callback}},
        {
          fn _host, _executable, _opts -> :invalid_result end,
          {:runtime_isolation_admission_invalid, :invalid_result}
        },
        {fn _host, _executable, _opts -> {:error, :unproven} end, :unproven},
        {
          fn _host, _executable, _opts -> raise ArgumentError, "sentinel" end,
          {:runtime_isolation_admission_failed, ArgumentError}
        },
        {fn _host, _executable, _opts -> throw(:unproven) end, :runtime_isolation_admission_failed}
      ]

      Enum.each(isolation_admission_results, fn {admission, expected_reason} ->
        assert {:error, ^expected_reason} =
                 AppServer.start_session(
                   workspace,
                   Profile.runtime_options(profile) ++
                     [
                       runtime_session_root: session_root,
                       test_runtime_workspace_admit: workspace_admission,
                       test_runtime_isolation_admit: admission
                     ]
                 )

        assert_received {:workspace_admission_arity_three, nil, ^workspace, nil}
        refute File.exists?(session_root)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "direct routed turn errors stop the child and remove the session home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-direct-turn-cleanup-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-DIRECT-TURN-CLEANUP")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      thread_result = %{
        "thread" => %{"id" => "thread-direct-turn-cleanup"},
        "activePermissionProfile" => %{"id" => "symphony_builder_write"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '#{Jason.encode!(%{"id" => 2, "result" => thread_result})}' ;;
          4)
            printf '%s\\n' '#{Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-direct-turn-cleanup"}, "activePermissionProfile" => %{"id" => "symphony_builder_write"}, "runtimeWorkspaceRoots" => [Path.expand(workspace)], "cwd" => Path.expand(workspace)}})}'
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"sandbox failure"}}'
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      issue = %Issue{
        id: "issue-direct-turn-cleanup",
        identifier: "MT-DIRECT-TURN-CLEANUP",
        title: "Direct turn cleanup"
      }

      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      on_exit(fn ->
        if is_integer(session.os_pid) do
          _ =
            System.cmd("kill", ["-KILL", Integer.to_string(session.os_pid)], stderr_to_stdout: true)
        end

        File.rm_rf(test_root)
      end)

      assert {:error, {:turn_failed, %{"reason" => "sandbox failure"}}} =
               AppServer.run_turn(session, "Run direct", issue)

      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "direct routed turn errors return cleanup failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-direct-turn-cleanup-error-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-DIRECT-TURN-CLEANUP-ERROR")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      thread_result = %{
        "thread" => %{"id" => "thread-direct-turn-cleanup-error"},
        "activePermissionProfile" => %{"id" => "symphony_builder_write"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '#{Jason.encode!(%{"id" => 2, "result" => thread_result})}' ;;
          4)
            printf '%s\\n' '#{Jason.encode!(%{"id" => 3, "result" => %{"turn" => %{"id" => "turn-direct-turn-cleanup-error"}, "activePermissionProfile" => %{"id" => "symphony_builder_write"}, "runtimeWorkspaceRoots" => [Path.expand(workspace)], "cwd" => Path.expand(workspace)}})}'
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"sandbox failure"}}'
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      issue = %Issue{
        id: "issue-direct-turn-cleanup-error",
        identifier: "MT-DIRECT-TURN-CLEANUP-ERROR",
        title: "Cleanup error"
      }

      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      on_exit(fn ->
        if is_integer(session.os_pid) do
          _ =
            System.cmd("kill", ["-KILL", Integer.to_string(session.os_pid)], stderr_to_stdout: true)
        end

        File.rm_rf(test_root)
      end)

      session = Map.put(session, :ephemeral_home, %{root: <<0>>})

      assert {:error, {:runtime_isolation_cleanup_failed, _reason}} =
               AppServer.run_turn(session, "Run direct", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed thread provenance mismatch stops the child and removes the session home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-routed-mismatch-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ROUTED-MISMATCH")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      wrong_thread_result = %{
        "thread" => %{"id" => "thread-routed-mismatch"},
        "activePermissionProfile" => %{"id" => "symphony_wrong_profile"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      write_direct_routed_codex!(codex_binary, wrong_thread_result)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      assert {:error, {:runtime_provenance_mismatch, :thread_start, :active_permission_profile, "symphony_builder_write", "symphony_wrong_profile"}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      refute File.exists?(session_root)

      invalid_thread_result = %{
        "thread" => %{"status" => "missing-id"},
        "activePermissionProfile" => %{"id" => "symphony_builder_write"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      write_direct_routed_codex!(codex_binary, invalid_thread_result)

      assert {:error, {:invalid_thread_payload, %{"status" => "missing-id"}}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      refute File.exists?(session_root)

      valid_thread_result = %{
        "thread" => %{"id" => "thread-routed-turn-provenance"},
        "activePermissionProfile" => %{"id" => "symphony_builder_write"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      turn_result = %{"turn" => %{"id" => "turn-missing-provenance"}}
      write_direct_routed_codex!(codex_binary, valid_thread_result, turn_result)

      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      issue = %Issue{
        id: "app-server-missing-turn-provenance",
        identifier: "MT-MISSING-TURN-PROVENANCE",
        title: "Missing turn provenance"
      }

      assert {:error, {:runtime_provenance_missing, :turn_start}} =
               AppServer.run_turn(session, "Run direct", issue)

      refute File.exists?(session_root)

      malformed_turn_result = %{
        "turn" => %{"id" => "turn-malformed-provenance"},
        "activePermissionProfile" => 17,
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }

      write_direct_routed_codex!(codex_binary, valid_thread_result, malformed_turn_result)

      assert {:ok, malformed_session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3
                   ]
               )

      assert {:error, {:runtime_provenance_mismatch, :turn_start, :active_permission_profile, "symphony_builder_write", nil}} =
               AppServer.run_turn(malformed_session, "Run direct", issue)

      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed session home stays in place when child exit cannot be confirmed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stop-unconfirmed-#{System.unique_integer([:positive])}"
      )

    fake_kill = Path.join(test_root, "kill")
    home = Path.join(test_root, "session-home")
    previous_path = System.get_env("PATH")
    real_kill = System.find_executable("kill")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "session-marker"), "retain until process exit")
    File.write!(fake_kill, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_kill, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        args: [~c"-c", ~c"trap '' TERM; while :; do sleep 1; done"]
      ])

    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      if is_nil(previous_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", previous_path)

      _ = System.cmd(real_kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
      File.rm_rf!(test_root)
    end)

    assert {:error, {:stop_failed, :process_still_running}} =
             AppServer.stop_session(%{port: port, os_pid: os_pid, ephemeral_home: home})

    assert File.exists?(Path.join(home, "session-marker"))

    assert {:error, {:stop_failed, :process_still_running}} =
             AppServer.stop_session(%{port: port, os_pid: os_pid, ephemeral_home: home})

    assert File.exists?(Path.join(home, "session-marker"))
  end

  test "routed containment timeout retains its session home" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "h080b-routed-stop-timeout-#{System.unique_integer([:positive])}"
      )

    home = Path.join(test_root, "session-home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "session-marker"), "retain until containment is proven")

    port =
      Port.open({:spawn_executable, ~c"/usr/bin/python3"}, [
        :binary,
        :exit_status,
        args: [
          ~c"-c",
          ~c"import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        ]
      ])

    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)

    on_exit(fn ->
      _ =
        System.cmd(
          System.find_executable("kill") || "/bin/kill",
          ["-KILL", Integer.to_string(os_pid)],
          stderr_to_stdout: true
        )

      File.rm_rf!(test_root)
    end)

    assert {:error, {:containment_unconfirmed, :termination_timeout}} =
             AppServer.stop_session(%{
               port: port,
               os_pid: os_pid,
               ephemeral_home: home,
               runtime_containment: :linux_pid_namespace
             })

    assert File.exists?(Path.join(home, "session-marker"))
  end

  test "routed stop contains a descendant that escapes the runtime session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-escaped-descendant-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ESCAPED-DESCENDANT")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    runtime_identity_path = Path.join(test_root, "runtime-identity")
    descendant_identity_path = Path.join(test_root, "descendant-identity")
    File.mkdir_p!(workspace)

    File.write!(
      codex_binary,
      """
      #!/usr/bin/python3
      import json
      import os
      import signal
      import sys
      import time

      runtime_identity_path = #{Jason.encode!(runtime_identity_path)}
      descendant_identity_path = #{Jason.encode!(descendant_identity_path)}
      descendant = os.fork()

      if descendant == 0:
          os.setsid()
          with open(descendant_identity_path, "w", encoding="utf-8") as file:
              file.write(f"{os.getpid()} {os.getsid(0)}")
          signal.signal(signal.SIGTERM, signal.SIG_IGN)
          while True:
              time.sleep(0.1)

      with open(runtime_identity_path, "w", encoding="utf-8") as file:
          file.write(f"{os.getpid()} {os.getsid(0)}")

      thread = {
          "thread": {"id": "thread-escaped-descendant"},
          "activePermissionProfile": {"id": "symphony_builder_write"},
          "runtimeWorkspaceRoots": [#{Jason.encode!(Path.expand(workspace))}],
          "cwd": #{Jason.encode!(Path.expand(workspace))},
      }

      for request_number, _line in enumerate(sys.stdin, start=1):
          if request_number == 1:
              print(json.dumps({"id": 1, "result": {}}), flush=True)
          elif request_number == 3:
              print(json.dumps({"id": 2, "result": thread}), flush=True)
              sys.exit(0)
      """
    )

    File.chmod!(codex_binary, 0o700)

    on_exit(fn ->
      unless File.dir?(session_root), do: File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agent_routing: "routed",
      codex_command: "#{codex_binary} app-server"
    )

    profile = Config.settings!().agent.profiles["builder"]

    assert {:ok, session} =
             AppServer.start_session(
               workspace,
               Profile.runtime_options(profile) ++
                 [
                   runtime_session_root: session_root,
                   test_runtime_workspace_admit: &admit_workspace_for_test/2,
                   test_runtime_isolation_admit: &admit_for_test/3
                 ]
             )

    on_exit(fn ->
      stop_result = if File.dir?(session_root), do: AppServer.stop_session(session), else: :ok

      if stop_result == :ok and not File.dir?(session_root) do
        File.rm_rf(test_root)
      end
    end)

    assert wait_for_test_file(runtime_identity_path)
    assert wait_for_test_file(descendant_identity_path)
    {runtime_namespace_pid, runtime_session_id} = read_process_identity!(runtime_identity_path)

    {descendant_namespace_pid, descendant_session_id} =
      read_process_identity!(descendant_identity_path)

    assert descendant_session_id == descendant_namespace_pid
    refute descendant_session_id == runtime_session_id
    assert wait_for_namespace_pid_absence(session.os_pid, runtime_namespace_pid)

    descendant_host_pid = wait_for_namespace_host_pid(session.os_pid, descendant_namespace_pid)
    assert test_pid_alive?(descendant_host_pid)
    assert File.dir?(session_root)

    assert :ok = AppServer.stop_session(session)

    refute test_pid_alive?(descendant_host_pid)
    refute File.exists?(session_root)
  end

  test "routed launch accepts a root-owned Codex executable when path trust is enforced" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-trusted-runtime-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-TRUSTED-RUNTIME")
    session_root = Path.join(test_root, "session")
    executable = System.find_executable("true") || "/usr/bin/true"
    codex_link = Path.join(test_root, "codex")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    assert {:ok, executable_stat} = File.stat(executable)
    assert executable_stat.uid == 0
    File.ln_s!(executable, codex_link)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agent_routing: "routed",
      codex_command: "#{codex_link} app-server"
    )

    profile = Config.settings!().agent.profiles["builder"]

    assert {:error, {:port_exit, 0}} =
             AppServer.start_session(
               workspace,
               Profile.runtime_options(profile) ++
                 [
                   command: "#{codex_link} app-server",
                   runtime_session_root: session_root,
                   test_runtime_workspace_admit: &admit_workspace_for_test/2,
                   test_runtime_isolation_admit: &admit_for_test/3,
                   test_routed_enforce_runtime_path_trust: true
                 ]
             )

    refute File.exists?(session_root)
  end

  test "routed launch fails closed when its platform has no Linux proof" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-unsupported-platform-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-UNSUPPORTED-PLATFORM")
    session_root = Path.join(test_root, "session")
    executable = System.find_executable("true") || "/usr/bin/true"
    codex_link = Path.join(test_root, "codex")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    File.ln_s!(executable, codex_link)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agent_routing: "routed",
      codex_command: "#{codex_link} app-server"
    )

    profile = Config.settings!().agent.profiles["builder"]

    assert {:error, {:runtime_isolation_unavailable, :unsupported_platform}} =
             AppServer.start_session(
               workspace,
               Profile.runtime_options(profile) ++
                 [
                   command: "#{codex_link} app-server",
                   runtime_session_root: session_root,
                   test_runtime_workspace_admit: &admit_workspace_for_test/2,
                   test_runtime_isolation_admit: &admit_for_test/3,
                   test_routed_platform: {:unix, :darwin}
                 ]
             )

    refute File.exists?(session_root)
  end

  test "routed launch rejects a user-owned Codex installation when path trust is enforced" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-runtime-replacement-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-RUNTIME-REPLACEMENT")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    try do
      write_direct_routed_codex!(
        codex_binary,
        %{
          "thread" => %{"id" => "thread-runtime-replacement"},
          "activePermissionProfile" => %{"id" => "symphony_builder_write"},
          "runtimeWorkspaceRoots" => [Path.expand(workspace)],
          "cwd" => Path.expand(workspace)
        }
      )

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      assert {:error, {:runtime_isolation_unavailable, :codex_installation_untrusted}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: &admit_for_test/3,
                     test_routed_enforce_runtime_path_trust: true
                   ]
               )

      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "routed launch rejects a user-writable Linux guard tool path" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-untrusted-guard-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-UNTRUSTED-GUARD")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_direct_routed_codex!(
      codex_binary,
      %{
        "thread" => %{"id" => "thread-untrusted-guard"},
        "activePermissionProfile" => %{"id" => "symphony_builder_write"},
        "runtimeWorkspaceRoots" => [Path.expand(workspace)],
        "cwd" => Path.expand(workspace)
      }
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agent_routing: "routed",
      codex_command: "#{codex_binary} app-server"
    )

    profile = Config.settings!().agent.profiles["builder"]

    assert {:error, {:runtime_isolation_unavailable, {:untrusted_linux_guard_tool, "unshare"}}} =
             AppServer.start_session(
               workspace,
               Profile.runtime_options(profile) ++
                 [
                   runtime_session_root: session_root,
                   test_runtime_workspace_admit: &admit_workspace_for_test/2,
                   test_runtime_isolation_admit: &admit_for_test/3,
                   test_routed_guard_tool_paths: %{"unshare" => codex_binary}
                 ]
             )

    trusted_guard_directory =
      System.find_executable("true")
      |> Path.dirname()

    assert {:ok, %File.Stat{type: :directory, uid: 0}} = File.stat(trusted_guard_directory)

    assert {:error, {:runtime_isolation_unavailable, {:untrusted_linux_guard_tool, "unshare"}}} =
             AppServer.start_session(
               workspace,
               Profile.runtime_options(profile) ++
                 [
                   runtime_session_root: session_root,
                   test_runtime_workspace_admit: &admit_workspace_for_test/2,
                   test_runtime_isolation_admit: &admit_for_test/3,
                   test_routed_guard_tool_paths: %{"unshare" => trusted_guard_directory}
                 ]
             )

    refute File.exists?(session_root)
  end

  @tag timeout: 120_000
  @tag skip:
         if(System.find_executable("codex"),
           do: false,
           else: "pinned Codex executable is unavailable"
         )
  test "pinned Codex returns routed thread provenance before exposing the session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-pinned-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-PINNED-CODEX")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "codex app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      runtime_path_trust_opts =
        if System.get_env("SYMPHONY_ENFORCE_TEST_RUNTIME_PATH_TRUST") == "1",
          do: [test_routed_enforce_runtime_path_trust: true],
          else: []

      assert {:ok, session} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2
                   ] ++
                   runtime_path_trust_opts
               )

      assert session.routed
      assert session.permission_profile == "symphony_builder_write"
      assert session.runtime_workspace_roots == [Path.expand(workspace)]
      assert :ok = AppServer.stop_session(session)
      refute File.exists?(session_root)
    after
      File.rm_rf(test_root)
    end
  end

  @tag timeout: 120_000
  test "routed launch fails closed when its isolation evidence is invalidated before spawn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-stale-runtime-proof-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-STALE-RUNTIME-PROOF")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "codex app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]
      admission_key = :h080b_runtime_proof_revalidation_count
      Process.put(admission_key, 0)

      workspace_admit = fn _issue, _workspace ->
        invocation = Process.get(admission_key, 0) + 1
        Process.put(admission_key, invocation)
        if invocation == 2, do: RuntimeIsolation.clear()
        :ok
      end

      runtime_path_trust_opts =
        if System.get_env("SYMPHONY_ENFORCE_TEST_RUNTIME_PATH_TRUST") == "1",
          do: [test_routed_enforce_runtime_path_trust: true],
          else: []

      assert {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: workspace_admit
                   ] ++ runtime_path_trust_opts
               )

      assert Process.get(admission_key) == 2
      refute File.exists?(session_root)
    after
      Process.delete(:h080b_runtime_proof_revalidation_count)
      File.rm_rf(test_root)
    end
  end

  defp admit_for_test(nil, _executable, _opts), do: {:ok, :test_admitted}

  defp admit_workspace_for_test(_issue, _workspace), do: :ok

  defp wait_for_test_file(path, attempts \\ 100)

  defp wait_for_test_file(_path, 0), do: false

  defp wait_for_test_file(path, attempts) do
    if File.regular?(path) do
      true
    else
      Process.sleep(10)
      wait_for_test_file(path, attempts - 1)
    end
  end

  defp read_process_identity!(path) do
    [pid, session_id] = path |> File.read!() |> String.split()
    {String.to_integer(pid), String.to_integer(session_id)}
  end

  defp wait_for_namespace_pid_absence(unshare_pid, namespace_pid, attempts \\ 100)

  defp wait_for_namespace_pid_absence(_unshare_pid, _namespace_pid, 0), do: false

  defp wait_for_namespace_pid_absence(unshare_pid, namespace_pid, attempts) do
    if is_nil(find_namespace_host_pid(unshare_pid, namespace_pid)) do
      true
    else
      Process.sleep(10)
      wait_for_namespace_pid_absence(unshare_pid, namespace_pid, attempts - 1)
    end
  end

  defp wait_for_namespace_host_pid(unshare_pid, namespace_pid, attempts \\ 100)

  defp wait_for_namespace_host_pid(_unshare_pid, _namespace_pid, 0), do: nil

  defp wait_for_namespace_host_pid(unshare_pid, namespace_pid, attempts) do
    case find_namespace_host_pid(unshare_pid, namespace_pid) do
      pid when is_integer(pid) ->
        pid

      nil ->
        Process.sleep(10)
        wait_for_namespace_host_pid(unshare_pid, namespace_pid, attempts - 1)
    end
  end

  defp find_namespace_host_pid(unshare_pid, namespace_pid) do
    unshare_pid
    |> runtime_process_tree_pids()
    |> Enum.find(&namespace_pid_matches?(&1, namespace_pid))
  end

  defp namespace_pid_matches?(host_pid, namespace_pid) do
    with {:ok, status} <- File.read("/proc/#{host_pid}/status"),
         line when is_binary(line) <- Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "NSpid:")),
         value when is_binary(value) <- line |> String.replace_prefix("NSpid:", "") |> String.split() |> List.last() do
      String.to_integer(value) == namespace_pid
    else
      _missing_status -> false
    end
  end

  defp runtime_process_tree_pids(root_pid) do
    runtime_process_tree_pids([root_pid], MapSet.new())
  end

  defp runtime_process_tree_pids([], seen), do: MapSet.to_list(seen)

  defp runtime_process_tree_pids([pid | remaining], seen) do
    if MapSet.member?(seen, pid) do
      runtime_process_tree_pids(remaining, seen)
    else
      children = runtime_process_children(pid)
      runtime_process_tree_pids(remaining ++ children, MapSet.put(seen, pid))
    end
  end

  defp runtime_process_children(pid) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, contents} -> contents |> String.split() |> Enum.flat_map(&parse_process_id/1)
      _error -> []
    end
  end

  defp parse_process_id(value) do
    case Integer.parse(value) do
      {pid, ""} -> [pid]
      _invalid -> []
    end
  end

  defp test_pid_alive?(pid) do
    case System.cmd(System.find_executable("kill") || "/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp write_direct_routed_codex!(path, thread_result, turn_result \\ nil) do
    turn_response =
      if is_map(turn_result), do: Jason.encode!(%{"id" => 3, "result" => turn_result}), else: ""

    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '#{Jason.encode!(%{"id" => 1, "result" => %{}})}' ;;
        2) ;;
        3) printf '%s\\n' '#{Jason.encode!(%{"id" => 2, "result" => thread_result})}' ;;
        4) printf '%s\\n' '#{turn_response}' ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  test "app server launches over ssh for remote workers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-ssh-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      remote_workspace = "/remote/workspaces/MT-REMOTE"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      count=0
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-remote"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-remote"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        codex_command: "fake-remote-codex app-server"
      )

      issue = %Issue{
        id: "issue-remote",
        identifier: "MT-REMOTE",
        title: "Run remote app server",
        description: "Validate ssh-backed codex startup",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE",
        labels: ["backend"]
      }

      assert {:ok, _result} =
               AppServer.run(
                 remote_workspace,
                 "Run remote worker",
                 issue,
                 worker_host: "worker-01:2200"
               )

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "-T -p 2200 worker-01 bash -lc"
      assert argv_line =~ "cd "
      assert argv_line =~ remote_workspace
      assert argv_line =~ "unset GITHUB_TOKEN"
      assert argv_line =~ "LINEAR_API_KEY"
      assert argv_line =~ "PLANE_API_KEY"
      assert argv_line =~ "SSH_AUTH_SOCK"
      assert argv_line =~ "exec "
      assert argv_line =~ "fake-remote-codex app-server"

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [remote_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == remote_workspace &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "prepared routed session homes must match profile, workspace, and access" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "h080b-validated-session-#{System.unique_integer([:positive])}"
      )

    policies = %{permission_profile: "symphony_builder_write", access: :write}

    session_home = %{
      permission_profile: "symphony_builder_write",
      workspace: workspace,
      access: :write
    }

    assert :ok = AppServer.validate_session_home(session_home, policies, workspace)

    assert {:error, {:runtime_profile_mismatch, :prepared_session_home, "symphony_builder_write", "other_profile"}} =
             AppServer.validate_session_home(
               %{session_home | permission_profile: "other_profile"},
               policies,
               workspace
             )

    assert {:error, {:runtime_workspace_mismatch, :prepared_session_home, ^workspace, "/outside/workspace"}} =
             AppServer.validate_session_home(
               %{session_home | workspace: "/outside/workspace"},
               policies,
               workspace
             )

    assert {:error, {:runtime_access_mismatch, :prepared_session_home, :write, :read}} =
             AppServer.validate_session_home(%{session_home | access: :read}, policies, workspace)
  end

  test "routed session startup cleans its private home after namespace exit proves termination" do
    test_root =
      Path.join(System.tmp_dir!(), "h080b-app-server-spawn-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-SPAWN-FAILURE")
    codex_binary = Path.join(test_root, "codex")
    session_root = Path.join(test_root, "session")
    File.mkdir_p!(workspace)
    File.write!(codex_binary, "#!/h080b/missing/interpreter\nexit 0\n")
    File.chmod!(codex_binary, 0o700)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agent_routing: "routed",
        codex_command: "#{codex_binary} app-server"
      )

      profile = Config.settings!().agent.profiles["builder"]

      assert {:error, {:port_exit, 0}} =
               AppServer.start_session(
                 workspace,
                 Profile.runtime_options(profile) ++
                   [
                     runtime_session_root: session_root,
                     test_runtime_workspace_admit: &admit_workspace_for_test/2,
                     test_runtime_isolation_admit: fn _host, _executable, _opts ->
                       {:ok, :admitted}
                     end
                   ]
               )

      refute File.exists?(session_root)
    after
      unless File.dir?(session_root), do: File.rm_rf(test_root)
    end
  end
end
