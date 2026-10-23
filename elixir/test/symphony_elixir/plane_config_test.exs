defmodule SymphonyElixir.PlaneConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  setup do
    previous =
      Map.new(["PLANE_API_KEY", "PLANE_API_KEY_FERDI", "PLANE_API_KEY_JC"], fn name ->
        {name, System.get_env(name)}
      end)

    System.put_env("PLANE_API_KEY", "test-generic-plane-key")
    System.put_env("PLANE_API_KEY_FERDI", "test-ferdi-plane-key")
    System.put_env("PLANE_API_KEY_JC", "test-jc-admin-plane-key")

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "selects Plane explicitly and resolves its host-side credential reference" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "provider" => %{
                   "workspace_slug" => "workspace-1",
                   "workspace_id" => "workspace-stable-1",
                   "project_id" => "project-1",
                   "api_key" => "$PLANE_API_KEY"
                 }
               }
             })

    assert settings.tracker.api_key == "test-generic-plane-key"
    assert "PLANE_API_KEY" in settings.tracker.secret_environment_names
    assert "PLANE_API_KEY_FERDI" in settings.tracker.secret_environment_names
    assert "PLANE_API_KEY_JC" in settings.tracker.secret_environment_names
    assert {:error, :plane_legacy_routing_unsupported} = Config.validate_settings(settings)
    assert {:ok, SymphonyElixir.Plane.Adapter} = Tracker.adapter_for_kind("plane")

    assert Tracker.identity(settings.tracker) == %{
             tracker_kind: "plane",
             provider_scope: %{workspace_slug: "workspace-1", workspace_id: "workspace-stable-1", project_id: "project-1"}
           }
  end

  test "accepts top-level Plane scope fields and keeps identity exact" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "workspace_slug" => "workspace-1",
                 "workspace_id" => "workspace-stable-1",
                 "project_id" => "project-1",
                 "api_key" => "$PLANE_API_KEY"
               }
             })

    assert {:error, :plane_legacy_routing_unsupported} = Config.validate_settings(settings)

    assert Tracker.identity(settings.tracker).provider_scope == %{
             workspace_slug: "workspace-1",
             workspace_id: "workspace-stable-1",
             project_id: "project-1"
           }
  end

  test "rejects a literal Plane credential from repository-controlled configuration" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "provider" => %{
                   "workspace_slug" => "workspace-1",
                   "workspace_id" => "workspace-stable-1",
                   "project_id" => "project-1",
                   "api_key" => "literal-token"
                 }
               }
             })

    assert {:error, :literal_plane_api_key_forbidden} = Config.validate_settings(settings)

    assert {:ok, top_level} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "workspace_slug" => "workspace-1",
                 "workspace_id" => "workspace-stable-1",
                 "project_id" => "project-1",
                 "api_key" => "literal-token"
               }
             })

    assert {:error, :literal_plane_api_key_forbidden} = Config.validate_settings(top_level)
  end

  test "routed Plane passes capability and configuration validation" do
    assert {:ok, settings} =
             Schema.parse(routed_plane_config())

    assert :ok = Config.validate_settings(settings)
    assert settings.tracker.api_key == "test-ferdi-plane-key"
    assert settings.tracker.runtime_principal.user_id == "920272c2-862e-4592-b13e-b0ba11c91b12"
    assert {:ok, declared} = Tracker.capabilities_for_kind("plane")
    assert :agent_read_tools in declared
    assert :agent_transition_tools in declared
  end

  test "routed Plane rejects generic and JC admin credential references" do
    for env_name <- ["PLANE_API_KEY", "PLANE_API_KEY_JC"] do
      assert {:ok, settings} = Schema.parse(routed_plane_config("$" <> env_name))
      assert {:error, :invalid_plane_api_key_reference} = Config.validate_settings(settings)
    end
  end

  test "routed Plane requires an explicit runtime principal policy" do
    config = Map.delete(routed_plane_config(), "provider_project_contract")
    assert {:ok, settings} = Schema.parse(config)
    assert {:error, :plane_runtime_principal_policy_required} = Config.validate_settings(settings)
  end

  test "missing Ferdi credential does not fall back to the generic or JC key" do
    previous = System.get_env("PLANE_API_KEY_FERDI")
    System.delete_env("PLANE_API_KEY_FERDI")

    on_exit(fn ->
      if previous,
        do: System.put_env("PLANE_API_KEY_FERDI", previous),
        else: System.delete_env("PLANE_API_KEY_FERDI")
    end)

    assert {:ok, settings} = Schema.parse(routed_plane_config())
    assert settings.tracker.api_key == nil
    assert {:error, :missing_plane_api_key} = Config.validate_settings(settings)
  end

  test "missing Plane credentials and repository endpoints fail before transport" do
    System.delete_env("PLANE_API_KEY")

    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "provider" => %{"workspace_slug" => "workspace-1", "project_id" => "project-1"}
               }
             })

    assert {:error, :missing_plane_api_key} = Config.validate_settings(settings)
    System.put_env("PLANE_API_KEY", "test-generic-plane-key")

    assert {:ok, unsafe} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "plane",
                 "endpoint" => "http://localhost:4000",
                 "provider" => %{
                   "workspace_slug" => "workspace-1",
                   "project_id" => "project-1",
                   "api_key" => "$PLANE_API_KEY"
                 }
               }
             })

    assert {:error, :plane_endpoint_must_be_host_controlled} = Config.validate_settings(unsafe)
  end

  defp routed_plane_config(api_key_ref \\ "$PLANE_API_KEY_FERDI") do
    %{
      "symphony" => %{"project_id" => "symphony-plane"},
      "tracker" => %{
        "kind" => "plane",
        "provider" => %{
          "workspace_slug" => "workspace-1",
          "workspace_id" => "workspace-stable-1",
          "project_id" => "project-1",
          "api_key" => api_key_ref
        }
      },
      "provider_project_contract" => %{
        "schema_version" => 1,
        "provider" => "plane",
        "workspace_id" => "workspace-stable-1",
        "project_id" => "project-1",
        "runtime_principal" => %{
          "api_key_env" => "PLANE_API_KEY_FERDI",
          "user_id" => "920272c2-862e-4592-b13e-b0ba11c91b12",
          "principal_kind" => "api_key",
          "project_relation" => "contributor",
          "required_permissions" => ["workitem:view", "workitem:edit"]
        },
        "state_mappings" =>
          Map.new(WorkflowLifecycle.states(), fn state ->
            {Atom.to_string(state), %{"state_id" => "state-#{state}"}}
          end)
      },
      "agent" => %{"routing" => "routed"},
      "source_control" => %{
        "kind" => "github",
        "repository" => "octo/symphony",
        "repository_id" => 1_368_436_395,
        "base_branch" => "main",
        "token_env" => "GITHUB_TOKEN",
        "required_checks" => [
          %{"context" => "make-all", "app_id" => 15_368, "subject" => "head"}
        ]
      }
    }
  end
end
