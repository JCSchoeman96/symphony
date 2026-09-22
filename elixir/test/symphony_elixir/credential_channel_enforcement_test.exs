defmodule SymphonyElixir.CredentialChannelEnforcementTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, CredentialBoundary, Workflow}
  alias SymphonyElixir.GitHub.SourceControl
  alias SymphonyElixir.Plane.Client
  alias SymphonyElixir.SourceControl.RepositoryProbe

  @plane_config %{
    base_url: "https://api.plane.so",
    workspace_slug: "workspace-1",
    workspace_id: "workspace-id-1",
    project_id: "project-1",
    api_key: "secret"
  }

  @github_config %{
    kind: :github,
    repository: "JCSchoeman96/symphony",
    repository_id: 1,
    base_branch: "main",
    token_env: "GITHUB_TOKEN",
    required_checks: [%{context: "ci", app_id: 1, subject: "head"}]
  }

  test "credential boundary expands configured secrets and standard SCM channels" do
    names = CredentialBoundary.deny_environment_names(["CUSTOM_GITHUB_TOKEN"])

    assert "PLANE_API_KEY" in names
    assert "GITHUB_TOKEN" in names
    assert "GH_TOKEN" in names
    assert "CUSTOM_GITHUB_TOKEN" in names
    assert "SSH_AUTH_SOCK" in names
    assert "GIT_SSH_COMMAND" in names
  end

  test "credential boundary builds port env, unset commands, and hook env" do
    deny = CredentialBoundary.deny_environment_names(["CUSTOM_TOKEN"])
    assert CredentialBoundary.unset_shell_command(["CUSTOM_TOKEN"]) =~ "unset "
    assert CredentialBoundary.unset_shell_command(["CUSTOM_TOKEN"]) =~ "CUSTOM_TOKEN"
    assert CredentialBoundary.port_env(["CUSTOM_TOKEN"]) != []
    refute Enum.any?(CredentialBoundary.hook_process_env(["CUSTOM_TOKEN"]), fn {name, _} -> name == "CUSTOM_TOKEN" end)
    assert "PLANE_API_KEY" in deny
  end

  test "credential boundary redacts configured secret values from strings" do
    previous = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "sentinel-plane-secret")

    on_exit(fn -> restore_env("PLANE_API_KEY", previous) end)

    redacted =
      CredentialBoundary.redact("leaked sentinel-plane-secret in output", ["PLANE_API_KEY"])

    refute redacted =~ "sentinel-plane-secret"
    assert redacted =~ "[REDACTED]"
  end

  test "credential boundary rejects malformed environment names" do
    refute CredentialBoundary.valid_environment_name?("")
    refute CredentialBoundary.valid_environment_name?("not-valid")
    assert CredentialBoundary.valid_environment_name?("VALID_TOKEN_1")
  end

  test "plane production transport rejects alternate https origins" do
    assert {:error, :invalid_base_url} =
             Client.get_project(%{@plane_config | base_url: "https://attacker.invalid"})
  end

  test "plane production transport keeps the canonical origin" do
    assert :ok = Client.validate_config(@plane_config)
    assert Client.default_base_url() == "https://api.plane.so"
  end

  test "github transport preserves already-normalized errors" do
    error = %SourceControl.Error{kind: :transport_failed, detail: :timeout}

    opts = [
      token: "token",
      http_request: fn _url, _headers -> {:error, error} end
    ]

    assert {:error, %SourceControl.Error{kind: :transport_failed, detail: :timeout}} =
             SourceControl.fetch_repository(@github_config, opts)
  end

  test "github transport ignores production api_url overrides" do
    parent = self()

    opts = [
      token: "sentinel-token-value",
      http_request: fn url, _headers ->
        send(parent, {:url, url})
        {:error, "sentinel-token-value leaked in transport"}
      end,
      api_url: "https://attacker.invalid"
    ]

    assert {:error, %SourceControl.Error{kind: :transport_failed, detail: detail}} =
             SourceControl.fetch_repository(@github_config, opts)

    refute inspect(detail) =~ "sentinel-token-value"
    assert_receive {:url, "https://api.github.com/repos/JCSchoeman96/symphony"}
  end

  test "invalid github token_env is rejected during schema validation" do
    alias SymphonyElixir.Config.Schema.SourceControl

    changeset =
      SourceControl.changeset(%SourceControl{}, %{
        kind: "github",
        repository: "octo/symphony",
        repository_id: 1_368_436_395,
        base_branch: "main",
        token_env: "not a valid env",
        required_checks: [%{context: "ci", app_id: 1, subject: "head"}]
      })

    refute changeset.valid?
    assert {"must be a valid environment variable name", _} = changeset.errors[:token_env]
  end

  test "remote repository probe uses sanitized git argv over ssh" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-remote-probe-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    trace_file = Path.join(test_root, "ssh.trace")
    fake_ssh = Path.join(test_root, "ssh")
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    sha = String.duplicate("b", 40)

    previous_path = System.get_env("PATH")
    System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    trace_file="${SYMP_TEST_SSH_TRACE}"
    printf 'ARGV:%s\\n' "$*" >> "$trace_file"
    printf '\\n%s\\n' "#{sha}"
    exit 0
    """)

    File.chmod!(fake_ssh, 0o755)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    assert {:ok, %{clean?: true, head_sha: head_sha}} =
             RepositoryProbe.probe(%{workspace_path: workspace, worker_host: "worker:22"})

    assert head_sha == sha
    trace = File.read!(trace_file)
    assert trace =~ "core.fsmonitor="
    assert trace =~ "rev-parse"
  end

  test "remote repository probe surfaces ssh git command failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-remote-probe-fail-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    fake_ssh = Path.join(test_root, "ssh")
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

    File.write!(fake_ssh, """
    #!/bin/sh
    echo git failed
    exit 1
    """)

    File.chmod!(fake_ssh, 0o755)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    assert {:error, {:git_command_failed, "git failed"}} =
             RepositoryProbe.probe(%{workspace_path: workspace, worker_host: "worker:22"})
  end

  test "remote repository probe surfaces runner failures" do
    assert {:error, :ssh_unavailable} =
             RepositoryProbe.probe(
               %{workspace_path: "/tmp/workspace", worker_host: "worker-1"},
               remote_command_runner: fn _host, _workspace, _git, _secrets ->
                 {:error, :ssh_unavailable}
               end
             )
  end

  test "repository probe returns git_not_found when git is unavailable" do
    assert {:error, :git_not_found} =
             RepositoryProbe.probe(%{workspace_path: "/tmp/workspace"}, git_executable: nil)
  end

  test "repository probe surfaces local git command failures from the default runner" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-probe-fail-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    assert {:error, {:git_command_failed, _message}} =
             RepositoryProbe.probe(%{workspace_path: root})

    File.rm_rf(root)
  end

  test "repository probe observes a clean local repository through trusted git argv" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-probe-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    assert {_output, 0} = System.cmd("git", ["init"], cd: root)
    assert {_output, 0} = System.cmd("git", ["commit", "--allow-empty", "-m", "probe"], cd: root)

    assert {:ok, %{clean?: true, head_sha: head_sha}} = RepositoryProbe.probe(%{workspace_path: root})
    assert is_binary(head_sha)
    assert byte_size(head_sha) == 40

    File.rm_rf(root)
  end

  test "repository probe uses argv git invocation" do
    command_runner = fn workspace, git_executable, argv ->
      assert is_binary(git_executable)
      assert List.starts_with?(argv, ["-C", workspace])
      assert Enum.member?(argv, "-c")
      assert Enum.member?(argv, "core.fsmonitor=")
      {:ok, ""}
    end

    assert {:ok, %{clean?: true}} =
             RepositoryProbe.probe(%{workspace_path: "/tmp/workspace"},
               command_runner: fn workspace, git, argv ->
                 if Enum.member?(argv, "rev-parse") do
                   {:ok, String.duplicate("a", 40) <> "\n"}
                 else
                   command_runner.(workspace, git, argv)
                 end
               end
             )
  end

  test "routed workspace hook environment omits symphony provider secrets" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "routed",
      tracker_kind: "memory"
    )

    previous = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "sentinel-plane-hook-secret")
    on_exit(fn -> restore_env("PLANE_API_KEY", previous) end)

    env =
      CredentialBoundary.hook_process_env(CredentialBoundary.configured_secret_environment_names())

    refute Enum.any?(env, fn {name, _} -> name == "PLANE_API_KEY" end)
    assert Config.settings!().agent.routing == "routed"
  end

  test "github transport requires a host token" do
    previous = System.get_env("GITHUB_TOKEN")
    System.delete_env("GITHUB_TOKEN")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous) end)

    assert {:error, :missing_source_control_token} =
             SourceControl.fetch_repository(@github_config)
  end

  test "github default transport disables redirects and retries" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})
        {request, Req.Response.new(status: 200, body: %{"id" => 1})}
      end
    )

    on_exit(fn -> Req.default_options([]) end)

    assert {:ok, %{"id" => 1}} = SourceControl.fetch_repository(@github_config, token: "token")
    assert_receive {:request, request}
    assert request.options[:redirect] == false
    assert request.options[:retry] == false
  end

  test "deny_environment_names_from_settings includes tracker and source-control secrets" do
    names = CredentialBoundary.deny_environment_names_from_settings()
    assert "GITHUB_TOKEN" in names
    assert "PLANE_API_KEY" in names
  end

  test "routed profile sandbox forces non-auto approval policy" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "routed",
      codex_approval_policy: "never"
    )

    assert {:ok, settings} =
             Config.codex_runtime_settings("/tmp/workspace", sandbox: "read-only")

    refute settings.approval_policy == "never"
    assert settings.approval_policy == CredentialBoundary.routed_safe_approval_policy()

    assert {:ok, write_settings} =
             Config.codex_runtime_settings("/tmp/workspace", sandbox: "workspace-write")

    assert write_settings.approval_policy == CredentialBoundary.routed_safe_approval_policy()
  end

  test "github default api url stays pinned" do
    assert SourceControl.default_api_url() == "https://api.github.com"
  end

  test "github transport normalizes unexpected failure shapes" do
    opts = [
      token: "sentinel-token-value",
      http_request: fn _url, _headers -> {:error, %{unexpected: true}} end
    ]

    assert {:error, %SourceControl.Error{kind: :transport_failed, detail: :transport_failed}} =
             SourceControl.fetch_repository(@github_config, opts)
  end
end
