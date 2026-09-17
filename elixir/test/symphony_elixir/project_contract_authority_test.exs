defmodule SymphonyElixir.ProjectContractAuthorityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Plane.ProjectContract
  alias SymphonyElixir.Tracker.Capabilities

  alias SymphonyElixir.WorkControl.{
    ProjectContractAuthority,
    ProviderProjectContract,
    WorkflowLifecycle
  }

  @states WorkflowLifecycle.states()

  test "a configured contract remains fenced until fresh provider validation succeeds" do
    authority = ProjectContractAuthority.new(contract!())

    assert authority.status == :unvalidated
    refute ProjectContractAuthority.allowed?(authority)
    refute ProjectContractAuthority.suspended?(authority)
  end

  test "unconfigured, invalid, and removed contracts expose safe authority states" do
    unconfigured = ProjectContractAuthority.new(nil)

    assert unconfigured.status == :unconfigured
    assert ProjectContractAuthority.allowed?(unconfigured)
    assert ProjectContractAuthority.allowed?(nil)
    refute ProjectContractAuthority.suspended?(unconfigured)
    assert ProjectContractAuthority.observability(nil) == %{status: :unconfigured, suspension: nil}

    invalid = ProjectContractAuthority.new(:invalid)

    assert invalid.status == :suspended
    refute ProjectContractAuthority.allowed?(invalid)
    assert ProjectContractAuthority.suspended?(invalid)
    refute ProjectContractAuthority.allowed?(:invalid)

    contract = contract!()
    pending = ProjectContractAuthority.reconfigure(nil, contract)
    assert pending.status == :unvalidated

    from_unconfigured = ProjectContractAuthority.reconfigure(unconfigured, contract)
    assert from_unconfigured.status == :unvalidated

    removed = ProjectContractAuthority.reconfigure(pending, nil)
    assert removed.status == :unconfigured
    assert removed.suspension == nil

    assert ProjectContractAuthority.reconfigure(removed, nil).suspension == nil
  end

  test "configuration drift suspends local authority and preserves diagnostics" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)
    drifted_snapshot = Map.put(snapshot(), :project_id, "project-recreated")
    validation = ProjectContract.validate(contract, drifted_snapshot)

    assert validation.status == :drift_detected
    suspended = ProjectContractAuthority.apply_validation(authority, validation)

    assert suspended.status == :suspended
    refute ProjectContractAuthority.allowed?(suspended)
    assert suspended.suspension.status == :open
    assert suspended.suspension.reason == :provider_configuration_drift
    assert suspended.suspension.expected_fingerprint == validation.expected_fingerprint
    assert suspended.suspension.diagnostics != []

    repeated = ProjectContractAuthority.apply_validation(suspended, validation)
    assert repeated.status == :suspended
    assert repeated.suspension.opened_at == suspended.suspension.opened_at
  end

  test "only a fresh valid contract validation closes a drift suspension" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)

    suspended =
      authority
      |> ProjectContractAuthority.apply_validation(ProjectContract.validate(contract, Map.put(snapshot(), :project_id, "wrong-project")))

    assert suspended.status == :suspended

    recovered =
      ProjectContractAuthority.apply_validation(
        suspended,
        ProjectContract.validate(contract, snapshot())
      )

    assert recovered.status == :valid
    assert ProjectContractAuthority.allowed?(recovered)
    assert recovered.suspension.status == :resolved
    assert recovered.suspension.resolved_at != nil

    revalidated = ProjectContractAuthority.apply_validation(recovered, ProjectContract.validate(contract, snapshot()))
    assert revalidated.status == :valid
    assert revalidated.suspension.status == :resolved
  end

  test "a valid result for an older contract cannot clear suspension" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)

    suspended =
      authority
      |> ProjectContractAuthority.apply_validation(ProjectContract.validate(contract, Map.put(snapshot(), :project_id, "wrong-project")))

    changed_contract = %{contract | project_id: "project-2"}
    stale_valid = ProjectContract.validate(contract, snapshot())
    reconfigured = ProjectContractAuthority.reconfigure(suspended, changed_contract)
    still_suspended = ProjectContractAuthority.apply_validation(reconfigured, stale_valid)

    assert reconfigured.status == :unvalidated
    refute ProjectContractAuthority.allowed?(reconfigured)
    assert still_suspended.status == :suspended
    refute ProjectContractAuthority.allowed?(still_suspended)
    assert still_suspended.suspension.status == :open
  end

  test "reconfiguration fences a changed contract and preserves suspension evidence" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)
    changed_contract = %{contract | project_id: "project-2"}

    changed = ProjectContractAuthority.reconfigure(authority, changed_contract)

    assert changed.status == :unvalidated
    refute ProjectContractAuthority.allowed?(changed)
    assert changed.suspension.reason == :provider_configuration_changed

    drifted =
      ProjectContractAuthority.apply_validation(
        changed,
        ProjectContract.validate(changed_contract, Map.put(snapshot(), :project_id, "wrong-project"))
      )

    assert drifted.suspension.reason == :provider_configuration_drift
    opened_at = drifted.suspension.opened_at

    repeated_snapshot = Map.put(snapshot(), :project_id, "project-2")

    repeated =
      ProjectContractAuthority.apply_validation(
        drifted,
        ProjectContract.validate(changed_contract, repeated_snapshot)
      )

    assert repeated.status == :valid
    assert repeated.suspension.status == :resolved
    assert repeated.suspension.opened_at == opened_at
  end

  test "non-valid and stale validation results remain fenced" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)

    for {status, reason} <- [
          {:snapshot_incomplete, :provider_contract_snapshot_incomplete},
          {:provider_malformed, :provider_contract_provider_malformed}
        ] do
      result = validation(status, contract)
      suspended = ProjectContractAuthority.apply_validation(authority, result)

      assert suspended.status == :suspended
      assert suspended.suspension.reason == reason
    end

    stale = ProjectContractAuthority.apply_validation(authority, validation(:valid, nil))
    assert stale.status == :suspended
    assert stale.suspension.reason == :provider_contract_validation_required

    assert ProjectContractAuthority.apply_validation(nil, validation(:valid, nil)).status == :unconfigured
    assert ProjectContractAuthority.apply_validation(ProjectContractAuthority.new(nil), validation(:valid, nil)).status == :unconfigured
    assert ProjectContractAuthority.apply_validation(authority, :invalid).status == :suspended
  end

  test "a forged valid result with authority diagnostics cannot clear suspension" do
    contract = contract!()
    authority = ProjectContractAuthority.new(contract)

    result = %{
      validation(:valid, contract)
      | diagnostics: [
          %ProviderProjectContract.Diagnostic{
            class: :project_identity_mismatch,
            field: :project_id
          }
        ]
    }

    suspended = ProjectContractAuthority.apply_validation(authority, result)

    assert suspended.status == :suspended
    assert suspended.suspension.reason == :provider_contract_validation_required
  end

  test "observability bounds suspension diagnostics" do
    authority = %ProjectContractAuthority{
      contract: contract!(),
      status: :suspended,
      suspension: %ProjectContractAuthority.Suspension{
        status: :open,
        reason: :test,
        opened_at: DateTime.utc_now(),
        diagnostics: [:unexpected]
      }
    }

    observed = ProjectContractAuthority.observability(authority)

    assert observed.status == :suspended
    assert observed.validation_status == nil
    assert observed.suspension.diagnostics == [%{class: :invalid_diagnostic}]

    valid = ProjectContractAuthority.apply_validation(ProjectContractAuthority.new(contract!()), validation(:valid, contract!()))
    valid_observed = ProjectContractAuthority.observability(valid)
    assert valid_observed.validation_status == :valid
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
