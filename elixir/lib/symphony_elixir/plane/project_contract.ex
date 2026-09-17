defmodule SymphonyElixir.Plane.ProjectContract do
  @moduledoc """
  Pure validation of a configured Plane project contract against a snapshot.

  The snapshot must already have been obtained by a provider boundary. This
  module performs no provider I/O and treats configured stable IDs as the only
  state identity; names are used only for descriptive diagnostics.
  """

  alias SymphonyElixir.Tracker.Capabilities

  alias SymphonyElixir.WorkControl.{ProviderProjectContract, WorkflowLifecycle}

  @max_identifier_bytes 256
  @max_name_bytes 256
  @max_snapshot_states 64
  @max_diagnostic_items 32

  @groups [:backlog, :unstarted, :started, :completed, :cancelled]
  @relation_keys [:blocked_by, :blocking]
  @capabilities Capabilities.vocabulary()

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

  @required_snapshot_fields [
    :provider,
    :workspace_id,
    :project_id,
    :states,
    :dependency_relation_semantics,
    :capability_statuses,
    :completeness
  ]

  @type snapshot :: map()

  @spec validate(ProviderProjectContract.t(), snapshot()) ::
          ProviderProjectContract.ValidationResult.t()
  def validate(%ProviderProjectContract{} = contract, snapshot) when is_map(snapshot) do
    expected_fingerprint = ProviderProjectContract.fingerprint(contract)

    case parse_snapshot(snapshot) do
      {:ok, parsed} ->
        validate_complete_snapshot(contract, parsed, expected_fingerprint)

      {:error, :snapshot_incomplete, diagnostics} ->
        validation_result(:snapshot_incomplete, diagnostics, expected_fingerprint, nil)

      {:error, :provider_malformed, diagnostics} ->
        validation_result(:provider_malformed, diagnostics, expected_fingerprint, nil)
    end
  end

  def validate(_contract, _snapshot) do
    validation_result(
      :provider_malformed,
      [diagnostic(:provider_malformed, field: :contract, reason: :invalid_contract)],
      nil,
      nil
    )
  end

  defp validate_complete_snapshot(contract, snapshot, expected_fingerprint) do
    diagnostics =
      identity_diagnostics(contract, snapshot) ++
        state_diagnostics(contract, snapshot.states) ++
        relation_diagnostics(contract, snapshot.dependency_relation_semantics) ++
        capability_diagnostics(contract, snapshot.capability_statuses)

    observed_fingerprint = observed_fingerprint(contract, snapshot)
    diagnostics = add_fingerprint_diagnostic(diagnostics, expected_fingerprint, observed_fingerprint)

    status =
      if Enum.any?(diagnostics, &authority_diagnostic?/1) do
        :drift_detected
      else
        :valid
      end

    validation_result(status, diagnostics, expected_fingerprint, observed_fingerprint)
  end

  defp identity_diagnostics(contract, snapshot) do
    []
    |> add_mismatch(:provider, contract.provider, snapshot.provider, :provider_identity_mismatch)
    |> add_mismatch(:workspace_id, contract.workspace_id, snapshot.workspace_id, :workspace_identity_mismatch)
    |> add_mismatch(:project_id, contract.project_id, snapshot.project_id, :project_identity_mismatch)
  end

  defp state_diagnostics(contract, states) do
    states_by_id = Map.new(states, &{&1.id, &1})

    Enum.flat_map(WorkflowLifecycle.states(), fn canonical_state ->
      mapping = Map.fetch!(contract.state_mappings, canonical_state)

      case Map.fetch(states_by_id, mapping.state_id) do
        {:ok, observed} ->
          group_diagnostics(canonical_state, mapping, observed) ++
            descriptive_name_diagnostics(canonical_state, mapping, observed)

        :error ->
          [
            diagnostic(
              :state_identity_missing,
              field: :state_id,
              canonical_state: canonical_state,
              expected: mapping.state_id,
              reason: :configured_state_id_not_found
            )
          ]
      end
    end)
  end

  defp group_diagnostics(canonical_state, expected, observed) do
    if expected.group == observed.group do
      []
    else
      [
        diagnostic(
          :state_group_mismatch,
          field: :group,
          canonical_state: canonical_state,
          expected: expected.group,
          observed: observed.group
        )
      ]
    end
  end

  defp descriptive_name_diagnostics(canonical_state, expected, observed) do
    if is_binary(expected.name) and is_binary(observed.name) and expected.name != observed.name do
      [
        diagnostic(
          :descriptive_name_changed,
          field: :name,
          canonical_state: canonical_state,
          expected: expected.name,
          observed: observed.name
        )
      ]
    else
      []
    end
  end

  defp relation_diagnostics(contract, observed_relations) do
    expected_relations = contract.dependency_relation_semantics

    if expected_relations == observed_relations do
      []
    else
      [
        diagnostic(
          :dependency_relation_semantics_mismatch,
          field: :dependency_relation_semantics,
          expected: expected_relations,
          observed: observed_relations
        )
      ]
    end
  end

  defp capability_diagnostics(contract, statuses) do
    required_diagnostics =
      Enum.flat_map(contract.required_capabilities, fn capability ->
        if Map.fetch!(statuses, capability) == :supported do
          []
        else
          [
            diagnostic(
              :required_capability_unavailable,
              field: :capability_status,
              capability: capability,
              expected: :supported,
              observed: Map.fetch!(statuses, capability)
            )
          ]
        end
      end)

    optional_diagnostics =
      Enum.flat_map(contract.optional_capabilities, fn capability ->
        if Map.fetch!(statuses, capability) == :unsupported do
          [
            diagnostic(
              :optional_capability_unavailable,
              field: :capability_status,
              capability: capability,
              expected: :supported,
              observed: :unsupported
            )
          ]
        else
          []
        end
      end)

    required_diagnostics ++ optional_diagnostics
  end

  defp observed_fingerprint(contract, snapshot) do
    states_by_id = Map.new(snapshot.states, &{&1.id, &1})

    observed_mappings =
      Map.new(WorkflowLifecycle.states(), fn canonical_state ->
        expected = Map.fetch!(contract.state_mappings, canonical_state)

        mapping =
          case Map.fetch(states_by_id, expected.state_id) do
            {:ok, observed} -> %{state_id: observed.id, group: observed.group, name: nil}
            :error -> %{state_id: {:missing, expected.state_id}, group: :missing, name: nil}
          end

        {canonical_state, mapping}
      end)

    supported_required_capabilities =
      Enum.filter(contract.required_capabilities, fn capability ->
        Map.fetch!(snapshot.capability_statuses, capability) == :supported
      end)

    observed_contract = %{
      contract
      | provider: snapshot.provider,
        workspace_id: snapshot.workspace_id,
        project_id: snapshot.project_id,
        state_mappings: observed_mappings,
        dependency_relation_semantics: snapshot.dependency_relation_semantics,
        required_capabilities: supported_required_capabilities
    }

    ProviderProjectContract.fingerprint(observed_contract)
  end

  defp add_fingerprint_diagnostic(diagnostics, expected, observed) when expected == observed, do: diagnostics

  defp add_fingerprint_diagnostic(diagnostics, expected, observed) do
    diagnostics ++
      [
        diagnostic(
          :configuration_fingerprint_mismatch,
          field: :configuration_fingerprint,
          expected: expected,
          observed: observed
        )
      ]
  end

  defp authority_diagnostic?(%ProviderProjectContract.Diagnostic{class: class}) do
    class not in [:descriptive_name_changed, :optional_capability_unavailable]
  end

  defp validation_result(status, diagnostics, expected_fingerprint, observed_fingerprint) do
    %ProviderProjectContract.ValidationResult{
      status: status,
      diagnostics: diagnostics,
      expected_fingerprint: expected_fingerprint,
      observed_fingerprint: observed_fingerprint
    }
  end

  defp parse_snapshot(snapshot) do
    case missing_snapshot_fields(snapshot) do
      [] ->
        parse_present_snapshot(snapshot)

      missing ->
        diagnostics =
          Enum.map(missing, fn field ->
            diagnostic(:snapshot_incomplete, field: field, reason: :required_field_missing)
          end)

        {:error, :snapshot_incomplete, diagnostics}
    end
  end

  defp parse_present_snapshot(snapshot) do
    case snapshot_value(snapshot, :completeness) do
      {:ok, :complete} ->
        parse_complete_snapshot(snapshot)

      {:ok, :incomplete} ->
        {:error, :snapshot_incomplete,
         [
           diagnostic(
             :snapshot_incomplete,
             field: :completeness,
             expected: :complete,
             observed: :incomplete
           )
         ]}

      {:ambiguous, field} ->
        {:error, :provider_malformed, [diagnostic(:provider_malformed, field: field, reason: :duplicate_field_key)]}

      {:ok, value} ->
        {:error, :provider_malformed,
         [
           diagnostic(
             :provider_malformed,
             field: :completeness,
             expected: :complete,
             observed: value
           )
         ]}
    end
  end

  defp parse_complete_snapshot(snapshot) do
    with {:ok, provider} <- parse_provider(snapshot_value(snapshot, :provider)),
         {:ok, workspace_id} <- parse_identifier(snapshot_value(snapshot, :workspace_id), :workspace_id),
         {:ok, workspace_name} <- parse_optional_name(snapshot_value(snapshot, :workspace_name), :workspace_name),
         {:ok, project_id} <- parse_identifier(snapshot_value(snapshot, :project_id), :project_id),
         {:ok, project_name} <- parse_optional_name(snapshot_value(snapshot, :project_name), :project_name),
         {:ok, states} <- parse_states(snapshot_value(snapshot, :states)),
         {:ok, relations} <- parse_relations(snapshot_value(snapshot, :dependency_relation_semantics)),
         {:ok, capabilities} <- parse_capabilities(snapshot_value(snapshot, :capability_statuses)) do
      {:ok,
       %{
         provider: provider,
         workspace_id: workspace_id,
         workspace_name: workspace_name,
         project_id: project_id,
         project_name: project_name,
         states: states,
         dependency_relation_semantics: relations,
         capability_statuses: capabilities,
         completeness: :complete
       }}
    else
      {:error, :snapshot_incomplete, field, reason} ->
        {:error, :snapshot_incomplete, [diagnostic(:snapshot_incomplete, field: field, reason: reason)]}

      {:error, :provider_malformed, field, value, reason} ->
        {:error, :provider_malformed, [diagnostic(:provider_malformed, field: field, observed: value, reason: reason)]}
    end
  end

  defp parse_provider({:ok, value}) when is_atom(value) do
    {:ok, value}
  end

  defp parse_provider({:ok, value}) when is_binary(value) do
    if valid_bounded_text?(value, @max_identifier_bytes) do
      {:ok, if(value == "plane", do: :plane, else: value)}
    else
      malformed(:provider, value, :invalid_provider)
    end
  end

  defp parse_provider({:ok, value}), do: malformed(:provider, value, :invalid_provider)
  defp parse_provider(:missing), do: incomplete(:provider, :required_field_missing)
  defp parse_provider({:ambiguous, field}), do: malformed(field, field, :duplicate_field_key)

  defp parse_identifier({:ok, value}, field) do
    if valid_bounded_text?(value, @max_identifier_bytes) do
      {:ok, value}
    else
      malformed(field, value, :invalid_identifier)
    end
  end

  defp parse_identifier(:missing, field), do: incomplete(field, :required_field_missing)
  defp parse_identifier({:ambiguous, _field}, field), do: malformed(field, field, :duplicate_field_key)

  defp parse_name({:ok, value}, field) do
    if valid_bounded_text?(value, @max_name_bytes) do
      {:ok, value}
    else
      malformed(field, value, :invalid_name)
    end
  end

  defp parse_name({:ambiguous, _field}, field), do: malformed(field, field, :duplicate_field_key)

  defp parse_optional_name(:missing, _field), do: {:ok, nil}
  defp parse_optional_name({:ok, nil}, _field), do: {:ok, nil}
  defp parse_optional_name(value, field), do: parse_name(value, field)

  defp parse_states({:ok, states}) when is_list(states) do
    case bounded_list_length(states, @max_snapshot_states) do
      {:ok, _length} -> parse_state_list(states)
      {:too_many, length} -> malformed(:states, length, :too_many_states)
      :improper -> malformed(:states, :improper_list, :invalid_states)
    end
  end

  defp parse_states({:ok, value}), do: malformed(:states, value, :invalid_states)
  defp parse_states(:missing), do: incomplete(:states, :required_field_missing)
  defp parse_states({:ambiguous, field}), do: malformed(field, field, :duplicate_field_key)

  defp reverse_parsed_states({:ok, states, _ids}), do: {:ok, Enum.reverse(states)}
  defp reverse_parsed_states({:error, _kind, _field, _value, _reason} = error), do: error

  defp parse_state_list(states) do
    Enum.reduce_while(states, {:ok, [], MapSet.new()}, fn state, {:ok, parsed, ids} ->
      case parse_state(state) do
        {:ok, normalized} ->
          append_parsed_state(normalized, parsed, ids)

        {:error, _kind, _field, _value, _reason} = error ->
          {:halt, error}
      end
    end)
    |> reverse_parsed_states()
  end

  defp append_parsed_state(normalized, parsed, ids) do
    case MapSet.member?(ids, normalized.id) do
      true -> {:halt, malformed(:states, normalized.id, :duplicate_state_id)}
      false -> {:cont, {:ok, [normalized | parsed], MapSet.put(ids, normalized.id)}}
    end
  end

  defp parse_state(state) when is_map(state) do
    with {:ok, id} <- parse_nested_identifier(state, :id),
         {:ok, group} <- parse_group(nested_value(state, :group)),
         {:ok, name} <- parse_nested_name(state, :name) do
      {:ok, %{id: id, group: group, name: name}}
    end
  end

  defp parse_state(value), do: malformed(:states, value, :invalid_state)

  defp parse_nested_identifier(state, field) do
    parse_identifier(nested_value(state, field), field)
  end

  defp parse_nested_name(state, field) do
    parse_optional_name(nested_value(state, field), field)
  end

  defp parse_group({:ok, value}) when value in @groups, do: {:ok, value}

  defp parse_group({:ok, value}) when is_binary(value) do
    case value do
      "backlog" -> {:ok, :backlog}
      "unstarted" -> {:ok, :unstarted}
      "started" -> {:ok, :started}
      "completed" -> {:ok, :completed}
      "cancelled" -> {:ok, :cancelled}
      _ -> malformed(:group, value, :invalid_group)
    end
  end

  defp parse_group({:ok, value}), do: malformed(:group, value, :invalid_group)
  defp parse_group(:missing), do: incomplete(:group, :required_field_missing)
  defp parse_group({:ambiguous, field}), do: malformed(field, field, :duplicate_field_key)

  defp parse_relations({:ok, relations}) when is_map(relations) do
    with :ok <- validate_relation_keys(relations),
         :ok <- require_relation_keys(relations),
         {:ok, blocked_by} <- parse_relation_value(nested_value(relations, :blocked_by)),
         {:ok, blocking} <- parse_relation_value(nested_value(relations, :blocking)) do
      {:ok, %{blocked_by: blocked_by, blocking: blocking}}
    end
  end

  defp parse_relations({:ok, value}), do: malformed(:dependency_relation_semantics, value, :invalid_relations)
  defp parse_relations(:missing), do: incomplete(:dependency_relation_semantics, :required_field_missing)

  defp validate_relation_keys(relations) do
    case Enum.reduce_while(Map.keys(relations), MapSet.new(), fn key, seen ->
           validate_relation_key(key, seen)
         end) do
      %MapSet{} = _seen -> :ok
      {:error, _kind, _field, _value, _reason} = error -> error
    end
  end

  defp validate_relation_key(key, seen) do
    case canonical_relation(key) do
      :unknown -> {:halt, malformed(:dependency_relation_semantics, key, :unknown_relation)}
      relation -> add_relation_key(relation, seen)
    end
  end

  defp add_relation_key(relation, seen) do
    case MapSet.member?(seen, relation) do
      true -> {:halt, malformed(:dependency_relation_semantics, relation, :duplicate_relation_key)}
      false -> {:cont, MapSet.put(seen, relation)}
    end
  end

  defp require_relation_keys(relations) do
    case Enum.find(@relation_keys, fn key -> nested_value(relations, key) == :missing end) do
      nil -> :ok
      missing -> incomplete(:dependency_relation_semantics, {:missing_relation, missing})
    end
  end

  defp parse_relation_value({:ok, value}) when is_atom(value), do: {:ok, value}

  defp parse_relation_value({:ok, "blocked_by"}), do: {:ok, :blocked_by}
  defp parse_relation_value({:ok, "blocking"}), do: {:ok, :blocking}

  defp parse_relation_value({:ok, value}) when is_binary(value) do
    if valid_bounded_text?(value, @max_identifier_bytes) do
      {:ok, value}
    else
      malformed(:dependency_relation_semantics, value, :invalid_relation)
    end
  end

  defp parse_relation_value({:ok, value}),
    do: malformed(:dependency_relation_semantics, value, :invalid_relation)

  defp parse_relation_value(:missing), do: incomplete(:dependency_relation_semantics, :required_field_missing)
  defp parse_relation_value({:ambiguous, field}), do: malformed(field, field, :duplicate_field_key)

  defp parse_capabilities({:ok, capabilities}) when is_map(capabilities) do
    with :ok <- validate_capability_keys(capabilities),
         :ok <- require_capability_keys(capabilities) do
      normalize_capability_statuses(capabilities)
    end
  end

  defp parse_capabilities({:ok, value}), do: malformed(:capability_statuses, value, :invalid_capability_statuses)
  defp parse_capabilities(:missing), do: incomplete(:capability_statuses, :required_field_missing)

  defp validate_capability_keys(capabilities) do
    case Enum.reduce_while(Map.keys(capabilities), MapSet.new(), fn key, seen ->
           validate_capability_key(key, seen)
         end) do
      %MapSet{} = _seen -> :ok
      {:error, _kind, _field, _value, _reason} = error -> error
    end
  end

  defp validate_capability_key(key, seen) do
    case canonical_capability(key) do
      :unknown -> {:halt, malformed(:capability_statuses, key, :unknown_capability)}
      capability -> add_capability_key(capability, seen)
    end
  end

  defp add_capability_key(capability, seen) do
    case MapSet.member?(seen, capability) do
      true -> {:halt, malformed(:capability_statuses, capability, :duplicate_capability_key)}
      false -> {:cont, MapSet.put(seen, capability)}
    end
  end

  defp require_capability_keys(capabilities) do
    case Enum.find(@capabilities, fn capability -> capability_value(capabilities, capability) == :missing end) do
      nil -> :ok
      missing -> incomplete(:capability_statuses, {:missing_capability, missing})
    end
  end

  defp normalize_capability_statuses(capabilities) do
    Enum.reduce_while(@capabilities, {:ok, %{}}, fn capability, {:ok, normalized} ->
      case capability_value(capabilities, capability) do
        {:ok, :supported} -> {:cont, {:ok, Map.put(normalized, capability, :supported)}}
        {:ok, :unsupported} -> {:cont, {:ok, Map.put(normalized, capability, :unsupported)}}
        {:ok, value} -> {:halt, malformed(:capability_statuses, value, {:invalid_capability_status, capability})}
        :missing -> {:halt, incomplete(:capability_statuses, {:missing_capability, capability})}
        {:ambiguous, field} -> {:halt, malformed(field, field, :duplicate_field_key)}
      end
    end)
  end

  defp canonical_capability(capability) when capability in @capabilities, do: capability

  defp canonical_capability(capability) when is_binary(capability),
    do: Map.get(@capability_names, capability, :unknown)

  defp canonical_capability(_capability), do: :unknown

  defp capability_value(capabilities, capability) do
    snapshot_value(capabilities, capability)
  end

  defp snapshot_value(snapshot, key) do
    case {Map.fetch(snapshot, key), Map.fetch(snapshot, Atom.to_string(key))} do
      {{:ok, _atom_value}, {:ok, _string_value}} ->
        {:ambiguous, key}

      {{:ok, value}, :error} ->
        {:ok, value}

      {:error, {:ok, value}} ->
        {:ok, value}

      {:error, :error} ->
        :missing
    end
  end

  defp nested_value(map, key), do: snapshot_value(map, key)

  defp missing_snapshot_fields(snapshot) do
    Enum.filter(@required_snapshot_fields, &(snapshot_value(snapshot, &1) == :missing))
  end

  defp incomplete(field, reason), do: {:error, :snapshot_incomplete, field, reason}
  defp malformed(field, value, reason), do: {:error, :provider_malformed, field, value, reason}

  defp add_mismatch(diagnostics, _field, expected, observed, _class) when expected == observed, do: diagnostics

  defp add_mismatch(diagnostics, field, expected, observed, class) do
    diagnostics ++ [diagnostic(class, field: field, expected: expected, observed: observed)]
  end

  defp diagnostic(class, attrs) do
    %ProviderProjectContract.Diagnostic{
      class: class,
      field: Keyword.get(attrs, :field),
      canonical_state: Keyword.get(attrs, :canonical_state),
      state: Keyword.get(attrs, :canonical_state),
      capability: Keyword.get(attrs, :capability),
      expected: safe_value(Keyword.get(attrs, :expected)),
      observed: safe_value(Keyword.get(attrs, :observed)),
      reason: safe_reason(Keyword.get(attrs, :reason))
    }
  end

  defp safe_reason(nil), do: nil
  defp safe_reason(value) when is_atom(value), do: value
  defp safe_reason(value) when is_binary(value), do: safe_text(value)
  defp safe_reason(_value), do: :redacted

  defp safe_value(nil), do: nil
  defp safe_value(value) when is_atom(value) or is_number(value) or is_boolean(value), do: value
  defp safe_value(value) when is_binary(value), do: safe_text(value)

  defp safe_value(value) when is_list(value) do
    value
    |> Enum.take(@max_diagnostic_items)
    |> Enum.map(&safe_value/1)
  end

  defp safe_value(value) when is_map(value) do
    value
    |> Map.take(@relation_keys)
    |> Enum.reduce(%{}, fn {key, nested}, safe ->
      Map.put(safe, key, safe_value(nested))
    end)
  end

  defp safe_value(_value), do: :redacted

  defp safe_text(value) when is_binary(value) do
    if String.valid?(value) do
      prefix = binary_part(value, 0, min(byte_size(value), @max_name_bytes))
      if String.valid?(prefix), do: prefix, else: "[truncated]"
    else
      "[redacted]"
    end
  end

  defp valid_bounded_text?(value, max_bytes) when is_binary(value) do
    byte_size(value) <= max_bytes and String.valid?(value) and String.trim(value) != ""
  end

  defp valid_bounded_text?(_value, _max_bytes), do: false

  defp canonical_relation(:blocked_by), do: :blocked_by
  defp canonical_relation(:blocking), do: :blocking
  defp canonical_relation("blocked_by"), do: :blocked_by
  defp canonical_relation("blocking"), do: :blocking
  defp canonical_relation(_key), do: :unknown

  defp bounded_list_length(list, limit), do: bounded_list_length(list, limit, 0)

  defp bounded_list_length([], _limit, length), do: {:ok, length}

  defp bounded_list_length([_head | _tail], limit, length) when length == limit,
    do: {:too_many, length + 1}

  defp bounded_list_length([_head | tail], limit, length),
    do: bounded_list_length(tail, limit, length + 1)

  defp bounded_list_length(_improper_tail, _limit, _length), do: :improper
end
