defmodule SymphonyElixir.Linear.AgentTool do
  @moduledoc """
  Provider-native Linear tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Dependency.{Graph, Guard}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Tracker.TransitionPolicy
  alias SymphonyElixir.WorkControl.{LifecycleAssessment, ProviderObservation, WorkflowLifecycle, WorkItem}

  @linear_graphql_tool "linear_graphql"
  @linear_transition_tool "linear_transition"
  @linear_graphql_description """
  Execute a read-only GraphQL query against Linear using Symphony's configured auth. Use
  `linear_transition` for workflow-controlled state changes.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Read-only GraphQL query document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @linear_transition_description """
  Move the current issue to an authorized workflow state using the responsibility and dependency
  decision bound to this agent session.
  """
  @linear_transition_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["targetState", "targetStateId"],
    "properties" => %{
      "targetState" => %{
        "type" => "string",
        "description" => "Workflow state name for the authorized handoff."
      },
      "targetStateId" => %{
        "type" => "string",
        "description" => "Linear workflow state ID returned by a read-only state query."
      }
    }
  }
  @transition_mutation """
  mutation SymphonyAuthorizedTransition($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """
  @transition_state_query """
  query SymphonyAuthorizedTransitionState($issueId: String!) {
    issue(id: $issueId) {
      team {
        states(first: 50) {
          nodes {
            id
            name
          }
          pageInfo {
            hasNextPage
          }
        }
      }
    }
  }
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @linear_transition_tool ->
        execute_linear_transition(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @linear_transition_tool,
        "description" => @linear_transition_description,
        "inputSchema" => @linear_transition_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- authorize_read_only_query(query),
         {:ok, response} <- linear_client.(query, variables, client_opts) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_transition(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
    client_opts = Keyword.take(opts, [:tracker_settings])
    context = Keyword.get(opts, :agent_tool_context, %{})
    routed? = routed?(opts)

    with {:ok, target_state, target_state_id} <- normalize_transition_arguments(arguments),
         {:ok, issue_id} <- normalize_issue_id(context),
         {:ok, trusted_state} <- require_trusted_lifecycle_context(context, routed?),
         :ok <-
           TransitionPolicy.authorize_intent(
             Map.merge(context, %{
               issue_id: issue_id,
               current_state: trusted_state,
               target_state: target_state
             })
           ),
         {:ok, state_response} <-
           linear_client.(@transition_state_query, %{"issueId" => issue_id}, client_opts),
         {:ok, ^target_state_id} <-
           verify_transition_state(state_response, target_state, target_state_id),
         :ok <-
           authorize_fresh_transition(
             context,
             issue_id,
             target_state,
             linear_client,
             client_opts,
             routed?
           ),
         :ok <- claim_transition(Keyword.get(opts, :transition_guard)),
         {:ok, response} <-
           linear_client.(@transition_mutation, %{"issueId" => issue_id, "stateId" => target_state_id}, client_opts) do
      transition_response(response)
    else
      {:error, %{code: _code} = reason} -> failure_response(transition_error_payload(reason))
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp authorize_fresh_transition(
         context,
         issue_id,
         target_state,
         linear_client,
         client_opts,
         routed?
       ) do
    tracker = Keyword.get_lazy(client_opts, :tracker_settings, fn -> Config.settings!().tracker end)

    with {:ok, issues} <-
           Client.fetch_dependency_graph(
             tracker_settings: tracker,
             graphql_fun: fn query, variables -> linear_client.(query, variables, client_opts) end
           ),
         %Issue{} = issue <- Enum.find(issues, &(&1.id == issue_id)) do
      graph = Graph.build(issues)
      responsibility = Map.get(context, :responsibility) || Map.get(context, "responsibility")

      decision =
        Guard.evaluate(issue, responsibility,
          active_states: tracker.active_states,
          terminal_states: tracker.terminal_states,
          work_control: dependency_work_control(context, issues)
        )

      decision =
        if Graph.incomplete?(graph, issue_id) or Graph.cyclic?(graph, issue_id) do
          Map.merge(decision, %{allowed?: false, merge_permitted?: false})
        else
          decision
        end

      case authorize_fresh_lifecycle(context, issue, routed?) do
        :ok ->
          TransitionPolicy.authorize(
            Map.merge(context, %{
              current_state: trusted_lifecycle_state(context, routed?),
              target_state: target_state,
              dependency_decision: decision
            })
          )

        {:error, _reason} = error ->
          error
      end
    else
      _ -> {:error, :transition_context_unavailable}
    end
  end

  defp authorize_fresh_lifecycle(context, %Issue{} = issue, true) do
    with {:ok, trusted_state} <- trusted_lifecycle_state_result(context, true),
         {:ok, observation} <- ProviderObservation.from_issue(issue, %{provider: :linear}),
         assessment <-
           LifecycleAssessment.assess(
             observation,
             trusted_state,
             Map.get(context, :guard_evidence, Map.get(context, :evidence, []))
           ),
         true <- LifecycleAssessment.validated?(assessment) do
      :ok
    else
      {:error, _reason} -> {:error, :canonical_work_item_required}
      false -> {:error, fresh_lifecycle_error(context, issue, true)}
    end
  end

  defp authorize_fresh_lifecycle(context, %Issue{} = issue, false) do
    with {:ok, trusted_state} <- trusted_lifecycle_state_result(context, false),
         {:ok, observation} <- ProviderObservation.from_issue(issue, %{provider: :linear}),
         {:ok, observed_state} <- ProviderObservation.map_legacy_state(observation),
         true <- observed_state == trusted_state do
      :ok
    else
      false -> {:error, :lifecycle_invalid}
      {:error, _reason} -> {:error, :canonical_work_item_required}
    end
  end

  defp fresh_lifecycle_error(context, issue, routed?) do
    case trusted_lifecycle_state_result(context, routed?) do
      {:ok, trusted_state} ->
        {:ok, observation} = ProviderObservation.from_issue(issue, %{provider: :linear})
        evidence = Map.get(context, :guard_evidence, Map.get(context, :evidence, []))
        assessment = LifecycleAssessment.assess(observation, trusted_state, evidence)

        cond do
          LifecycleAssessment.authority_reducing?(assessment) -> :lifecycle_authority_reducing
          LifecycleAssessment.validation_required?(assessment) -> :lifecycle_validation_required
          LifecycleAssessment.invalid?(assessment) -> :lifecycle_invalid
          true -> :lifecycle_invalid
        end

      {:error, _reason} ->
        :canonical_work_item_required
    end
  end

  defp trusted_lifecycle_state(context, routed?) do
    case trusted_lifecycle_state_result(context, routed?) do
      {:ok, state} -> state
      {:error, _reason} -> nil
    end
  end

  defp trusted_lifecycle_state_result(context, routed?) when is_map(context) do
    case Map.get(context, :work_item) do
      %WorkItem{} = work_item ->
        trusted_work_item_state(work_item)

      _ ->
        parse_trusted_lifecycle_state(context, routed?)
    end
  end

  defp parse_trusted_lifecycle_state(context, routed?) do
    case trusted_state_value(context, routed?) do
      nil ->
        {:error, :canonical_work_item_required}

      value ->
        with {:ok, observation} <-
               ProviderObservation.new(%{
                 provider: :linear,
                 work_item_id: "trusted-context",
                 provider_state_name: provider_state_name_for_value(value)
               }),
             {:ok, state} <- map_trusted_state(observation, routed?) do
          {:ok, state}
        else
          _error -> {:error, :canonical_work_item_required}
        end
    end
  end

  defp trusted_work_item_state(%WorkItem{
         lifecycle_assessment: assessment,
         validated_lifecycle_state: state
       }) do
    if LifecycleAssessment.validated?(assessment) do
      case WorkflowLifecycle.parse(state) do
        {:ok, canonical_state} -> {:ok, canonical_state}
        {:error, _reason} -> {:error, :invalid_work_item}
      end
    else
      {:error, :invalid_work_item}
    end
  end

  defp trusted_state_value(context, routed?) do
    Map.get(context, :trusted_lifecycle_state) ||
      Map.get(context, :current_lifecycle_state) ||
      raw_provider_state(context, routed?)
  end

  defp raw_provider_state(context, false), do: Map.get(context, :current_issue_state)
  defp raw_provider_state(_context, true), do: nil

  defp provider_state_name_for_value(value) when is_binary(value), do: value

  defp provider_state_name_for_value(value) when is_atom(value) do
    case WorkflowLifecycle.parse(value) do
      {:ok, state} -> WorkflowLifecycle.display(state)
      {:error, _reason} -> Atom.to_string(value)
    end
  end

  defp provider_state_name_for_value(_value), do: nil

  defp map_trusted_state(observation, true), do: ProviderObservation.map_state(observation)
  defp map_trusted_state(observation, false), do: ProviderObservation.map_legacy_state(observation)

  defp require_trusted_lifecycle_context(context, routed?) when is_map(context) do
    case trusted_lifecycle_state_result(context, routed?) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, :canonical_work_item_required}
    end
  end

  defp require_trusted_lifecycle_context(_context, _routed?), do: {:error, :canonical_work_item_required}

  defp routed?(opts) when is_list(opts) do
    Keyword.get(opts, :agent_routing, Config.settings!().agent.routing) == "routed"
  end

  defp dependency_work_control(context, issues) when is_map(context) and is_list(issues) do
    previous_work_control = Map.get(context, :work_control, %{})

    if is_map(previous_work_control) do
      Enum.reduce(issues, %{}, &refresh_dependency_work_item(&1, &2, previous_work_control))
    else
      %{}
    end
  end

  defp dependency_work_control(_context, _issues), do: %{}

  defp refresh_dependency_work_item(
         %Issue{id: issue_id} = issue,
         work_control,
         previous_work_control
       )
       when is_binary(issue_id) do
    previous = Map.get(previous_work_control, issue_id)

    opts = %{
      provider: :linear,
      prior_validated_lifecycle_state: prior_validated_state(previous),
      evidence: evidence_for_observation(issue, previous)
    }

    case WorkItem.from_issue(issue, opts) do
      {:ok, work_item} -> Map.put(work_control, issue_id, work_item)
      {:error, _reason} -> work_control
    end
  end

  defp refresh_dependency_work_item(_issue, work_control, _previous_work_control), do: work_control

  defp prior_validated_state(%WorkItem{validated_lifecycle_state: state}), do: state
  defp prior_validated_state(_previous), do: nil

  defp prior_guard_evidence(%WorkItem{lifecycle_assessment: assessment}),
    do: assessment.satisfied_guards

  defp evidence_for_observation(%Issue{state: state}, %WorkItem{} = previous) do
    case WorkflowLifecycle.parse(state) do
      {:ok, canonical_state} when canonical_state == previous.validated_lifecycle_state ->
        prior_guard_evidence(previous)

      _different_state ->
        []
    end
  end

  defp evidence_for_observation(_issue, _previous), do: []

  # Bound sessions share this guard across calls. Consume before sending the mutation:
  # a transport error can mean the provider committed it without returning a response.
  defp claim_transition(nil), do: :ok

  defp claim_transition(guard) do
    case :atomics.compare_exchange(guard, 1, 0, 1) do
      :ok -> :ok
      _ -> {:error, :transition_already_attempted}
    end
  end

  defp normalize_transition_arguments(arguments) when is_map(arguments) do
    with {:ok, target_state} <-
           normalize_required_string(arguments, ["targetState", "target_state", :targetState, :target_state]),
         {:ok, target_state_id} <-
           normalize_required_string(arguments, ["targetStateId", "target_state_id", :targetStateId, :target_state_id]) do
      {:ok, target_state, target_state_id}
    end
  end

  defp normalize_transition_arguments(_arguments), do: {:error, :invalid_transition_arguments}

  defp normalize_required_string(arguments, keys) do
    value = Enum.find_value(keys, &Map.get(arguments, &1))

    case value do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, :invalid_transition_arguments}, else: {:ok, trimmed}

      _ ->
        {:error, :invalid_transition_arguments}
    end
  end

  defp normalize_issue_id(context) when is_map(context) do
    case Map.get(context, :issue_id) || Map.get(context, "issue_id") do
      issue_id when is_binary(issue_id) ->
        issue_id = String.trim(issue_id)
        if issue_id == "", do: {:error, :invalid_transition_context}, else: {:ok, issue_id}

      _ ->
        {:error, :invalid_transition_context}
    end
  end

  defp normalize_issue_id(_context), do: {:error, :invalid_transition_context}

  defp authorize_read_only_query(query) do
    if Regex.match?(~r/(?<![A-Za-z0-9_])mutation(?![A-Za-z0-9_])/i, query) do
      {:error, :lifecycle_mutation_denied}
    else
      :ok
    end
  end

  defp transition_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        %{"data" => %{"issueUpdate" => %{"success" => true}}} -> true
        %{data: %{issueUpdate: %{success: true}}} -> true
        _ -> false
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp verify_transition_state(response, target_state, target_state_id) do
    cond do
      graphql_error_response?(response) ->
        {:error, :transition_state_unavailable}

      transition_state_verified?(response, target_state, target_state_id) ->
        {:ok, target_state_id}

      true ->
        {:error, :transition_state_unverified}
    end
  end

  defp graphql_error_response?(%{"errors" => errors}) when is_list(errors), do: errors != []
  defp graphql_error_response?(%{errors: errors}) when is_list(errors), do: errors != []
  defp graphql_error_response?(_response), do: false

  defp transition_state_verified?(response, target_state, target_state_id) do
    {nodes, page_info} = transition_state_connection(response)

    is_list(nodes) and page_info_complete?(page_info) and
      Enum.any?(nodes, &transition_state_matches?(&1, target_state, target_state_id))
  end

  defp transition_state_connection(%{"data" => %{"issue" => %{"team" => %{"states" => states}}}}),
    do: state_connection_values(states)

  defp transition_state_connection(%{data: %{issue: %{team: %{states: states}}}}),
    do: state_connection_values(states)

  defp transition_state_connection(_response), do: {nil, nil}

  defp state_connection_values(%{"nodes" => nodes, "pageInfo" => page_info}), do: {nodes, page_info}
  defp state_connection_values(%{nodes: nodes, pageInfo: page_info}), do: {nodes, page_info}
  defp state_connection_values(_states), do: {nil, nil}

  defp page_info_complete?(%{"hasNextPage" => false}), do: true
  defp page_info_complete?(%{hasNextPage: false}), do: true
  defp page_info_complete?(_page_info), do: false

  defp transition_state_matches?(state, target_state, target_state_id) when is_map(state) do
    state_id = Map.get(state, "id") || Map.get(state, :id)
    state_name = Map.get(state, "name") || Map.get(state, :name)

    state_id == target_state_id and
      is_binary(state_name) and normalize_state(state_name) == normalize_state(target_state)
  end

  defp transition_state_matches?(_state, _target_state, _target_state_id), do: false

  defp normalize_state(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_transition_arguments) do
    %{
      "error" => %{
        "code" => "invalid_transition_arguments",
        "message" => "`linear_transition` requires non-empty `targetState` and `targetStateId` strings."
      }
    }
  end

  defp tool_error_payload(:invalid_transition_context) do
    %{
      "error" => %{
        "code" => "invalid_transition_context",
        "message" => "`linear_transition` requires a bound current issue and agent responsibility."
      }
    }
  end

  defp tool_error_payload(:lifecycle_mutation_denied) do
    %{
      "error" => %{
        "code" => "lifecycle_mutation_denied",
        "message" => "Raw Linear GraphQL mutations are disabled; use linear_transition for workflow-controlled state changes."
      }
    }
  end

  defp tool_error_payload(:transition_state_unavailable) do
    %{
      "error" => %{
        "code" => "transition_state_unavailable",
        "message" => "The current issue workflow states could not be read safely; no transition was performed."
      }
    }
  end

  defp tool_error_payload(:transition_context_unavailable) do
    %{"error" => %{"code" => "transition_context_unavailable", "message" => "Current issue and dependency data could not be verified; no transition was performed."}}
  end

  defp tool_error_payload(:transition_already_attempted) do
    %{"error" => %{"code" => "transition_already_attempted", "message" => "This session has already attempted its workflow handoff; start a fresh attempt before another transition."}}
  end

  defp tool_error_payload(:transition_state_unverified) do
    %{
      "error" => %{
        "code" => "transition_state_unverified",
        "message" => "The requested Linear workflow state was not verified for the current issue; no transition was performed."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `tracker.provider.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp transition_error_payload(%{code: :invalid_transition_context}),
    do: tool_error_payload(:invalid_transition_context)

  defp transition_error_payload(%{code: :unauthorized_transition}) do
    %{
      "error" => %{
        "code" => "unauthorized_transition",
        "message" => "The active responsibility is not authorized for this workflow transition."
      }
    }
  end

  defp transition_error_payload(%{code: :dependency_transition_denied}) do
    %{
      "error" => %{
        "code" => "dependency_transition_denied",
        "message" => "The workflow transition is denied because dependency data is not safe for this handoff."
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
