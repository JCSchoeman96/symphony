defmodule SymphonyElixir.CredentialBoundaryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CredentialBoundary

  test "deny list always includes canonical provider and scm delegation env names" do
    deny = CredentialBoundary.deny_environment_names([])

    for name <-
          ~w(PLANE_API_KEY GITHUB_TOKEN GH_TOKEN SSH_AUTH_SOCK GIT_ASKPASS GIT_SSH_COMMAND) do
      assert name in deny
    end
  end

  test "unset command includes canonical deny names even without configured secrets" do
    assert CredentialBoundary.unset_shell_command([]) =~ "unset "
    assert CredentialBoundary.unset_shell_command([]) =~ "PLANE_API_KEY"
  end

  test "port env marks every denied variable as unset" do
    env = CredentialBoundary.port_env(["EXTRA_SECRET"])
    assert {~c"PLANE_API_KEY", false} in env
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
