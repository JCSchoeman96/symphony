defmodule SymphonyElixir.RuntimeAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentRuntime.{Authority, Profile, Route}
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

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

  test "validate_profile accepts the effective policies for the standard profiles" do
    profiles = Profile.default_profiles("codex app-server", 20)

    for profile <- Map.values(profiles) do
      assert Authority.validate_profile(profile) == :ok
    end
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

  defp assert_denied({:error, %{code: code, reason: reason}}, code, reason), do: :ok

  defp assert_denied(result, expected_code, expected_reason) do
    flunk(
      "expected {:error, %{code: #{inspect(expected_code)}, reason: #{inspect(expected_reason)}}}, " <>
        "got #{inspect(result)}"
    )
  end
end
