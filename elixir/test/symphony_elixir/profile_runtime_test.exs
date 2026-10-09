defmodule SymphonyElixir.ProfileRuntimeTestFake do
  def start_session(workspace, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:profile_runtime_started, workspace, opts})
    {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}
  end

  def run_turn(session, _prompt, issue, opts) do
    send(session.test_pid, {:profile_runtime_turn, issue, opts})
    {:ok, %{session_id: "profile-runtime-turn"}}
  end

  def stop_session(session) do
    send(session.test_pid, {:profile_runtime_stopped, session})
    :ok
  end
end

defmodule SymphonyElixir.ProfileRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}
  alias SymphonyElixir.AgentRuntime.RuntimeAttempt.Identity
  alias SymphonyElixir.Codex.IsolationProfile
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.WorkControl.WorkItem
  alias SymphonyElixir.Workspace.OwnershipLedger

  defp dispatch_guard_evidence(route, %Identity{} = runtime_identity) do
    %{
      class: :mechanical_guard,
      name: :dispatch_guard,
      outcome: :verified,
      subject: {:work_item, runtime_identity.work_item_id},
      transition: {:ready, :in_progress},
      responsibility: route.responsibility,
      runtime_attempt_id: runtime_identity.runtime_attempt_id,
      lineage_generation: runtime_identity.lineage_generation,
      runtime_profile: route.profile_name,
      route_fingerprint: route.fingerprint,
      verified_at: DateTime.utc_now()
    }
  end

  defp dispatch_guard_assessment_context(route, %Identity{} = runtime_identity) do
    %{
      trusted_route: route,
      subject: {:work_item, runtime_identity.work_item_id},
      transition: {:ready, :in_progress},
      responsibility: route.responsibility,
      runtime_attempt_id: runtime_identity.runtime_attempt_id,
      lineage_generation: runtime_identity.lineage_generation,
      runtime_profile: route.profile_name,
      route_fingerprint: route.fingerprint
    }
  end

  test "planner permission profile binds read-only access to the exact workspace" do
    root = Path.join(System.tmp_dir!(), "symphony-profile-runtime-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-READONLY")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_routing: "routed",
        tracker_kind: "memory"
      )

      profile = Config.settings!().agent.profiles["planner"]

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, Profile.runtime_options(profile))
      assert settings.permission_profile == "symphony_planner_read"
      assert settings.runtime_workspace_roots == [Path.expand(workspace)]
      assert settings.access == :read
      assert settings.thread_sandbox == "read-only"
      assert settings.turn_sandbox_policy == %{}
    after
      File.rm_rf(root)
    end
  end

  test "legacy runtime settings preserve the workflow sandbox without a routed profile" do
    root = Path.join(System.tmp_dir!(), "symphony-legacy-runtime-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-LEGACY")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_routing: "legacy",
        codex_thread_sandbox: "read-only",
        codex_turn_sandbox_policy: %{type: "readOnly"}
      )

      assert Config.settings!().agent.profiles == nil
      assert {:ok, settings} = Config.codex_runtime_settings(workspace)
      assert settings.thread_sandbox == "read-only"
      assert settings.turn_sandbox_policy == %{"type" => "readOnly"}
    after
      File.rm_rf(root)
    end
  end

  test "builder permission profile binds write access to the exact workspace" do
    root = Path.join(System.tmp_dir!(), "symphony-profile-runtime-write-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-WRITE")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_routing: "routed",
        tracker_kind: "memory"
      )

      profile = Config.settings!().agent.profiles["builder"]
      runtime_opts = Profile.runtime_options(profile)

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, runtime_opts)
      assert settings.permission_profile == "symphony_builder_write"
      assert settings.runtime_workspace_roots == [Path.expand(workspace)]
      assert settings.access == :write
      assert settings.thread_sandbox == "workspace-write"
      assert settings.turn_sandbox_policy == %{}

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_routing: "routed",
        tracker_kind: "memory",
        workspace_root: root,
        codex_turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}
      )

      assert {:ok, settings} = Config.codex_runtime_settings(workspace, runtime_opts)
      assert settings.permission_profile == "symphony_builder_write"
      assert settings.runtime_workspace_roots == [Path.expand(workspace)]
      assert settings.turn_sandbox_policy == %{}
    after
      File.rm_rf(root)
    end
  end

  test "routed runtime settings map each responsibility to a named permission profile" do
    root = Path.join(System.tmp_dir!(), "symphony-named-profile-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "SYM-ROLE")
    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        agent_routing: "routed",
        tracker_kind: "memory"
      )

      settings = Config.settings!()

      expected = %{
        "planning" => {"symphony_planner_read", :read},
        "review" => {"symphony_reviewer_read", :read},
        "implementation" => {"symphony_builder_write", :write},
        "correction" => {"symphony_fixer_write", :write}
      }

      Enum.each(expected, fn {responsibility, {permission_profile, access}} ->
        profile =
          Enum.find_value(settings.agent.profiles, fn {_name, profile} ->
            if profile.responsibility == responsibility, do: profile
          end)

        assert {:ok, runtime_settings} =
                 Config.codex_runtime_settings(workspace, Profile.runtime_options(profile))

        assert runtime_settings.routed
        assert runtime_settings.responsibility == responsibility
        assert runtime_settings.permission_profile == permission_profile
        assert runtime_settings.runtime_workspace_roots == [Path.expand(workspace)]
        assert runtime_settings.access == access
        assert runtime_settings.turn_sandbox_policy == %{}
        assert IsolationProfile.profile_name(responsibility) == permission_profile
      end)

      merge_profile = Map.fetch!(settings.agent.profiles, "merge_gatekeeper")

      assert {:error, {:non_executable_routed_responsibility, "merge"}} =
               Config.codex_runtime_settings(workspace, Profile.runtime_options(merge_profile))
    after
      File.rm_rf(root)
    end
  end

  test "routed schema rejects missing or mismatched runtime profiles and unsafe turn policies" do
    valid_profiles = Profile.default_profiles("codex app-server", 1)

    assert :ok =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: valid_profiles}
             })

    assert :ok =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "legacy", profiles: nil}
             })

    assert {:error, :routed_runtime_profiles_missing} =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: nil}
             })

    assert {:error, {:invalid_routed_runtime_profile, "builder", :invalid_profile}} =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: %{"builder" => :invalid}}
             })

    unsupported = routed_profile("custom", "codex", "read-only")

    assert {:error, {:invalid_routed_runtime_profile, "custom", {:unsupported_runtime_responsibility, "custom", "codex"}}} =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: %{"custom" => unsupported}}
             })

    runtime_mismatch = routed_profile("planning", "deferred", "read-only")

    assert {:error, {:invalid_routed_runtime_profile, "planner", {:runtime_or_access_mismatch, "deferred", "planning", "read-only"}}} =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: %{"planner" => runtime_mismatch}}
             })

    invalid_merge = routed_profile("merge", "codex", "workspace-write")

    assert {:error, {:invalid_routed_runtime_profile, "merge_gatekeeper", :merge_must_be_deferred}} =
             Schema.validate_routed_runtime_profiles(%Schema{
               agent: %Schema.Agent{routing: "routed", profiles: %{"merge_gatekeeper" => invalid_merge}}
             })

    assert :ok = Schema.validate_routed_turn_sandbox_policy_type(%{"type" => "readOnly"})
    assert :ok = Schema.validate_routed_turn_sandbox_policy_type(%{"type" => :workspaceWrite})

    assert {:error, {:unsafe_routed_turn_sandbox_policy, :missing_type}} =
             Schema.validate_routed_turn_sandbox_policy_type(%{})

    assert {:error, {:unsafe_routed_turn_sandbox_policy, :invalid_type}} =
             Schema.validate_routed_turn_sandbox_policy_type(%{"type" => 1})

    assert_raise ArgumentError, ~r/only readOnly and workspaceWrite are permitted/, fn ->
      Schema.finalize_routed_turn_sandbox_policy(%{"type" => "fullAccess"}, "/tmp/workspace")
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
               ownership_ledger: workspace_ownership_ledger(),
               issue_state_fetcher: fn [_issue_id] -> {:ok, []} end
             )

    assert_receive {:profile_runtime_started, _workspace, opts}
    assert opts[:command] == "custom-codex app-server"
    assert opts[:model] == "custom-model"
    assert opts[:sandbox] == "read-only"
    assert opts[:profile] == profile
    assert_receive {:profile_runtime_turn, ^issue, turn_opts}
    assert turn_opts[:model] == "custom-model"
    assert turn_opts[:sandbox] == "read-only"
    assert turn_opts[:profile] == profile
    assert_receive {:profile_runtime_stopped, _session}
  end

  defp routed_profile(responsibility, runtime, sandbox) do
    %Profile{
      name: responsibility,
      responsibility: responsibility,
      runtime: runtime,
      command: if(runtime == "deferred", do: nil, else: "codex app-server"),
      model: nil,
      prompt: responsibility,
      sandbox: sandbox,
      max_turns: 1,
      concurrency_class: nil
    }
  end

  test "routed remote attempts block before workspace creation or runtime startup" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "h080b-remote-attempt",
      identifier: "SYM-REMOTE-ISOLATION",
      title: "Remote runtime admission",
      state: "Ready"
    }

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: "Ready"
      })

    settings = Config.settings!()
    assert {:ok, route} = Router.resolve(work_item, settings.agent.profiles, settings.agent.routes)
    ledger = workspace_ownership_ledger()
    remote_host = "h080b-uncontained-worker.invalid"

    assert :ok =
             AgentRunner.run(issue, self(),
               runtime: SymphonyElixir.ProfileRuntimeTestFake,
               test_pid: self(),
               route: route,
               work_item: work_item,
               worker_host: remote_host,
               ownership_ledger: ledger
             )

    assert_receive {
      :runtime_isolation_blocked,
      issue_id,
      {:runtime_isolation_unavailable, :remote_containment_unproven}
    }

    assert issue_id == issue.id
    refute_receive {:profile_runtime_started, _, _}, 20
    assert {:ok, []} = OwnershipLedger.list_for_work_item(ledger, issue.id)
  end

  test "routed catalogue restart revalidates current workspace ownership before starting a new session" do
    test_pid = self()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Ready", "In Progress"],
      max_turns: 2
    )

    issue = %Issue{
      id: "restart-ownership-drift",
      identifier: "SYM-RESTART-OWNERSHIP",
      title: "Revalidate workspace on restart",
      state: "Ready",
      dispatchable: true
    }

    refreshed_issue = %{issue | state: "In Progress"}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: DateTime.utc_now(),
        prior_validated_lifecycle_state: issue.state
      })

    assert {:ok, route} = Router.resolve(work_item, Config.settings!().agent.profiles)
    runtime_identity = Identity.allocate(issue.id, route, "lineage-restart-ownership-drift")
    dispatch_evidence = dispatch_guard_evidence(route, runtime_identity)
    assessment_context = dispatch_guard_assessment_context(route, runtime_identity)
    ledger = workspace_ownership_ledger()
    refresh_count = :atomics.new(1, [])

    admission = fn worker_host, executable, _opts ->
      send(test_pid, {:runtime_isolation_admitted, worker_host, executable})
      {:ok, :test_admitted}
    end

    assert :ok =
             AgentRunner.run(issue, test_pid,
               runtime: SymphonyElixir.ProfileRuntimeTestFake,
               test_pid: test_pid,
               runtime_attempt_identity: runtime_identity,
               route: route,
               work_item: work_item,
               ownership_ledger: ledger,
               guard_evidence: [dispatch_evidence],
               assessment_context: assessment_context,
               test_runtime_isolation_admit: admission,
               issue_state_fetcher: fn [_issue_id] ->
                 if :atomics.add_get(refresh_count, 1, 1) == 1 do
                   {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
                   assert record.state == :owned

                   assert {:ok, _released_record} =
                            OwnershipLedger.transition(
                              ledger,
                              record.workspace_ownership_id,
                              :release_pending,
                              release_origin: :authorized_cleanup
                            )
                 end

                 {:ok, [refreshed_issue]}
               end
             )

    assert_receive {:runtime_isolation_admitted, nil, executable}
    assert Path.basename(executable) == "codex"
    assert_receive {:profile_runtime_started, _workspace, _opts}
    assert_receive {:profile_runtime_turn, ^issue, _turn_opts}
    assert_receive {:profile_runtime_stopped, _session}

    assert_receive {
      :runtime_isolation_blocked,
      "restart-ownership-drift",
      ^runtime_identity,
      {:runtime_isolation_unavailable, :workspace_identity_or_runtime_unproven}
    }

    refute_receive {:profile_runtime_started, _, _}, 20
  end
end
