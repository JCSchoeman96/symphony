defmodule SymphonyElixir.ProfileRuntimeTestFake do
  def start_session(workspace, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:profile_runtime_started, workspace, opts})
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  def run_turn(session, _prompt, issue, _opts) do
    send(session.test_pid, {:profile_runtime_turn, issue})
    {:ok, %{session_id: "profile-runtime-turn"}}
  end

  def stop_session(session) do
    send(session.test_pid, {:profile_runtime_stopped, session})
    :ok
  end
end

defmodule SymphonyElixir.ProfileRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route}

  test "read-only profile settings cannot inherit a writable turn policy" do
    root = Path.join(System.tmp_dir!(), "symphony-profile-runtime-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-READONLY")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, sandbox: "read-only")
      assert settings.thread_sandbox == "read-only"
      assert settings.turn_sandbox_policy["type"] == "readOnly"
      refute Map.has_key?(settings.turn_sandbox_policy, "writableRoots")
    after
      File.rm_rf(root)
    end
  end

  test "workspace-write profile settings use the bounded workspace policy" do
    root = Path.join(System.tmp_dir!(), "symphony-profile-runtime-write-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-WRITE")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, sandbox: "workspace-write")
      assert settings.thread_sandbox == "workspace-write"
      assert settings.turn_sandbox_policy["type"] == "workspaceWrite"
      assert settings.turn_sandbox_policy["writableRoots"] == [Path.expand(workspace)]

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        codex_turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
      )

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, sandbox: "workspace-write")
      assert settings.turn_sandbox_policy["type"] == "workspaceWrite"
      assert settings.turn_sandbox_policy["writableRoots"] == [Path.expand(workspace)]
    after
      File.rm_rf(root)
    end
  end

  test "route profile command, model, and sandbox reach an injected runtime" do
    test_pid = self()

    profile = %Profile{
      name: "custom-builder",
      responsibility: "implementation",
      runtime: "codex",
      command: "custom-codex app-server",
      model: "custom-model",
      prompt: "builder",
      sandbox: "read-only",
      max_turns: 1,
      concurrency_class: nil
    }

    issue = %Issue{id: "profile-runtime", identifier: "SYM-PROFILE", title: "Profile", state: "Ready"}

    route = %Route{
      issue_id: issue.id,
      starting_state: "ready",
      profile_name: profile.name,
      runtime_name: profile.runtime,
      responsibility: profile.responsibility,
      profile: profile,
      fingerprint: "test"
    }

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.ProfileRuntimeTestFake,
               test_pid: test_pid,
               route: route,
               issue_state_fetcher: fn [_issue_id] -> {:ok, []} end
             )

    assert_receive {:profile_runtime_started, _workspace, opts}
    assert opts[:command] == "custom-codex app-server"
    assert opts[:model] == "custom-model"
    assert opts[:sandbox] == "read-only"
    assert opts[:profile] == profile
    assert_receive {:profile_runtime_stopped, _session}
  end
end
