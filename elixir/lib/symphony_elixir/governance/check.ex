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
  @status_begin "<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->"
  @status_end "<!-- END SYMPHONY_GOVERNANCE_STATUS_V1 -->"
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

  @type diagnostic :: %{
          code: atom(),
          path: String.t() | nil,
          detail: String.t()
        }

  @spec validate(Path.t()) :: :ok | {:error, [diagnostic()]}
  def validate(path), do: validate(path, [])

  @spec validate(Path.t(), keyword()) :: :ok | {:error, [diagnostic()]}
  def validate(root, opts) when is_binary(root) and is_list(opts) do
    projection_relative_path = Keyword.get(opts, :projection_path, @projection_path)
    projection_path = Path.join(root, projection_relative_path)

    with {:ok, projection} <- read_projection(projection_path),
         :ok <- validate_projection(projection),
         :ok <- validate_immutable_blobs(root),
         :ok <- validate_status_documents(root, projection, opts),
         :ok <- validate_skills(root),
         :ok <- validate_freeze(root, projection, opts) do
      :ok
    else
      {:error, diagnostics} -> {:error, sort_diagnostics(diagnostics)}
    end
  end

  def validate(_root, _opts) do
    {:error, sort_diagnostics([diagnostic(:invalid_path, nil, "repository path and options must be valid")])}
  end

  defp read_projection(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_projection_bytes ->
        {:error, [diagnostic(:projection_too_large, path, "projection exceeds 64 KiB")]}

      {:ok, _stat} ->
        read_projection_file(path)

      {:error, :enoent} ->
        {:error, [diagnostic(:projection_missing, path, "projection file does not exist")]}

      {:error, reason} ->
        {:error, [diagnostic(:projection_read_error, path, inspect(reason))]}
    end
  end

  defp read_projection_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_projection_content(path, content)
      {:error, reason} -> {:error, [diagnostic(:projection_read_error, path, inspect(reason))]}
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
    path = Path.join(root, relative_path)

    case File.read(path) do
      {:ok, content} -> immutable_blob_diagnostics(relative_path, content, expected_blob)
      {:error, :enoent} -> [diagnostic(:immutable_blob_missing, relative_path, "immutable file does not exist")]
      {:error, reason} -> [diagnostic(:immutable_blob_read_error, relative_path, inspect(reason))]
    end
  end

  defp immutable_blob_diagnostics(relative_path, content, expected_blob) do
    if git_blob_sha(content) == expected_blob do
      []
    else
      [diagnostic(:immutable_blob_mismatch, relative_path, "content does not match the accepted immutable blob")]
    end
  end

  defp validate_status_documents(root, projection, opts) do
    status_paths =
      Keyword.get(opts, :status_paths, [
        "docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md",
        "docs/symphony-hardening-playbook-v4.1/README.md",
        "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md"
      ])

    expected = status_values(projection, Keyword.get(opts, :projection_path, @projection_path))

    diagnostics =
      Enum.flat_map(status_paths, fn relative_path ->
        path = Path.join(root, relative_path)

        case File.read(path) do
          {:ok, content} -> parse_status_block(content, relative_path, expected)
          {:error, :enoent} -> [diagnostic(:status_document_missing, relative_path, "status document does not exist")]
          {:error, reason} -> [diagnostic(:status_document_read_error, relative_path, inspect(reason))]
        end
      end)

    if diagnostics == [], do: :ok, else: {:error, diagnostics}
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
    skill_root = Path.join(root, ".codex/skills")
    skill_paths = Path.wildcard(Path.join(skill_root, "*/SKILL.md")) |> Enum.sort()

    skill_diagnostics =
      Enum.flat_map(skill_paths, fn path ->
        relative_path = Path.relative_to(path, root)

        case File.read(path) do
          {:ok, content} ->
            marker_diagnostics = skill_marker_diagnostics(content, relative_path)
            policy_diagnostics = skill_policy_diagnostics(content, relative_path)
            marker_diagnostics ++ policy_diagnostics

          {:error, reason} ->
            [diagnostic(:skill_read_error, relative_path, inspect(reason))]
        end
      end)

    watcher_path = Path.join(skill_root, "land/land_watch.py")

    watcher_diagnostics =
      case File.read(watcher_path) do
        {:ok, content} ->
          marker_diagnostics =
            if String.contains?(content, "# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY") do
              []
            else
              [diagnostic(:land_watch_marker_missing, Path.relative_to(watcher_path, root), "advisory marker is required")]
            end

          policy_diagnostics = skill_policy_diagnostics(content, Path.relative_to(watcher_path, root))
          marker_diagnostics ++ policy_diagnostics

        {:error, :enoent} ->
          [diagnostic(:land_watch_marker_missing, Path.relative_to(watcher_path, root), "land watcher does not exist")]

        {:error, reason} ->
          [diagnostic(:skill_read_error, Path.relative_to(watcher_path, root), inspect(reason))]
      end

    diagnostics = skill_diagnostics ++ watcher_diagnostics
    if diagnostics == [], do: :ok, else: {:error, diagnostics}
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
      if Regex.match?(~r/^\s*(?:\$\s*)?gh\s+pr\s+merge\b/im, content) do
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
      if Regex.match?(~r/\bChecks passed\b/, content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "watcher output must identify observations as advisory")]
      else
        diagnostics
      end

    diagnostics =
      if Regex.match?(~r/^\s*(?:\$\s*)?git\s+push\b[^\n]*(?:\s|\/)(?:main|master)\b/im, content) do
        diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "skills cannot push directly to protected main")]
      else
        diagnostics
      end

    raw_lifecycle_recipe? = raw_lifecycle_recipe?(content)

    if Path.basename(Path.dirname(relative_path)) == "linear" and raw_lifecycle_recipe? do
      diagnostics ++ [diagnostic(:skill_policy_violation, relative_path, "Linear compatibility must not contain a raw lifecycle mutation recipe")]
    else
      diagnostics
    end
  end

  defp active_green_authority_claim?(content) do
    positive_claim? =
      Regex.match?(
        ~r/green\s+(?:ci|checks?).{0,100}(?:grant|authoriz|permit|prove|mean).{0,60}(?:merge|accept)|(?:merge|accept).{0,100}green\s+(?:ci|checks?).{0,60}(?:grant|authoriz|permit|prove|mean)/is,
        content
      )

    prohibition? =
      Regex.match?(
        ~r/green\s+(?:ci|checks?).{0,100}(?:do\s+not|does\s+not|cannot|must\s+not|is\s+not|are\s+not).{0,100}(?:grant|authoriz|permit|prove|mean)/is,
        content
      )

    positive_claim? and not prohibition?
  end

  defp active_no_required_checks_claim?(content) do
    Regex.match?(
      ~r/(?:this|the)\s+repo(?:sitory)?\s+(?:has|have|contains?)\s+no\s+required\s+checks|(?:there|we)\s+are\s+no\s+required\s+checks|no\s+required\s+checks\s+(?:exist|apply|are\s+required)/i,
      content
    )
  end

  defp raw_lifecycle_recipe?(content) do
    fenced_blocks = Regex.scan(~r/```(?:graphql)?\s*\n(.*?)```/is, content, capture: :all_but_first) |> List.flatten()

    Enum.any?(fenced_blocks, &raw_lifecycle_mutation_block?/1) or
      Regex.match?(~r/^\s*mutation\b[^\n]*\bissueUpdate\b[^\n]*\bstateId\b/im, content) or
      Regex.match?(~r/issueUpdate\s*[({][^\n]{0,160}\bstateId\s*:/is, content)
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

  defp check_candidate_worktree(root) do
    case git(root, ["status", "--porcelain", "--untracked-files=all"]) do
      {output, 0} ->
        if String.trim(output) == "" do
          []
        else
          [diagnostic(:dirty_worktree, nil, "freeze mode requires a clean candidate worktree")]
        end

      _ ->
        [diagnostic(:git_status_error, nil, "could not inspect candidate worktree")]
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
    json_object(skip_json_whitespace(rest), [], MapSet.new())
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
    case MapSet.member?(seen, key) do
      true -> {:error, [diagnostic(:duplicate_key, key, "JSON object key appears more than once")]}
      false -> json_object_tail(skip_json_whitespace(after_value), key, value, pairs, seen)
    end
  end

  defp json_object_tail(<<",", next::binary>>, key, value, pairs, seen) do
    next = skip_json_whitespace(next)

    case next do
      <<"}">> -> {:error, [diagnostic(:malformed_json, nil, "trailing comma in JSON object")]}
      _ -> json_object(next, [{key, value} | pairs], MapSet.put(seen, key))
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
      _ -> {:error, [diagnostic(:malformed_json, nil, "invalid JSON array")]}
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
