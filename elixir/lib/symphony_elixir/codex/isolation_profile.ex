defmodule SymphonyElixir.Codex.IsolationProfile do
  @moduledoc """
  Builds session-local Codex permission profiles and runs the real sandbox proof.
  """

  alias SymphonyElixir.{CredentialBoundary, PathSafety}

  @safe_shell_environment ~w(
    PATH HOME USER LOGNAME LANG TERM TMPDIR SHELL CODEX_HOME
    XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME GIT_CONFIG_NOSYSTEM LC_*
  )

  @supported_codex_version "codex-cli 0.159.3"

  @credential_environment ~w(
    PLANE_API_KEY PLANE_WEBHOOK_SECRET GITHUB_TOKEN GH_TOKEN
    SYMPHONY_H080B_SENTINEL_TRACKER SYMPHONY_H080B_SENTINEL_SCM
    SSH_AUTH_SOCK SSH_AGENT_PID GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
    GIT_SSH GIT_SSH_COMMAND GH_CONFIG_DIR GIT_CONFIG_GLOBAL
    GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  )

  @probe_process_term_timeout_ms 500
  @probe_process_kill_timeout_ms 1_000
  @probe_process_poll_interval_ms 100
  @probe_port_close_timeout_ms 1_000

  @probe_script """
  import errno, json, os, pathlib, socket, sys

  mode, workspace, sibling, outside, fake_home, unix_socket, tcp_port, sentinel, expected_home, expected_codex_home, expected_config, expected_state, expected_cache = sys.argv[1:]
  workspace_path = pathlib.Path(workspace)
  results = {}
  reasons = set()

  def check(name, operation):
      try:
          operation()
          results[name] = True
      except Exception as error:
          results[name] = False
          reasons.add(type(error).__name__)

  def read_text(path):
      return pathlib.Path(path).read_text()

  check("workspace_read", lambda: (_ for _ in ()).throw(ValueError()) if read_text(workspace_path / "readable.txt") != "workspace-sentinel\\n" else None)

  def create_workspace_file():
      (workspace_path / "created.txt").write_text("created")
  check("workspace_create", create_workspace_file)

  def modify_workspace_file():
      (workspace_path / "writable.txt").write_text("modified")
  check("workspace_modify", modify_workspace_file)

  def rename_workspace_file():
      os.rename(workspace_path / "rename-source.txt", workspace_path / "renamed.txt")
  check("workspace_rename", rename_workspace_file)

  def delete_workspace_file():
      (workspace_path / "delete-target.txt").unlink()
  check("workspace_delete", delete_workspace_file)

  check("sibling_read", lambda: read_text(pathlib.Path(sibling) / "sibling.txt"))
  check("outside_read", lambda: read_text(pathlib.Path(outside) / "protected.txt"))
  workspace_parent = pathlib.Path(workspace).parent
  workspace_parent_entries = sorted(entry.name for entry in workspace_parent.iterdir())
  results["workspace_parent_entries"] = workspace_parent_entries
  results["workspace_parent_sibling_name_visible"] = pathlib.Path(sibling).name in workspace_parent_entries
  results["workspace_parent_host_sentinel_name_visible"] = "parent-protected.txt" in workspace_parent_entries
  check("workspace_parent_read", lambda: read_text(workspace_parent / "parent-protected.txt"))
  check("workspace_parent_host_sentinel_readable", lambda: read_text(workspace_parent / "parent-protected.txt"))
  check("credential_gitconfig_read", lambda: read_text(pathlib.Path(fake_home) / ".gitconfig"))
  check("credential_netrc_read", lambda: read_text(pathlib.Path(fake_home) / ".netrc"))
  check("credential_ssh_config_read", lambda: read_text(pathlib.Path(fake_home) / ".ssh" / "config"))
  check("credential_ssh_identity_read", lambda: read_text(pathlib.Path(fake_home) / ".ssh" / "id_sentinel"))
  check("credential_gh_config_read", lambda: read_text(pathlib.Path(fake_home) / ".config" / "gh" / "hosts.yml"))

  def sibling_write():
      (pathlib.Path(sibling) / "forbidden.txt").write_text("forbidden")
  check("sibling_write", sibling_write)

  def outside_write():
      (pathlib.Path(outside) / "writable-target").write_text("forbidden")
  check("outside_write", outside_write)

  def sandbox_parent_write():
      parent_sentinel = workspace_parent / "SANDBOX_PARENT_WRITE_SENTINEL"
      parent_sentinel.write_text("sandbox-only")
      if read_text(parent_sentinel) != "sandbox-only":
          raise ValueError("sandbox parent write did not round-trip")
  check("sandbox_parent_write_succeeded", sandbox_parent_write)

  def sandbox_synthetic_sibling_write():
      synthetic_sibling = workspace_parent / "SYNTHETIC-SIBLING"
      synthetic_sibling.mkdir()
      sibling_sentinel = synthetic_sibling / "test"
      sibling_sentinel.write_text("sandbox-only")
      if read_text(sibling_sentinel) != "sandbox-only":
          raise ValueError("synthetic sibling write did not round-trip")
  check("sandbox_synthetic_sibling_write_succeeded", sandbox_synthetic_sibling_write)

  def symlink_read():
      read_text(workspace_path / "escape-link")
  check("symlink_escape_read", symlink_read)

  def symlink_write():
      (workspace_path / "escape-link").write_text("forbidden")
  check("symlink_escape_write", symlink_write)

  def create_hardlink_escape():
      os.link(pathlib.Path(outside) / "protected.txt", workspace_path / "hardlink-escape")
  check("hardlink_escape_create", create_hardlink_escape)

  results["credential_environment_absent"] = all(name not in os.environ for name in __CREDENTIAL_NAMES__)
  results["parent_sentinel_environment_absent"] = "SYMPHONY_H080B_PARENT_SENTINEL" not in os.environ
  results["home_bound"] = os.environ.get("HOME") == expected_home
  results["codex_home_bound"] = os.environ.get("CODEX_HOME") == expected_codex_home
  results["xdg_config_home_bound"] = os.environ.get("XDG_CONFIG_HOME") == expected_config
  results["xdg_state_home_bound"] = os.environ.get("XDG_STATE_HOME") == expected_state
  results["xdg_cache_home_bound"] = os.environ.get("XDG_CACHE_HOME") == expected_cache
  results["session_home_bound"] = all(results[name] for name in ["home_bound", "codex_home_bound", "xdg_config_home_bound", "xdg_state_home_bound", "xdg_cache_home_bound"])

  def tcp_connect():
      connection = socket.create_connection(("127.0.0.1", int(tcp_port)), timeout=0.25)
      connection.close()
  check("loopback_connect", tcp_connect)

  def unix_connect():
      connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
      connection.connect(unix_socket)
      connection.close()
  check("unix_socket_connect", unix_connect)

  proc_environ = pathlib.Path("/proc") / str(os.getppid()) / "environ"
  if pathlib.Path("/proc").exists():
      results["parent_environment_supported"] = True
      def read_parent_environment():
          return sentinel.encode() in proc_environ.read_bytes()
      try:
          results["parent_environment_visible"] = read_parent_environment()
          results["parent_environment_probe_error"] = False
      except (PermissionError, FileNotFoundError) as error:
          results["parent_environment_visible"] = False
          results["parent_environment_probe_error"] = False
          reasons.add(type(error).__name__)
      except Exception as error:
          results["parent_environment_visible"] = False
          results["parent_environment_probe_error"] = True
          reasons.add(type(error).__name__)
  else:
      results["parent_environment_visible"] = False
      results["parent_environment_supported"] = False
      results["parent_environment_probe_error"] = False

  print(json.dumps({"results": results, "reason_classes": sorted(reasons)}, sort_keys=True))
  """

  @type access :: :read | :write
  @type probe_process_ids :: [pos_integer()]
  @type permission_profile :: %{
          name: String.t(),
          access: access(),
          workspace_roots: [Path.t()],
          network_enabled: false,
          git_access: :read,
          native_executable: Path.t()
        }

  @spec profile_name(String.t()) :: String.t() | {:error, term()}
  def profile_name(responsibility) when is_binary(responsibility) do
    case responsibility do
      role when role in ["planning", "planner"] -> "symphony_planner_read"
      role when role in ["review", "reviewer"] -> "symphony_reviewer_read"
      role when role in ["implementation", "builder"] -> "symphony_builder_write"
      role when role in ["correction", "fixer"] -> "symphony_fixer_write"
      role -> {:error, {:unsupported_runtime_responsibility, role}}
    end
  end

  @spec build_permission_profile(Path.t(), String.t(), Path.t()) ::
          {:ok, permission_profile()} | {:error, term()}
  def build_permission_profile(workspace, responsibility, native_executable)
      when is_binary(workspace) and is_binary(responsibility) and is_binary(native_executable) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_native} <- PathSafety.canonicalize(native_executable),
         profile_name when is_binary(profile_name) <- profile_name(responsibility),
         {:ok, access} <- access_for_responsibility(responsibility) do
      {:ok,
       %{
         name: profile_name,
         access: access,
         workspace_roots: [canonical_workspace],
         network_enabled: false,
         git_access: :read,
         native_executable: canonical_native
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prepare_session_home(Path.t(), String.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_session_home(workspace, responsibility, native_executable, opts \\ [])
      when is_binary(workspace) and is_binary(responsibility) and is_binary(native_executable) do
    root = session_root(opts)

    with {:ok, root_identity} <- create_session_root(root) do
      session_home = %{root: root, root_identity: root_identity}

      try do
        with {:ok, profile} <- build_permission_profile(workspace, responsibility, native_executable),
             home <- Path.join(root, "home"),
             codex_home <- Path.join(root, "codex"),
             xdg_config_home <- Path.join(home, ".config"),
             xdg_state_home <- Path.join(home, ".local/state"),
             xdg_cache_home <- Path.join(home, ".cache"),
             temp_dir <- Path.join(home, "tmp"),
             :ok <-
               create_session_directories([
                 home,
                 codex_home,
                 xdg_config_home,
                 xdg_state_home,
                 xdg_cache_home,
                 temp_dir
               ]),
             config_path <- Path.join(codex_home, "config.toml"),
             :ok <- File.write(config_path, render_config(profile, home), [:binary]),
             :ok <- File.chmod(config_path, 0o600) do
          {:ok,
           Map.merge(session_home, %{
             home: home,
             codex_home: codex_home,
             xdg_config_home: xdg_config_home,
             xdg_state_home: xdg_state_home,
             xdg_cache_home: xdg_cache_home,
             temp_dir: temp_dir,
             config_path: config_path,
             permission_profile: profile.name,
             workspace: hd(profile.workspace_roots),
             access: profile.access,
             native_executable: profile.native_executable
           })}
        else
          {:error, reason} ->
            cleanup_failed_session_home(session_home, reason)
        end
      rescue
        error in [File.Error, ArgumentError] ->
          cleanup_failed_session_home(session_home, {:ephemeral_home_failed, error.__struct__})
      end
    end
  end

  @spec cleanup_session_home(map()) :: :ok | {:error, term()}
  def cleanup_session_home(%{root: root, root_identity: identity})
      when is_binary(root) and is_tuple(identity) do
    with {:ok, current_identity} <- session_root_identity(root),
         true <- current_identity == identity do
      case File.rm_rf(root) do
        {:ok, _removed_paths} -> :ok
        {:error, reason, path} -> {:error, {:runtime_isolation_cleanup_failed, reason, Path.basename(path)}}
      end
    else
      false -> {:error, {:runtime_isolation_cleanup_failed, :ownership_unverified}}
      {:error, _reason} -> {:error, {:runtime_isolation_cleanup_failed, :ownership_unverified}}
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:runtime_isolation_cleanup_failed, error.__struct__}}
  end

  def cleanup_session_home(_session_home),
    do: {:error, {:runtime_isolation_cleanup_failed, :invalid_session_home}}

  @doc false
  @spec combine_cleanup_result(term(), term()) :: term()
  def combine_cleanup_result(result, :ok), do: result

  def combine_cleanup_result(_result, {:error, _reason} = error), do: error

  def combine_cleanup_result(_result, _cleanup_result),
    do: {:error, {:runtime_isolation_cleanup_failed, :invalid_cleanup_result}}

  defp create_session_root(root) do
    case File.mkdir(root) do
      :ok ->
        with :ok <- File.chmod(root, 0o700),
             {:ok, identity} <- session_root_identity(root) do
          {:ok, identity}
        else
          {:error, reason} ->
            _ = File.rmdir(root)
            {:error, {:ephemeral_home_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:ephemeral_home_failed, reason}}
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:ephemeral_home_failed, error.__struct__}}
  end

  defp session_root_identity(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, {stat.major_device, stat.minor_device, stat.inode}}

      {:ok, _other} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_failed_session_home(session_home, original_reason) do
    case cleanup_session_home(session_home) do
      :ok -> {:error, original_reason}
      {:error, cleanup_reason} -> {:error, cleanup_reason}
    end
  end

  @spec resolve_codex_executable(String.t() | nil, keyword()) ::
          {:ok, %{executable: Path.t(), native_executable: Path.t(), argv: [String.t()]}}
          | {:error, term()}
  def resolve_codex_executable(command \\ nil, opts \\ []) do
    command = command || Keyword.get(opts, :command, "codex app-server")

    with true <- safe_codex_command?(command) || {:error, {:unsafe_routed_command, :shape}},
         [candidate, "app-server"] <- String.split(command),
         executable when is_binary(executable) <- find_executable(candidate),
         {:ok, canonical_executable} <- PathSafety.canonicalize(executable),
         true <- Path.basename(candidate) in ["codex", "codex.exe"] || {:error, {:unsafe_routed_command, :executable_name}},
         {:ok, native_executable} <- resolve_native_executable(canonical_executable) do
      {:ok, %{executable: canonical_executable, native_executable: native_executable, argv: ["app-server"]}}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :codex_executable_not_found}
      _ -> {:error, {:unsafe_routed_command, :argv}}
    end
  end

  @spec runtime_identity(Path.t()) :: {:ok, map()} | {:error, term()}
  def runtime_identity(executable) when is_binary(executable) do
    with {:ok, canonical_executable} <- PathSafety.canonicalize(executable),
         {:ok, %File.Stat{} = stat} <- File.stat(canonical_executable),
         {:ok, binary} <- File.read(canonical_executable),
         {:ok, native_executable} <- resolve_native_executable(canonical_executable),
         {:ok, %File.Stat{} = native_stat} <- File.stat(native_executable),
         {:ok, native_binary} <- File.read(native_executable),
         {:ok, version} <- codex_version(canonical_executable),
         :ok <- validate_supported_version(version) do
      {:ok,
       %{
         executable: canonical_executable,
         size: stat.size,
         mtime: stat.mtime,
         inode: stat.inode,
         digest: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower),
         native_executable: native_executable,
         native_size: native_stat.size,
         native_mtime: native_stat.mtime,
         native_inode: native_stat.inode,
         native_digest: :crypto.hash(:sha256, native_binary) |> Base.encode16(case: :lower),
         version: version,
         platform: {elem(:os.type(), 0), elem(:os.type(), 1), :erlang.system_info(:system_architecture)}
       }}
    else
      {:error, reason} -> {:error, {:codex_identity_failed, reason}}
      other -> {:error, {:codex_identity_failed, other}}
    end
  rescue
    error in [File.Error, ErlangError] -> {:error, {:codex_identity_failed, error.__struct__}}
  end

  @spec run_actual_probe(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def run_actual_probe(executable, native_executable)
      when is_binary(executable) and is_binary(native_executable) do
    run_actual_probe_profiles_independently(executable, native_executable, [
      {"planning", :read, :read_only},
      {"review", :read, :reviewer_read},
      {"implementation", :write, :workspace_write},
      {"correction", :write, :fixer_write}
    ])
  end

  @doc false
  @spec run_actual_read_probe(Path.t(), Path.t(), :planner | :reviewer) ::
          {:ok, map()} | {:error, term()}
  def run_actual_read_probe(executable, native_executable, role \\ :planner)
      when is_binary(executable) and is_binary(native_executable) and role in [:planner, :reviewer] do
    {responsibility, result_key} =
      case role do
        :planner -> {"planning", :read_only}
        :reviewer -> {"review", :reviewer_read}
      end

    run_actual_probe_profiles(executable, native_executable, [
      {responsibility, :read, result_key}
    ])
  end

  @doc false
  @spec run_actual_write_probe(Path.t(), Path.t(), :builder | :fixer) ::
          {:ok, map()} | {:error, term()}
  def run_actual_write_probe(executable, native_executable, role)
      when is_binary(executable) and is_binary(native_executable) and role in [:builder, :fixer] do
    {responsibility, result_key} =
      case role do
        :builder -> {"builder", :builder_write}
        :fixer -> {"fixer", :fixer_write}
      end

    run_actual_probe_profiles(executable, native_executable, [
      {responsibility, :write, result_key}
    ])
  end

  defp run_actual_probe_profiles(executable, native_executable, profiles) do
    case create_probe_fixture() do
      {:ok, fixture} ->
        result =
          safely_run_probe(fn ->
            run_probe_fixture(executable, native_executable, fixture, profiles)
          end)

        if probe_child_cleanup_pending?(result) do
          result
        else
          combine_cleanup_result(result, cleanup_probe_fixture(fixture))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_actual_probe_profiles_independently(executable, native_executable, profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn profile, {:ok, proofs} ->
      case run_actual_probe_profiles(executable, native_executable, [profile]) do
        {:ok, proof} ->
          {:cont, {:ok, Map.merge(proofs, proof)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @spec shell_environment_names() :: [String.t()]
  def shell_environment_names, do: @safe_shell_environment

  defp run_probe_profile(executable, fixture, session_home, access) do
    with {:ok, listener} <- start_tcp_listener() do
      run_probe_with_listener(executable, fixture, session_home, listener, access)
    end
  end

  defp run_probe_with_listener(executable, fixture, session_home, listener, access) do
    case start_unix_socket_server(fixture.unix_socket) do
      {:ok, unix_server} ->
        run_with_probe_cleanup(
          fn ->
            run_probe_command(executable, fixture, session_home, listener, unix_server, access)
          end,
          [
            fn -> stop_tcp_listener(listener) end,
            fn -> stop_unix_socket_server(unix_server, fixture.unix_socket) end
          ]
        )

      {:error, reason} ->
        combine_cleanup_result({:error, reason}, stop_tcp_listener(listener))
    end
  end

  defp run_probe_command(executable, fixture, session_home, listener, unix_server, access) do
    sentinel = "h080b-parent-sentinel-#{System.unique_integer([:positive])}"

    args = [
      "sandbox",
      "--permission-profile",
      session_home.permission_profile,
      "--sandbox-state-disable-network",
      "--cd",
      fixture.workspace,
      find_python(),
      "-c",
      probe_script(probe_credential_environment_names()),
      Atom.to_string(access),
      fixture.workspace,
      fixture.sibling,
      fixture.outside,
      fixture.fake_home,
      fixture.unix_socket,
      Integer.to_string(listener.port),
      sentinel,
      session_home.home,
      session_home.codex_home,
      session_home.xdg_config_home,
      session_home.xdg_state_home,
      session_home.xdg_cache_home
    ]

    credential_names = probe_credential_environment_names()

    env =
      (CredentialBoundary.routed_port_env(credential_names, session_home.home, session_home.codex_home) ++
         Enum.map(credential_names, fn name ->
           {String.to_charlist(name), String.to_charlist(sentinel)}
         end) ++
         [{~c"SYMPHONY_H080B_PARENT_SENTINEL", String.to_charlist(sentinel)}])
      |> Map.new()
      |> Enum.to_list()

    with {:ok, output} <- run_port_command(executable, args, env, fixture.workspace, 15_000),
         :ok <- reject_probe_sentinel_output(output, sentinel),
         {:ok, proof} <- decode_probe_output(output),
         proof <- attach_host_state_results(proof, fixture, access) do
      {:ok,
       Map.merge(proof, %{
         access: access,
         platform: elem(:os.type(), 1),
         tcp_listener: listener.port,
         unix_socket_ready: unix_server
       })}
    end
  end

  @doc false
  @spec validate_probe_results(term(), access(), String.t(), [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def validate_probe_results(%{results: results} = proof, access, workspace_basename, host_parent_entries) do
    mismatches =
      results
      |> base_probe_mismatches(access, proof.platform)
      |> add_workspace_parent_mismatch(results, workspace_basename, host_parent_entries)
      |> add_write_attempt_mismatch(results)
      |> add_workspace_snapshot_mismatch(results, access)

    if mismatches == %{} do
      {:ok, Map.put(proof, :verified, true)}
    else
      {:error, {:codex_isolation_probe_failed, access, mismatches, false}}
    end
  end

  def validate_probe_results(_proof, access, _workspace_basename, _host_parent_entries),
    do: {:error, {:codex_isolation_probe_invalid, access}}

  defp base_probe_mismatches(results, access, platform) do
    positive_expected = %{
      "workspace_read" => true,
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
      "workspace_parent_host_entry_names_visible" => false,
      "host_parent_write_sentinel_absent" => true,
      "host_synthetic_sibling_absent" => true,
      "host_parent_entries_unchanged" => true,
      "host_parent_snapshot_unchanged" => true,
      "host_parent_sentinel_unchanged" => true,
      "host_sibling_unchanged" => true,
      "host_workspace_matches_expected" => true,
      "parent_sentinel_environment_absent" => true,
      "symlink_escape_read" => false,
      "symlink_escape_write" => false,
      "credential_environment_absent" => true,
      "home_bound" => true,
      "codex_home_bound" => true,
      "xdg_config_home_bound" => true,
      "xdg_state_home_bound" => true,
      "xdg_cache_home_bound" => true,
      "session_home_bound" => true,
      "parent_environment_supported" => platform == :linux,
      "parent_environment_visible" => false,
      "parent_environment_probe_error" => false,
      "loopback_connect" => false,
      "unix_socket_connect" => false,
      "hardlink_escape_create" => false
    }

    expected =
      Map.merge(positive_expected, %{
        "workspace_create" => access == :write,
        "workspace_modify" => access == :write,
        "workspace_rename" => access == :write,
        "workspace_delete" => access == :write
      })

    Enum.reduce(expected, %{}, fn {key, expected_value}, mismatches ->
      if Map.get(results, key) == expected_value do
        mismatches
      else
        Map.put(mismatches, key, %{expected: expected_value, actual: Map.get(results, key)})
      end
    end)
  end

  defp add_workspace_parent_mismatch(mismatches, results, workspace_basename, host_parent_entries) do
    workspace_parent_entries = Map.get(results, "workspace_parent_entries")
    visible_parent_entries = if is_list(workspace_parent_entries), do: workspace_parent_entries, else: []
    known_host_entries = Enum.reject(host_parent_entries, &(&1 == workspace_basename))
    workspace_visible = is_list(workspace_parent_entries) and workspace_basename in workspace_parent_entries
    leaked_host_entries = Enum.filter(known_host_entries, &Enum.member?(visible_parent_entries, &1))

    if workspace_visible and leaked_host_entries == [] do
      mismatches
    else
      Map.put(mismatches, "workspace_parent_entries", %{
        expected: %{workspace_visible: true, host_entries_visible: []},
        actual: %{entries: workspace_parent_entries, host_entries_visible: leaked_host_entries}
      })
    end
  end

  defp add_write_attempt_mismatch(mismatches, results) do
    write_attempts_recorded =
      is_boolean(Map.get(results, "sandbox_parent_write_succeeded")) and
        is_boolean(Map.get(results, "sandbox_synthetic_sibling_write_succeeded"))

    if write_attempts_recorded do
      mismatches
    else
      Map.put(mismatches, "sandbox_parent_write_attempts", %{
        expected: :boolean_results,
        actual: %{
          parent: Map.get(results, "sandbox_parent_write_succeeded"),
          synthetic_sibling: Map.get(results, "sandbox_synthetic_sibling_write_succeeded")
        }
      })
    end
  end

  defp add_workspace_snapshot_mismatch(mismatches, results, access) do
    mismatches =
      if Map.get(results, "host_workspace_matches_expected") == true do
        mismatches
      else
        Map.put(mismatches, "host_workspace_matches_expected", %{
          expected: true,
          actual: Map.get(results, "host_workspace_matches_expected")
        })
      end

    if access == :read and Map.get(results, "host_workspace_unchanged") != true do
      Map.put(mismatches, "host_workspace_unchanged", %{
        expected: true,
        actual: Map.get(results, "host_workspace_unchanged")
      })
    else
      mismatches
    end
  end

  defp run_probe_fixture(executable, native_executable, fixture, accesses) do
    Enum.reduce_while(accesses, {:ok, %{}}, fn {responsibility, access, result_key}, {:ok, proofs} ->
      with {:ok, proof} <-
             run_session_probe(executable, fixture, responsibility, access, native_executable),
           {:ok, proof} <-
             validate_probe_results(
               proof,
               access,
               Path.basename(fixture.workspace),
               fixture.host_parent_entries
             ) do
        {:cont, {:ok, Map.put(proofs, result_key, proof)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, proofs} -> {:ok, Map.put(proofs, :platform, elem(:os.type(), 1))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_session_probe(executable, fixture, responsibility, access, native_executable) do
    with {:ok, session_home} <-
           prepare_session_home(fixture.workspace, responsibility, native_executable) do
      result = safely_run_probe(fn -> run_probe_profile(executable, fixture, session_home, access) end)

      if probe_child_cleanup_pending?(result) do
        result
      else
        combine_cleanup_result(result, cleanup_session_home(session_home))
      end
    end
  end

  defp create_probe_fixture do
    probe_id = System.unique_integer([:positive])
    host_home = System.user_home!()
    root = Path.join(host_home, ".symphony-h080b-probe-#{probe_id}")
    workspace = Path.join(root, "workspace")
    sibling = Path.join(root, "sibling")
    outside = Path.join(root, "outside")
    fake_home = Path.join(host_home, ".symphony-h080b-credential-home-#{probe_id}")
    unix_socket = Path.join(System.tmp_dir!(), "symphony-h080b-sock-#{probe_id}")

    try do
      for path <- [workspace, sibling, outside, fake_home, Path.join(fake_home, ".ssh"), Path.join(fake_home, ".config/gh")] do
        File.mkdir_p!(path)
      end

      git = System.find_executable("git") || raise ArgumentError, "git is unavailable"

      case System.cmd(git, ["init", "--quiet", workspace],
             env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> raise ArgumentError, "workspace repository setup failed"
      end

      File.write!(Path.join(workspace, "readable.txt"), "workspace-sentinel\n")
      File.write!(Path.join(workspace, "writable.txt"), "before\n")
      File.write!(Path.join(workspace, "rename-source.txt"), "rename\n")
      File.write!(Path.join(workspace, "delete-target.txt"), "delete\n")
      File.write!(Path.join(sibling, "sibling.txt"), "sibling-sentinel\n")
      File.write!(Path.join(outside, "protected.txt"), "outside-sentinel\n")
      File.write!(Path.join(outside, "writable-target"), "before\n")
      File.write!(Path.join(root, "parent-protected.txt"), "workspace-parent-sentinel\n")
      File.write!(Path.join(fake_home, ".gitconfig"), "[credential]\\nhelper = sentinel\\n")
      File.write!(Path.join(fake_home, ".netrc"), "machine fake login sentinel password sentinel\\n")
      File.write!(Path.join(fake_home, ".ssh/config"), "Host fake\\n  IdentityFile id_sentinel\\n")
      File.write!(Path.join(fake_home, ".ssh/id_sentinel"), "fake-private-key-sentinel\\n")
      File.write!(Path.join(fake_home, ".config/gh/hosts.yml"), "github.com: oauth_token: sentinel\\n")
      File.ln_s!(Path.join(outside, "protected.txt"), Path.join(workspace, "escape-link"))

      {:ok,
       %{
         root: root,
         workspace: workspace,
         sibling: sibling,
         outside: outside,
         fake_home: fake_home,
         unix_socket: unix_socket,
         host_parent_entries: File.ls!(root) |> Enum.sort(),
         host_parent_snapshot: filesystem_snapshot!(root, [Path.basename(workspace)]),
         host_parent_sentinel: File.read!(Path.join(root, "parent-protected.txt")),
         host_sibling_snapshot: filesystem_snapshot!(sibling),
         host_workspace_snapshot: filesystem_snapshot!(workspace),
         host_parent_write_sentinel: Path.join(root, "SANDBOX_PARENT_WRITE_SENTINEL"),
         host_synthetic_sibling: Path.join(root, "SYNTHETIC-SIBLING")
       }}
    rescue
      error in [File.Error, ArgumentError] ->
        result = {:error, {:probe_fixture_failed, error.__struct__}}
        combine_cleanup_result(result, cleanup_probe_fixture(%{root: root, fake_home: fake_home}))
    end
  end

  defp cleanup_probe_fixture(%{root: root} = fixture) do
    [Map.get(fixture, :fake_home), root]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&remove_probe_fixture_path/1)
    |> Enum.find(:ok, fn
      {:error, _reason} -> true
      :ok -> false
    end)
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:runtime_isolation_cleanup_failed, :probe_fixture, error.__struct__}}
  end

  defp cleanup_probe_fixture(_fixture),
    do: {:error, {:runtime_isolation_cleanup_failed, :invalid_probe_fixture}}

  defp remove_probe_fixture_path(path) do
    case File.rm_rf(path) do
      {:ok, _removed_paths} ->
        :ok

      {:error, reason, failed_path} ->
        {:error, {:runtime_isolation_cleanup_failed, :probe_fixture, reason, Path.basename(failed_path)}}
    end
  end

  defp attach_host_state_results(%{results: results} = proof, fixture, access) do
    host_parent_entries = File.ls!(fixture.root) |> Enum.sort()
    host_parent_snapshot = filesystem_snapshot!(fixture.root, [Path.basename(fixture.workspace)])
    host_sibling_snapshot = filesystem_snapshot!(fixture.sibling)
    workspace_parent_entries = Map.get(results, "workspace_parent_entries", [])
    visible_parent_entries = if is_list(workspace_parent_entries), do: workspace_parent_entries, else: []
    known_host_entries = Enum.reject(fixture.host_parent_entries, &(&1 == Path.basename(fixture.workspace)))

    host_results = %{
      "workspace_parent_host_entry_names_visible" => Enum.any?(known_host_entries, &Enum.member?(visible_parent_entries, &1)),
      "host_parent_entries_unchanged" => host_parent_entries == fixture.host_parent_entries,
      "host_parent_snapshot_unchanged" => host_parent_snapshot == fixture.host_parent_snapshot,
      "host_parent_sentinel_unchanged" => File.read!(Path.join(fixture.root, "parent-protected.txt")) == fixture.host_parent_sentinel,
      "host_sibling_unchanged" => host_sibling_snapshot == fixture.host_sibling_snapshot,
      "host_parent_write_sentinel_absent" => not path_entry_exists?(fixture.host_parent_write_sentinel),
      "host_synthetic_sibling_absent" => not path_entry_exists?(fixture.host_synthetic_sibling),
      "host_workspace_matches_expected" =>
        workspace_matches_expected?(
          fixture.host_workspace_snapshot,
          filesystem_snapshot!(fixture.workspace),
          access
        )
    }

    host_results =
      if access == :read do
        Map.put(
          host_results,
          "host_workspace_unchanged",
          filesystem_snapshot!(fixture.workspace) == fixture.host_workspace_snapshot
        )
      else
        host_results
      end

    %{proof | results: Map.merge(results, host_results)}
  end

  @doc false
  @spec workspace_matches_expected?(map(), map(), access()) :: boolean()
  def workspace_matches_expected?(before, after_probe, :read), do: before == after_probe

  def workspace_matches_expected?(before, after_probe, :write) do
    removed_paths = ["rename-source.txt", "delete-target.txt"]
    changed_paths = ["", "created.txt", "writable.txt", "renamed.txt" | removed_paths]
    expected_paths = before |> Map.keys() |> Kernel.--(removed_paths) |> Kernel.++(["created.txt", "renamed.txt"])
    unchanged_paths = Enum.reject(Map.keys(before), &(&1 in changed_paths))

    checks = %{
      paths_match: MapSet.new(Map.keys(after_probe)) == MapSet.new(expected_paths),
      directory_preserved: directory_snapshot_preserved?(Map.get(before, ""), Map.get(after_probe, "")),
      unchanged_paths_preserved: Enum.all?(unchanged_paths, &(Map.get(before, &1) == Map.get(after_probe, &1))),
      created_file_valid: created_file_snapshot?(Map.get(before, "writable.txt"), Map.get(before, ""), Map.get(after_probe, "created.txt")),
      writable_file_valid: file_snapshot_preserved?(Map.get(before, "writable.txt"), Map.get(after_probe, "writable.txt"), "modified"),
      renamed_file_valid:
        file_snapshot_preserved?(
          Map.get(before, "rename-source.txt"),
          Map.get(after_probe, "renamed.txt"),
          "rename\n"
        )
    }

    Enum.all?(checks, fn {_check, passed?} -> passed? end)
  end

  defp directory_snapshot_preserved?(
         {:directory, before_metadata},
         {:directory, after_metadata}
       ) do
    preserved_metadata?(before_metadata, after_metadata)
  end

  defp directory_snapshot_preserved?(_before, _after), do: false

  defp created_file_snapshot?(
         {:file, baseline_metadata, _baseline_content},
         {:directory, directory_metadata},
         {:file, created_metadata, "created"}
       ) do
    created_metadata.mode == baseline_metadata.mode and
      created_metadata.uid == directory_metadata.uid and
      created_metadata.gid == directory_metadata.gid and
      created_metadata.links == 1 and
      created_metadata.major_device == directory_metadata.major_device and
      created_metadata.minor_device == directory_metadata.minor_device
  end

  defp created_file_snapshot?(_baseline_file, _directory, _created_file), do: false

  defp file_snapshot_preserved?(
         {:file, before_metadata, _before_content},
         {:file, after_metadata, expected_content},
         expected_content
       ) do
    preserved_metadata?(before_metadata, after_metadata)
  end

  defp file_snapshot_preserved?(_before, _after, _expected_content), do: false

  defp preserved_metadata?(before_metadata, after_metadata) do
    Enum.all?([:mode, :inode, :links, :uid, :gid, :major_device, :minor_device], fn key ->
      Map.get(before_metadata, key) == Map.get(after_metadata, key)
    end)
  end

  defp filesystem_snapshot!(root, excluded_children \\ []) do
    root = Path.expand(root)
    root_entry = snapshot_entry(root, File.lstat!(root))
    snapshot_directory(root, "", excluded_children, %{"" => root_entry})
  end

  defp snapshot_directory(root, relative_directory, excluded_children, snapshot) do
    current_directory = if relative_directory == "", do: root, else: Path.join(root, relative_directory)

    current_directory
    |> File.ls!()
    |> Enum.sort()
    |> Enum.reduce(snapshot, fn name, entries ->
      snapshot_child(root, relative_directory, name, excluded_children, entries)
    end)
  end

  defp snapshot_child(root, relative_directory, name, excluded_children, entries) do
    if relative_directory == "" and Enum.member?(excluded_children, name) do
      entries
    else
      add_snapshot_entry(root, relative_directory, name, excluded_children, entries)
    end
  end

  defp add_snapshot_entry(root, relative_directory, name, excluded_children, entries) do
    relative_path = if relative_directory == "", do: name, else: Path.join(relative_directory, name)
    path = Path.join(root, relative_path)
    stat = File.lstat!(path)
    entries = Map.put(entries, relative_path, snapshot_entry(path, stat))

    if stat.type == :directory do
      snapshot_directory(root, relative_path, excluded_children, entries)
    else
      entries
    end
  end

  defp snapshot_entry(_path, %File.Stat{type: :directory} = stat),
    do: {:directory, snapshot_metadata(stat)}

  defp snapshot_entry(path, %File.Stat{type: :regular} = stat),
    do: {:file, snapshot_metadata(stat), File.read!(path)}

  defp snapshot_entry(path, %File.Stat{type: :symlink} = stat),
    do: {:symlink, snapshot_metadata(stat), File.read_link!(path)}

  defp snapshot_entry(_path, %File.Stat{type: type} = stat),
    do: {type, snapshot_metadata(stat)}

  defp snapshot_metadata(stat) do
    %{
      mode: Bitwise.band(stat.mode, 0o7777),
      size: stat.size,
      mtime: stat.mtime,
      ctime: stat.ctime,
      inode: stat.inode,
      links: stat.links,
      uid: stat.uid,
      gid: stat.gid,
      major_device: stat.major_device,
      minor_device: stat.minor_device
    }
  end

  defp path_entry_exists?(path) do
    case File.lstat(path) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, reason} -> raise File.Error, reason: reason, action: "inspect", path: path
    end
  end

  defp render_config(profile, home) do
    access = Atom.to_string(profile.access)
    workspace = toml_string(hd(profile.workspace_roots))
    native = toml_string(profile.native_executable)
    session_home = toml_string(home)

    """
    allow_login_shell = false

    [permissions.#{profile.name}.filesystem]
    ":minimal" = "read"
    #{native} = "read"
    #{session_home} = "read"
    #{workspace} = "#{access}"
    #{toml_string(Path.join(hd(profile.workspace_roots), ".git"))} = "read"

    [permissions.#{profile.name}.network]
    enabled = false

    [permissions.#{profile.name}.workspace_roots]
    #{workspace} = true

    [shell_environment_policy]
    inherit = "all"
    include_only = #{toml_array(@safe_shell_environment)}
    ignore_default_excludes = false
    """
  end

  defp probe_credential_environment_names do
    (@credential_environment ++
       CredentialBoundary.deny_environment_names(CredentialBoundary.configured_secret_environment_names()))
    |> Enum.uniq()
  end

  defp probe_script(credential_environment_names) do
    credential_names = Enum.map_join(credential_environment_names, ", ", &toml_string/1)
    String.replace(@probe_script, "__CREDENTIAL_NAMES__", "[" <> credential_names <> "]")
  end

  defp toml_string(value), do: Jason.encode!(value)

  defp toml_array(values), do: "[" <> Enum.map_join(values, ", ", &toml_string/1) <> "]"

  defp access_for_responsibility(role) when role in ["planning", "planner", "review", "reviewer"], do: {:ok, :read}
  defp access_for_responsibility(role) when role in ["implementation", "builder", "correction", "fixer"], do: {:ok, :write}
  defp access_for_responsibility(role), do: {:error, {:unsupported_runtime_responsibility, role}}

  defp session_root(opts) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) -> Path.expand(root)
      _ -> Path.join(System.tmp_dir!(), "symphony-routed-session-#{System.unique_integer([:positive])}")
    end
  end

  defp create_session_directories(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case create_session_directory(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp create_session_directory(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:ephemeral_home_failed, reason}}
    end
  end

  defp safe_codex_command?(command) when is_binary(command) do
    byte_size(command) > 0 and
      not String.contains?(command, ["|", ">", "<", ";", "&", "$", "`", "\\", "'", "\"", "\n", "\r"]) and
      String.split(command) |> length() == 2
  end

  defp safe_codex_command?(_command), do: false

  defp find_executable(candidate) do
    if Path.type(candidate) == :absolute do
      if File.regular?(candidate) and File.stat!(candidate).mode |> Bitwise.band(0o111) != 0 do
        candidate
      end
    else
      System.find_executable(candidate)
    end
  end

  defp resolve_native_executable(canonical_executable) do
    case package_native_executable(canonical_executable) do
      {:ok, path} -> PathSafety.canonicalize(path)
      :error -> {:ok, canonical_executable}
    end
  end

  defp package_native_executable(executable) do
    target = platform_target()
    package = platform_package()
    package_name = String.replace_prefix(package, "@openai/", "")

    executable
    |> ancestor_directories(7)
    |> Enum.find_value(:error, fn parent ->
      candidate = Path.join([parent, "node_modules", "@openai", package_name, "vendor", target, "bin", codex_binary_name()])
      if File.regular?(candidate), do: {:ok, candidate}, else: nil
    end)
  end

  defp ancestor_directories(path, limit), do: ancestor_directories(Path.dirname(path), limit, [])

  defp ancestor_directories(_path, 0, acc), do: Enum.reverse(acc)

  defp ancestor_directories(path, limit, acc) do
    parent = Path.dirname(path)
    if parent == path, do: Enum.reverse([path | acc]), else: ancestor_directories(parent, limit - 1, [path | acc])
  end

  defp platform_target do
    system = elem(:os.type(), 1)
    architecture = :erlang.system_info(:system_architecture) |> to_string()
    platform_target(system, architecture_family(architecture))
  end

  @doc false
  @spec platform_target(atom(), atom()) :: String.t()
  def platform_target(:linux, :x86_64), do: "x86_64-unknown-linux-musl"
  def platform_target(:linux, :aarch64), do: "aarch64-unknown-linux-musl"
  def platform_target(:darwin, :x86_64), do: "x86_64-apple-darwin"
  def platform_target(:darwin, :aarch64), do: "aarch64-apple-darwin"
  def platform_target(_system, _architecture), do: "unsupported"

  @doc false
  @spec architecture_family(String.t()) :: :x86_64 | :aarch64 | :unsupported
  def architecture_family(architecture) do
    cond do
      String.contains?(architecture, "x86_64") -> :x86_64
      String.contains?(architecture, "aarch64") -> :aarch64
      true -> :unsupported
    end
  end

  defp platform_package, do: platform_package(platform_target())

  @doc false
  @spec platform_package(String.t()) :: String.t()
  def platform_package(target) do
    case target do
      "x86_64-unknown-linux-musl" -> "@openai/codex-linux-x64"
      "aarch64-unknown-linux-musl" -> "@openai/codex-linux-arm64"
      "x86_64-apple-darwin" -> "@openai/codex-darwin-x64"
      "aarch64-apple-darwin" -> "@openai/codex-darwin-arm64"
      _ -> "@openai/codex-unsupported"
    end
  end

  defp codex_binary_name do
    if elem(:os.type(), 0) == :win32, do: "codex.exe", else: "codex"
  end

  defp codex_version(executable) do
    root = session_root([])

    case create_session_root(root) do
      {:ok, root_identity} ->
        session_home = %{root: root, root_identity: root_identity}
        codex_home = Path.join(root, ".codex")
        result = safely_run_probe(fn -> query_codex_version(executable, root, codex_home) end)
        combine_cleanup_result(result, cleanup_session_home(session_home))

      {:error, _reason} ->
        {:error, :version_unavailable}
    end
  rescue
    error in [ErlangError, File.Error] -> {:error, {:version_unavailable, error.__struct__}}
  end

  defp query_codex_version(executable, home, codex_home) do
    :ok = File.mkdir_p(codex_home)
    env = CredentialBoundary.routed_port_env([], home, codex_home) |> Enum.map(&version_environment_entry/1)

    executable
    |> System.cmd(["--version"], env: env, cd: home, stderr_to_stdout: true)
    |> version_result()
  end

  defp version_environment_entry({name, value}) do
    name = List.to_string(name)
    value = if value == false, do: nil, else: List.to_string(value)
    {name, value}
  end

  defp version_result({output, 0}) do
    case String.trim(output) do
      "" -> {:error, :version_unavailable}
      version -> {:ok, version}
    end
  end

  defp version_result({_output, _status}), do: {:error, :version_unavailable}

  defp validate_supported_version(@supported_codex_version), do: :ok

  defp validate_supported_version(version),
    do: {:error, {:unsupported_codex_version, version}}

  defp run_port_command(executable, args, env, cwd, timeout) do
    charlist_env = Enum.map(env, fn {name, value} -> {List.wrap(name) |> List.flatten() |> to_string() |> String.to_charlist(), env_value(value)} end)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(args, &String.to_charlist/1),
        cd: String.to_charlist(cwd),
        env: charlist_env
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, root_pid} when is_integer(root_pid) and root_pid > 0 ->
        deadline = System.monotonic_time(:millisecond) + timeout
        collect_port_output(port, "", deadline, root_pid, [], 0)

      _other ->
        case terminate_probe_port(port) do
          :ok -> {:error, :codex_probe_process_id_unavailable}
          {:error, reason} -> {:error, {:runtime_isolation_probe_process_alive, reason}}
        end
    end
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:codex_probe_spawn_failed, error.__struct__}}
  end

  @spec collect_port_output(port(), binary(), integer(), pos_integer(), probe_process_ids(), integer()) ::
          {:ok, binary()} | {:error, term()}
  defp collect_port_output(port, output, deadline, root_pid, observed_descendants, next_scan_at) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      case terminate_probe_port(port) do
        :ok -> {:error, :codex_probe_timeout}
        {:error, reason} -> {:error, {:runtime_isolation_probe_process_alive, reason}}
      end
    else
      collect_port_output_after_scan(
        port,
        output,
        deadline,
        root_pid,
        observed_descendants,
        next_scan_at,
        now
      )
    end
  end

  @spec collect_port_output_after_scan(
          port(),
          binary(),
          integer(),
          pos_integer(),
          probe_process_ids(),
          integer(),
          integer()
        ) :: {:ok, binary()} | {:error, term()}
  defp collect_port_output_after_scan(
         port,
         output,
         deadline,
         root_pid,
         observed_descendants,
         next_scan_at,
         now
       ) do
    case observe_probe_descendants(root_pid, observed_descendants, next_scan_at, now) do
      {:ok, observed_descendants, next_scan_at} ->
        receive_port_output(
          port,
          output,
          deadline,
          root_pid,
          observed_descendants,
          next_scan_at,
          now
        )

      {:error, reason} ->
        stop_after_probe_process_inspection_failure(port, reason)
    end
  end

  defp stop_after_probe_process_inspection_failure(port, reason) do
    case terminate_probe_port(port) do
      :ok -> {:error, {:codex_probe_process_inspection_failed, reason}}
      {:error, cleanup_reason} -> {:error, {:runtime_isolation_probe_process_alive, cleanup_reason}}
    end
  end

  @spec observe_probe_descendants(pos_integer(), probe_process_ids(), integer(), integer()) ::
          {:ok, probe_process_ids(), integer()} | {:error, term()}
  defp observe_probe_descendants(_root_pid, observed_descendants, next_scan_at, now)
       when now < next_scan_at do
    {:ok, observed_descendants, next_scan_at}
  end

  defp observe_probe_descendants(root_pid, observed_descendants, _next_scan_at, now) do
    with {:ok, process_ids} <- probe_process_tree(root_pid) do
      descendants = Enum.reject(process_ids, &(&1 == root_pid))
      next_scan_at = now + @probe_process_poll_interval_ms
      {:ok, Enum.uniq(observed_descendants ++ descendants), next_scan_at}
    end
  end

  @spec receive_port_output(port(), binary(), integer(), pos_integer(), probe_process_ids(), integer(), integer()) ::
          {:ok, binary()} | {:error, term()}
  defp receive_port_output(port, output, deadline, root_pid, observed_descendants, next_scan_at, now) do
    timeout = min(deadline - now, max(next_scan_at - now, 0))

    receive do
      {^port, {:data, data}} ->
        collect_port_output(
          port,
          output <> data,
          deadline,
          root_pid,
          observed_descendants,
          next_scan_at
        )

      {^port, {:exit_status, status}} ->
        finish_probe_command(port, status, output, observed_descendants)
    after
      timeout ->
        collect_port_output(
          port,
          output,
          deadline,
          root_pid,
          observed_descendants,
          next_scan_at
        )
    end
  end

  @spec finish_probe_command(port(), non_neg_integer(), binary(), probe_process_ids()) ::
          {:ok, binary()} | {:error, term()}
  defp finish_probe_command(port, status, output, observed_descendants) do
    result = if status == 0, do: {:ok, output}, else: {:error, {:codex_probe_exit, status}}

    case await_observed_descendants_exit(observed_descendants) do
      :ok ->
        result

      {:error, process_ids} ->
        case terminate_probe_process_tree(port, process_ids) do
          :ok -> {:error, :codex_probe_descendant_survived}
          {:error, reason} -> {:error, {:runtime_isolation_probe_process_alive, reason}}
        end
    end
  end

  @spec await_observed_descendants_exit(probe_process_ids()) :: :ok | {:error, [pos_integer()]}
  defp await_observed_descendants_exit(observed_descendants) do
    case {observed_descendants, System.find_executable("kill")} do
      {[], _kill} ->
        :ok

      {_process_ids, kill} when is_binary(kill) ->
        case wait_probe_processes(kill, observed_descendants, @probe_process_term_timeout_ms) do
          :ok -> :ok
          :timeout -> {:error, Enum.filter(observed_descendants, &probe_process_alive?(kill, &1))}
        end

      {_process_ids, nil} ->
        {:error, observed_descendants}
    end
  end

  defp decode_probe_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, :codex_probe_output_missing}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"results" => results, "reason_classes" => reasons}} ->
          {:ok, %{results: results, reason_classes: reasons}}

        _ ->
          nil
      end
    end)
  end

  defp reject_probe_sentinel_output(output, sentinel) do
    if String.contains?(output, sentinel), do: {:error, :codex_probe_output_contains_sentinel}, else: :ok
  end

  defp find_python do
    System.find_executable("python3") || System.find_executable("python") || "python3"
  end

  defp start_tcp_listener do
    case :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        task = Task.async(fn -> :gen_tcp.accept(socket, 5_000) end)
        {:ok, %{socket: socket, task: task, port: port}}

      {:error, reason} ->
        {:error, {:tcp_probe_listener_failed, reason}}
    end
  end

  defp stop_tcp_listener(%{socket: socket, task: task}) do
    socket_result = safely_cleanup_probe_resource(fn -> :gen_tcp.close(socket) end)

    task_result =
      safely_cleanup_probe_resource(fn ->
        _ = Task.shutdown(task, :brutal_kill)

        if Process.alive?(task.pid) do
          {:error, {:runtime_isolation_cleanup_failed, :tcp_listener_task_alive}}
        else
          :ok
        end
      end)

    first_cleanup_error([socket_result, task_result])
  end

  defp start_unix_socket_server(path) do
    python = find_python()

    port =
      Port.open({:spawn_executable, String.to_charlist(python)}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          ~c"-c",
          ~c"import socket,sys; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind(sys.argv[1]); s.listen(1); print('ready',flush=True); c,_=s.accept(); c.close(); s.close()",
          String.to_charlist(path)
        ]
      ])

    case await_unix_server(port, "", 5_000) do
      {:ok, port} ->
        {:ok, port}

      {:error, _reason} = error ->
        cleanup_result =
          cleanup_probe_resources([
            fn -> terminate_probe_port(port) end,
            fn -> remove_probe_socket(path) end
          ])

        combine_cleanup_result(error, cleanup_result)
    end
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:unix_probe_listener_failed, error.__struct__}}
  end

  defp await_unix_server(port, output, timeout) do
    receive do
      {^port, {:data, data}} ->
        if String.contains?(output <> data, "ready") do
          {:ok, port}
        else
          await_unix_server(port, output <> data, timeout)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:unix_probe_listener_exit, status}}
    after
      timeout ->
        {:error, :unix_probe_listener_timeout}
    end
  end

  defp stop_unix_socket_server(port, path) when is_port(port) and is_binary(path) do
    case terminate_probe_port(port) do
      :ok -> remove_probe_socket(path)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec safely_run_probe((-> term())) :: {:ok, term()} | {:error, term()} | :ok
  def safely_run_probe(operation) when is_function(operation, 0) do
    case operation.() do
      {:ok, _result} = success -> success
      {:error, _reason} = error -> error
      :ok -> :ok
      _other -> {:error, :invalid_probe_result}
    end
  rescue
    _error -> {:error, :probe_failed}
  catch
    _kind, _reason -> {:error, :probe_failed}
  end

  @doc false
  @spec run_with_probe_cleanup((-> term()), [(-> term())]) :: {:ok, term()} | {:error, term()} | :ok
  def run_with_probe_cleanup(operation, cleanup_functions) do
    result = safely_run_probe(operation)
    cleanup_result = cleanup_probe_resources(cleanup_functions)
    combine_cleanup_result(result, cleanup_result)
  end

  defp cleanup_probe_resources(cleanup_functions) do
    cleanup_functions
    |> Enum.map(&safely_cleanup_probe_resource/1)
    |> first_cleanup_error()
  end

  @doc false
  @spec safely_cleanup_probe_resource((-> term())) :: :ok | {:error, term()}
  def safely_cleanup_probe_resource(cleanup) when is_function(cleanup, 0) do
    case cleanup.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, {:runtime_isolation_cleanup_failed, :invalid_cleanup_result}}
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, {:runtime_isolation_cleanup_failed, error.__struct__}}
  catch
    _kind, reason -> {:error, {:runtime_isolation_cleanup_failed, reason_class(reason)}}
  end

  defp first_cleanup_error(results) do
    Enum.find(results, :ok, &match?({:error, _reason}, &1))
  end

  @doc false
  @spec remove_probe_socket(Path.t()) :: :ok | {:error, term()}
  def remove_probe_socket(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:runtime_isolation_cleanup_failed, :unix_socket, reason}}
    end
  rescue
    error in [ArgumentError, File.Error] ->
      {:error, {:runtime_isolation_cleanup_failed, :unix_socket, error.__struct__}}
  end

  defp terminate_probe_port(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) and pid > 0 ->
        case probe_process_tree(pid) do
          {:ok, process_ids} ->
            terminate_probe_process_tree(port, process_ids)

          {:error, reason} ->
            _ = close_and_confirm_probe_port(port)
            {:error, {:runtime_isolation_cleanup_failed, :probe_process_tree, reason}}
        end

      nil ->
        close_and_confirm_probe_port(port)

      _other ->
        _ = close_and_confirm_probe_port(port)
        {:error, {:runtime_isolation_cleanup_failed, :probe_process_id_unavailable}}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:runtime_isolation_cleanup_failed, :probe_process, error.__struct__}}
  catch
    _kind, _reason -> {:error, {:runtime_isolation_cleanup_failed, :probe_process}}
  end

  defp probe_process_tree(root_pid) do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         {output, 0} <- System.cmd(ps, ["-eo", "pid=,ppid="], stderr_to_stdout: true) do
      {:ok, process_tree_from_table(root_pid, output)}
    else
      nil -> {:error, :process_inspection_unavailable}
      {_output, _status} -> {:error, :process_inspection_failed}
    end
  rescue
    error in [ErlangError, File.Error] -> {:error, error.__struct__}
  end

  defp parse_process_table(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &parse_process_table_line/2)
  end

  defp parse_process_table_line(line, table) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s*$/, line, capture: :all_but_first) do
      [pid, parent_pid] -> put_process_table_entry(table, pid, parent_pid)
      _ -> table
    end
  end

  defp put_process_table_entry(table, pid, parent_pid) do
    with {pid, ""} <- Integer.parse(pid),
         {parent_pid, ""} <- Integer.parse(parent_pid) do
      Map.put(table, pid, parent_pid)
    else
      _ -> table
    end
  end

  defp process_descendants(parent_pid, process_table, seen) do
    process_table
    |> Enum.filter(fn {pid, candidate_parent} ->
      candidate_parent == parent_pid and not MapSet.member?(seen, pid)
    end)
    |> Enum.reduce({[], seen}, fn {pid, _candidate_parent}, {descendants, seen} ->
      seen = MapSet.put(seen, pid)
      {nested, seen} = process_descendants(pid, process_table, seen)
      {descendants ++ nested ++ [pid], seen}
    end)
  end

  @doc false
  @spec process_tree_from_table(pos_integer(), String.t()) :: [pos_integer()]
  def process_tree_from_table(root_pid, output) when is_integer(root_pid) and root_pid > 0 and is_binary(output) do
    process_table = parse_process_table(output)
    {descendants, _seen} = process_descendants(root_pid, process_table, MapSet.new([root_pid]))
    [root_pid | descendants]
  end

  defp terminate_probe_process_tree(port, process_ids) do
    case System.find_executable("kill") do
      kill when is_binary(kill) ->
        terminate_probe_process_tree_with_kill(port, process_ids, kill)

      nil ->
        _ = close_and_confirm_probe_port(port)
        {:error, {:runtime_isolation_cleanup_failed, :process_signal_unavailable}}
    end
  end

  defp terminate_probe_process_tree_with_kill(port, process_ids, kill) do
    case signal_probe_processes(kill, process_ids, "TERM") do
      :ok -> wait_or_force_probe_stop(port, process_ids, kill)
      {:error, reason} -> failed_probe_process_signal(port, process_ids, kill, reason)
    end
  end

  defp wait_or_force_probe_stop(port, process_ids, kill) do
    case wait_probe_processes(kill, process_ids, @probe_process_term_timeout_ms) do
      :ok -> close_and_confirm_probe_port(port)
      :timeout -> force_stop_probe_processes(port, kill, process_ids)
    end
  end

  defp failed_probe_process_signal(port, process_ids, kill, reason) do
    _ = signal_probe_processes(kill, process_ids, "KILL")
    _ = close_and_confirm_probe_port(port)
    {:error, {:runtime_isolation_cleanup_failed, :probe_process_signal, reason}}
  end

  defp force_stop_probe_processes(port, kill, process_ids) do
    with :ok <- signal_probe_processes(kill, process_ids, "KILL"),
         :ok <- wait_probe_processes(kill, process_ids, @probe_process_kill_timeout_ms),
         :ok <- close_and_confirm_probe_port(port) do
      :ok
    else
      :timeout ->
        _ = close_and_confirm_probe_port(port)
        {:error, {:runtime_isolation_cleanup_failed, :probe_process_alive}}

      {:error, reason} ->
        _ = close_and_confirm_probe_port(port)
        {:error, {:runtime_isolation_cleanup_failed, :probe_process_kill, reason}}
    end
  end

  defp signal_probe_processes(kill, process_ids, signal) do
    Enum.reduce_while(process_ids, :ok, &signal_probe_process(&1, &2, kill, signal))
  rescue
    error in [ErlangError, File.Error] -> {:error, error.__struct__}
  end

  defp signal_probe_process(pid, :ok, kill, signal) do
    case System.cmd(kill, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> {:cont, :ok}
      {_output, _status} -> continue_or_fail_signal(kill, pid)
    end
  end

  defp continue_or_fail_signal(kill, pid) do
    if probe_process_alive?(kill, pid) do
      {:halt, {:error, :process_signal_failed}}
    else
      {:cont, :ok}
    end
  end

  defp wait_probe_processes(kill, process_ids, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_probe_process_exit(kill, process_ids, deadline)
  end

  defp await_probe_process_exit(kill, process_ids, deadline) do
    if Enum.all?(process_ids, &(not probe_process_alive?(kill, &1))) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(10)
        await_probe_process_exit(kill, process_ids, deadline)
      end
    end
  end

  defp probe_process_alive?(kill, pid) do
    case System.cmd(kill, ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error in [ErlangError, File.Error] -> true
  end

  defp close_and_confirm_probe_port(port) do
    monitor = :erlang.monitor(:port, port)

    try do
      _ = Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> :ok
    after
      @probe_port_close_timeout_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, {:runtime_isolation_cleanup_failed, :probe_port_alive}}
    end
  end

  @doc false
  @spec reason_class(term()) :: atom()
  def reason_class(reason) when is_atom(reason), do: reason
  def reason_class(_reason), do: :cleanup_failed

  @doc false
  @spec probe_child_cleanup_pending?(term()) :: boolean()
  def probe_child_cleanup_pending?({:error, {:runtime_isolation_probe_process_alive, _reason}}), do: true
  def probe_child_cleanup_pending?(_result), do: false

  @doc false
  @spec env_value(false | nil | String.t() | charlist()) :: false | charlist()
  def env_value(false), do: false
  def env_value(nil), do: false
  def env_value(value) when is_binary(value), do: String.to_charlist(value)
  def env_value(value) when is_list(value), do: value
end
