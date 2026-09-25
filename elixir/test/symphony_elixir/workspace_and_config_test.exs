defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.WorkControl.{GuardClass, WorkItem}
  alias SymphonyElixir.Workspace.OwnershipLedger

  test "workspace creation records the exact durable ownership binding" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-ledger-binding-#{System.unique_integer([:positive])}"
      )

    ledger_root = Path.join(workspace_root, "ledger")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        symphony_project_id: "workspace-test"
      )

      config = Config.settings!()

      {:ok, ledger} =
        OwnershipLedger.open(config.symphony.project_id, Tracker.identity(config.tracker), root: ledger_root)

      assert {:ok, workspace} = Workspace.create_for_issue(%Issue{id: "issue-1", identifier: "MT-1"}, nil, ledger)
      assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, "issue-1")
      assert record.state == :owned
      assert record.work_item_id == "issue-1"
      assert record.workspace_key == Workspace.workspace_key("MT-1")
      assert record.canonical_workspace_path == workspace
      assert record.configured_root_identity
      assert record.top_level_filesystem_identity
      refute Map.has_key?(record, :ownership_generation)

      assert :ok = OwnershipLedger.close(ledger)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace refuses a pre-existing directory without durable ownership" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-unowned-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "MT-UNOWNED")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, ".symphony-workspace.json"), "forged marker")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, _reason} = Workspace.create_for_issue("MT-UNOWNED")
      assert File.dir?(workspace)
      assert File.exists?(Path.join(workspace, ".symphony-workspace.json"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creation preserves a pre-existing non-directory target" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-file-target-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "MT-FILE-TARGET")

    try do
      File.mkdir_p!(workspace_root)
      File.write!(workspace, "operator-owned file")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_path_exists, ^workspace, :regular}} =
               Workspace.create_for_issue("MT-FILE-TARGET", nil, workspace_ownership_ledger())

      assert File.read!(workspace) == "operator-owned file"

      assert {:ok, []} =
               OwnershipLedger.list_for_work_item(workspace_ownership_ledger(), "MT-FILE-TARGET")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "recorded workspace removal requires explicit durable authorization" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-removal-auth-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(workspace_root, "MT-AUTH")

    try do
      File.mkdir_p!(workspace)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, _reason, ""} = Workspace.remove_recorded(workspace, nil)
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "authorized recorded removal releases the exact local ownership record" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-removal-owned-#{System.unique_integer([:positive])}"
      )

    ledger_root = Path.join(workspace_root, "ledger")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        symphony_project_id: "workspace-removal-owned"
      )

      config = Config.settings!()

      {:ok, ledger} =
        OwnershipLedger.open(config.symphony.project_id, Tracker.identity(config.tracker), root: ledger_root)

      issue = %Issue{id: "issue-removal-owned", identifier: "MT-REMOVE"}
      assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)

      assert {:ok, [^workspace]} =
               Workspace.remove_recorded(workspace, nil, ledger, cleanup_authorized?: true)

      refute File.exists?(workspace)
      assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert record.state == :released
      assert :ok = OwnershipLedger.close(ledger)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "cleanup completes an owned release when the recorded workspace is already missing" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-missing-release-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      issue = %Issue{id: "missing-release", identifier: "MT-MISSING-RELEASE"}
      ledger = workspace_ownership_ledger()
      assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)
      assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert owned.state == :owned

      assert {:ok, _removed_paths} = File.rm_rf(workspace)
      refute File.exists?(workspace)

      assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)
      assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert released.state == :released
    after
      File.rm_rf(workspace_root)
    end
  end

  test "a failed before_remove hook preserves a retryable pending release" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-pending-hook-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      issue = %Issue{id: "pending-hook", identifier: "MT-PENDING-HOOK"}
      ledger = workspace_ownership_ledger()
      assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "printf removal-blocked; exit 17"
      )

      assert {:error, {:workspace_hook_failed, "before_remove", 17, output}} =
               Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

      assert output =~ "removal-blocked"
      assert File.dir?(workspace)
      assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert pending.state == :release_pending

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)
      refute File.exists?(workspace)
      assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert released.state == :released
    after
      File.rm_rf(workspace_root)
    end
  end

  test "authorized removal preserves a workspace after the recorded identity changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-removal-mismatch-#{System.unique_integer([:positive])}"
      )

    ledger_root = Path.join(workspace_root, "ledger")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        symphony_project_id: "workspace-removal-mismatch"
      )

      config = Config.settings!()

      {:ok, ledger} =
        OwnershipLedger.open(config.symphony.project_id, Tracker.identity(config.tracker), root: ledger_root)

      issue = %Issue{id: "issue-removal-mismatch", identifier: "MT-REMOVE-MISMATCH"}
      assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)
      replacement = workspace <> ".replacement"
      File.mkdir!(replacement)
      File.rm_rf!(workspace)
      File.rename!(replacement, workspace)

      assert {:error, _reason, ""} =
               Workspace.remove_recorded(workspace, nil, ledger, cleanup_authorized?: true)

      assert File.dir?(workspace)
      assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert record.state == :release_pending
      assert :ok = OwnershipLedger.close(ledger)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removal overloads enforce record-bound authorization" do
    ownership_state = workspace_ownership_state()
    issue = %Issue{id: "workspace-overloads", identifier: "MT-OVERLOADS", state: "In Progress"}
    ledger = ownership_state.workspace_ownership_ledger

    assert {:ok, workspace} = Workspace.create_for_issue(issue, ledger)
    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    assert {:error, :workspace_cleanup_authorization_required, ""} = Workspace.remove(workspace, nil, ledger)
    assert {:error, :workspace_cleanup_authorization_required, ""} = Workspace.remove_recorded(workspace, nil, ledger)
    assert {:error, :workspace_cleanup_authorization_required} = Workspace.remove_issue_workspaces(issue, nil, ledger)
    assert {:error, {:workspace_path_unreadable, nil, :invalid}, ""} = Workspace.remove_recorded(nil, nil, [])
    assert {:error, :invalid_worker_host} = Workspace.remove_issue_workspaces(issue, 123, [])

    assert {:error, :workspace_cleanup_authorization_mismatch, ""} =
             Workspace.remove_recorded(workspace, nil, ledger,
               cleanup_authorized?: true,
               cleanup_authorization: %{workspace_ownership_id: "another-owner"}
             )

    assert {:error, :workspace_cleanup_authorization_mismatch, ""} =
             Workspace.remove_recorded(workspace, nil, ledger,
               cleanup_authorized?: true,
               cleanup_authorization: %{
                 workspace_ownership_id: record.workspace_ownership_id,
                 canonical_workspace_path: workspace <> ".different"
               }
             )

    assert {:error, :workspace_cleanup_authorization_mismatch, ""} =
             Workspace.remove_recorded(workspace, nil, ledger,
               cleanup_authorized?: true,
               cleanup_authorization: %{
                 workspace_ownership_id: record.workspace_ownership_id,
                 canonical_workspace_path: workspace,
                 worker_host: "worker-other"
               }
             )

    authorization = %{
      workspace_ownership_id: record.workspace_ownership_id,
      canonical_workspace_path: workspace,
      worker_host: nil
    }

    assert {:ok, [^workspace]} =
             Workspace.remove(workspace, nil, ledger,
               cleanup_authorized?: true,
               cleanup_authorization: authorization
             )

    refute File.exists?(workspace)
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "cancels a pending release only while the recorded local workspace remains current" do
    ownership_state = workspace_ownership_state()
    issue = %Issue{id: "workspace-cancel-release", identifier: "MT-CANCEL-RELEASE", state: "In Progress"}
    ledger = ownership_state.workspace_ownership_ledger

    assert {:ok, workspace} = Workspace.create_for_issue(issue, ledger)
    assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    assert {:error, {:invalid_pending_release_state, :owned}} =
             Workspace.cancel_pending_release_if_current(owned, ledger)

    assert {:ok, pending} = OwnershipLedger.transition_sync(ledger, owned.workspace_ownership_id, :release_pending)
    assert {:error, :workspace_ownership_changed} = Workspace.cancel_pending_release_if_current(owned, ledger)

    configured_root = Config.settings!().workspace.root
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: configured_root <> "-changed")

    assert {:error, {:workspace_configured_root_mismatch, _, _}} =
             Workspace.cancel_pending_release_if_current(pending, ledger)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: configured_root)
    assert :ok = Workspace.cancel_pending_release_if_current(pending, ledger)
    assert {:ok, [restored]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert restored.state == :owned
    assert File.dir?(workspace)

    assert {:error, :workspace_ownership_not_found} = Workspace.cancel_pending_release_if_current(%{}, ledger)

    assert {:error, :workspace_ownership_not_found} =
             Workspace.cancel_pending_release_if_current(%{workspace_ownership_id: "missing"}, ledger)

    assert {:error, :workspace_ownership_not_found} = Workspace.cancel_pending_release_if_current(nil, ledger)

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)
  end

  test "releases a missing local workspace without treating it as a cleanup failure" do
    ownership_state = workspace_ownership_state()
    issue = %Issue{id: "workspace-missing-release", identifier: "MT-MISSING-RELEASE", state: "In Progress"}
    ledger = ownership_state.workspace_ownership_ledger

    assert {:ok, workspace} = Workspace.create_for_issue(issue, ledger)
    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert {:ok, _pending} = OwnershipLedger.transition_sync(ledger, record.workspace_ownership_id, :release_pending)
    File.rm_rf!(workspace)

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)
  end

  test "after_create replacement leaves the durable record provisioning" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-post-hook-replacement-#{System.unique_integer([:positive])}"
      )

    ledger_root = Path.join(workspace_root, "ledger")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        symphony_project_id: "workspace-post-hook-replacement",
        hook_after_create: "cd .. && mv MT-POST-HOOK MT-POST-HOOK.original && mkdir MT-POST-HOOK"
      )

      config = Config.settings!()

      {:ok, ledger} =
        OwnershipLedger.open(config.symphony.project_id, Tracker.identity(config.tracker), root: ledger_root)

      issue = %Issue{id: "issue-post-hook-replacement", identifier: "MT-POST-HOOK"}

      assert {:error, {:owned_identity_mismatch, _reason}} =
               Workspace.create_for_issue(issue, nil, ledger)

      workspace = Path.join(workspace_root, "MT-POST-HOOK")
      assert File.dir?(workspace)
      assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
      assert record.state == :provisioning
      assert :ok = OwnershipLedger.close(ledger)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    ledger_root = Path.join(workspace_root, "ledger")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        symphony_project_id: "workspace-deterministic-test"
      )

      config = Config.settings!()

      {:ok, ledger} =
        OwnershipLedger.open(config.symphony.project_id, Tracker.identity(config.tracker), root: ledger_root)

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det", nil, ledger)
      assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det", nil, ledger)

      assert first_workspace == second_workspace
      assert Path.basename(first_workspace) == Workspace.workspace_key("MT/Det")
      assert String.starts_with?(Path.basename(first_workspace), "MT_Det--")
      assert :ok = OwnershipLedger.close(ledger)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "relative local workspace roots resolve from the workflow directory" do
    workflow_dir = Path.dirname(Workflow.workflow_file_path())
    launcher_dir = Path.join(System.tmp_dir!(), "symphony-elixir-launcher-#{System.unique_integer([:positive])}")
    original_cwd = File.cwd!()

    try do
      File.mkdir_p!(launcher_dir)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "relative-workspaces")
      File.cd!(launcher_dir)

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workflow_dir, "relative-workspaces", "MT-REL"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-REL")

      assert workspace == expected_workspace
      refute String.starts_with?(workspace, launcher_dir <> "/")
    after
      File.cd!(original_cwd)
      File.rm_rf(launcher_dir)
    end
  end

  test "workspace keys disambiguate identifiers that sanitize to the same path" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-collision-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      slash_issue = %Issue{id: "dispatch-slash", identifier: "team/a-1"}
      underscore_issue = %Issue{id: "dispatch-underscore", identifier: "team_a-1"}

      assert {:ok, slash_workspace} = Workspace.create_for_issue(slash_issue)
      assert {:ok, ^slash_workspace} = Workspace.create_for_issue(slash_issue)
      assert {:ok, underscore_workspace} = Workspace.create_for_issue(underscore_issue)

      refute slash_workspace == underscore_workspace
      assert Path.basename(underscore_workspace) == "team_a-1"
      assert String.starts_with?(Path.basename(slash_workspace), "team_a-1--")
      assert Workspace.workspace_key(slash_issue) == Workspace.workspace_key(slash_issue.identifier)
      assert Workspace.workspace_key(nil) == "issue"

      assert :ok = Workspace.remove_issue_workspaces(slash_issue, nil, cleanup_authorized?: true)
      refute File.exists?(slash_workspace)
      assert File.exists?(underscore_workspace)

      assert :ok = Workspace.remove_issue_workspaces(slash_issue, nil, cleanup_authorized?: true)

      assert {:ok, recreated_workspace} = Workspace.create_for_issue(slash_issue)
      assert recreated_workspace == slash_workspace
      assert :ok = Workspace.remove_issue_workspaces(slash_issue, nil, cleanup_authorized?: true)
      refute File.exists?(recreated_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace preserves stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:error, _reason} = Workspace.create_for_issue("MT-STALE")
      assert canonical_workspace == Path.expand(stale_workspace)
      assert File.regular?(stale_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "recorded workspace removal rejects symlink escapes before hooks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-recorded-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      recorded_root = Path.join(test_root, "recorded-workspaces")
      current_root = Path.join(test_root, "current-workspaces")
      outside_root = Path.join(test_root, "outside")
      recorded_workspace = Path.join(recorded_root, "MT-SYM")
      hook_marker = Path.join(test_root, "before-remove-ran")

      File.mkdir_p!(recorded_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, recorded_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: current_root,
        hook_before_remove: "touch \"#{hook_marker}\""
      )

      assert {:error, {:workspace_outside_root, _, _}, ""} =
               Workspace.remove_recorded(recorded_workspace, nil, cleanup_authorized?: true)

      refute File.exists?(hook_marker)
      assert File.exists?(outside_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: actual_root)

      assert {:error, {:workspace_ownership_required, ^workspace}} =
               Workspace.create_for_issue("MT-LINK")

      assert {:error, {:workspace_configured_root_mismatch, _, _}, ""} =
               Workspace.remove_recorded(workspace, nil, cleanup_authorized?: true)

      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root, nil, cleanup_authorized?: true)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    before_remove_marker = Path.join(workspace_root, "before-remove")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17",
        hook_before_remove: "touch #{before_remove_marker}"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")

      refute File.exists?(Path.join(workspace_root, "MT-FAIL"))
      assert File.exists?(before_remove_marker)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace retries after_create after a failed new workspace bootstrap" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-retry-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    attempt_log = Path.join(test_root, "after-create-attempts")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        if [ -f "#{attempt_log}" ]; then count=$(wc -l < "#{attempt_log}"); else count=0; fi
        printf 'attempt\\n' >> "#{attempt_log}"
        if [ "$count" -eq 0 ]; then printf partial > partial.txt; exit 17; fi
        printf ready > READY
        """
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL-RETRY")

      assert {:ok, workspace} = Workspace.create_for_issue("MT-FAIL-RETRY")
      assert File.read!(Path.join(workspace, "READY")) == "ready"
      assert String.split(String.trim(File.read!(attempt_log)), "\n") == ["attempt", "attempt"]
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup preserves unowned paths for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, _reason} =
               Workspace.remove_issue_workspaces("S_1", nil, cleanup_authorized?: true)

      assert File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces("S-2", nil, cleanup_authorized?: true)
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert {:error, :workspace_cleanup_authorization_required} = Workspace.remove_issue_workspaces(nil)
  end

  test "tracker issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      dispatchable: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.dispatchable
  end

  test "tracker issue routing requires every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], dispatchable: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | dispatchable: false}, ["symphony"])
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}, %{"name" => " backend "}, %{"name" => " "}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.native_ref == nil
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.dispatchable
  end

  test "linear blocker relations remain routable for the lifecycle dependency guard" do
    raw_issue = %{
      "id" => "issue-planning",
      "identifier" => "MT-PLANNING",
      "title" => "Planning with dependency",
      "state" => %{"name" => "Todo"},
      "assignee" => %{"id" => "user-1"},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-blocker",
              "identifier" => "MT-BLOCKER",
              "state" => %{"name" => "In Progress"}
            }
          }
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-blocker", identifier: "MT-BLOCKER", state: "In Progress"}]
    assert issue.dispatchable
  end

  test "linear client rejects malformed issues instead of returning invalid scheduler records" do
    assert Client.normalize_issue_for_test(
             %{
               "id" => "issue-empty-title",
               "identifier" => "MT-EMPTY",
               "title" => " ",
               "state" => %{"name" => "Todo"}
             },
             nil
           ) == nil

    graphql_fun = fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => "issue-empty-title",
                 "identifier" => "MT-EMPTY",
                 "title" => " ",
                 "state" => %{"name" => "Todo"}
               }
             ]
           }
         }
       }}
    end

    assert {:error, :linear_unknown_payload} =
             Client.fetch_issues_by_ids_for_test(["issue-empty-title"], graphql_fun)
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.dispatchable
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issues_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query,
                    %{
                      ids: ^first_batch_ids,
                      projectSlug: "test-project",
                      first: 50,
                      relationFirst: 50
                    }}

    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "projectSlug"
    assert query =~ "slugId"

    assert_receive {:fetch_issue_states_page, ^query,
                    %{
                      ids: ^second_batch_ids,
                      projectSlug: "test-project",
                      first: 5,
                      relationFirst: 50
                    }}
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear graphql honors a bound tracker-settings snapshot without loading live config" do
    parent = self()
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(WorkflowStore)

    missing_workflow_path =
      Path.join(System.tmp_dir!(), "missing-bound-workflow-#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end
    end)

    if is_pid(Process.whereis(WorkflowStore)) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    end

    Workflow.set_workflow_file_path(missing_workflow_path)

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}} =
             Client.graphql(
               "query Viewer { viewer { id } }",
               %{},
               tracker_settings: %{
                 api_key: "bound-token",
                 endpoint: "https://bound.example.test/graphql"
               },
               request_fun: fn payload, headers ->
                 send(parent, {:bound_graphql_request, payload, headers})
                 {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer-bound"}}}}}
               end
             )

    assert_receive {:bound_graphql_request, %{"query" => "query Viewer { viewer { id } }"}, [{"Authorization", "bound-token"}, {"Content-Type", "application/json"}]}
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "provider-marked blocked issue is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      dependency_graph: Graph.build([]),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      dependency_graph: Graph.build([]),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      dispatchable: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      dependency_graph: Graph.build([]),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"],
      dispatchable: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "provider-marked ready issue remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      dependency_graph: Graph.build([]),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Done"}],
      dispatchable: true
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)

    {:ok, completed_blocker} =
      WorkItem.from_issue(
        %Issue{id: "blocker-2", identifier: "MT-1004", title: "Blocker", state: "Done"},
        %{
          provider: :memory,
          prior_validated_lifecycle_state: :merging,
          evidence: [GuardClass.requirement(:mechanical_guard, :completion_proof_verified)]
        }
      )

    state = %{state | work_control: %{"blocker-2" => completed_blocker}}
    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "routed dispatchability comes from validated canonical work control, not active state scope" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Todo"]
    )

    issue = %Issue{
      id: "canonical-dispatch",
      identifier: "MT-CANONICAL-DISPATCH",
      title: "Canonical dispatch",
      state: "In Progress",
      blocked_by: [],
      dispatchable: false
    }

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        prior_validated_lifecycle_state: :in_progress
      })

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      dependency_graph: Graph.build([]),
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{},
      work_control: %{issue.id => work_item}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "routed dispatch refresh does not reject a non-fetch-scope canonical state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      tracker_active_states: ["Todo"]
    )

    issue = %Issue{
      id: "canonical-refresh",
      identifier: "MT-CANONICAL-REFRESH",
      title: "Canonical refresh",
      state: "In Progress",
      dispatchable: true
    }

    assert {:ok, ^issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn ["canonical-refresh"] ->
               {:ok, [issue]}
             end)
  end

  test "dispatch revalidation skips an issue when provider routing changes" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      dispatchable: false,
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:error, :workspace_cleanup_authorization_required, ""} = Workspace.remove(random_path)
  end

  test "workspace operations reject invalid work items, roots, and worker hosts" do
    assert {:error, :invalid_issue_identity} = Workspace.create_for_issue(%{identifier: "MT-NO-ID"})

    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-root-file-#{System.unique_integer([:positive])}")
    File.write!(workspace_root, "not a directory")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:path_canonicalize_failed, _workspace_path, :enotdir}} =
               Workspace.create_for_issue(%Issue{id: "root-file", identifier: "MT-ROOT-FILE"})
    after
      File.rm(workspace_root)
    end

    assert {:error, :invalid_worker_host} =
             Workspace.remove_issue_workspaces("MT-INVALID-HOST", :invalid, cleanup_authorized?: true)

    assert {:error, {:workspace_path_unreadable, "", :invalid}, ""} =
             Workspace.remove_recorded("", "worker-invalid-path", workspace_ownership_ledger(), cleanup_authorized?: true)
  end

  test "after_run hook failures are ignored while before_run failures are returned" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-hook-semantics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        hook_before_run: "printf before-failed; exit 17",
        hook_after_run: "printf after-failed; exit 18"
      )

      assert {:error, {:workspace_hook_failed, "before_run", 17, output}} =
               Workspace.run_before_run_hook(workspace, "MT-HOOK-FAILURE")

      assert output =~ "before-failed"
      assert :ok = Workspace.run_after_run_hook(workspace, "MT-HOOK-FAILURE")
    after
      File.rm_rf(workspace)
    end
  end

  test "workspace cleanup reports unresolved ownership records" do
    issue = %Issue{id: "workspace-unresolved", identifier: "MT-UNRESOLVED"}
    ledger = workspace_ownership_ledger()
    configured_root = Path.join(System.tmp_dir!(), "symphony-remote-workspaces")
    workspace_key = Workspace.workspace_key(issue.identifier)

    remote_reservation = %{
      work_item_id: issue.id,
      issue_identifier: issue.identifier,
      workspace_key: workspace_key,
      workspace_ownership_id: "workspace-unresolved-remote",
      location: :remote,
      worker_host: "worker-unresolved",
      trusted_host_identity: "remote-host-unresolved",
      configured_root: configured_root,
      configured_root_identity: "1:2",
      canonical_root: configured_root,
      canonical_workspace_path: Path.join(configured_root, workspace_key),
      top_level_filesystem_identity: nil
    }

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, remote_reservation)

    assert {:error, {:workspace_ownership_not_releasable, [^reserved]}} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert {:ok, current} = OwnershipLedger.get(ledger, reserved.workspace_ownership_id)
    assert current.state == :reserved
  end

  test "local creation safely resumes an absent reservation and rejects ambiguous records" do
    ledger = workspace_ownership_ledger()
    canonical_root = Config.local_workspace_root()
    File.mkdir_p!(canonical_root)
    configured_root = Path.expand(canonical_root)
    {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(canonical_root)
    {:ok, root_identity} = OwnershipLedger.root_identity(canonical_root)
    issue = %Issue{id: "workspace-reservation-recovery", identifier: "MT-RESERVATION-RECOVERY"}
    workspace_key = Workspace.workspace_key(issue.identifier)

    reservation = %{
      work_item_id: issue.id,
      issue_identifier: issue.identifier,
      workspace_key: workspace_key,
      workspace_ownership_id: "workspace-reservation-recovery-owned",
      location: :local,
      worker_host: nil,
      trusted_host_identity: ledger.host_identity,
      configured_root: configured_root,
      configured_root_identity: root_identity,
      canonical_root: canonical_root,
      canonical_workspace_path: Path.join(canonical_root, workspace_key),
      top_level_filesystem_identity: nil
    }

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, reservation)
    assert {:ok, workspace} = Workspace.create_for_issue(issue, nil, ledger)
    assert workspace == reservation.canonical_workspace_path
    assert {:ok, owned} = OwnershipLedger.get(ledger, reserved.workspace_ownership_id)
    assert owned.state == :owned

    ambiguous_issue = %Issue{id: "workspace-reservation-ambiguous", identifier: "MT-RESERVATION-AMBIGUOUS"}
    ambiguous_key = Workspace.workspace_key(ambiguous_issue.identifier)

    ambiguous_reservation = %{
      reservation
      | work_item_id: ambiguous_issue.id,
        issue_identifier: ambiguous_issue.identifier,
        workspace_key: ambiguous_key,
        workspace_ownership_id: "workspace-reservation-ambiguous",
        canonical_workspace_path: Path.join(canonical_root, ambiguous_key)
    }

    assert {:ok, provisioning} = OwnershipLedger.reserve_sync(ledger, ambiguous_reservation)

    assert {:ok, _provisioning} =
             OwnershipLedger.transition_sync(
               ledger,
               provisioning.workspace_ownership_id,
               :provisioning,
               top_level_filesystem_identity: %{major_device: 1, minor_device: 0, inode: 99}
             )

    assert {:error, {:workspace_ownership_inconsistent, _path}} =
             Workspace.create_for_issue(ambiguous_issue, nil, ledger)

    refute File.exists?(ambiguous_reservation.canonical_workspace_path)
  end

  test "authorized path-only removal still requires a trusted ownership record" do
    workspace = Path.join(Config.local_workspace_root(), "MT-UNOWNED-REMOVE")

    assert {:error, :workspace_ownership_not_found, ""} =
             Workspace.remove_recorded(workspace, nil, workspace_ownership_ledger(), cleanup_authorized?: true)
  end

  test "reservation, provisioning, and ownership write failures never expose a workspace" do
    test_root = Path.join(System.tmp_dir!(), "symphony-local-ledger-write-failure-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    ledger = workspace_ownership_ledger()
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    cases = [
      {"reservation-write-failure", 1, :missing, false},
      {"provisioning-write-failure", 2, :reserved, false},
      {"owned-write-failure", 3, :provisioning, true}
    ]

    for {suffix, fail_on_write, expected_state, after_create_ran?} <- cases do
      issue = %Issue{id: "workspace-#{suffix}", identifier: "MT-#{suffix}"}
      counter = :counters.new(1, [:atomics])
      workspace = Path.join(workspace_root, issue.identifier)
      after_create_marker = Path.join(workspace, "after-create-ran")

      failing_ledger = %{
        ledger
        | write_fun: fn table, records ->
            :counters.add(counter, 1, 1)
            write_number = :counters.get(counter, 1)

            if write_number == fail_on_write do
              {:error, :disk_full}
            else
              :dets.insert(table, records)
            end
          end
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "touch after-create-ran"
      )

      assert {:error, _reason} = Workspace.create_for_issue(issue, nil, failing_ledger)
      assert File.exists?(workspace) == (expected_state != :missing)
      assert File.exists?(after_create_marker) == after_create_ran?

      case {expected_state, OwnershipLedger.list_for_work_item(ledger, issue.id)} do
        {:missing, {:ok, []}} -> :ok
        {state, {:ok, [record]}} when state in [:reserved, :provisioning] -> assert record.state == state
        unexpected -> flunk("unexpected ownership result: #{inspect(unexpected)}")
      end
    end
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS", nil, cleanup_authorized?: true)
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup preserves workspace when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")

      assert {:error, _reason} =
               Workspace.remove_issue_workspaces("MT-HOOKS-FAIL", nil, cleanup_authorized?: true)

      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup preserves workspace when before_remove hook has large failure output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")

      assert {:error, _reason} =
               Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL", nil, cleanup_authorized?: true)

      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup preserves workspace when before_remove hook times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")

      assert {:error, _reason} =
               Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT", nil, cleanup_authorized?: true)

      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "after_create workspace replacement remains provisioning and is never adopted" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-replacement-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-replaced", identifier: "MT-REPLACED"}
    workspace = Path.join(workspace_root, issue.identifier)
    moved_workspace = workspace <> ".moved"
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "echo original > marker; mv \"$PWD\" \"#{moved_workspace}\"; mkdir \"$PWD\""
    )

    assert {:error, {:owned_identity_mismatch, {:workspace_identity_mismatch, ^workspace}}} =
             Workspace.create_for_issue(issue, nil, workspace_ownership_ledger())

    assert {:ok, [provisioning]} = OwnershipLedger.list_for_work_item(workspace_ownership_ledger(), issue.id)
    assert provisioning.state == :provisioning
    assert File.read!(Path.join(moved_workspace, "marker")) == "original\n"
    assert File.dir?(workspace)
    assert File.ls!(workspace) == []
  end

  test "before_remove replacement fails the second filesystem identity check" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-remove-replacement-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-remove-replaced", identifier: "MT-REMOVE-REPLACED"}
    workspace = Path.join(workspace_root, issue.identifier)
    moved_workspace = workspace <> ".moved"
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.write!(Path.join(workspace, "marker"), "owned")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "mv \"$PWD\" \"#{moved_workspace}\"; mkdir \"$PWD\""
    )

    assert {:error, {:workspace_identity_mismatch, ^workspace}} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending
    assert File.read!(Path.join(moved_workspace, "marker")) == "owned"
    assert File.dir?(workspace)
    assert File.ls!(workspace) == []
  end

  test "local cleanup deletes the detached workspace and preserves a replacement at its original path" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-detach-race-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-detach-race", identifier: "MT-DETACH-RACE"}
    workspace = Path.join(workspace_root, issue.identifier)
    test_process = self()

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.write!(Path.join(workspace, "owned"), "owned")

    workspace_tree_remover = fn quarantine_path ->
      if File.dir?(workspace), do: File.rename!(workspace, workspace <> ".replaced-owned")

      File.mkdir!(workspace)
      File.write!(Path.join(workspace, "foreign"), "foreign")
      send(test_process, {:workspace_quarantine_delete, quarantine_path})
      File.rm_rf(quarantine_path)
    end

    assert :ok =
             Workspace.remove_issue_workspaces(issue, nil, ledger,
               cleanup_authorized?: true,
               workspace_tree_remover: workspace_tree_remover
             )

    assert_receive {:workspace_quarantine_delete, quarantine_path}
    refute quarantine_path == workspace
    assert File.read!(Path.join(workspace, "foreign")) == "foreign"
    refute File.exists?(Path.join(workspace <> ".replaced-owned", "owned"))
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "local cleanup resumes deletion from an owned quarantine after a failed tree removal" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-quarantine-retry-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-quarantine-retry", identifier: "MT-QUARANTINE-RETRY"}
    workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.write!(Path.join(workspace, "owned"), "owned")

    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    quarantine_token =
      :crypto.hash(:sha256, record.workspace_ownership_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    quarantine_dir = Path.join(record.canonical_root, ".symphony-workspace-release-#{quarantine_token}")
    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o700)

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger,
               cleanup_authorized?: true,
               workspace_tree_remover: :invalid
             )

    refute File.exists?(workspace)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending

    failing_tree_remover = fn quarantine_path ->
      {:error, :simulated_tree_removal_failure, quarantine_path}
    end

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger,
               cleanup_authorized?: true,
               workspace_tree_remover: failing_tree_remover
             )

    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "local cleanup fails closed for an invalid quarantine and preserves its owned workspace" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-quarantine-foreign-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-quarantine-foreign", identifier: "MT-QUARANTINE-FOREIGN"}
    workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.write!(Path.join(workspace, "owned"), "owned")

    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    quarantine_token =
      :crypto.hash(:sha256, record.workspace_ownership_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    quarantine_dir = Path.join(record.canonical_root, ".symphony-workspace-release-#{quarantine_token}")
    File.write!(quarantine_dir, "foreign file")

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(workspace, "owned")) == "owned"
    assert File.read!(quarantine_dir) == "foreign file"

    File.rm!(quarantine_dir)
    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o755)

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(workspace, "owned")) == "owned"

    File.chmod!(quarantine_dir, 0o700)
    File.write!(Path.join(quarantine_dir, "foreign"), "foreign")

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(workspace, "owned")) == "owned"
    assert File.read!(Path.join(quarantine_dir, "foreign")) == "foreign"
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending

    File.rm!(Path.join(quarantine_dir, "foreign"))
    File.rmdir!(quarantine_dir)

    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o700)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "chmod 755 '#{quarantine_dir}'"
    )

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(workspace, "owned")) == "owned"
    assert {:ok, %File.Stat{mode: mode}} = File.lstat(quarantine_dir)
    assert Bitwise.band(mode, 0o777) == 0o755

    File.chmod!(quarantine_dir, 0o700)
    File.rmdir!(quarantine_dir)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "local cleanup releases a missing workspace after validating an empty quarantine" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-empty-quarantine-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-empty-quarantine", identifier: "MT-EMPTY-QUARANTINE"}
    workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    quarantine_token =
      :crypto.hash(:sha256, record.workspace_ownership_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    quarantine_dir = Path.join(record.canonical_root, ".symphony-workspace-release-#{quarantine_token}")
    File.rm_rf!(workspace)
    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o700)

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    refute File.exists?(quarantine_dir)
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "local cleanup preserves a replacement found in the quarantine path" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-quarantine-replaced-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-quarantine-replaced", identifier: "MT-QUARANTINE-REPLACED"}
    workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.write!(Path.join(workspace, "owned"), "owned")
    assert {:ok, [record]} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    quarantine_token =
      :crypto.hash(:sha256, record.workspace_ownership_id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    quarantine_dir = Path.join(record.canonical_root, ".symphony-workspace-release-#{quarantine_token}")
    quarantined_workspace = Path.join(quarantine_dir, "workspace")
    preserved_workspace = workspace <> ".owned"

    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o700)
    File.rename!(workspace, preserved_workspace)
    File.mkdir!(quarantined_workspace)
    File.write!(Path.join(quarantined_workspace, "foreign"), "foreign")

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(preserved_workspace, "owned")) == "owned"
    assert File.read!(Path.join(quarantined_workspace, "foreign")) == "foreign"
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending

    File.rm_rf!(quarantine_dir)
    File.mkdir!(quarantine_dir)
    File.chmod!(quarantine_dir, 0o700)
    File.ln_s!(preserved_workspace, quarantined_workspace)

    assert {:error, _reason} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.lstat!(quarantined_workspace).type == :symlink
    assert File.read!(Path.join(preserved_workspace, "owned")) == "owned"

    File.rm_rf!(quarantine_dir)
    File.rename!(preserved_workspace, workspace)

    assert :ok = Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "failed after_create cleanup preserves the workspace when the configured root changes identity" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-root-replaced-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    moved_root = workspace_root <> ".moved"
    issue = %Issue{id: "workspace-root-replaced", identifier: "MT-ROOT-REPLACED"}
    moved_workspace = Path.join(moved_root, issue.identifier)
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "mv \"#{workspace_root}\" \"#{moved_root}\"; mkdir \"#{workspace_root}\"; exit 17"
    )

    assert {:error, {:after_create_cleanup_failed, hook_error, cleanup_error}} =
             Workspace.create_for_issue(issue, nil, workspace_ownership_ledger())

    assert {:workspace_hook_failed, "after_create", 17, _output} = hook_error
    assert {:workspace_root_identity_mismatch, _, _} = cleanup_error

    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(workspace_ownership_ledger(), issue.id)
    assert pending.state == :release_pending
    assert pending.release_origin == :failed_provisioning

    assert {:error, :failed_provisioning_release_cannot_be_cancelled} =
             Workspace.cancel_pending_release_if_current(pending, workspace_ownership_ledger())

    assert File.dir?(moved_workspace)
  end

  test "workspace symlink replacement is rejected before the removal hook" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-symlink-replacement-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-symlink-replaced", identifier: "MT-SYMLINK-REPLACED"}
    workspace = Path.join(workspace_root, issue.identifier)
    protected_target = Path.join(workspace_root, "operator-data")
    hook_marker = Path.join(test_root, "before-remove-ran")
    File.mkdir_p!(workspace_root)
    File.mkdir!(protected_target)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)
    File.rm_rf!(workspace)
    File.ln_s!(protected_target, workspace)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "touch #{hook_marker}"
    )

    assert {:error, {:workspace_symlink_escape, ^workspace, ^workspace_root}} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.lstat!(workspace).type == :symlink
    assert File.dir?(protected_target)
    refute File.exists?(hook_marker)
    assert {:ok, [owned]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert owned.state == :owned
  end

  test "local workspace provisioning detects a replaced configured-root object" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-root-identity-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    moved_root = workspace_root <> ".moved"
    issue = %Issue{id: "workspace-root-identity", identifier: "MT-ROOT-IDENTITY"}
    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_after_create: "mv '#{workspace_root}' '#{moved_root}'; mkdir '#{workspace_root}'; mv '#{moved_root}/#{issue.identifier}' '#{workspace}'"
    )

    ledger = workspace_ownership_ledger()

    assert {:error, {:owned_identity_mismatch, {:workspace_root_identity_mismatch, _, _}}} =
             Workspace.create_for_issue(issue, nil, ledger)

    assert File.dir?(workspace)
    assert {:ok, [provisioning]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert provisioning.state == :provisioning
  end

  test "atomic workspace creation preserves a path that appears after reservation sync" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-create-race-#{System.unique_integer([:positive])}")
    issue = %Issue{id: "workspace-create-race", identifier: "MT-CREATE-RACE"}
    workspace = Path.join(workspace_root, Workspace.workspace_key(issue.identifier))
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    ledger = workspace_ownership_ledger()

    racing_ledger = %{
      ledger
      | sync_fun: fn table ->
          case :dets.sync(table) do
            :ok ->
              File.mkdir!(workspace)
              File.write!(Path.join(workspace, "foreign"), "created after durable reservation")
              :ok

            error ->
              error
          end
        end
    }

    assert {:error, {:workspace_path_exists, ^workspace}} =
             Workspace.create_for_issue(issue, nil, racing_ledger)

    assert File.read!(Path.join(workspace, "foreign")) == "created after durable reservation"
    assert {:ok, [reserved]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert reserved.state == :reserved
  end

  test "atomic workspace creation preserves its reservation when the root disappears" do
    workspace_root = Path.join(System.tmp_dir!(), "symphony-workspace-parent-race-#{System.unique_integer([:positive])}")
    issue = %Issue{id: "workspace-parent-race", identifier: "MT-PARENT-RACE"}
    workspace = Path.join(workspace_root, Workspace.workspace_key(issue.identifier))
    File.mkdir_p!(workspace_root)

    on_exit(fn -> File.rm_rf(workspace_root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    ledger = workspace_ownership_ledger()

    racing_ledger = %{
      ledger
      | sync_fun: fn table ->
          case :dets.sync(table) do
            :ok ->
              File.rm_rf!(workspace_root)
              :ok

            error ->
              error
          end
        end
    }

    assert {:error, {:workspace_create_failed, ^workspace, :enoent}} =
             Workspace.create_for_issue(issue, nil, racing_ledger)

    refute File.exists?(workspace)
    assert {:ok, [reserved]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert reserved.state == :reserved
  end

  test "before_remove hook replacing a workspace with a file fails the identity recheck" do
    test_root = Path.join(System.tmp_dir!(), "symphony-workspace-file-replacement-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    issue = %Issue{id: "workspace-file-replaced", identifier: "MT-FILE-REPLACED"}
    workspace = Path.join(workspace_root, issue.identifier)
    moved_workspace = workspace <> ".moved"

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    ledger = workspace_ownership_ledger()
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue, nil, ledger)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "mv '#{workspace}' '#{moved_workspace}'; touch '#{workspace}'"
    )

    assert {:error, {:workspace_identity_mismatch, ^workspace, :regular}} =
             Workspace.remove_issue_workspaces(issue, nil, ledger, cleanup_authorized?: true)

    assert File.regular?(workspace)
    assert File.dir?(moved_workspace)
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() ==
             Schema.routed_credential_safe_workspace_write_policy(canonical_default_workspace_root)

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "future-policy",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "future-policy"
    assert config.codex.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.tracker.provider["api_key"] == "$#{api_key_env_var}"
    assert config.tracker.secret_environment_names == ["LINEAR_API_KEY", api_key_env_var]
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "schema preserves adapter-owned provider config while keeping linear aliases compatible" do
    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{
                   endpoint: "https://linear.example.test/graphql",
                   api_key: "provider-token",
                   project_slug: "provider-project",
                   extra: %{team: "platform"}
                 }
               }
             })

    assert settings.tracker.endpoint == "https://linear.example.test/graphql"
    assert settings.tracker.api_key == "provider-token"
    assert settings.tracker.project_slug == "provider-project"
    assert settings.tracker.secret_environment_names == ["LINEAR_API_KEY"]

    assert settings.tracker.provider == %{
             "endpoint" => "https://linear.example.test/graphql",
             "api_key" => "provider-token",
             "project_slug" => "provider-project",
             "assignee" => nil,
             "extra" => %{"team" => "platform"}
           }
  end

  test "linear adapter rejects invalid provider values without crashing config parsing" do
    assert {:ok, invalid_secret_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: 123, project_slug: "project"}
               }
             })

    assert {:error, :missing_linear_api_token} =
             Config.validate_settings(invalid_secret_settings)

    assert {:ok, invalid_endpoint_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", endpoint: 123}
               }
             })

    assert {:error, :invalid_linear_endpoint} =
             Config.validate_settings(invalid_endpoint_settings)

    assert {:ok, invalid_assignee_settings} =
             Schema.parse(%{
               tracker: %{
                 kind: "linear",
                 provider: %{api_key: "token", project_slug: "project", assignee: 123}
               }
             })

    assert {:error, :invalid_linear_assignee} =
             Config.validate_settings(invalid_assignee_settings)
  end

  test "schema does not inject linear defaults before an adapter is selected" do
    assert {:ok, settings} = Schema.parse(%{tracker: %{kind: "future-tracker"}})

    assert settings.tracker.endpoint == nil
    assert settings.tracker.api_key == nil
    assert settings.tracker.active_states == nil
    assert settings.tracker.terminal_states == nil
    assert settings.tracker.provider == %{}
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    tracker:
      kind: memory
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{" In Progress " => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]

    whitespace_state_changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"   " => 1}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert whitespace_state_changeset.errors == [
             limits: {"state names must not be blank", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{kind: "linear", api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "runtime sandbox policy resolution passes explicit policies through unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => ["relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
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
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"
      canonical_root = "/remote/home/.symphony-remote-workspaces"
      host_identity = "host-remote-test"
      host_identity_path = "/remote/home/.local/state/symphony/workspace-ownership/host.identity"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      response_count_file="$trace_file.prepare-count"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      if printf '%s' "$*" | grep -q 'workspace_identity=-'; then
        response_count=0
        if [ -f "$response_count_file" ]; then
          response_count=$(cat "$response_count_file")
        fi
        response_count=$((response_count + 1))
        printf '%s\\n' "$response_count" > "$response_count_file"

        if [ "$response_count" -eq 1 ]; then
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '0' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '-' '#{host_identity_path}'
        elif [ "$response_count" -eq 4 ]; then
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '1' '#{workspace_path}' '#{canonical_root}' 'host-changed' '1:2' '2:3' '#{host_identity_path}'
        else
          printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '1' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '2:3' '#{host_identity_path}'
        fi
      elif printf '%s' "$*" | grep -q '__SYMPHONY_WORKSPACE_PREPARE__'; then
        printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '#{workspace_path}' '2:3' '1:2'
      fi

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      ownership_state = workspace_ownership_state()
      ledger = ownership_state.workspace_ownership_ledger

      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200", ledger)
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200", ledger)
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.different-remote-workspaces",
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_remove: "echo before-remove"
      )

      assert {:error, {:workspace_configured_root_mismatch, _, _}} =
               Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200", ledger, cleanup_authorized?: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_remove: "echo before-remove"
      )

      assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, "MT-SSH-WS")
      assert pending.state == :release_pending
      assert {:error, {:workspace_identity_mismatch, _}} = Workspace.cancel_pending_release_if_current(pending, ledger)
      assert :ok = Workspace.cancel_pending_release_if_current(pending, ledger)

      assert :ok =
               Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200", ledger, cleanup_authorized?: true)

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE_PREPARE__"
      assert trace =~ host_identity
      assert trace =~ canonical_root
      assert trace =~ "~/.symphony-remote-workspaces/MT-SSH-WS"
      assert trace =~ "${workspace#\\~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf --"
      assert trace =~ "[ ! -e \"$workspace\" ] && [ ! -L \"$workspace\" ]"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  test "remote cleanup deletes the detached workspace and preserves a replacement at its original path" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-workspace-detach-race-#{System.unique_integer([:positive])}")
    remote_home = Path.join(test_root, "remote-home")
    workspace_root = Path.join(remote_home, "workspaces")
    issue = %Issue{id: "remote-workspace-detach-race", identifier: "MT-REMOTE-DETACH-RACE"}
    workspace_path = Path.join(workspace_root, issue.identifier)
    host_identity = "host-remote-detach-race"
    host_identity_path = Path.join(remote_home, ".local/state/symphony/workspace-ownership/host.identity")
    host_identity_dir = Path.dirname(host_identity_path)
    worker_host = "worker-remote-detach-race"
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_home = System.get_env("HOME")
    previous_race_workspace = System.get_env("SYMP_TEST_REMOTE_RACE_WORKSPACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("HOME", previous_home)
      restore_env("SYMP_TEST_REMOTE_RACE_WORKSPACE", previous_race_workspace)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(workspace_root)
    File.mkdir_p!(host_identity_dir)
    File.chmod!(host_identity_dir, 0o700)
    File.write!(host_identity_path, host_identity <> "\n")
    File.chmod!(host_identity_path, 0o600)
    File.mkdir!(workspace_path)
    File.write!(Path.join(workspace_path, "owned"), "owned")

    File.write!(fake_ssh, """
    #!/usr/bin/env bash
    set -euo pipefail
    remote_command="${!#}"

    rm() {
      if [ "${1:-}" = "-rf" ] && [ "${SYMP_TEST_REMOTE_RACE_DONE:-0}" != "1" ]; then
        if [ -e "$SYMP_TEST_REMOTE_RACE_WORKSPACE" ]; then
          /bin/mv -- "$SYMP_TEST_REMOTE_RACE_WORKSPACE" "$SYMP_TEST_REMOTE_RACE_WORKSPACE.owned"
        fi
        /bin/mkdir -p -- "$SYMP_TEST_REMOTE_RACE_WORKSPACE"
        /usr/bin/printf 'foreign\\n' > "$SYMP_TEST_REMOTE_RACE_WORKSPACE/foreign"
        export SYMP_TEST_REMOTE_RACE_DONE=1
      fi

      command rm "$@"
    }

    export -f rm
    exec /bin/bash -lc "$remote_command"
    """)

    File.chmod!(fake_ssh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
    System.put_env("HOME", remote_home)
    System.put_env("SYMP_TEST_REMOTE_RACE_WORKSPACE", workspace_path)
    System.delete_env("SYMP_TEST_REMOTE_RACE_DONE")

    {root_identity, 0} = System.cmd("stat", ["-c", "%d:%i", workspace_root])
    {workspace_identity, 0} = System.cmd("stat", ["-c", "%d:%i", workspace_path])

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: [worker_host]
    )

    ledger = workspace_ownership_ledger()

    attrs = %{
      issue_identifier: issue.identifier,
      work_item_id: issue.id,
      workspace_key: Workspace.workspace_key(issue.identifier),
      workspace_ownership_id: "workspace-" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower),
      location: :remote,
      worker_host: worker_host,
      trusted_host_identity: host_identity,
      configured_root: workspace_root,
      configured_root_identity: String.trim(root_identity),
      canonical_root: workspace_root,
      canonical_workspace_path: workspace_path
    }

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, attrs)

    assert {:ok, provisioning} =
             OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :provisioning,
               configured_root_identity: String.trim(root_identity),
               top_level_filesystem_identity: String.trim(workspace_identity)
             )

    assert {:ok, _owned} =
             OwnershipLedger.transition_sync(ledger, provisioning.workspace_ownership_id, :owned)

    assert :ok =
             Workspace.remove_issue_workspaces(issue, worker_host, ledger, cleanup_authorized?: true)

    assert File.read!(Path.join(workspace_path, "foreign")) == "foreign\n"
    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "remote after_create failures release a workspace through the guarded remote removal path" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-hook-failure-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    workspace_root = "~/.symphony-remote-failure-workspaces"
    workspace_path = "/remote/home/.symphony-remote-failure-workspaces/MT-REMOTE-FAIL"
    canonical_root = "/remote/home/.symphony-remote-failure-workspaces"
    host_identity = "host-remote-failure"
    host_identity_path = "/remote/home/.local/state/symphony/workspace-ownership/host.identity"

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE}"
    response_count_file="$trace_file.prepare-count"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    if printf '%s' "$*" | grep -q 'workspace_identity=-'; then
      response_count=0
      if [ -f "$response_count_file" ]; then response_count=$(cat "$response_count_file"); fi
      response_count=$((response_count + 1))
      printf '%s\\n' "$response_count" > "$response_count_file"
      if [ "$response_count" -eq 1 ]; then
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '0' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '-' '#{host_identity_path}'
      fi
    elif printf '%s' "$*" | grep -q 'exit 17'; then
      exit 17
    elif printf '%s' "$*" | grep -q 'rm -rf --'; then
      exit 0
    elif printf '%s' "$*" | grep -q '__SYMPHONY_WORKSPACE_PREPARE__'; then
      printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '#{workspace_path}' '3:4' '1:2'
    fi

    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: ["worker-failure"],
      hook_after_create: "exit 17"
    )

    issue = %Issue{id: "remote-hook-failure", identifier: "MT-REMOTE-FAIL", state: "In Progress"}
    ledger = workspace_ownership_ledger()

    assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
             Workspace.create_for_issue(issue, "worker-failure", ledger)

    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "remote probe failures never authorize workspace creation or removal" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-probe-failure-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    worker_host = "worker-probe-failure"
    workspace_root = "~/.symphony-probe-failure-workspaces"
    canonical_root = "/remote/home/.symphony-probe-failure-workspaces"
    issue = %Issue{id: "remote-probe-failure", identifier: "MT-REMOTE-PROBE-FAILURE"}
    workspace_key = Workspace.workspace_key(issue.identifier)
    workspace_path = Path.join(canonical_root, workspace_key)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
    File.write!(fake_ssh, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$SYMP_TEST_SSH_TRACE\"\nprintf 'probe failed\\n'\nexit 42\n")
    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: [worker_host]
    )

    ledger = workspace_ownership_ledger()

    assert {:error, {:workspace_prepare_failed, ^worker_host, 42, output}} =
             Workspace.create_for_issue(issue, worker_host, ledger)

    assert output =~ "probe failed"
    assert {:ok, []} = OwnershipLedger.list_for_work_item(ledger, issue.id)

    malformed_issue = %{issue | id: "remote-malformed-probe", identifier: "MT-REMOTE-MALFORMED-PROBE"}
    malformed_workspace_path = Path.join(canonical_root, Workspace.workspace_key(malformed_issue.identifier))

    File.write!(fake_ssh, """
    #!/bin/sh
    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '1' '#{malformed_workspace_path}' '#{canonical_root}' 'trusted-remote-host' '1:2' '-' '/remote/home/.local/state/symphony/workspace-ownership/host.identity'
    """)

    assert {:error, {:workspace_prepare_failed, :invalid_output, _output}} =
             Workspace.create_for_issue(malformed_issue, worker_host, ledger)

    assert {:ok, []} = OwnershipLedger.list_for_work_item(ledger, malformed_issue.id)

    File.write!(fake_ssh, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"
    printf 'probe failed\\n'
    exit 42
    """)

    File.chmod!(fake_ssh, 0o755)

    remote_record = %{
      work_item_id: issue.id,
      issue_identifier: issue.identifier,
      workspace_key: workspace_key,
      workspace_ownership_id: "remote-probe-failure-owned",
      location: :remote,
      worker_host: worker_host,
      trusted_host_identity: "trusted-remote-host",
      configured_root: workspace_root,
      configured_root_identity: "1:2",
      canonical_root: canonical_root,
      canonical_workspace_path: workspace_path,
      top_level_filesystem_identity: nil
    }

    assert {:ok, reserved} = OwnershipLedger.reserve_sync(ledger, remote_record)

    assert {:ok, _provisioning} =
             OwnershipLedger.transition_sync(
               ledger,
               reserved.workspace_ownership_id,
               :provisioning,
               top_level_filesystem_identity: "1:3"
             )

    assert {:ok, _owned} = OwnershipLedger.transition_sync(ledger, reserved.workspace_ownership_id, :owned)

    assert {:error, {:workspace_remove_failed, ^worker_host, 42, output}} =
             Workspace.remove_issue_workspaces(issue, worker_host, ledger, cleanup_authorized?: true)

    assert output =~ "probe failed"
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending
    trace = File.read!(trace_file)
    assert trace =~ "workspace_identity=-"
    assert trace =~ "rm -rf --"
    {identity_guard_offset, _length} = List.last(:binary.matches(trace, "workspace_identity="))
    {remove_offset, _length} = :binary.match(trace, "rm -rf --")
    assert identity_guard_offset < remove_offset
  end

  test "remote failed-provision cleanup stays pending after an ambiguous SSH result" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-cleanup-ambiguous-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    previous_remove_failure = System.get_env("SYMP_TEST_REMOTE_REMOVE_FAIL")
    worker_host = "worker-cleanup-ambiguous"
    workspace_root = "~/.symphony-cleanup-ambiguous-workspaces"
    canonical_root = "/remote/home/.symphony-cleanup-ambiguous-workspaces"
    workspace_path = Path.join(canonical_root, "MT-REMOTE-CLEANUP-AMBIGUOUS")
    host_identity = "host-remote-cleanup-ambiguous"
    host_identity_path = "/remote/home/.local/state/symphony/workspace-ownership/host.identity"
    issue = %Issue{id: "remote-cleanup-ambiguous", identifier: "MT-REMOTE-CLEANUP-AMBIGUOUS"}

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      restore_env("SYMP_TEST_REMOTE_REMOVE_FAIL", previous_remove_failure)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("SYMP_TEST_REMOTE_REMOVE_FAIL", "1")
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "$SYMP_TEST_SSH_TRACE"

    if printf '%s' "$*" | grep -q 'workspace_identity=-'; then
      printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '0' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '-' '#{host_identity_path}'
    elif printf '%s' "$*" | grep -q 'exit 17'; then
      printf 'bootstrap failed\\n'
      exit 17
    elif printf '%s' "$*" | grep -q 'rm -rf --'; then
      if [ "${SYMP_TEST_REMOTE_REMOVE_FAIL:-0}" = 1 ]; then
        printf 'remote result is ambiguous\\n'
        exit 42
      fi
      exit 0
    else
      printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '#{workspace_path}' '2:3' '1:2'
    fi

    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: [worker_host],
      hook_after_create: "exit 17"
    )

    ledger = workspace_ownership_ledger()

    assert {:error, {:after_create_cleanup_failed, hook_error, removal_error}} =
             Workspace.create_for_issue(issue, worker_host, ledger)

    assert {:workspace_hook_failed, "after_create", 17, _} = hook_error
    assert {:workspace_remove_failed, ^worker_host, 42, output} = removal_error

    assert output =~ "remote result is ambiguous"
    assert {:ok, [pending]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert pending.state == :release_pending
    assert pending.release_origin == :failed_provisioning

    assert {:error, :failed_provisioning_release_cannot_be_cancelled} =
             Workspace.cancel_pending_release_if_current(pending, ledger)

    System.put_env("SYMP_TEST_REMOTE_REMOVE_FAIL", "0")

    assert {:ok, [^workspace_path]} =
             Workspace.remove_recorded(workspace_path, worker_host, ledger, cleanup_authorized?: true)

    assert {:ok, [released]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert released.state == :released
  end

  test "remote mkdir ambiguity leaves a reservation that cannot adopt a later path" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-mkdir-ambiguous-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    worker_host = "worker-mkdir-ambiguous"
    workspace_root = "~/.symphony-mkdir-ambiguous-workspaces"
    canonical_root = "/remote/home/.symphony-mkdir-ambiguous-workspaces"
    issue = %Issue{id: "remote-mkdir-ambiguous", identifier: "MT-REMOTE-MKDIR-AMBIGUOUS"}
    workspace_path = Path.join(canonical_root, Workspace.workspace_key(issue.identifier))
    host_identity = "host-remote-mkdir-ambiguous"
    host_identity_path = "/remote/home/.local/state/symphony/workspace-ownership/host.identity"

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="$SYMP_TEST_SSH_TRACE"
    count_file="$trace_file.probes"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    if printf '%s' "$*" | grep -q 'workspace_identity=-'; then
      count=0
      if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
      count=$((count + 1))
      printf '%s\\n' "$count" > "$count_file"
      if [ "$count" -eq 1 ]; then
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '0' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '-' '#{host_identity_path}'
      else
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '1' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '2:3' '#{host_identity_path}'
      fi
    elif printf '%s' "$*" | grep -q 'mkdir "\\$workspace"'; then
      printf 'mkdir outcome unknown\\n'
      exit 42
    fi

    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: [worker_host]
    )

    ledger = workspace_ownership_ledger()

    assert {:error, {:workspace_prepare_failed, ^worker_host, 42, output}} =
             Workspace.create_for_issue(issue, worker_host, ledger)

    assert output =~ "mkdir outcome unknown"
    assert {:ok, [reserved]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert reserved.state == :reserved

    assert {:error, {:workspace_ownership_required, ^workspace_path}} =
             Workspace.create_for_issue(issue, worker_host, ledger)

    assert {:ok, [still_reserved]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert still_reserved.workspace_ownership_id == reserved.workspace_ownership_id
    assert still_reserved.state == :reserved
  end

  test "remote post-create identity drift leaves the workspace provisioning" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-owned-mismatch-#{System.unique_integer([:positive])}")
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")
    worker_host = "worker-post-create-mismatch"
    workspace_root = "~/.symphony-post-create-mismatch-workspaces"
    canonical_root = "/remote/home/.symphony-post-create-mismatch-workspaces"
    issue = %Issue{id: "remote-post-create-mismatch", identifier: "MT-REMOTE-POST-CREATE-MISMATCH"}
    workspace_path = Path.join(canonical_root, Workspace.workspace_key(issue.identifier))
    host_identity = "host-remote-post-create-mismatch"
    host_identity_path = "/remote/home/.local/state/symphony/workspace-ownership/host.identity"

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="$SYMP_TEST_SSH_TRACE"
    count_file="$trace_file.probes"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"

    if printf '%s' "$*" | grep -q 'workspace_identity=-'; then
      count=0
      if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
      count=$((count + 1))
      printf '%s\\n' "$count" > "$count_file"
      if [ "$count" -eq 1 ]; then
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '0' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '-' '#{host_identity_path}'
      else
        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '1' '#{workspace_path}' '#{canonical_root}' '#{host_identity}' '1:2' '9:9' '#{host_identity_path}'
      fi
    elif printf '%s' "$*" | grep -q 'mkdir "\\$workspace"'; then
      printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE_PREPARE__' '#{workspace_path}' '2:3' '1:2'
    fi

    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      worker_ssh_hosts: [worker_host]
    )

    ledger = workspace_ownership_ledger()

    assert {:error, {:owned_identity_mismatch, {:workspace_identity_mismatch, ^workspace_path}}} =
             Workspace.create_for_issue(issue, worker_host, ledger)

    assert {:ok, [provisioning]} = OwnershipLedger.list_for_work_item(ledger, issue.id)
    assert provisioning.state == :provisioning
    assert provisioning.top_level_filesystem_identity == "2:3"
  end

  test "remote workspace hook timeout is returned to the caller" do
    test_root = Path.join(System.tmp_dir!(), "symphony-remote-hook-timeout-#{System.unique_integer([:positive])}")
    fake_ssh = Path.join(test_root, "ssh")
    previous_path = System.get_env("PATH")
    worker_host = "worker-hook-timeout"

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
    File.write!(fake_ssh, "#!/bin/sh\nsleep 1\nexit 0\n")
    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "legacy",
      worker_ssh_hosts: [worker_host],
      hook_before_run: "echo before-run",
      hook_timeout_ms: 1
    )

    assert {:error, {:workspace_hook_timeout, "before_run", 1}} =
             Workspace.run_before_run_hook("/remote/workspace", "MT-TIMEOUT", worker_host)
  end

  test "routed mode skips workspace shell hooks on local and remote workers" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      agent_routing: "routed",
      hook_before_run: "exit 41"
    )

    assert :ok = Workspace.run_before_run_hook("/local/workspace", "MT-ROUTED-HOOK")

    assert capture_log([level: :info], fn ->
             assert :ok = Workspace.run_before_run_hook("/remote/workspace", "MT-ROUTED-HOOK", "worker-routed")
           end) =~ "Skipping workspace hook in routed mode"
  end

  test "local workspace hook timeout is returned to the caller" do
    workspace = Path.join(System.tmp_dir!(), "symphony-local-hook-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "legacy",
      hook_before_run: "sleep 1",
      hook_timeout_ms: 1
    )

    assert {:error, {:workspace_hook_timeout, "before_run", 1}} =
             Workspace.run_before_run_hook(workspace, "MT-LOCAL-TIMEOUT")
  end

  test "remote workspace hook reports SSH setup failures" do
    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)
    System.put_env("PATH", "")

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "legacy",
      hook_before_run: "echo before-run",
      hook_timeout_ms: 1_000
    )

    assert {:error, :ssh_not_found} =
             Workspace.run_before_run_hook("/remote/workspace", "MT-SSH-SETUP-FAILURE", "worker-missing-ssh")
  end

  test "workspace removal defaults to denied and rejects invalid worker hosts" do
    assert {:error, :workspace_cleanup_authorization_required} =
             Workspace.remove_issue_workspaces("MT-UNAUTHORIZED-REMOVE")

    assert {:error, :invalid_worker_host} =
             Workspace.remove_issue_workspaces("MT-INVALID-HOST", 42, [])
  end

  test "remote workspace removal rejects an empty workspace path before probing the host" do
    assert {:error, {:workspace_path_unreadable, "", :invalid}, ""} =
             Workspace.remove_recorded("", "worker-empty-path", workspace_ownership_ledger(), cleanup_authorized?: true)
  end
end
