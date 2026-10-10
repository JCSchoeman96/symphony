defmodule SymphonyElixir.Governance.Check do
  @moduledoc """
  Read-only validation for the repository's derivative governance projection.

  The projection records an already-issued human governance decision. This
  module can report drift at a validation boundary, but it cannot create or
  advance authority.
  """

  @max_projection_bytes 64 * 1024
  @projection_path "docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json"
  @roadmap_path "docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md"
  @pre_080c_02_path "docs/symphony-hardening-playbook-v4.1/PRE-080C-02_PRODUCTION_RATE_EPOCH_CHARACTERIZATION.md"
  @roadmap_blob "4b0528bdc0647d889b42ebc478081d5b873898fe"
  @pre_080c_02_blob "b69d46676d3286262bf7cab783654c10a08801bf"
  @accepted_baseline_sha "0640bf1135f8b5000ea29518c2c456272379e9c6"
  @accepted_baseline_tree "5c6f10cc88c41f395837a930fb7ea20e0bdae0cc"
  @accepted_phase "H-080B"
  @accepted_prerequisite "PRE-080C-02"
  @pre_080c_02_outcome "LIMIT_FOUND"
  @authorized_work_id "PRE-080C-03"
  @authorized_work_status "AUTHORIZED_ACTIVE_NOT_ACCEPTED"
  @authorized_work_scope "GOVERNANCE_DOCUMENTATION_RECONCILIATION_ONLY"
  @pre_h080c "NOT_REACHED"
  @h_080c "NOT_AUTHORIZED"
  @next_governance_step "PRE-H080C"
  @next_authorized_phase nil
  @decision_authority "Master Governance"
  @decision_reference "MG-2026-10-10-PRE-080C-03-AUTH-01"
  @decision_timestamp "2026-10-10T16:35:00+02:00"
  @unresolved_conditions [
    "PRE080C02_LIMIT_FOUND_REQUIRES_PRE_H080C_ADJUDICATION",
    "PRE080C03_NOT_ACCEPTED",
    "PRE_H080C_NOT_REACHED",
    "H080C_NOT_AUTHORIZED"
  ]
  @status_begin "<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->"
  @status_end "<!-- END SYMPHONY_GOVERNANCE_STATUS_V1 -->"
  @watcher_relative_path ".codex/skills/land/land_watch.py"
  @sha_pattern ~r/\A[0-9a-f]{40}\z/
  @status_keys [
    "GOVERNANCE_PROJECTION_PATH",
    "GOVERNING_ROADMAP_ID",
    "GOVERNING_ROADMAP_VERSION",
    "GOVERNING_ROADMAP_BLOB_SHA",
    "ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA",
    "ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE",
    "CURRENT_ACCEPTED_PHASE",
    "CURRENT_ACCEPTED_PREREQUISITE",
    "PRE_080C_02_OUTCOME",
    "CURRENTLY_AUTHORIZED_WORK",
    "CURRENTLY_AUTHORIZED_STATUS",
    "PRE_H080C",
    "H_080C",
    "NEXT_GOVERNANCE_STEP",
    "NEXT_AUTHORIZED_PHASE",
    "DECISION_AUTHORITY",
    "DECISION_REFERENCE",
    "DECISION_TIMESTAMP",
    "KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS"
  ]
  @status_paths [
    "docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md",
    "docs/symphony-hardening-playbook-v4.1/README.md",
    "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md"
  ]
  @required_skill_names ~w(commit debug land linear pull push release)

  @type diagnostic :: %{
          code: atom(),
          path: String.t() | nil,
          detail: String.t()
        }

  @spec validate(Path.t()) :: :ok | {:error, [diagnostic()]}
  def validate(path), do: validate(path, [])

  @spec validate(Path.t(), keyword()) :: :ok | {:error, [diagnostic()]}
  def validate(root, opts) when is_binary(root) and is_list(opts) do
    case validate_options(opts) do
      :ok ->
        validate_repository(root, opts)

      {:error, diagnostics} ->
        {:error, sort_diagnostics(diagnostics)}
    end
  end

  def validate(_root, _opts) do
    {:error, sort_diagnostics([diagnostic(:invalid_path, nil, "repository path and options must be valid")])}
  end

  defp append_validation_result(diagnostics, :ok), do: diagnostics
  defp append_validation_result(diagnostics, {:error, new_diagnostics}), do: diagnostics ++ new_diagnostics

  defp validate_repository(root, opts) do
    case read_projection(root, @projection_path) do
      {:ok, projection} -> validate_repository_contents(root, projection, opts)
      {:error, diagnostics} -> {:error, sort_diagnostics(diagnostics)}
    end
  end

  defp validate_repository_contents(root, projection, opts) do
    diagnostics =
      []
      |> append_validation_result(validate_projection(projection))
      |> append_validation_result(validate_immutable_blobs(root))
      |> append_validation_result(validate_status_documents(root, projection, opts))
      |> append_validation_result(validate_skills(root))
      |> append_validation_result(validate_freeze(root, projection, opts))

    if diagnostics == [], do: :ok, else: {:error, sort_diagnostics(diagnostics)}
  end

  defp validate_options(opts) do
    if Keyword.has_key?(opts, :candidate_phase) and Keyword.get(opts, :freeze) != true do
      {:error, [diagnostic(:candidate_phase_requires_freeze, "candidate_phase", "candidate phase requires freeze mode")]}
    else
      :ok
    end
  end

  defp read_projection(root, relative_path) do
    path = Path.join(root, relative_path)

    case safe_regular_file(root, relative_path) do
      {:ok, _file_path, %{size: size}} when size > @max_projection_bytes ->
        {:error, [diagnostic(:projection_too_large, path, "projection exceeds 64 KiB")]}

      {:ok, file_path, _stat} ->
        case File.read(file_path) do
          {:ok, content} -> parse_projection_content(path, content)
          {:error, reason} -> {:error, [diagnostic(:projection_read_error, path, inspect(reason))]}
        end

      {:error, {:symlink, symlink_path}} ->
        {:error, [diagnostic(:projection_symlink, symlink_path, "projection path cannot contain a symlink")]}

      {:error, :enoent} ->
        {:error, [diagnostic(:projection_missing, path, "projection file does not exist")]}

      {:error, {:not_regular, type}} ->
        {:error, [diagnostic(:projection_read_error, path, "projection path is not a regular file: #{type}")]}

      {:error, reason} ->
        {:error, [diagnostic(:projection_read_error, path, inspect(reason))]}
    end
  end

  defp safe_regular_file(root, relative_path) do
    path = Path.join(root, relative_path)

    case safe_lstat(root, relative_path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, path, stat}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink, relative_path}}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_lstat(root, relative_path) do
    root = Path.expand(root)

    case File.lstat(root) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:symlink, "."}}
      {:ok, _stat} -> safe_lstat_components(root, Path.split(relative_path), root)
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_lstat_components(_root, [], current), do: File.lstat(current)

  defp safe_lstat_components(root, [component | rest], current) do
    path = Path.join(current, component)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} when rest != [] ->
        {:error, {:symlink, Path.relative_to(path, root)}}

      {:ok, _stat} when rest == [] ->
        File.lstat(path)

      {:ok, _stat} ->
        safe_lstat_components(root, rest, path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_projection_content(path, content) when byte_size(content) > @max_projection_bytes do
    {:error, [diagnostic(:projection_too_large, path, "projection exceeds 64 KiB")]}
  end

  defp parse_projection_content(_path, content) do
    case parse_json(content) do
      {:ok, node} -> validate_projection_schema(node)
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp validate_projection_schema(node) do
    spec = projection_schema()

    case schema_object(node, "projection", spec) do
      {projection, []} -> {:ok, projection}
      {_projection, diagnostics} -> {:error, diagnostics}
    end
  end

  defp projection_schema do
    %{
      "schema_version" => {:integer, :schema_version},
      "projection_role" => {:string, :projection_role},
      "governing_roadmap" =>
        {:object,
         %{
           "id" => {:string, :roadmap_id},
           "version" => {:string, :roadmap_version},
           "blob_sha" => {:string, :roadmap_blob}
         }},
      "authority_snapshot" =>
        {:object,
         %{
           "accepted_protected_main_at_decision" =>
             {:object,
              %{
                "sha" => {:string, :accepted_sha},
                "tree" => {:string, :accepted_tree}
              }},
           "current_accepted_phase" => {:string, :current_accepted_phase},
           "current_accepted_prerequisite" => {:string, :current_accepted_prerequisite},
           "pre_080c_02_outcome" => {:string, :pre_080c_02_outcome},
           "currently_authorized_work" =>
             {:object,
              %{
                "id" => {:string, :authorized_work_id},
                "status" => {:string, :authorized_work_status},
                "scope" => {:string, :authorized_work_scope}
              }},
           "pre_h080c" => {:string, :pre_h080c},
           "h_080c" => {:string, :h_080c},
           "next_governance_step" => {:string, :next_governance_step},
           "next_authorized_phase" => {:nullable_string, :next_authorized_phase}
         }},
      "decision" =>
        {:object,
         %{
           "authority" => {:string, :decision_authority},
           "reference" => {:string, :decision_reference},
           "timestamp" => {:string, :decision_timestamp}
         }},
      "known_unresolved_governance_conditions" => {{:array, {:string, :condition}}, :known_unresolved_governance_conditions}
    }
  end

  defp schema_object({:object, pairs}, path, spec) do
    values = Map.new(pairs)
    keys = Map.keys(values)
    expected_keys = Map.keys(spec)

    unknown_diagnostics =
      keys
      |> Enum.reject(&(&1 in expected_keys))
      |> Enum.map(fn key -> diagnostic(:unknown_field, join_path(path, key), "unknown field") end)

    missing_diagnostics =
      expected_keys
      |> Enum.reject(&Map.has_key?(values, &1))
      |> Enum.map(fn key -> diagnostic(:missing_field, join_path(path, key), "required field is missing") end)

    {normalized, type_diagnostics} = Enum.reduce(spec, {%{}, []}, &normalize_schema_field(&1, &2, values, path))

    {normalized, unknown_diagnostics ++ missing_diagnostics ++ type_diagnostics}
  end

  defp schema_object(_node, path, _spec) do
    {nil, [diagnostic(:wrong_type, path, "expected a JSON object")]}
  end

  defp normalize_schema_field({key, descriptor}, {acc, diagnostics}, values, path) do
    case Map.fetch(values, key) do
      {:ok, value} -> normalize_schema_value(key, value, descriptor, acc, diagnostics, path)
      :error -> {acc, diagnostics}
    end
  end

  defp normalize_schema_value(key, value, descriptor, acc, diagnostics, path) do
    case schema_value(value, descriptor, join_path(path, key)) do
      {:ok, normalized_value} -> {Map.put(acc, key, normalized_value), diagnostics}
      {:error, new_diagnostics} -> {acc, diagnostics ++ new_diagnostics}
    end
  end

  defp schema_value(value, {:object, spec}, path), do: schema_object(value, path, spec) |> schema_result()

  defp schema_value(value, {{:array, descriptor}, _label}, path) do
    case value do
      {:array, values} ->
        {normalized, diagnostics} =
          values
          |> Enum.with_index()
          |> Enum.reduce({[], []}, &normalize_array_item(&1, &2, descriptor, path))

        if diagnostics == [] do
          {:ok, Enum.reverse(normalized)}
        else
          {:error, diagnostics}
        end

      _ ->
        {:error, [diagnostic(:wrong_type, path, "expected a JSON array")]}
    end
  end

  defp schema_value(value, {:string, _label}, path) do
    case value do
      {:string, string} when is_binary(string) -> {:ok, string}
      _ -> {:error, [diagnostic(:wrong_type, path, "expected a JSON string")]}
    end
  end

  defp schema_value(value, {:nullable_string, _label}, path) do
    case value do
      :null -> {:ok, nil}
      {:string, string} when is_binary(string) -> {:ok, string}
      _ -> {:error, [diagnostic(:wrong_type, path, "expected null or a JSON string")]}
    end
  end

  defp schema_value(value, {:integer, _label}, path) do
    case value do
      {:number, number} when is_integer(number) -> {:ok, number}
      _ -> {:error, [diagnostic(:wrong_type, path, "expected a JSON integer")]}
    end
  end

  defp normalize_array_item({item, index}, {acc, errors}, descriptor, path) do
    case schema_value(item, descriptor, join_path(path, Integer.to_string(index))) do
      {:ok, normalized_item} -> {[normalized_item | acc], errors}
      {:error, new_errors} -> {acc, errors ++ new_errors}
    end
  end

  defp schema_result({normalized, diagnostics}) do
    if diagnostics == [] do
      {:ok, normalized}
    else
      {:error, diagnostics}
    end
  end

  defp validate_projection(projection) do
    diagnostics =
      []
      |> append_unless(projection["schema_version"] == 1, diagnostic(:unsupported_schema_version, "projection.schema_version", "schema version must be 1"))
      |> append_unless(
        projection["projection_role"] == "MACHINE_PROJECTION_OF_ACCEPTED_AUTHORITY",
        diagnostic(:invalid_projection_role, "projection.projection_role", "projection role is not supported")
      )
      |> append_unless(
        projection["governing_roadmap"]["id"] == @roadmap_path,
        diagnostic(:roadmap_id_mismatch, "projection.governing_roadmap.id", "roadmap id does not match the canonical path")
      )
      |> append_unless(
        projection["governing_roadmap"]["version"] == "V4.1",
        diagnostic(:roadmap_version_mismatch, "projection.governing_roadmap.version", "roadmap version does not match V4.1")
      )
      |> append_unless(
        projection["governing_roadmap"]["blob_sha"] == @roadmap_blob,
        diagnostic(:roadmap_blob_mismatch, "projection.governing_roadmap.blob_sha", "roadmap blob does not match the accepted blob")
      )
      |> append_identity_diagnostics(projection)
      |> append_decision_diagnostics(projection)
      |> append_condition_diagnostics(projection)
      |> append_authority_snapshot_diagnostics(projection)
      |> append_gate_diagnostics(projection)

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp append_identity_diagnostics(diagnostics, projection) do
    roadmap_blob = projection["governing_roadmap"]["blob_sha"]
    accepted = projection["authority_snapshot"]["accepted_protected_main_at_decision"]

    diagnostics
    |> append_unless(
      Regex.match?(@sha_pattern, roadmap_blob),
      diagnostic(:invalid_sha, "projection.governing_roadmap.blob_sha", "value must be 40 lowercase hexadecimal characters")
    )
    |> append_unless(
      Regex.match?(@sha_pattern, accepted["sha"]),
      diagnostic(:invalid_sha, "projection.authority_snapshot.accepted_protected_main_at_decision.sha", "value must be 40 lowercase hexadecimal characters")
    )
    |> append_unless(
      Regex.match?(@sha_pattern, accepted["tree"]),
      diagnostic(:invalid_tree, "projection.authority_snapshot.accepted_protected_main_at_decision.tree", "value must be 40 lowercase hexadecimal characters")
    )
  end

  defp append_decision_diagnostics(diagnostics, projection) do
    decision = projection["decision"]
    reference = decision["reference"]
    timestamp = decision["timestamp"]

    diagnostics
    |> append_unless(
      nonblank?(decision["authority"]),
      diagnostic(:invalid_decision_authority, "projection.decision.authority", "decision authority must be nonblank")
    )
    |> append_unless(
      nonblank?(reference) and not placeholder?(reference),
      diagnostic(:invalid_decision_reference, "projection.decision.reference", "decision reference must be nonblank and resolved")
    )
    |> append_unless(
      valid_timestamp?(timestamp) and not placeholder?(timestamp),
      diagnostic(:invalid_decision_timestamp, "projection.decision.timestamp", "decision timestamp must include a timezone or offset")
    )
  end

  defp append_condition_diagnostics(diagnostics, projection) do
    conditions = projection["known_unresolved_governance_conditions"]

    diagnostics
    |> append_unless(
      Enum.all?(conditions, &nonblank?/1),
      diagnostic(:invalid_unresolved_condition, "projection.known_unresolved_governance_conditions", "conditions must be nonblank")
    )
    |> append_unless(
      length(Enum.uniq(conditions)) == length(conditions),
      diagnostic(:duplicate_unresolved_condition, "projection.known_unresolved_governance_conditions", "conditions must be unique")
    )
  end

  defp append_authority_snapshot_diagnostics(diagnostics, projection) do
    authority = projection["authority_snapshot"]
    accepted = authority["accepted_protected_main_at_decision"]
    authorized = authority["currently_authorized_work"]
    decision = projection["decision"]
    conditions = projection["known_unresolved_governance_conditions"]

    diagnostics
    |> append_exact_diagnostic(
      accepted["sha"],
      @accepted_baseline_sha,
      "projection.authority_snapshot.accepted_protected_main_at_decision.sha",
      :authority_snapshot_mismatch
    )
    |> append_exact_diagnostic(
      accepted["tree"],
      @accepted_baseline_tree,
      "projection.authority_snapshot.accepted_protected_main_at_decision.tree",
      :authority_snapshot_mismatch
    )
    |> append_exact_diagnostic(authority["current_accepted_phase"], @accepted_phase, "projection.authority_snapshot.current_accepted_phase", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(
      authority["current_accepted_prerequisite"],
      @accepted_prerequisite,
      "projection.authority_snapshot.current_accepted_prerequisite",
      :authority_snapshot_mismatch
    )
    |> append_exact_diagnostic(authority["pre_080c_02_outcome"], @pre_080c_02_outcome, "projection.authority_snapshot.pre_080c_02_outcome", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(authorized["id"], @authorized_work_id, "projection.authority_snapshot.currently_authorized_work.id", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(
      authorized["status"],
      @authorized_work_status,
      "projection.authority_snapshot.currently_authorized_work.status",
      :authority_snapshot_mismatch
    )
    |> append_exact_diagnostic(
      authorized["scope"],
      @authorized_work_scope,
      "projection.authority_snapshot.currently_authorized_work.scope",
      :authority_snapshot_mismatch
    )
    |> append_exact_diagnostic(authority["pre_h080c"], @pre_h080c, "projection.authority_snapshot.pre_h080c", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(authority["h_080c"], @h_080c, "projection.authority_snapshot.h_080c", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(authority["next_governance_step"], @next_governance_step, "projection.authority_snapshot.next_governance_step", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(authority["next_authorized_phase"], @next_authorized_phase, "projection.authority_snapshot.next_authorized_phase", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(decision["authority"], @decision_authority, "projection.decision.authority", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(decision["reference"], @decision_reference, "projection.decision.reference", :authority_snapshot_mismatch)
    |> append_exact_diagnostic(decision["timestamp"], @decision_timestamp, "projection.decision.timestamp", :authority_snapshot_mismatch)
    |> append_unless(
      Enum.sort(conditions) == Enum.sort(@unresolved_conditions),
      diagnostic(
        :authority_snapshot_mismatch,
        "projection.known_unresolved_governance_conditions",
        "conditions do not match the approved PRE-080C-03 snapshot"
      )
    )
  end

  defp append_exact_diagnostic(diagnostics, actual, expected, path, code) do
    append_unless(diagnostics, actual == expected, diagnostic(code, path, "value does not match the approved PRE-080C-03 snapshot"))
  end

  defp append_gate_diagnostics(diagnostics, projection) do
    authority = projection["authority_snapshot"]

    if authority["pre_h080c"] == "NOT_REACHED" and
         (authority["h_080c"] != "NOT_AUTHORIZED" or authority["next_authorized_phase"] != nil) do
      diagnostics ++
        [
          diagnostic(
            :invalid_gate_state,
            "projection.authority_snapshot",
            "an unreached PRE-H080C gate cannot authorize H-080C or a next phase"
          )
        ]
    else
      diagnostics
    end
  end

  defp validate_immutable_blobs(root) do
    checks = [{@roadmap_path, @roadmap_blob}, {@pre_080c_02_path, @pre_080c_02_blob}]

    diagnostics = Enum.flat_map(checks, &validate_immutable_blob(root, &1))

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp validate_immutable_blob(root, {relative_path, expected_blob}) do
    case safe_regular_file(root, relative_path) do
      {:ok, path, %{mode: mode}} ->
        validate_immutable_file(path, mode, relative_path, expected_blob)

      {:error, {:symlink, symlink_path}} ->
        [diagnostic(:immutable_blob_symlink, symlink_path, "immutable path cannot contain a symlink")]

      {:error, :enoent} ->
        [diagnostic(:immutable_blob_missing, relative_path, "immutable file does not exist")]

      {:error, {:not_regular, type}} ->
        [diagnostic(:immutable_blob_read_error, relative_path, "immutable path is not a regular file: #{type}")]

      {:error, reason} ->
        [diagnostic(:immutable_blob_read_error, relative_path, inspect(reason))]
    end
  end

  defp validate_immutable_file(path, mode, relative_path, expected_blob) do
    case File.read(path) do
      {:ok, content} ->
        immutable_mode_diagnostics(mode, relative_path) ++
          immutable_blob_diagnostics(relative_path, content, expected_blob)

      {:error, reason} ->
        [diagnostic(:immutable_blob_read_error, relative_path, inspect(reason))]
    end
  end

  defp immutable_mode_diagnostics(mode, relative_path) do
    if regular_git_mode(mode) == "100644" do
      []
    else
      [diagnostic(:immutable_blob_mode_mismatch, relative_path, "immutable file must have regular 0644 mode")]
    end
  end

  defp immutable_blob_diagnostics(relative_path, content, expected_blob) do
    if git_blob_sha(content) == expected_blob do
      []
    else
      [diagnostic(:immutable_blob_mismatch, relative_path, "content does not match the accepted immutable blob")]
    end
  end

  defp validate_status_documents(root, projection, _opts) do
    expected = status_values(projection, @projection_path)

    diagnostics =
      Enum.flat_map(@status_paths, &validate_status_document(root, &1, expected))

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp validate_status_document(root, relative_path, expected) do
    case safe_regular_file(root, relative_path) do
      {:ok, path, _stat} ->
        read_status_document(path, relative_path, expected)

      {:error, {:symlink, symlink_path}} ->
        [diagnostic(:status_document_symlink, symlink_path, "status document path cannot contain a symlink")]

      {:error, :enoent} ->
        [diagnostic(:status_document_missing, relative_path, "status document does not exist")]

      {:error, {:not_regular, type}} ->
        [diagnostic(:status_document_read_error, relative_path, "status document is not a regular file: #{type}")]

      {:error, reason} ->
        [diagnostic(:status_document_read_error, relative_path, inspect(reason))]
    end
  end

  defp read_status_document(path, relative_path, expected) do
    case File.read(path) do
      {:ok, content} -> parse_status_block(content, relative_path, expected)
      {:error, reason} -> [diagnostic(:status_document_read_error, relative_path, inspect(reason))]
    end
  end

  defp status_values(projection, projection_relative_path) do
    roadmap = projection["governing_roadmap"]
    authority = projection["authority_snapshot"]
    accepted = authority["accepted_protected_main_at_decision"]
    authorized = authority["currently_authorized_work"]
    decision = projection["decision"]

    %{
      "GOVERNANCE_PROJECTION_PATH" => projection_relative_path,
      "GOVERNING_ROADMAP_ID" => roadmap["id"],
      "GOVERNING_ROADMAP_VERSION" => roadmap["version"],
      "GOVERNING_ROADMAP_BLOB_SHA" => roadmap["blob_sha"],
      "ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA" => accepted["sha"],
      "ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE" => accepted["tree"],
      "CURRENT_ACCEPTED_PHASE" => authority["current_accepted_phase"],
      "CURRENT_ACCEPTED_PREREQUISITE" => authority["current_accepted_prerequisite"],
      "PRE_080C_02_OUTCOME" => authority["pre_080c_02_outcome"],
      "CURRENTLY_AUTHORIZED_WORK" => authorized["id"],
      "CURRENTLY_AUTHORIZED_STATUS" => authorized["status"],
      "PRE_H080C" => authority["pre_h080c"],
      "H_080C" => authority["h_080c"],
      "NEXT_GOVERNANCE_STEP" => authority["next_governance_step"],
      "NEXT_AUTHORIZED_PHASE" => authority["next_authorized_phase"] || "NONE",
      "DECISION_AUTHORITY" => decision["authority"],
      "DECISION_REFERENCE" => decision["reference"],
      "DECISION_TIMESTAMP" => decision["timestamp"],
      "KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS" => Enum.join(projection["known_unresolved_governance_conditions"], ",")
    }
  end

  defp parse_status_block(content, relative_path, expected) do
    begin_count = count_occurrences(content, @status_begin)
    end_count = count_occurrences(content, @status_end)

    cond do
      begin_count == 0 or end_count == 0 ->
        [diagnostic(:status_block_missing, relative_path, "exactly one status block is required")]

      begin_count != 1 or end_count != 1 ->
        [diagnostic(:status_block_duplicate, relative_path, "exactly one status block is required")]

      true ->
        with {:ok, block} <- extract_status_block(content),
             {:ok, values} <- parse_status_entries(block, relative_path) do
          compare_status_values(values, expected, relative_path)
        else
          {:error, diagnostics} -> diagnostics
        end
    end
  end

  defp extract_status_block(content) do
    with [_, after_begin] <- String.split(content, @status_begin, parts: 2),
         [block, _after_end] <- String.split(after_begin, @status_end, parts: 2) do
      {:ok, block}
    else
      _ -> {:error, [diagnostic(:status_block_malformed, nil, "status block delimiters are out of order")]}
    end
  end

  defp parse_status_entries(block, relative_path) do
    {values, diagnostics} =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({%{}, []}, &parse_status_line(&1, &2, relative_path))

    missing =
      @status_keys
      |> Enum.reject(&Map.has_key?(values, &1))
      |> Enum.map(fn key -> diagnostic(:status_block_missing_key, relative_path <> ":" <> key, "status key is missing") end)

    if diagnostics == [] and missing == [] do
      {:ok, values}
    else
      {:error, diagnostics ++ missing}
    end
  end

  defp parse_status_line(line, {values, diagnostics}, relative_path) do
    case String.split(line, "=", parts: 2) do
      [key, value] when key != "" -> parse_status_key(key, value, values, diagnostics, relative_path)
      _ -> {values, diagnostics ++ [diagnostic(:status_block_malformed, relative_path, "status entries must use KEY=VALUE")]}
    end
  end

  defp parse_status_key(key, value, values, diagnostics, relative_path) do
    cond do
      key not in @status_keys ->
        {values, diagnostics ++ [diagnostic(:status_block_unknown_key, relative_path <> ":" <> key, "unknown status key")]}

      Map.has_key?(values, key) ->
        {values, diagnostics ++ [diagnostic(:status_block_duplicate_key, relative_path <> ":" <> key, "status key appears more than once")]}

      true ->
        {Map.put(values, key, value), diagnostics}
    end
  end

  defp compare_status_values(values, expected, relative_path) do
    diagnostics =
      @status_keys
      |> Enum.flat_map(fn key ->
        if values[key] == expected[key] do
          []
        else
          [diagnostic(:status_mismatch, relative_path <> ":" <> key, "status value differs from the projection")]
        end
      end)

    diagnostics
  end

  defp validate_skills(root) do
    {skill_paths, tree_diagnostics} = scan_skill_tree(root, ".codex/skills")
    skill_paths = Enum.reject(skill_paths, &(&1 == @watcher_relative_path))

    required_paths =
      [".codex/skills/README.md" | Enum.map(@required_skill_names, &Path.join([".codex/skills", &1, "SKILL.md"]))]

    diagnostics =
      required_skill_diagnostics(root, required_paths) ++
        tree_diagnostics ++
        Enum.flat_map(skill_paths, &skill_file_diagnostics(root, &1)) ++
        watcher_diagnostics(root)

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp scan_skill_tree(root, relative_path) do
    case safe_lstat(root, relative_path) do
      {:ok, %File.Stat{type: :directory}} ->
        scan_skill_directory(root, relative_path)

      {:ok, %File.Stat{type: :symlink}} ->
        {[], [diagnostic(:skill_symlink, relative_path, "skill tree cannot contain a symlink")]}

      {:ok, %File.Stat{type: type}} ->
        {[], [diagnostic(:skill_entry_invalid, relative_path, "skill tree entry is not a directory: #{type}")]}

      {:error, reason} ->
        {[], [diagnostic(:skill_read_error, relative_path, inspect(reason))]}
    end
  end

  defp scan_skill_directory(root, relative_path) do
    path = Path.join(root, relative_path)

    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce({[], []}, &scan_skill_entry(root, relative_path, &1, &2))
        |> then(fn {paths, diagnostics} -> {Enum.sort(paths), diagnostics} end)

      {:error, reason} ->
        {[], [diagnostic(:skill_read_error, relative_path, inspect(reason))]}
    end
  end

  defp scan_skill_entry(root, relative_path, entry, {paths, diagnostics}) do
    child = Path.join(relative_path, entry)

    case safe_lstat(root, child) do
      {:ok, %File.Stat{type: :directory}} ->
        {nested_paths, nested_diagnostics} = scan_skill_tree(root, child)
        {nested_paths ++ paths, nested_diagnostics ++ diagnostics}

      {:ok, %File.Stat{type: :regular}} ->
        {[child | paths], diagnostics}

      {:ok, %File.Stat{type: :symlink}} ->
        {paths, [diagnostic(:skill_symlink, child, "skill tree cannot contain a symlink") | diagnostics]}

      {:ok, %File.Stat{type: type}} ->
        {paths, [diagnostic(:skill_entry_invalid, child, "skill tree entry is not a regular file or directory: #{type}") | diagnostics]}

      {:error, reason} ->
        {paths, [diagnostic(:skill_read_error, child, inspect(reason)) | diagnostics]}
    end
  end

  defp required_skill_diagnostics(root, required_paths) do
    Enum.flat_map(required_paths, fn relative_path ->
      case safe_regular_file(root, relative_path) do
        {:ok, _path, _stat} -> []
        {:error, {:symlink, symlink_path}} -> [diagnostic(:skill_symlink, symlink_path, "skill instruction path cannot contain a symlink")]
        {:error, :enoent} -> [diagnostic(:required_skill_missing, relative_path, "required current skill file does not exist")]
        {:error, _reason} -> [diagnostic(:required_skill_missing, relative_path, "required current skill file is not a regular file")]
      end
    end)
  end

  defp skill_file_diagnostics(root, path) do
    case safe_regular_file(root, path) do
      {:ok, file_path, _stat} -> read_skill_file(file_path, path)
      {:error, {:symlink, symlink_path}} -> [diagnostic(:skill_symlink, symlink_path, "skill instruction path cannot contain a symlink")]
      {:error, reason} -> [diagnostic(:skill_read_error, path, inspect(reason))]
    end
  end

  defp read_skill_file(path, relative_path) do
    case File.read(path) do
      {:ok, content} ->
        if String.valid?(content) do
          skill_content_diagnostics(content, relative_path)
        else
          [diagnostic(:skill_non_text, relative_path, "skill file must be valid UTF-8 text")]
        end

      {:error, reason} ->
        [diagnostic(:skill_read_error, relative_path, inspect(reason))]
    end
  end

  defp skill_content_diagnostics(content, @watcher_relative_path) do
    watcher_content_diagnostics(content, @watcher_relative_path)
  end

  defp skill_content_diagnostics(content, relative_path) do
    marker_diagnostics =
      if skill_marker_required?(relative_path) do
        skill_marker_diagnostics(content, relative_path)
      else
        []
      end

    marker_diagnostics ++ skill_policy_diagnostics(content, relative_path)
  end

  defp skill_marker_required?(relative_path), do: Path.extname(relative_path) == ".md"

  defp watcher_diagnostics(root) do
    case safe_regular_file(root, @watcher_relative_path) do
      {:ok, path, _stat} -> read_skill_file(path, @watcher_relative_path)
      {:error, :enoent} -> [diagnostic(:land_watch_marker_missing, @watcher_relative_path, "land watcher does not exist")]
      {:error, _reason} -> []
    end
  end

  defp watcher_content_diagnostics(content, relative_path) do
    marker_diagnostics =
      if watcher_marker_present?(content) do
        []
      else
        [diagnostic(:land_watch_marker_missing, relative_path, "advisory marker is required")]
      end

    marker_diagnostics ++
      watcher_output_diagnostics(content, relative_path) ++
      skill_policy_diagnostics(content, relative_path)
  end

  defp watcher_marker_present?(content) do
    content
    |> String.split(~r/\r?\n/, trim: false)
    |> Enum.take(12)
    |> Enum.reduce_while(nil, fn line, triple_quote ->
      if triple_quote == nil and Regex.match?(~r/^[[:blank:]]*#[[:blank:]]*SYMPHONY_AUTHORITY_CLASS:[[:blank:]]*ADVISORY_NON_AUTHORITY[[:blank:]]*$/, line) do
        {:halt, true}
      else
        {:cont, watcher_triple_quote_state(line, triple_quote)}
      end
    end) == true
  end

  defp watcher_triple_quote_state(line, nil) do
    case Regex.run(~r/("""|''')/, line) do
      [delimiter | _captures] ->
        if rem(length(:binary.matches(line, delimiter)), 2) == 1, do: delimiter, else: nil

      nil ->
        nil
    end
  end

  defp watcher_triple_quote_state(line, delimiter) do
    if rem(length(:binary.matches(line, delimiter)), 2) == 1, do: nil, else: delimiter
  end

  defp watcher_output_diagnostics(content, relative_path) do
    if watcher_checks_passed_output?(content) do
      [diagnostic(:skill_policy_violation, relative_path, "watcher output must not report Checks passed")]
    else
      []
    end
  end

  defp skill_marker_diagnostics(content, relative_path) do
    markers =
      Regex.scan(~r/<!--\s*SYMPHONY_AUTHORITY_CLASS:\s*([A-Z_]+)\s*-->/, content, capture: :all_but_first)
      |> List.flatten()

    cond do
      markers == [] ->
        [diagnostic(:skill_marker_missing, relative_path, "an allowed authority-class marker is required")]

      Enum.any?(markers, &(&1 not in ["PROCEDURAL_NON_AUTHORITY", "LEGACY_COMPATIBILITY_PROCEDURE"])) ->
        [diagnostic(:skill_marker_invalid, relative_path, "authority-class marker is not allowed")]

      Path.basename(Path.dirname(relative_path)) == "linear" and markers != ["LEGACY_COMPATIBILITY_PROCEDURE"] ->
        [diagnostic(:skill_marker_invalid, relative_path, "linear must use the legacy compatibility marker")]

      true ->
        []
    end
  end

  defp skill_policy_diagnostics(content, relative_path) do
    diagnostics = []

    diagnostics =
      if active_merge_instruction?(content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "skills cannot contain an autonomous merge command")]
      else
        diagnostics
      end

    diagnostics =
      if active_green_authority_claim?(content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "green checks do not grant merge or acceptance authority")]
      else
        diagnostics
      end

    diagnostics =
      if active_no_required_checks_claim?(content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "required checks must not be dismissed")]
      else
        diagnostics
      end

    diagnostics =
      if unqualified_checks_passed_output?(content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "watcher output must identify observations as advisory")]
      else
        diagnostics
      end

    diagnostics =
      if active_protected_push_instruction?(content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "skills cannot push directly to protected main")]
      else
        diagnostics
      end

    if raw_lifecycle_recipe?(content) do
      diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "skills cannot contain a raw Linear lifecycle mutation recipe")]
    else
      diagnostics
    end
  end

  defp active_merge_instruction?(content) do
    command_pattern = ~r/\bgh\s+pr\s+merge\b|\bmerge\s+(?:(?:the|this|a)\s+)?(?:pull\s+request|pr)\b/i

    Enum.any?(policy_clauses(content), &active_command_clause?(&1, command_pattern))
  end

  defp active_protected_push_instruction?(content) do
    command_pattern =
      ~r/\bgit\s+push\b[^.!?;]*\b(?:HEAD:(?:main|master)|main|master)\b|\bpush\s+(?:(?:this|the)\s+branch)\s+to\s+(?:protected\s+)?(?:main|master)\b/i

    Enum.any?(policy_clauses(content), &active_command_clause?(&1, command_pattern))
  end

  defp unqualified_checks_passed_output?(content) do
    content
    |> normalize_policy_content()
    |> String.split("\n")
    |> Enum.any?(fn line ->
      Regex.match?(~r/\bchecks\s+passed\b/i, line) and
        not Regex.match?(~r/advisory|observation|informational|not\s+authority|not\s+proof|does\s+not\s+prove/i, line)
    end)
  end

  defp active_green_authority_claim?(content) do
    Enum.any?(policy_clauses(content), fn clause ->
      positive_claim =
        Regex.match?(
          ~r/green\s+(?:ci|checks?).{0,100}(?:grant|authoriz|permit|prove|mean|allow).{0,60}(?:merge|accept)|(?:merge|accept).{0,100}green\s+(?:ci|checks?).{0,60}(?:grant|authoriz|permit|prove|mean|allow)|(?:ci|checks?).{0,40}green.{0,100}(?:grant|authoriz|permit|prove|mean|allow).{0,60}(?:merge|accept)|(?:merge|accept).{0,100}(?:grant|authoriz|permit|prove|mean|allow).{0,100}(?:green\s+(?:ci|checks?)|(?:ci|checks?)\s+(?:is\s+)?green)/is,
          clause
        ) or
          Regex.match?(~r/ci\s+passed.{0,100}(?:accept|approv|merge|ship|land)|(?:accept|approv|merge|ship|land).{0,100}ci\s+passed/is, clause)

      positive_claim and not authority_claim_prohibited?(clause)
    end) or active_connector_claim?(content)
  end

  defp active_connector_claim?(content) do
    patterns = [
      ~r/\bci\s+passed\s*(?:,|;)\s*(?:so|therefore)\s+[^.!?;]+/i,
      ~r/\b(?:green\s+(?:ci|checks?)|(?:ci|checks?)\s+(?:is\s+)?green)\s*(?:,|;)\s*(?:so|therefore)\s+[^.!?;]+/i
    ]

    content = normalize_policy_content(content)

    Enum.any?(patterns, fn pattern ->
      case Regex.run(pattern, content) do
        [match | _captures] -> not authority_claim_prohibited?(match)
        nil -> false
      end
    end)
  end

  defp policy_clauses(content) do
    content
    |> normalize_policy_content()
    |> String.split(~r/\r?\n+/, trim: true)
    |> Enum.flat_map(&Regex.split(~r/[.!?;]+|,\s*(?=(?:but|however|so|then|and)\b)/i, &1, trim: true))
  end

  defp normalize_policy_content(content) do
    Regex.replace(~r/\\\r?\n[[:blank:]]*/m, content, "")
  end

  defp active_command_clause?(clause, command_pattern) do
    matches = Regex.scan(command_pattern, clause, return: :index)

    Enum.zip([nil | matches], matches)
    |> Enum.any?(&active_command_occurrence?(clause, &1))
  end

  defp active_command_occurrence?(clause, {previous_match, [{start, length}]}) do
    previous_end = command_match_end(previous_match)
    prefix = binary_part(clause, previous_end, start - previous_end)
    suffix_start = start + length
    suffix = binary_part(clause, suffix_start, byte_size(clause) - suffix_start)

    not prohibited_command_occurrence?(prefix, suffix)
  end

  defp command_match_end(nil), do: 0
  defp command_match_end([{start, length}]), do: start + length

  defp prohibited_command_occurrence?(prefix, suffix) do
    Regex.match?(
      ~r/\b(?:do\s+not|don't|does\s+not|must\s+not|cannot|never|forbidden|prohibited|avoid)\b[^.!?;]{0,48}$/i,
      prefix
    ) or
      Regex.match?(~r/^\s*(?:is|are)\s+(?:not\s+allowed|prohibited|forbidden)\b/i, suffix)
  end

  defp authority_claim_prohibited?(clause) do
    Regex.match?(
      ~r/\b(?:do\s+not|don't|does\s+not|must\s+not|cannot|never|forbidden|prohibited|avoid|is\s+not|are\s+not)\b.{0,100}\b(?:grant|authoriz|permit|prove|mean|allow|accept|approv|merge|ship|land)\b/is,
      clause
    )
  end

  defp watcher_checks_passed_output?(content) do
    content = normalize_policy_content(content)

    collapsed_content = Regex.replace(~r/["'`+<>]/, content, "")

    Regex.match?(~r/\bchecks\s+passed\b/i, collapsed_content) or assigned_watcher_output?(content)
  end

  defp assigned_watcher_output?(content) do
    assignments = watcher_string_assignments(content)

    Regex.scan(~r/\bprint\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\+\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/i, content, capture: :all_but_first)
    |> Enum.any?(fn [left, right] ->
      case {Map.get(assignments, left), Map.get(assignments, right)} do
        {left_value, right_value} when is_binary(left_value) and is_binary(right_value) ->
          Regex.match?(~r/\bchecks\s+passed\b/i, left_value <> right_value)

        _ ->
          false
      end
    end)
  end

  defp watcher_string_assignments(content) do
    content = Regex.replace(~r/[;\r\n]+/, content, "\n")

    double_quoted =
      Regex.scan(~r/^[[:blank:]]*([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*=[[:blank:]]*"([^"\r\n]*)"[[:blank:]]*$/m, content, capture: :all_but_first)

    single_quoted =
      Regex.scan(~r/^[[:blank:]]*([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*=[[:blank:]]*'([^'\r\n]*)'[[:blank:]]*$/m, content, capture: :all_but_first)

    Map.new(double_quoted ++ single_quoted, fn [name, value] -> {name, value} end)
  end

  defp active_no_required_checks_claim?(content) do
    Regex.match?(
      ~r/(?:this|the)\s+repo(?:sitory)?\s+(?:has|have|contains?)\s+no\s+required\s+checks|(?:there|we)\s+are\s+no\s+required\s+checks|no\s+required\s+checks\s+(?:exist|apply|are\s+required)/i,
      content
    )
  end

  defp raw_lifecycle_recipe?(content) do
    fenced_blocks =
      (Regex.scan(~r/```[^\r\n]*\r?\n(.*?)```/is, content, capture: :all_but_first) ++
         Regex.scan(~r/~~~[^\r\n]*\r?\n(.*?)~~~/is, content, capture: :all_but_first))
      |> List.flatten()

    unfenced_content = Regex.replace(~r/```[^\r\n]*\r?\n.*?```/is, content, "")
    unfenced_content = Regex.replace(~r/~~~[^\r\n]*\r?\n.*?~~~/is, unfenced_content, "")

    Enum.any?(fenced_blocks, &raw_lifecycle_mutation_block?/1) or
      Regex.match?(~r/^\s*mutation\b.{0,1200}\bissueUpdate\b.{0,400}\bstateId\b/ims, unfenced_content) or
      Regex.match?(~r/issueUpdate\s*[({][^\n]{0,160}\bstateId\s*:/is, unfenced_content)
  end

  defp raw_lifecycle_mutation_block?(block) do
    Regex.match?(~r/^\s*mutation\b.{0,1200}\bissueUpdate\b.{0,400}\bstateId\b/ims, block)
  end

  defp validate_freeze(root, projection, opts) do
    if Keyword.get(opts, :freeze, false) != true do
      :ok
    else
      validate_freeze_enabled(root, projection, opts)
    end
  end

  defp validate_freeze_enabled(root, projection, opts) do
    candidate_phase = Keyword.get(opts, :candidate_phase)
    authorized_work = projection["authority_snapshot"]["currently_authorized_work"]
    baseline = projection["authority_snapshot"]["accepted_protected_main_at_decision"]

    diagnostics =
      []
      |> append_unless(
        is_binary(candidate_phase) and nonblank?(candidate_phase),
        diagnostic(:candidate_phase_required, nil, "freeze mode requires --candidate-phase")
      )
      |> append_unless(
        is_binary(candidate_phase) and candidate_phase == authorized_work["id"],
        diagnostic(:candidate_phase_mismatch, "candidate_phase", "candidate phase does not match the projection")
      )

    if diagnostics != [] do
      {:error, diagnostics}
    else
      freeze_git_diagnostics(root, baseline)
    end
  end

  defp freeze_git_diagnostics(root, baseline) do
    accepted_sha = baseline["sha"]
    accepted_tree = baseline["tree"]

    diagnostics =
      [
        check_baseline_commit(root, accepted_sha),
        check_baseline_tree(root, accepted_sha, accepted_tree),
        check_candidate_head(root),
        check_candidate_ancestry(root, accepted_sha),
        check_immutable_tree_entries(root),
        check_candidate_worktree(root)
      ]
      |> List.flatten()

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
  end

  defp check_baseline_commit(root, accepted_sha) do
    case git(root, ["rev-parse", "--verify", accepted_sha <> "^{commit}"]) do
      {_output, 0} -> []
      _ -> [diagnostic(:baseline_commit_missing, "authority_snapshot.accepted_protected_main_at_decision.sha", "accepted baseline commit is not available locally")]
    end
  end

  defp check_baseline_tree(root, accepted_sha, accepted_tree) do
    case git(root, ["rev-parse", "--verify", accepted_sha <> "^{tree}"]) do
      {output, 0} ->
        if String.trim(output) == accepted_tree do
          []
        else
          [diagnostic(:baseline_tree_mismatch, "authority_snapshot.accepted_protected_main_at_decision.tree", "accepted baseline tree does not match Git")]
        end

      _ ->
        [diagnostic(:baseline_tree_missing, "authority_snapshot.accepted_protected_main_at_decision.tree", "accepted baseline tree is not available locally")]
    end
  end

  defp check_candidate_head(root) do
    case git(root, ["rev-parse", "--verify", "HEAD"]) do
      {_output, 0} -> []
      _ -> [diagnostic(:candidate_head_missing, nil, "candidate HEAD is not available locally")]
    end
  end

  defp check_candidate_ancestry(root, accepted_sha) do
    case git(root, ["merge-base", "--is-ancestor", accepted_sha, "HEAD"]) do
      {_output, 0} -> []
      _ -> [diagnostic(:candidate_not_descended, nil, "candidate HEAD does not descend from the accepted baseline")]
    end
  end

  defp check_immutable_tree_entries(root) do
    checks = [{@roadmap_path, @roadmap_blob}, {@pre_080c_02_path, @pre_080c_02_blob}]

    Enum.flat_map(checks, &check_immutable_tree_entry(root, &1))
  end

  defp check_immutable_tree_entry(root, {relative_path, expected_blob}) do
    case git(root, ["ls-tree", "-z", "HEAD", "--", relative_path]) do
      {output, 0} -> immutable_tree_entry_diagnostics(output, relative_path, expected_blob)
      _ -> [diagnostic(:immutable_tree_entry_missing, relative_path, "could not inspect candidate HEAD immutable entry")]
    end
  end

  defp immutable_tree_entry_diagnostics(output, relative_path, expected_blob) do
    case parse_git_tree_entries(output) do
      {:ok, [%{mode: "100644", path: ^relative_path, sha: ^expected_blob}]} -> []
      {:ok, []} -> [diagnostic(:immutable_tree_entry_missing, relative_path, "immutable path is missing from candidate HEAD")]
      {:ok, _entries} -> [diagnostic(:immutable_tree_entry_mismatch, relative_path, "candidate HEAD immutable entry does not match the accepted blob and mode")]
      {:error, _reason} -> [diagnostic(:immutable_tree_entry_mismatch, relative_path, "candidate HEAD immutable entry is malformed")]
    end
  end

  defp check_candidate_worktree(root) do
    with {index_output, 0} <- git(root, ["ls-files", "--stage", "-z"]),
         {head_output, 0} <- git(root, ["ls-tree", "-r", "-z", "HEAD"]),
         {flags_output, 0} <- git(root, ["ls-files", "-v", "-z"]),
         {status_output, 0} <- git(root, ["status", "--porcelain", "--untracked-files=all"]),
         {:ok, index_entries} <- parse_git_index_entries(index_output),
         {:ok, head_entries} <- parse_git_tree_entries(head_output) do
      diagnostics =
        []
        |> Kernel.++(index_flag_diagnostics(flags_output))
        |> Kernel.++(compare_index_to_head(index_entries, head_entries))
        |> Kernel.++(compare_index_to_worktree(root, index_entries))
        |> append_unless(
          String.trim(status_output) == "",
          diagnostic(:dirty_worktree, nil, "freeze mode requires a clean candidate worktree")
        )

      if diagnostics == [], do: [], else: diagnostics
    else
      _ -> [diagnostic(:git_status_error, nil, "could not inspect candidate index or worktree")]
    end
  end

  defp index_flag_diagnostics(output) do
    flagged =
      output
      |> nul_records()
      |> Enum.filter(fn
        <<flag, " ", _path::binary>> -> flag in ?a..?z or flag == ?S
        _ -> true
      end)

    if flagged == [] do
      []
    else
      [diagnostic(:dirty_worktree, nil, "freeze mode cannot trust assume-unchanged or skip-worktree index entries")]
    end
  end

  defp compare_index_to_head(index_entries, head_entries) do
    cond do
      Enum.any?(index_entries, &(&1.stage != "0")) ->
        [diagnostic(:dirty_worktree, nil, "freeze mode requires a resolved candidate index")]

      git_entry_state(index_entries) == git_entry_state(head_entries) ->
        []

      true ->
        [diagnostic(:dirty_worktree, nil, "freeze mode requires an index matching candidate HEAD")]
    end
  end

  defp compare_index_to_worktree(root, index_entries) do
    index_entries
    |> Enum.filter(&(&1.stage == "0"))
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.path)
    |> Enum.flat_map(&compare_worktree_entry(root, &1))
  end

  defp compare_worktree_entry(root, %{path: relative_path, mode: expected_mode, sha: expected_sha}) do
    path = Path.join(root, relative_path)

    case safe_lstat(root, relative_path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        compare_regular_worktree_entry(path, relative_path, mode, expected_mode, expected_sha)

      {:ok, %File.Stat{type: :symlink}} ->
        compare_symlink_worktree_entry(path, relative_path, expected_mode, expected_sha)

      {:ok, %File.Stat{type: type}} ->
        [diagnostic(:dirty_worktree, relative_path, "tracked entry is not a regular file or symlink: #{type}")]

      {:error, {:symlink, symlink_path}} ->
        [diagnostic(:dirty_worktree, symlink_path, "tracked path contains a symlinked directory")]

      {:error, :enoent} ->
        [diagnostic(:dirty_worktree, relative_path, "tracked file is missing from the worktree")]

      {:error, _reason} ->
        [diagnostic(:dirty_worktree, relative_path, "tracked file cannot be inspected")]
    end
  end

  defp compare_regular_worktree_entry(path, relative_path, mode, expected_mode, expected_sha) do
    mode_diagnostics =
      if regular_git_mode(mode) == expected_mode do
        []
      else
        [diagnostic(:dirty_worktree, relative_path, "tracked file mode differs from candidate index")]
      end

    mode_diagnostics ++ worktree_content_diagnostics(path, relative_path, expected_sha)
  end

  defp worktree_content_diagnostics(path, relative_path, expected_sha) do
    case File.read(path) do
      {:ok, content} ->
        if git_blob_sha(content) == expected_sha do
          []
        else
          [diagnostic(:dirty_worktree, relative_path, "tracked file content differs from candidate index")]
        end

      {:error, _reason} ->
        [diagnostic(:dirty_worktree, relative_path, "tracked file cannot be read")]
    end
  end

  defp compare_symlink_worktree_entry(path, relative_path, expected_mode, expected_sha) do
    if expected_mode == "120000" do
      symlink_content_diagnostics(path, relative_path, expected_sha)
    else
      [diagnostic(:dirty_worktree, relative_path, "tracked file type differs from candidate index")]
    end
  end

  defp symlink_content_diagnostics(path, relative_path, expected_sha) do
    case File.read_link(path) do
      {:ok, target} ->
        if git_blob_sha(target) == expected_sha do
          []
        else
          [diagnostic(:dirty_worktree, relative_path, "tracked symlink differs from candidate index")]
        end

      {:error, _reason} ->
        [diagnostic(:dirty_worktree, relative_path, "tracked symlink cannot be read")]
    end
  end

  defp git_entry_state(entries) do
    Map.new(entries, fn entry -> {entry.path, {entry.mode, entry.sha}} end)
  end

  defp parse_git_index_entries(output) do
    parse_git_entries(output, fn record ->
      with [header, path] <- String.split(record, "\t", parts: 2),
           [mode, sha, stage] <- String.split(header, " ", parts: 3) do
        {:ok, %{mode: mode, path: path, sha: sha, stage: stage}}
      else
        _ -> :error
      end
    end)
  end

  defp parse_git_tree_entries(output) do
    parse_git_entries(output, fn record ->
      with [header, path] <- String.split(record, "\t", parts: 2),
           [mode, type, sha] <- String.split(header, " ", parts: 3) do
        {:ok, %{mode: mode, path: path, sha: sha, type: type}}
      else
        _ -> :error
      end
    end)
  end

  defp parse_git_entries(output, parser) do
    output
    |> nul_records()
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, entries} ->
      case parser.(record) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        :error -> {:halt, {:error, :malformed_git_entry}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp nul_records(output), do: :binary.split(output, <<0>>, [:global]) |> Enum.reject(&(&1 == ""))

  defp regular_git_mode(mode) do
    permissions = rem(mode, 0o1000)

    if Bitwise.band(permissions, 0o111) == 0 do
      "100644"
    else
      "100755"
    end
  end

  defp git(root, args) do
    System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  end

  defp git_blob_sha(content) do
    :crypto.hash(:sha, "blob #{byte_size(content)}\0" <> content)
    |> Base.encode16(case: :lower)
  end

  defp parse_json(content) when is_binary(content) do
    if String.valid?(content) do
      parse_json_utf8(content)
    else
      {:error, [diagnostic(:malformed_json, nil, "projection is not valid UTF-8")]}
    end
  end

  defp parse_json_utf8(content) do
    case json_value(skip_json_whitespace(content)) do
      {:ok, value, rest} ->
        if skip_json_whitespace(rest) == "" do
          {:ok, value}
        else
          {:error, [diagnostic(:malformed_json, nil, "trailing JSON content")]}
        end

      {:error, diagnostics} ->
        {:error, diagnostics}
    end
  end

  defp json_value(<<"{", rest::binary>>) do
    json_object(skip_json_whitespace(rest), [], %{})
  end

  defp json_value(<<"[", rest::binary>>) do
    json_array(skip_json_whitespace(rest), [])
  end

  defp json_value(<<"\"", rest::binary>>) do
    case json_string(rest, []) do
      {:ok, value, after_value} -> {:ok, {:string, value}, after_value}
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp json_value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp json_value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp json_value(<<"null", rest::binary>>), do: {:ok, :null, rest}

  defp json_value(<<char, _rest::binary>> = binary) when char == ?- or char in ?0..?9 do
    json_number(binary)
  end

  defp json_value(_binary) do
    {:error, [diagnostic(:malformed_json, nil, "invalid JSON value")]}
  end

  defp json_object(<<"}", rest::binary>>, pairs, _seen), do: {:ok, {:object, Enum.reverse(pairs)}, rest}

  defp json_object(binary, pairs, seen) do
    with {:ok, key, rest} <- json_string_key(binary),
         <<":", after_colon::binary>> <- skip_json_whitespace(rest),
         {:ok, value, after_value} <- json_value(skip_json_whitespace(after_colon)) do
      parse_json_object_member(key, value, after_value, pairs, seen)
    else
      {:error, diagnostics} -> {:error, diagnostics}
      _ -> {:error, [diagnostic(:malformed_json, nil, "invalid JSON object")]}
    end
  end

  defp parse_json_object_member(key, value, after_value, pairs, seen) do
    case Map.has_key?(seen, key) do
      true -> {:error, [diagnostic(:duplicate_key, key, "JSON object key appears more than once")]}
      false -> json_object_tail(skip_json_whitespace(after_value), key, value, pairs, seen)
    end
  end

  defp json_object_tail(<<",", next::binary>>, key, value, pairs, seen) do
    next = skip_json_whitespace(next)

    case next do
      <<"}">> -> {:error, [diagnostic(:malformed_json, nil, "trailing comma in JSON object")]}
      _ -> json_object(next, [{key, value} | pairs], Map.put(seen, key, true))
    end
  end

  defp json_object_tail(<<"}", next::binary>>, key, value, pairs, _seen) do
    {:ok, {:object, Enum.reverse([{key, value} | pairs])}, next}
  end

  defp json_object_tail(_binary, _key, _value, _pairs, _seen) do
    {:error, [diagnostic(:malformed_json, nil, "expected a comma or object terminator")]}
  end

  defp json_string_key(<<"\"", rest::binary>>) do
    case json_string(rest, []) do
      {:ok, {:string, key}, after_key} -> {:ok, key, after_key}
      {:ok, key, after_key} when is_binary(key) -> {:ok, key, after_key}
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp json_string_key(_binary) do
    {:error, [diagnostic(:malformed_json, nil, "object keys must be JSON strings")]}
  end

  defp json_array(<<"]", rest::binary>>, values), do: {:ok, {:array, Enum.reverse(values)}, rest}

  defp json_array(binary, values) do
    case json_value(binary) do
      {:ok, value, rest} -> json_array_tail(skip_json_whitespace(rest), value, values)
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp json_array_tail(<<",", next::binary>>, value, values) do
    next = skip_json_whitespace(next)

    case next do
      <<"]">> -> {:error, [diagnostic(:malformed_json, nil, "trailing comma in JSON array")]}
      _ -> json_array(next, [value | values])
    end
  end

  defp json_array_tail(<<"]", next::binary>>, value, values) do
    {:ok, {:array, Enum.reverse([value | values])}, next}
  end

  defp json_array_tail(_binary, _value, _values) do
    {:error, [diagnostic(:malformed_json, nil, "expected a comma or array terminator")]}
  end

  defp json_string(binary, parts) do
    case binary do
      <<"\"", rest::binary>> ->
        raw = IO.iodata_to_binary(["\"", Enum.reverse(parts), "\""])

        case Jason.decode(raw) do
          {:ok, value} -> {:ok, value, rest}
          {:error, _reason} -> {:error, [diagnostic(:malformed_json, nil, "invalid JSON string")]}
        end

      <<"\\", rest::binary>> ->
        json_escape(rest, parts)

      <<char, _rest::binary>> when char < 0x20 ->
        {:error, [diagnostic(:malformed_json, nil, "control character in JSON string")]}

      <<char, rest::binary>> ->
        json_string(rest, [<<char>> | parts])

      <<>> ->
        {:error, [diagnostic(:malformed_json, nil, "unterminated JSON string")]}
    end
  end

  defp json_escape(<<char, rest::binary>>, parts) when char in [?\", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] do
    json_string(rest, [<<"\\", char>> | parts])
  end

  defp json_escape(<<"u", h1, h2, h3, h4, rest::binary>>, parts) do
    digits = <<h1, h2, h3, h4>>

    if hex_digits?(digits) do
      json_string(rest, [<<"\\u", digits::binary>> | parts])
    else
      {:error, [diagnostic(:malformed_json, nil, "invalid Unicode escape in JSON string")]}
    end
  end

  defp json_escape(_binary, _parts) do
    {:error, [diagnostic(:malformed_json, nil, "invalid JSON string escape")]}
  end

  defp json_number(binary) do
    case Regex.run(~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/, binary) do
      [token] ->
        rest = binary_part(binary, byte_size(token), byte_size(binary) - byte_size(token))

        case Jason.decode(token) do
          {:ok, number} -> {:ok, {:number, number}, rest}
          {:error, _reason} -> {:error, [diagnostic(:malformed_json, nil, "invalid JSON number")]}
        end

      _ ->
        {:error, [diagnostic(:malformed_json, nil, "invalid JSON number")]}
    end
  end

  defp skip_json_whitespace(<<char, rest::binary>>) when char in [32, 9, 10, 13], do: skip_json_whitespace(rest)
  defp skip_json_whitespace(binary), do: binary

  defp hex_digits?(digits) do
    digits
    |> :binary.bin_to_list()
    |> Enum.all?(fn digit -> digit in ?0..?9 or digit in ?a..?f or digit in ?A..?F end)
  end

  defp count_occurrences(content, needle) do
    content
    |> :binary.matches(needle)
    |> length()
  end

  defp append_unless(diagnostics, true, _diagnostic), do: diagnostics
  defp append_unless(diagnostics, false, new_diagnostic), do: diagnostics ++ [new_diagnostic]

  defp valid_timestamp?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> true
      _ -> false
    end
  end

  defp valid_timestamp?(_value), do: false

  defp placeholder?(value), do: is_binary(value) and String.contains?(value, "{{")
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp join_path(path, key), do: path <> "." <> key

  defp sort_diagnostics(diagnostics) do
    Enum.sort_by(diagnostics, fn diagnostic ->
      {Atom.to_string(diagnostic.code), diagnostic.path || "", diagnostic.detail}
    end)
  end

  defp diagnostic(code, path, detail), do: %{code: code, path: path, detail: detail}
end
