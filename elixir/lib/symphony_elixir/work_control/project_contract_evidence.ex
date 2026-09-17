defmodule SymphonyElixir.WorkControl.ProjectContractEvidence do
  @moduledoc """
  Mechanical evidence for a configured provider project contract.

  This value records contract validation and whether fresh reconciliation is
  required. It does not own autonomous authority or a suspension lifecycle;
  canonical `WorkItem` authority consumes the evidence as a guard.
  """

  alias SymphonyElixir.WorkControl.ProviderProjectContract

  defstruct contract: nil,
            validation: nil,
            reconciliation_required?: false,
            configured_before?: false,
            reason: nil

  @type t :: %__MODULE__{
          contract: ProviderProjectContract.t() | nil,
          validation: ProviderProjectContract.ValidationResult.t() | nil,
          reconciliation_required?: boolean(),
          configured_before?: boolean(),
          reason: atom() | nil
        }

  @spec new(nil | ProviderProjectContract.t()) :: t()
  def new(nil), do: %__MODULE__{}

  def new(%ProviderProjectContract{} = contract) do
    %__MODULE__{
      contract: contract,
      reconciliation_required?: true,
      configured_before?: true,
      reason: :provider_configuration_required
    }
  end

  def new(_invalid_contract) do
    %__MODULE__{
      reconciliation_required?: true,
      configured_before?: true,
      reason: :invalid_provider_project_contract
    }
  end

  @spec reconfigure(t() | nil, nil | ProviderProjectContract.t()) :: t()
  def reconfigure(nil, contract), do: new(contract)

  def reconfigure(%__MODULE__{} = evidence, nil) do
    if evidence.configured_before? do
      %{
        evidence
        | contract: nil,
          validation: nil,
          reconciliation_required?: true,
          configured_before?: true,
          reason: :provider_contract_removed
      }
    else
      new(nil)
    end
  end

  def reconfigure(%__MODULE__{} = evidence, %ProviderProjectContract{} = contract) do
    if same_contract?(evidence.contract, contract) do
      evidence
    else
      reason =
        if evidence.configured_before?,
          do: :provider_configuration_changed,
          else: :provider_configuration_required

      %{new(contract) | reason: reason}
    end
  end

  @spec apply_validation(t() | nil, ProviderProjectContract.ValidationResult.t()) :: t()
  def apply_validation(nil, _validation), do: new(nil)

  def apply_validation(%__MODULE__{contract: nil} = evidence, _validation), do: evidence

  def apply_validation(
        %__MODULE__{contract: %ProviderProjectContract{} = contract} = evidence,
        %ProviderProjectContract.ValidationResult{} = validation
      ) do
    expected_fingerprint = ProviderProjectContract.fingerprint(contract)

    cond do
      valid_validation?(validation, expected_fingerprint) ->
        %{
          evidence
          | validation: validation,
            reconciliation_required?: false,
            configured_before?: true,
            reason: nil
        }

      validation.status == :drift_detected ->
        mark_reconciliation_required(evidence, validation, :provider_configuration_drift)

      validation.status == :snapshot_incomplete ->
        mark_reconciliation_required(evidence, validation, :provider_contract_snapshot_incomplete)

      validation.status == :provider_malformed ->
        mark_reconciliation_required(evidence, validation, :provider_contract_provider_malformed)

      true ->
        mark_reconciliation_required(evidence, validation, :provider_contract_validation_required)
    end
  end

  def apply_validation(%__MODULE__{} = evidence, _invalid_validation) do
    mark_reconciliation_required(evidence, nil, :provider_contract_validation_required)
  end

  @spec reconciliation_required?(t() | nil) :: boolean()
  def reconciliation_required?(nil), do: false
  def reconciliation_required?(%__MODULE__{reconciliation_required?: required}), do: required
  def reconciliation_required?(_evidence), do: true

  @spec observability(t() | nil) :: map()
  def observability(nil) do
    %{
      contract_present?: false,
      contract_fingerprint: nil,
      validation_status: nil,
      reconciliation_required?: false,
      reason: nil,
      diagnostics: []
    }
  end

  def observability(%__MODULE__{} = evidence) do
    %{
      contract_present?: match?(%ProviderProjectContract{}, evidence.contract),
      contract_fingerprint: contract_fingerprint(evidence.contract),
      validation_status: validation_status(evidence.validation),
      reconciliation_required?: evidence.reconciliation_required?,
      reason: evidence.reason,
      diagnostics: validation_diagnostics(evidence.validation)
    }
  end

  defp same_contract?(%ProviderProjectContract{} = current, %ProviderProjectContract{} = next) do
    ProviderProjectContract.fingerprint(current) == ProviderProjectContract.fingerprint(next)
  end

  defp same_contract?(_current, _next), do: false

  defp valid_validation?(%ProviderProjectContract.ValidationResult{} = validation, expected_fingerprint) do
    validation.status == :valid and
      validation.expected_fingerprint == expected_fingerprint and
      validation.observed_fingerprint == expected_fingerprint and
      authority_safe_diagnostics?(validation)
  end

  defp authority_safe_diagnostics?(%{diagnostics: diagnostics}) when is_list(diagnostics) do
    Enum.all?(diagnostics, fn
      %ProviderProjectContract.Diagnostic{class: class} ->
        class in [:descriptive_name_changed, :optional_capability_unavailable]

      _diagnostic ->
        false
    end)
  end

  defp authority_safe_diagnostics?(_validation), do: false

  defp mark_reconciliation_required(%__MODULE__{} = evidence, validation, reason) do
    %{
      evidence
      | validation: validation,
        reconciliation_required?: true,
        configured_before?: true,
        reason: reason
    }
  end

  defp contract_fingerprint(nil), do: nil
  defp contract_fingerprint(contract), do: ProviderProjectContract.fingerprint(contract)

  defp validation_status(nil), do: nil
  defp validation_status(validation), do: validation.status

  defp validation_diagnostics(nil), do: []

  defp validation_diagnostics(%ProviderProjectContract.ValidationResult{diagnostics: diagnostics}) do
    Enum.map(diagnostics, &observability_diagnostic/1)
  end

  defp validation_diagnostics(_validation), do: [%{class: :invalid_validation}]

  defp observability_diagnostic(%ProviderProjectContract.Diagnostic{} = diagnostic) do
    %{
      class: diagnostic.class,
      field: diagnostic.field,
      canonical_state: diagnostic.canonical_state,
      capability: diagnostic.capability,
      expected: diagnostic.expected,
      observed: diagnostic.observed,
      reason: diagnostic.reason
    }
  end

  defp observability_diagnostic(_diagnostic), do: %{class: :invalid_diagnostic}
end
