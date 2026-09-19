defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.TransitionCoordinator
  alias SymphonyElixir.WorkControl.{SemanticTransitionIntent, WorkflowLifecycle}

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory,
    "plane" => SymphonyElixir.Plane.Adapter
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_dependency_graph() :: {:ok, term()} | {:error, term()}
  @callback fetch_project_snapshot() :: {:ok, map()} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback capabilities() :: [Capabilities.capability()]

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      fetch_dependency_graph: 0,
                      fetch_project_snapshot: 0,
                      validate_config: 1,
                      capabilities: 0

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @spec fetch_dependency_graph() :: {:ok, term()} | {:error, term()}
  def fetch_dependency_graph do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :fetch_dependency_graph, 0) do
      adapter.fetch_dependency_graph()
    else
      {:error, :dependency_graph_unsupported}
    end
  end

  @spec fetch_project_snapshot() :: {:ok, map()} | {:error, term()}
  def fetch_project_snapshot do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :fetch_project_snapshot, 0) do
      adapter.fetch_project_snapshot()
    else
      {:error, :project_snapshot_unsupported}
    end
  end

  @doc """
  Executes one complete host-owned controlled transition through the durable
  transition coordinator.
  """
  @spec controlled_transition(String.t(), WorkflowLifecycle.state(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def controlled_transition(work_item_id, target_state, opts \\ [])
      when is_binary(work_item_id) and is_list(opts) do
    coordinator = Keyword.get(opts, :coordinator, TransitionCoordinator)

    with {:ok, intent} <- semantic_transition_intent(work_item_id, target_state, opts) do
      TransitionCoordinator.request_transition(coordinator, intent)
    end
  end

  @doc false
  @spec submit_controlled_transition(String.t(), WorkflowLifecycle.state(), keyword()) ::
          :ok | {:ok, term()} | {:error, term()}
  def submit_controlled_transition(work_item_id, target_state, opts \\ [])
      when is_binary(work_item_id) and is_list(opts) do
    adapter = Keyword.get_lazy(opts, :adapter, &adapter/0)

    with {:ok, declared} <- Capabilities.validate_adapter(adapter),
         true <- :controlled_transition in declared,
         true <- Code.ensure_loaded?(adapter),
         true <- function_exported?(adapter, :submit_controlled_transition, 3) do
      adapter.submit_controlled_transition(work_item_id, target_state, opts)
    else
      false -> {:error, :controlled_transition_unsupported}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools(keyword()) :: map()
  def bind_agent_tools(opts \\ []) do
    settings = Config.settings!()
    tracker_settings = settings.tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      agent_routing: settings.agent.routing,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings),
      transition_guard: :atomics.new(1, []),
      agent_tool_context: Keyword.get(opts, :agent_tool_context, %{})
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings} = binding,
        tool,
        arguments,
        opts \\ []
      ) do
    execute_agent_tool_with_adapter(
      adapter,
      tool,
      arguments,
      opts
      |> Keyword.put(:tracker_settings, tracker_settings)
      |> Keyword.put(:agent_routing, Map.get(binding, :agent_routing, "legacy"))
      |> Keyword.put(:transition_guard, Map.get(binding, :transition_guard))
      |> Keyword.put(:agent_tool_context, Map.get(binding, :agent_tool_context, %{}))
    )
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec capabilities() :: {:ok, [Capabilities.capability()]} | {:error, term()}
  def capabilities do
    Config.settings!().tracker.kind
    |> capabilities_for_kind()
  end

  @spec identity(map()) :: %{tracker_kind: String.t(), provider_scope: map()}
  def identity(%{kind: kind} = tracker_settings) when is_binary(kind) do
    %{
      tracker_kind: kind,
      provider_scope: provider_scope(kind, tracker_settings)
    }
  end

  @spec capabilities_for_kind(String.t()) ::
          {:ok, [Capabilities.capability()]} | {:error, term()}
  def capabilities_for_kind(kind) when is_binary(kind) do
    with {:ok, adapter} <- adapter_for_kind(kind),
         {:ok, declared} <- Capabilities.validate_adapter(adapter) do
      {:ok, declared}
    else
      {:error, {:invalid_provider_capability_declaration, _adapter, reason}} ->
        {:error, {:invalid_provider_capability_declaration, kind, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec validate_routed_capabilities(map()) :: :ok | {:error, term()}
  def validate_routed_capabilities(%{agent: %{routing: "legacy"}}), do: :ok

  def validate_routed_capabilities(%{agent: %{routing: "routed"}, tracker: %{kind: kind}})
      when is_binary(kind) do
    with {:ok, declared} <- capabilities_for_kind(kind) do
      case Capabilities.missing(declared) do
        [] -> :ok
        missing -> {:error, {:routed_provider_capabilities_missing, kind, missing}}
      end
    end
  end

  def validate_routed_capabilities(_settings), do: :ok

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp semantic_transition_intent(work_item_id, target_state, opts) do
    case Keyword.get(opts, :intent) do
      %SemanticTransitionIntent{} = intent ->
        if intent.work_item_id == work_item_id and intent.requested_to == target_state do
          {:ok, intent}
        else
          {:error, :intent_mismatch}
        end

      nil ->
        attrs = Keyword.get(opts, :intent_attrs, %{})

        if is_map(attrs) do
          attrs
          |> Map.merge(%{work_item_id: work_item_id, requested_to: target_state})
          |> SemanticTransitionIntent.new()
        else
          {:error, :invalid_intent}
        end

      _other ->
        {:error, :invalid_intent}
    end
  end

  defp provider_scope("linear", tracker_settings) do
    compact_scope(%{
      project_slug: tracker_settings.project_slug || provider_value(tracker_settings.provider, "project_slug")
    })
  end

  defp provider_scope(kind, tracker_settings) when kind in ["github", "gitlab"] do
    compact_scope(%{repo: provider_value(tracker_settings.provider, "repo")})
  end

  defp provider_scope("jira", tracker_settings) do
    compact_scope(%{project_key: provider_value(tracker_settings.provider, "project_key")})
  end

  defp provider_scope("asana", tracker_settings) do
    compact_scope(%{project_gid: provider_value(tracker_settings.provider, "project_gid")})
  end

  defp provider_scope("plane", tracker_settings) do
    provider = Map.get(tracker_settings, :provider) || Map.get(tracker_settings, "provider") || %{}

    compact_scope(%{
      workspace_slug: plane_workspace_scope(provider, tracker_settings),
      workspace_id: plane_workspace_id(provider, tracker_settings),
      project_id: plane_project_scope(provider, tracker_settings)
    })
  end

  defp provider_scope(_kind, _tracker_settings), do: %{}

  defp provider_value(provider, key) when is_map(provider) do
    Map.get(provider, key) || Map.get(provider, provider_key_atom(key))
  end

  defp provider_value(_provider, _key), do: nil

  defp provider_key_atom("project_slug"), do: :project_slug
  defp provider_key_atom("repo"), do: :repo
  defp provider_key_atom("project_key"), do: :project_key
  defp provider_key_atom("project_gid"), do: :project_gid
  defp provider_key_atom("workspace_slug"), do: :workspace_slug
  defp provider_key_atom("workspace_id"), do: :workspace_id
  defp provider_key_atom("project_id"), do: :project_id
  defp provider_key_atom("project"), do: :project

  defp plane_workspace_scope(provider, tracker_settings) do
    provider_value(provider, "workspace_slug") ||
      first_scope_value(tracker_settings, [:workspace_slug, "workspace_slug"])
  end

  defp plane_workspace_id(provider, tracker_settings) do
    provider_value(provider, "workspace_id") ||
      first_scope_value(tracker_settings, [:workspace_id, "workspace_id"])
  end

  defp plane_project_scope(provider, tracker_settings) do
    provider_value(provider, "project_id") ||
      provider_value(provider, "project") ||
      first_scope_value(tracker_settings, [:project_id, "project_id"])
  end

  defp first_scope_value(map, keys), do: Enum.find_value(keys, &scope_value(Map.get(map, &1)))

  defp scope_value(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp scope_value(_value), do: nil

  defp compact_scope(scope) do
    Enum.reduce(scope, %{}, fn
      {key, value}, acc when is_binary(value) ->
        if String.trim(value) == "", do: acc, else: Map.put(acc, key, String.trim(value))

      {_key, _value}, acc ->
        acc
    end)
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
