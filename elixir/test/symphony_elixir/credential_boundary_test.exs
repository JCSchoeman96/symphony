defmodule SymphonyElixir.CredentialBoundaryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CredentialBoundary
  alias SymphonyElixir.Workflow

  test "deny list always includes canonical provider and scm delegation env names" do
    deny = CredentialBoundary.deny_environment_names([])

    for name <-
          ~w(PLANE_API_KEY PLANE_WEBHOOK_SECRET GITHUB_TOKEN GH_TOKEN SSH_AUTH_SOCK SSH_AGENT_PID GIT_ASKPASS GIT_SSH_COMMAND GH_CONFIG_DIR GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT) do
      assert name in deny
    end
  end

  test "unset command includes canonical deny names even without configured secrets" do
    assert CredentialBoundary.unset_shell_command([]) =~ "unset "
    assert CredentialBoundary.unset_shell_command([]) =~ "PLANE_API_KEY"
    assert CredentialBoundary.unset_shell_command([]) =~ "PLANE_WEBHOOK_SECRET"
  end

  test "routed workspace hooks are skipped and their shell launcher is disabled" do
    root = Path.join(System.tmp_dir!(), "h080b-routed-hook-#{System.unique_integer([:positive])}")
    workflow = Path.join(root, "WORKFLOW.md")
    previous_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    File.mkdir_p!(root)

    SymphonyElixir.TestSupport.write_workflow_file!(workflow,
      agent_routing: "routed",
      symphony_project_id: "h080b-hook-test",
      tracker_kind: "memory"
    )

    Workflow.set_workflow_file_path(workflow)

    on_exit(fn ->
      if previous_workflow_path do
        Workflow.set_workflow_file_path(previous_workflow_path)
      else
        Workflow.clear_workflow_file_path()
      end

      File.rm_rf(root)
    end)

    for hook <- ~w(before_run after_run before_remove) do
      assert CredentialBoundary.routed_workspace_shell_hook_skipped?(hook)
    end

    refute CredentialBoundary.routed_workspace_shell_hook_skipped?("custom_hook")
    assert CredentialBoundary.routed_unset_shell_command([]) =~ "unset "
  end

  test "port env marks every denied variable as unset" do
    env = CredentialBoundary.port_env(["EXTRA_SECRET"])
    assert {~c"PLANE_API_KEY", false} in env
    assert {~c"PLANE_WEBHOOK_SECRET", false} in env
    assert {~c"EXTRA_SECRET", false} in env
  end

  test "probe env disables prompting helpers" do
    env = CredentialBoundary.probe_process_env([])
    assert {"GIT_TERMINAL_PROMPT", "0"} in env
    assert {"GIT_ASKPASS", nil} in env
    assert {"SSH_ASKPASS", nil} in env
  end

  test "redact leaves messages unchanged when no secret value is present" do
    assert CredentialBoundary.redact("safe output", ["PLANE_API_KEY"]) == "safe output"
  end

  test "redact ignores configured secrets whose current value is empty" do
    previous = System.get_env("SYMPHONY_H080B_EMPTY_SECRET")
    System.put_env("SYMPHONY_H080B_EMPTY_SECRET", "")
    on_exit(fn -> restore_env("SYMPHONY_H080B_EMPTY_SECRET", previous) end)

    assert CredentialBoundary.redact("safe output", ["SYMPHONY_H080B_EMPTY_SECRET"]) == "safe output"
  end

  test "routed port env clears credential channels and binds every home to session state" do
    names = ~w(
      SSH_AGENT_PID GH_CONFIG_DIR GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
      GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
      XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS PLANE_API_KEY
    )

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.put_env(&1, "h080b-env-sentinel"))

    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)

    home = Path.join(System.tmp_dir!(), "h080b-routed-home-#{System.unique_integer([:positive])}")
    codex_home = Path.join(home, "codex")
    env = CredentialBoundary.routed_port_env(["CUSTOM_TRACKER_SECRET"], home, codex_home)
    values = Map.new(env, fn {name, value} -> {List.to_string(name), value} end)

    for name <- names ++ ["CUSTOM_TRACKER_SECRET"] do
      assert values[name] == false
    end

    assert values["HOME"] == String.to_charlist(home)
    assert values["CODEX_HOME"] == String.to_charlist(codex_home)
    assert values["XDG_CONFIG_HOME"] == String.to_charlist(Path.join(home, ".config"))
    assert values["XDG_STATE_HOME"] == String.to_charlist(Path.join(home, ".local/state"))
    assert values["XDG_CACHE_HOME"] == String.to_charlist(Path.join(home, ".cache"))
    assert values["TMPDIR"] == String.to_charlist(Path.join(home, "tmp"))
    assert values["SHELL"] == String.to_charlist("/bin/sh")
    assert values["GIT_CONFIG_NOSYSTEM"] == String.to_charlist("1")
  end

  test "routed approval policy disables every elevation prompt" do
    policy = CredentialBoundary.routed_safe_approval_policy()

    assert policy == %{
             "granular" => %{
               "sandbox_approval" => false,
               "rules" => false,
               "mcp_elicitations" => false,
               "request_permissions" => false,
               "skill_approval" => false
             }
           }
  end

  test "workspace Git config rejects credential channels without returning their values" do
    root = Path.join(System.tmp_dir!(), "h080b-git-config-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    config = Path.join(workspace, ".git/config")
    File.mkdir_p!(Path.dirname(config))

    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(config, """
    [core]
      repositoryformatversion = 0
    [remote "origin"]
      url = https://github.com/openai/codex.git
    """)

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    unsafe_configs = [
      """
      [credential]
        helper = !echo sentinel
      """,
      """
      [http]
        extraHeader = Authorization: sentinel
      """,
      """
      [core]
        sshCommand = ssh -i /tmp/id_sentinel
      """,
      """
      [include]
        path = /outside/credentials.config
      """,
      """
      [remote "origin"]
        url = https://user:sentinel@github.com/openai/codex.git
      """,
      """
      [remote "origin"]
        url = https://github.com/openai/codex.git?access_token=sentinel
      """,
      """
      [remote "origin"]
        url = https://github.com/openai/codex.git?access_token=%
      """,
      """
      [remote "origin"]
        url = alice@github.com:openai/codex.git
      """,
      """
      [remote "origin"]
        url = ssh://git:sentinel@github.com/openai/codex.git
      """,
      """
      [remote "origin"]
        url = ssh://alice@github.com/openai/codex.git
      """,
      """
      [remote "origin"]
        url = git+ssh://alice:sentinel@github.com/openai/codex.git
      """,
      """
      [credential "https://example.com"]
        password = sentinel
      """,
      """
      [http]
        proxy = https://user:sentinel@proxy.example
      """,
      """
      [url "https://user:sentinel@github.com/"]
        insteadOf = https://github.com/
      """,
      """
      [url "https://user:sentinel@github.com/"]
        pushInsteadOf = https://github.com/
      """
    ]

    Enum.each(unsafe_configs, fn unsafe_config ->
      File.write!(config, unsafe_config)

      assert {:error, {:unsafe_workspace_scm_credentials, _reason}} =
               CredentialBoundary.workspace_credential_residue(workspace)
    end)

    File.rm!(config)
    File.ln_s!(Path.join(root, "missing-config"), config)

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_symlink}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(config)
    File.write!(config, String.duplicate("x", 1_048_577))

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_too_large}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    worktree_config = Path.join(Path.dirname(config), "config.worktree")
    File.write!(config, "[extensions]\n  worktreeConfig = true\n")

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(worktree_config, "[credential]\n  helper = !echo h080b-worktree-secret\n")

    assert {:error, {:unsafe_workspace_scm_credentials, :credential_bearing_git_config}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(worktree_config)
    File.ln_s!(Path.join(root, "missing-worktree-config"), worktree_config)

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_symlink}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(worktree_config)
    {_, 0} = System.cmd("mkfifo", [worktree_config])

    assert {:error, {:unsafe_workspace_scm_credentials, {:git_config_type, :other}}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(worktree_config)
    File.write!(worktree_config, String.duplicate("x", 1_048_577))

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_too_large}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(config, "[extensions]\n  worktreeConfig = false\n")

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)
  end

  test "ordinary workspaces without Git metadata and safe Git remotes pass the credential check" do
    root = Path.join(System.tmp_dir!(), "h080b-git-safe-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "plain-workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.mkdir_p!(Path.join(workspace, ".git"))

    File.write!(Path.join(workspace, ".git/config"), """
    [remote "origin"]
      url = git@github.com:openai/symphony.git
    [extensions]
      worktreeConfig = true
    """)

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(Path.join(workspace, ".git/config.worktree"), "[remote \"upstream\"]\n  url = ssh://git@github.com/openai/symphony.git\n")

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(Path.join(workspace, ".git/config"), "[core]\n  bare\n")

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)
  end

  test "workspace Git metadata paths reject missing, symlinked, malformed, and external state" do
    root = Path.join(System.tmp_dir!(), "h080b-git-paths-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, {:unsafe_workspace_scm_credentials, :invalid_workspace}} =
             CredentialBoundary.workspace_credential_residue(:invalid)

    assert {:error, {:unsafe_workspace_scm_credentials, :workspace_missing}} =
             CredentialBoundary.workspace_credential_residue(Path.join(root, "missing"))

    assert {:error, {:unsafe_workspace_scm_credentials, :badarg}} =
             CredentialBoundary.workspace_credential_residue(<<0>>)

    regular_file = Path.join(root, "not-a-workspace")
    File.write!(regular_file, "file")

    assert {:error, {:unsafe_workspace_scm_credentials, {:workspace_type, :regular}}} =
             CredentialBoundary.workspace_credential_residue(regular_file)

    workspace_link = Path.join(root, "workspace-link")
    File.ln_s!(workspace, workspace_link)

    assert {:error, {:unsafe_workspace_scm_credentials, :workspace_symlink}} =
             CredentialBoundary.workspace_credential_residue(workspace_link)

    git_link = Path.join(workspace, ".git")
    File.ln_s!(root, git_link)

    assert {:error, {:unsafe_workspace_scm_credentials, :git_metadata_symlink}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(git_link)
    File.write!(git_link, "not a git directory pointer")

    assert {:error, {:unsafe_workspace_scm_credentials, :git_metadata_pointer_invalid}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(git_link)
    {_, 0} = System.cmd("mkfifo", [git_link])

    assert {:error, {:unsafe_workspace_scm_credentials, :unreadable}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(git_link)

    loop = Path.join(workspace, "gitdir-loop")
    File.ln_s!("gitdir-loop", loop)
    File.write!(git_link, "gitdir: gitdir-loop\n")

    assert {:error, {:unsafe_workspace_scm_credentials, :git_metadata_pointer_invalid}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(loop)

    File.write!(git_link, "gitdir: ../outside-git\n")

    assert {:error, {:unsafe_workspace_scm_credentials, :git_metadata_outside_workspace}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(git_link, "gitdir: missing-git-directory\n")

    assert {:error, {:unsafe_workspace_scm_credentials, :git_metadata_target_missing}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(git_link, "gitdir: .git-directory\n")
    File.mkdir!(Path.join(workspace, ".git-directory"))

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(git_link)
    File.mkdir!(git_link)
    config = Path.join(git_link, "config")

    assert :ok = CredentialBoundary.workspace_credential_residue(workspace)

    File.ln_s!(regular_file, config)

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_symlink}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm!(config)
    File.mkdir!(config)

    assert {:error, {:unsafe_workspace_scm_credentials, {:git_config_type, :directory}}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.rm_rf!(config)
    File.write!(config, String.duplicate("x", 1_048_577))

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_too_large}} =
             CredentialBoundary.workspace_credential_residue(workspace)

    File.write!(config, "[invalid section\n")

    assert {:error, {:unsafe_workspace_scm_credentials, :git_config_unreadable}} =
             CredentialBoundary.workspace_credential_residue(workspace)
  end

  test "redact ignores non-list secret name inputs" do
    assert CredentialBoundary.redact("safe output", :not_a_list) == "safe output"
  end

  test "valid_environment_name? guards identifier syntax" do
    refute CredentialBoundary.valid_environment_name?(nil)
    assert CredentialBoundary.valid_environment_name?("A1")
  end

  test "deny list ignores malformed configured secret names" do
    deny = CredentialBoundary.deny_environment_names(["bad name", "GOOD_NAME"])
    assert "GOOD_NAME" in deny
    refute "bad name" in deny
  end

  test "hook env clears active host secrets for spawned children" do
    previous_token = System.get_env("GITHUB_TOKEN")
    previous_xdg = System.get_env("XDG_STATE_HOME")
    System.put_env("GITHUB_TOKEN", "sentinel-github-token")
    System.put_env("XDG_STATE_HOME", "/tmp/symphony-real-attempt-ledger")

    on_exit(fn ->
      restore_env("GITHUB_TOKEN", previous_token)
      restore_env("XDG_STATE_HOME", previous_xdg)
    end)

    env = CredentialBoundary.hook_process_env([])

    assert {"GITHUB_TOKEN", nil} in env
    assert {"XDG_STATE_HOME", nil} in env

    {output, _} =
      System.cmd("sh", ["-c", "printenv GITHUB_TOKEN; printenv XDG_STATE_HOME; true"], env: env)

    refute output =~ "sentinel-github-token"
    refute output =~ "symphony-real-attempt-ledger"
  end

  defp restore_env(name, previous) do
    case previous do
      nil -> System.delete_env(name)
      value -> System.put_env(name, value)
    end
  end
end
