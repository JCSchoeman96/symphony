defmodule SymphonyElixir.PlaneAdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.Tracker.Issue

  @settings %{
    kind: "plane",
    api_key: "secret",
    endpoint: "https://api.plane.so",
    provider: %{"workspace_slug" => "workspace-1", "workspace_id" => "workspace-stable-1", "project_id" => "project-1", "api_key" => "$PLANE_API_KEY"},
    secret_environment_names: ["PLANE_API_KEY"]
  }

  test "declares only the current refresh capability" do
    assert Adapter.capabilities() == [:current_issue_refresh]
    assert Adapter.secret_environment_names(@settings) == ["PLANE_API_KEY"]
  end

  test "fresh ID refresh returns factual Plane fields and performs a fresh request" do
    parent = self()

    request_fun = fn request ->
      send(parent, {:request, request})

      {:ok,
       %{
         status: 200,
         body: %{
           "id" => "item-1",
           "name" => "Work",
           "state" => %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"},
           "project_id" => "project-1",
           "workspace_slug" => "workspace-1",
           "updated_at" => "2026-09-17T08:09:10Z"
         }
       }}
    end

    assert {:ok, [%Issue{} = first]} = Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, request_fun)
    assert {:ok, [%Issue{} = second]} = Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, request_fun)
    assert first.id == second.id
    assert first.workspace_id == "workspace-stable-1"
    assert first.project_id == "project-1"
    assert first.provider_state_id == "state-ready"
    assert first.provider_state_group == :unstarted
    assert first.updated_at == ~U[2026-09-17 08:09:10Z]
    assert_receive {:request, _}
    assert_receive {:request, _}
  end

  test "lists the complete project and locally filters descriptive provider states" do
    request_fun = fn request ->
      case request.path do
        "/api/v1/workspaces/workspace-1/projects/project-1/work-items/" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [
                 %{
                   "id" => "one",
                   "name" => "One",
                   "state" => %{"id" => "s1", "name" => "Ready", "group" => "unstarted"},
                   "updated_at" => "2026-09-17T08:09:10Z"
                 },
                 %{
                   "id" => "two",
                   "name" => "Two",
                   "state" => %{"id" => "s2", "name" => "In Progress", "group" => "started"},
                   "updated_at" => "2026-09-17T08:09:11Z"
                 }
               ],
               "next_page_results" => false,
               "next_cursor" => nil
             }
           }}

        "/api/v1/workspaces/workspace-1/projects/project-1/states/" ->
          {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => false, "next_cursor" => nil}}}
      end
    end

    assert {:ok, [%Issue{id: "one", state: "Ready"}]} =
             Adapter.fetch_issues_by_states_for_test([" ready "], @settings, request_fun)

    assert {:ok, []} = Adapter.fetch_issues_by_states_for_test([nil], @settings, request_fun)
  end

  test "does not silently accept a Plane failure as a Linear read" do
    assert {:error, :unauthorized} =
             Adapter.fetch_issues_by_ids_for_test(["item-1"], @settings, fn _request ->
               {:ok, %{status: 401, body: %{}}}
             end)
  end

  test "builds a fresh complete project snapshot from scoped project and state reads" do
    request_fun = fn request ->
      case request.path do
        "/api/v1/workspaces/workspace-1/projects/project-1/" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => "project-1",
               "name" => "Project",
               "identifier" => "PROJ",
               "description" => "Description",
               "workspace_slug" => "workspace-1"
             }
           }}

        "/api/v1/workspaces/workspace-1/projects/project-1/states/" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "results" => [
                 %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"}
               ],
               "next_page_results" => false,
               "next_cursor" => nil
             }
           }}
      end
    end

    assert {:ok, snapshot} = Adapter.fetch_project_snapshot_for_test(@settings, request_fun)
    assert snapshot.provider == :plane
    assert snapshot.workspace_id == "workspace-stable-1"
    assert snapshot.project_id == "project-1"
    assert snapshot.workspace_name == nil
    assert snapshot.project_identifier == "PROJ"
    assert snapshot.project_description == "Description"
    assert snapshot.completeness == :complete
    assert hd(snapshot.states) == %{id: "state-ready", name: "Ready", group: :unstarted}
    assert snapshot.capability_statuses.current_issue_refresh == :supported
    assert snapshot.capability_statuses.dependency_graph == :unsupported
  end

  test "rejects a project response with a contradictory stable workspace or project ID" do
    for project <- [
          %{"id" => "project-1", "workspace_id" => "other-stable-workspace"},
          %{"id" => "other-project", "name" => "Project"}
        ] do
      assert {:error, :wrong_project} =
               Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
                 case request.path do
                   "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                     {:ok, %{status: 200, body: project}}

                   _states_path ->
                     {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => false}}}
                 end
               end)
    end
  end

  test "validates Plane scope, host credential references and operator endpoint boundaries" do
    assert {:error, :invalid_plane_configuration} = Adapter.validate_config(:invalid)
    assert {:error, :missing_plane_workspace_slug} = Adapter.validate_config(%{kind: "plane", api_key: "secret"})

    assert {:error, :missing_plane_project_id} =
             Adapter.validate_config(%{kind: "plane", api_key: "secret", workspace_slug: "workspace-1"})

    assert {:error, :missing_plane_workspace_id} =
             Adapter.validate_config(%{kind: "plane", api_key: "secret", workspace_slug: "workspace-1", project_id: "project-1"})

    assert {:error, :missing_plane_api_key} =
             Adapter.validate_config(%{kind: "plane", workspace_slug: "workspace-1", project_id: "project-1"})

    assert {:error, :invalid_plane_api_key_reference} =
             Adapter.validate_config(%{
               kind: "plane",
               api_key: "$OTHER_TOKEN",
               workspace_slug: "workspace-1",
               workspace_id: "workspace-stable-1",
               project_id: "project-1",
               provider: %{"api_key" => "$OTHER_TOKEN"}
             })

    assert {:error, :literal_plane_api_key_forbidden} =
             Adapter.validate_config(%{
               kind: "plane",
               api_key: "literal",
               workspace_slug: "workspace-1",
               workspace_id: "workspace-stable-1",
               project_id: "project-1",
               provider: %{"api_key" => "literal"}
             })

    assert {:error, :plane_endpoint_must_be_host_controlled} =
             Adapter.validate_config(%{@settings | endpoint: "https://other.example"})
  end

  test "fresh ID reads skip not-found items but fail malformed or foreign responses" do
    assert {:ok, []} =
             Adapter.fetch_issues_by_ids_for_test(["missing"], @settings, fn _request ->
               {:ok, %{status: 404, body: %{}}}
             end)

    assert {:error, {:provider_malformed, :missing_state}} =
             Adapter.fetch_issues_by_ids_for_test(["broken"], @settings, fn _request ->
               {:ok, %{status: 200, body: %{"id" => "broken", "updated_at" => "2026-09-17T08:09:10Z"}}}
             end)

    assert {:error, :wrong_project} =
             Adapter.fetch_issues_by_ids_for_test(["foreign"], @settings, fn _request ->
               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "foreign",
                    "project_id" => "other-project",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)

    assert {:error, :wrong_project} =
             Adapter.fetch_issues_by_ids_for_test(["foreign-workspace"], @settings, fn _request ->
               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "foreign-workspace",
                    "workspace_id" => "other-stable-workspace",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)
  end

  test "project listings fail closed for malformed projected items and state snapshots" do
    assert {:error, {:provider_malformed, :missing_state}} =
             Adapter.fetch_issues_by_states_for_test(["Ready"], @settings, fn request ->
               if String.ends_with?(request.path, "/work-items/"),
                 do: {:ok, %{status: 200, body: %{"results" => [%{"id" => "broken", "updated_at" => "2026-09-17T08:09:10Z"}], "next_page_results" => false}}},
                 else: {:ok, %{status: 200, body: %{"results" => [], "next_page_results" => false}}}
             end)

    assert {:error, {:provider_malformed, :invalid_group}} =
             Adapter.fetch_project_snapshot_for_test(@settings, fn request ->
               case request.path do
                 "/api/v1/workspaces/workspace-1/projects/project-1/" ->
                   {:ok, %{status: 200, body: %{"id" => "project-1", "workspace" => %{"slug" => "workspace-1"}}}}

                 _states_path ->
                   {:ok,
                    %{
                      status: 200,
                      body: %{
                        "results" => [%{"id" => "state-1", "name" => "Ready", "group" => "unknown"}],
                        "next_page_results" => false
                      }
                    }}
               end
             end)
  end

  test "supports contract scope fallback and string-keyed tracker settings" do
    settings = %{
      "kind" => "plane",
      "api_key" => "secret",
      "provider" => %{"workspace_slug" => "workspace-1", "workspace_id" => "workspace-stable-1", "api_key" => "$PLANE_API_KEY"},
      "secret_environment_names" => ["PLANE_API_KEY"],
      "provider_project_contract" => %{"workspace_id" => "workspace-stable-1", "project_id" => "project-1"}
    }

    assert {:ok, [%Issue{id: "item-1"}]} =
             Adapter.fetch_issues_by_ids_for_test(["item-1"], settings, fn request ->
               assert request.path =~ "/workspaces/workspace-1/projects/project-1/"

               {:ok,
                %{
                  status: 200,
                  body: %{
                    "id" => "item-1",
                    "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                    "updated_at" => "2026-09-17T08:09:10Z"
                  }
                }}
             end)
  end
end
