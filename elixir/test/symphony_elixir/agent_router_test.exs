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

  test "router preserves common provider active-state aliases as builder work" do
    profiles = Profile.default_profiles("codex app-server", 20)

    for state <- ["Open", "Opened", "Pending", "Started", "In Development"] do
      assert {:ok, %Route{profile_name: "builder", responsibility: "implementation"}} =
               Router.resolve(%Issue{id: "issue-#{state}", state: state}, profiles)
    end
  end

  test "router refuses unknown states and missing profiles" do
    profiles = Profile.default_profiles("codex app-server", 20)

    assert {:error, {:unknown_issue_state, "mystery"}} =
             Router.resolve(%Issue{id: "issue-1", state: "Mystery"}, profiles)

    assert {:error, {:missing_profile, "reviewer"}} =
             Router.resolve(%Issue{id: "issue-1", state: "In Review"}, Map.delete(profiles, "reviewer"))

    assert {:error, {:invalid_profile, "planner"}} =
             Router.resolve(%Issue{id: "issue-1", state: "Planning"}, %{"planner" => :invalid})

    assert {:error, :invalid_profiles} =
             Router.resolve(%Issue{id: "issue-1", state: "Planning"}, nil)

    assert {:error, :invalid_issue} =
             Router.resolve(%Issue{id: nil, state: "Planning"}, profiles)
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

  test "custom profiles and profile predicates cover normalized runtime settings" do
    assert {:ok, profiles} =
             Profile.resolve_profiles(
               %{
                 "custom role" => %{
                   "responsibility" => "Implementation",
                   "runtime" => "Codex",
                   "command" => "custom-codex",
                   "model" => "custom-model",
                   "prompt" => "custom-prompt",
                   "sandbox" => "Workspace-Write",
                   "max_turns" => 2,
                   "concurrency_class" => "isolated"
                 }
               },
               "codex app-server",
               20
             )

    assert %Profile{
             name: "custom_role",
             responsibility: "implementation",
             runtime: "codex",
             command: "custom-codex",
             model: "custom-model",
             prompt: "custom-prompt",
             sandbox: "workspace-write",
             max_turns: 2,
             concurrency_class: "isolated"
           } = profiles["custom_role"]

    assert Profile.responsibility?("Planning")
    refute Profile.responsibility?(:planning)
    assert Profile.runtime?("Deferred")
    refute Profile.runtime?("cursor")
    assert Profile.sandbox?("Read-Only")
    refute Profile.sandbox?(nil)
    assert Profile.normalize_name("  Custom  Name ") == "custom_name"
  end

  test "profile normalization rejects malformed values and supports deferred commands" do
    assert {:error, {:invalid_profile, "builder", "must be a map"}} =
             Profile.resolve_profiles(%{"builder" => "invalid"}, "codex", 20)

    wrong_name = %{Profile.default_profiles("codex", 20)["builder"] | name: "other"}

    assert {:error, {:invalid_profile, "builder", "name must match profile key"}} =
             Profile.resolve_profiles(%{"builder" => wrong_name}, "codex", 20)

    assert {:error, {:invalid_profile, "custom", "must be a map"}} =
             Profile.resolve_profiles(%{"custom" => :invalid}, "codex", 20)

    assert {:ok, profiles} =
             Profile.resolve_profiles(%{"merge_gatekeeper" => %{"command" => nil}}, "codex", 20)

    assert profiles["merge_gatekeeper"].command == nil

    assert {:ok, profiles} =
             Profile.resolve_profiles(%{"merge_gatekeeper" => %{"command" => "gatekeeper"}}, "codex", 20)

    assert profiles["merge_gatekeeper"].command == "gatekeeper"

    assert {:error, {:invalid_profile, "merge_gatekeeper", message}} =
             Profile.resolve_profiles(%{"merge_gatekeeper" => %{"command" => " "}}, "codex", 20)

    assert message =~ "executable profile"

    assert {:error, {:invalid_profile, "merge_gatekeeper", message}} =
             Profile.resolve_profiles(%{"merge_gatekeeper" => %{"command" => 123}}, "codex", 20)

    assert message =~ "executable profile"

    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(%{"builder" => %{"command" => " "}}, "codex", 20)

    assert message =~ "non-empty string"

    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(%{"builder" => %{"command" => 123}}, "codex", 20)

    assert message =~ "non-empty string"

    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(%{"builder" => %{"model" => 123}}, "codex", 20)

    assert message =~ "model must be a string"

    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(%{"builder" => %{"model" => " "}}, "codex", 20)

    assert message =~ "model must not be blank"

    assert {:error, {:invalid_profile, "builder", message}} =
             Profile.resolve_profiles(%{"builder" => %{"max_turns" => 0}}, "codex", 20)

    assert message =~ "max_turns must be a positive integer"
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
