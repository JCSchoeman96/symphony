defmodule SymphonyElixir.Plane.DependencyReader do
  @moduledoc """
  Acquires one complete Plane dependency graph epoch.

  This module only reads and normalizes provider data. Lifecycle authority stays
  in the existing WorkControl assessment and dependency policy modules.
  """

  alias SymphonyElixir.Dependency.Graph
  alias SymphonyElixir.Plane.{Client, StateProjection}
  alias SymphonyElixir.Tracker.Issue

  @max_concurrency 4
  @relation_task_timeout_ms 240_000
  @max_relation_entries 10_000
  @phase_transitions %{
    not_built: [:enumerating_items, :failed],
    enumerating_items: [:reading_relations, :failed],
    reading_relations: [:normalizing, :failed],
    normalizing: [:validating, :failed],
    validating: [:analyzing_cycles, :failed],
    analyzing_cycles: [:complete, :failed],
    complete: [],
    failed: []
  }

  @type acquisition_phase ::
          :not_built
          | :enumerating_items
          | :reading_relations
          | :normalizing
          | :validating
          | :analyzing_cycles
          | :complete
          | :failed

  @spec fetch(Client.config()) :: {:ok, Graph.t()} | {:error, term()}
  def fetch(config) when is_map(config), do: fetch(config, [])
  def fetch(_config), do: {:error, :provider_unavailable}

  @spec fetch(Client.config(), keyword()) :: {:ok, Graph.t()} | {:error, term()}
  def fetch(config, opts) when is_map(config) and is_list(opts) do
    acquisition = %{phase: :not_built}
    epoch_id = Keyword.get(opts, :epoch_id, Keyword.get(opts, :epoch, make_ref()))
    request_metrics = Keyword.get(opts, :request_metrics) || :atomics.new(2, signed: true)

    opts =
      opts
      |> Keyword.put(:epoch_id, epoch_id)
      |> Keyword.put(:request_metrics, request_metrics)

    with {:ok, config} <- validate_configuration(config),
         {:ok, acquisition} <- advance(acquisition, :enumerating_items),
         {:ok, opening_items} <- enumerate_items(config, opts),
         {:ok, opening_issues} <- project_items(opening_items, scope(config)),
         :ok <- ensure_unique_ids(opening_issues),
         {:ok, acquisition} <- advance(acquisition, :reading_relations),
         {:ok, observations} <- read_relations(config, opening_issues, opts),
         {:ok, acquisition} <- advance(acquisition, :normalizing),
         {:ok, edges} <- normalize_observations(observations),
         {:ok, acquisition} <- advance(acquisition, :validating),
         :ok <- validate_edges(edges, opening_issues),
         {:ok, closing_items} <- enumerate_items(config, opts),
         {:ok, closing_issues} <- project_items(closing_items, scope(config)),
         :ok <- ensure_unique_ids(closing_issues),
         :ok <- ensure_node_set_unchanged(opening_issues, closing_issues),
         {:ok, final_issues} <- apply_edges(closing_issues, edges),
         {:ok, acquisition} <- advance(acquisition, :analyzing_cycles),
         {:ok, graph} <- build_graph(final_issues, config, opts),
         true <- Graph.complete?(graph),
         {:ok, _complete} <- advance(acquisition, :complete) do
      {:ok, graph}
    else
      {:error, reason} ->
        _failed = advance(acquisition, :failed)
        {:error, normalize_failure(reason)}

      false ->
        _failed = advance(acquisition, :failed)
        {:error, :graph_incomplete}
    end
  end

  def fetch(_config, _opts), do: {:error, :provider_unavailable}

  @doc false
  @spec fetch_for_test(Client.config(), Client.request_fun(), keyword()) ::
          {:ok, Graph.t()} | {:error, term()}
  def fetch_for_test(config, request_fun, opts \\ [])
      when is_map(config) and is_function(request_fun, 1) and is_list(opts) do
    fetch(config, Keyword.put(opts, :request_fun, request_fun))
  end

  defp validate_configuration(config) do
    with :ok <- Client.validate_config(config),
         {:ok, workspace_slug} <- required_string(config, :workspace_slug),
         {:ok, workspace_id} <- required_string(config, :workspace_id),
         {:ok, project_id} <- required_string(config, :project_id),
         {:ok, api_key} <- required_string(config, :api_key) do
      {:ok,
       %{
         base_url: Map.get(config, :base_url, Client.default_base_url()),
         workspace_slug: workspace_slug,
         workspace_id: workspace_id,
         project_id: project_id,
         api_key: api_key
       }}
    else
      {:error, :invalid_scope} -> {:error, :item_enumeration_incomplete}
      {:error, :missing_credential} -> {:error, :provider_unavailable}
      {:error, :invalid_base_url} -> {:error, :provider_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp required_string(config, key) do
    case Map.get(config, key, Map.get(config, Atom.to_string(key))) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :invalid_scope}, else: {:ok, value}

      _value ->
        {:error, :invalid_scope}
    end
  end

  defp enumerate_items(config, opts) do
    case Client.list_work_items(config, client_opts(opts)) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:error, :snapshot_incomplete} -> {:error, :item_enumeration_incomplete}
      {:error, :provider_malformed} -> {:error, :item_enumeration_incomplete}
      {:error, {:rate_limited, _metadata}} -> {:error, :rate_limited}
      {:error, :provider_unavailable} -> {:error, :provider_unavailable}
      {:error, _reason} -> {:error, :item_enumeration_incomplete}
    end
  end

  defp project_items(raw_items, expected_scope) when is_list(raw_items) do
    Enum.reduce_while(raw_items, {:ok, []}, fn raw_item, {:ok, acc} ->
      case StateProjection.project_work_item(raw_item, expected_scope) do
        {:ok, projected} -> {:cont, {:ok, [issue_from_projection(projected) | acc]}}
        {:error, :wrong_project} -> {:halt, {:error, :item_enumeration_incomplete}}
        {:error, _reason} -> {:halt, {:error, :item_enumeration_incomplete}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_from_projection(projected) do
    %Issue{
      id: projected.id,
      native_ref: projected.native_ref,
      identifier: projected.identifier,
      title: projected.title,
      description: projected.description,
      priority: projected.priority,
      state: projected.state,
      branch_name: nil,
      url: projected.url,
      assignee_id: nil,
      workspace_id: projected.workspace_id,
      project_id: projected.project_id,
      provider_state_id: projected.provider_state_id,
      provider_state_group: projected.provider_state_group,
      blocked_by: projected.blocked_by,
      dependency_completeness: projected.dependency_completeness,
      labels: projected.labels,
      dispatchable: projected.dispatchable,
      created_at: projected.created_at,
      updated_at: projected.updated_at
    }
  end

  defp ensure_unique_ids(issues) do
    ids = Enum.map(issues, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, :duplicate_work_item}
  end

  defp read_relations(config, issues, opts) do
    task_opts = [
      ordered: false,
      max_concurrency: bounded_concurrency(opts),
      timeout: bounded_task_timeout(opts),
      on_timeout: :kill_task
    ]

    issues
    |> Task.async_stream(fn issue -> read_relation(config, issue, opts) end, task_opts)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, observations}}, {:ok, acc} -> {:cont, {:ok, [observations | acc]}}
      {:ok, {:error, reason}}, _acc -> {:halt, {:error, relation_failure(reason)}}
      {:exit, _reason}, _acc -> {:halt, {:error, :relation_read_failed}}
      _invalid, _acc -> {:halt, {:error, :relation_read_failed}}
    end)
    |> case do
      {:ok, observation_groups} -> {:ok, observation_groups |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp read_relation(config, %Issue{id: owner_id}, opts) do
    case Client.get_work_item_relations(config, owner_id, client_opts(opts)) do
      {:ok, body} -> parse_relation_body(owner_id, body, config.project_id)
      {:error, {:rate_limited, _metadata}} -> {:error, :rate_limited}
      {:error, :provider_unavailable} -> {:error, :provider_unavailable}
      {:error, :provider_malformed} -> {:error, :relation_malformed}
      {:error, :provider_response_too_large} -> {:error, :relation_read_failed}
      {:error, _reason} -> {:error, :relation_read_failed}
    end
  end

  defp parse_relation_body(owner_id, body, project_id) when is_map(body) do
    if paginated_relation_shape?(body) do
      {:error, :relation_shape_unsupported}
    else
      with {:ok, blocked_by} <- relation_group(body, :blocked_by),
           {:ok, blocking} <- relation_group(body, :blocking),
           :ok <- relation_fanout_limit(blocked_by, blocking),
           {:ok, blocked_observations} <- parse_group(owner_id, :blocked_by, blocked_by, project_id),
           {:ok, blocking_observations} <- parse_group(owner_id, :blocking, blocking, project_id) do
        {:ok, blocked_observations ++ blocking_observations}
      end
    end
  end

  defp relation_group(body, group) do
    case fetch_key(body, group) do
      {:ok, value} when is_list(value) ->
        {:ok, value}

      {:ok, value} when is_map(value) ->
        if paginated_relation_shape?(value),
          do: {:error, :relation_shape_unsupported},
          else: {:error, :relation_malformed}

      {:ok, _value} ->
        {:error, :relation_malformed}

      :missing ->
        if paginated_relation_shape?(body) do
          {:error, :relation_shape_unsupported}
        else
          {:error, :relation_malformed}
        end
    end
  end

  defp relation_fanout_limit(blocked_by, blocking) do
    if length(blocked_by) + length(blocking) <= @max_relation_entries,
      do: :ok,
      else: {:error, :relation_fanout_exceeded}
  end

  defp parse_group(owner_id, group, entries, project_id) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case relation_target(entry, project_id) do
        {:ok, target_id} ->
          {:cont, {:ok, [canonical_observation(group, owner_id, target_id) | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, Enum.reverse(observations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp relation_target(entry, project_id) when is_map(entry) do
    with {:ok, target_id} <- required_relation_string(entry, :issue_id),
         {:ok, target_project_id} <- required_relation_string(entry, :project_id),
         true <- target_project_id == project_id do
      {:ok, target_id}
    else
      false -> {:error, :cross_project_dependency}
      {:error, _reason} -> {:error, :relation_malformed}
    end
  end

  defp relation_target(_entry, _project_id), do: {:error, :relation_malformed}

  defp canonical_observation(:blocked_by, owner_id, target_id),
    do: %{prerequisite_id: target_id, dependent_id: owner_id}

  defp canonical_observation(:blocking, owner_id, target_id),
    do: %{prerequisite_id: owner_id, dependent_id: target_id}

  defp required_relation_string(map, key) do
    case fetch_key(map, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing}, else: {:ok, value}

      _ ->
        {:error, :missing}
    end
  end

  defp normalize_observations(observations) when is_list(observations) do
    observations
    |> Enum.map(&{&1.prerequisite_id, &1.dependent_id})
    |> Enum.uniq()
    |> Enum.sort()
    |> then(&{:ok, &1})
  rescue
    _error -> {:error, :relation_malformed}
  end

  defp validate_edges(edges, issues) do
    node_ids = issues |> Enum.map(& &1.id) |> MapSet.new()

    case Enum.find(edges, fn {prerequisite_id, dependent_id} ->
           not MapSet.member?(node_ids, prerequisite_id) or not MapSet.member?(node_ids, dependent_id)
         end) do
      nil -> :ok
      _edge -> {:error, :missing_dependency_target}
    end
  end

  defp apply_edges(issues, edges) do
    blocked_by =
      Enum.reduce(edges, %{}, fn {prerequisite_id, dependent_id}, acc ->
        Map.update(acc, dependent_id, [prerequisite_id], &[prerequisite_id | &1])
      end)

    facts = Map.new(issues, &{&1.id, &1})

    {:ok,
     Enum.map(issues, fn issue ->
       prerequisite_ids = blocked_by |> Map.get(issue.id, []) |> Enum.uniq() |> Enum.sort()

       %{issue | blocked_by: Enum.map(prerequisite_ids, &blocker_fact(facts[&1])), dependency_completeness: :complete}
     end)}
  rescue
    _error -> {:error, :missing_dependency_target}
  end

  defp blocker_fact(%Issue{} = issue), do: %{id: issue.id, identifier: issue.identifier, state: issue.state}

  defp ensure_node_set_unchanged(opening, closing) do
    opening_ids = opening |> Enum.map(& &1.id) |> MapSet.new()
    closing_ids = closing |> Enum.map(& &1.id) |> MapSet.new()

    if opening_ids == closing_ids, do: :ok, else: {:error, :node_set_changed}
  end

  defp build_graph(issues, config, opts) do
    graph =
      Graph.build(issues,
        source: :plane,
        scope: scope(config),
        epoch_id: Keyword.get(opts, :epoch_id),
        completeness: :complete,
        acquired_at: DateTime.utc_now(),
        on_scc: Keyword.get(opts, :on_scc)
      )

    if Graph.complete?(graph), do: {:ok, graph}, else: {:error, :graph_incomplete}
  end

  defp relation_failure(:rate_limited), do: :rate_limited
  defp relation_failure(:provider_unavailable), do: :provider_unavailable
  defp relation_failure(:relation_read_failed), do: :relation_read_failed
  defp relation_failure(:relation_fanout_exceeded), do: :relation_fanout_exceeded
  defp relation_failure(:relation_shape_unsupported), do: :relation_shape_unsupported
  defp relation_failure(:cross_project_dependency), do: :cross_project_dependency
  defp relation_failure(:missing_dependency_target), do: :missing_dependency_target
  defp relation_failure(_reason), do: :relation_malformed

  defp normalize_failure({:duplicate_work_item, _id}), do: :duplicate_work_item

  defp normalize_failure(reason)
       when reason in [
              :item_enumeration_incomplete,
              :duplicate_work_item,
              :relation_read_failed,
              :relation_malformed,
              :relation_fanout_exceeded,
              :relation_shape_unsupported,
              :cross_project_dependency,
              :missing_dependency_target,
              :node_set_changed,
              :provider_unavailable,
              :rate_limited,
              :graph_incomplete
            ],
       do: reason

  defp normalize_failure(_reason), do: :provider_unavailable

  defp client_opts(opts),
    do: Keyword.take(opts, [:request_fun, :request_metrics, :scheduler, :read_scheduler, :class, :epoch_id])

  defp bounded_concurrency(opts) do
    case Keyword.get(opts, :max_concurrency, @max_concurrency) do
      value when is_integer(value) and value > 0 -> min(value, @max_concurrency)
      _invalid -> @max_concurrency
    end
  end

  defp bounded_task_timeout(opts) do
    case Keyword.get(opts, :relation_task_timeout_ms, @relation_task_timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, @relation_task_timeout_ms)
      _invalid -> @relation_task_timeout_ms
    end
  end

  defp scope(config) do
    %{workspace_slug: config.workspace_slug, workspace_id: config.workspace_id, project_id: config.project_id}
  end

  defp fetch_key(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:ok, Map.get(map, string_key)}
      true -> :missing
    end
  end

  defp paginated_relation_shape?(body) do
    Enum.any?([:results, :next_page_results, :next_cursor, :count, :total_results], &Map.has_key?(body, &1)) or
      Enum.any?(["results", "next_page_results", "next_cursor", "count", "total_results"], &Map.has_key?(body, &1))
  end

  defp advance(%{phase: current} = acquisition, next) when is_map_key(@phase_transitions, current) do
    if next in Map.fetch!(@phase_transitions, current) do
      {:ok, %{acquisition | phase: next}}
    else
      {:error, :invalid_acquisition_transition}
    end
  end

  defp advance(_acquisition, _next), do: {:error, :invalid_acquisition_transition}
end
