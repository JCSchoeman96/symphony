defmodule SymphonyElixir.CredentialBoundary do
  @moduledoc """
  H-050D process-boundary policy for provider and SCM credentials.

  Owns environment-name validation, deny-set construction, and child-process
  unset policy. Does not perform authorization or HTTP transport.
  """

  alias SymphonyElixir.Config

  @plane_api_key_env "PLANE_API_KEY"

  @standard_github_token_envs ["GITHUB_TOKEN", "GH_TOKEN"]

  @scm_delegation_envs [
    "SSH_AUTH_SOCK",
    "GIT_ASKPASS",
    "SSH_ASKPASS",
    "SSH_ASKPASS_REQUIRE",
    "GIT_SSH",
    "GIT_SSH_COMMAND"
  ]

  @lineage_channel_env_names [
    "XDG_STATE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME"
  ]

  @routed_ephemeral_home_env "SYMPHONY_ROUTED_EPHEMERAL_HOME"

  @routed_safe_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
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

    Enum.uniq(@standard_github_token_envs ++ [@plane_api_key_env] ++ configured ++ @scm_delegation_envs)
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
    unset_shell_command_for_names(deny_environment_names(secret_environment_names) ++ @lineage_channel_env_names)
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

  @spec routed_port_env([String.t()], Path.t()) :: [{charlist(), charlist() | false}]
  def routed_port_env(secret_environment_names, home_dir)
      when is_list(secret_environment_names) and is_binary(home_dir) do
    state_home = Path.join(home_dir, ".local/state")
    config_home = Path.join(home_dir, ".config")
    cache_home = Path.join(home_dir, ".cache")

    port_env(secret_environment_names) ++
      [
        {String.to_charlist("HOME"), String.to_charlist(home_dir)},
        {String.to_charlist("XDG_STATE_HOME"), String.to_charlist(state_home)},
        {String.to_charlist("XDG_CONFIG_HOME"), String.to_charlist(config_home)},
        {String.to_charlist("XDG_CACHE_HOME"), String.to_charlist(cache_home)},
        {String.to_charlist(@routed_ephemeral_home_env), String.to_charlist(home_dir)}
      ]
  end

  @spec create_routed_ephemeral_home!() :: Path.t()
  def create_routed_ephemeral_home! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-routed-home-#{System.unique_integer([:positive])}"
      )

    for path <- [root, Path.join(root, ".local/state"), Path.join(root, ".config"), Path.join(root, ".cache")] do
      File.mkdir_p!(path)
    end

    root
  end

  @spec routed_workspace_shell_hooks_disabled?() :: boolean()
  def routed_workspace_shell_hooks_disabled? do
    case Config.settings() do
      {:ok, %{agent: %{routing: "routed"}}} -> true
      _ -> false
    end
  end

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
