defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.AgentRuntime.RuntimeIsolation
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Codex.IsolationProfile
  alias SymphonyElixir.{Config, CredentialBoundary, PathSafety, SSH, Workspace}
  alias SymphonyElixir.Workspace.OwnershipLedger

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @stop_poll_interval_ms 10
  @stop_poll_attempts 20
  @port_monitor_timeout_ms 5_000
  @type session :: %{
          :port => port(),
          :os_pid => pos_integer() | nil,
          :metadata => map(),
          :approval_policy => String.t() | map(),
          :auto_approve_requests => boolean(),
          :thread_sandbox => String.t() | nil,
          :turn_sandbox_policy => map(),
          :thread_id => String.t(),
          :workspace => Path.t(),
          :worker_host => String.t() | nil,
          :dynamic_tool_binding => map(),
          :ephemeral_home => Path.t() | map() | nil,
          optional(:runtime_policies) => map(),
          optional(:routed) => boolean(),
          optional(:permission_profile) => String.t() | nil,
          optional(:runtime_workspace_roots) => [Path.t()] | nil,
          optional(:access) => :read | :write | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = DynamicTool.bind(opts)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts) do
      start_with_policies(
        expanded_workspace,
        worker_host,
        dynamic_tool_binding,
        opts,
        session_policies
      )
    end
  end

  defp start_with_policies(workspace, worker_host, dynamic_tool_binding, opts, session_policies) do
    case prepare_launch(workspace, worker_host, session_policies, opts) do
      {:ok, launch} ->
        start_prepared_launch(
          workspace,
          worker_host,
          dynamic_tool_binding,
          opts,
          session_policies,
          launch
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp start_prepared_launch(workspace, worker_host, dynamic_tool_binding, opts, session_policies, launch) do
    case revalidate_routed_workspace(workspace, session_policies, opts) do
      :ok ->
        case start_port(workspace, worker_host, dynamic_tool_binding, opts, session_policies, launch) do
          {:ok, port, ephemeral_home} ->
            start_session_on_port(
              port,
              ephemeral_home,
              workspace,
              worker_host,
              dynamic_tool_binding,
              opts,
              session_policies
            )

          {:error, reason} ->
            cleanup_launch_after_error(launch, reason)
        end

      {:error, reason} ->
        cleanup_launch_after_error(launch, reason)
    end
  end

  defp cleanup_launch_after_error(launch, reason) do
    case cleanup_launch(launch) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, cleanup_reason}
    end
  end

  defp start_session_on_port(port, ephemeral_home, workspace, worker_host, dynamic_tool_binding, opts, session_policies) do
    case do_start_session(port, workspace, session_policies, dynamic_tool_binding) do
      {:ok, thread_id} ->
        session =
          build_session(
            port,
            ephemeral_home,
            workspace,
            worker_host,
            dynamic_tool_binding,
            opts,
            session_policies,
            thread_id
          )

        {:ok, session}

      {:error, reason} ->
        cleanup_failed_session_start(port, ephemeral_home, reason)
    end
  end

  defp build_session(port, ephemeral_home, workspace, worker_host, dynamic_tool_binding, opts, session_policies, thread_id) do
    os_pid = port_os_pid(port)

    %{
      port: port,
      os_pid: os_pid,
      metadata: port_metadata(port, worker_host),
      approval_policy: policy_value(session_policies, :approval_policy),
      auto_approve_requests: auto_approve_requests?(session_policies, opts),
      thread_sandbox: policy_value(session_policies, :thread_sandbox),
      turn_sandbox_policy: policy_value(session_policies, :turn_sandbox_policy, %{}),
      thread_id: thread_id,
      workspace: workspace,
      worker_host: worker_host,
      dynamic_tool_binding: dynamic_tool_binding,
      ephemeral_home: ephemeral_home,
      runtime_policies: session_policies,
      routed: routed_policies?(session_policies),
      permission_profile: policy_value(session_policies, :permission_profile),
      runtime_workspace_roots: policy_value(session_policies, :runtime_workspace_roots),
      access: policy_value(session_policies, :access)
    }
  end

  defp cleanup_failed_session_start(port, ephemeral_home, reason) do
    case stop_port(port) do
      :ok ->
        case cleanup_ephemeral_home(ephemeral_home) do
          :ok -> {:error, reason}
          {:error, cleanup_reason} -> {:error, cleanup_reason}
        end

      {:error, _stop_reason} = error ->
        error
    end
  end

  defp routed_failure(session, session_policies, reason) do
    if routed_policies?(session_policies) do
      case stop_session(session) do
        :ok -> {:error, reason}
        {:error, cleanup_reason} -> {:error, cleanup_reason}
      end
    else
      {:error, reason}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    session_policies =
      Map.get(
        session,
        :runtime_policies,
        %{
          approval_policy: approval_policy,
          turn_sandbox_policy: Map.get(session, :turn_sandbox_policy, %{}),
          routed: Map.get(session, :routed, false),
          permission_profile: Map.get(session, :permission_profile),
          runtime_workspace_roots: Map.get(session, :runtime_workspace_roots)
        }
      )

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_tool_binding = overlay_agent_tool_context(dynamic_tool_binding, opts)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, turn_tool_binding, issue: issue)
      end)

    case start_turn(
           port,
           thread_id,
           prompt,
           issue,
           workspace,
           session_policies,
           Keyword.get(opts, :model)
         ) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            routed_failure(session, session_policies, reason)
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        result = routed_failure(session, session_policies, reason)
        emit_message(on_message, :startup_failed, %{reason: elem(result, 1)}, metadata)
        result
    end
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(%{port: port} = session) when is_port(port) do
    case stop_port(port, Map.get(session, :os_pid)) do
      :ok ->
        cleanup_ephemeral_home(Map.get(session, :ephemeral_home))

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding, opts, session_policies, launch) do
    if routed_policies?(session_policies) do
      start_routed_local_port(workspace, dynamic_tool_binding, launch)
    else
      start_legacy_local_port(workspace, dynamic_tool_binding, opts)
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding, opts, session_policies, _launch)
       when is_binary(worker_host) do
    if routed_policies?(session_policies) do
      {:error, {:runtime_isolation_unavailable, :remote_containment_unproven}}
    else
      remote_command = remote_launch_command(workspace, dynamic_tool_binding, opts)

      case SSH.start_port(worker_host, remote_command, line: @port_line_bytes) do
        {:ok, port} -> {:ok, port, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_legacy_local_port(workspace, dynamic_tool_binding, opts) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      {port_env, ephemeral_home} = local_port_env(dynamic_tool_binding, opts)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding, opts))],
            cd: String.to_charlist(workspace),
            env: port_env,
            line: @port_line_bytes
          ]
        )

      {:ok, port, ephemeral_home}
    end
  end

  defp start_routed_local_port(
         workspace,
         dynamic_tool_binding,
         %{
           resolved: resolved,
           session_home: session_home,
           launch_identity: launch_identity,
           runtime_evidence: runtime_evidence
         }
       ) do
    with :ok <- validate_routed_runtime_identity(resolved, launch_identity, runtime_evidence) do
      env =
        CredentialBoundary.routed_port_env(
          dynamic_tool_binding.secret_environment_names,
          session_home.home,
          session_home.codex_home
        )

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(resolved.executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(resolved.argv, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: env,
            line: @port_line_bytes
          ]
        )

      {:ok, port, session_home}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:codex_spawn_failed, error.__struct__}}
  end

  defp local_port_env(dynamic_tool_binding, opts) do
    if routed_profile?(opts) do
      home_dir = CredentialBoundary.create_routed_ephemeral_home!()

      {CredentialBoundary.routed_port_env(dynamic_tool_binding.secret_environment_names, home_dir), home_dir}
    else
      {CredentialBoundary.port_env(dynamic_tool_binding.secret_environment_names), nil}
    end
  end

  defp local_launch_command(dynamic_tool_binding, opts) do
    unset_command =
      if routed_profile?(opts) do
        CredentialBoundary.routed_unset_shell_command(dynamic_tool_binding.secret_environment_names)
      else
        CredentialBoundary.unset_shell_command(dynamic_tool_binding.secret_environment_names)
      end

    [
      unset_command,
      "exec #{runtime_command(opts)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp cleanup_ephemeral_home(nil), do: :ok

  defp cleanup_ephemeral_home(%{} = session_home) do
    IsolationProfile.cleanup_session_home(session_home)
  end

  defp cleanup_ephemeral_home(home_dir) when is_binary(home_dir) do
    File.rm_rf(home_dir)
    :ok
  end

  defp cleanup_launch(%{session_home: session_home}), do: cleanup_ephemeral_home(session_home)
  defp cleanup_launch(_launch), do: :ok

  defp remote_launch_command(workspace, dynamic_tool_binding, opts) when is_binary(workspace) do
    unset_command =
      if routed_profile?(opts) do
        CredentialBoundary.routed_unset_shell_command(dynamic_tool_binding.secret_environment_names)
      else
        CredentialBoundary.unset_shell_command(dynamic_tool_binding.secret_environment_names)
      end

    [
      "cd #{shell_escape(workspace)}",
      unset_command,
      "exec #{runtime_command(opts)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp runtime_command(opts) do
    case Keyword.get(opts, :command) do
      command when is_binary(command) and byte_size(command) > 0 -> command
      _ -> Config.settings!().codex.command
    end
  end

  defp auto_approve_requests?(session_policies, opts) do
    routed_policies?(session_policies) == false and
      policy_value(session_policies, :approval_policy) == "never" and
      routed_profile?(opts) == false
  end

  defp routed_profile?(opts) do
    case Keyword.get(opts, :sandbox) do
      sandbox when sandbox in ["read-only", "workspace-write"] -> true
      _ -> false
    end
  end

  defp routed_policies?(session_policies) when is_map(session_policies) do
    policy_value(session_policies, :routed, false) == true
  end

  defp policy_value(session_policies, key, default \\ nil) when is_map(session_policies) do
    case Map.fetch(session_policies, key) do
      {:ok, value} -> value
      :error -> Map.get(session_policies, Atom.to_string(key), default)
    end
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, opts) do
    Config.codex_runtime_settings(workspace, opts)
  end

  defp session_policies(workspace, worker_host, opts) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, Keyword.put(opts, :remote, true))
  end

  defp prepare_launch(_workspace, worker_host, session_policies, _opts)
       when is_binary(worker_host) do
    if routed_policies?(session_policies) do
      {:error, {:runtime_isolation_unavailable, :remote_containment_unproven}}
    else
      {:ok, nil}
    end
  end

  defp prepare_launch(workspace, nil, session_policies, opts) do
    if routed_policies?(session_policies) do
      prepare_routed_launch(workspace, session_policies, opts)
    else
      {:ok, nil}
    end
  end

  defp prepare_routed_launch(workspace, session_policies, opts) do
    with :ok <- validate_routed_policy(session_policies, workspace),
         :ok <- revalidate_routed_workspace(workspace, session_policies, opts),
         {:ok, resolved} <- IsolationProfile.resolve_codex_executable(runtime_command(opts)),
         {:ok, launch_identity} <- runtime_file_identity(resolved),
         {:ok, runtime_evidence} <- admit_runtime(resolved.executable, opts),
         :ok <- validate_routed_runtime_identity(resolved, launch_identity, runtime_evidence),
         {:ok, session_home} <-
           IsolationProfile.prepare_session_home(
             workspace,
             policy_value(session_policies, :responsibility),
             resolved.native_executable,
             session_home_opts(opts)
           ) do
      bind_routed_session_home(
        resolved,
        session_home,
        session_policies,
        workspace,
        launch_identity,
        runtime_evidence
      )
    end
  end

  defp bind_routed_session_home(
         resolved,
         session_home,
         session_policies,
         workspace,
         launch_identity,
         runtime_evidence
       ) do
    case validate_session_home(session_home, session_policies, workspace) do
      :ok ->
        {:ok,
         %{
           resolved: resolved,
           session_home: session_home,
           launch_identity: launch_identity,
           runtime_evidence: runtime_evidence
         }}

      {:error, reason} ->
        cleanup_launch_after_error(%{session_home: session_home}, reason)
    end
  end

  defp revalidate_routed_workspace(workspace, session_policies, opts) when is_map(session_policies) do
    if routed_policies?(session_policies) do
      case test_runtime_workspace_admit(opts) do
        {:test, admission} ->
          invoke_test_workspace_admission(admission, workspace, opts)

        :production ->
          revalidate_runtime_workspace(workspace, opts)
      end
    else
      :ok
    end
  end

  defp test_runtime_workspace_admit(opts) do
    if test_environment?() do
      case Keyword.get(opts, :test_runtime_workspace_admit) do
        admission when is_function(admission, 2) -> {:test, admission}
        admission when is_function(admission, 3) -> {:test, admission}
        _missing -> :production
      end
    else
      :production
    end
  end

  defp invoke_test_workspace_admission(admission, workspace, opts) when is_function(admission, 2) do
    normalize_workspace_admission(admission.(Keyword.get(opts, :runtime_issue), workspace))
  end

  defp invoke_test_workspace_admission(admission, workspace, opts) when is_function(admission, 3) do
    normalize_workspace_admission(
      admission.(
        Keyword.get(opts, :runtime_issue),
        workspace,
        Keyword.get(opts, :ownership_ledger)
      )
    )
  end

  defp normalize_workspace_admission(:ok), do: :ok

  defp normalize_workspace_admission({:error, reason}),
    do: {:error, {:runtime_isolation_unavailable, {:workspace_identity_unproven, reason}}}

  defp normalize_workspace_admission(other),
    do: {:error, {:runtime_isolation_unavailable, {:workspace_admission_invalid, other}}}

  defp revalidate_runtime_workspace(workspace, opts) do
    issue = Keyword.get(opts, :runtime_issue)
    ledger = Keyword.get(opts, :ownership_ledger)

    with %OwnershipLedger{} <- ledger,
         true <- is_map(issue) or is_struct(issue),
         :ok <- Workspace.revalidate_owned_local_workspace(issue, workspace, ledger),
         :ok <- CredentialBoundary.workspace_credential_residue(workspace) do
      :ok
    else
      {:error, {:unsafe_workspace_scm_credentials, _reason}} ->
        {:error, {:runtime_isolation_unavailable, :workspace_scm_boundary_unproven}}

      {:error, _reason} ->
        {:error, {:runtime_isolation_unavailable, :workspace_identity_unproven}}

      _missing_context ->
        {:error, {:runtime_isolation_unavailable, :workspace_identity_unproven}}
    end
  end

  defp validate_routed_policy(session_policies, workspace) do
    responsibility = policy_value(session_policies, :responsibility)
    permission_profile = policy_value(session_policies, :permission_profile)
    runtime_workspace_roots = policy_value(session_policies, :runtime_workspace_roots)
    access = policy_value(session_policies, :access)

    cond do
      not is_binary(responsibility) or String.trim(responsibility) == "" ->
        {:error, {:invalid_routed_policy, :responsibility}}

      not is_binary(permission_profile) or String.trim(permission_profile) == "" ->
        {:error, {:invalid_routed_policy, :permission_profile}}

      access not in [:read, :write] ->
        {:error, {:invalid_routed_policy, :access}}

      runtime_workspace_roots != [workspace] ->
        {:error, {:invalid_routed_policy, :runtime_workspace_roots, [workspace], runtime_workspace_roots}}

      true ->
        :ok
    end
  end

  @doc false
  @spec validate_session_home(map(), map(), Path.t()) :: :ok | {:error, term()}
  def validate_session_home(session_home, session_policies, workspace) do
    expected_profile = policy_value(session_policies, :permission_profile)
    expected_access = policy_value(session_policies, :access)

    cond do
      session_home.permission_profile != expected_profile ->
        {:error, {:runtime_profile_mismatch, :prepared_session_home, expected_profile, session_home.permission_profile}}

      session_home.workspace != workspace ->
        {:error, {:runtime_workspace_mismatch, :prepared_session_home, workspace, session_home.workspace}}

      session_home.access != expected_access ->
        {:error, {:runtime_access_mismatch, :prepared_session_home, expected_access, session_home.access}}

      true ->
        :ok
    end
  end

  defp admit_runtime(executable, opts) do
    test_admission? = test_environment?() and Keyword.has_key?(opts, :test_runtime_isolation_admit)

    admit =
      if test_environment?() do
        Keyword.get(opts, :test_runtime_isolation_admit, &RuntimeIsolation.admit/3)
      else
        &RuntimeIsolation.admit/3
      end

    result =
      cond do
        is_function(admit, 3) -> admit.(nil, executable, [])
        is_function(admit, 2) -> admit.(nil, executable)
        true -> {:error, {:runtime_isolation_admission_invalid, :callback}}
      end

    case result do
      {:ok, _evidence} when test_admission? ->
        {:ok, :test_admitted}

      {:ok, %{status: :verified, fingerprint: fingerprint}} ->
        {:ok, {:verified, fingerprint}}

      {:error, reason} ->
        {:error, reason}

      {:ok, _evidence} ->
        {:error, {:runtime_isolation_admission_invalid, :evidence}}

      other ->
        {:error, {:runtime_isolation_admission_invalid, other}}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:runtime_isolation_admission_failed, error.__struct__}}
  catch
    _kind, _reason -> {:error, :runtime_isolation_admission_failed}
  end

  defp runtime_file_identity(resolved) do
    paths = Enum.uniq([resolved.executable, resolved.native_executable])

    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, identities} ->
      with {:ok, canonical_path} <- PathSafety.canonicalize(path),
           {:ok, %File.Stat{} = stat} <- File.stat(canonical_path),
           {:ok, binary} <- File.read(canonical_path) do
        identity = %{
          path: canonical_path,
          device: {stat.major_device, stat.minor_device},
          inode: stat.inode,
          mode: stat.mode,
          size: stat.size,
          mtime: stat.mtime,
          digest: :crypto.hash(:sha256, binary)
        }

        {:cont, {:ok, Map.put(identities, path, identity)}}
      else
        _error -> {:halt, {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}}}
      end
    end)
  rescue
    _error in [ArgumentError, File.Error, ErlangError] ->
      {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}}
  end

  defp validate_routed_runtime_identity(resolved, expected_identity, runtime_evidence) do
    with {:ok, current_identity} <- runtime_file_identity(resolved),
         true <- current_identity == expected_identity,
         :ok <- validate_runtime_evidence(resolved.executable, runtime_evidence) do
      :ok
    else
      false -> {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_runtime_evidence(_executable, :test_admitted), do: :ok

  defp validate_runtime_evidence(executable, {:verified, fingerprint}) do
    case RuntimeIsolation.evidence(executable) do
      %{status: :verified, fingerprint: ^fingerprint} -> :ok
      _evidence -> {:error, {:runtime_isolation_unavailable, :runtime_changed_after_admission}}
    end
  rescue
    _error -> {:error, {:runtime_isolation_unavailable, :verifier_unavailable}}
  catch
    :exit, _reason -> {:error, {:runtime_isolation_unavailable, :verifier_unavailable}}
  end

  defp test_environment? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  rescue
    _ -> false
  end

  defp session_home_opts(opts) do
    case Keyword.get(opts, :runtime_session_root, Keyword.get(opts, :session_home_root)) do
      root when is_binary(root) -> [root: root]
      _ -> []
    end
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies, dynamic_tool_binding)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, session_policies, dynamic_tool_binding) do
    if routed_policies?(session_policies) do
      start_routed_thread(port, workspace, session_policies, dynamic_tool_binding)
    else
      start_legacy_thread(port, workspace, session_policies, dynamic_tool_binding)
    end
  end

  defp start_legacy_thread(port, workspace, session_policies, dynamic_tool_binding) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => policy_value(session_policies, :approval_policy),
        "sandbox" => policy_value(session_policies, :thread_sandbox),
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp start_routed_thread(port, workspace, session_policies, dynamic_tool_binding) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => policy_value(session_policies, :approval_policy),
        "permissions" => policy_value(session_policies, :permission_profile),
        "runtimeWorkspaceRoots" => policy_value(session_policies, :runtime_workspace_roots),
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => thread_id}} = response} ->
        case validate_runtime_provenance(response, session_policies, workspace, :thread_start) do
          :ok -> {:ok, thread_id}
          {:error, _reason} = error -> error
        end

      {:ok, %{"thread" => thread_payload}} ->
        {:error, {:invalid_thread_payload, thread_payload}}

      other ->
        other
    end
  end

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         session_policies,
         model
       ) do
    base_params = %{
      "threadId" => thread_id,
      "input" => [
        %{
          "type" => "text",
          "text" => prompt
        }
      ],
      "cwd" => workspace,
      "title" => "#{issue.identifier}: #{issue.title}",
      "approvalPolicy" => policy_value(session_policies, :approval_policy)
    }

    params =
      if routed_policies?(session_policies) do
        Map.merge(base_params, %{
          "permissions" => policy_value(session_policies, :permission_profile),
          "runtimeWorkspaceRoots" => policy_value(session_policies, :runtime_workspace_roots)
        })
      else
        Map.put(base_params, "sandboxPolicy", policy_value(session_policies, :turn_sandbox_policy, %{}))
      end

    params = maybe_put_model(params, model)

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}} = response} ->
        case validate_turn_provenance(response, session_policies, workspace) do
          :ok -> {:ok, turn_id}
          {:error, _reason} = error -> error
        end

      other ->
        other
    end
  end

  defp validate_runtime_provenance(response, session_policies, workspace, phase) do
    expected_profile = policy_value(session_policies, :permission_profile)
    expected_roots = policy_value(session_policies, :runtime_workspace_roots)

    actual_profile =
      response
      |> Map.get("activePermissionProfile")
      |> profile_id()

    actual_roots = Map.get(response, "runtimeWorkspaceRoots")
    actual_cwd = Map.get(response, "cwd")

    with :ok <-
           compare_provenance(
             phase,
             :active_permission_profile,
             expected_profile,
             actual_profile
           ),
         :ok <- compare_provenance(phase, :runtime_workspace_roots, expected_roots, actual_roots) do
      compare_provenance(phase, :cwd, workspace, actual_cwd)
    end
  end

  defp validate_turn_provenance(response, session_policies, workspace) do
    case routed_policies?(session_policies) do
      true -> validate_routed_turn_provenance(response, session_policies, workspace)
      false -> :ok
    end
  end

  defp validate_routed_turn_provenance(response, session_policies, workspace) do
    turn_payload = Map.get(response, "turn", %{})

    case turn_provenance_present?(response, turn_payload) do
      true ->
        provenance = Map.merge(response, turn_payload_map(turn_payload))
        validate_runtime_provenance(provenance, session_policies, workspace, :turn_start)

      false ->
        {:error, {:runtime_provenance_missing, :turn_start}}
    end
  end

  defp turn_provenance_present?(response, turn_payload) do
    Enum.any?([response, turn_payload], &provenance_payload?/1)
  end

  defp provenance_payload?(payload) when is_map(payload) do
    Enum.any?(["activePermissionProfile", "runtimeWorkspaceRoots", "cwd"], &Map.has_key?(payload, &1))
  end

  defp provenance_payload?(_payload), do: false

  defp turn_payload_map(turn_payload) when is_map(turn_payload), do: turn_payload
  defp turn_payload_map(_turn_payload), do: %{}

  defp profile_id(%{"id" => id}) when is_binary(id), do: id
  defp profile_id(id) when is_binary(id), do: id
  defp profile_id(_profile), do: nil

  defp compare_provenance(_phase, _field, expected, expected), do: :ok

  defp compare_provenance(phase, field, expected, actual),
    do: {:error, {:runtime_provenance_mismatch, phase, field, expected, actual}}

  defp maybe_put_model(params, model) when is_binary(model) do
    if String.trim(model) == "", do: params, else: Map.put(params, "model", model)
  end

  defp maybe_put_model(params, _model), do: params

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, data, timeout_ms, tool_executor, auto_approve_requests) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          auto_approve_requests
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    stop_port(port, port_os_pid(port))
  end

  defp stop_port(port, fallback_os_pid) when is_port(port) do
    os_pid = port_os_pid(port) || fallback_os_pid
    ref = :erlang.monitor(:port, port)

    close_result = close_port(port)

    receive do
      {:DOWN, ^ref, :port, ^port, _reason} ->
        case {close_result, os_pid} do
          {:already_closed, nil} ->
            {:error, {:stop_failed, :session_stopped}}

          _ ->
            case terminate_os_process(os_pid) do
              :ok -> :ok
              {:error, reason} -> {:error, {:stop_failed, reason}}
            end
        end
    after
      @port_monitor_timeout_ms ->
        Process.demonitor(ref, [:flush])
        _ = terminate_os_process(os_pid)
        {:error, {:stop_failed, :process_state_unavailable}}
    end
  end

  defp close_port(port) do
    Port.close(port)
    :closed
  rescue
    ArgumentError -> :already_closed
  end

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp terminate_os_process(nil), do: :ok

  defp terminate_os_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case System.find_executable("kill") do
      nil ->
        {:error, :process_state_unavailable}

      kill ->
        run_kill(kill, ["-TERM", "-#{os_pid}"])
        run_kill(kill, ["-TERM", Integer.to_string(os_pid)])

        case await_os_process_exit(kill, os_pid, @stop_poll_attempts) do
          :ok ->
            :ok

          {:error, :process_still_running} ->
            run_kill(kill, ["-KILL", "-#{os_pid}"])
            run_kill(kill, ["-KILL", Integer.to_string(os_pid)])
            await_os_process_exit(kill, os_pid, @stop_poll_attempts * 5)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp await_os_process_exit(_kill, _os_pid, 0), do: {:error, :process_still_running}

  defp await_os_process_exit(kill, os_pid, attempts) do
    case run_kill(kill, ["-0", Integer.to_string(os_pid)]) do
      {:ok, 0} ->
        Process.sleep(@stop_poll_interval_ms)
        await_os_process_exit(kill, os_pid, attempts - 1)

      {:ok, _status} ->
        :ok

      :error ->
        {:error, :process_state_unavailable}
    end
  end

  defp run_kill(kill, args) do
    case System.cmd(kill, args, stderr_to_stdout: true) do
      {_output, status} -> {:ok, status}
    end
  rescue
    _ -> :error
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp overlay_agent_tool_context(binding, opts) do
    case Keyword.get(opts, :agent_tool_context) do
      context when is_map(context) -> Map.put(binding, :agent_tool_context, context)
      _missing -> binding
    end
  end

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
