defmodule SymphonyElixir.WorkControl.GuardClass do
  @moduledoc """
  Typed guard requirements used by canonical lifecycle transitions.

  Guard class is part of the requirement identity. Evidence from another class
  cannot satisfy the requirement, even when its name is the same.
  """

  @classes [:mechanical_guard, :semantic_attestation, :human_decision]

  @type class :: :mechanical_guard | :semantic_attestation | :human_decision
  @type requirement :: %{class: class(), name: atom()}
  @type evidence :: requirement()

  @spec classes() :: [class()]
  def classes, do: @classes

  @spec valid?(term()) :: boolean()
  def valid?(%{class: class, name: name}) when class in @classes and is_atom(name), do: true
  def valid?(_requirement), do: false

  @spec requirement(term(), term()) :: requirement() | nil
  def requirement(class, name) when class in @classes and is_atom(name) do
    %{class: class, name: name}
  end

  def requirement(_class, _name), do: nil

  @spec satisfied?(requirement(), term()) :: boolean()
  def satisfied?(%{class: class, name: name} = requirement, evidence)
      when class in @classes and is_atom(name) do
    evidence
    |> normalize_evidence()
    |> Enum.any?(fn
      %{class: ^class, name: ^name} -> true
      _other -> false
    end) and valid?(requirement)
  end

  def satisfied?(_requirement, _evidence), do: false

  @spec all_satisfied?([requirement()], term()) :: boolean()
  def all_satisfied?(requirements, evidence) when is_list(requirements) do
    Enum.all?(requirements, &satisfied?(&1, evidence))
  end

  def all_satisfied?(_requirements, _evidence), do: false

  @spec missing([requirement()], term()) :: [requirement()]
  def missing(requirements, evidence) when is_list(requirements) do
    Enum.reject(requirements, &satisfied?(&1, evidence))
  end

  def missing(_requirements, _evidence), do: []

  @spec classes_for([requirement()]) :: [class()]
  def classes_for(requirements) when is_list(requirements) do
    requirements
    |> Enum.filter(&valid?/1)
    |> Enum.map(& &1.class)
    |> Enum.uniq()
  end

  def classes_for(_requirements), do: []

  defp normalize_evidence(evidence) when is_list(evidence), do: evidence
  defp normalize_evidence(evidence) when is_map(evidence), do: [evidence]
  defp normalize_evidence(_evidence), do: []
end
