defmodule SymphonyElixir.ConfigIdentityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Tracker

  test "preserves an explicit stable project identity for routed settings" do
    assert {:ok, settings} =
             Schema.parse(%{
               "symphony" => %{"project_id" => "  symphony-main  "},
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"routing" => "routed"}
             })

    assert settings.symphony.project_id == "symphony-main"
    assert :ok = Config.validate_settings(settings)
  end

  test "routed settings require a stable project identity" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "memory"},
               "agent" => %{"routing" => "routed"}
             })

    assert {:error, :missing_symphony_project_id} = Config.validate_settings(settings)
  end

  test "blank and path-like project identities are rejected" do
    for project_id <- ["", "   ", "../symphony", "/srv/symphony", "project/id"] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 "symphony" => %{"project_id" => project_id},
                 "tracker" => %{"kind" => "memory"},
                 "agent" => %{"routing" => "routed"}
               })

      assert message =~ "symphony.project_id"
    end
  end

  test "legacy settings remain valid without a project identity" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{
                 "kind" => "github",
                 "provider" => %{"repo" => "octo/repo", "token" => "secret"},
                 "active_states" => ["open"],
                 "terminal_states" => ["closed"]
               },
               "agent" => %{"routing" => "legacy"}
             })

    assert is_nil(settings.symphony.project_id)
    assert :ok = Config.validate_settings(settings)
  end

  test "tracker identity keeps provider scope but excludes secrets and checkout paths" do
    tracker = %Schema.Tracker{
      kind: "linear",
      endpoint: "https://api.linear.app/graphql",
      api_key: "secret-token",
      project_slug: "symphony-main",
      provider: %{
        "project_slug" => "symphony-main",
        "api_key" => "secret-token",
        "token" => "secret-token",
        "repo" => "octo/repo",
        "workspace_root" => "/srv/symphony"
      }
    }

    assert Tracker.identity(tracker) == %{
             tracker_kind: "linear",
             provider_scope: %{project_slug: "symphony-main"}
           }
  end

  test "identity helpers fail closed for malformed direct inputs" do
    assert {:error, :missing_symphony_project_id} = Schema.validate_project_identity(%{})
    refute Schema.valid_project_id?(123)
  end
end
