defmodule SymphonyElixir.AgentRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Profile, Route, Router}
  alias SymphonyElixir.Config.Schema

  test "default profiles provide isolated responsibility and sandbox settings" do
    profiles = Profile.default_profiles("codex app-server", 7)

    assert %Profile{
             name: "planner",
             responsibility: "planning",
             runtime: "codex",
             command: "codex app-server",
             sandbox: "read-only",
             max_turns: 7
           } = profiles["planner"]

    assert profiles["builder"].responsibility == "implementation"
    assert profiles["builder"].sandbox == "workspace-write"
    assert profiles["reviewer"].responsibility == "review"
    assert profiles["reviewer"].sandbox == "read-only"
    assert profiles["fixer"].responsibility == "correction"
    assert profiles["fixer"].sandbox == "workspace-write"
    assert profiles["merge_gatekeeper"].runtime == "deferred"
  end

  test "configured profile overrides are normalized without changing other defaults" do
    assert {:ok, profiles} =
             Profile.resolve_profiles(
               %{
                 "builder" => %{
                   "model" => "reasoning-model",
                   "max_turns" => 3
                 }
               },
               "codex app-server",
               20
             )

    assert profiles["builder"].model == "reasoning-model"
    assert profiles["builder"].max_turns == 3
    assert profiles["builder"].command == "codex app-server"
    assert profiles["planner"].max_turns == 20
  end

  test "router normalizes lifecycle states and returns one auditable route" do
    profiles = Profile.default_profiles("codex app-server", 20)
    issue = %Issue{id: "issue-1", identifier: "SYM-1", state: "  In   Review "}

    assert {:ok, %Route{} = route} = Router.resolve(issue, profiles)
    assert route.issue_id == "issue-1"
    assert route.starting_state == "in review"
    assert route.profile_name == "reviewer"
    assert route.runtime_name == "codex"
    assert route.responsibility == "review"
    assert is_binary(route.fingerprint)
    assert route.fingerprint == Route.fingerprint(route)
  end

  test "router refuses unknown states and missing profiles" do
    profiles = Profile.default_profiles("codex app-server", 20)

    assert {:error, {:unknown_issue_state, "mystery"}} =
             Router.resolve(%Issue{id: "issue-1", state: "Mystery"}, profiles)

    assert {:error, {:missing_profile, "reviewer"}} =
             Router.resolve(%Issue{id: "issue-1", state: "In Review"}, Map.delete(profiles, "reviewer"))
  end

  test "profile validation rejects unknown runtimes and unsafe sandbox names" do
    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(
               %{"builder" => %{"runtime" => "cursor"}},
               "codex app-server",
               20
             )

    assert message =~ "runtime"

    assert {:error, {:invalid_profile, "reviewer", message}} =
             Profile.resolve_profiles(
               %{"reviewer" => %{"sandbox" => "danger-full-access"}},
               "codex app-server",
               20
             )

    assert message =~ "sandbox"
  end

  test "workflow schema materializes default profiles and validates overrides" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "profiles" => %{
                   "builder" => %{"model" => "configured-model"}
                 }
               }
             })

    assert settings.agent.profiles["planner"].responsibility == "planning"
    assert settings.agent.profiles["builder"].model == "configured-model"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"profiles" => %{"reviewer" => %{"runtime" => "cursor"}}}
             })

    assert message =~ "agent.profiles.reviewer"
    assert message =~ "runtime"
  end
end
