defmodule SymphonyElixir.RuntimeIsolationActualCodexTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRuntime.RuntimeIsolation
  alias SymphonyElixir.Codex.IsolationProfile

  @codex_version "codex-cli 0.159.3"

  test "probe cleanup failures discard otherwise successful isolation evidence" do
    assert {:error, {:runtime_isolation_cleanup_failed, :probe_fixture}} =
             IsolationProfile.combine_cleanup_result(
               {:ok, %{verified: true}},
               {:error, {:runtime_isolation_cleanup_failed, :probe_fixture}}
             )

    assert {:ok, %{verified: true}} = IsolationProfile.combine_cleanup_result({:ok, %{verified: true}}, :ok)

    assert {:error, {:runtime_isolation_cleanup_failed, :invalid_cleanup_result}} =
             IsolationProfile.combine_cleanup_result({:ok, %{verified: true}}, :unexpected)
  end

  test "session-home cleanup confirms the temporary root is gone" do
    workspace = Path.join(System.tmp_dir!(), "h080b-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, session_home} = IsolationProfile.prepare_session_home(workspace, "planning", "/bin/true")
    assert File.dir?(session_home.root)
    assert :ok = IsolationProfile.cleanup_session_home(session_home)
    refute File.exists?(session_home.root)
  end

  test "invalid session homes return a cleanup error" do
    assert {:error, {:runtime_isolation_cleanup_failed, :invalid_session_home}} =
             IsolationProfile.cleanup_session_home(nil)
  end

  test "actual probe rejects a failed sandbox command and cleans its fixture" do
    executable = probe_executable!("sleep 0.1\nexit 23\n")

    assert {:error, {:codex_probe_exit, 23}} =
             IsolationProfile.run_actual_probe(executable, executable)
  end

  test "actual probe fails closed when its executable cannot be started" do
    executable = Path.join(System.tmp_dir!(), "h080b-non-executable-#{System.unique_integer([:positive])}")
    File.write!(executable, "#!/bin/sh\nexit 0\n")
    on_exit(fn -> File.rm(executable) end)

    assert {:error, {:codex_probe_spawn_failed, ErlangError}} =
             IsolationProfile.run_actual_probe(executable, executable)
  end

  test "actual probe timeout terminates its process tree and removes its fixture" do
    executable =
      probe_executable!("python3 -c 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' &\nwait\n")

    assert {:error, :codex_probe_timeout} =
             IsolationProfile.run_actual_probe(executable, executable)
  end

  test "actual probe rejects sentinel text in sandbox output" do
    executable = probe_executable!("printf '%s\\n' \"${17}\"\n")

    assert {:error, :codex_probe_output_contains_sentinel} =
             IsolationProfile.run_actual_probe(executable, executable)
  end

  test "actual probe rejects sandbox output without a JSON proof" do
    executable = probe_executable!("printf '%s\\n' 'sandbox output without proof'\n")

    assert {:error, :codex_probe_output_missing} =
             IsolationProfile.run_actual_probe(executable, executable)
  end

  test "actual proof reports a visible host sibling in the synthetic parent" do
    read_results =
      proof_results(:read)
      |> Map.put("workspace_parent_entries", ["workspace", "sibling"])
      |> Map.put("workspace_parent_sibling_name_visible", true)

    executable = proof_executable!(read_results, proof_results(:write))

    assert {:error, {:codex_isolation_probe_failed, :read, mismatches, false}} =
             IsolationProfile.run_actual_probe(executable, executable)

    assert Map.has_key?(mismatches, "workspace_parent_entries")
    assert Map.has_key?(mismatches, "workspace_parent_sibling_name_visible")
  end

  test "actual proof rejects missing synthetic parent write evidence" do
    read_results = Map.put(proof_results(:read), "sandbox_parent_write_succeeded", nil)
    executable = proof_executable!(read_results, proof_results(:write))

    assert {:error, {:codex_isolation_probe_failed, :read, mismatches, false}} =
             IsolationProfile.run_actual_probe(executable, executable)

    assert Map.has_key?(mismatches, "sandbox_parent_write_attempts")
  end

  test "actual proof detects host workspace changes under read-only access" do
    executable =
      proof_executable!(
        proof_results(:read),
        proof_results(:write),
        planner_mutation: true
      )

    assert {:error, {:codex_isolation_probe_failed, :read, mismatches, false}} =
             IsolationProfile.run_actual_probe(executable, executable)

    assert Map.has_key?(mismatches, "host_workspace_unchanged")
  end

  test "actual proof checks the builder's expected workspace mutation snapshot" do
    executable =
      proof_executable!(
        proof_results(:read),
        proof_results(:write),
        builder_mutation: :unexpected_created_content
      )

    assert {:error, {:codex_isolation_probe_failed, :write, mismatches, false}} =
             IsolationProfile.run_actual_probe(executable, executable)

    assert Map.has_key?(mismatches, "host_workspace_matches_expected")
  end

  test "probe result validation accepts private ancestors and rejects incomplete evidence" do
    host_parent_entries = ["workspace", "sibling", "parent-protected.txt"]
    proof = %{results: proof_results(:read), platform: :linux}

    assert {:ok, %{verified: true}} =
             IsolationProfile.validate_probe_results(proof, :read, "workspace", host_parent_entries)

    assert {:error, {:codex_isolation_probe_invalid, :read}} =
             IsolationProfile.validate_probe_results(nil, :read, "workspace", host_parent_entries)

    invalid_results =
      proof.results
      |> Map.put("workspace_read", false)
      |> Map.put("sibling_read", true)
      |> Map.put("workspace_parent_entries", ["workspace", "sibling"])
      |> Map.put("sandbox_parent_write_succeeded", nil)
      |> Map.put("host_workspace_matches_expected", false)
      |> Map.put("host_workspace_unchanged", false)

    assert {:error, {:codex_isolation_probe_failed, :read, mismatches, false}} =
             IsolationProfile.validate_probe_results(
               %{proof | results: invalid_results},
               :read,
               "workspace",
               host_parent_entries
             )

    for key <- [
          "workspace_read",
          "sibling_read",
          "workspace_parent_entries",
          "sandbox_parent_write_attempts",
          "host_workspace_matches_expected",
          "host_workspace_unchanged"
        ] do
      assert Map.has_key?(mismatches, key)
    end
  end

  test "workspace snapshot validation checks builder changes without permitting unrelated edits" do
    directory_metadata = snapshot_metadata(0o755, 10, 2)
    file_metadata = snapshot_metadata(0o644, 11, 1)
    keep_metadata = snapshot_metadata(0o644, 12, 1)

    before = %{
      "" => {:directory, directory_metadata},
      "writable.txt" => {:file, file_metadata, "before\n"},
      "rename-source.txt" => {:file, file_metadata, "rename\n"},
      "delete-target.txt" => {:file, file_metadata, "delete\n"},
      "keep.txt" => {:file, keep_metadata, "keep\n"}
    }

    after_probe = %{
      "" => {:directory, directory_metadata},
      "writable.txt" => {:file, file_metadata, "modified"},
      "created.txt" => {:file, snapshot_metadata(0o644, 13, 1), "created"},
      "renamed.txt" => {:file, file_metadata, "rename\n"},
      "keep.txt" => {:file, keep_metadata, "keep\n"}
    }

    assert IsolationProfile.workspace_matches_expected?(before, before, :read)
    refute IsolationProfile.workspace_matches_expected?(before, after_probe, :read)
    assert IsolationProfile.workspace_matches_expected?(before, after_probe, :write)

    invalid_after_probe = %{
      after_probe
      | "" => {:file, directory_metadata, "wrong type"},
        "created.txt" => :unexpected,
        "writable.txt" => {:file, file_metadata, "unexpected content"},
        "renamed.txt" => :unexpected,
        "keep.txt" => {:file, keep_metadata, "changed"}
    }

    refute IsolationProfile.workspace_matches_expected?(before, invalid_after_probe, :write)
  end

  test "probe and cleanup callbacks normalize unexpected results and exceptions" do
    assert {:ok, :proof} = IsolationProfile.safely_run_probe(fn -> {:ok, :proof} end)
    assert {:error, :denied} = IsolationProfile.safely_run_probe(fn -> {:error, :denied} end)
    assert :ok = IsolationProfile.safely_run_probe(fn -> :ok end)
    assert {:error, :invalid_probe_result} = IsolationProfile.safely_run_probe(fn -> :unexpected end)
    assert {:error, :probe_failed} = IsolationProfile.safely_run_probe(fn -> raise ArgumentError end)
    assert {:error, :probe_failed} = IsolationProfile.safely_run_probe(fn -> throw(:probe_failure) end)

    assert :ok = IsolationProfile.safely_cleanup_probe_resource(fn -> :ok end)
    assert {:error, :denied} = IsolationProfile.safely_cleanup_probe_resource(fn -> {:error, :denied} end)

    assert {:error, {:runtime_isolation_cleanup_failed, :invalid_cleanup_result}} =
             IsolationProfile.safely_cleanup_probe_resource(fn -> :unexpected end)

    assert {:error, {:runtime_isolation_cleanup_failed, ArgumentError}} =
             IsolationProfile.safely_cleanup_probe_resource(fn -> raise ArgumentError end)

    assert {:error, {:runtime_isolation_cleanup_failed, :cleanup_failed}} =
             IsolationProfile.safely_cleanup_probe_resource(fn -> throw({:cleanup_failure, :unknown}) end)

    assert {:error, {:runtime_isolation_cleanup_failed, :cleanup_atom}} =
             IsolationProfile.safely_cleanup_probe_resource(fn -> throw(:cleanup_atom) end)
  end

  test "probe cleanup preserves the first cleanup failure and handles resource paths" do
    assert {:ok, :proof} =
             IsolationProfile.run_with_probe_cleanup(fn -> {:ok, :proof} end, [fn -> :ok end])

    assert {:error, :operation_failed} =
             IsolationProfile.run_with_probe_cleanup(fn -> {:error, :operation_failed} end, [fn -> :ok end])

    assert {:error, :first_cleanup_failed} =
             IsolationProfile.run_with_probe_cleanup(fn -> {:ok, :proof} end, [
               fn -> {:error, :first_cleanup_failed} end,
               fn -> {:error, :second_cleanup_failed} end
             ])

    root = Path.join(System.tmp_dir!(), "h080b-socket-cleanup-#{System.unique_integer([:positive])}")
    socket_file = Path.join(root, "socket")
    directory = Path.join(root, "directory")
    File.mkdir_p!(directory)
    File.write!(socket_file, "socket")
    on_exit(fn -> File.rm_rf(root) end)

    assert :ok = IsolationProfile.remove_probe_socket(Path.join(root, "missing"))
    assert :ok = IsolationProfile.remove_probe_socket(socket_file)
    refute File.exists?(socket_file)

    assert {:error, {:runtime_isolation_cleanup_failed, :unix_socket, _reason}} =
             IsolationProfile.remove_probe_socket(directory)

    assert IsolationProfile.reason_class(:cleanup_atom) == :cleanup_atom
    assert IsolationProfile.reason_class({:cleanup_failure, :unknown}) == :cleanup_failed

    assert IsolationProfile.probe_child_cleanup_pending?({
             :error,
             {:runtime_isolation_probe_process_alive, :unconfirmed}
           })

    refute IsolationProfile.probe_child_cleanup_pending?({:error, :codex_probe_timeout})
    assert IsolationProfile.env_value(false) == false
    assert IsolationProfile.env_value(nil) == false
    assert IsolationProfile.env_value("secret") == ~c"secret"
    assert IsolationProfile.env_value(~c"secret") == ~c"secret"
  end

  test "process tree parsing tolerates malformed rows and stops at a cycle" do
    process_table = "100 102\n101 100\n102 101\nbad row\nprocess 100\n"
    process_ids = IsolationProfile.process_tree_from_table(100, process_table)

    assert MapSet.new(process_ids) == MapSet.new([100, 101, 102])
    assert length(process_ids) == 3
    assert "PATH" in IsolationProfile.shell_environment_names()
    refute "GH_CONFIG_DIR" in IsolationProfile.shell_environment_names()
  end

  test "permission profile helpers reject unsupported roles and unsafe commands" do
    workspace = Path.join(System.tmp_dir!(), "h080b-invalid-role-#{System.unique_integer([:positive])}")
    executable = probe_executable!("exit 0\n")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:error, {:unsupported_runtime_responsibility, "merge"}} =
             IsolationProfile.profile_name("merge")

    assert {:error, {:unsupported_runtime_responsibility, "merge"}} =
             IsolationProfile.build_permission_profile(workspace, "merge", executable)

    profiles = [
      {"review", "symphony_reviewer_read", :read},
      {"reviewer", "symphony_reviewer_read", :read},
      {"correction", "symphony_fixer_write", :write},
      {"fixer", "symphony_fixer_write", :write}
    ]

    Enum.each(profiles, fn {responsibility, expected_name, expected_access} ->
      assert {:ok, profile} =
               IsolationProfile.build_permission_profile(workspace, responsibility, executable)

      assert profile.name == expected_name
      assert profile.access == expected_access
    end)

    assert {:error, {:unsafe_routed_command, :shape}} =
             IsolationProfile.resolve_codex_executable("codex app-server; touch marker")

    assert {:error, {:unsafe_routed_command, :shape}} =
             IsolationProfile.resolve_codex_executable(:codex)

    missing = "codex-h080b-missing-#{System.unique_integer([:positive])}"

    assert {:error, :codex_executable_not_found} =
             IsolationProfile.resolve_codex_executable("#{missing} app-server")

    assert {:error, {:unsafe_routed_command, :executable_name}} =
             IsolationProfile.resolve_codex_executable("/bin/sh app-server")

    assert {:error, {:unsafe_routed_command, :argv}} =
             IsolationProfile.resolve_codex_executable("codex sandbox")

    non_executable = Path.join(System.tmp_dir!(), "h080b-not-executable-codex-#{System.unique_integer([:positive])}")
    File.write!(non_executable, "not executable")
    on_exit(fn -> File.rm(non_executable) end)

    assert {:error, :codex_executable_not_found} =
             IsolationProfile.resolve_codex_executable("#{non_executable} app-server")
  end

  test "Codex package selection covers the supported runtime targets" do
    assert IsolationProfile.architecture_family("x86_64-unknown-linux-gnu") == :x86_64
    assert IsolationProfile.architecture_family("aarch64-apple-darwin") == :aarch64
    assert IsolationProfile.architecture_family("riscv64-unknown-linux-gnu") == :unsupported

    assert IsolationProfile.platform_target(:linux, :x86_64) == "x86_64-unknown-linux-musl"
    assert IsolationProfile.platform_target(:linux, :aarch64) == "aarch64-unknown-linux-musl"
    assert IsolationProfile.platform_target(:darwin, :x86_64) == "x86_64-apple-darwin"
    assert IsolationProfile.platform_target(:darwin, :aarch64) == "aarch64-apple-darwin"
    assert IsolationProfile.platform_target(:freebsd, :x86_64) == "unsupported"

    assert IsolationProfile.platform_package("x86_64-unknown-linux-musl") == "@openai/codex-linux-x64"
    assert IsolationProfile.platform_package("aarch64-unknown-linux-musl") == "@openai/codex-linux-arm64"
    assert IsolationProfile.platform_package("x86_64-apple-darwin") == "@openai/codex-darwin-x64"
    assert IsolationProfile.platform_package("aarch64-apple-darwin") == "@openai/codex-darwin-arm64"
    assert IsolationProfile.platform_package("unsupported") == "@openai/codex-unsupported"
  end

  test "Codex wrapper resolution finds its matching pinned native package binary on Linux x64" do
    if elem(:os.type(), 1) == :linux and IsolationProfile.architecture_family(to_string(:erlang.system_info(:system_architecture))) == :x86_64 do
      root = Path.join(System.tmp_dir!(), "h080b-codex-package-#{System.unique_integer([:positive])}")
      wrapper = Path.join([root, "bin", "codex"])
      native = Path.join([root, "node_modules", "@openai", "codex-linux-x64", "vendor", "x86_64-unknown-linux-musl", "bin", "codex"])

      File.mkdir_p!(Path.dirname(wrapper))
      File.mkdir_p!(Path.dirname(native))
      File.write!(wrapper, "#!/bin/sh\nprintf 'codex-cli 0.159.3\\n'\n")
      File.write!(native, "#!/bin/sh\n# native package binary\nprintf 'codex-cli 0.159.3\\n'\n")
      File.chmod!(wrapper, 0o700)
      File.chmod!(native, 0o700)
      on_exit(fn -> File.rm_rf(root) end)

      assert {:ok, resolved} = IsolationProfile.resolve_codex_executable("#{wrapper} app-server")
      assert resolved.executable == Path.expand(wrapper)
      assert resolved.native_executable == Path.expand(native)
      assert resolved.argv == ["app-server"]

      assert {:ok, identity} = IsolationProfile.runtime_identity(resolved.executable)
      assert identity.version == @codex_version
      assert identity.native_executable == Path.expand(native)
      refute identity.digest == identity.native_digest
    end
  end

  test "unsupported session responsibilities remove their partial session root" do
    root = Path.join(System.tmp_dir!(), "h080b-invalid-session-#{System.unique_integer([:positive])}")
    workspace = Path.join(System.tmp_dir!(), "h080b-invalid-workspace-#{System.unique_integer([:positive])}")
    executable = probe_executable!("exit 0\n")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:error, {:unsupported_runtime_responsibility, "merge"}} =
             IsolationProfile.prepare_session_home(workspace, "merge", executable, root: root)

    refute File.exists?(root)
  end

  test "session-home setup removes a partial root after directory creation fails" do
    root = Path.join(System.tmp_dir!(), "h080b-blocked-session-#{System.unique_integer([:positive])}")
    workspace = Path.join(System.tmp_dir!(), "h080b-session-workspace-#{System.unique_integer([:positive])}")
    executable = probe_executable!("exit 0\n")
    File.write!(root, "blocker")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:error, {:ephemeral_home_failed, :eexist}} =
             IsolationProfile.prepare_session_home(workspace, "planning", executable, root: root)

    assert File.read!(root) == "blocker"
  end

  test "runtime identity rejects missing executables and unavailable versions" do
    missing = Path.join(System.tmp_dir!(), "h080b-missing-#{System.unique_integer([:positive])}")
    blank_version = probe_executable!("exit 0\n")
    failed_version = probe_executable!("exit 9\n")

    assert {:error, {:codex_identity_failed, _reason}} = IsolationProfile.runtime_identity(missing)

    assert {:error, {:codex_identity_failed, :version_unavailable}} =
             IsolationProfile.runtime_identity(blank_version)

    assert {:error, {:codex_identity_failed, :version_unavailable}} =
             IsolationProfile.runtime_identity(failed_version)
  end

  test "runtime identity records fingerprints for the pinned supported version" do
    executable = probe_executable!("printf 'codex-cli 0.159.3\\n'\n")

    assert {:ok, identity} = IsolationProfile.runtime_identity(executable)
    assert identity.executable == Path.expand(executable)
    assert identity.native_executable == Path.expand(executable)
    assert identity.version == @codex_version
    assert identity.size == File.stat!(executable).size
    assert identity.native_size == identity.size
    assert identity.digest == identity.native_digest
    assert identity.platform == {elem(:os.type(), 0), elem(:os.type(), 1), :erlang.system_info(:system_architecture)}
  end

  test "session-home cleanup reports invalid filesystem paths" do
    assert {:error, {:runtime_isolation_cleanup_failed, :ownership_unverified}} =
             IsolationProfile.cleanup_session_home(%{root: <<0>>, root_identity: {0, 0, 0}})

    if elem(:os.type(), 1) == :linux do
      assert {:error, {:runtime_isolation_cleanup_failed, :ownership_unverified}} =
               IsolationProfile.cleanup_session_home(%{root: "/proc/self/status", root_identity: {0, 0, 0}})
    end
  end

  test "session setup and socket cleanup fail closed on invalid paths" do
    workspace = Path.join(System.tmp_dir!(), "h080b-invalid-root-workspace-#{System.unique_integer([:positive])}")
    executable = probe_executable!("exit 0\n")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:error, {:ephemeral_home_failed, :badarg}} =
             IsolationProfile.prepare_session_home(workspace, "planning", executable, root: <<0>>)

    assert {:error, {:runtime_isolation_cleanup_failed, :unix_socket, :badarg}} =
             IsolationProfile.remove_probe_socket(<<0>>)
  end

  test "pinned Codex enforces read-only and workspace-write profiles against real sentinels" do
    assert {:ok, resolved} = IsolationProfile.resolve_codex_executable("codex app-server")
    assert {:ok, identity} = IsolationProfile.runtime_identity(resolved.executable)
    assert identity.version == @codex_version

    assert {:ok, evidence} = RuntimeIsolation.verify(resolved.executable)
    assert evidence.status == :verified
    assert evidence.version == @codex_version
    proof = evidence.result

    assert proof.platform in [:linux, :darwin]

    assert_profile_results(proof.read_only, :read)
    assert_profile_results(proof.reviewer_read, :read)
    assert_profile_results(proof.workspace_write, :write)
    assert_profile_results(proof.fixer_write, :write)

    for profile <- [proof.read_only, proof.reviewer_read, proof.workspace_write, proof.fixer_write] do
      assert profile.results["credential_environment_absent"]
      assert profile.results["parent_sentinel_environment_absent"]
      assert profile.results["session_home_bound"]
      assert profile.results["parent_environment_supported"] == (proof.platform == :linux)
      assert profile.results["parent_environment_visible"] == false
      assert profile.results["parent_environment_probe_error"] == false
      assert profile.results["loopback_connect"] == false
      assert profile.results["unix_socket_connect"] == false
      refute inspect(profile) =~ "h080b-parent-sentinel-"
      assert is_list(profile.results["workspace_parent_entries"])
      assert "workspace" in profile.results["workspace_parent_entries"]
      assert profile.results["workspace_parent_sibling_name_visible"] == false
      assert profile.results["workspace_parent_host_sentinel_name_visible"] == false
      assert profile.results["workspace_parent_host_entry_names_visible"] == false
      assert profile.results["workspace_parent_host_sentinel_readable"] == false
      assert profile.results["sandbox_parent_write_succeeded"]
      assert profile.results["sandbox_synthetic_sibling_write_succeeded"]
      assert profile.results["host_parent_write_sentinel_absent"]
      assert profile.results["host_synthetic_sibling_absent"]
      assert profile.results["host_parent_entries_unchanged"]
      assert profile.results["host_parent_snapshot_unchanged"]
      assert profile.results["host_parent_sentinel_unchanged"]
      assert profile.results["host_sibling_unchanged"]
    end

    assert proof.read_only.results["host_workspace_unchanged"]
    assert proof.read_only.results["host_workspace_matches_expected"]
    assert proof.workspace_write.results["host_workspace_matches_expected"]
  end

  test "pinned Planner and Reviewer profiles keep synthetic parent writes out of the host root" do
    assert {:ok, resolved} = IsolationProfile.resolve_codex_executable("codex app-server")
    assert {:ok, identity} = IsolationProfile.runtime_identity(resolved.executable)
    assert identity.version == @codex_version

    for {role, result_key} <- [planner: :read_only, reviewer: :reviewer_read] do
      assert {:ok, proof} =
               IsolationProfile.run_actual_read_probe(
                 resolved.executable,
                 resolved.native_executable,
                 role
               )

      assert proof.platform == elem(:os.type(), 1)
      profile = Map.fetch!(proof, result_key)
      assert_profile_results(profile, :read)
      results = profile.results

      assert results["workspace_parent_entries"] == ["workspace"]
      refute results["workspace_parent_host_sentinel_name_visible"]
      refute results["workspace_parent_sibling_name_visible"]
      refute results["workspace_parent_host_sentinel_readable"]
      refute results["sibling_read"]

      assert results["sandbox_parent_write_succeeded"]
      assert results["sandbox_synthetic_sibling_write_succeeded"]
      assert results["host_parent_write_sentinel_absent"]
      assert results["host_synthetic_sibling_absent"]
      assert results["host_parent_entries_unchanged"]
      assert results["host_parent_snapshot_unchanged"]
      assert results["host_parent_sentinel_unchanged"]
      assert results["host_sibling_unchanged"]
      assert results["host_workspace_unchanged"]
    end
  end

  test "pinned Builder and Fixer profiles keep synthetic parent writes sandbox-private" do
    assert {:ok, resolved} = IsolationProfile.resolve_codex_executable("codex app-server")
    assert {:ok, identity} = IsolationProfile.runtime_identity(resolved.executable)
    assert identity.version == @codex_version

    for {role, result_key} <- [builder: :builder_write, fixer: :fixer_write] do
      assert {:ok, proof} =
               IsolationProfile.run_actual_write_probe(
                 resolved.executable,
                 resolved.native_executable,
                 role
               )

      assert proof.platform == elem(:os.type(), 1)
      profile = Map.fetch!(proof, result_key)
      results = profile.results

      assert_profile_results(profile, :write)
      assert results["workspace_parent_entries"] == ["workspace"]
      refute results["workspace_parent_host_entry_names_visible"]
      refute results["workspace_parent_host_sentinel_name_visible"]
      refute results["workspace_parent_sibling_name_visible"]
      refute results["workspace_parent_host_sentinel_readable"]
      refute results["sibling_read"]

      # Parent writes must round-trip in the sandbox and leave no host artifacts.
      assert results["sandbox_parent_write_succeeded"]
      assert results["sandbox_synthetic_sibling_write_succeeded"]
      assert results["host_parent_write_sentinel_absent"]
      assert results["host_synthetic_sibling_absent"]
      assert results["host_parent_entries_unchanged"]
      assert results["host_parent_snapshot_unchanged"]
      assert results["host_parent_sentinel_unchanged"]
      assert results["host_sibling_unchanged"]
      assert results["host_workspace_matches_expected"]

      assert results["credential_environment_absent"]
      assert results["loopback_connect"] == false
      assert results["unix_socket_connect"] == false
    end
  end

  defp assert_profile_results(profile, access) do
    assert profile.verified
    assert profile.results["workspace_read"]

    for key <- [
          "sibling_read",
          "outside_read",
          "credential_gitconfig_read",
          "credential_netrc_read",
          "credential_ssh_config_read",
          "credential_ssh_identity_read",
          "credential_gh_config_read",
          "sibling_write",
          "outside_write",
          "workspace_parent_read",
          "workspace_parent_host_sentinel_readable",
          "workspace_parent_sibling_name_visible",
          "workspace_parent_host_sentinel_name_visible",
          "workspace_parent_host_entry_names_visible",
          "symlink_escape_read",
          "symlink_escape_write",
          "hardlink_escape_create"
        ] do
      assert profile.results[key] == false
    end

    expected_write = access == :write

    for key <- ["workspace_create", "workspace_modify", "workspace_rename", "workspace_delete"] do
      assert profile.results[key] == expected_write
    end
  end

  defp probe_executable!(body) do
    path = Path.join(System.tmp_dir!(), "h080b-probe-executable-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n#{body}\nsleep 0.05\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp snapshot_metadata(mode, inode, links) do
    %{
      mode: mode,
      inode: inode,
      links: links,
      uid: 1000,
      gid: 1000,
      major_device: 0,
      minor_device: 1
    }
  end

  defp proof_results(access) do
    %{
      "workspace_read" => true,
      "workspace_create" => access == :write,
      "workspace_modify" => access == :write,
      "workspace_rename" => access == :write,
      "workspace_delete" => access == :write,
      "sibling_read" => false,
      "outside_read" => false,
      "credential_gitconfig_read" => false,
      "credential_netrc_read" => false,
      "credential_ssh_config_read" => false,
      "credential_ssh_identity_read" => false,
      "credential_gh_config_read" => false,
      "sibling_write" => false,
      "outside_write" => false,
      "workspace_parent_read" => false,
      "workspace_parent_host_sentinel_readable" => false,
      "workspace_parent_sibling_name_visible" => false,
      "workspace_parent_host_sentinel_name_visible" => false,
      "workspace_parent_entries" => ["workspace"],
      "host_parent_write_sentinel_absent" => true,
      "host_synthetic_sibling_absent" => true,
      "host_parent_entries_unchanged" => true,
      "host_parent_snapshot_unchanged" => true,
      "host_parent_sentinel_unchanged" => true,
      "host_sibling_unchanged" => true,
      "host_workspace_unchanged" => access == :read,
      "host_workspace_matches_expected" => true,
      "parent_sentinel_environment_absent" => true,
      "workspace_parent_host_entry_names_visible" => false,
      "sandbox_parent_write_succeeded" => true,
      "sandbox_synthetic_sibling_write_succeeded" => true,
      "symlink_escape_read" => false,
      "symlink_escape_write" => false,
      "credential_environment_absent" => true,
      "home_bound" => true,
      "codex_home_bound" => true,
      "xdg_config_home_bound" => true,
      "xdg_state_home_bound" => true,
      "xdg_cache_home_bound" => true,
      "session_home_bound" => true,
      "parent_environment_supported" => true,
      "parent_environment_visible" => false,
      "parent_environment_probe_error" => false,
      "loopback_connect" => false,
      "unix_socket_connect" => false,
      "hardlink_escape_create" => false
    }
  end

  defp proof_executable!(read_results, write_results, opts \\ []) do
    read_output = Jason.encode!(%{results: read_results, reason_classes: []})
    write_output = Jason.encode!(%{results: write_results, reason_classes: []})
    planner_mutation = if Keyword.get(opts, :planner_mutation), do: "printf 'planner-change\\n' > \"$6/writable.txt\"\n", else: ""

    builder_created_content =
      case Keyword.get(opts, :builder_mutation) do
        :unexpected_created_content -> "unexpected"
        _ -> "created"
      end

    builder_setup = """
    printf 'modified\\n' > \"$6/writable.txt\"
    printf '#{builder_created_content}' > \"$6/created.txt\"
    mv \"$6/rename-source.txt\" \"$6/renamed.txt\"
    rm \"$6/delete-target.txt\"
    """

    body = """
    case \"$3\" in
      symphony_planner_read)
        #{planner_mutation}printf '%s\\n' '#{read_output}'
        ;;
      symphony_reviewer_read)
        printf '%s\\n' '#{read_output}'
        ;;
      symphony_builder_write)
        #{builder_setup}
        printf '%s\\n' '#{write_output}'
        ;;
      symphony_fixer_write)
        #{builder_setup}
        printf '%s\\n' '#{write_output}'
        ;;
    esac
    sleep 0.05
    """

    probe_executable!(body)
  end
end
