defmodule SymphonyElixir.ProjectContractEvidenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.ProjectContract
  alias SymphonyElixir.Tracker.Capabilities

  alias SymphonyElixir.WorkControl.{
    ProjectContractEvidence,
    ProviderProjectContract,
    WorkflowLifecycle
  }

  @states WorkflowLifecycle.states()

  test "a configured contract requires fresh reconciliation while pristine nil bootstraps" do
    unconfigured = ProjectContractEvidence.new(nil)

    refute ProjectContractEvidence.reconciliation_required?(unconfigured)
    assert unconfigured.configured_before? == false
    assert ProjectContractEvidence.reconciliation_required?(nil) == false

    configured = ProjectContractEvidence.new(contract!())

    assert configured.configured_before? == true
    assert ProjectContractEvidence.reconciliation_required?(configured)
    assert configured.reason == :provider_configuration_required
  end

  test "invalid evidence remains fenced and nil observability is explicit" do
    invalid = ProjectContractEvidence.new(:invalid)

    assert invalid.contract == nil
    assert invalid.reason == :invalid_provider_project_contract
    assert ProjectContractEvidence.reconciliation_required?(invalid)

    assert ProjectContractEvidence.observability(nil) == %{
             contract_present?: false,
             contract_fingerprint: nil,
             validation_status: nil,
             reconciliation_required?: false,
             reason: nil,
             diagnostics: []
           }
  end

  test "bootstrap reconfiguration and same-contract updates preserve evidence semantics" do
    bootstrap = ProjectContractEvidence.new(nil)
    contract = contract!()

    configured = ProjectContractEvidence.reconfigure(bootstrap, contract)
    assert configured.reason == :provider_configuration_required
    assert ProjectContractEvidence.reconciliation_required?(configured)

    unchanged = ProjectContractEvidence.reconfigure(configured, contract)
    assert unchanged == configured

    assert ProjectContractEvidence.apply_validation(bootstrap, validation(:valid, contract)) == bootstrap
  end

  test "removing an established contract remains fenced" do
    contract = contract!()
    pending = ProjectContractEvidence.reconfigure(nil, contract)

    removed = ProjectContractEvidence.reconfigure(pending, nil)

    assert removed.contract == nil
    assert removed.configured_before? == true
    assert ProjectContractEvidence.reconciliation_required?(removed)
    assert removed.reason == :provider_contract_removed

    drifted =
      pending
      |> ProjectContractEvidence.apply_validation(ProjectContract.validate(contract, Map.put(snapshot(), :project_id, "wrong-project")))

    removed_after_drift = ProjectContractEvidence.reconfigure(drifted, nil)
    assert removed_after_drift.contract == nil
    assert ProjectContractEvidence.reconciliation_required?(removed_after_drift)
    assert removed_after_drift.reason == :provider_contract_removed
  end

  test "configuration drift records mechanical evidence without owning authority" do
    contract = contract!()
    evidence = ProjectContractEvidence.new(contract)
    validation = ProjectContract.validate(contract, Map.put(snapshot(), :project_id, "project-recreated"))

    assert validation.status == :drift_detected
    drifted = ProjectContractEvidence.apply_validation(evidence, validation)

    assert drifted.validation == validation
    assert drifted.reason == :provider_configuration_drift
    assert ProjectContractEvidence.reconciliation_required?(drifted)
    assert drifted.configured_before? == true
  end

  test "only a fresh valid contract validation clears the mechanical guard" do
    contract = contract!()

    drifted =
      ProjectContractEvidence.new(contract)
      |> ProjectContractEvidence.apply_validation(ProjectContract.validate(contract, Map.put(snapshot(), :project_id, "wrong-project")))

    recovered =
      ProjectContractEvidence.apply_validation(
        drifted,
        ProjectContract.validate(contract, snapshot())
      )

    assert recovered.validation.status == :valid
    refute ProjectContractEvidence.reconciliation_required?(recovered)
    assert recovered.reason == nil
  end

  test "descriptive-only validation diagnostics remain valid evidence" do
    contract = contract!()
    fingerprint = ProviderProjectContract.fingerprint(contract)

    validation = %ProviderProjectContract.ValidationResult{
      status: :valid,
      diagnostics: [
        %ProviderProjectContract.Diagnostic{class: :descriptive_name_changed, field: :name}
      ],
      expected_fingerprint: fingerprint,
      observed_fingerprint: fingerprint
    }

    evidence = ProjectContractEvidence.apply_validation(ProjectContractEvidence.new(contract), validation)

    refute ProjectContractEvidence.reconciliation_required?(evidence)
    assert evidence.validation == validation
  end

  test "a valid result for an older contract cannot clear changed configuration evidence" do
    contract = contract!()
    changed_contract = %{contract | project_id: "project-2"}
    evidence = ProjectContractEvidence.reconfigure(nil, changed_contract)
    stale_valid = ProjectContract.validate(contract, snapshot())

    still_required = ProjectContractEvidence.apply_validation(evidence, stale_valid)

    assert ProjectContractEvidence.reconciliation_required?(still_required)
    assert still_required.reason == :provider_contract_validation_required
  end

  test "reconfiguration requires fresh reconciliation for changed contract semantics" do
    contract = contract!()
    changed_contract = %{contract | project_id: "project-2"}

    changed = ProjectContractEvidence.reconfigure(ProjectContractEvidence.new(contract), changed_contract)

    assert changed.contract == changed_contract
    assert changed.reason == :provider_configuration_changed
    assert ProjectContractEvidence.reconciliation_required?(changed)
  end

  test "non-valid and stale validation results remain mechanically fenced" do
    contract = contract!()
    evidence = ProjectContractEvidence.new(contract)

    for status <- [:snapshot_incomplete, :provider_malformed] do
      result = validation(status, contract)
      required = ProjectContractEvidence.apply_validation(evidence, result)

      assert ProjectContractEvidence.reconciliation_required?(required)
    end

    stale = ProjectContractEvidence.apply_validation(evidence, validation(:valid, nil))
    assert ProjectContractEvidence.reconciliation_required?(stale)

    assert ProjectContractEvidence.apply_validation(nil, validation(:valid, nil)).contract == nil
    assert ProjectContractEvidence.apply_validation(ProjectContractEvidence.new(nil), validation(:valid, nil)).contract == nil
    assert ProjectContractEvidence.apply_validation(evidence, :invalid).reason == :provider_contract_validation_required
  end

  test "a forged valid result with authority diagnostics cannot clear evidence" do
    contract = contract!()

    result = %{
      validation(:valid, contract)
      | diagnostics: [
          %ProviderProjectContract.Diagnostic{
            class: :project_identity_mismatch,
            field: :project_id
          }
        ]
    }

    evidence = ProjectContractEvidence.apply_validation(ProjectContractEvidence.new(contract), result)

    assert ProjectContractEvidence.reconciliation_required?(evidence)
    assert evidence.reason == :provider_contract_validation_required
  end

  test "observability bounds validation diagnostics" do
    evidence = %ProjectContractEvidence{
      contract: contract!(),
      validation: %ProviderProjectContract.ValidationResult{
        status: :drift_detected,
        diagnostics: [:unexpected]
      },
      reconciliation_required?: true,
      configured_before?: true,
      reason: :provider_configuration_drift
    }

    observed = ProjectContractEvidence.observability(evidence)

    assert observed.contract_present?
    assert observed.reconciliation_required?
    assert observed.reason == :provider_configuration_drift
    assert observed.diagnostics == [%{class: :invalid_diagnostic}]

    diagnostic_evidence = %{
      evidence
      | validation: %ProviderProjectContract.ValidationResult{
          status: :drift_detected,
          diagnostics: [
            %ProviderProjectContract.Diagnostic{
              class: :project_identity_mismatch,
              field: :project_id,
              expected: "project-1",
              observed: "project-2",
              reason: :test
            }
          ]
        }
    }

    assert ProjectContractEvidence.observability(diagnostic_evidence).diagnostics == [
             %{
               class: :project_identity_mismatch,
               field: :project_id,
               canonical_state: nil,
               capability: nil,
               expected: "project-1",
               observed: "project-2",
               reason: :test
             }
           ]

    valid =
      ProjectContractEvidence.apply_validation(
        ProjectContractEvidence.new(contract!()),
        validation(:valid, contract!())
      )

    valid_observed = ProjectContractEvidence.observability(valid)
    assert valid_observed.validation_status == :valid
    refute valid_observed.reconciliation_required?
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

  defp validation(status, contract) do
    fingerprint = if contract, do: ProviderProjectContract.fingerprint(contract)

    %ProviderProjectContract.ValidationResult{
      status: status,
      diagnostics: [],
      expected_fingerprint: fingerprint,
      observed_fingerprint: if(status == :valid, do: fingerprint)
    }
  end

  defp snapshot do
    groups = %{
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

    %{
      provider: :plane,
      workspace_id: "workspace-1",
      project_id: "project-1",
      states:
        Enum.map(@states, fn state ->
          %{id: "state-#{state}", group: Map.fetch!(groups, state), name: WorkflowLifecycle.display(state)}
        end),
      dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
      capability_statuses: Map.new(Capabilities.vocabulary(), &{&1, :supported}),
      completeness: :complete
    }
  end
end
