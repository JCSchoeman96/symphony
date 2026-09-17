defmodule SymphonyElixir.Plane.StateProjection do
  @moduledoc """
  Strict, provider-only projection of Plane resources.

  The projection preserves Plane identities and descriptive values. It never
  maps a provider state to a Symphony lifecycle authority.
  """

  @groups %{
    "backlog" => :backlog,
    "unstarted" => :unstarted,
    "started" => :started,
    "completed" => :completed,
    "cancelled" => :cancelled
  }

  @spec project_work_item(map(), map()) :: {:ok, map()} | {:error, term()}
  def project_work_item(raw_item, expected_scope) when is_map(raw_item) and is_map(expected_scope) do
    with {:ok, workspace_id} <- expected_identifier(expected_scope, :workspace_id),
         {:ok, project_id} <- expected_identifier(expected_scope, :project_id),
         {:ok, id} <- required_identifier(raw_item, [:id, :uuid]),
         :ok <- validate_scope(raw_item, workspace_id, project_id),
         {:ok, state} <- project_state_from_item(raw_item),
         {:ok, updated_at} <- required_datetime(raw_value(raw_item, :updated_at), :updated_at),
         {:ok, created_at} <- optional_datetime(raw_value(raw_item, :created_at), :created_at) do
      {:ok,
       %{
         id: id,
         workspace_id: workspace_id,
         project_id: project_id,
         provider_state_id: state.id,
         provider_state_group: state.group,
         provider_state_name: state.name,
         provider_updated_at: updated_at,
         identifier: first_text(raw_item, [:identifier, :sequence_id, :name]) || id,
         title: first_text(raw_item, [:name, :title]) || id,
         description: optional_text(raw_value(raw_item, :description)),
         priority: optional_integer(raw_value(raw_item, :priority)),
         url: first_text(raw_item, [:url, :link, :web_url]),
         labels: project_labels(raw_value(raw_item, :labels)),
         created_at: created_at,
         updated_at: updated_at,
         state: state.name,
         dispatchable: state.group not in [:completed, :cancelled],
         blocked_by: [],
         dependency_completeness: {:unavailable, :dependency_graph_unsupported},
         native_ref: %{
           "workspace_id" => workspace_id,
           "project_id" => project_id,
           "work_item_id" => id,
           "provider_state_id" => state.id,
           "provider_state_group" => state.group
         }
       }}
    end
  end

  def project_work_item(_raw_item, _expected_scope), do: {:error, {:provider_malformed, :invalid_work_item}}

  @spec project_state(map()) :: {:ok, %{id: String.t(), name: String.t() | nil, group: atom()}} | {:error, term()}
  def project_state(raw_state) when is_map(raw_state) do
    with {:ok, id} <- required_identifier(raw_state, [:id, :uuid]),
         {:ok, group} <- project_group(raw_value(raw_state, :group)),
         {:ok, name} <- required_text(raw_value(raw_state, :name), :name) do
      {:ok, %{id: id, name: name, group: group}}
    end
  end

  def project_state(_raw_state), do: {:error, {:provider_malformed, :invalid_state}}

  @spec project_project(map()) :: {:ok, map()} | {:error, term()}
  def project_project(raw_project) when is_map(raw_project) do
    with {:ok, project_id} <- required_identifier(raw_project, [:id, :uuid]),
         {:ok, workspace_id} <- project_workspace(raw_project),
         {:ok, name} <- optional_required_text(first_value(raw_project, [:name, :identifier]), :name) do
      {:ok,
       %{
         provider: :plane,
         workspace_id: workspace_id,
         project_id: project_id,
         name: name,
         workspace_name: project_workspace_name(raw_project),
         identifier: first_text(raw_project, [:identifier]),
         description: optional_text(raw_value(raw_project, :description))
       }}
    end
  end

  def project_project(_raw_project), do: {:error, {:provider_malformed, :invalid_project}}

  @spec normalize_group(term()) :: atom() | nil
  def normalize_group(value) when is_atom(value) and value in [:backlog, :unstarted, :started, :completed, :cancelled], do: value
  def normalize_group(value) when is_binary(value), do: Map.get(@groups, String.trim(String.downcase(value)))
  def normalize_group(_value), do: nil

  defp project_state_from_item(raw_item) do
    case raw_value(raw_item, :state) do
      state when is_map(state) -> project_state(state)
      nil -> {:error, {:provider_malformed, :missing_state}}
      _value -> {:error, {:provider_malformed, :invalid_state}}
    end
  end

  defp project_group(value) do
    case normalize_group(value) do
      nil -> {:error, {:provider_malformed, :invalid_group}}
      group -> {:ok, group}
    end
  end

  defp project_workspace(raw_project) do
    workspace = raw_value(raw_project, :workspace)

    workspace_id =
      first_text(raw_project, [:workspace_slug, :workspace_id]) ||
        if(is_map(workspace), do: first_text(workspace, [:slug, :id]), else: nil)

    if present?(workspace_id), do: {:ok, workspace_id}, else: {:error, {:provider_malformed, :missing_workspace}}
  end

  defp project_workspace_name(raw_project) do
    first_text(raw_project, [:workspace_name]) ||
      nested_text(raw_value(raw_project, :workspace), [:name])
  end

  defp validate_scope(raw_item, workspace_id, project_id) do
    returned_projects =
      scope_values([
        first_text(raw_item, [:project_id]),
        nested_text(raw_value(raw_item, :project), [:id, :uuid])
      ])

    returned_workspaces =
      scope_values([
        first_text(raw_item, [:workspace_slug, :workspace_id]),
        nested_text(raw_value(raw_item, :workspace), [:slug, :id])
      ])

    cond do
      Enum.any?(returned_projects, &(&1 != project_id)) -> {:error, :wrong_project}
      Enum.any?(returned_workspaces, &(&1 != workspace_id)) -> {:error, :wrong_project}
      true -> :ok
    end
  end

  defp scope_values(values), do: Enum.filter(values, &present?/1)

  defp expected_identifier(scope, key) do
    case first_value(scope, [key, alternate_scope_key(key)]) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, {:provider_malformed, {:missing_scope, key}}}, else: {:ok, value}

      _value ->
        {:error, {:provider_malformed, {:missing_scope, key}}}
    end
  end

  defp alternate_scope_key(:workspace_id), do: :workspace_slug
  defp alternate_scope_key(:project_id), do: :project

  defp required_identifier(raw, keys) do
    case first_text(raw, keys) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:provider_malformed, :missing_id}}
    end
  end

  defp required_text(value, field) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, {:provider_malformed, {:invalid_field, field}}}, else: {:ok, value}
  end

  defp required_text(_value, field), do: {:error, {:provider_malformed, {:invalid_field, field}}}

  defp optional_required_text(nil, _field), do: {:ok, nil}

  defp optional_required_text(value, field) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, {:provider_malformed, {:invalid_field, field}}}, else: {:ok, value}
  end

  defp optional_required_text(_value, field), do: {:error, {:provider_malformed, {:invalid_field, field}}}

  defp optional_datetime(nil, _field), do: {:ok, nil}

  defp optional_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, {:provider_malformed, {:invalid_datetime, field}}}
    end
  end

  defp optional_datetime(_value, field), do: {:error, {:provider_malformed, {:invalid_datetime, field}}}

  defp required_datetime(value, field) do
    case optional_datetime(value, field) do
      {:ok, %DateTime{} = datetime} -> {:ok, datetime}
      {:ok, nil} -> {:error, {:provider_malformed, {:invalid_datetime, field}}}
      {:error, _reason} = error -> error
    end
  end

  defp optional_integer(value) when is_integer(value), do: value
  defp optional_integer(_value), do: nil

  defp project_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      label when is_binary(label) -> [String.trim(label)]
      label when is_map(label) -> if(is_binary(first_value(label, [:name])), do: [String.trim(first_value(label, [:name]))], else: [])
      _label -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp project_labels(_labels), do: []

  defp first_text(map, keys) when is_map(map) do
    Enum.find_value(keys, &text_value(raw_value(map, &1)))
  end

  defp nested_text(value, keys) when is_map(value), do: first_text(value, keys)
  defp nested_text(_value, _keys), do: nil

  defp first_value(map, keys) when is_map(map), do: Enum.find_value(keys, &raw_value(map, &1))

  defp raw_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp text_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text_value(_value), do: nil

  defp optional_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_text(_value), do: nil
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
