defmodule SymphonyElixir.PlaneConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker

  setup do
    previous = System.get_env("PLANE_API_KEY")
    System.put_env("PLANE_API_KEY", "host-secret")

    on_exit(fn ->
      if previous, do: System.put_env("PLANE_API_KEY", previous), else: System.delete_env("PLANE_API_KEY")
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

    assert settings.tracker.api_key == "host-secret"
    assert "PLANE_API_KEY" in settings.tracker.secret_environment_names
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

  test "routed Plane remains fail-closed while later capabilities are absent" do
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
               },
               "agent" => %{"routing" => "routed"}
             })

    assert {:error, {:routed_provider_capabilities_missing, "plane", missing}} =
             Config.validate_settings(settings)

    assert missing == [
             :dependency_graph,
             :dependency_completeness,
             :controlled_transition,
             :transition_verification,
             :agent_read_tools,
             :agent_transition_tools
           ]
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
    System.put_env("PLANE_API_KEY", "host-secret")

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
end
