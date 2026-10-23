defmodule SymphonyElixir.PlaneRuntimePrincipalEnforcementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.Adapter
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle}

  @runtime_user_id "920272c2-862e-4592-b13e-b0ba11c91b12"
  @workspace_slug "workspace-1"
  @workspace_id "workspace-stable-1"
  @project_id "project-1"
  @permissions ["workitem:view", "workitem:edit"]

  test "accepts a project snapshot only after the configured Ferdi principal and grants pass" do
    parent = self()

    assert {:ok, snapshot} =
             Adapter.fetch_project_snapshot_for_test(runtime_settings(), provider_response(:valid, parent))

    assert snapshot.runtime_principal == %{
             user_id: @runtime_user_id,
             principal_kind: "api_key",
             project_relation: "contributor",
             required_permissions: @permissions
           }

    assert_receive {:request_path, "/api/v2/users/me/"}
    assert_receive {:request_path, "/api/v2/workspaces/workspace-1/projects/project-1/permissions/me/"}
    assert_receive {:request_path, "/api/v1/workspaces/workspace-1/projects/project-1/"}
  end

  test "rejects the JC or any other Plane user before project snapshot reads" do
    for user_id <- ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"] do
      parent = self()

      assert {:error, :runtime_principal_identity_mismatch} =
               Adapter.fetch_project_snapshot_for_test(runtime_settings(), provider_response({:user, user_id}, parent))

      assert_receive {:request_path, "/api/v2/users/me/"}
      refute_receive {:request_path, "/api/v2/workspaces/workspace-1/projects/project-1/permissions/me/"}
      refute_receive {:request_path, "/api/v1/workspaces/workspace-1/projects/project-1/"}
    end
  end

  test "rejects a non API-key principal" do
    assert {:error, :runtime_principal_kind_mismatch} =
             Adapter.fetch_project_snapshot_for_test(runtime_settings(), provider_response(:oauth, self()))
  end

  test "rejects a wrong project relation" do
    assert {:error, :runtime_project_relation_mismatch} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:admin_relation, self())
             )
  end

  test "rejects missing required project permissions" do
    assert {:error, {:runtime_permissions_missing, ["workitem:edit"]}} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:missing_edit, self())
             )
  end

  test "fails closed when the identity endpoint is unavailable or malformed" do
    assert {:error, :provider_unavailable} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:identity_unavailable, self())
             )

    assert {:error, :provider_malformed} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:identity_malformed, self())
             )
  end

  test "fails closed when the project permission endpoint is unavailable or malformed" do
    assert {:error, :provider_unavailable} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:permissions_unavailable, self())
             )

    assert {:error, :provider_malformed} =
             Adapter.fetch_project_snapshot_for_test(
               runtime_settings(),
               provider_response(:permissions_malformed, self())
             )
  end

  test "rejects a JC identity before a controlled lifecycle mutation" do
    contract = runtime_contract()
    parent = self()

    assert {:error, :runtime_principal_identity_mismatch} =
             Adapter.submit_controlled_transition("item-1", :in_progress,
               tracker_settings: runtime_settings(),
               provider_project_contract: contract,
               request_fun: provider_response({:user, "00000000-0000-4000-8000-000000000001"}, parent)
             )

    refute_received {:request_path, "/api/v1/workspaces/workspace-1/projects/project-1/work-items/item-1/"}
  end

  defp runtime_settings do
    %{
      kind: "plane",
      api_key: "test-fixture-api-key",
      endpoint: "https://api.plane.so",
      workspace_slug: @workspace_slug,
      workspace_id: @workspace_id,
      project_id: @project_id,
      provider: %{
        "workspace_slug" => @workspace_slug,
        "workspace_id" => @workspace_id,
        "project_id" => @project_id,
        "api_key" => "$PLANE_API_KEY_FERDI"
      },
      secret_environment_names: ["PLANE_API_KEY_FERDI"],
      runtime_principal: runtime_contract().runtime_principal,
      provider_project_contract: runtime_contract()
    }
  end

  defp runtime_contract do
    {:ok, contract} =
      ProviderProjectContract.new(%{
        schema_version: 1,
        provider: :plane,
        workspace_id: @workspace_id,
        project_id: @project_id,
        runtime_principal: %{
          api_key_env: "PLANE_API_KEY_FERDI",
          user_id: @runtime_user_id,
          principal_kind: "api_key",
          project_relation: "contributor",
          required_permissions: @permissions
        },
        state_mappings:
          Map.new(WorkflowLifecycle.states(), fn state ->
            {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
          end)
      })

    contract
  end

  defp provider_response(scenario, parent) do
    fn request ->
      send(parent, {:request_path, request.path})
      response_for(request.path, scenario)
    end
  end

  defp response_for("/api/v2/users/me/", scenario) do
    case scenario do
      :identity_unavailable ->
        {:error, :closed}

      :identity_malformed ->
        {:ok, %{status: 200, body: %{"id" => 42, "principal_kind" => "api_key"}}}

      :oauth ->
        {:ok, %{status: 200, body: %{"id" => @runtime_user_id, "principal_kind" => "oauth"}}}

      {:user, user_id} ->
        {:ok, %{status: 200, body: %{"id" => user_id, "principal_kind" => "api_key"}}}

      _valid ->
        {:ok, %{status: 200, body: %{"id" => @runtime_user_id, "principal_kind" => "api_key"}}}
    end
  end

  defp response_for("/api/v2/workspaces/workspace-1/projects/project-1/permissions/me/", scenario) do
    case scenario do
      :permissions_unavailable ->
        {:error, :timeout}

      :permissions_malformed ->
        {:ok, %{status: 200, body: %{"relation" => "contributor", "permission_grants" => "workitem:view"}}}

      :admin_relation ->
        {:ok, %{status: 200, body: %{"relation" => "admin", "permission_grants" => @permissions}}}

      :missing_edit ->
        {:ok, %{status: 200, body: %{"relation" => "contributor", "permission_grants" => ["workitem:view"]}}}

      _valid ->
        {:ok, %{status: 200, body: %{"relation" => "contributor", "permission_grants" => @permissions}}}
    end
  end

  defp response_for("/api/v1/workspaces/workspace-1/projects/project-1/", _scenario) do
    {:ok, %{status: 200, body: %{"id" => @project_id, "workspace" => @workspace_id}}}
  end

  defp response_for("/api/v1/workspaces/workspace-1/projects/project-1/states/", _scenario) do
    {:ok,
     %{
       status: 200,
       body: %{
         "results" => [],
         "count" => 0,
         "total_results" => 0,
         "next_page_results" => false,
         "next_cursor" => nil
       }
     }}
  end

  defp response_for(_path, _scenario), do: {:error, :not_found}
end
