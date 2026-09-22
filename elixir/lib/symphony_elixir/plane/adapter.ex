defmodule SymphonyElixir.Plane.Adapter do
  @moduledoc "Scoped Plane tracker adapter for host reads and controlled transitions."

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Plane.{AgentTool, Client, DependencyReader, StateProjection}
  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkControl.ProviderProjectContract

  @plane_api_key_env "PLANE_API_KEY"

  @spec capabilities() :: [Capabilities.capability()]
  def capabilities do
    [
      :current_issue_refresh,
      :dependency_graph,
      :dependency_completeness,
      :controlled_transition,
      :transition_verification,
      :agent_read_tools,
      :agent_transition_tools
    ]
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    AgentTool.agent_tool_specs()
  end

  @spec agent_tool_specs(map()) :: [map()]
  def agent_tool_specs(context) when is_map(context) do
    AgentTool.agent_tool_specs(context)
  end

  @spec execute_agent_tool(String.t() | nil, term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) when is_list(opts) do
    AgentTool.execute(tool, arguments, opts)
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) when is_map(tracker_settings) do
    with :ok <- validate_endpoint_setting(tracker_settings),
         {:ok, config} <- client_config(tracker_settings),
         :ok <- Client.validate_config(config) do
      validate_credential_reference(tracker_settings)
    end
  end

  def validate_config(_tracker_settings), do: {:error, :invalid_plane_configuration}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, nil)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, nil)
  end

  @spec fetch_project_snapshot() :: {:ok, map()} | {:error, term()}
  def fetch_project_snapshot do
    fetch_project_snapshot(Config.settings!().tracker, nil)
  end

  @spec fetch_dependency_graph() ::
          {:ok, SymphonyElixir.Dependency.Graph.t()} | {:error, term()}
  def fetch_dependency_graph do
    fetch_dependency_graph(Config.settings!().tracker, nil)
  end

  @doc """
  Applies one host-owned lifecycle transition using the stable state UUID from
  the bound project contract. No provider name, endpoint, method, or request
  body is accepted from the caller.
  """
  @spec submit_controlled_transition(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def submit_controlled_transition(work_item_id, requested_to, opts \\ [])
      when is_binary(work_item_id) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    contract = Keyword.get(opts, :provider_project_contract) || contract_from_settings(tracker_settings)

    with {:ok, %ProviderProjectContract{} = contract} <- normalize_contract(contract),
         tracker_settings <- bind_contract_scope(tracker_settings, contract),
         :ok <- validate_config(tracker_settings),
         {:ok, config} <- client_config(tracker_settings),
         :ok <- validate_contract_scope(config, contract),
         :ok <- validate_work_item_scope(Keyword.get(opts, :pre_observation), config, work_item_id),
         {:ok, mapping} <- ProviderProjectContract.provider_mapping_for(contract, requested_to),
         :ok <- validate_target_mapping(mapping, contract, requested_to) do
      Client.update_work_item_state(
        config,
        work_item_id,
        mapping.state_id,
        request_opts(Keyword.get(opts, :request_fun))
      )
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    configured = Map.get(tracker_settings, :secret_environment_names, [])

    [@plane_api_key_env | configured ++ env_reference_names([provider_value(provider, "api_key")])]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), Client.request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 1) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), Client.request_fun()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 1) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_project_snapshot_for_test(map(), Client.request_fun()) :: {:ok, map()} | {:error, term()}
  def fetch_project_snapshot_for_test(tracker_settings, request_fun)
      when is_map(tracker_settings) and is_function(request_fun, 1) do
    fetch_project_snapshot(tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_dependency_graph_for_test(map(), Client.request_fun()) ::
          {:ok, SymphonyElixir.Dependency.Graph.t()} | {:error, term()}
  def fetch_dependency_graph_for_test(tracker_settings, request_fun)
      when is_map(tracker_settings) and is_function(request_fun, 1) do
    fetch_dependency_graph(tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_dependency_graph_for_test(map(), Client.request_fun(), keyword()) ::
          {:ok, SymphonyElixir.Dependency.Graph.t()} | {:error, term()}
  def fetch_dependency_graph_for_test(tracker_settings, request_fun, opts)
      when is_map(tracker_settings) and is_function(request_fun, 1) and is_list(opts) do
    fetch_dependency_graph(tracker_settings, request_fun, opts)
  end

  @doc false
  @spec controlled_transition_for_test(String.t(), term(), map(), ProviderProjectContract.t(), Client.request_fun()) ::
          :ok | {:error, term()}
  def controlled_transition_for_test(work_item_id, requested_to, tracker_settings, contract, request_fun)
      when is_binary(work_item_id) and is_map(tracker_settings) and
             is_struct(contract, ProviderProjectContract) and is_function(request_fun, 1) do
    submit_controlled_transition(work_item_id, requested_to,
      tracker_settings: tracker_settings,
      provider_project_contract: contract,
      request_fun: request_fun
    )
  end

  defp fetch_issues_by_states(states, tracker_settings, request_fun) do
    with :ok <- validate_config(tracker_settings),
         {:ok, config} <- client_config(tracker_settings),
         {:ok, raw_items} <- Client.list_work_items(config, request_opts(request_fun)),
         {:ok, issues} <- project_issues(raw_items, config) do
      requested = MapSet.new(states, &normalize_state/1)

      {:ok, Enum.filter(issues, &MapSet.member?(requested, normalize_state(&1.state)))}
    end
  end

  defp fetch_issues_by_ids(ids, tracker_settings, request_fun) do
    with :ok <- validate_config(tracker_settings),
         {:ok, config} <- client_config(tracker_settings) do
      ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, &fetch_item(&1, &2, config, request_fun))
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_item(id, {:ok, acc}, config, request_fun) do
    case Client.get_work_item(config, id, request_opts(request_fun)) do
      {:ok, raw_item} ->
        case StateProjection.project_work_item(raw_item, scope(config)) do
          {:ok, projected} -> {:cont, {:ok, [issue_from_projection(projected) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, :not_found} ->
        {:cont, {:ok, acc}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp fetch_project_snapshot(tracker_settings, request_fun) do
    with :ok <- validate_config(tracker_settings),
         {:ok, config} <- client_config(tracker_settings),
         {:ok, raw_project} <- Client.get_project(config, request_opts(request_fun)),
         {:ok, project} <- StateProjection.project_project(raw_project),
         :ok <- validate_project_scope(project, config),
         {:ok, raw_states} <- Client.list_states(config, request_opts(request_fun)),
         {:ok, states} <- project_states(raw_states, config),
         {:ok, workspace_id} <- observed_workspace_id(project, states) do
      {:ok,
       %{
         provider: :plane,
         workspace_id: workspace_id,
         project_id: project.project_id,
         workspace_name: project.workspace_name,
         project_name: project.name,
         project_identifier: project.identifier,
         project_description: project.description,
         states: states,
         dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
         capability_statuses: capability_statuses(),
         completeness: :complete
       }}
    end
  end

  defp fetch_dependency_graph(tracker_settings, request_fun) do
    fetch_dependency_graph(tracker_settings, request_fun, [])
  end

  defp fetch_dependency_graph(tracker_settings, request_fun, opts) do
    with :ok <- validate_config(tracker_settings),
         {:ok, config} <- client_config(tracker_settings) do
      DependencyReader.fetch(config, Keyword.merge(opts, request_opts(request_fun)))
    end
  end

  defp project_issues(raw_items, config) when is_list(raw_items) do
    Enum.reduce_while(raw_items, {:ok, []}, fn raw_item, {:ok, acc} ->
      case StateProjection.project_work_item(raw_item, scope(config)) do
        {:ok, projected} -> {:cont, {:ok, [issue_from_projection(projected) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_states(raw_states, config) when is_list(raw_states) do
    Enum.reduce_while(raw_states, {:ok, []}, fn raw_state, {:ok, acc} ->
      case StateProjection.project_state(raw_state, scope(config)) do
        {:ok, state} -> {:cont, {:ok, [state | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, states} -> {:ok, Enum.reverse(states)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp observed_workspace_id(project, states) do
    state_workspace_ids = states |> Enum.map(&Map.get(&1, :workspace_id)) |> Enum.uniq()

    case state_workspace_ids do
      [workspace_id] ->
        if present?(project.workspace_id) and project.workspace_id != workspace_id,
          do: {:error, :wrong_project},
          else: {:ok, workspace_id}

      [] ->
        if present?(project.workspace_id), do: {:ok, project.workspace_id}, else: {:error, :snapshot_incomplete}

      _multiple ->
        {:error, :wrong_project}
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

  defp client_config(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    {workspace_slug, workspace_id, project_id} = configured_scope(tracker_settings, provider)
    api_key = configured_api_key(tracker_settings)

    validate_client_config(
      Client.default_base_url(),
      workspace_slug,
      workspace_id,
      project_id,
      api_key
    )
  end

  defp configured_scope(tracker_settings, provider) do
    workspace_slug =
      first_string(provider, ["workspace_slug", :workspace_slug]) ||
        first_string(tracker_settings, [:workspace_slug, "workspace_slug"])

    workspace_id =
      first_string(provider, ["workspace_id", :workspace_id]) ||
        first_string(tracker_settings, [:workspace_id, "workspace_id"]) ||
        contract_value(tracker_settings, :workspace_id)

    project_id =
      first_string(provider, ["project_id", "project", :project_id, :project]) ||
        first_string(tracker_settings, [:project_id, "project_id", "project"]) ||
        contract_value(tracker_settings, :project_id)

    {workspace_slug, workspace_id, project_id}
  end

  defp configured_api_key(tracker_settings) do
    Map.get(tracker_settings, :api_key) ||
      Map.get(tracker_settings, "api_key") ||
      System.get_env(@plane_api_key_env)
  end

  defp validate_client_config(base_url, workspace_slug, workspace_id, project_id, api_key) do
    cond do
      not present?(workspace_slug) ->
        {:error, :missing_plane_workspace_slug}

      not present?(project_id) ->
        {:error, :missing_plane_project_id}

      not present?(api_key) ->
        {:error, :missing_plane_api_key}

      not present?(workspace_id) ->
        {:error, :missing_plane_workspace_id}

      true ->
        {:ok,
         %{
           base_url: base_url,
           workspace_slug: workspace_slug,
           workspace_id: workspace_id,
           project_id: project_id,
           api_key: api_key
         }}
    end
  end

  defp validate_credential_reference(tracker_settings) do
    provider = provider_settings(tracker_settings)

    case provider_value(provider, "api_key") do
      nil ->
        configured = Map.get(tracker_settings, :api_key, Map.get(tracker_settings, "api_key"))
        names = Map.get(tracker_settings, :secret_environment_names, [])

        if is_nil(configured) or @plane_api_key_env in names,
          do: :ok,
          else: {:error, :literal_plane_api_key_forbidden}

      "$" <> env_name ->
        if env_name == @plane_api_key_env, do: :ok, else: {:error, :invalid_plane_api_key_reference}

      _literal ->
        {:error, :literal_plane_api_key_forbidden}
    end
  end

  defp validate_endpoint_setting(tracker_settings) do
    provider = provider_settings(tracker_settings)
    configured = provider_value(provider, "endpoint") || Map.get(tracker_settings, :endpoint, Map.get(tracker_settings, "endpoint"))

    if is_nil(configured) or configured == Client.default_base_url(),
      do: :ok,
      else: {:error, :plane_endpoint_must_be_host_controlled}
  end

  defp validate_project_scope(project, config) do
    cond do
      project.project_id != config.project_id -> {:error, :wrong_project}
      present?(project.workspace_id) and project.workspace_id != config.workspace_id -> {:error, :wrong_project}
      present?(project.workspace_slug) and project.workspace_slug != config.workspace_slug -> {:error, :wrong_project}
      true -> :ok
    end
  end

  defp scope(config), do: %{workspace_slug: config.workspace_slug, workspace_id: config.workspace_id, project_id: config.project_id}

  defp capability_statuses do
    Map.new(Capabilities.vocabulary(), fn capability ->
      {capability,
       if(
         capability in [
           :current_issue_refresh,
           :dependency_graph,
           :dependency_completeness,
           :controlled_transition,
           :transition_verification,
           :agent_read_tools,
           :agent_transition_tools
         ],
         do: :supported,
         else: :unsupported
       )}
    end)
  end

  defp request_opts(nil), do: []
  defp request_opts(request_fun), do: [request_fun: request_fun]

  defp normalize_contract(%ProviderProjectContract{} = contract), do: {:ok, contract}
  defp normalize_contract(nil), do: {:error, :provider_project_contract_required}
  defp normalize_contract(_contract), do: {:error, :invalid_provider_project_contract}

  defp contract_from_settings(settings) when is_map(settings) do
    Map.get(settings, :provider_project_contract) || Map.get(settings, "provider_project_contract")
  end

  defp contract_from_settings(_settings), do: nil

  defp bind_contract_scope(settings, %ProviderProjectContract{} = contract) when is_map(settings) do
    case Map.get(settings, :provider_project_contract, Map.get(settings, "provider_project_contract")) do
      nil -> Map.put(settings, :provider_project_contract, contract)
      _existing -> settings
    end
  end

  defp bind_contract_scope(settings, _contract), do: settings

  defp validate_contract_scope(config, %ProviderProjectContract{} = contract) do
    cond do
      config.workspace_id != contract.workspace_id -> {:error, :wrong_project}
      config.project_id != contract.project_id -> {:error, :wrong_project}
      true -> :ok
    end
  end

  defp validate_target_mapping(mapping, %ProviderProjectContract{} = contract, requested_to)
       when is_map(mapping) do
    with {:ok, expected} <- ProviderProjectContract.provider_mapping_for(contract, requested_to),
         true <- mapping.state_id == expected.state_id,
         true <- mapping.group == expected.group,
         true <- is_binary(mapping.state_id) and String.trim(mapping.state_id) != "" do
      :ok
    else
      _ -> {:error, :invalid_target_mapping}
    end
  end

  defp validate_work_item_scope(nil, _config, _expected_work_item_id), do: :ok

  defp validate_work_item_scope(observation, config, expected_work_item_id) when is_map(observation) do
    workspace_id = Map.get(observation, :workspace_id) || Map.get(observation, "workspace_id")
    project_id = Map.get(observation, :project_id) || Map.get(observation, "project_id")
    work_item_id = Map.get(observation, :work_item_id) || Map.get(observation, "work_item_id")

    with :ok <- validate_work_item_id(work_item_id),
         :ok <- validate_work_item_id_match(work_item_id, expected_work_item_id),
         :ok <- validate_optional_scope(workspace_id, config.workspace_id) do
      validate_optional_scope(project_id, config.project_id)
    end
  end

  defp validate_work_item_scope(_observation, _config, _expected_work_item_id),
    do: {:error, :invalid_work_item_observation}

  defp validate_work_item_id(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_work_item_id}, else: :ok
  end

  defp validate_work_item_id(_value), do: {:error, :invalid_work_item_id}

  defp validate_work_item_id_match(value, expected) when is_binary(value) and is_binary(expected) do
    if String.trim(value) == String.trim(expected), do: :ok, else: {:error, :work_item_mismatch}
  end

  defp validate_work_item_id_match(_value, _expected), do: {:error, :work_item_mismatch}

  defp validate_optional_scope(nil, _expected), do: :ok
  defp validate_optional_scope(value, value), do: :ok
  defp validate_optional_scope(_value, _expected), do: {:error, :wrong_project}

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(%{"provider" => provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp provider_value(provider, key) when is_map(provider) do
    Map.get(provider, key) || Map.get(provider, provider_key_atom(key))
  end

  defp provider_key_atom("api_key"), do: :api_key
  defp provider_key_atom("endpoint"), do: :endpoint
  defp provider_key_atom("workspace_slug"), do: :workspace_slug
  defp provider_key_atom("workspace_id"), do: :workspace_id
  defp provider_key_atom("project_id"), do: :project_id
  defp provider_key_atom("project"), do: :project

  defp contract_value(settings, key) do
    case Map.get(settings, :provider_project_contract, Map.get(settings, "provider_project_contract")) do
      %{^key => value} -> value
      contract when is_map(contract) -> Map.get(contract, Atom.to_string(key))
      _ -> nil
    end
  end

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name -> if env_name =~ ~r/^[A-Za-z_][A-Za-z0-9_]*$/, do: [env_name], else: []
      _value -> []
    end)
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
