defmodule SymphonyElixir.OrchestratorProjectContractTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Capabilities

  alias SymphonyElixir.WorkControl.{
    ProjectContractAuthority,
    ProviderProjectContract,
    WorkflowLifecycle
  }

  @states WorkflowLifecycle.states()

  test "contract drift fences orchestrator authority without a provider mutation" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_authority: ProjectContractAuthority.new(contract)
    }

    validated = Orchestrator.reconcile_project_contract_for_test(state, snapshot())
    assert validated.project_contract_authority.status == :valid
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(validated)

    drifted =
      Orchestrator.reconcile_project_contract_for_test(
        validated,
        Map.put(snapshot(), :project_id, "project-recreated")
      )

    assert drifted.project_contract_authority.status == :suspended
    assert drifted.project_contract_authority.suspension.reason == :provider_configuration_drift
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(drifted)
  end

  test "contract suspension remains closed until revalidation of the current contract" do
    contract = contract!()

    state = %Orchestrator.State{
      attempt_ledger_status: :disabled,
      project_contract_authority: ProjectContractAuthority.new(contract)
    }

    suspended =
      state
      |> Orchestrator.reconcile_project_contract_for_test(snapshot())
      |> Orchestrator.reconcile_project_contract_for_test(Map.put(snapshot(), :project_id, "wrong-project"))

    assert suspended.project_contract_authority.status == :suspended
    refute Orchestrator.autonomous_dispatch_allowed_for_test?(suspended)

    recovered = Orchestrator.reconcile_project_contract_for_test(suspended, snapshot())

    assert recovered.project_contract_authority.status == :valid
    assert recovered.project_contract_authority.suspension.status == :resolved
    assert Orchestrator.autonomous_dispatch_allowed_for_test?(recovered)
  end

  test "public reconciliation call hands a trusted snapshot to the orchestrator" do
    name = String.to_atom("project-contract-orchestrator-#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    contract = contract!()

    :sys.replace_state(pid, fn state ->
      %{state | attempt_ledger_status: :disabled, project_contract_authority: ProjectContractAuthority.new(contract)}
    end)

    assert {:ok, %ProviderProjectContract.ValidationResult{status: :valid}} =
             Orchestrator.reconcile_project_contract(name, snapshot())

    assert :sys.get_state(pid).project_contract_authority.status == :valid
  end

  test "changing the configured contract stops running work and clears pending retries" do
    contract = contract!()
    retry_timer = Process.send_after(self(), :project_contract_retry, 60_000)

    state = %Orchestrator.State{
      project_contract_authority: ProjectContractAuthority.new(contract),
      running: %{
        "running-issue" => %{
          pid: nil,
          ref: nil,
          identifier: "RUNNING-1",
          started_at: DateTime.utc_now()
        }
      },
      retry_attempts: %{
        "retry-issue" => %{timer_ref: retry_timer}
      },
      claimed: MapSet.new(["running-issue", "retry-issue"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    changed = Orchestrator.reconfigure_project_contract_for_test(state, %{contract | project_id: "project-2"})

    assert changed.project_contract_authority.status == :unvalidated
    assert changed.running == %{}
    assert changed.retry_attempts == %{}
    assert changed.claimed == MapSet.new()
    assert changed.recent_attempts |> hd() |> Map.get(:termination_reason) == :provider_configuration_changed
    refute_receive :project_contract_retry, 0
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
