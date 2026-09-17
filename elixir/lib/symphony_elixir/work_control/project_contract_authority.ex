defmodule SymphonyElixir.WorkControl.ProjectContractAuthority do
  @moduledoc """
  Symphony-owned authority state for a configured provider project contract.

  A configured contract is unusable until a fresh provider validation proves it
  valid. Validation drift opens a local suspension; no provider-side `Blocked`
  mutation is required to enforce the fence.
  """

  alias SymphonyElixir.WorkControl.ProviderProjectContract

  defmodule Suspension do
    @moduledoc "Local, operator-visible suspension evidence for contract authority."

    defstruct [
      :status,
      :reason,
      :opened_at,
      :resolved_at,
      :expected_fingerprint,
      :observed_fingerprint,
      :diagnostics
    ]

    @type status :: :open | :resolved
    @type t :: %__MODULE__{
            status: status(),
            reason: atom(),
            opened_at: DateTime.t(),
            resolved_at: DateTime.t() | nil,
            expected_fingerprint: String.t() | nil,
            observed_fingerprint: String.t() | nil,
            diagnostics: [ProviderProjectContract.Diagnostic.t()]
          }
  end

  defstruct contract: nil, status: :unconfigured, validation: nil, suspension: nil

  @type status :: :unconfigured | :unvalidated | :valid | :suspended
  @type t :: %__MODULE__{
          contract: ProviderProjectContract.t() | nil,
          status: status(),
          validation: ProviderProjectContract.ValidationResult.t() | nil,
          suspension: Suspension.t() | nil
        }

  @spec new(nil | ProviderProjectContract.t()) :: t()
  def new(nil), do: %__MODULE__{}

  def new(%ProviderProjectContract{} = contract) do
    %__MODULE__{contract: contract, status: :unvalidated}
  end

  def new(_invalid_contract) do
    %__MODULE__{
      status: :suspended,
      suspension: %Suspension{
        status: :open,
        reason: :invalid_provider_project_contract,
        opened_at: DateTime.utc_now(),
        diagnostics: []
      }
    }
  end

  @spec reconfigure(t() | nil, nil | ProviderProjectContract.t()) :: t()
  def reconfigure(nil, contract), do: new(contract)

  def reconfigure(%__MODULE__{} = authority, nil) do
    if authority.contract == nil do
      %{authority | status: :unconfigured, validation: nil, suspension: nil}
    else
      %{new(nil) | suspension: resolve_removed_contract_suspension(authority.suspension)}
    end
  end

  def reconfigure(%__MODULE__{} = authority, %ProviderProjectContract{} = contract) do
    if same_contract?(authority.contract, contract) do
      authority
    else
      %{
        new(contract)
        | suspension: open_suspension(:provider_configuration_changed, nil, authority.suspension)
      }
    end
  end

  @spec apply_validation(t(), ProviderProjectContract.ValidationResult.t()) :: t()
  def apply_validation(nil, _validation), do: new(nil)

  def apply_validation(%__MODULE__{contract: nil} = authority, _validation), do: authority

  def apply_validation(
        %__MODULE__{contract: %ProviderProjectContract{} = contract} = authority,
        %ProviderProjectContract.ValidationResult{} = validation
      ) do
    expected_fingerprint = ProviderProjectContract.fingerprint(contract)

    cond do
      valid_validation?(validation, expected_fingerprint) ->
        %{authority | status: :valid, validation: validation, suspension: resolve_suspension(authority.suspension)}

      validation.status == :drift_detected ->
        suspend(authority, :provider_configuration_drift, validation)

      validation.status == :snapshot_incomplete ->
        suspend(authority, :provider_contract_snapshot_incomplete, validation)

      validation.status == :provider_malformed ->
        suspend(authority, :provider_contract_provider_malformed, validation)

      true ->
        suspend(authority, :provider_contract_validation_required, validation)
    end
  end

  def apply_validation(%__MODULE__{} = authority, _invalid_validation) do
    suspend(authority, :provider_contract_validation_required, nil)
  end

  @spec allowed?(t() | nil) :: boolean()
  def allowed?(nil), do: true
  def allowed?(%__MODULE__{status: status}), do: status in [:unconfigured, :valid]
  def allowed?(_authority), do: false

  @spec suspended?(t() | nil) :: boolean()
  def suspended?(%__MODULE__{status: :suspended}), do: true
  def suspended?(_authority), do: false

  @spec observability(t() | nil) :: map()
  def observability(nil), do: %{status: :unconfigured, suspension: nil}

  def observability(%__MODULE__{} = authority) do
    %{
      status: authority.status,
      contract_fingerprint: contract_fingerprint(authority.contract),
      validation_status: validation_status(authority.validation),
      suspension: observability_suspension(authority.suspension)
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

  defp suspend(%__MODULE__{} = authority, reason, validation) do
    %{
      authority
      | status: :suspended,
        validation: validation,
        suspension: open_suspension(reason, validation, authority.suspension)
    }
  end

  defp open_suspension(reason, validation, %Suspension{status: :open} = previous) do
    if previous.reason == reason do
      %{
        previous
        | expected_fingerprint: validation_expected_fingerprint(validation, previous.expected_fingerprint),
          observed_fingerprint: validation_observed_fingerprint(validation, previous.observed_fingerprint),
          diagnostics: validation_diagnostics(validation)
      }
    else
      open_suspension(reason, validation, nil)
    end
  end

  defp open_suspension(reason, validation, previous) do
    %Suspension{
      status: :open,
      reason: reason,
      opened_at: DateTime.utc_now(),
      expected_fingerprint: validation_expected_fingerprint(validation, nil),
      observed_fingerprint: validation_observed_fingerprint(validation, nil),
      diagnostics: validation_diagnostics(validation)
    }
    |> preserve_opened_at(previous)
  end

  defp preserve_opened_at(suspension, %Suspension{status: :open, reason: reason} = previous)
       when reason == suspension.reason,
       do: %{suspension | opened_at: previous.opened_at}

  defp preserve_opened_at(suspension, _previous), do: suspension

  defp resolve_suspension(nil), do: nil

  defp resolve_suspension(%Suspension{status: :open} = suspension) do
    %{suspension | status: :resolved, resolved_at: DateTime.utc_now()}
  end

  defp resolve_suspension(%Suspension{} = suspension), do: suspension

  defp resolve_removed_contract_suspension(nil), do: nil

  defp resolve_removed_contract_suspension(%Suspension{} = previous) do
    %{
      previous
      | status: :resolved,
        reason: :provider_contract_removed,
        resolved_at: DateTime.utc_now()
    }
  end

  defp validation_expected_fingerprint(nil, fallback), do: fallback
  defp validation_expected_fingerprint(validation, _fallback), do: validation.expected_fingerprint

  defp validation_observed_fingerprint(nil, fallback), do: fallback
  defp validation_observed_fingerprint(validation, _fallback), do: validation.observed_fingerprint

  defp validation_diagnostics(nil), do: []
  defp validation_diagnostics(validation), do: validation.diagnostics

  defp contract_fingerprint(nil), do: nil
  defp contract_fingerprint(contract), do: ProviderProjectContract.fingerprint(contract)

  defp validation_status(nil), do: nil
  defp validation_status(validation), do: validation.status

  defp observability_suspension(nil), do: nil

  defp observability_suspension(%Suspension{} = suspension) do
    %{
      status: suspension.status,
      reason: suspension.reason,
      opened_at: suspension.opened_at,
      resolved_at: suspension.resolved_at,
      expected_fingerprint: suspension.expected_fingerprint,
      observed_fingerprint: suspension.observed_fingerprint,
      diagnostics: Enum.map(suspension.diagnostics, &observability_diagnostic/1)
    }
  end

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
