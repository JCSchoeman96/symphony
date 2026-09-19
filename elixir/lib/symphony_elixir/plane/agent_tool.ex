defmodule SymphonyElixir.Plane.AgentTool do
  @moduledoc """
  Host-owned semantic Plane tools for one trusted routed work item.

  The tools read canonical state held by the orchestrator. Lifecycle requests
  delegate to the host-owned transition coordinator and never accept provider
  transport details from the runtime.
  """

  alias SymphonyElixir.AgentRuntime.{Authority, Route}
  alias SymphonyElixir.Dependency.Policy
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker

  alias SymphonyElixir.WorkControl.{
    AuthorityDisposition,
    GuardClass,
    LifecycleAssessment,
    ProviderObservation,
    ProviderProjectContract,
    WorkflowLifecycle,
    WorkItem
  }

  @current_work_item_tool "plane_get_current_work_item"
  @dependencies_tool "plane_get_dependencies"
  @lifecycle_assessment_tool "plane_get_lifecycle_assessment"
  @authority_disposition_tool "plane_get_authority_disposition"
  @transition_request_tool "plane_request_lifecycle_transition"

  @read_tool_names [
    @current_work_item_tool,
    @dependencies_tool,
    @lifecycle_assessment_tool,
    @authority_disposition_tool
  ]

  @all_tool_names @read_tool_names ++ [@transition_request_tool]

  @empty_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{}
  }

  @transition_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["targetState"],
    "properties" => %{
      "targetState" => %{
        "type" => "string",
        "description" => "Canonical lifecycle state requested by the current responsibility."
      }
    }
  }

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    structural_specs()
  end

  @spec agent_tool_specs(map()) :: [map()]
  def agent_tool_specs(context) when is_map(context) do
    case trusted_route(context) do
      {:ok, route} -> scoped_specs(route)
      {:error, _reason} -> []
    end
  end

  def agent_tool_specs(_context), do: []

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@current_work_item_tool, arguments, opts) do
    execute_read(@current_work_item_tool, arguments, opts)
  end

  def execute(@dependencies_tool, arguments, opts) do
    execute_read(@dependencies_tool, arguments, opts)
  end

  def execute(@lifecycle_assessment_tool, arguments, opts) do
    execute_read(@lifecycle_assessment_tool, arguments, opts)
  end

  def execute(@authority_disposition_tool, arguments, opts) do
    execute_read(@authority_disposition_tool, arguments, opts)
  end

  def execute(@transition_request_tool, arguments, opts) when is_list(opts) do
    execute_transition(arguments, opts)
  end

  def execute(_tool, _arguments, _opts) do
    unsupported_response()
  end

  defp structural_specs do
    read_specs() ++ [transition_spec(@transition_input_schema)]
  end

  defp scoped_specs(%Route{} = route) do
    specs = read_specs()
    targets = permitted_targets(route)

    if targets == [] do
      specs
    else
      specs ++ [transition_spec(transition_input_schema(targets))]
    end
  end

  defp read_specs do
    [
      %{
        "name" => @current_work_item_tool,
        "description" => "Read the current canonical Plane work item from Symphony.",
        "inputSchema" => @empty_input_schema
      },
      %{
        "name" => @dependencies_tool,
        "description" => "Read the current complete dependency decision for the Plane work item.",
        "inputSchema" => @empty_input_schema
      },
      %{
        "name" => @lifecycle_assessment_tool,
        "description" => "Read the current canonical lifecycle assessment for the Plane work item.",
        "inputSchema" => @empty_input_schema
      },
      %{
        "name" => @authority_disposition_tool,
        "description" => "Read the current autonomous authority disposition for the Plane work item.",
        "inputSchema" => @empty_input_schema
      }
    ]
  end

  defp transition_spec(input_schema) do
    %{
      "name" => @transition_request_tool,
      "description" => "Request a responsibility-authorized Plane lifecycle transition.",
      "inputSchema" => input_schema
    }
  end

  defp transition_input_schema(targets) when is_list(targets) do
    put_in(@transition_input_schema, ["properties", "targetState", "enum"], targets)
  end

  defp permitted_targets(%Route{} = route) do
    WorkflowLifecycle.states()
    |> Enum.filter(fn target ->
      Enum.any?(WorkflowLifecycle.states(), fn source ->
        Authority.authorize_lifecycle_command(route, source, target) == :ok
      end)
    end)
    |> Enum.map(&WorkflowLifecycle.display/1)
  end

  defp trusted_route(%{route: %Route{} = route}) do
    if valid_route?(route), do: {:ok, route}, else: {:error, :invalid_route}
  end

  defp trusted_route(_context), do: {:error, :missing_route}

  defp valid_route?(%Route{} = route) do
    case Authority.authorize_lifecycle_command(route, :backlog, :planning) do
      :ok -> true
      {:error, %{code: :not_permitted}} -> true
      _other -> false
    end
  end

  defp execute_read(tool, arguments, opts) when is_list(opts) do
    with :ok <- validate_empty_arguments(arguments),
         {:ok, context} <- trusted_context(opts),
         {:ok, payload} <- read_payload(tool, context) do
      success_response(payload)
    else
      {:error, reason} -> failure_response(reason)
    end
  end

  defp execute_read(_tool, _arguments, _opts), do: failure_response(:invalid_options)

  defp validate_empty_arguments(%{} = arguments) do
    if map_size(arguments) == 0, do: :ok, else: {:error, :invalid_arguments}
  end

  defp validate_empty_arguments(_arguments), do: {:error, :invalid_arguments}

  defp execute_transition(arguments, opts) do
    with {:ok, target} <- normalize_transition_arguments(arguments),
         {:ok, host_context} <- valid_host_context(Keyword.get(opts, :agent_tool_context)),
         {:ok, route} <- trusted_route(host_context),
         {:ok, route_source} <- route_source(route),
         :ok <- Authority.authorize_lifecycle_command(route, route_source, target),
         {:ok, context} <- trusted_context(opts),
         {:ok, work_item} <- fetch_work_item(context),
         {:ok, source} <- work_item_source(work_item),
         :ok <- Authority.authorize_lifecycle_command(route, source, target),
         {:ok, result} <- request_transition(work_item, route, source, target, host_context, opts) do
      transition_result_response(result, target)
    else
      {:error, reason} -> transition_failure_response(reason)
    end
  end

  defp normalize_transition_arguments(arguments) when is_map(arguments) do
    if map_size(arguments) == 1 do
      normalize_transition_target(Map.get(arguments, "targetState"))
    else
      {:error, :invalid_transition_arguments}
    end
  end

  defp normalize_transition_arguments(_arguments), do: {:error, :invalid_transition_arguments}

  defp normalize_transition_target(target_state) when is_binary(target_state) do
    target_state = String.trim(target_state)

    if target_state == "" do
      {:error, :invalid_transition_arguments}
    else
      parse_and_validate_transition_target(target_state)
    end
  end

  defp normalize_transition_target(_target_state), do: {:error, :invalid_transition_arguments}

  defp parse_and_validate_transition_target(target_state) do
    case parse_transition_target(target_state) do
      {:ok, target} ->
        {:ok, target}

      {:error, _reason} ->
        {:error, :invalid_target_state}
    end
  end

  defp parse_transition_target(target_state) when is_binary(target_state),
    do: WorkflowLifecycle.parse(target_state)

  defp route_source(%Route{starting_state: starting_state}) do
    case WorkflowLifecycle.parse(starting_state) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp work_item_source(%WorkItem{validated_lifecycle_state: state}) do
    case WorkflowLifecycle.parse(state) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp request_transition(
         %WorkItem{id: work_item_id},
         %Route{} = route,
         source,
         target,
         host_context,
         opts
       ) do
    intent_attrs = %{
      work_item_id: work_item_id,
      requested_from: source,
      requested_to: target,
      responsibility: route.responsibility,
      guard_evidence: host_guard_evidence(host_context)
    }

    transition_opts =
      [route: route, intent_attrs: intent_attrs]
      |> maybe_put_transition_option(opts, :coordinator)

    try do
      case Tracker.controlled_transition(work_item_id, target, transition_opts) do
        {:ok, _attempt} = result -> {:ok, result}
        {:error, _reason} = error -> error
      end
    rescue
      _error -> {:error, :coordinator_unavailable}
    catch
      _kind, _reason -> {:error, :coordinator_unavailable}
    end
  end

  defp host_guard_evidence(context) when is_map(context) do
    case Map.get(context, :guard_evidence) do
      evidence when is_list(evidence) -> evidence
      evidence when is_map(evidence) -> [evidence]
      _missing -> []
    end
  end

  defp maybe_put_transition_option(options, opts, key) do
    case Keyword.get(opts, key) do
      nil -> options
      value -> Keyword.put(options, key, value)
    end
  end

  defp transition_result_response({:ok, %{state: :verified}}, target) do
    success_response(%{
      "status" => "verified",
      "targetState" => WorkflowLifecycle.display(target)
    })
  end

  defp transition_result_response({:ok, %{state: state, outcome_reason: reason}}, target)
       when state in [:rejected, :conflict, :provider_failed, :indeterminate] do
    transition_terminal_response(state, reason, target)
  end

  defp transition_result_response({:ok, %{state: state}}, target)
       when state in [
              :requested,
              :intent_authorized,
              :fresh_context_loaded,
              :prepared,
              :mutation_submitted,
              :verifying
            ] do
    transition_terminal_response(:indeterminate, :non_terminal_result, target)
  end

  defp transition_result_response(_result, _target),
    do: transition_failure_response(:invalid_transition_result)

  defp transition_terminal_response(state, reason, _target) do
    status = Atom.to_string(state)
    code = transition_reason_code(state, reason)

    tool_response(false, %{
      "error" => %{
        "code" => code,
        "message" => "Plane lifecycle transition was rejected.",
        "status" => status
      }
    })
  end

  defp transition_failure_response(reason) do
    tool_response(false, %{
      "error" => %{
        "code" => transition_reason_code(:rejected, reason),
        "message" => "Plane lifecycle transition was rejected."
      }
    })
  end

  defp transition_reason_code(_state, :required_guard_missing), do: "required_guard_missing"

  defp transition_reason_code(_state, :dependency_context_unavailable),
    do: "dependency_context_unavailable"

  defp transition_reason_code(_state, :transitions_disabled), do: "transitions_disabled"
  defp transition_reason_code(_state, :transition_in_progress), do: "transition_in_progress"
  defp transition_reason_code(_state, :transition_fenced), do: "transition_fenced"
  defp transition_reason_code(_state, :coordinator_unavailable), do: "coordinator_unavailable"

  defp transition_reason_code(_state, :invalid_transition_arguments),
    do: "invalid_transition_arguments"

  defp transition_reason_code(_state, :invalid_target_state), do: "invalid_target_state"
  defp transition_reason_code(_state, :invalid_transition_target), do: "invalid_transition_target"
  defp transition_reason_code(_state, :invalid_context), do: "invalid_transition_context"
  defp transition_reason_code(_state, :invalid_intent), do: "invalid_intent"
  defp transition_reason_code(_state, :invalid_transition_result), do: "invalid_transition_result"
  defp transition_reason_code(_state, %{code: :not_permitted}), do: "unauthorized_transition"
  defp transition_reason_code(_state, %{code: :invalid_subject}), do: "invalid_transition_context"

  defp transition_reason_code(_state, {:authority_rejected, %{code: :not_permitted}}),
    do: "unauthorized_transition"

  defp transition_reason_code(_state, {:authority_rejected, %{code: :invalid_subject}}),
    do: "invalid_transition_context"

  defp transition_reason_code(_state, {:policy_rejected, %{code: :dependency_transition_denied}}),
    do: "dependency_transition_denied"

  defp transition_reason_code(_state, {:policy_rejected, :dependency_transition_denied}),
    do: "dependency_transition_denied"

  defp transition_reason_code(:conflict, _reason), do: "transition_conflict"
  defp transition_reason_code(:provider_failed, _reason), do: "provider_failed"
  defp transition_reason_code(:indeterminate, _reason), do: "transition_indeterminate"
  defp transition_reason_code(:rejected, _reason), do: "transition_rejected"

  defp trusted_context(opts) do
    host_context = Keyword.get(opts, :agent_tool_context)

    with {:ok, host_context} <- valid_host_context(host_context),
         {:ok, route} <- trusted_route(host_context),
         {:ok, semantic_context} <- load_semantic_context(route, host_context, opts),
         {:ok, semantic_context} <- validate_semantic_context(semantic_context),
         :ok <- validate_binding(route, semantic_context, opts) do
      {:ok, Map.put(semantic_context, :route, route)}
    end
  end

  defp valid_host_context(context) when is_map(context), do: {:ok, context}
  defp valid_host_context(_context), do: {:error, :invalid_context}

  defp load_semantic_context(%Route{} = route, host_context, opts) do
    case semantic_context_override(host_context, opts) do
      {:map, context} -> {:ok, context}
      {:function, function} -> invoke_context_function(function, route.issue_id)
      :none -> query_orchestrator(route.issue_id, host_context, opts)
    end
  end

  defp semantic_context_override(host_context, opts) do
    override =
      Keyword.get(opts, :semantic_tool_context, :not_configured) != :not_configured &&
        Keyword.get(opts, :semantic_tool_context)

    override =
      if override == false or override == nil do
        first_present([
          Map.get(host_context, :semantic_tool_context),
          Map.get(host_context, :semantic_context),
          Keyword.get(opts, :semantic_context)
        ])
      else
        override
      end

    case override do
      context when is_map(context) -> {:map, context}
      function when is_function(function, 1) -> {:function, function}
      _missing -> :none
    end
  end

  defp invoke_context_function(function, issue_id) do
    # credo:disable-for-next-line
    try do
      case function.(issue_id) do
        {:ok, context} when is_map(context) -> {:ok, context}
        context when is_map(context) -> {:ok, context}
        {:error, _reason} -> {:error, :context_unavailable}
        _invalid -> {:error, :invalid_context}
      end
    rescue
      _error -> {:error, :context_unavailable}
    catch
      _kind, _reason -> {:error, :context_unavailable}
    end
  end

  defp query_orchestrator(issue_id, host_context, opts) do
    server =
      first_present([
        Keyword.get(opts, :orchestrator_server),
        Keyword.get(opts, :orchestrator),
        Map.get(host_context, :orchestrator_server),
        Map.get(host_context, :orchestrator)
      ]) || Orchestrator

    try do
      case Orchestrator.semantic_tool_context(server, issue_id) do
        {:ok, context} when is_map(context) -> {:ok, context}
        {:error, _reason} -> {:error, :context_unavailable}
        :unavailable -> {:error, :context_unavailable}
      end
    rescue
      _error -> {:error, :context_unavailable}
    catch
      _kind, _reason -> {:error, :context_unavailable}
    end
  end

  defp validate_semantic_context(context) when is_map(context), do: {:ok, context}

  defp validate_binding(%Route{} = route, context, opts) do
    with true <- route_fingerprints_match?(route),
         {:ok, work_item} <- fetch_work_item(context),
         :ok <- validate_work_item_route(work_item, route),
         {:ok, contract} <- fetch_contract(context),
         :ok <- validate_contract(contract, context),
         {:ok, configured_scope} <- configured_scope(Keyword.get(opts, :tracker_settings)),
         :ok <- validate_scope(configured_scope, contract),
         :ok <- validate_observation(work_item.provider_observation, work_item.id, contract),
         :ok <-
           validate_assessment(
             work_item.lifecycle_assessment,
             work_item.id,
             work_item.provider_observation,
             work_item.validated_lifecycle_state
           ),
         :ok <-
           validate_disposition(
             work_item.authority_disposition,
             work_item.validated_lifecycle_state
           ) do
      :ok
    else
      false -> {:error, :invalid_context}
      {:error, _reason} -> {:error, :invalid_context}
    end
  end

  defp route_fingerprints_match?(%Route{} = route) do
    route.fingerprint == Route.fingerprint(route) and
      route.starting_state_fingerprint == Route.starting_state_fingerprint(route)
  end

  defp fetch_work_item(context) do
    case Map.get(context, :work_item) do
      %WorkItem{} = work_item -> {:ok, work_item}
      _missing -> {:error, :missing_work_item}
    end
  end

  defp validate_work_item_route(%WorkItem{} = work_item, %Route{} = route) do
    with {:ok, current_state} <- WorkflowLifecycle.parse(work_item.validated_lifecycle_state),
         {:ok, starting_state} <- WorkflowLifecycle.parse(route.starting_state),
         true <- work_item.id == route.issue_id,
         true <- current_state == starting_state,
         true <-
           route.starting_state == Route.normalize_state(WorkflowLifecycle.display(current_state)),
         true <- route.responsibility == WorkflowLifecycle.responsibility(current_state),
         true <- LifecycleAssessment.validated?(work_item.lifecycle_assessment) do
      :ok
    else
      _failure -> {:error, :work_item_route_mismatch}
    end
  end

  defp fetch_contract(context) do
    case map_value(context, :provider_project_contract) do
      %ProviderProjectContract{} = contract -> {:ok, contract}
      _missing -> {:error, :missing_provider_project_contract}
    end
  end

  defp validate_contract(%ProviderProjectContract{} = contract, context) do
    valid_fingerprint? =
      contract.configuration_fingerprint == ProviderProjectContract.fingerprint(contract)

    context_fingerprint = map_value(context, :provider_contract_fingerprint)

    cond do
      not valid_fingerprint? ->
        {:error, :contract_fingerprint_mismatch}

      is_binary(context_fingerprint) and
          context_fingerprint != ProviderProjectContract.fingerprint(contract) ->
        {:error, :contract_fingerprint_mismatch}

      true ->
        :ok
    end
  end

  defp configured_scope(settings) when is_map(settings) do
    provider = Map.get(settings, :provider) || Map.get(settings, "provider") || %{}

    kind = Map.get(settings, :kind) || Map.get(settings, "kind")
    workspace_id = first_scope_value(provider, settings, :workspace_id)
    project_id = first_scope_value(provider, settings, :project_id)

    if kind in [:plane, "plane"] and is_binary(workspace_id) and is_binary(project_id) do
      {:ok, %{workspace_id: workspace_id, project_id: project_id}}
    else
      {:error, :invalid_tracker_scope}
    end
  end

  defp configured_scope(_settings), do: {:error, :invalid_tracker_scope}

  defp first_scope_value(provider, settings, key) do
    Map.get(provider, key) || Map.get(provider, Atom.to_string(key)) || Map.get(settings, key) ||
      Map.get(settings, Atom.to_string(key))
  end

  defp validate_scope(
         %{workspace_id: workspace_id, project_id: project_id},
         %ProviderProjectContract{} = contract
       ) do
    if contract.workspace_id == workspace_id and contract.project_id == project_id do
      :ok
    else
      {:error, :scope_mismatch}
    end
  end

  defp validate_observation(
         %ProviderObservation{} = observation,
         work_item_id,
         %ProviderProjectContract{} = contract
       ) do
    if observation.provider == :plane and present_text?(observation.work_item_id) and
         observation.work_item_id == work_item_id and
         present_text?(observation.provider_state_name) and
         observation.workspace_id == contract.workspace_id and
         observation.project_id == contract.project_id do
      :ok
    else
      {:error, :observation_mismatch}
    end
  end

  defp validate_observation(_observation, _work_item_id, _contract),
    do: {:error, :observation_mismatch}

  defp validate_assessment(
         %LifecycleAssessment{} = assessment,
         work_item_id,
         %ProviderObservation{} = observation,
         validated_state
       ) do
    if valid_assessment_status?(assessment) and
         valid_assessment_identity?(assessment, work_item_id, observation, validated_state) and
         valid_assessment_states?(assessment) and valid_guard_requirements?(assessment) do
      :ok
    else
      {:error, :assessment_mismatch}
    end
  end

  defp validate_assessment(_assessment, _work_item_id, _observation, _validated_state),
    do: {:error, :assessment_mismatch}

  defp valid_assessment_status?(%LifecycleAssessment{status: status}) do
    status in [
      :unassessed,
      :mapping_resolved,
      :validated,
      :authority_reducing,
      :validation_required,
      :invalid
    ]
  end

  defp valid_assessment_status?(_assessment), do: false

  defp valid_assessment_identity?(assessment, work_item_id, observation, validated_state) do
    assessment.work_item_id == work_item_id and
      assessment.provider_observation == observation and
      assessment.validated_state == validated_state
  end

  defp valid_assessment_states?(%LifecycleAssessment{} = assessment) do
    (is_nil(assessment.mapped_state) or WorkflowLifecycle.canonical?(assessment.mapped_state)) and
      (is_nil(assessment.validated_state) or
         WorkflowLifecycle.canonical?(assessment.validated_state))
  end

  defp valid_guard_requirements?(%LifecycleAssessment{
         required_guards: required,
         missing_guards: missing
       })
       when is_list(required) and is_list(missing) do
    Enum.all?(required ++ missing, &GuardClass.valid?/1)
  end

  defp valid_guard_requirements?(_assessment), do: false

  defp validate_disposition(%AuthorityDisposition{} = disposition, validated_state) do
    if disposition.status in [:none, :eligible, :active, :suspended, :escalated] and
         (is_nil(disposition.lifecycle_state) or disposition.lifecycle_state == validated_state) and
         (is_nil(disposition.resume_target) or
            WorkflowLifecycle.canonical?(disposition.resume_target)) do
      :ok
    else
      {:error, :disposition_mismatch}
    end
  end

  defp validate_disposition(_disposition, _validated_state), do: {:error, :disposition_mismatch}

  defp read_payload(@current_work_item_tool, %{work_item: %WorkItem{} = work_item}) do
    observation = work_item.provider_observation

    {:ok,
     %{
       "workItemId" => work_item.id,
       "identifier" => work_item.identifier,
       "title" => work_item.title,
       "canonicalLifecycleState" => work_item.validated_lifecycle_state,
       "dependencyCompleteness" => serialize_completeness(work_item.dependency_completeness),
       "providerObservation" => %{
         "stateName" => observation.provider_state_name,
         "observedAt" => serialize_datetime(observation.observed_at),
         "providerUpdatedAt" => serialize_datetime(observation.provider_updated_at)
       }
     }}
  end

  defp read_payload(@dependencies_tool, context), do: dependencies_payload(context)

  defp read_payload(@lifecycle_assessment_tool, %{work_item: %WorkItem{} = work_item}) do
    assessment = work_item.lifecycle_assessment

    {:ok,
     %{
       "status" => assessment.status,
       "mappedState" => assessment.mapped_state,
       "validatedState" => assessment.validated_state,
       "reason" => serialize_reason(assessment.reason),
       "requiredGuards" => serialize_guards(assessment.required_guards),
       "missingGuards" => serialize_guards(assessment.missing_guards),
       "assessedAt" => serialize_datetime(assessment.assessed_at)
     }}
  end

  defp read_payload(@authority_disposition_tool, %{work_item: %WorkItem{} = work_item}) do
    disposition = work_item.authority_disposition

    {:ok,
     %{
       "status" => disposition.status,
       "lifecycleState" => disposition.lifecycle_state,
       "reason" => serialize_reason(disposition.reason),
       "resumeTarget" => disposition.resume_target,
       "updatedAt" => serialize_datetime(disposition.updated_at)
     }}
  end

  defp read_payload(_tool, _context), do: {:error, :invalid_context}

  defp dependencies_payload(%{work_item: %WorkItem{dependency_completeness: :complete}} = context) do
    with {:ok, epoch_evidence} <- dependency_epoch(context),
         {:ok, decision} <- dependency_decision(context),
         {:ok, blockers} <- serialize_blockers(decision, context) do
      {:ok,
       %{
         "epoch" => serialize_epoch(map_value(epoch_evidence, :epoch)),
         "completeness" => "complete",
         "status" => dependency_status(decision, blockers),
         "reason" => serialize_reason(map_value(decision, :reason)),
         "blockers" => blockers
       }}
    end
  end

  defp dependencies_payload(_context), do: {:error, :dependency_epoch_unavailable}

  defp dependency_epoch(context) do
    evidence = map_value(context, :dependency_epoch_evidence)

    if is_map(evidence) and map_value(evidence, :complete?) == true and
         map_value(evidence, :completeness) in [nil, :complete, "complete"] and
         not is_nil(map_value(evidence, :epoch)) do
      {:ok, evidence}
    else
      {:error, :dependency_epoch_unavailable}
    end
  end

  defp dependency_decision(context) do
    decision = map_value(context, :dependency_decision)

    if is_map(decision) and
         (Map.has_key?(decision, :allowed?) or Map.has_key?(decision, "allowed?")) do
      {:ok, decision}
    else
      {:error, :dependency_decision_unavailable}
    end
  end

  defp serialize_blockers(decision, context) do
    work_control = map_value(context, :work_control) || %{}

    with {:ok, blockers} <- normalize_blockers(decision),
         true <- is_map(work_control) do
      serialize_blocker_list(blockers, decision, work_control)
    else
      {:error, _reason} = error -> error
      false -> {:error, :dependency_decision_unavailable}
    end
  end

  defp normalize_blockers(decision) do
    case map_value(decision, :blockers) do
      nil ->
        if has_key?(decision, :blockers),
          do: {:error, :dependency_decision_unavailable},
          else: {:ok, []}

      blockers when is_list(blockers) ->
        {:ok, blockers}

      _invalid ->
        {:error, :dependency_decision_unavailable}
    end
  end

  defp serialize_blocker_list(blockers, decision, work_control) do
    Enum.reduce_while(blockers, {:ok, []}, fn blocker, {:ok, acc} ->
      case serialize_blocker(blocker, decision, work_control) do
        {:ok, serialized} -> {:cont, {:ok, [serialized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, serialized} -> {:ok, Enum.reverse(serialized)}
      {:error, _reason} = error -> error
    end
  end

  defp serialize_blocker(%WorkItem{} = work_item, _decision, _work_control) do
    classification = classify_work_item(work_item)

    {:ok,
     %{
       "id" => work_item.id,
       "identifier" => work_item.identifier,
       "classification" => classification
     }}
  end

  defp serialize_blocker(%{} = blocker, decision, work_control) do
    id = Map.get(blocker, :id) || Map.get(blocker, "id")
    identifier = Map.get(blocker, :identifier) || Map.get(blocker, "identifier")

    if present_text?(id) do
      classification =
        case work_item_for(work_control, id) do
          %WorkItem{} = work_item -> classify_work_item(work_item)
          _missing -> classify_raw_blocker(blocker, decision)
        end

      {:ok,
       %{
         "id" => id,
         "identifier" => if(present_text?(identifier), do: identifier, else: nil),
         "classification" => classification
       }}
    else
      {:error, :malformed_dependency_blocker}
    end
  end

  defp serialize_blocker(_blocker, _decision, _work_control),
    do: {:error, :malformed_dependency_blocker}

  defp classify_work_item(%WorkItem{} = work_item) do
    cond do
      WorkItem.dependency_satisfying?(work_item) -> :satisfied
      WorkItem.canonical_state(work_item) == :canceled -> :invalidated
      true -> :unavailable
    end
  end

  defp classify_raw_blocker(blocker, decision) do
    case Policy.classify_blocker(blocker, work_control: %{}) do
      {:ok, %{status: :satisfied}} -> :satisfied
      {:ok, %{status: :invalidated}} -> :invalidated
      {:ok, %{status: :unresolved}} -> :unavailable
      {:error, _reason} -> classify_from_decision(blocker, decision)
    end
  end

  defp classify_from_decision(blocker, decision) do
    id = Map.get(blocker, :id) || Map.get(blocker, "id")

    cond do
      blocker_in?(map_value(decision, :invalidated_blockers), id) -> :invalidated
      blocker_in?(map_value(decision, :unresolved_blockers), id) -> :unavailable
      true -> :unavailable
    end
  end

  defp blocker_in?(blockers, id) when is_list(blockers) do
    Enum.any?(blockers, fn
      %WorkItem{id: blocker_id} -> blocker_id == id
      blocker when is_map(blocker) -> (Map.get(blocker, :id) || Map.get(blocker, "id")) == id
      _other -> false
    end)
  end

  defp blocker_in?(_blockers, _id), do: false

  defp work_item_for(work_control, id) do
    Map.get(work_control, id) || Map.get(work_control, to_string(id))
  end

  defp dependency_status(decision, blockers) do
    status = map_value(decision, :dependency_status)

    cond do
      status in [:none, :satisfied, :unresolved, :invalidated, :unavailable] ->
        status

      status in ["none", "satisfied", "unresolved", "invalidated", "unavailable"] ->
        status_from_string(status)

      blockers == [] and map_value(decision, :allowed?) == true ->
        :none

      true ->
        :unavailable
    end
  end

  defp status_from_string("none"), do: :none
  defp status_from_string("satisfied"), do: :satisfied
  defp status_from_string("unresolved"), do: :unresolved
  defp status_from_string("invalidated"), do: :invalidated
  defp status_from_string("unavailable"), do: :unavailable

  defp serialize_guards(guards) when is_list(guards) do
    Enum.map(guards, fn %{class: class, name: name} -> %{"class" => class, "name" => name} end)
  end

  defp serialize_guards(_guards), do: []

  defp serialize_completeness(:complete), do: "complete"

  defp serialize_completeness({kind, reason}) when kind in [:incomplete, :unavailable],
    do: %{"status" => kind, "reason" => serialize_reason(reason)}

  defp serialize_completeness(_value), do: "unavailable"

  defp serialize_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize_datetime(_value), do: nil

  defp serialize_epoch(value) when is_binary(value), do: value
  defp serialize_epoch(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_epoch(value) when is_integer(value), do: Integer.to_string(value)
  defp serialize_epoch(value) when is_float(value), do: Float.to_string(value)
  defp serialize_epoch(value), do: inspect(value, limit: 5, printable_limit: 256)

  defp serialize_reason(nil), do: nil
  defp serialize_reason(value) when is_binary(value), do: value
  defp serialize_reason(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_reason(value) when is_integer(value), do: Integer.to_string(value)
  defp serialize_reason(value) when is_float(value), do: Float.to_string(value)
  defp serialize_reason(value) when is_boolean(value), do: value
  defp serialize_reason(_value), do: "unavailable"

  defp first_present(values), do: Enum.find(values, &(!is_nil(&1) and &1 != false))

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp has_key?(_map, _key), do: false

  defp success_response(payload), do: tool_response(true, payload)

  defp failure_response(reason) do
    %{
      "error" => %{
        "code" => reason_code(reason),
        "message" => "Plane semantic tool request was rejected."
      }
    }
    |> then(&tool_response(false, &1))
  end

  defp unsupported_response do
    tool_response(false, %{
      "error" => %{
        "code" => "unsupported_tool",
        "message" => "Unsupported Plane semantic tool.",
        "supportedTools" => @all_tool_names
      }
    })
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "invalid_request"

  defp tool_response(success, payload) when is_boolean(success) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
