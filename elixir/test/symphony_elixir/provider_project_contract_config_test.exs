defmodule SymphonyElixir.ProviderProjectContractConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle}

  @states WorkflowLifecycle.states()

  test "legacy and current workflows remain valid without a project contract" do
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})

    assert settings.provider_project_contract == nil
    assert settings.tracker.kind == "linear"
  end

  test "parses a top-level contract into typed authority without activating Plane" do
    assert {:ok, settings} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear"},
               "provider_project_contract" => contract_config()
             })

    assert %ProviderProjectContract{} = contract = settings.provider_project_contract
    assert contract.provider == :plane
    assert contract.workspace_id == "workspace-1"
    assert contract.project_id == "project-1"
    assert contract.configuration_fingerprint == ProviderProjectContract.fingerprint(contract)
    assert %Schema.Tracker{kind: "linear"} = settings.tracker
  end

  test "accepts descriptive metadata without treating it as authority" do
    config =
      contract_config()
      |> Map.put("workspace_name", "Workspace")
      |> Map.put("project_name", "Project")

    assert {:ok, settings} = Schema.parse(%{"provider_project_contract" => config})

    assert settings.provider_project_contract.state_mappings.ready.name == "Ready"

    assert settings.provider_project_contract.configuration_fingerprint ==
             ProviderProjectContract.fingerprint(settings.provider_project_contract)
  end

  test "rejects malformed contract configuration with a bounded workflow error" do
    malformed = Map.put(contract_config(), "project_id", " ")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"provider_project_contract" => malformed})

    assert message =~ "provider_project_contract"
    assert message =~ "project_id"
  end

  test "does not trust a caller-supplied fingerprint" do
    forged = Map.put(contract_config(), "configuration_fingerprint", "sha256:forged")

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"provider_project_contract" => forged})

    assert message =~ "provider_project_contract"
  end

  test "contract configuration does not require Plane credentials or a Plane tracker" do
    assert {:ok, settings} = Schema.parse(%{"provider_project_contract" => contract_config()})

    assert settings.tracker.kind == nil
    assert settings.tracker.api_key == nil
    assert settings.provider_project_contract.provider == :plane
  end

  test "runtime principal policy is limited to the Ferdi user, contributor role, and required grants" do
    for {field, value} <- [
          {"api_key_env", "PLANE_API_KEY_JC"},
          {"user_id", "00000000-0000-4000-8000-000000000001"},
          {"project_relation", "admin"},
          {"required_permissions", ["workitem:view"]}
        ] do
      malformed =
        update_in(contract_config(), ["runtime_principal", field], fn _ -> value end)

      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{"provider_project_contract" => malformed})

      assert message =~ "provider_project_contract"
    end
  end

  defp contract_config do
    %{
      "schema_version" => 1,
      "provider" => "plane",
      "workspace_id" => "workspace-1",
      "project_id" => "project-1",
      "runtime_principal" => %{
        "api_key_env" => "PLANE_API_KEY_FERDI",
        "user_id" => "920272c2-862e-4592-b13e-b0ba11c91b12",
        "principal_kind" => "api_key",
        "project_relation" => "contributor",
        "required_permissions" => ["workitem:view", "workitem:edit"]
      },
      "state_mappings" =>
        Map.new(@states, fn state ->
          {Atom.to_string(state),
           %{
             "state_id" => "state-#{state}",
             "name" => WorkflowLifecycle.display(state)
           }}
        end)
    }
  end
end
