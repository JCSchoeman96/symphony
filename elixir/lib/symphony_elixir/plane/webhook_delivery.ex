defmodule SymphonyElixir.Plane.WebhookDelivery do
  @moduledoc "Validated, non-authoritative identity and classification for Plane v2 events."

  defmodule EventIdentity do
    @moduledoc false

    @enforce_keys [:version, :workspace_id, :webhook_id, :delivery_id, :event_id, :event, :entity_id, :entity_type]
    defstruct [
      :version,
      :workspace_id,
      :webhook_id,
      :delivery_id,
      :event_id,
      :event,
      :entity_id,
      :entity_type,
      :project_hint
    ]

    @type t :: %__MODULE__{
            version: String.t(),
            workspace_id: String.t(),
            webhook_id: String.t(),
            delivery_id: String.t(),
            event_id: String.t(),
            event: String.t(),
            entity_id: String.t(),
            entity_type: String.t(),
            project_hint: String.t() | nil
          }
  end

  @type classification :: %{
          required(:kind) => :targeted | :full_epoch | :other_project | :ignore,
          optional(:work_item_id) => String.t()
        }

  @identifier ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @targeted_events ["workitem.updated", "workitem.deleted"]
  @full_epoch_events [
    "workitem.created",
    "workitem.archived",
    "workitem.dependency.created",
    "workitem.dependency.deleted",
    "workitem.relation.created",
    "workitem.relation.deleted",
    "project.created",
    "project.updated",
    "project.archived",
    "project.deleted"
  ]

  @spec validate_envelope(map(), map()) :: {:ok, EventIdentity.t()} | {:error, atom()}
  def validate_envelope(payload, headers) when is_map(payload) and is_map(headers) do
    with :ok <- validate_version(payload),
         {:ok, workspace_id} <- identifier(payload, "workspace_id"),
         {:ok, webhook_id} <- identifier(payload, "webhook_id"),
         {:ok, delivery_id} <- identifier(payload, "delivery_id"),
         {:ok, event_id} <- identifier(payload, "event_id"),
         {:ok, entity_id} <- identifier(payload, "entity_id"),
         {:ok, event} <- non_empty_string(payload, "event", :missing_event),
         {:ok, entity_type} <- non_empty_string(payload, "entity_type", :missing_entity_type),
         :ok <- validate_entity_type(event, entity_type),
         :ok <- validate_object(payload, "data", :invalid_data),
         :ok <- validate_object(payload, "previous_attributes", :invalid_previous_attributes),
         :ok <- validate_delivery_header(headers, delivery_id),
         :ok <- validate_event_header(headers, event) do
      {:ok,
       %EventIdentity{
         version: "v2",
         workspace_id: workspace_id,
         webhook_id: webhook_id,
         delivery_id: delivery_id,
         event_id: event_id,
         event: event,
         entity_id: entity_id,
         entity_type: entity_type,
         project_hint:
           project_hint(
             event,
             entity_id,
             Map.get(payload, "data"),
             Map.get(payload, "previous_attributes")
           )
       }}
    end
  end

  def validate_envelope(_payload, _headers), do: {:error, :malformed_envelope}

  @spec classify(EventIdentity.t(), String.t()) :: classification()
  def classify(%EventIdentity{} = identity, configured_project_id) when is_binary(configured_project_id) do
    case identity.event do
      event when event in @targeted_events -> classify_targeted(identity, configured_project_id)
      event when event in @full_epoch_events -> classify_full_epoch(identity, configured_project_id)
      _unknown -> %{kind: :ignore}
    end
  end

  def classify(%EventIdentity{}, _configured_project_id), do: %{kind: :ignore}

  defp classify_targeted(%EventIdentity{project_hint: project_hint} = identity, configured_project_id) do
    cond do
      is_binary(project_hint) and project_hint != configured_project_id ->
        %{kind: :other_project}

      is_binary(project_hint) ->
        %{kind: :targeted, work_item_id: identity.entity_id}

      true ->
        %{kind: :full_epoch}
    end
  end

  defp classify_full_epoch(%EventIdentity{project_hint: project_hint}, configured_project_id) do
    if is_binary(project_hint) and project_hint != configured_project_id,
      do: %{kind: :other_project},
      else: %{kind: :full_epoch}
  end

  @spec delivery_key(EventIdentity.t()) :: tuple()
  def delivery_key(%EventIdentity{} = identity),
    do: {:delivery, identity.workspace_id, identity.webhook_id, identity.delivery_id}

  @spec event_key(EventIdentity.t()) :: tuple()
  def event_key(%EventIdentity{} = identity),
    do: {:event, identity.workspace_id, identity.webhook_id, identity.event_id}

  defp validate_version(%{"version" => "v2"}), do: :ok
  defp validate_version(%{"version" => _version}), do: {:error, :unsupported_version}
  defp validate_version(_payload), do: {:error, :missing_version}

  defp identifier(payload, field) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        if Regex.match?(@identifier, value), do: {:ok, value}, else: {:error, String.to_atom("invalid_#{field}")}

      _value ->
        {:error, String.to_atom("missing_#{field}")}
    end
  end

  defp non_empty_string(payload, field, error) do
    case Map.get(payload, field) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, error}, else: {:ok, value}

      _value ->
        {:error, error}
    end
  end

  defp validate_object(payload, field, error) do
    if is_map(Map.get(payload, field)), do: :ok, else: {:error, error}
  end

  defp validate_entity_type(event, "issue")
       when event in [
              "workitem.created",
              "workitem.updated",
              "workitem.archived",
              "workitem.deleted",
              "workitem.dependency.created",
              "workitem.dependency.deleted",
              "workitem.relation.created",
              "workitem.relation.deleted"
            ],
       do: :ok

  defp validate_entity_type(event, "project")
       when event in ["project.created", "project.updated", "project.archived", "project.deleted"],
       do: :ok

  defp validate_entity_type(event, _entity_type)
       when event in [
              "workitem.created",
              "workitem.updated",
              "workitem.archived",
              "workitem.deleted",
              "workitem.dependency.created",
              "workitem.dependency.deleted",
              "workitem.relation.created",
              "workitem.relation.deleted",
              "project.created",
              "project.updated",
              "project.archived",
              "project.deleted"
            ],
       do: {:error, :entity_type_mismatch}

  defp validate_entity_type(_event, _entity_type), do: :ok

  defp validate_delivery_header(headers, delivery_id) do
    case Map.get(headers, "x-plane-delivery") do
      ^delivery_id -> :ok
      _value -> {:error, :delivery_header_mismatch}
    end
  end

  defp validate_event_header(headers, event) do
    case Map.get(headers, "x-plane-event") do
      ^event -> :ok
      _value -> {:error, :event_header_mismatch}
    end
  end

  defp project_hint(event, entity_id, _data, _previous_attributes)
       when event in ["project.created", "project.updated", "project.archived", "project.deleted"],
       do: entity_id

  defp project_hint(_event, _entity_id, data, previous_attributes) do
    project_id =
      Map.get(data || %{}, "project_id") || Map.get(previous_attributes || %{}, "project_id")

    project_hint_identifier(project_id)
  end

  defp project_hint_identifier(project_id) when is_binary(project_id) do
    if Regex.match?(@identifier, project_id), do: project_id, else: nil
  end

  defp project_hint_identifier(_project_id), do: nil
end
