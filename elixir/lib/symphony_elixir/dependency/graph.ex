defmodule SymphonyElixir.Dependency.Graph do
  @moduledoc """
  Deterministic inspection graph for normalized tracker dependency relations.

  Edges point from a dependent issue to each issue that blocks it. The graph
  never mutates tracker data and retains diagnostics for relations that cannot
  be represented safely.
  """

  alias SymphonyElixir.Tracker.Issue

  defstruct nodes: %{}, edges: %{}, reverse_edges: %{}, diagnostics: [], completeness: :complete

  @type completeness :: :complete | {:incomplete, term()} | {:unavailable, term()}

  @type diagnostic :: %{
          kind: atom(),
          dependent_id: String.t() | nil,
          blocker_id: String.t() | nil,
          blocker: term()
        }

  @type t :: %__MODULE__{
          nodes: %{String.t() => Issue.t()},
          edges: %{String.t() => [String.t()]},
          reverse_edges: %{String.t() => [String.t()]},
          diagnostics: [diagnostic()],
          completeness: completeness()
        }

  @spec build([Issue.t()]) :: t()
  def build(issues) when is_list(issues), do: build(issues, [])
  def build(_issues), do: %__MODULE__{completeness: {:incomplete, :invalid_issue_collection}}

  @spec build([Issue.t()], keyword()) :: t()
  def build(issues, opts) when is_list(issues) and is_list(opts) do
    {nodes, diagnostics} = collect_nodes(issues)
    diagnostics = diagnostics ++ incomplete_dependency_diagnostics(nodes)
    node_ids = nodes |> Map.keys() |> Enum.sort()

    {edges, diagnostics} =
      Enum.reduce(node_ids, {%{}, diagnostics}, fn issue_id, {edges, diagnostics} ->
        issue = nodes[issue_id]
        {blocker_ids, next_diagnostics} = dependency_edges(issue_id, issue.blocked_by, nodes)
        {Map.put(edges, issue_id, blocker_ids), diagnostics ++ next_diagnostics}
      end)

    reverse_edges = reverse_edges(node_ids, edges)

    %__MODULE__{
      nodes: nodes,
      edges: edges,
      reverse_edges: reverse_edges,
      diagnostics: sort_diagnostics(diagnostics),
      completeness: normalize_completeness(Keyword.get(opts, :completeness, :complete))
    }
  end

  def build(_issues, _opts), do: %__MODULE__{completeness: {:incomplete, :invalid_issue_collection}}

  @spec unavailable(term()) :: t()
  def unavailable(reason), do: %__MODULE__{completeness: {:unavailable, normalize_reason(reason)}}

  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{completeness: :complete}), do: true
  def complete?(%__MODULE__{}), do: false

  @spec incomplete?(t(), String.t()) :: boolean()
  def incomplete?(%__MODULE__{} = graph, issue_id) when is_binary(issue_id) do
    not is_nil(incompleteness_reason(graph, issue_id))
  end

  def incomplete?(_graph, _issue_id), do: true

  @spec incompleteness_reason(t(), String.t()) :: term() | nil
  def incompleteness_reason(%__MODULE__{completeness: {:unavailable, reason}}, _issue_id), do: {:unavailable, reason}
  def incompleteness_reason(%__MODULE__{completeness: {:incomplete, reason}}, _issue_id), do: {:incomplete, reason}

  def incompleteness_reason(%__MODULE__{} = graph, issue_id) when is_binary(issue_id) do
    cond do
      match?(%Issue{dependency_completeness: {:incomplete, _}}, graph.nodes[issue_id]) ->
        graph.nodes[issue_id].dependency_completeness

      match?(%Issue{dependency_completeness: {:unavailable, _}}, graph.nodes[issue_id]) ->
        graph.nodes[issue_id].dependency_completeness

      match?(%Issue{}, graph.nodes[issue_id]) ->
        if graph.nodes[issue_id].dependency_completeness == :complete do
          dependency_diagnostic_reason(graph, issue_id)
        else
          {:incomplete, :invalid_dependency_completeness}
        end

      true ->
        dependency_diagnostic_reason(graph, issue_id)
    end
  end

  def incompleteness_reason(_graph, _issue_id), do: {:incomplete, :invalid_issue_id}

  @spec cycles(t()) :: [[String.t()]]
  def cycles(%__MODULE__{} = graph) do
    graph
    |> strongly_connected_components()
    |> Enum.filter(&cyclic_component?(graph, &1))
    |> Enum.map(&Enum.sort/1)
    |> Enum.sort()
  end

  @spec cycle_members(t()) :: MapSet.t()
  def cycle_members(%__MODULE__{} = graph) do
    graph
    |> cycles()
    |> List.flatten()
    |> MapSet.new()
  end

  @spec cyclic?(t(), String.t()) :: boolean()
  def cyclic?(%__MODULE__{} = graph, issue_id) when is_binary(issue_id) do
    MapSet.member?(cycle_members(graph), issue_id)
  end

  def cyclic?(_graph, _issue_id), do: false

  defp collect_nodes(issues) do
    Enum.reduce(issues, {%{}, []}, fn
      %Issue{id: issue_id} = issue, {nodes, diagnostics}
      when is_binary(issue_id) and byte_size(issue_id) > 0 ->
        if Map.has_key?(nodes, issue_id) do
          {nodes,
           [
             diagnostic(:duplicate_issue, issue_id, nil, issue)
             | diagnostics
           ]}
        else
          {Map.put(nodes, issue_id, issue), diagnostics}
        end

      issue, {nodes, diagnostics} ->
        {nodes, [diagnostic(:malformed_issue, nil, nil, issue) | diagnostics]}
    end)
  end

  defp incomplete_dependency_diagnostics(nodes) when is_map(nodes) do
    nodes
    |> Enum.flat_map(fn
      {issue_id, %Issue{dependency_completeness: {:incomplete, reason}}} ->
        [diagnostic(:incomplete_dependency_data, issue_id, nil, reason)]

      {issue_id, %Issue{dependency_completeness: {:unavailable, reason}}} ->
        [diagnostic(:unavailable_dependency_data, issue_id, nil, reason)]

      _ ->
        []
    end)
  end

  defp incomplete_diagnostic?(kind) do
    kind in [
      :incomplete_dependency_data,
      :unavailable_dependency_data,
      :malformed_blocker,
      :malformed_blocker_list,
      :malformed_issue,
      :missing_blocker
    ]
  end

  defp dependency_diagnostic_reason(%__MODULE__{diagnostics: diagnostics}, issue_id) do
    diagnostics
    |> Enum.find(&(&1.dependent_id == issue_id and incomplete_diagnostic?(&1.kind)))
    |> case do
      %{kind: kind} -> {:incomplete, kind}
      nil -> nil
    end
  end

  defp normalize_completeness(:complete), do: :complete
  defp normalize_completeness({kind, reason}) when kind in [:incomplete, :unavailable], do: {kind, normalize_reason(reason)}
  defp normalize_completeness(reason), do: {:incomplete, normalize_reason(reason)}

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason({kind, _detail}) when is_atom(kind), do: kind
  defp normalize_reason(_reason), do: :unknown

  defp dependency_edges(dependent_id, blockers, nodes) when is_list(blockers) do
    Enum.reduce(blockers, {[], []}, fn blocker, {blocker_ids, diagnostics} ->
      case dependency_edge(dependent_id, blocker, nodes) do
        {:ok, blocker_id} -> {[blocker_id | blocker_ids], diagnostics}
        {:error, diagnostic} -> {blocker_ids, [diagnostic | diagnostics]}
      end
    end)
    |> then(fn {blocker_ids, diagnostics} ->
      {blocker_ids |> Enum.uniq() |> Enum.sort(), diagnostics}
    end)
  end

  defp dependency_edges(dependent_id, blockers, _nodes) do
    {[], [diagnostic(:malformed_blocker_list, dependent_id, nil, blockers)]}
  end

  defp dependency_edge(dependent_id, blocker, nodes) do
    case blocker_id(blocker) do
      {:ok, blocker_id} -> dependency_edge_for_id(dependent_id, blocker_id, blocker, nodes)
      :error -> {:error, diagnostic(:malformed_blocker, dependent_id, nil, blocker)}
    end
  end

  defp dependency_edge_for_id(_dependent_id, blocker_id, _blocker, nodes)
       when is_map_key(nodes, blocker_id),
       do: {:ok, blocker_id}

  defp dependency_edge_for_id(dependent_id, blocker_id, blocker, _nodes),
    do: {:error, diagnostic(:missing_blocker, dependent_id, blocker_id, blocker)}

  defp blocker_id(%{} = blocker) do
    id = Map.get(blocker, :id) || Map.get(blocker, "id")

    if is_binary(id) and String.trim(id) != "" do
      {:ok, id}
    else
      :error
    end
  end

  defp blocker_id(_blocker), do: :error

  defp reverse_edges(node_ids, edges) do
    reverse = Map.new(node_ids, &{&1, []})

    Enum.reduce(edges, reverse, fn {dependent_id, blocker_ids}, reverse_acc ->
      Enum.reduce(blocker_ids, reverse_acc, fn blocker_id, acc ->
        Map.update!(acc, blocker_id, &[dependent_id | &1])
      end)
    end)
    |> Map.new(fn {issue_id, dependents} -> {issue_id, Enum.sort(Enum.uniq(dependents))} end)
  end

  defp diagnostic(kind, dependent_id, blocker_id, blocker) do
    %{kind: kind, dependent_id: dependent_id, blocker_id: blocker_id, blocker: blocker}
  end

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn diagnostic ->
      {
        Atom.to_string(diagnostic.kind),
        diagnostic.dependent_id || "",
        diagnostic.blocker_id || ""
      }
    end)
  end

  defp strongly_connected_components(%__MODULE__{} = graph) do
    initial = %{
      next_index: 0,
      indexes: %{},
      lowlinks: %{},
      stack: [],
      on_stack: MapSet.new(),
      components: []
    }

    graph.nodes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(initial, fn issue_id, state ->
      if Map.has_key?(state.indexes, issue_id) do
        state
      else
        visit(issue_id, state, graph.edges)
      end
    end)
    |> Map.fetch!(:components)
  end

  defp visit(issue_id, state, edges) do
    index = state.next_index

    state = %{
      state
      | next_index: index + 1,
        indexes: Map.put(state.indexes, issue_id, index),
        lowlinks: Map.put(state.lowlinks, issue_id, index),
        stack: [issue_id | state.stack],
        on_stack: MapSet.put(state.on_stack, issue_id)
    }

    state =
      edges
      |> Map.get(issue_id, [])
      |> Enum.sort()
      |> Enum.reduce(state, fn neighbor, state_acc ->
        cond do
          not Map.has_key?(state_acc.indexes, neighbor) ->
            state_acc = visit(neighbor, state_acc, edges)
            lower = min(state_acc.lowlinks[issue_id], state_acc.lowlinks[neighbor])
            %{state_acc | lowlinks: Map.put(state_acc.lowlinks, issue_id, lower)}

          MapSet.member?(state_acc.on_stack, neighbor) ->
            lower = min(state_acc.lowlinks[issue_id], state_acc.indexes[neighbor])
            %{state_acc | lowlinks: Map.put(state_acc.lowlinks, issue_id, lower)}

          true ->
            state_acc
        end
      end)

    if state.lowlinks[issue_id] == state.indexes[issue_id] do
      {component, stack, on_stack} = pop_component(issue_id, state.stack, state.on_stack, [])

      %{
        state
        | stack: stack,
          on_stack: on_stack,
          components: [component | state.components]
      }
    else
      state
    end
  end

  defp pop_component(issue_id, [issue_id | rest], on_stack, component) do
    {[issue_id | component], rest, MapSet.delete(on_stack, issue_id)}
  end

  defp pop_component(issue_id, [head | rest], on_stack, component) do
    pop_component(issue_id, rest, MapSet.delete(on_stack, head), [head | component])
  end

  defp cyclic_component?(_graph, component) when length(component) > 1, do: true

  defp cyclic_component?(%__MODULE__{edges: edges}, [issue_id]) do
    issue_id in Map.get(edges, issue_id, [])
  end
end
