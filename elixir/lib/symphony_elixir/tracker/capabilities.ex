defmodule SymphonyElixir.Tracker.Capabilities do
  @moduledoc """
  Local semantic capability contract for tracker adapters.

  Capabilities describe what an adapter is implemented and tested to support;
  they are not runtime responsibility grants and are never discovered through
  provider requests.
  """

  @type capability ::
          :current_issue_refresh
          | :dependency_graph
          | :dependency_completeness
          | :controlled_transition
          | :transition_verification
          | :agent_read_tools
          | :agent_transition_tools
          | :conditional_transition

  @vocabulary [
    :current_issue_refresh,
    :dependency_graph,
    :dependency_completeness,
    :controlled_transition,
    :transition_verification,
    :agent_read_tools,
    :agent_transition_tools,
    :conditional_transition
  ]

  @required_routed [
    :current_issue_refresh,
    :dependency_graph,
    :dependency_completeness,
    :controlled_transition,
    :transition_verification,
    :agent_read_tools,
    :agent_transition_tools
  ]

  @spec vocabulary() :: [capability()]
  def vocabulary, do: @vocabulary

  @spec required_routed() :: [capability()]
  def required_routed, do: @required_routed

  @spec validate_adapter(module()) :: {:ok, [capability()]} | {:error, term()}
  def validate_adapter(adapter) when is_atom(adapter) do
    with {:ok, declared} <- declared_by(adapter),
         :ok <- validate_structural_support(adapter, declared) do
      {:ok, declared}
    else
      {:error, _reason} = error ->
        {:error, {:invalid_provider_capability_declaration, adapter, elem(error, 1)}}
    end
  end

  @spec missing([capability()]) :: [capability()]
  def missing(declared) when is_list(declared) do
    Enum.reject(@required_routed, &(&1 in declared))
  end

  defp declared_by(adapter) do
    declared =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :capabilities, 0) do
        adapter.capabilities()
      else
        []
      end

    normalize_declaration(declared)
  end

  defp normalize_declaration(declared) when is_list(declared) do
    Enum.reduce_while(declared, {:ok, []}, fn capability, {:ok, normalized} ->
      cond do
        capability not in @vocabulary ->
          {:halt, {:error, {:unknown_capability, capability}}}

        capability in normalized ->
          {:halt, {:error, {:duplicate_capability, capability}}}

        true ->
          {:cont, {:ok, normalized ++ [capability]}}
      end
    end)
  end

  defp normalize_declaration(declared), do: {:error, {:invalid_capability_list, declared}}

  defp validate_structural_support(adapter, declared) do
    Enum.reduce_while(declared, :ok, fn capability, :ok ->
      case required_callback(capability) do
        nil ->
          {:cont, :ok}

        {function, arity} ->
          if function_exported?(adapter, function, arity) do
            {:cont, :ok}
          else
            {:halt, {:error, {:missing_callback, capability, function, arity}}}
          end
      end
    end)
  end

  defp required_callback(:current_issue_refresh), do: {:fetch_issues_by_ids, 1}
  defp required_callback(:dependency_graph), do: {:fetch_dependency_graph, 0}
  defp required_callback(:dependency_completeness), do: {:fetch_dependency_graph, 0}
  defp required_callback(:controlled_transition), do: {:execute_agent_tool, 3}
  defp required_callback(:agent_read_tools), do: {:agent_tool_specs, 0}
  defp required_callback(:agent_transition_tools), do: {:execute_agent_tool, 3}
  defp required_callback(_capability), do: nil
end
