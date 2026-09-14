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

  test "profile validation rejects responsibility and capability mismatches" do
    assert {:error, {:invalid_profile, "reviewer", message}} =
             Profile.resolve_profiles(
               %{
                 "reviewer" => %{
                   "runtime" => "codex",
                   "command" => "codex app-server",
                   "sandbox" => "workspace-write"
                 }
               },
               "codex app-server",
               20
             )

    assert message =~ "review"
    assert message =~ "read-only"

    assert {:error, {:invalid_profile, "merge_gatekeeper", merge_message}} =
             Profile.resolve_profiles(
               %{
                 "merge_gatekeeper" => %{
                   "runtime" => "codex",
                   "command" => "codex app-server",
                   "sandbox" => "workspace-write"
                 }
               },
               "codex app-server",
               20
             )

    assert merge_message =~ "merge"
    assert merge_message =~ "deferred"

    assert {:error, {:invalid_profile, "planner", planner_message}} =
             Profile.resolve_profiles(
               %{
                 "planner" => %{
                   "responsibility" => "implementation",
                   "sandbox" => "workspace-write"
                 }
               },
               "codex app-server",
               20
             )

    assert planner_message =~ "planner"
    assert planner_message =~ "planning"
  end

  test "profile validation rejects normalized name collisions" do
    assert {:error, {:profile_name_collision, "reviewer", _names}} =
             Profile.resolve_profiles(
               %{
                 "Reviewer" => %{"sandbox" => "read-only"},
                 "reviewer" => %{"sandbox" => "read-only"}
               },
               "codex app-server",
               20
             )
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

  test "explicit state routes can select a custom profile only within its responsibility class" do
    assert {:ok, profiles} =
             Profile.resolve_profiles(
               %{
                 "custom builder" => %{
                   "responsibility" => "implementation",
                   "runtime" => "codex",
                   "command" => "custom-codex",
                   "sandbox" => "workspace-write"
                 }
               },
               "codex app-server",
               20
             )

    issue = %Issue{id: "custom-route", state: "Ready"}

    assert {:ok, %Route{profile_name: "custom_builder", responsibility: "implementation"}} =
             Router.resolve(issue, profiles, %{"ready" => "custom builder"})

    assert {:error, {:route_responsibility_mismatch, "ready", "review"}} =
             Router.resolve(issue, profiles, %{"ready" => "reviewer"})
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

    assert {:error, {:invalid_profile, "merge_gatekeeper", message}} =
             Profile.resolve_profiles(%{"merge_gatekeeper" => %{"command" => "gatekeeper"}}, "codex", 20)

    assert message =~ "deferred"

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

    invalid_struct = %{Profile.default_profiles("codex", 20)["reviewer"] | sandbox: "workspace-write"}

    assert {:error, {:invalid_profile, "reviewer", struct_message}} =
             Profile.resolve_profiles(%{"reviewer" => invalid_struct}, "codex", 20)

    assert struct_message =~ "read-only"

    builder_struct = Profile.default_profiles("codex", 20)["builder"]
    assert {:ok, resolved_struct_profiles} = Profile.resolve_profiles(%{"builder" => builder_struct}, "codex", 20)
    assert resolved_struct_profiles["builder"] == builder_struct

    assert {:error, {:invalid_profile_name, "   "}} =
             Profile.resolve_profiles(%{"   " => %{}}, "codex", 20)

    assert :ok = Profile.validate_effective_policy(Profile.default_profiles("codex", 20)["builder"])

    unsupported = %Profile{
      name: "custom",
      responsibility: "unsupported",
      runtime: "codex",
      command: "codex",
      model: nil,
      prompt: "custom",
      sandbox: "workspace-write",
      max_turns: 20,
      concurrency_class: nil
    }

    assert {:error, "unsupported responsibility \"unsupported\""} =
             Profile.validate_effective_policy(unsupported)

    assert {:error, {:invalid_profile, "custom_reviewer", custom_message}} =
             Profile.resolve_profiles(
               %{
                 "custom reviewer" => %{
                   "responsibility" => "review",
                   "runtime" => "codex",
                   "command" => "codex",
                   "sandbox" => "workspace-write"
                 }
               },
               "codex",
               20
             )

    assert custom_message =~ "read-only"
  end

  test "workflow schema materializes default profiles and validates overrides" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "routing" => "routed",
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
               "agent" => %{
                 "routing" => "routed",
                 "profiles" => %{"reviewer" => %{"runtime" => "cursor"}}
               }
             })

    assert message =~ "agent.profiles.reviewer"
    assert message =~ "runtime"
  end

  test "workflow schema keeps legacy workflows out of routed permissions" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "codex" => %{
                 "thread_sandbox" => "read-only",
                 "turn_sandbox_policy" => %{"type" => "readOnly"}
               }
             })

    assert settings.agent.routing == "legacy"
    assert settings.agent.profiles == nil
    assert settings.codex.thread_sandbox == "read-only"
    assert settings.codex.turn_sandbox_policy == %{"type" => "readOnly"}
  end

  test "workflow schema requires custom routed profiles to be explicitly selectable" do
    custom_profile = %{
      "responsibility" => "implementation",
      "runtime" => "codex",
      "command" => "custom-codex",
      "sandbox" => "workspace-write"
    }

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "routing" => "routed",
                 "profiles" => %{"custom builder" => custom_profile}
               }
             })

    assert message =~ "custom_builder"
    assert message =~ "agent.routes"

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "routing" => "routed",
                 "profiles" => %{"custom builder" => custom_profile},
                 "routes" => %{"ready" => "custom builder"}
               }
             })

    assert settings.agent.routes == %{"ready" => "custom builder"}

    assert {:error, {:invalid_workflow_config, legacy_message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{
                 "profiles" => %{"builder" => %{}}
               }
             })

    assert legacy_message =~ "agent.profiles requires explicit agent.routing"
  end

  test "router rejects malformed route maps and exposes state responsibility classes" do
    profiles = Profile.default_profiles("codex app-server", 20)
    issue = %Issue{id: "route-errors", state: "Ready"}

    assert {:error, {:invalid_route_state, "  "}} =
             Router.resolve(issue, profiles, %{"  " => "builder"})

    assert {:error, {:invalid_route_profile, "ready", 42}} =
             Router.resolve(issue, profiles, %{"ready" => 42})

    assert {:error, {:route_state_collision, "ready"}} =
             Router.validate_routes(%{"Ready" => "builder", "ready" => "builder"}, profiles)

    assert {:error, {:missing_profile, "missing"}} =
             Router.validate_routes(%{"ready" => "missing"}, profiles)

    assert {:error, {:route_responsibility_mismatch, "ready", "review"}} =
             Router.validate_routes(%{"ready" => "reviewer"}, profiles)

    invalid_policy = %{profiles["reviewer"] | sandbox: "workspace-write"}

    assert {:error, {:invalid_profile, "reviewer", policy_message}} =
             Router.resolve(%{issue | state: "In Review"}, Map.put(profiles, "reviewer", invalid_policy))

    assert policy_message =~ "read-only"

    assert Router.expected_responsibility("In Review") == "review"
    assert Router.expected_responsibility("unknown") == nil
    assert Router.validate_routes(:invalid, profiles) == {:error, :invalid_routes}

    assert Router.resolve(issue, profiles, :invalid) == {:error, :invalid_issue}
    assert Router.resolve(issue, :invalid, %{}) == {:error, :invalid_profiles}
  end

  test "schema formats routed profile and route validation errors" do
    base = %{"tracker" => %{"kind" => "memory"}, "agent" => %{"routing" => "routed"}}

    assert {:error, {:invalid_workflow_config, collision_message}} =
             Schema.parse(
               put_in(base, ["agent", "profiles"], %{
                 "Reviewer" => %{},
                 "reviewer" => %{}
               })
             )

    assert collision_message =~ "name collision"

    assert {:error, {:invalid_workflow_config, route_message}} =
             Schema.parse(put_in(base, ["agent", "routes"], %{"ready" => "missing"}))

    assert route_message =~ "references missing profile"

    assert {:error, {:invalid_workflow_config, bad_state_message}} =
             Schema.parse(put_in(base, ["agent", "routes"], %{" " => "builder"}))

    assert bad_state_message =~ "invalid state"

    assert {:error, {:invalid_workflow_config, mismatch_message}} =
             Schema.parse(put_in(base, ["agent", "routes"], %{"ready" => "reviewer"}))

    assert mismatch_message =~ "cannot use review responsibility"

    assert {:error, {:invalid_workflow_config, collision_message}} =
             Schema.parse(put_in(base, ["agent", "routes"], %{"Ready" => "builder", "ready" => "builder"}))

    assert collision_message =~ "duplicate normalized state"

    assert {:error, {:invalid_workflow_config, invalid_profile_message}} =
             Schema.parse(put_in(base, ["agent", "routes"], %{"ready" => 42}))

    assert invalid_profile_message =~ "references invalid profile"

    assert {:error, {:invalid_workflow_config, invalid_name_message}} =
             Schema.parse(put_in(base, ["agent", "profiles"], %{"   " => %{}}))

    assert invalid_name_message =~ "invalid name"
  end

  test "workflow reload retains the last valid routed policy after an invalid override" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_routing: "routed"
    )

    assert {:ok, valid_settings} = WorkflowStore.settings()
    assert valid_settings.agent.routing == "routed"

    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: memory
      agent:
        routing: routed
        profiles:
          reviewer:
            runtime: codex
            command: codex app-server
            sandbox: workspace-write
      ---
      valid workflow body
      """
    )

    assert {:error, {:invalid_workflow_config, _message}} = WorkflowStore.force_reload()
    assert {:ok, retained_settings} = WorkflowStore.settings()
    assert retained_settings == valid_settings
  end
end
