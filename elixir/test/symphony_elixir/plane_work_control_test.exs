defmodule SymphonyElixir.PlaneWorkControlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle, WorkItem}

  test "Plane observations resolve stable IDs and groups, never descriptive names" do
    contract = contract!()

    issue = %Issue{
      id: "item-1",
      identifier: "ITEM-1",
      title: "Work",
      state: "Renamed Ready",
      workspace_id: "workspace-1",
      project_id: "project-1",
      provider_state_id: "state-ready",
      provider_state_group: :unstarted,
      updated_at: ~U[2026-09-17 08:09:10Z]
    }

    assert {:ok, work_item} =
             WorkItem.from_issue(issue, %{
               provider: :plane,
               prior_validated_lifecycle_state: :ready,
               provider_project_contract: contract
             })

    assert work_item.provider_observation.provider_state_name == "Renamed Ready"

    assert %{provider: :plane, workspace_id: "workspace-1", project_id: "project-1"} =
             work_item.provider_observation.snapshot_identity

    assert work_item.lifecycle_assessment.mapped_state == :ready
    assert work_item.lifecycle_assessment.status == :validated
    refute Map.has_key?(work_item.provider_observation, :authority)
    refute Map.has_key?(work_item.provider_observation, :validated_lifecycle_state)
  end

  test "unknown IDs and changed groups fail closed even when the display name is unchanged" do
    contract = contract!()

    for {state_id, group, reason} <- [
          {"new-state-with-old-name", :unstarted, :unknown_state_mapping},
          {"state-ready", :started, :state_group_mismatch}
        ] do
      issue = %Issue{
        id: "item-1",
        identifier: "ITEM-1",
        title: "Work",
        state: "Ready",
        provider_state_id: state_id,
        provider_state_group: group
      }

      assert {:ok, work_item} =
               WorkItem.from_issue(issue, %{
                 provider: :plane,
                 prior_validated_lifecycle_state: :ready,
                 provider_project_contract: contract
               })

      assert work_item.lifecycle_assessment.status == :invalid
      assert work_item.lifecycle_assessment.reason == reason
      assert work_item.authority_disposition.status == :suspended
    end
  end

  defp contract! do
    attrs = %{
      schema_version: 1,
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      state_mappings:
        Map.new(WorkflowLifecycle.states(), fn state ->
          {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
        end)
    }

    {:ok, contract} = ProviderProjectContract.new(attrs)
    contract
  end
end
