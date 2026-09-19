defmodule SymphonyElixir.ProviderProjectContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle}

  @states WorkflowLifecycle.states()

  @plane_groups %{
    backlog: :backlog,
    planning: :unstarted,
    ready: :unstarted,
    in_progress: :started,
    in_review: :started,
    changes_requested: :started,
    ready_to_merge: :started,
    merging: :started,
    blocked: :started,
    done: :completed,
    canceled: :cancelled
  }

  test "constructs the exact provider-neutral Plane authority contract" do
    assert {:ok, contract} = ProviderProjectContract.new(valid_attrs())

    assert contract.schema_version == 1
    assert contract.provider == :plane
    assert contract.workspace_id == "workspace-1"
    assert contract.project_id == "project-1"
    assert Map.keys(contract.state_mappings) |> Enum.sort() == Enum.sort(@states)

    for state <- @states do
      mapping = Map.fetch!(contract.state_mappings, state)
      assert mapping.state_id == "state-#{state}"
      assert mapping.group == Map.fetch!(@plane_groups, state)
      assert mapping.name == WorkflowLifecycle.display(state)
    end

    assert contract.dependency_relation_semantics == %{
             blocked_by: :blocked_by,
             blocking: :blocking
           }

    assert contract.required_capabilities == Capabilities.required_routed()
    assert contract.optional_capabilities == [:conditional_transition]
    assert contract.configuration_fingerprint == ProviderProjectContract.fingerprint(contract)
    assert String.starts_with?(contract.configuration_fingerprint, "sha256:")
  end

  test "accepts normalized workflow maps with string keys and canonicalizes them" do
    assert {:ok, contract} = ProviderProjectContract.new(string_keyed_attrs())

    assert Map.keys(contract.state_mappings) |> Enum.sort() == Enum.sort(@states)

    for state <- @states do
      mapping = Map.fetch!(contract.state_mappings, state)

      assert mapping.state_id == "state-#{state}"
      assert mapping.group == Map.fetch!(@plane_groups, state)
      assert mapping.name == WorkflowLifecycle.display(state)
      assert Map.keys(mapping) |> Enum.sort() == [:group, :name, :state_id]
    end

    assert contract.dependency_relation_semantics == %{
             blocked_by: :blocked_by,
             blocking: :blocking
           }
  end

  test "maps only canonical states to stable provider IDs" do
    assert {:ok, contract} = ProviderProjectContract.new(valid_attrs())

    assert {:ok, %{state_id: "state-in_progress", group: :started}} =
             ProviderProjectContract.provider_mapping_for(contract, :in_progress)

    assert {:error, :unknown_canonical_state} =
             ProviderProjectContract.provider_mapping_for(contract, "In Progress")
  end

  test "accepts string capability names from workflow configuration" do
    attrs =
      string_keyed_attrs()
      |> Map.put("required_capabilities", Enum.map(Capabilities.required_routed(), &Atom.to_string/1))
      |> Map.put("optional_capabilities", ["conditional_transition"])

    assert {:ok, contract} = ProviderProjectContract.new(attrs)
    assert contract.required_capabilities == Capabilities.required_routed()
    assert contract.optional_capabilities == [:conditional_transition]
  end

  test "rejects unknown and ambiguous canonical configuration keys" do
    string_attrs = string_keyed_attrs()

    unknown_state =
      Map.put(
        string_attrs["state_mappings"],
        "provider_open",
        %{"state_id" => "state-provider-open"}
      )

    duplicate_state =
      Map.put(
        string_attrs["state_mappings"],
        :ready,
        %{"state_id" => "state-ready-ambiguous"}
      )

    duplicate_mapping_key =
      Map.put(
        string_attrs["state_mappings"],
        "ready",
        Map.put(string_attrs["state_mappings"]["ready"], :state_id, "state-ready-ambiguous")
      )

    unknown_mapping_key =
      Map.put(
        string_attrs["state_mappings"],
        "ready",
        Map.put(string_attrs["state_mappings"]["ready"], "label", "Ready")
      )

    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_canonical_state}} =
             ProviderProjectContract.new(%{string_attrs | "state_mappings" => unknown_state})

    assert {:error, %ProviderProjectContract.ConfigError{code: :duplicate_canonical_state}} =
             ProviderProjectContract.new(%{string_attrs | "state_mappings" => duplicate_state})

    assert {:error, %ProviderProjectContract.ConfigError{code: :duplicate_state_mapping_key}} =
             ProviderProjectContract.new(%{string_attrs | "state_mappings" => duplicate_mapping_key})

    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_state_mapping_key}} =
             ProviderProjectContract.new(%{string_attrs | "state_mappings" => unknown_mapping_key})
  end

  test "rejects unknown and ambiguous top-level configuration keys" do
    attrs = string_keyed_attrs()

    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_configuration_key}} =
             ProviderProjectContract.new(Map.put(attrs, "unexpected", true))

    assert {:error, %ProviderProjectContract.ConfigError{code: :duplicate_configuration_key}} =
             ProviderProjectContract.new(Map.put(attrs, :provider, "plane"))
  end

  test "derives capability sets from the accepted Tracker vocabulary" do
    assert ProviderProjectContract.required_capabilities() == Capabilities.required_routed()

    assert ProviderProjectContract.optional_capabilities() ==
             Capabilities.vocabulary() -- Capabilities.required_routed()
  end

  test "rejects unsupported, wrong, missing, duplicate, and malformed configuration" do
    invalid_cases = [
      {Map.put(valid_attrs(), :schema_version, 2), :unsupported_schema_version},
      {Map.put(valid_attrs(), :provider, :linear), :unsupported_provider},
      {Map.put(valid_attrs(), :workspace_id, "   "), :invalid_workspace_id},
      {Map.put(valid_attrs(), :project_id, String.duplicate("p", 257)), :invalid_project_id},
      {Map.put(valid_attrs(), :state_mappings, [:not_a_mapping]), :invalid_state_mappings},
      {Map.put(valid_attrs(), :state_mappings, Map.delete(valid_attrs().state_mappings, :blocked)), :missing_canonical_state},
      {Map.put(valid_attrs(), :state_mappings, Map.put(valid_attrs().state_mappings, :provider_open, %{state_id: "other"})), :unknown_canonical_state},
      {Map.put(
         valid_attrs(),
         :state_mappings,
         Map.update!(valid_attrs().state_mappings, :done, &Map.put(&1, :state_id, "state-backlog"))
       ), :duplicate_state_id},
      {Map.put(
         valid_attrs(),
         :state_mappings,
         Map.update!(valid_attrs().state_mappings, :ready, &Map.put(&1, :group, :backlog))
       ), :state_group_redefinition},
      {Map.put(valid_attrs(), :dependency_relation_semantics, %{blocked_by: :depends_on, blocking: :blocking}), :dependency_relation_redefinition},
      {Map.put(valid_attrs(), :required_capabilities, [:current_issue_refresh]), :required_capabilities_redefinition},
      {Map.put(valid_attrs(), :optional_capabilities, []), :optional_capabilities_redefinition}
    ]

    for {attrs, code} <- invalid_cases do
      assert {:error, %ProviderProjectContract.ConfigError{code: ^code}} =
               ProviderProjectContract.new(attrs)
    end
  end

  test "fails closed for missing scalar fields and malformed nested mappings" do
    assert {:error, %ProviderProjectContract.ConfigError{code: :invalid_configuration}} =
             ProviderProjectContract.new([])

    for {attrs, code} <- [
          {Map.delete(valid_attrs(), :schema_version), :unsupported_schema_version},
          {Map.delete(valid_attrs(), :provider), :unsupported_provider},
          {Map.delete(valid_attrs(), :workspace_id), :invalid_workspace_id},
          {Map.delete(valid_attrs(), :project_id), :invalid_project_id},
          {Map.put(valid_attrs(), :workspace_name, nil), nil},
          {Map.put(valid_attrs(), :workspace_name, 42), :invalid_descriptive_name},
          {Map.update!(valid_attrs(), :state_mappings, &Map.put(&1, :ready, :not_a_mapping)), :invalid_state_mapping},
          {Map.update!(valid_attrs(), :state_mappings, &Map.update!(&1, :ready, fn mapping -> Map.delete(mapping, :state_id) end)), :invalid_state_id},
          {Map.update!(valid_attrs(), :state_mappings, &Map.update!(&1, :ready, fn mapping -> Map.delete(mapping, :name) end)), nil},
          {Map.update!(valid_attrs(), :state_mappings, &Map.update!(&1, :ready, fn mapping -> Map.put(mapping, :name, nil) end)), nil},
          {Map.update!(valid_attrs(), :state_mappings, &Map.update!(&1, :ready, fn mapping -> Map.put(mapping, :name, 42) end)), :invalid_state_name}
        ] do
      case code do
        nil -> assert {:ok, _contract} = ProviderProjectContract.new(attrs)
        expected -> assert {:error, %ProviderProjectContract.ConfigError{code: ^expected}} = ProviderProjectContract.new(attrs)
      end
    end
  end

  test "rejects non-canonical keys and semantic redefinitions" do
    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_configuration_key}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), 42, true))

    unknown_state = Map.put(valid_attrs().state_mappings, 42, %{state_id: "state-unknown"})

    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_canonical_state}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :state_mappings, unknown_state))

    unknown_mapping_key = Map.put(valid_attrs().state_mappings.ready, 42, true)

    assert {:error, %ProviderProjectContract.ConfigError{code: :unknown_state_mapping_key}} =
             ProviderProjectContract.new(put_in(valid_attrs(), [:state_mappings, :ready], unknown_mapping_key))

    string_group = Map.put(valid_attrs().state_mappings.ready, "group", "started")

    assert {:error, %ProviderProjectContract.ConfigError{code: :state_group_redefinition}} =
             ProviderProjectContract.new(put_in(valid_attrs(), [:state_mappings, :ready], string_group))

    assert {:error, %ProviderProjectContract.ConfigError{code: :dependency_relation_redefinition}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :dependency_relation_semantics, :not_a_map))

    relation_with_unknown_key = %{42 => :unknown, blocked_by: :blocked_by, blocking: :blocking}

    assert {:error, %ProviderProjectContract.ConfigError{code: :dependency_relation_redefinition}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :dependency_relation_semantics, relation_with_unknown_key))

    assert {:error, %ProviderProjectContract.ConfigError{code: :required_capabilities_redefinition}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :required_capabilities, %{}))

    assert {:error, %ProviderProjectContract.ConfigError{code: :required_capabilities_redefinition}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :required_capabilities, [:unknown]))
  end

  test "fingerprint handles non-canonical manual struct values deterministically" do
    assert {:ok, contract} = ProviderProjectContract.new(valid_attrs())

    malformed = %{
      contract
      | provider: "plane",
        state_mappings: :not_a_map,
        dependency_relation_semantics: :not_a_map,
        required_capabilities: :not_a_list,
        configuration_fingerprint: nil
    }

    assert is_binary(ProviderProjectContract.fingerprint(malformed))

    nested_malformed = %{malformed | state_mappings: %{ready: :not_a_mapping}}
    assert is_binary(ProviderProjectContract.fingerprint(nested_malformed))
  end

  test "does not accept a caller-supplied fingerprint" do
    assert {:error, %ProviderProjectContract.ConfigError{code: :fingerprint_is_derived}} =
             ProviderProjectContract.new(Map.put(valid_attrs(), :configuration_fingerprint, "sha256:forged"))
  end

  test "fingerprint is stable across map order, names, and optional capability changes" do
    assert {:ok, first} = ProviderProjectContract.new(valid_attrs())

    reordered_attrs = %{
      project_id: "project-1",
      workspace_id: "workspace-1",
      provider: "plane",
      schema_version: 1,
      state_mappings:
        first.state_mappings
        |> Enum.reverse()
        |> Map.new(fn {state, mapping} ->
          {state, %{name: "renamed #{state}", state_id: mapping.state_id}}
        end),
      dependency_relation_semantics: %{blocking: "blocking", blocked_by: "blocked_by"},
      required_capabilities: Enum.reverse(Capabilities.required_routed()),
      optional_capabilities: [:conditional_transition]
    }

    assert {:ok, second} = ProviderProjectContract.new(reordered_attrs)
    assert ProviderProjectContract.fingerprint(first) == ProviderProjectContract.fingerprint(second)
    assert first.configuration_fingerprint == second.configuration_fingerprint

    forged = %{first | configuration_fingerprint: "sha256:forged"}
    assert ProviderProjectContract.fingerprint(forged) == ProviderProjectContract.fingerprint(first)
  end

  test "fingerprint changes for every configured semantic identity" do
    assert {:ok, contract} = ProviderProjectContract.new(valid_attrs())
    base_fingerprint = ProviderProjectContract.fingerprint(contract)

    for {field, value} <- [workspace_id: "workspace-2", project_id: "project-2"] do
      assert ProviderProjectContract.fingerprint(%{contract | field => value}) != base_fingerprint
    end

    replaced_state = put_in(contract.state_mappings[:ready].state_id, "state-ready-replaced")
    assert ProviderProjectContract.fingerprint(%{contract | state_mappings: replaced_state}) != base_fingerprint

    changed_relation = %{contract.dependency_relation_semantics | blocked_by: :blocking}

    assert ProviderProjectContract.fingerprint(%{contract | dependency_relation_semantics: changed_relation}) !=
             base_fingerprint

    changed_capabilities = %{contract | required_capabilities: Enum.reverse(contract.required_capabilities)}
    assert ProviderProjectContract.fingerprint(changed_capabilities) == base_fingerprint

    changed_schema = %{contract | schema_version: 2}
    assert ProviderProjectContract.fingerprint(changed_schema) != base_fingerprint

    changed_provider = %{contract | provider: :other_provider}
    assert ProviderProjectContract.fingerprint(changed_provider) != base_fingerprint
  end

  defp valid_attrs do
    %{
      schema_version: 1,
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      state_mappings:
        Map.new(@states, fn state ->
          {state,
           %{
             state_id: "state-#{state}",
             name: WorkflowLifecycle.display(state)
           }}
        end)
    }
  end

  defp string_keyed_attrs do
    %{
      "schema_version" => 1,
      "provider" => "plane",
      "workspace_id" => "workspace-1",
      "project_id" => "project-1",
      "state_mappings" =>
        Map.new(@states, fn state ->
          {Atom.to_string(state),
           %{
             "state_id" => "state-#{state}",
             "name" => WorkflowLifecycle.display(state)
           }}
        end),
      "dependency_relation_semantics" => %{
        "blocked_by" => "blocked_by",
        "blocking" => "blocking"
      },
      "required_capabilities" => Capabilities.required_routed(),
      "optional_capabilities" => [:conditional_transition]
    }
  end
end
