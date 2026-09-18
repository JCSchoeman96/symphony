defmodule SymphonyElixir.WorkControl.ProviderProjectContract do
  @moduledoc """
  Immutable, provider-neutral authority for one configured work-control scope.

  V1 is intentionally a Plane contract, but the shape keeps provider identity
  and provider observations separate from canonical workflow policy. Stable
  provider IDs are authoritative; names are descriptive metadata only.
  """

  alias SymphonyElixir.Tracker.Capabilities
  alias SymphonyElixir.WorkControl.WorkflowLifecycle

  @schema_version 1
  @provider :plane
  @max_identifier_bytes 256
  @max_name_bytes 256

  @config_keys [
    :schema_version,
    :provider,
    :workspace_id,
    :project_id,
    :workspace_name,
    :project_name,
    :state_mappings,
    :dependency_relation_semantics,
    :required_capabilities,
    :optional_capabilities,
    :configuration_fingerprint
  ]

  @config_key_names %{
    "schema_version" => :schema_version,
    "provider" => :provider,
    "workspace_id" => :workspace_id,
    "project_id" => :project_id,
    "workspace_name" => :workspace_name,
    "project_name" => :project_name,
    "state_mappings" => :state_mappings,
    "dependency_relation_semantics" => :dependency_relation_semantics,
    "required_capabilities" => :required_capabilities,
    "optional_capabilities" => :optional_capabilities,
    "configuration_fingerprint" => :configuration_fingerprint
  }

  @capability_names %{
    "current_issue_refresh" => :current_issue_refresh,
    "dependency_graph" => :dependency_graph,
    "dependency_completeness" => :dependency_completeness,
    "controlled_transition" => :controlled_transition,
    "transition_verification" => :transition_verification,
    "agent_read_tools" => :agent_read_tools,
    "agent_transition_tools" => :agent_transition_tools,
    "conditional_transition" => :conditional_transition
  }

  @state_mapping_keys [:state_id, :name, :group]

  @canonical_state_names %{
    "backlog" => :backlog,
    "planning" => :planning,
    "ready" => :ready,
    "in_progress" => :in_progress,
    "in_review" => :in_review,
    "changes_requested" => :changes_requested,
    "ready_to_merge" => :ready_to_merge,
    "merging" => :merging,
    "blocked" => :blocked,
    "done" => :done,
    "canceled" => :canceled
  }

  @state_groups %{
    backlog: :backlog,
    planning: :unstarted,
    ready: :unstarted,
    in_progress: :started,
    in_review: :started,
    changes_requested: :started,
    ready_to_merge: :started,
    merging: :started,
    blocked: :started,
    done: :completed,
    canceled: :cancelled
  }

  @dependency_relation_semantics %{
    blocked_by: :blocked_by,
    blocking: :blocking
  }

  defmodule ConfigError do
    @moduledoc "Bounded error returned for invalid project contract configuration."

    defexception [:message, :code, :field, :value, :reason]

    @type t :: %__MODULE__{
            message: String.t() | nil,
            code: atom() | nil,
            field: term(),
            value: term(),
            reason: term()
          }
  end

  defmodule Diagnostic do
    @moduledoc "Bounded, concrete description of one contract validation finding."

    defstruct [
      :class,
      :field,
      :canonical_state,
      :state,
      :capability,
      :expected,
      :observed,
      :reason
    ]

    @type t :: %__MODULE__{
            class: atom() | nil,
            field: atom() | nil,
            canonical_state: atom() | nil,
            state: atom() | nil,
            capability: atom() | nil,
            expected: term(),
            observed: term(),
            reason: atom() | nil
          }
  end

  defmodule ValidationResult do
    @moduledoc "Immutable result of validating a configured project contract."

    defstruct status: nil, diagnostics: [], expected_fingerprint: nil, observed_fingerprint: nil

    @type status :: :valid | :drift_detected | :snapshot_incomplete | :provider_malformed

    @type t :: %__MODULE__{
            status: status(),
            diagnostics: [Diagnostic.t()],
            expected_fingerprint: String.t() | nil,
            observed_fingerprint: String.t() | nil
          }
  end

  defstruct [
    :schema_version,
    :provider,
    :workspace_id,
    :project_id,
    :state_mappings,
    :dependency_relation_semantics,
    :required_capabilities,
    :optional_capabilities,
    :configuration_fingerprint
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          provider: :plane,
          workspace_id: String.t(),
          project_id: String.t(),
          state_mappings: %{WorkflowLifecycle.state() => map()},
          dependency_relation_semantics: %{blocked_by: :blocked_by, blocking: :blocking},
          required_capabilities: [Capabilities.capability()],
          optional_capabilities: [Capabilities.capability()],
          configuration_fingerprint: String.t()
        }

  @spec new(map()) :: {:ok, t()} | {:error, ConfigError.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_config_keys(attrs),
         :ok <- reject_caller_fingerprint(attrs),
         :ok <- validate_schema_version(attribute(attrs, :schema_version)),
         {:ok, provider} <- normalize_provider(attribute(attrs, :provider)),
         {:ok, workspace_id} <- validate_identifier(attribute(attrs, :workspace_id), :workspace_id),
         {:ok, project_id} <- validate_identifier(attribute(attrs, :project_id), :project_id),
         :ok <- validate_optional_name(attribute(attrs, :workspace_name), :workspace_name),
         :ok <- validate_optional_name(attribute(attrs, :project_name), :project_name),
         {:ok, state_mappings} <- validate_state_mappings(attribute(attrs, :state_mappings)),
         {:ok, dependency_relation_semantics} <-
           resolve_dependency_relation_semantics(attribute(attrs, :dependency_relation_semantics)),
         {:ok, required} <-
           resolve_capability_set(
             attribute(attrs, :required_capabilities),
             required_capabilities(),
             :required_capabilities_redefinition
           ),
         {:ok, optional} <-
           resolve_capability_set(
             attribute(attrs, :optional_capabilities),
             optional_capabilities(),
             :optional_capabilities_redefinition
           ) do
      contract = %__MODULE__{
        schema_version: @schema_version,
        provider: provider,
        workspace_id: workspace_id,
        project_id: project_id,
        state_mappings: state_mappings,
        dependency_relation_semantics: dependency_relation_semantics,
        required_capabilities: required,
        optional_capabilities: optional,
        configuration_fingerprint: ""
      }

      {:ok, %{contract | configuration_fingerprint: fingerprint(contract)}}
    end
  end

  def new(_attrs), do: {:error, config_error(:invalid_configuration)}

  @spec required_capabilities() :: [Capabilities.capability()]
  def required_capabilities, do: Capabilities.required_routed()

  @spec optional_capabilities() :: [Capabilities.capability()]
  def optional_capabilities, do: Capabilities.vocabulary() -- Capabilities.required_routed()

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = contract) do
    semantics = {
      Map.get(contract, :schema_version),
      fingerprint_provider(Map.get(contract, :provider)),
      Map.get(contract, :workspace_id),
      Map.get(contract, :project_id),
      fingerprint_state_mappings(Map.get(contract, :state_mappings)),
      fingerprint_relations(Map.get(contract, :dependency_relation_semantics)),
      fingerprint_capabilities(Map.get(contract, :required_capabilities))
    }

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(semantics))
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  @spec resolve_provider_state(t(), String.t() | nil, atom() | String.t() | nil) ::
          {:ok, WorkflowLifecycle.state()} | {:error, :unknown_state_mapping | :state_group_mismatch}
  def resolve_provider_state(%__MODULE__{} = contract, provider_state_id, provider_state_group) do
    normalized_group = normalize_provider_group(provider_state_group)

    case Enum.find(contract.state_mappings, fn {_state, mapping} -> mapping.state_id == provider_state_id end) do
      nil ->
        {:error, :unknown_state_mapping}

      {canonical_state, %{group: expected_group}} ->
        if expected_group == normalized_group do
          {:ok, canonical_state}
        else
          {:error, :state_group_mismatch}
        end
    end
  end

  defp validate_schema_version({:ok, @schema_version}), do: :ok

  defp validate_schema_version({:ok, value}),
    do: {:error, config_error(:unsupported_schema_version, :schema_version, value)}

  defp validate_schema_version(:missing),
    do: {:error, config_error(:unsupported_schema_version, :schema_version)}

  defp normalize_provider({:ok, :plane}), do: {:ok, @provider}
  defp normalize_provider({:ok, "plane"}), do: {:ok, @provider}

  defp normalize_provider({:ok, value}),
    do: {:error, config_error(:unsupported_provider, :provider, safe_config_value(value))}

  defp normalize_provider(:missing), do: {:error, config_error(:unsupported_provider, :provider)}

  defp validate_identifier(:missing, field), do: {:error, config_error(invalid_identifier_code(field), field)}

  defp validate_identifier({:ok, value}, field) do
    if valid_bounded_text?(value, @max_identifier_bytes) do
      {:ok, value}
    else
      {:error, config_error(invalid_identifier_code(field), field, safe_config_value(value))}
    end
  end

  defp validate_optional_name(:missing, _field), do: :ok
  defp validate_optional_name({:ok, nil}, _field), do: :ok

  defp validate_optional_name({:ok, value}, field) do
    if valid_bounded_text?(value, @max_name_bytes) do
      :ok
    else
      {:error, config_error(:invalid_descriptive_name, field, safe_config_value(value))}
    end
  end

  defp validate_state_mappings({:ok, mappings}) when is_map(mappings) do
    states = WorkflowLifecycle.states()

    with {:ok, mappings} <- normalize_state_mapping_keys(mappings),
         :ok <- reject_unknown_states(mappings, states),
         :ok <- reject_missing_states(mappings, states),
         {:ok, normalized} <- normalize_state_mappings(mappings, states),
         :ok <- reject_duplicate_state_ids(normalized) do
      {:ok, normalized}
    end
  end

  defp validate_state_mappings(_value), do: {:error, config_error(:invalid_state_mappings, :state_mappings)}

  defp reject_unknown_states(mappings, states) do
    case Enum.find(Map.keys(mappings), fn state -> state not in states end) do
      nil -> :ok
      unknown -> {:error, config_error(:unknown_canonical_state, :state_mappings, unknown)}
    end
  end

  defp reject_missing_states(mappings, states) do
    case Enum.find(states, fn state -> not Map.has_key?(mappings, state) end) do
      nil -> :ok
      missing -> {:error, config_error(:missing_canonical_state, :state_mappings, missing)}
    end
  end

  defp normalize_state_mappings(mappings, states) do
    Enum.reduce_while(states, {:ok, %{}}, fn state, {:ok, normalized} ->
      case normalize_state_mapping(state, Map.fetch!(mappings, state)) do
        {:ok, mapping} -> {:cont, {:ok, Map.put(normalized, state, mapping)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_state_mapping(state, mapping) when is_map(mapping) do
    with {:ok, mapping} <- normalize_state_mapping_fields(mapping, state),
         :ok <- reject_group_redefinition(mapping, state),
         {:ok, state_id} <- validate_mapping_identifier(mapping, state),
         {:ok, name} <- validate_mapping_name(mapping, state) do
      {:ok, %{state_id: state_id, group: Map.fetch!(@state_groups, state), name: name}}
    end
  end

  defp normalize_state_mapping(state, value),
    do: {:error, config_error(:invalid_state_mapping, state, safe_config_value(value))}

  defp normalize_config_keys(attrs) do
    normalize_keys(
      attrs,
      &canonical_config_key/1,
      :configuration,
      :unknown_configuration_key,
      :duplicate_configuration_key
    )
  end

  defp normalize_state_mapping_keys(mappings), do: normalize_state_mapping_keys(mappings, :state_mappings)

  defp normalize_state_mapping_keys(mappings, field) do
    normalize_keys(
      mappings,
      &canonical_state_key/1,
      field,
      :unknown_canonical_state,
      :duplicate_canonical_state
    )
  end

  defp normalize_state_mapping_fields(mapping, state) do
    normalize_keys(
      mapping,
      &canonical_state_mapping_key/1,
      state,
      :unknown_state_mapping_key,
      :duplicate_state_mapping_key
    )
  end

  defp normalize_keys(map, canonicalizer, field, unknown_code, duplicate_code) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      normalize_key_entry(
        canonicalizer.(key),
        key,
        value,
        normalized,
        field,
        unknown_code,
        duplicate_code
      )
    end)
  end

  defp normalize_key_entry(:unknown, key, _value, _normalized, field, unknown_code, _duplicate_code),
    do: {:halt, {:error, config_error(unknown_code, field, key)}}

  defp normalize_key_entry(canonical_key, _key, value, normalized, field, _unknown_code, duplicate_code) do
    case Map.fetch(normalized, canonical_key) do
      {:ok, _existing} -> {:halt, {:error, config_error(duplicate_code, field, canonical_key)}}
      :error -> {:cont, {:ok, Map.put(normalized, canonical_key, value)}}
    end
  end

  defp canonical_config_key(key) when key in @config_keys, do: key

  defp canonical_config_key(key) when is_binary(key), do: Map.get(@config_key_names, key, :unknown)

  defp canonical_config_key(_key), do: :unknown

  defp canonical_state_key(key) when is_atom(key) do
    if Map.has_key?(@state_groups, key), do: key, else: :unknown
  end

  defp canonical_state_key(key) when is_binary(key), do: Map.get(@canonical_state_names, key, :unknown)
  defp canonical_state_key(_key), do: :unknown

  defp canonical_state_mapping_key(key) when key in @state_mapping_keys, do: key

  defp canonical_state_mapping_key(key) when is_binary(key) do
    case key do
      "state_id" -> :state_id
      "name" -> :name
      "group" -> :group
      _ -> :unknown
    end
  end

  defp canonical_state_mapping_key(_key), do: :unknown

  defp reject_group_redefinition(mapping, state) do
    if Map.has_key?(mapping, :group) do
      {:error, config_error(:state_group_redefinition, state, Map.fetch!(mapping, :group))}
    else
      :ok
    end
  end

  defp validate_mapping_identifier(mapping, state) do
    case attribute(mapping, :state_id) do
      :missing -> {:error, config_error(:invalid_state_id, state)}
      {:ok, value} -> validate_identifier({:ok, value}, state)
    end
  end

  defp validate_mapping_name(mapping, state) do
    case attribute(mapping, :name) do
      :missing ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if valid_bounded_text?(value, @max_name_bytes) do
          {:ok, value}
        else
          {:error, config_error(:invalid_state_name, state, safe_config_value(value))}
        end

      {:ok, value} ->
        {:error, config_error(:invalid_state_name, state, safe_config_value(value))}
    end
  end

  defp reject_duplicate_state_ids(mappings) do
    ids = Enum.map(WorkflowLifecycle.states(), fn state -> Map.fetch!(mappings, state).state_id end)

    case Enum.find(Enum.frequencies(ids), fn {_state_id, count} -> count > 1 end) do
      nil -> :ok
      {duplicate, _count} -> {:error, config_error(:duplicate_state_id, :state_mappings, duplicate)}
    end
  end

  defp reject_caller_fingerprint(attrs) do
    if has_attribute?(attrs, :configuration_fingerprint) do
      {:error, config_error(:fingerprint_is_derived, :configuration_fingerprint)}
    else
      :ok
    end
  end

  defp resolve_dependency_relation_semantics(:missing), do: {:ok, @dependency_relation_semantics}

  defp resolve_dependency_relation_semantics({:ok, value}) when is_map(value) do
    keys = Enum.map(Map.keys(value), &relation_key/1)

    if Enum.sort(keys) == [:blocked_by, :blocking] and
         relation_value(value, :blocked_by) == {:ok, :blocked_by} and
         relation_value(value, :blocking) == {:ok, :blocking} do
      {:ok, @dependency_relation_semantics}
    else
      {:error, config_error(:dependency_relation_redefinition, :dependency_relation_semantics)}
    end
  end

  defp resolve_dependency_relation_semantics({:ok, _value}),
    do: {:error, config_error(:dependency_relation_redefinition, :dependency_relation_semantics)}

  defp resolve_capability_set(:missing, expected, _code), do: {:ok, expected}

  defp resolve_capability_set({:ok, value}, expected, code) when is_list(value) do
    case normalize_capability_list(value) do
      {:ok, normalized} ->
        if Enum.sort(normalized) == Enum.sort(expected) and Enum.uniq(normalized) == normalized do
          {:ok, expected}
        else
          {:error, config_error(code)}
        end

      :error ->
        {:error, config_error(code)}
    end
  end

  defp resolve_capability_set({:ok, _value}, _expected, code), do: {:error, config_error(code)}

  defp relation_key(:blocked_by), do: :blocked_by
  defp relation_key(:blocking), do: :blocking
  defp relation_key("blocked_by"), do: :blocked_by
  defp relation_key("blocking"), do: :blocking
  defp relation_key(_key), do: :unknown

  defp relation_value(map, key) do
    case attribute(map, key) do
      {:ok, :blocked_by} when key == :blocked_by -> {:ok, :blocked_by}
      {:ok, "blocked_by"} when key == :blocked_by -> {:ok, :blocked_by}
      {:ok, :blocking} when key == :blocking -> {:ok, :blocking}
      {:ok, "blocking"} when key == :blocking -> {:ok, :blocking}
      _value -> :error
    end
  end

  defp normalize_capability_list(capabilities) do
    Enum.reduce_while(capabilities, {:ok, []}, fn capability, {:ok, normalized} ->
      case canonical_capability(capability) do
        :unknown -> {:halt, :error}
        canonical -> {:cont, {:ok, normalized ++ [canonical]}}
      end
    end)
  end

  defp canonical_capability(capability) when is_atom(capability) do
    if capability in Capabilities.vocabulary(), do: capability, else: :unknown
  end

  defp canonical_capability(capability) when is_binary(capability) do
    Map.get(@capability_names, capability, :unknown)
  end

  defp canonical_capability(_capability), do: :unknown

  defp attribute(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> {:ok, value}
          :error -> :missing
        end
    end
  end

  defp has_attribute?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp invalid_identifier_code(:workspace_id), do: :invalid_workspace_id
  defp invalid_identifier_code(:project_id), do: :invalid_project_id
  defp invalid_identifier_code(_field), do: :invalid_identifier

  defp valid_bounded_text?(value, max_bytes) when is_binary(value) do
    byte_size(value) <= max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_bounded_text?(_value, _max_bytes), do: false

  defp fingerprint_provider(:plane), do: :plane
  defp fingerprint_provider("plane"), do: :plane
  defp fingerprint_provider(value), do: value

  defp fingerprint_state_mappings(mappings) when is_map(mappings) do
    Enum.map(WorkflowLifecycle.states(), fn state ->
      case Map.get(mappings, state) do
        mapping when is_map(mapping) ->
          {state, Map.get(mapping, :state_id), Map.get(mapping, :group)}

        nil ->
          {state, nil, nil}

        _invalid_mapping ->
          {state, :invalid_state_mapping, :invalid_state_mapping}
      end
    end)
  end

  defp fingerprint_state_mappings(value), do: value

  defp fingerprint_relations(relations) when is_map(relations),
    do: {Map.get(relations, :blocked_by), Map.get(relations, :blocking)}

  defp fingerprint_relations(value), do: value

  defp fingerprint_capabilities(capabilities) when is_list(capabilities), do: Enum.sort(capabilities)
  defp fingerprint_capabilities(value), do: value

  defp config_error(code, field \\ nil, value \\ nil, reason \\ nil) do
    %ConfigError{code: code, field: field, value: safe_config_value(value), reason: reason}
  end

  defp safe_config_value(value) when is_binary(value) do
    if String.valid?(value) do
      String.slice(value, 0, @max_name_bytes)
    else
      "[redacted]"
    end
  end

  defp safe_config_value(value) when is_atom(value) or is_number(value) or is_boolean(value), do: value
  defp safe_config_value(nil), do: nil
  defp safe_config_value(_value), do: "[redacted]"

  defp normalize_provider_group(group) when group in [:backlog, :unstarted, :started, :completed, :cancelled], do: group

  defp normalize_provider_group(group) when is_binary(group) do
    case String.trim(String.downcase(group)) do
      "backlog" -> :backlog
      "unstarted" -> :unstarted
      "started" -> :started
      "completed" -> :completed
      "cancelled" -> :cancelled
      _ -> nil
    end
  end

  defp normalize_provider_group(_group), do: nil
end
