defmodule SymphonyElixir.PlaneStateProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.StateProjection

  @scope %{workspace_slug: "workspace-slug-1", workspace_id: "workspace-id-1", project_id: "project-1"}

  test "projects a work item without turning the provider name into canonical lifecycle authority" do
    assert {:ok, projected} =
             StateProjection.project_work_item(
               %{
                 "id" => "item-1",
                 "name" => "Ship the thing",
                 "state" => %{"id" => "state-ready", "name" => "Ready for work", "group" => "unstarted"},
                 "updated_at" => "2026-09-17T08:09:10Z",
                 "project_id" => "project-1",
                 "workspace_slug" => "workspace-slug-1",
                 "workspace_id" => "workspace-id-1"
               },
               @scope
             )

    assert projected.id == "item-1"
    assert projected.workspace_id == "workspace-id-1"
    assert projected.workspace_slug == "workspace-slug-1"
    assert projected.project_id == "project-1"
    assert projected.provider_state_id == "state-ready"
    assert projected.provider_state_group == :unstarted
    assert projected.provider_state_name == "Ready for work"
    assert %DateTime{} = projected.provider_updated_at
    refute Map.has_key?(projected, :validated_lifecycle_state)
    refute Map.has_key?(projected, :authority)
  end

  test "rejects a work item whose returned project scope contradicts the request" do
    assert {:error, :wrong_project} =
             StateProjection.project_work_item(
               %{
                 "id" => "item-1",
                 "name" => "Foreign item",
                 "state" => %{"id" => "state-ready", "name" => "Ready", "group" => "unstarted"},
                 "project_id" => "other-project"
               },
               @scope
             )
  end

  test "fails closed for missing or malformed state facts" do
    item = %{"id" => "item-1", "name" => "Broken"}
    assert {:error, {:provider_malformed, :missing_state}} = StateProjection.project_work_item(item, @scope)

    malformed = Map.put(item, "state", %{"id" => "state-1", "name" => "Ready", "group" => "unknown"})

    assert {:error, {:provider_malformed, :invalid_group}} =
             StateProjection.project_work_item(malformed, @scope)
  end

  test "projects states and projects with stable IDs and descriptive metadata" do
    assert {:ok, state} =
             StateProjection.project_state(%{"id" => "state-1", "name" => "Renamed", "group" => "started"})

    assert state == %{id: "state-1", name: "Renamed", group: :started}

    assert {:ok, project} =
             StateProjection.project_project(%{
               "id" => "project-1",
               "name" => "Project",
               "workspace_slug" => "workspace-slug-1"
             })

    assert project.project_id == "project-1"
    assert project.workspace_id == nil
    assert project.workspace_slug == "workspace-slug-1"
    assert project.workspace_name == nil
    assert project.name == "Project"
  end

  test "fails closed for invalid resource shapes, scope and timestamps" do
    assert {:error, {:provider_malformed, :invalid_work_item}} = StateProjection.project_work_item(:not_a_map, @scope)
    assert {:error, {:provider_malformed, :invalid_state}} = StateProjection.project_state(:not_a_map)
    assert {:error, {:provider_malformed, :invalid_project}} = StateProjection.project_project(:not_a_map)

    item = %{
      "id" => "item-1",
      "name" => "Work",
      "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
      "updated_at" => "not-a-date"
    }

    assert {:error, {:provider_malformed, {:invalid_datetime, :updated_at}}} =
             StateProjection.project_work_item(item, @scope)

    assert {:error, :wrong_project} =
             StateProjection.project_work_item(Map.put(item, "workspace_slug", "other-workspace"), @scope)

    assert {:error, :wrong_project} =
             StateProjection.project_work_item(
               Map.merge(item, %{"project_id" => "project-1", "project" => %{"id" => "other-project"}}),
               @scope
             )

    assert {:error, :wrong_project} =
             StateProjection.project_work_item(
               Map.put(item, "project", "other-project") |> Map.put("updated_at", "2026-09-17T08:09:10Z"),
               @scope
             )

    assert {:error, :wrong_project} =
             StateProjection.project_work_item(
               Map.put(item, "workspace", "other-workspace") |> Map.put("updated_at", "2026-09-17T08:09:10Z"),
               @scope
             )

    valid_item = Map.put(item, "updated_at", "2026-09-17T08:09:10Z")

    assert {:ok, _projected} =
             StateProjection.project_work_item(Map.put(valid_item, "project", "project-1"), @scope)

    assert {:ok, _projected} =
             StateProjection.project_work_item(Map.put(valid_item, "workspace", "workspace-id-1"), @scope)

    assert {:ok, _projected} =
             StateProjection.project_work_item(Map.put(valid_item, "workspace", "workspace-slug-1"), @scope)

    assert {:error, {:provider_malformed, {:missing_scope, :workspace_id}}} =
             StateProjection.project_work_item(item, %{project_id: "project-1"})
  end

  test "normalizes only the documented Plane groups and preserves bounded labels" do
    assert StateProjection.normalize_group(:started) == :started
    assert StateProjection.normalize_group(" COMPLETED ") == :completed
    assert StateProjection.normalize_group("unknown") == nil
    assert StateProjection.normalize_group(42) == nil

    assert {:ok, projected} =
             StateProjection.project_work_item(
               %{
                 "id" => "item-1",
                 "name" => "Work",
                 "description" => "Details",
                 "priority" => 2,
                 "labels" => [%{"name" => "bug"}, "urgent", %{"name" => "bug"}, 42],
                 "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                 "updated_at" => "2026-09-17T08:09:10Z",
                 "created_at" => "2026-09-16T08:09:10Z"
               },
               @scope
             )

    assert projected.labels == ["bug", "urgent"]
    assert projected.description == "Details"
    assert projected.priority == 2
    assert projected.created_at == ~U[2026-09-16 08:09:10Z]

    assert {:error, {:provider_malformed, {:invalid_datetime, :created_at}}} =
             StateProjection.project_work_item(
               %{
                 "id" => "item-1",
                 "state" => %{"id" => "state-1", "name" => "Ready", "group" => "unstarted"},
                 "updated_at" => "2026-09-17T08:09:10Z",
                 "created_at" => 42
               },
               @scope
             )
  end

  test "rejects missing state/project fields while allowing absent descriptive project name" do
    assert {:error, {:provider_malformed, :missing_id}} =
             StateProjection.project_state(%{"name" => "Ready", "group" => "started"})

    assert {:error, {:provider_malformed, {:invalid_field, :name}}} =
             StateProjection.project_state(%{"id" => "state-1", "name" => 42, "group" => "started"})

    assert {:ok, %{project_id: "project-1", workspace_id: nil}} =
             StateProjection.project_project(%{"id" => "project-1"})

    assert {:error, {:provider_malformed, {:invalid_field, :name}}} =
             StateProjection.project_project(%{"id" => "project-1", "workspace" => %{"slug" => "workspace-1"}, "name" => 42})

    assert {:ok, %{name: nil}} =
             StateProjection.project_project(%{"id" => "project-1", "workspace_id" => "workspace-id-1"})
  end
end
