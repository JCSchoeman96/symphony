defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.{Issue, TransitionPolicy}
  alias SymphonyElixir.WorkControl.{LifecycleAssessment, ProviderObservation, WorkflowLifecycle, WorkItem}

  @read_tool "memory_read"
  @transition_tool "memory_transition"

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs do
    [
      %{
        "name" => @read_tool,
        "description" => "Read the configured in-memory project's issue state.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"issueId" => %{"type" => "string"}}
        }
      },
      %{
        "name" => @transition_tool,
        "description" => "Apply a responsibility-authorized workflow transition in the test project.",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["targetState"],
          "properties" => %{"targetState" => %{"type" => "string"}}
        }
      }
    ]
  end

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(@read_tool, arguments, _opts) do
    case issue_id_from_arguments(arguments) do
      nil -> tool_response(true, Enum.map(issue_entries(), &issue_payload/1))
      issue_id -> tool_response(true, issue_entries() |> Enum.find(&(&1.id == issue_id)) |> issue_payload())
    end
  end

  def execute_agent_tool(@transition_tool, arguments, opts) do
    context = Keyword.get(opts, :agent_tool_context, %{})

    with {:ok, target_state} <- target_state_from_arguments(arguments),
         {:ok, issue_id} <- issue_id_from_context(context),
         %Issue{} = issue <- Enum.find(issue_entries(), &(&1.id == issue_id)),
         {:ok, trusted_state} <- fresh_lifecycle_allowed?(context, issue, routed?(opts)),
         :ok <-
           TransitionPolicy.authorize(
             Map.merge(context, %{
               current_state: trusted_state,
               target_state: target_state
             })
           ),
         updated_issue = %{issue | state: target_state},
         :ok <- replace_issue(updated_issue),
         %Issue{state: ^target_state} <- Enum.find(issue_entries(), &(&1.id == issue_id)) do
      tool_response(true, issue_payload(updated_issue))
    else
      nil -> tool_response(false, %{"error" => "memory issue was not found"})
      {:error, reason} -> tool_response(false, %{"error" => inspect(reason)})
      _ -> tool_response(false, %{"error" => "memory transition could not be verified"})
    end
  end

  def execute_agent_tool(tool, _arguments, _opts) do
    tool_response(false, %{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => Enum.map(agent_tool_specs(), &Map.fetch!(&1, "name"))
      }
    })
  end

  @spec capabilities() :: [SymphonyElixir.Tracker.Capabilities.capability()]
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

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec fetch_dependency_graph() :: {:ok, [Issue.t()]}
  def fetch_dependency_graph, do: {:ok, issue_entries()}

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp replace_issue(%Issue{id: issue_id} = updated_issue) do
    issues =
      Enum.map(configured_issues(), fn
        %Issue{id: ^issue_id} -> updated_issue
        entry -> entry
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues)
    :ok
  end

  defp issue_id_from_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "issueId") || Map.get(arguments, :issueId) || Map.get(arguments, :issue_id) do
      issue_id when is_binary(issue_id) and issue_id != "" -> issue_id
      _ -> nil
    end
  end

  defp issue_id_from_arguments(_arguments), do: nil

  defp issue_id_from_context(context) when is_map(context) do
    case Map.get(context, :issue_id) || Map.get(context, "issue_id") do
      issue_id when is_binary(issue_id) and issue_id != "" -> {:ok, issue_id}
      _ -> {:error, :invalid_transition_context}
    end
  end

  defp issue_id_from_context(_context), do: {:error, :invalid_transition_context}

  defp fresh_lifecycle_allowed?(context, %Issue{} = issue, true) when is_map(context) do
    case trusted_lifecycle_state(context, true) do
      {:ok, trusted_state} ->
        with {:ok, observation} <- ProviderObservation.from_issue(issue, %{provider: :memory}),
             assessment <-
               LifecycleAssessment.assess(
                 observation,
                 trusted_state,
                 Map.get(context, :guard_evidence, Map.get(context, :evidence, []))
               ),
             true <- LifecycleAssessment.validated?(assessment) do
          {:ok, trusted_state}
        else
          false -> {:error, {:lifecycle_not_validated, :unsafe_observation}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fresh_lifecycle_allowed?(context, %Issue{} = issue, false) when is_map(context) do
    with {:ok, trusted_state} <- trusted_lifecycle_state(context, false),
         {:ok, observation} <- ProviderObservation.from_issue(issue, %{provider: :memory}),
         {:ok, observed_state} <- ProviderObservation.map_legacy_state(observation),
         true <- observed_state == trusted_state do
      {:ok, trusted_state}
    else
      false -> {:error, {:lifecycle_not_validated, :unsafe_observation}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh_lifecycle_allowed?(_context, _issue, _routed?), do: {:error, :invalid_transition_context}

  defp trusted_lifecycle_state(%{work_item: %WorkItem{} = work_item}, _routed?) do
    if LifecycleAssessment.validated?(work_item.lifecycle_assessment) and
         WorkflowLifecycle.canonical?(work_item.validated_lifecycle_state) do
      {:ok, work_item.validated_lifecycle_state}
    else
      {:error, :canonical_work_item_required}
    end
  end

  defp trusted_lifecycle_state(context, routed?) do
    keys =
      if routed? do
        [:trusted_lifecycle_state, :current_lifecycle_state]
      else
        [:trusted_lifecycle_state, :current_lifecycle_state, :current_issue_state]
      end

    value =
      Enum.find_value(keys, fn key ->
        if Map.has_key?(context, key), do: Map.get(context, key)
      end)

    if is_nil(value) do
      {:error, :canonical_work_item_required}
    else
      with {:ok, observation} <-
             ProviderObservation.new(%{
               provider: :memory,
               work_item_id: "trusted-context",
               provider_state_name: provider_state_name_for_value(value)
             }),
           {:ok, canonical_state} <- map_trusted_state(observation, routed?) do
        {:ok, canonical_state}
      else
        _error -> {:error, :canonical_work_item_required}
      end
    end
  end

  defp map_trusted_state(observation, true), do: ProviderObservation.map_state(observation)
  defp map_trusted_state(observation, false), do: ProviderObservation.map_legacy_state(observation)

  defp provider_state_name_for_value(value) when is_binary(value), do: value

  defp provider_state_name_for_value(value) when is_atom(value) do
    case WorkflowLifecycle.parse(value) do
      {:ok, state} -> WorkflowLifecycle.display(state)
      {:error, _reason} -> Atom.to_string(value)
    end
  end

  defp provider_state_name_for_value(_value), do: nil

  defp routed?(opts) when is_list(opts) do
    Keyword.get(opts, :agent_routing, Config.settings!().agent.routing) == "routed"
  end

  defp target_state_from_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "targetState") || Map.get(arguments, :targetState) || Map.get(arguments, :target_state) do
      target when is_binary(target) ->
        target = String.trim(target)
        if target == "", do: {:error, :invalid_transition_arguments}, else: {:ok, target}

      _ ->
        {:error, :invalid_transition_arguments}
    end
  end

  defp target_state_from_arguments(_arguments), do: {:error, :invalid_transition_arguments}

  defp issue_payload(nil), do: nil

  defp issue_payload(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "state" => issue.state,
      "url" => issue.url
    }
  end

  defp tool_response(success, payload) when is_boolean(success) do
    output = Jason.encode!(payload, pretty: true)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
