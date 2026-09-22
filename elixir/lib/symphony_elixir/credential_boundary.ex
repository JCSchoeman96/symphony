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
    case deny_environment_names(secret_environment_names) do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  @spec hook_process_env([String.t()]) :: [{String.t(), String.t()}]
  def hook_process_env(secret_environment_names) when is_list(secret_environment_names) do
    deny_set = MapSet.new(deny_environment_names(secret_environment_names))

    System.get_env()
    |> Enum.reject(fn {name, _value} -> MapSet.member?(deny_set, name) end)
    |> Enum.map(fn {name, value} -> {name, value} end)
  end

  @spec probe_process_env([String.t()]) :: [{String.t(), String.t()}]
  def probe_process_env(secret_environment_names) when is_list(secret_environment_names) do
    hook_process_env(secret_environment_names)
    |> Kernel.++([
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", ""},
      {"SSH_ASKPASS", ""}
    ])
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
