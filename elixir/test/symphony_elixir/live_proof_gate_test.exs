defmodule SymphonyElixir.LiveProofGateTest do
  use ExUnit.Case

  alias SymphonyElixir.LiveProofGate

  @consent "I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES"

  test "refuses live proof without explicit consent" do
    env = valid_env(:linear) |> Map.delete("SYMPHONY_LIVE_PROOF_CONSENT")

    assert {:error, %{code: :consent_required}} = LiveProofGate.check(:linear, env)

    reason = LiveProofGate.skip_reason(:linear, env)
    assert reason =~ "SYMPHONY_LIVE_PROOF_CONSENT"
    refute reason =~ "linear-secret"
  end

  test "refuses live proof when the run flag or named resource configuration is absent" do
    env = valid_env(:linear) |> Map.delete("SYMPHONY_RUN_LIVE_E2E")

    assert {:error, %{code: :run_flag_required}} = LiveProofGate.check(:linear, env)

    env = valid_env(:linear) |> Map.delete("SYMPHONY_LIVE_LINEAR_TEAM_KEY")

    assert {:error, %{code: :configuration_required, missing: ["SYMPHONY_LIVE_LINEAR_TEAM_KEY"]}} =
             LiveProofGate.check(:linear, env)
  end

  test "accepts a fully named disposable Linear proof configuration" do
    assert :ok = LiveProofGate.check(:linear, valid_env(:linear))
    assert LiveProofGate.skip_reason(:linear, valid_env(:linear)) == nil
  end

  test "uses provider-specific resource and credential requirements" do
    github_env = valid_env(:github)

    assert :ok = LiveProofGate.check(:github, github_env)

    missing_repo = Map.delete(github_env, "SYMPHONY_LIVE_GITHUB_REPO")

    assert {:error, %{code: :configuration_required, missing: ["SYMPHONY_LIVE_GITHUB_REPO"]}} =
             LiveProofGate.check(:github, missing_repo)
  end

  test "rejects unsupported providers without exposing input" do
    assert {:error, %{code: :unsupported_provider}} =
             LiveProofGate.check(:not_a_provider, %{"token" => "provider-secret"})

    reason = LiveProofGate.skip_reason(:not_a_provider, %{"token" => "provider-secret"})
    refute reason =~ "provider-secret"
  end

  defp valid_env(:linear) do
    %{
      "SYMPHONY_LIVE_PROOF_CONSENT" => @consent,
      "SYMPHONY_RUN_LIVE_E2E" => "1",
      "SYMPHONY_LIVE_LINEAR_TEAM_KEY" => "SYME2E",
      "LINEAR_API_KEY" => "linear-secret",
      "SYMPHONY_LIVE_CODEX_HOME" => "/tmp/symphony-live-codex"
    }
  end

  defp valid_env(:github) do
    %{
      "SYMPHONY_LIVE_PROOF_CONSENT" => @consent,
      "SYMPHONY_RUN_GITHUB_LIVE_E2E" => "1",
      "SYMPHONY_LIVE_GITHUB_REPO" => "owner/disposable-proof",
      "GITHUB_TOKEN" => "github-secret",
      "SYMPHONY_LIVE_CODEX_HOME" => "/tmp/symphony-live-codex"
    }
  end
end
