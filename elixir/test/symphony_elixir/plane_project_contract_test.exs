defmodule SymphonyElixir.PlaneProjectContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.ProjectContract
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

  test "accepts a complete matching snapshot and returns an immutable result" do
    contract = contract!()
    result = ProjectContract.validate(contract, snapshot())

    assert %ProviderProjectContract.ValidationResult{
             status: :valid,
             diagnostics: [],
             expected_fingerprint: expected,
             observed_fingerprint: observed
           } = result

    assert expected == ProviderProjectContract.fingerprint(contract)
    assert observed == expected
  end

  test "ignores unrelated metadata and descriptive renames" do
    contract = contract!()

    renamed =
      snapshot()
      |> Map.put(:workspace_name, "Renamed Workspace")
      |> Map.put(:project_name, "Renamed Project")
      |> Map.put(:unrelated_metadata, %{secret: "must-not-affect-authority"})
      |> Map.update!(:states, fn states ->
        Enum.map(states, fn state -> %{state | name: "Renamed #{state.name}"} end)
      end)

    result = ProjectContract.validate(contract, renamed)

    assert result.status == :valid
    assert result.observed_fingerprint == result.expected_fingerprint
    assert Enum.count(result.diagnostics, &(&1.class == :descriptive_name_changed)) == 11
    refute Enum.any?(result.diagnostics, &(&1.class == :configuration_fingerprint_mismatch))
  end

  test "accepts complete snapshots with absent or nil descriptive metadata" do
    contract = contract!()

    snapshots = [
      snapshot()
      |> Map.delete(:workspace_name)
      |> Map.delete(:project_name)
      |> Map.update!(:states, fn states -> Enum.map(states, &Map.delete(&1, :name)) end),
      snapshot()
      |> Map.put(:workspace_name, nil)
      |> Map.put(:project_name, nil)
      |> Map.update!(:states, fn states -> Enum.map(states, &Map.put(&1, :name, nil)) end)
    ]

    for candidate <- snapshots do
      result = ProjectContract.validate(contract, candidate)

      assert result.status == :valid
      assert result.observed_fingerprint == result.expected_fingerprint
      assert result.diagnostics == []
    end
  end

  test "normalizes string-keyed provider snapshots and descriptive groups" do
    contract = contract!()
    result = ProjectContract.validate(contract, string_snapshot())

    assert result.status == :valid
    assert result.diagnostics == []
    assert result.observed_fingerprint == result.expected_fingerprint
  end

  test "classifies wrong typed present snapshot fields as provider malformed" do
    contract = contract!()

    malformed_snapshots = [
      Map.put(snapshot(), :provider, 42),
      Map.put(snapshot(), :workspace_id, 42),
      Map.put(snapshot(), :project_id, 42),
      Map.put(snapshot(), :workspace_name, 42),
      Map.put(snapshot(), :project_name, 42),
      Map.update!(snapshot(), :states, fn [state | rest] -> [%{state | id: 42} | rest] end),
      Map.update!(snapshot(), :states, fn [state | rest] -> [%{state | name: 42} | rest] end),
      Map.put(snapshot(), :states, :not_a_list),
      Map.put(snapshot(), :dependency_relation_semantics, :not_a_map),
      Map.put(snapshot(), :capability_statuses, :not_a_map),
      Map.put(snapshot(), :completeness, nil)
    ]

    for candidate <- malformed_snapshots do
      result = ProjectContract.validate(contract, candidate)

      assert result.status == :provider_malformed
      assert has_class?(result, :provider_malformed)
      refute has_class?(result, :snapshot_incomplete)
    end
  end

  test "does not accept a replacement state with the old descriptive name" do
    contract = contract!()

    replaced =
      snapshot()
      |> Map.update!(:states, fn states ->
        Enum.map(states, fn
          %{id: "state-ready"} = state -> %{state | id: "state-ready-recreated", name: "Ready"}
          state -> state
        end)
      end)

    result = ProjectContract.validate(contract, replaced)

    assert result.status == :drift_detected
    assert has_class?(result, :state_identity_missing)
    assert has_class?(result, :configuration_fingerprint_mismatch)
    assert result.observed_fingerprint != result.expected_fingerprint
  end

  test "classifies provider, workspace, project, group, relation, and capability drift" do
    contract = contract!()

    drifted =
      snapshot()
      |> Map.put(:provider, :linear)
      |> Map.put(:workspace_id, "workspace-other")
      |> Map.put(:project_id, "project-other")
      |> Map.put(:dependency_relation_semantics, %{blocked_by: :depends_on, blocking: :blocking})
      |> Map.put(:capability_statuses, Map.put(snapshot().capability_statuses, :dependency_graph, :unsupported))
      |> Map.update!(:states, fn states ->
        Enum.map(states, fn
          %{id: "state-ready"} = state -> %{state | group: :started}
          state -> state
        end)
      end)

    result = ProjectContract.validate(contract, drifted)

    assert result.status == :drift_detected

    for class <- [
          :provider_identity_mismatch,
          :workspace_identity_mismatch,
          :project_identity_mismatch,
          :state_group_mismatch,
          :dependency_relation_semantics_mismatch,
          :required_capability_unavailable,
          :configuration_fingerprint_mismatch
        ] do
      assert has_class?(result, class), "missing diagnostic #{inspect(class)}"
    end
  end

  test "optional capability loss remains valid and is diagnostic only" do
    contract = contract!()
    statuses = Map.put(snapshot().capability_statuses, :conditional_transition, :unsupported)
    result = ProjectContract.validate(contract, Map.put(snapshot(), :capability_statuses, statuses))

    assert result.status == :valid
    assert has_class?(result, :optional_capability_unavailable)
    refute has_class?(result, :configuration_fingerprint_mismatch)
  end

  test "rejects unknown capability statuses and duplicate provider state IDs" do
    contract = contract!()

    assert ProjectContract.validate(
             contract,
             Map.put(snapshot().capability_statuses, :current_issue_refresh, :maybe)
             |> then(&Map.put(snapshot(), :capability_statuses, &1))
           ).status == :provider_malformed

    duplicate_states = [%{id: "state-ready", group: :unstarted, name: "Another"} | snapshot().states]
    duplicate_result = ProjectContract.validate(contract, Map.put(snapshot(), :states, duplicate_states))

    assert duplicate_result.status == :provider_malformed
    assert has_class?(duplicate_result, :provider_malformed)
  end

  test "rejects ambiguous and unsupported dependency relation keys" do
    contract = contract!()

    ambiguous =
      snapshot()
      |> Map.put(:dependency_relation_semantics, %{
        "blocked_by" => :depends_on,
        blocked_by: :blocked_by,
        blocking: :blocking
      })

    unsupported =
      snapshot()
      |> Map.put(:dependency_relation_semantics, %{
        blocked_by: :blocked_by,
        blocking: :blocking,
        start_before: :start_before
      })

    for candidate <- [ambiguous, unsupported] do
      result = ProjectContract.validate(contract, candidate)

      assert result.status == :provider_malformed
      assert has_class?(result, :provider_malformed)
    end
  end

  test "rejects conflicting atom and string capability keys" do
    contract = contract!()

    statuses = Map.put(snapshot().capability_statuses, "current_issue_refresh", :unsupported)
    result = ProjectContract.validate(contract, Map.put(snapshot(), :capability_statuses, statuses))

    assert result.status == :provider_malformed
    assert has_class?(result, :provider_malformed)
  end

  test "rejects conflicting atom and string identity keys" do
    contract = contract!()

    result =
      ProjectContract.validate(
        contract,
        snapshot()
        |> Map.put("project_id", "project-other")
      )

    assert result.status == :provider_malformed
    assert has_class?(result, :provider_malformed)
  end

  test "fails closed for an improper provider state list" do
    contract = contract!()
    malformed_states = [hd(snapshot().states) | :truncated]

    result = ProjectContract.validate(contract, Map.put(snapshot(), :states, malformed_states))

    assert result.status == :provider_malformed
    assert has_class?(result, :provider_malformed)
  end

  test "fails closed for bounded, nested, and semantic snapshot errors" do
    contract = contract!()
    base = snapshot()

    too_many_states = Map.put(base, :states, List.duplicate(hd(base.states), 65))
    invalid_state = Map.put(base, :states, [42 | tl(base.states)])

    invalid_group =
      Map.update!(base, :states, fn [state | rest] -> [%{state | group: "unknown"} | rest] end)

    relation_missing = Map.put(base, :dependency_relation_semantics, %{blocking: :blocking})
    relation_invalid = Map.put(base, :dependency_relation_semantics, %{blocked_by: 42, blocking: :blocking})
    missing_capability = Map.put(base, :capability_statuses, Map.delete(base.capability_statuses, :dependency_graph))

    invalid_capability =
      Map.put(base, :capability_statuses, Map.put(base.capability_statuses, :dependency_graph, %{}))

    unknown_capability =
      Map.put(base, :capability_statuses, Map.put(base.capability_statuses, "unknown", :supported))

    malformed_candidates = [
      too_many_states,
      invalid_state,
      invalid_group,
      relation_invalid,
      invalid_capability,
      unknown_capability
    ]

    for candidate <- malformed_candidates do
      result = ProjectContract.validate(contract, candidate)
      assert result.status == :provider_malformed
      assert has_class?(result, :provider_malformed)
    end

    for candidate <- [relation_missing, missing_capability] do
      result = ProjectContract.validate(contract, candidate)
      assert result.status == :snapshot_incomplete
      assert has_class?(result, :snapshot_incomplete)
    end
  end

  test "bounds malformed diagnostic values and rejects invalid contract inputs" do
    contract = contract!()

    assert ProjectContract.validate(%{}, snapshot()).status == :provider_malformed

    for value <- [[], %{}, {:unexpected, :value}] do
      result =
        ProjectContract.validate(
          contract,
          Map.put(snapshot(), :capability_statuses, Map.put(snapshot().capability_statuses, :dependency_graph, value))
        )

      assert result.status == :provider_malformed
      assert has_class?(result, :provider_malformed)
    end
  end

  test "fails closed for incomplete snapshots" do
    contract = contract!()

    result = ProjectContract.validate(contract, Map.put(snapshot(), :completeness, :incomplete))

    assert %ProviderProjectContract.ValidationResult{status: :snapshot_incomplete} = result
    assert has_class?(result, :snapshot_incomplete)
  end

  test "missing required snapshot fields are incomplete rather than guessed" do
    contract = contract!()
    incomplete = snapshot() |> Map.delete(:project_id) |> Map.delete(:project_name)
    result = ProjectContract.validate(contract, incomplete)

    assert result.status == :snapshot_incomplete
    assert has_class?(result, :snapshot_incomplete)
  end

  defp contract! do
    attrs = %{
      schema_version: 1,
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      state_mappings:
        Map.new(@states, fn state ->
          {state, %{state_id: "state-#{state}", name: WorkflowLifecycle.display(state)}}
        end)
    }

    {:ok, contract} = ProviderProjectContract.new(attrs)
    contract
  end

  defp snapshot do
    %{
      provider: :plane,
      workspace_id: "workspace-1",
      workspace_name: "Workspace",
      project_id: "project-1",
      project_name: "Project",
      states:
        Enum.map(@states, fn state ->
          %{id: "state-#{state}", group: Map.fetch!(@plane_groups, state), name: WorkflowLifecycle.display(state)}
        end),
      dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
      capability_statuses: Map.new(Capabilities.vocabulary(), &{&1, :supported}),
      completeness: :complete
    }
  end

  defp string_snapshot do
    groups = %{
      backlog: "backlog",
      planning: "unstarted",
      ready: "unstarted",
      in_progress: "started",
      in_review: "started",
      changes_requested: "started",
      ready_to_merge: "started",
      merging: "started",
      blocked: "started",
      done: "completed",
      canceled: "cancelled"
    }

    %{
      "provider" => "plane",
      "workspace_id" => "workspace-1",
      "project_id" => "project-1",
      "states" =>
        Enum.map(@states, fn state ->
          %{
            "id" => "state-#{state}",
            "group" => Map.fetch!(groups, state),
            "name" => WorkflowLifecycle.display(state)
          }
        end),
      "dependency_relation_semantics" => %{
        "blocked_by" => "blocked_by",
        "blocking" => "blocking"
      },
      "capability_statuses" => Map.new(Capabilities.vocabulary(), &{Atom.to_string(&1), :supported}),
      "completeness" => :complete
    }
  end

  defp has_class?(result, class) do
    Enum.any?(result.diagnostics, &(&1.class == class))
  end
end
