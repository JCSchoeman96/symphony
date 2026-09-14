defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @relation_page_query """
  query SymphonyLinearIssueRelations($issueId: ID!, $relationFirst: Int!, $after: String) {
    issue(id: $issueId) {
      inverseRelations(first: $relationFirst, after: $after) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @dependency_graph_query """
  query SymphonyLinearDependencyGraph($projectSlug: String!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      states ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(tracker.project_slug, states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- configured_tracker_for_read(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, tracker.project_slug, assignee_filter)
        end
    end
  end

  @spec fetch_dependency_graph() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_dependency_graph do
    with {:ok, tracker} <- configured_tracker_for_read(),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_dependency_graph(tracker.project_slug, assignee_filter)
    end
  end

  @doc "Reads the full graph using the provider settings captured by a bound tool session."
  @spec fetch_dependency_graph(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_dependency_graph(opts) when is_list(opts) do
    tracker = Keyword.fetch!(opts, :tracker_settings)
    graphql_fun = Keyword.get(opts, :graphql_fun, fn query, variables -> graphql(query, variables, opts) end)
    do_fetch_dependency_graph(tracker.project_slug, nil, graphql_fun)
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)

    request_fun =
      Keyword.get(opts, :request_fun, fn request_payload, headers ->
        post_graphql_request(request_payload, headers, tracker_settings.endpoint)
      end)

    with {:ok, headers} <- graphql_headers(tracker_settings),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, "test-project", nil, graphql_fun)
    end
  end

  @doc false
  @spec fetch_dependency_graph_for_test(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_dependency_graph_for_test(project_slug, graphql_fun)
      when is_binary(project_slug) and is_function(graphql_fun, 2) do
    do_fetch_dependency_graph(project_slug, nil, graphql_fun)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter, &graphql/2) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_fetch_dependency_graph(project_slug, assignee_filter),
    do: do_fetch_dependency_graph(project_slug, assignee_filter, &graphql/2)

  defp do_fetch_dependency_graph(project_slug, assignee_filter, graphql_fun)
       when is_binary(project_slug) and is_function(graphql_fun, 2) do
    do_fetch_dependency_graph_page(project_slug, assignee_filter, graphql_fun, nil, [])
  end

  defp do_fetch_dependency_graph_page(
         project_slug,
         assignee_filter,
         graphql_fun,
         after_cursor,
         acc_issues
       ) do
    case graphql_fun.(@dependency_graph_query, %{
           projectSlug: project_slug,
           first: @issue_page_size,
           relationFirst: @issue_page_size,
           after: after_cursor
         }) do
      {:ok, body} ->
        decode_dependency_graph_page(
          body,
          project_slug,
          assignee_filter,
          graphql_fun,
          acc_issues
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_dependency_graph_page(
         body,
         project_slug,
         assignee_filter,
         graphql_fun,
         acc_issues
       ) do
    with {:ok, issues, page_info} <-
           decode_linear_page_response(body, assignee_filter, graphql_fun) do
      updated_acc = prepend_page_issues(issues, acc_issues)
      continue_dependency_graph_page(project_slug, assignee_filter, graphql_fun, page_info, updated_acc)
    end
  end

  defp continue_dependency_graph_page(
         project_slug,
         assignee_filter,
         graphql_fun,
         page_info,
         acc_issues
       ) do
    case next_page_cursor(page_info) do
      {:ok, next_cursor} ->
        do_fetch_dependency_graph_page(
          project_slug,
          assignee_filter,
          graphql_fun,
          next_cursor,
          acc_issues
        )

      :done ->
        {:ok, finalize_paginated_issues(acc_issues)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, project_slug, assignee_filter) do
    do_fetch_issue_states(ids, project_slug, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, project_slug, assignee_filter, graphql_fun)
       when is_list(ids) and is_binary(project_slug) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, project_slug, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _project_slug, _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, project_slug, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           projectSlug: project_slug,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response_strict(body, assignee_filter, graphql_fun) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            project_slug,
            assignee_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers(tracker_settings) do
    case tracker_settings.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers, endpoint) do
    Req.post(endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response_strict(response, assignee_filter, graphql_fun) do
    decode_linear_response(response, assignee_filter, :error_on_malformed, graphql_fun)
  end

  defp decode_linear_response(
         %{"errors" => _errors},
         _assignee_filter,
         _malformed_policy,
         _graphql_fun
       ) do
    {:error, :linear_graphql_errors}
  end

  defp decode_linear_response(
         %{"data" => %{"issues" => %{"nodes" => nodes}}},
         assignee_filter,
         malformed_policy,
         graphql_fun
       )
       when is_list(nodes) and is_function(graphql_fun, 2) do
    with {:ok, normalized_nodes} <- normalize_issue_nodes(nodes, assignee_filter, graphql_fun) do
      malformed_count = Enum.count(normalized_nodes, &is_nil/1)

      case {malformed_policy, malformed_count > 0} do
        {:error_on_malformed, true} ->
          {:error, :linear_unknown_payload}

        {:drop_malformed, true} ->
          Logger.warning("Dropping malformed Linear issue records count=#{malformed_count}")
          {:ok, Enum.reject(normalized_nodes, &is_nil/1)}

        {:drop_malformed, false} ->
          {:ok, normalized_nodes}

        {_, false} ->
          {:ok, normalized_nodes}
      end
    end
  end

  defp decode_linear_response(_unknown, _assignee_filter, _malformed_policy, _graphql_fun) do
    {:error, :linear_unknown_payload}
  end

  defp normalize_issue_nodes(nodes, assignee_filter, graphql_fun) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case complete_issue_relations(node, graphql_fun) do
        {:ok, complete_node} ->
          {:cont, {:ok, [normalize_issue(complete_node, assignee_filter) | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => page_info
             }
           }
         },
         assignee_filter,
         graphql_fun
       ) do
    with {:ok, page_info} <- decode_issue_page_info(page_info),
         {:ok, issues} <-
           decode_linear_response(
             %{"data" => %{"issues" => %{"nodes" => nodes}}},
             assignee_filter,
             :drop_malformed,
             graphql_fun
           ) do
      {:ok, issues, page_info}
    end
  end

  defp decode_linear_page_response(response, _assignee_filter, graphql_fun)
       when is_function(graphql_fun, 2) do
    case response do
      %{"errors" => _errors} ->
        {:error, :linear_graphql_errors}

      _ ->
        {:error, :linear_missing_page_info}
    end
  end

  defp decode_issue_page_info(%{"hasNextPage" => has_next_page, "endCursor" => end_cursor})
       when is_boolean(has_next_page) do
    case next_page_cursor(%{has_next_page: has_next_page, end_cursor: end_cursor}) do
      {:ok, _cursor} ->
        {:ok, %{has_next_page: true, end_cursor: end_cursor}}

      :done ->
        {:ok, %{has_next_page: false, end_cursor: end_cursor}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_issue_page_info(_page_info), do: {:error, :linear_missing_page_info}

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp complete_issue_relations(%{"id" => issue_id, "inverseRelations" => relation_connection} = issue, graphql_fun)
       when is_binary(issue_id) and is_function(graphql_fun, 2) do
    case relation_connection_page(relation_connection) do
      {:ok, %{has_next_page: true, end_cursor: end_cursor, nodes: nodes}} ->
        fetch_relation_pages(issue, nodes, end_cursor, graphql_fun)

      {:ok, _page} ->
        {:ok, issue}

      {:error, _reason} ->
        {:ok, issue}
    end
  end

  defp complete_issue_relations(issue, _graphql_fun), do: {:ok, issue}

  defp fetch_relation_pages(issue, nodes, after_cursor, graphql_fun) do
    case graphql_fun.(@relation_page_query, %{
           issueId: issue["id"],
           relationFirst: @issue_page_size,
           after: after_cursor
         }) do
      {:ok, %{"data" => %{"issue" => %{"inverseRelations" => relation_connection}}}} ->
        case relation_connection_page(relation_connection) do
          {:ok, %{has_next_page: true, end_cursor: next_cursor, nodes: next_nodes}} ->
            fetch_relation_pages(issue, nodes ++ next_nodes, next_cursor, graphql_fun)

          {:ok, %{has_next_page: false, nodes: final_nodes}} ->
            {:ok,
             Map.put(issue, "inverseRelations", %{
               "nodes" => nodes ++ final_nodes,
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             })}

          {:error, reason} ->
            {:error, {:linear_relation_response, reason}}
        end

      {:ok, %{"errors" => _errors}} ->
        {:error, {:linear_relation_response, :linear_graphql_errors}}

      {:ok, _body} ->
        {:error, {:linear_relation_response, :linear_unknown_payload}}

      {:error, reason} ->
        {:error, {:linear_relation_request, reason}}
    end
  end

  defp relation_connection_page(%{"nodes" => nodes, "pageInfo" => page_info}) when is_list(nodes) do
    with {:ok, %{has_next_page: has_next_page, end_cursor: end_cursor}} <-
           decode_relation_page_info(page_info) do
      {:ok,
       %{
         nodes: nodes,
         has_next_page: has_next_page,
         end_cursor: end_cursor
       }}
    end
  end

  defp relation_connection_page(%{"nodes" => _nodes}),
    do: {:error, :missing_relation_page_info}

  defp relation_connection_page(%{"pageInfo" => _page_info}),
    do: {:error, :missing_relation_nodes}

  defp relation_connection_page(_connection), do: {:error, :missing_relation_connection}

  defp decode_relation_page_info(%{"hasNextPage" => has_next_page, "endCursor" => end_cursor})
       when is_boolean(has_next_page) do
    case next_page_cursor(%{has_next_page: has_next_page, end_cursor: end_cursor}) do
      {:ok, _cursor} ->
        {:ok, %{has_next_page: true, end_cursor: end_cursor}}

      :done ->
        {:ok, %{has_next_page: false, end_cursor: end_cursor}}

      {:error, reason} ->
        {:error, relation_completeness_reason(reason)}
    end
  end

  defp decode_relation_page_info(_page_info), do: {:error, :missing_relation_page_info}

  defp relation_completeness(%{"inverseRelations" => %{"nodes" => nodes, "pageInfo" => page_info}})
       when is_list(nodes) do
    with {:ok, %{has_next_page: false}} <- decode_relation_page_info(page_info),
         :ok <- validate_relation_nodes(nodes) do
      :complete
    else
      {:ok, %{has_next_page: true}} -> {:incomplete, :relation_page_truncated}
      {:error, reason} -> {:incomplete, relation_completeness_reason(reason)}
      {:incomplete, reason} -> {:incomplete, reason}
    end
  end

  defp relation_completeness(%{"inverseRelations" => %{"nodes" => _nodes}}),
    do: {:incomplete, :missing_relation_page_info}

  defp relation_completeness(%{"inverseRelations" => %{"pageInfo" => _page_info}}),
    do: {:incomplete, :missing_relation_nodes}

  defp relation_completeness(%{"inverseRelations" => _connection}),
    do: {:incomplete, :malformed_relation_connection}

  defp relation_completeness(_issue), do: {:incomplete, :missing_relation_connection}

  defp relation_completeness_reason(:linear_missing_end_cursor), do: :missing_relation_end_cursor
  defp relation_completeness_reason(:missing_relation_page_info), do: :missing_relation_page_info
  defp relation_completeness_reason(:missing_relation_nodes), do: :missing_relation_nodes
  defp relation_completeness_reason(reason), do: reason

  defp validate_relation_nodes(nodes) when is_list(nodes) do
    Enum.reduce_while(nodes, :ok, fn
      %{"type" => relation_type, "issue" => issue}, :ok
      when is_binary(relation_type) and is_map(issue) ->
        if valid_relation_issue?(issue) do
          {:cont, :ok}
        else
          {:halt, {:error, :malformed_relation}}
        end

      _relation, :ok ->
        {:halt, {:error, :malformed_relation}}
    end)
  end

  defp validate_relation_nodes(_nodes), do: {:error, :missing_relation_nodes}

  defp valid_relation_issue?(issue) when is_map(issue) do
    present_string?(issue["id"]) and
      present_string?(issue["identifier"]) and
      present_string?(get_in(issue, ["state", "name"]))
  end

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    state_name = get_in(issue, ["state", "name"])

    if Enum.all?([issue["id"], issue["identifier"], issue["title"], state_name], &present_string?/1) do
      assignee = issue["assignee"]
      {blockers, dependency_completeness} = extract_relation_data(issue)

      %Issue{
        id: issue["id"],
        identifier: issue["identifier"],
        title: issue["title"],
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: state_name,
        branch_name: issue["branchName"],
        url: issue["url"],
        assignee_id: assignee_field(assignee, "id"),
        blocked_by: blockers,
        dependency_completeness: dependency_completeness,
        labels: extract_labels(issue),
        dispatchable: dispatchable?(state_name, blockers, assignee, assignee_filter),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp extract_relation_data(issue) do
    blockers = extract_blockers(issue)

    case relation_completeness(issue) do
      :complete -> {blockers, :complete}
      {:incomplete, reason} -> {blockers, {:incomplete, reason}}
    end
  end

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp dispatchable?(_state_name, _blockers, assignee, assignee_filter) do
    assigned_to_worker?(assignee, assignee_filter)
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp configured_tracker_for_read do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) -> {:error, :missing_linear_api_token}
      is_nil(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> {:ok, tracker}
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" and
             valid_relation_issue?(blocker_issue) do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
