defmodule SymphonyElixir.CredentialBoundary do
  @moduledoc """
  H-050D process-boundary policy for provider and SCM credentials.

  Owns environment-name validation, deny-set construction, and child-process
  unset policy. Does not perform authorization or HTTP transport.
  """

  alias SymphonyElixir.{Config, PathSafety}

  @plane_api_key_env "PLANE_API_KEY"
  @plane_webhook_secret_env "PLANE_WEBHOOK_SECRET"

  @standard_github_token_envs ["GITHUB_TOKEN", "GH_TOKEN"]

  @scm_delegation_envs [
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GIT_ASKPASS",
    "SSH_ASKPASS",
    "SSH_ASKPASS_REQUIRE",
    "GIT_SSH",
    "GIT_SSH_COMMAND"
  ]

  @lineage_channel_env_names [
    "XDG_STATE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS"
  ]

  @routed_credential_channel_envs [
    "GH_CONFIG_DIR",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT"
  ]

  @routed_safe_inherited_envs ~w(PATH USER LOGNAME LANG TERM)

  @routed_ephemeral_home_env "SYMPHONY_ROUTED_EPHEMERAL_HOME"

  @routed_safe_approval_policy %{
    "granular" => %{
      "sandbox_approval" => false,
      "rules" => false,
      "mcp_elicitations" => false,
      "request_permissions" => false,
      "skill_approval" => false
    }
  }

  @spec valid_environment_name?(String.t()) :: boolean()
  def valid_environment_name?(name) when is_binary(name) do
    name != "" and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
  end

  def valid_environment_name?(_name), do: false

  @spec deny_environment_names([String.t()]) :: [String.t()]
  def deny_environment_names(secret_environment_names) when is_list(secret_environment_names) do
    configured =
      Enum.filter(secret_environment_names, &valid_environment_name?/1)

    Enum.uniq(
      @standard_github_token_envs ++
        [@plane_api_key_env, @plane_webhook_secret_env] ++
        configured ++
        @scm_delegation_envs ++
        @routed_credential_channel_envs ++
        current_git_config_channel_names()
    )
  end

  @spec configured_secret_environment_names() :: [String.t()]
  def configured_secret_environment_names do
    case Config.settings() do
      {:ok, settings} ->
        settings.tracker.secret_environment_names ++
          source_control_secret_names(settings.source_control)

      {:error, _} ->
        []
    end
  end

  @spec deny_environment_names_from_settings() :: [String.t()]
  def deny_environment_names_from_settings do
    deny_environment_names(configured_secret_environment_names())
  end

  @spec port_env([String.t()]) :: [{charlist(), false}]
  def port_env(secret_environment_names) when is_list(secret_environment_names) do
    secret_environment_names
    |> deny_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  @spec unset_shell_command([String.t()]) :: String.t() | nil
  def unset_shell_command(secret_environment_names) when is_list(secret_environment_names) do
    unset_shell_command_for_names(deny_environment_names(secret_environment_names))
  end

  @spec routed_unset_shell_command([String.t()]) :: String.t() | nil
  def routed_unset_shell_command(secret_environment_names) when is_list(secret_environment_names) do
    names = deny_environment_names(secret_environment_names) ++ @lineage_channel_env_names
    unset_shell_command_for_names(names)
  end

  defp unset_shell_command_for_names(names) do
    case Enum.uniq(names) do
      [] -> nil
      uniq -> "unset " <> Enum.join(uniq, " ")
    end
  end

  @spec hook_process_env([String.t()]) :: [{String.t(), String.t() | nil}]
  def hook_process_env(secret_environment_names) when is_list(secret_environment_names) do
    child_process_env(secret_environment_names, [])
  end

  @spec probe_process_env([String.t()]) :: [{String.t(), String.t() | nil}]
  def probe_process_env(secret_environment_names) when is_list(secret_environment_names) do
    child_process_env(
      secret_environment_names,
      git_probe_overrides()
    )
  end

  @spec routed_port_env([String.t()], Path.t(), Path.t() | nil) ::
          [{charlist(), charlist() | false}]
  def routed_port_env(secret_environment_names, home_dir, codex_home \\ nil)
      when is_list(secret_environment_names) and is_binary(home_dir) do
    state_home = Path.join(home_dir, ".local/state")
    config_home = Path.join(home_dir, ".config")
    cache_home = Path.join(home_dir, ".cache")
    temp_dir = Path.join(home_dir, "tmp")
    codex_home = codex_home || Path.join(home_dir, ".codex")
    current = System.get_env()

    inherited =
      current
      |> Enum.filter(fn {name, _value} ->
        name in @routed_safe_inherited_envs or String.starts_with?(name, "LC_")
      end)

    names_to_clear =
      current
      |> Map.keys()
      |> Kernel.++(deny_environment_names(secret_environment_names))
      |> Kernel.++(@lineage_channel_env_names)
      |> Kernel.++(@routed_credential_channel_envs)
      |> Kernel.++(current_git_config_channel_names())
      |> Enum.uniq()

    base = Enum.map(names_to_clear, &{String.to_charlist(&1), false})

    overrides =
      inherited ++
        [
          {"HOME", home_dir},
          {"XDG_STATE_HOME", state_home},
          {"XDG_CONFIG_HOME", config_home},
          {"XDG_CACHE_HOME", cache_home},
          {"XDG_RUNTIME_DIR", nil},
          {"DBUS_SESSION_BUS_ADDRESS", nil},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"CODEX_HOME", codex_home},
          {"TMPDIR", temp_dir},
          {"SHELL", "/bin/sh"},
          {@routed_ephemeral_home_env, home_dir},
          {"GIT_TERMINAL_PROMPT", "0"}
        ]

    overrides =
      Enum.map(overrides, fn {name, value} ->
        key = if is_atom(name), do: Atom.to_string(name), else: name
        {String.to_charlist(key), if(is_binary(value), do: String.to_charlist(value), else: false)}
      end)

    Map.new(base ++ overrides)
    |> Map.to_list()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec create_routed_ephemeral_home!() :: Path.t()
  def create_routed_ephemeral_home! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-routed-home-#{System.unique_integer([:positive])}"
      )

    for path <- [
          root,
          Path.join(root, ".local/state"),
          Path.join(root, ".config"),
          Path.join(root, ".cache"),
          Path.join(root, ".codex"),
          Path.join(root, "tmp")
        ] do
      File.mkdir_p!(path)
    end

    root
  end

  @routed_skipped_workspace_hooks ~w(before_run after_run before_remove)

  @max_workspace_git_config_bytes 1_048_576

  @spec routed_workspace_shell_hook_skipped?(String.t()) :: boolean()
  def routed_workspace_shell_hook_skipped?(hook_name) when is_binary(hook_name) do
    case Config.settings() do
      {:ok, %{agent: %{routing: "routed"}}} ->
        hook_name in @routed_skipped_workspace_hooks

      _ ->
        false
    end
  end

  @spec workspace_credential_residue(Path.t()) :: :ok | {:error, term()}
  def workspace_credential_residue(workspace) when is_binary(workspace) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(workspace),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, git_dir} <- workspace_git_dir(canonical_workspace),
         :ok <- inspect_workspace_git_dir(git_dir, canonical_workspace) do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_workspace_scm_credentials, :workspace_symlink}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_workspace_scm_credentials, {:workspace_type, type}}}

      {:error, :enoent} ->
        {:error, {:unsafe_workspace_scm_credentials, :workspace_missing}}

      {:error, {:unsafe_workspace_scm_credentials, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:unsafe_workspace_scm_credentials, safe_file_reason(reason)}}
    end
  rescue
    error in [ArgumentError, File.Error, ErlangError] ->
      {:error, {:unsafe_workspace_scm_credentials, error.__struct__}}
  end

  def workspace_credential_residue(_workspace),
    do: {:error, {:unsafe_workspace_scm_credentials, :invalid_workspace}}

  @spec child_process_env([String.t()], [{String.t(), String.t() | nil}]) ::
          [{String.t(), String.t() | nil}]
  def child_process_env(secret_environment_names, extra_overrides)
      when is_list(secret_environment_names) and is_list(extra_overrides) do
    unset_names =
      deny_environment_names(secret_environment_names) ++ @lineage_channel_env_names

    unset_set = MapSet.new(unset_names)

    env_map =
      System.get_env()
      |> Map.new()
      |> Map.merge(Map.new(extra_overrides))
      |> then(fn map ->
        Enum.reduce(unset_set, map, fn name, acc -> Map.put(acc, name, nil) end)
      end)

    Enum.sort_by(Map.to_list(env_map), &elem(&1, 0))
  end

  defp git_probe_overrides do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", nil},
      {"SSH_ASKPASS", nil}
    ]
  end

  defp current_git_config_channel_names do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&String.match?(&1, ~r/^GIT_CONFIG_(?:KEY|VALUE)_\d+$/))
  end

  defp workspace_git_dir(workspace) do
    git_entry = Path.join(workspace, ".git")

    case File.lstat(git_entry) do
      {:error, :enoent} -> {:ok, :none}
      {:ok, %File.Stat{type: :directory}} -> {:ok, git_entry}
      {:ok, %File.Stat{type: :regular}} -> resolve_workspace_gitfile(git_entry, workspace)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :git_metadata_symlink}
      {:ok, %File.Stat{type: type}} -> {:error, {:git_metadata_type, type}}
      {:error, reason} -> {:error, {:git_metadata_unreadable, reason}}
    end
  end

  defp resolve_workspace_gitfile(gitfile, workspace) do
    with {:ok, contents} <- File.read(gitfile),
         true <- byte_size(contents) <= 4_096,
         [_, target] <- Regex.run(~r/^gitdir:\s*(.+)\s*$/i, String.trim(contents)),
         {:ok, canonical_target} <- PathSafety.canonicalize(Path.expand(target, Path.dirname(gitfile))),
         true <- path_within?(canonical_target, workspace),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical_target) do
      {:ok, canonical_target}
    else
      false -> {:error, :git_metadata_outside_workspace}
      {:error, :enoent} -> {:error, :git_metadata_target_missing}
      {:error, _reason} -> {:error, :git_metadata_pointer_invalid}
      _other -> {:error, :git_metadata_pointer_invalid}
    end
  end

  defp inspect_workspace_git_dir(:none, _workspace), do: :ok

  defp inspect_workspace_git_dir(git_dir, workspace) when is_binary(git_dir) do
    config_path = Path.join(git_dir, "config")

    case File.lstat(config_path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_workspace_git_config_bytes ->
        inspect_workspace_git_config(config_path, workspace, git_dir)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:unsafe_workspace_scm_credentials, :git_config_too_large}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_workspace_scm_credentials, :git_config_symlink}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_workspace_scm_credentials, {:git_config_type, type}}}

      {:error, reason} ->
        {:error, {:unsafe_workspace_scm_credentials, safe_file_reason(reason)}}
    end
  end

  defp inspect_workspace_git_config(config_path, workspace, git_dir) do
    with {:ok, canonical_config} <- PathSafety.canonicalize(config_path),
         true <- path_within?(canonical_config, workspace),
         {:ok, entries} <- git_config_entries(canonical_config),
         :ok <- validate_workspace_git_entries(entries),
         :ok <- inspect_workspace_git_worktree_config(git_dir, workspace, entries) do
      :ok
    else
      false -> {:error, {:unsafe_workspace_scm_credentials, :git_config_outside_workspace}}
      {:error, {:unsafe_workspace_scm_credentials, _reason}} = error -> error
      {:error, _reason} -> {:error, {:unsafe_workspace_scm_credentials, :git_config_unreadable}}
    end
  end

  defp validate_workspace_git_entries(entries) do
    if Enum.any?(entries, &unsafe_workspace_git_entry?/1) do
      {:error, {:unsafe_workspace_scm_credentials, :credential_bearing_git_config}}
    else
      :ok
    end
  end

  defp inspect_workspace_git_worktree_config(git_dir, workspace, entries) do
    if worktree_config_enabled?(entries) do
      inspect_workspace_git_config_file(Path.join(git_dir, "config.worktree"), workspace)
    else
      :ok
    end
  end

  defp worktree_config_enabled?(entries) do
    Enum.any?(entries, fn
      {"extensions.worktreeconfig", value} -> String.downcase(String.trim(value)) in ["true", "yes", "on", "1"]
      _entry -> false
    end)
  end

  defp inspect_workspace_git_config_file(config_path, workspace) do
    case File.lstat(config_path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_workspace_git_config_bytes ->
        with {:ok, canonical_config} <- PathSafety.canonicalize(config_path),
             true <- path_within?(canonical_config, workspace),
             {:ok, entries} <- git_config_entries(canonical_config),
             :ok <- validate_workspace_git_entries(entries) do
          :ok
        else
          false -> {:error, {:unsafe_workspace_scm_credentials, :git_config_outside_workspace}}
          {:error, {:unsafe_workspace_scm_credentials, _reason}} = error -> error
          {:error, _reason} -> {:error, {:unsafe_workspace_scm_credentials, :git_config_unreadable}}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:unsafe_workspace_scm_credentials, :git_config_too_large}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_workspace_scm_credentials, :git_config_symlink}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_workspace_scm_credentials, {:git_config_type, type}}}

      {:error, reason} ->
        {:error, {:unsafe_workspace_scm_credentials, safe_file_reason(reason)}}
    end
  end

  defp git_config_entries(config_path) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_unavailable}

      git ->
        case System.cmd(
               git,
               ["config", "--file", config_path, "--no-includes", "--null", "--list"],
               env: isolated_git_config_env(),
               stderr_to_stdout: true
             ) do
          {output, 0} when byte_size(output) <= @max_workspace_git_config_bytes * 4 ->
            parse_git_config_output(output)

          {_output, 0} ->
            {:error, :git_config_output_too_large}

          {_output, _status} ->
            {:error, :git_config_parse_failed}
        end
    end
  rescue
    error in [ErlangError, ArgumentError] -> {:error, {:git_config_parse_failed, error.__struct__}}
  end

  defp parse_git_config_output(output) do
    entries =
      output
      |> :binary.split(<<0>>, [:global])
      |> Enum.reject(&(&1 == <<>>))
      |> Enum.map(fn entry ->
        case :binary.split(entry, "\n") do
          [key, value] -> {String.downcase(key), value}
          [key] -> {String.downcase(key), ""}
        end
      end)

    {:ok, entries}
  rescue
    _error -> {:error, :git_config_parse_failed}
  end

  defp unsafe_workspace_git_entry?({key, value}) do
    value = String.trim(value)
    value != "" and unsafe_workspace_git_config_entry?(key, value)
  end

  defp unsafe_workspace_git_config_entry?(key, value) do
    unsafe_git_credential_entry?(key) or unsafe_git_delegation_entry?(key) or
      unsafe_git_remote_url_entry?(key, value) or unsafe_git_url_rewrite_entry?(key, value) or
      unsafe_git_proxy_entry?(key, value)
  end

  defp unsafe_git_credential_entry?(key) do
    key == "credential.helper" or
      (String.starts_with?(key, "credential.") and
         (String.ends_with?(key, ".helper") or String.match?(key, ~r/(?:password|token|oauth)/)))
  end

  defp unsafe_git_delegation_entry?(key) do
    key == "core.sshcommand" or key == "include.path" or
      (String.starts_with?(key, "includeif.") and String.ends_with?(key, ".path")) or
      (String.starts_with?(key, "http.") and String.ends_with?(key, ".extraheader"))
  end

  defp unsafe_git_remote_url_entry?(key, value) do
    String.starts_with?(key, "remote.") and
      (String.ends_with?(key, ".url") or String.ends_with?(key, ".pushurl")) and
      unsafe_scm_url?(value)
  end

  defp unsafe_git_url_rewrite_entry?(key, value) do
    String.starts_with?(key, "url.") and
      (String.ends_with?(key, ".insteadof") or String.ends_with?(key, ".pushinsteadof")) and
      unsafe_git_url_rewrite?(key, value)
  end

  defp unsafe_git_proxy_entry?(key, value) do
    (key == "http.proxy" or String.ends_with?(key, ".proxy")) and unsafe_scm_url?(value)
  end

  defp unsafe_scm_url?(value) do
    uri = URI.parse(value)

    unsafe_scm_query?(uri.query) or unsafe_scm_userinfo?(uri.scheme, uri.userinfo) or unsafe_scp_user?(value)
  rescue
    _error -> true
  end

  defp unsafe_scm_query?(nil), do: false

  defp unsafe_scm_query?(query) do
    URI.decode_query(query)
    |> Enum.any?(fn {key, value} ->
      String.match?(String.downcase(key), ~r/(?:token|password|secret|authorization|oauth)/) and
        String.trim(value) != ""
    end)
  end

  defp unsafe_scm_userinfo?(scheme, userinfo) when scheme in ["http", "https"] and is_binary(userinfo),
    do: true

  defp unsafe_scm_userinfo?("ssh", userinfo) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      ["git"] -> false
      ["git", password] -> password != ""
      _ -> true
    end
  end

  defp unsafe_scm_userinfo?(_scheme, userinfo) when is_binary(userinfo),
    do: String.contains?(userinfo, ":")

  defp unsafe_scm_userinfo?(_scheme, _userinfo), do: false

  defp unsafe_scp_user?(value) do
    case Regex.run(~r{^([^/:@]+)@[^:]+:.+$}, value, capture: :all_but_first) do
      [username] -> username != "git"
      _ -> false
    end
  end

  defp unsafe_git_url_rewrite?(key, value) do
    rewritten_url =
      key
      |> String.replace_suffix(".pushinsteadof", "")
      |> String.replace_suffix(".insteadof", "")
      |> String.trim_leading("url.")

    unsafe_scm_url?(rewritten_url) or unsafe_scm_url?(value)
  end

  defp isolated_git_config_env do
    values =
      System.get_env()
      |> Map.keys()
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "PATH" => System.get_env("PATH"),
        "HOME" => System.tmp_dir!(),
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_SYSTEM" => "/dev/null",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_CONFIG_COUNT" => "0"
      })

    Enum.to_list(values)
  end

  defp path_within?(path, root) do
    path == root or String.starts_with?(path, Path.expand(root) <> "/")
  end

  defp safe_file_reason(reason) when is_atom(reason), do: reason
  defp safe_file_reason(_reason), do: :unreadable

  @spec routed_safe_approval_policy() :: map()
  def routed_safe_approval_policy, do: @routed_safe_approval_policy

  @spec redact(String.t(), [String.t()]) :: String.t()
  def redact(message, secret_environment_names)
      when is_binary(message) and is_list(secret_environment_names) do
    Enum.reduce(deny_environment_names(secret_environment_names), message, fn env_name, acc ->
      case System.get_env(env_name) do
        nil ->
          acc

        "" ->
          acc

        value ->
          String.replace(acc, value, "[REDACTED]")
      end
    end)
  end

  def redact(message, _secret_environment_names) when is_binary(message), do: message

  defp source_control_secret_names(nil), do: []

  defp source_control_secret_names(%{token_env: token_env}) when is_binary(token_env) do
    if valid_environment_name?(token_env), do: [token_env], else: []
  end

  defp source_control_secret_names(_source_control), do: []
end
