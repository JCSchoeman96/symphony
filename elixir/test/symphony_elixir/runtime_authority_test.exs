defmodule SymphonyElixir.RuntimeAuthorityCapabilityProbe do
  def capabilities do
    [
      :current_issue_refresh,
      :dependency_graph,
      :dependency_completeness,
      :transition_verification,
      :agent_read_tools,
      :agent_transition_tools
    ]
  end

  def fetch_issues_by_ids(_issue_ids) do
    send(self(), :provider_request)
    {:ok, []}
  end

  def fetch_dependency_graph do
    send(self(), :provider_request)
    {:ok, []}
  end

  def agent_tool_specs, do: []
  def execute_agent_tool(_tool, _arguments, _opts), do: %{}
end

defmodule SymphonyElixir.RuntimeAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Authority, Profile, Route}
  alias SymphonyElixir.AgentRuntime.Router
  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.{Capabilities, TransitionPolicy}
  alias SymphonyElixir.WorkControl.{WorkflowLifecycle, WorkItem}

  @now ~U[2026-09-19 00:00:00Z]

  @states WorkflowLifecycle.states()
  @responsibilities ["planning", "implementation", "review", "correction", "merge"]
  @grants %{
    "planning" => [{:planning, :ready}],
    "implementation" => [{:ready, :in_progress}, {:in_progress, :in_review}],
    "review" => [{:in_review, :changes_requested}, {:in_review, :ready_to_merge}],
    "correction" => [{:changes_requested, :in_review}],
    "merge" => []
  }

  @profile_names %{
    "planning" => "planner",
    "implementation" => "builder",
    "review" => "reviewer",
    "correction" => "fixer",
    "merge" => "merge_gatekeeper"
  }

  @starting_states %{
    "planning" => "Planning",
    "implementation" => "Ready",
    "review" => "In Review",
    "correction" => "Changes Requested",
    "merge" => "Ready to Merge"
  }

  @routed_starting_states Map.take(@starting_states, ["planning", "implementation", "review", "correction"])

  test "planner authorizes planning to ready" do
    assert :ok == authorize("planner", :planning, :ready)
  end

  test "builder authorizes ready to in progress" do
    assert :ok == authorize("builder", :ready, :in_progress)
  end

  test "builder authorizes in progress to in review" do
    assert :ok == authorize("builder", :in_progress, :in_review)
  end

  test "reviewer authorizes in review to changes requested" do
    assert :ok == authorize("reviewer", :in_review, :changes_requested)
  end

  test "reviewer authorizes in review to ready to merge" do
    assert :ok == authorize("reviewer", :in_review, :ready_to_merge)
  end

  test "fixer authorizes changes requested to in review" do
    assert :ok == authorize("fixer", :changes_requested, :in_review)
  end

  test "planner denies a builder command" do
    assert_denied(authorize("planner", :ready, :in_progress), :not_permitted, :command_not_permitted)
  end

  test "builder denies a planner command" do
    assert_denied(authorize("builder", :planning, :ready), :not_permitted, :command_not_permitted)
  end

  test "reviewer denies a fixer command" do
    assert_denied(
      authorize("reviewer", :changes_requested, :in_review),
      :not_permitted,
      :command_not_permitted
    )
  end

  test "fixer denies a reviewer command" do
    assert_denied(
      authorize("fixer", :in_review, :ready_to_merge),
      :not_permitted,
      :command_not_permitted
    )
  end

  test "merge gatekeeper denies every lifecycle command" do
    assert_denied(authorize("merge_gatekeeper", :ready_to_merge, :merging), :not_permitted, :command_not_permitted)
  end

  test "the exact static grants are the only grants across every lifecycle pair" do
    for responsibility <- @responsibilities,
        source <- @states,
        target <- @states do
      profile_name = Map.fetch!(@profile_names, responsibility)
      allowed? = {source, target} in Map.fetch!(@grants, responsibility)
      result = authorize(profile_name, source, target)

      if allowed? do
        assert result == :ok,
               "expected #{responsibility} to authorize #{inspect({source, target})}, got #{inspect(result)}"
      else
        assert_denied(result, :not_permitted, :command_not_permitted)
      end
    end
  end

  test "canonical cancellation transitions remain denied" do
    for responsibility <- @responsibilities,
        source <- Enum.reject(@states, &WorkflowLifecycle.terminal?/1) do
      result = authorize(Map.fetch!(@profile_names, responsibility), source, :canceled)
      assert_denied(result, :not_permitted, :command_not_permitted)
    end
  end

  test "unknown, same-state, and impossible commands deny without crashing" do
    route = route_for(default_profile("planner"))

    assert_denied(
      Authority.authorize_lifecycle_command(route, :unknown_state, :ready),
      :invalid_command,
      :unknown_state
    )

    assert_denied(
      Authority.authorize_lifecycle_command(route, :planning, :unknown_state),
      :invalid_command,
      :unknown_state
    )

    assert_denied(
      Authority.authorize_lifecycle_command(route, :planning, :planning),
      :not_permitted,
      :command_not_permitted
    )

    assert_denied(
      Authority.authorize_lifecycle_command(route, :ready, :in_review),
      :not_permitted,
      :command_not_permitted
    )
  end

  test "malformed and noncanonical command values deny without crashing" do
    route = route_for(default_profile("planner"))

    for {source, target, reason} <- [
          {"Planning", :ready, :noncanonical_state},
          {:planning, "Ready", :noncanonical_state},
          {nil, :ready, :malformed_command},
          {:planning, nil, :malformed_command},
          {%{}, :ready, :malformed_command},
          {:planning, %{}, :malformed_command}
        ] do
      assert_denied(
        Authority.authorize_lifecycle_command(route, source, target),
        :invalid_command,
        reason
      )
    end
  end

  test "validate_profile denies malformed profile subjects" do
    assert_denied(Authority.validate_profile(:planner), :invalid_profile, :not_a_profile)
    assert_denied(Authority.validate_profile(%{}), :invalid_profile, :not_a_profile)

    malformed = %Profile{
      name: "planner",
      responsibility: "",
      runtime: "codex",
      command: "codex app-server",
      model: nil,
      prompt: "planner",
      sandbox: "read-only",
      max_turns: 20,
      concurrency_class: nil
    }

    assert_denied(Authority.validate_profile(malformed), :invalid_profile, :unsupported_responsibility)
  end

  test "forged incomplete profile structs deny without raising" do
    forged_profile = %{__struct__: Profile}

    assert_denied(
      Authority.validate_profile(forged_profile),
      :invalid_profile,
      :malformed_profile
    )
  end

  test "validate_profile accepts the effective policies for the standard profiles" do
    profiles = Profile.default_profiles("codex app-server", 20)

    for profile <- Map.values(profiles) do
      assert Authority.validate_profile(profile) == :ok
    end
  end

  test "canonical routing embeds authority-valid profiles with only static grants" do
    profiles = Profile.default_profiles("codex app-server", 20)

    for {responsibility, starting_state} <- @routed_starting_states do
      assert {:ok, %Route{profile: profile} = route} =
               Router.resolve(trusted_work_item(starting_state), profiles)

      assert Authority.validate_profile(profile) == :ok

      for source <- @states, target <- @states do
        result = Authority.authorize_lifecycle_command(route, source, target)

        if {source, target} in Map.fetch!(@grants, responsibility) do
          assert result == :ok,
                 "expected #{responsibility} to authorize #{inspect({source, target})}, got #{inspect(result)}"
        else
          assert_denied(result, :not_permitted, :command_not_permitted)
        end
      end
    end
  end

  test "canonical routing validates the selected profile authority shape" do
    profiles = Profile.default_profiles("codex app-server", 20)
    malformed_builder = %{profiles["builder"] | name: ""}

    assert {:error, %{code: :invalid_profile, reason: :malformed_profile}} =
             Router.resolve(trusted_work_item("Ready"), Map.put(profiles, "builder", malformed_builder))
  end

  test "canonical routing denies forged incomplete profile subjects without raising" do
    profiles = Profile.default_profiles("codex app-server", 20)
    forged_builder = %{__struct__: Profile}
    work_item = trusted_work_item("Ready")
    profiles = Map.put(profiles, "builder", forged_builder)

    assert {:error, %{code: :invalid_profile, reason: :malformed_profile}} =
             Router.resolve(work_item, profiles)

    assert {:error, %{code: :invalid_profile, reason: :malformed_profile}} =
             Router.resolve(work_item, profiles, %{})
  end

  test "custom routed profiles keep their responsibility command set" do
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

    custom_builder = Map.put(profiles["custom_builder"], :allowed_commands, [{:planning, :ready}])
    profiles = Map.put(profiles, "custom_builder", custom_builder)

    assert {:ok, %Route{profile: ^custom_builder, responsibility: "implementation"} = route} =
             Router.resolve(trusted_work_item("Ready"), profiles, %{"ready" => "custom builder"})

    assert Authority.validate_profile(custom_builder) == :ok
    assert Authority.authorize_lifecycle_command(route, :ready, :in_progress) == :ok

    assert_denied(
      Authority.authorize_lifecycle_command(route, :planning, :ready),
      :not_permitted,
      :command_not_permitted
    )

    custom_reviewer = %{profiles["reviewer"] | name: "custom_reviewer", prompt: "custom-reviewer"}
    profiles = Map.put(profiles, "custom_reviewer", custom_reviewer)

    assert {:error, {:route_responsibility_mismatch, "ready", "implementation"}} =
             Router.resolve(trusted_work_item("Ready"), profiles, %{"ready" => "custom reviewer"})
  end

  test "legacy resolver remains compatible while legacy routes stay outside authority" do
    profiles = Profile.default_profiles("codex app-server", 20)
    issue = %Issue{id: "legacy-authority", state: "Planning"}

    assert {:ok, %Route{profile: %Profile{}, starting_state: "planning"}} =
             Router.resolve_legacy(issue, profiles)

    legacy_route = Route.legacy(issue)

    assert_denied(
      Authority.authorize_lifecycle_command(legacy_route, :planning, :ready),
      :invalid_subject,
      :missing_profile
    )
  end

  test "provider capabilities do not grant runtime lifecycle authority" do
    capabilities = Adapter.capabilities()

    assert :controlled_transition in capabilities
    refute :agent_read_tools in capabilities
    refute :agent_transition_tools in capabilities
    refute :conditional_transition in capabilities

    profiles = Profile.default_profiles("codex app-server", 20)
    builder_route = routed_route("Ready", profiles)
    reviewer_route = routed_route("In Review", profiles)

    assert Authority.authorize_lifecycle_command(builder_route, :ready, :in_progress) == :ok

    assert_denied(
      Authority.authorize_lifecycle_command(reviewer_route, :ready, :in_progress),
      :not_permitted,
      :command_not_permitted
    )
  end

  test "a provider declaration reports a missing controlled transition" do
    assert {:ok, declared} = Capabilities.validate_adapter(SymphonyElixir.RuntimeAuthorityCapabilityProbe)
    assert Capabilities.missing(declared) == [:controlled_transition]
  end

  test "runtime authority checks do not invoke provider callbacks" do
    profiles = Profile.default_profiles("codex app-server", 20)
    route = routed_route("Ready", profiles)

    assert {:ok, []} = SymphonyElixir.RuntimeAuthorityCapabilityProbe.fetch_dependency_graph()
    assert_received :provider_request

    assert Authority.authorize_lifecycle_command(route, :ready, :in_progress) == :ok
    refute_received :provider_request
  end

  test "runtime authority and dependency transition policy remain separate" do
    profiles = Profile.default_profiles("codex app-server", 20)
    builder_route = routed_route("Ready", profiles)
    reviewer_route = routed_route("In Review", profiles)

    assert Authority.authorize_lifecycle_command(builder_route, :in_progress, :in_review) == :ok

    assert :ok =
             TransitionPolicy.authorize(%{
               responsibility: builder_route.responsibility,
               current_state: :in_progress,
               target_state: :in_review,
               dependency_decision: allowed_dependency()
             })

    assert {:error, %{code: :dependency_transition_denied}} =
             TransitionPolicy.authorize(%{
               responsibility: builder_route.responsibility,
               current_state: :in_progress,
               target_state: :in_review,
               dependency_decision: %{
                 allowed?: false,
                 dependency_status: :unavailable,
                 dependency_completeness: {:unavailable, :provider_error}
               }
             })

    assert_denied(
      Authority.authorize_lifecycle_command(reviewer_route, :in_progress, :in_review),
      :not_permitted,
      :command_not_permitted
    )

    assert {:error, %{code: :unauthorized_transition}} =
             TransitionPolicy.authorize(%{
               responsibility: reviewer_route.responsibility,
               current_state: :in_progress,
               target_state: :in_review,
               dependency_decision: allowed_dependency()
             })
  end

  test "raw, arbitrary, malformed, and legacy routes deny by default" do
    profile = default_profile("planner")
    route = route_for(profile)

    assert_denied(
      Authority.authorize_lifecycle_command("planner", :planning, :ready),
      :invalid_subject,
      :not_a_route
    )

    assert_denied(
      Authority.authorize_lifecycle_command(%{profile: profile}, :planning, :ready),
      :invalid_subject,
      :not_a_route
    )

    assert_denied(
      Authority.authorize_lifecycle_command(%Route{profile: profile}, :planning, :ready),
      :invalid_subject,
      :malformed_route
    )

    legacy = Route.legacy(%Issue{id: "legacy", state: "Planning"})

    assert_denied(
      Authority.authorize_lifecycle_command(legacy, :planning, :ready),
      :invalid_subject,
      :missing_profile
    )

    assert Authority.authorize_lifecycle_command(route, :planning, :ready) == :ok
  end

  test "forged incomplete route structs deny without raising" do
    forged_route = %{__struct__: Route, profile: default_profile("planner")}

    assert_denied(
      Authority.authorize_lifecycle_command(forged_route, :planning, :ready),
      :invalid_subject,
      :malformed_route
    )
  end

  test "route and profile metadata must match and the fingerprint must be current" do
    profile = default_profile("planner")
    route = route_for(profile)

    mismatched_metadata = %{
      route
      | profile_name: "different-profile",
        fingerprint: Route.fingerprint(%{route | profile_name: "different-profile"})
    }

    assert_denied(
      Authority.authorize_lifecycle_command(mismatched_metadata, :planning, :ready),
      :invalid_subject,
      :route_profile_mismatch
    )

    assert_denied(
      Authority.authorize_lifecycle_command(%{route | fingerprint: "sha256:stale"}, :planning, :ready),
      :invalid_subject,
      :route_fingerprint_mismatch
    )
  end

  test "unsupported and blank responsibilities cannot authorize commands" do
    profile = default_profile("planner")

    for responsibility <- ["", "architect", "PLANNING", "plan"] do
      invalid_profile = %{profile | responsibility: responsibility}
      assert_denied(Authority.validate_profile(invalid_profile), :invalid_profile, :unsupported_responsibility)
    end
  end

  test "custom canonical profiles cannot expand their static command set" do
    custom_profile = %{default_profile("planner") | name: "custom-planner", prompt: "custom-planner"}
    custom_profile_with_permissions = Map.put(custom_profile, :allowed_commands, [:ready_to_in_progress])
    route = route_for(custom_profile_with_permissions)

    assert Authority.validate_profile(custom_profile_with_permissions) == :ok
    assert Authority.authorize_lifecycle_command(route, :planning, :ready) == :ok

    assert_denied(
      Authority.authorize_lifecycle_command(route, :ready, :in_progress),
      :not_permitted,
      :command_not_permitted
    )
  end

  test "standard profile capability properties remain intact" do
    profiles = Profile.default_profiles("codex app-server", 20)

    assert profiles["planner"].sandbox == "read-only"
    assert profiles["reviewer"].sandbox == "read-only"
    assert profiles["builder"].sandbox == "workspace-write"
    assert profiles["fixer"].sandbox == "workspace-write"
    assert profiles["merge_gatekeeper"].runtime == "deferred"
    assert profiles["merge_gatekeeper"].command == nil
  end

  defp authorize(profile_name, source, target) do
    profile_name
    |> default_profile()
    |> route_for()
    |> Authority.authorize_lifecycle_command(source, target)
  end

  defp default_profile(name) do
    Profile.default_profiles("codex app-server", 20)
    |> Map.fetch!(name)
  end

  defp route_for(%Profile{} = profile) do
    issue = %Issue{
      id: "authority-#{profile.name}",
      state: Map.fetch!(@starting_states, profile.responsibility),
      dispatchable: true
    }

    Route.new(issue, profile)
  end

  defp routed_route(state, profiles, routes \\ nil) do
    assert {:ok, route} = Router.resolve(trusted_work_item(state), profiles, routes)
    route
  end

  defp trusted_work_item(state) do
    issue = %Issue{id: "routed-#{state}", state: state, dispatchable: true}

    {:ok, work_item} =
      WorkItem.from_issue(issue, %{
        provider: :memory,
        observed_at: @now,
        prior_validated_lifecycle_state: state
      })

    work_item
  end

  defp allowed_dependency do
    %{
      allowed?: true,
      dependency_status: :none,
      dependency_completeness: :complete
    }
  end

  defp assert_denied({:error, %{code: code, reason: reason}}, code, reason), do: :ok

  defp assert_denied(result, expected_code, expected_reason) do
    flunk(
      "expected {:error, %{code: #{inspect(expected_code)}, reason: #{inspect(expected_reason)}}}, " <>
        "got #{inspect(result)}"
    )
  end
end
