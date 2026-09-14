defmodule SymphonyElixir.LiveProofGate do
  @moduledoc """
  Pure consent and configuration gate for opt-in provider live proofs.

  The gate checks only environment-variable presence and returns variable names,
  never their values. Live tests must remain skipped unless the operator names
  the disposable provider resource, supplies provider credentials, names an
  explicit Codex home, enables the provider test, and provides the exact
  consent token.
  """

  @consent_env "SYMPHONY_LIVE_PROOF_CONSENT"
  @consent_value "I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES"

  @requirements %{
    linear: %{
      run_env: "SYMPHONY_RUN_LIVE_E2E",
      required_envs: ["LINEAR_API_KEY", "SYMPHONY_LIVE_LINEAR_TEAM_KEY", "SYMPHONY_LIVE_CODEX_HOME"]
    },
    github: %{
      run_env: "SYMPHONY_RUN_GITHUB_LIVE_E2E",
      required_envs: ["GITHUB_TOKEN", "SYMPHONY_LIVE_GITHUB_REPO", "SYMPHONY_LIVE_CODEX_HOME"]
    },
    asana: %{
      run_env: "SYMPHONY_RUN_ASANA_LIVE_E2E",
      required_envs: ["ASANA_PAT", "SYMPHONY_LIVE_ASANA_WORKSPACE_GID", "SYMPHONY_LIVE_CODEX_HOME"]
    },
    gitlab: %{
      run_env: "SYMPHONY_RUN_GITLAB_LIVE_E2E",
      required_envs: ["GITLAB_PAT", "SYMPHONY_LIVE_GITLAB_PROJECT_ID", "SYMPHONY_LIVE_CODEX_HOME"]
    },
    jira: %{
      run_env: "SYMPHONY_RUN_JIRA_LIVE_E2E",
      required_envs: [
        "JIRA_API_TOKEN",
        "JIRA_BASE_URL",
        "JIRA_EMAIL",
        "SYMPHONY_LIVE_JIRA_PROJECT_KEY",
        "SYMPHONY_LIVE_CODEX_HOME"
      ]
    }
  }

  @type gate_error :: %{
          code: :configuration_required | :consent_required | :run_flag_required | :unsupported_provider,
          missing: [String.t()] | nil,
          provider: atom() | nil
        }

  @spec check(atom(), map()) :: :ok | {:error, gate_error()}
  def check(provider, env) when is_atom(provider) and is_map(env) do
    case Map.get(@requirements, provider) do
      nil ->
        {:error, %{code: :unsupported_provider, missing: nil, provider: provider}}

      %{run_env: run_env, required_envs: required_envs} ->
        missing = Enum.reject(required_envs, &present?(Map.get(env, &1)))

        cond do
          env_value(env, @consent_env) != @consent_value ->
            {:error, %{code: :consent_required, missing: [@consent_env], provider: provider}}

          env_value(env, run_env) != "1" ->
            {:error, %{code: :run_flag_required, missing: [run_env], provider: provider}}

          missing != [] ->
            {:error, %{code: :configuration_required, missing: missing, provider: provider}}

          true ->
            :ok
        end
    end
  end

  def check(provider, _env),
    do: {:error, %{code: :unsupported_provider, missing: nil, provider: provider}}

  @spec skip_reason(atom(), map()) :: String.t() | nil
  def skip_reason(provider, env) do
    case check(provider, env) do
      :ok ->
        nil

      {:error, %{code: :consent_required}} ->
        "live proof skipped: set #{@consent_env}=#{@consent_value} only for named disposable resources"

      {:error, %{code: :run_flag_required, missing: [run_env]}} ->
        "live proof skipped: set #{run_env}=1 after the consent gate is configured"

      {:error, %{code: :configuration_required, missing: missing}} ->
        "live proof skipped: configure named disposable resources and credentials: #{Enum.join(missing, ", ")}"

      {:error, %{code: :unsupported_provider}} ->
        "live proof skipped: unsupported provider"
    end
  end

  defp env_value(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
