defmodule SymphonyElixir.GovernanceCheckTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Governance.Check

  @repo_root Path.expand("../../..", __DIR__)
  @roadmap_path "docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md"
  @pre_080c_02_path "docs/symphony-hardening-playbook-v4.1/PRE-080C-02_PRODUCTION_RATE_EPOCH_CHARACTERIZATION.md"
  @projection_path "docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json"
  @roadmap_blob "4b0528bdc0647d889b42ebc478081d5b873898fe"
  @accepted_sha "0640bf1135f8b5000ea29518c2c456272379e9c6"
  @accepted_tree "5c6f10cc88c41f395837a930fb7ea20e0bdae0cc"
  @decision_reference "MG-2026-10-10-PRE-080C-03-AUTH-01"
  @decision_timestamp "2026-10-10T16:35:00+02:00"

  @conditions [
    "PRE080C02_LIMIT_FOUND_REQUIRES_PRE_H080C_ADJUDICATION",
    "PRE080C03_NOT_ACCEPTED",
    "PRE_H080C_NOT_REACHED",
    "H080C_NOT_AUTHORIZED"
  ]

  setup do
    root = temp_root()
    build_fixture!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  describe "projection parsing" do
    test "accepts a valid schema-v1 projection", %{root: root} do
      assert :ok = Check.validate(root)
    end

    test "rejects malformed JSON", %{root: root} do
      write_projection(root, "{")

      assert_has_code(Check.validate(root), :malformed_json)
    end

    test "rejects a symlinked projection", %{root: root} do
      path = Path.join(root, @projection_path)
      target = path <> ".target"
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert_has_code(Check.validate(root), :projection_symlink)
    end

    test "always reads the canonical projection despite an override", %{root: root} do
      external_path = Path.join(Path.dirname(root), "governance-external-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(external_path) end)
      File.write!(external_path, projection_json())
      write_projection(root, "{")

      assert_has_code(
        Check.validate(root, projection_path: "../#{Path.basename(external_path)}"),
        :malformed_json
      )
    end

    test "rejects duplicate keys at the top level", %{root: root} do
      projection = projection_json() |> String.replace("\"schema_version\": 1", "\"schema_version\": 1, \"schema_version\": 1", global: false)

      write_projection(root, projection)

      assert_has_code(Check.validate(root), :duplicate_key)
    end

    test "rejects duplicate keys nested in an object", %{root: root} do
      projection =
        projection_json()
        |> String.replace(~s("version": "V4.1"), ~s("version": "V4.1", "version": "V4.1"), global: false)

      write_projection(root, projection)

      assert_has_code(Check.validate(root), :duplicate_key)
    end

    test "rejects a missing required field", %{root: root} do
      projection = projection_map() |> update_in(["decision"], &Map.delete(&1, "timestamp"))

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :missing_field)
    end

    test "rejects an unknown top-level field", %{root: root} do
      projection = Map.put(projection_map(), "unexpected", true)

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :unknown_field)
    end

    test "rejects an unknown nested field", %{root: root} do
      projection = update_in(projection_map(), ["decision"], &Map.put(&1, "unexpected", true))

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :unknown_field)
    end

    test "rejects an unsupported schema version", %{root: root} do
      projection = Map.put(projection_map(), "schema_version", 2)

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :unsupported_schema_version)
    end

    test "rejects a projection larger than 64 KiB", %{root: root} do
      projection = Map.put(projection_map(), "known_unresolved_governance_conditions", List.duplicate(String.duplicate("x", 17_000), 4))

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :projection_too_large)
    end
  end

  describe "identity and decision validation" do
    test "rejects malformed baseline SHA", %{root: root} do
      projection = put_in(projection_map(), ["authority_snapshot", "accepted_protected_main_at_decision", "sha"], "BAD")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_sha)
    end

    test "rejects malformed baseline tree", %{root: root} do
      projection = put_in(projection_map(), ["authority_snapshot", "accepted_protected_main_at_decision", "tree"], "BAD")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_tree)
    end

    test "rejects a roadmap identity mismatch", %{root: root} do
      projection = put_in(projection_map(), ["governing_roadmap", "id"], "wrong.md")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :roadmap_id_mismatch)
    end

    test "rejects a roadmap version mismatch", %{root: root} do
      projection = put_in(projection_map(), ["governing_roadmap", "version"], "V3")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :roadmap_version_mismatch)
    end

    test "rejects a roadmap blob mismatch", %{root: root} do
      projection = put_in(projection_map(), ["governing_roadmap", "blob_sha"], String.duplicate("0", 40))

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :roadmap_blob_mismatch)
    end

    test "rejects blank decision reference", %{root: root} do
      projection = put_in(projection_map(), ["decision", "reference"], " ")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_decision_reference)
    end

    test "rejects a decision reference placeholder", %{root: root} do
      projection = put_in(projection_map(), ["decision", "reference"], "{{MASTER_DECISION_REFERENCE}}")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_decision_reference)
    end

    test "rejects a decision timestamp without timezone", %{root: root} do
      projection = put_in(projection_map(), ["decision", "timestamp"], "2026-10-10T16:35:00")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_decision_timestamp)
    end

    test "rejects authority values outside the approved PRE-080C-03 snapshot", %{root: root} do
      mutations = [
        {[
           "authority_snapshot",
           "accepted_protected_main_at_decision",
           "sha"
         ], String.duplicate("1", 40)},
        {[
           "authority_snapshot",
           "accepted_protected_main_at_decision",
           "tree"
         ], String.duplicate("2", 40)},
        {["authority_snapshot", "current_accepted_phase"], "PRE-080C-03"},
        {["authority_snapshot", "current_accepted_prerequisite"], "WRONG"},
        {["authority_snapshot", "pre_080c_02_outcome"], "NO_LIMIT"},
        {["authority_snapshot", "currently_authorized_work", "id"], "OTHER"},
        {["authority_snapshot", "currently_authorized_work", "status"], "AUTHORIZED"},
        {["authority_snapshot", "currently_authorized_work", "scope"], "OTHER_SCOPE"},
        {["authority_snapshot", "pre_h080c"], "REACHED"},
        {["authority_snapshot", "h_080c"], "AUTHORIZED"},
        {["authority_snapshot", "next_governance_step"], "H-080C"},
        {["authority_snapshot", "next_authorized_phase"], "PRE-080C-04"}
      ]

      Enum.each(mutations, fn {path, value} ->
        projection = put_in(projection_map(), path, value)
        write_projection(root, Jason.encode!(projection))
        assert_has_code(Check.validate(root), :authority_snapshot_mismatch)
      end)
    end

    test "rejects decision metadata outside the approved governance decision", %{root: root} do
      mutations = [
        {["decision", "authority"], "Another Authority"},
        {["decision", "reference"], "MG-OTHER"},
        {["decision", "timestamp"], "2026-10-11T16:35:00+02:00"},
        {["known_unresolved_governance_conditions"], @conditions ++ ["FAKE_CONDITION"]}
      ]

      Enum.each(mutations, fn {path, value} ->
        projection = put_in(projection_map(), path, value)
        write_projection(root, Jason.encode!(projection))
        assert_has_code(Check.validate(root), :authority_snapshot_mismatch)
      end)
    end
  end

  describe "logical governance consistency" do
    test "accepts an unreached PRE-H080C gate with no authorized next phase", %{root: root} do
      assert :ok = Check.validate(root)
    end

    test "rejects an authorized H-080C before the gate", %{root: root} do
      projection = put_in(projection_map(), ["authority_snapshot", "h_080c"], "AUTHORIZED")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_gate_state)
    end

    test "rejects a next authorized phase before the gate", %{root: root} do
      projection = put_in(projection_map(), ["authority_snapshot", "next_authorized_phase"], "H-080C")

      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root), :invalid_gate_state)
    end
  end

  describe "status surfaces" do
    test "requires one complete status block in each status document", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      File.write!(path, String.replace(File.read!(path), "<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->", ""))

      assert_has_code(Check.validate(root), :status_block_missing)
    end

    test "rejects duplicate status blocks", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      body = File.read!(path)
      File.write!(path, body <> "\n" <> body)

      assert_has_code(Check.validate(root), :status_block_duplicate)
    end

    test "rejects duplicate status block keys", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      duplicate = "GOVERNANCE_PROJECTION_PATH=docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json\n"
      File.write!(path, String.replace(File.read!(path), "GOVERNING_ROADMAP_ID=", duplicate <> "GOVERNING_ROADMAP_ID=", global: false))

      assert_has_code(Check.validate(root), :status_block_duplicate_key)
    end

    test "rejects unknown status block keys", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      File.write!(path, String.replace(File.read!(path), "GOVERNING_ROADMAP_ID=", "UNKNOWN=bad\nGOVERNING_ROADMAP_ID=", global: false))

      assert_has_code(Check.validate(root), :status_block_unknown_key)
    end

    test "rejects a baseline mismatch in one status document", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md")
      File.write!(path, String.replace(File.read!(path), @accepted_sha, String.duplicate("0", 40), global: false))

      assert_has_code(Check.validate(root), :status_mismatch)
    end

    test "rejects an unresolved-condition mismatch", %{root: root} do
      path = Path.join(root, "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md")
      File.write!(path, String.replace(File.read!(path), "KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=", "KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=WRONG,", global: false))

      assert_has_code(Check.validate(root), :status_mismatch)
    end

    test "rejects a Unified Roadmap phase mismatch", %{root: root} do
      path = Path.join(root, "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md")
      File.write!(path, String.replace(File.read!(path), "CURRENT_ACCEPTED_PHASE=H-080B", "CURRENT_ACCEPTED_PHASE=WRONG", global: false))

      assert_has_code(Check.validate(root), :status_mismatch)
    end

    test "rejects a playbook decision mismatch", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      File.write!(path, String.replace(File.read!(path), "DECISION_REFERENCE=#{@decision_reference}", "DECISION_REFERENCE=WRONG", global: false))

      assert_has_code(Check.validate(root), :status_mismatch)
    end

    test "always checks the canonical status documents", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      File.write!(path, String.replace(File.read!(path), "<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->", "", global: false))

      assert_has_code(Check.validate(root, status_paths: ["replacement.md"]), :status_block_missing)
    end

    test "rejects a symlinked status document", %{root: root} do
      path = Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md")
      target = path <> ".target"
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert_has_code(Check.validate(root), :status_document_symlink)
    end
  end

  describe "immutable artifacts" do
    test "accepts the exact immutable roadmap and PRE-080C-02 blobs", %{root: root} do
      assert :ok = Check.validate(root)
    end

    test "rejects a modified Master Roadmap", %{root: root} do
      path = Path.join(root, @roadmap_path)
      File.write!(path, File.read!(path) <> "\nchanged\n")

      assert_has_code(Check.validate(root), :immutable_blob_mismatch)
    end

    test "rejects modified PRE-080C-02 evidence", %{root: root} do
      path = Path.join(root, @pre_080c_02_path)
      File.write!(path, File.read!(path) <> "\nchanged\n")

      assert_has_code(Check.validate(root), :immutable_blob_mismatch)
    end

    test "rejects a symlinked immutable artifact", %{root: root} do
      path = Path.join(root, @roadmap_path)
      target = path <> ".target"
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert_has_code(Check.validate(root), :immutable_blob_symlink)
    end
  end

  describe "freeze mode" do
    test "requires a candidate phase", %{root: root} do
      init_git!(root)

      assert_has_code(Check.validate(root, freeze: true), :candidate_phase_required)
    end

    test "accepts the exact candidate phase and clean descended baseline", %{root: root} do
      init_git!(root)

      assert :ok = Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true)
    end

    test "rejects the wrong candidate phase", %{root: root} do
      init_git!(root)

      assert_has_code(Check.validate(root, candidate_phase: "H-080C", freeze: true), :candidate_phase_mismatch)
    end

    test "rejects a missing accepted commit", %{root: root} do
      init_git!(root)
      projection = put_in(projection_map(), ["authority_snapshot", "accepted_protected_main_at_decision", "sha"], String.duplicate("1", 40))
      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :baseline_commit_missing)
    end

    test "rejects a baseline tree mismatch", %{root: root} do
      init_git!(root)
      projection = Jason.decode!(File.read!(Path.join(root, @projection_path)))
      projection = put_in(projection, ["authority_snapshot", "accepted_protected_main_at_decision", "tree"], String.duplicate("0", 40))
      write_projection(root, Jason.encode!(projection))

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :baseline_tree_mismatch)
    end

    test "rejects a candidate unrelated to the accepted baseline", %{root: root} do
      init_git!(root)
      git!(root, ["checkout", "--orphan", "unrelated"])
      git!(root, ["rm", "-rf", "--cached", "."])
      git!(root, ["add", "."])
      git!(root, ["commit", "-qm", "unrelated"])

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :candidate_not_descended)
    end

    test "rejects a dirty freeze worktree", %{root: root} do
      init_git!(root)
      File.write!(Path.join(root, "dirty.txt"), "dirty")

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :dirty_worktree)
    end

    test "rejects tracked edits hidden by assume-unchanged", %{root: root} do
      init_git!(root)
      path = Path.join(root, @roadmap_path)
      File.write!(path, File.read!(path) <> "\nhidden edit\n")
      git!(root, ["update-index", "--assume-unchanged", @roadmap_path])

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :dirty_worktree)
    end

    test "rejects tracked mode changes when core.fileMode is false", %{root: root} do
      init_git!(root)
      path = Path.join(root, @roadmap_path)
      git!(root, ["config", "core.fileMode", "false"])
      File.chmod!(path, 0o755)

      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03", freeze: true), :dirty_worktree)
    end

    test "rejects a candidate phase supplied without freeze mode", %{root: root} do
      assert_has_code(Check.validate(root, candidate_phase: "PRE-080C-03"), :candidate_phase_requires_freeze)
    end
  end

  describe "skill policy" do
    test "accepts required markers and narrow policies", %{root: root} do
      assert :ok = Check.validate(root)
    end

    test "rejects a missing skill marker", %{root: root} do
      path = Path.join(root, ".codex/skills/commit/SKILL.md")
      File.write!(path, String.replace(File.read!(path), "<!-- SYMPHONY_AUTHORITY_CLASS: PROCEDURAL_NON_AUTHORITY -->\n", "", global: false))

      assert_has_code(Check.validate(root), :skill_marker_missing)
    end

    test "rejects the old direct land merge command", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\ngh pr merge --squash\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects inline autonomous land merge instructions", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nUse gh pr merge --squash after review.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a land merge command with global GitHub flags", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nUse gh --repo org/repo pr merge 123.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a disclaimer followed by an autonomous merge command", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nDo not use gh pr merge in this document. Review can later run gh pr merge --squash.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects direct pull request merge prose", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nMerge the pull request now.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a command after a same-line disclaimer through continuation", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      continuation = "\nDo not use gh pr merge in this document; review can later run gh pr " <> "\\" <> "\nmerge --squash.\n"
      File.write!(path, File.read!(path) <> continuation)

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a green-check authority claim", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nGreen checks grant merge authority.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects reverse-order green-CI authority claims", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI is green and permits acceptance.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects acceptance authorized by green CI in reverse order", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nAcceptance is permitted because CI is green.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects CI-passed acceptance claims", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI passed, so acceptance is permitted.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects an acceptance clause after a CI disclaimer", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI passed does not permit acceptance; acceptance is permitted because CI passed.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a semicolon-separated CI acceptance claim", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI passed; therefore acceptance is permitted.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects CI acceptance claims split by a period and therefore", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI passed. Therefore acceptance is permitted.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a later CI acceptance claim after an earlier connector disclaimer", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\nCI passed, so it does not permit acceptance. CI passed, and acceptance is permitted.\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a later CI acceptance claim after an earlier disclaimer", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nCI passed does not permit acceptance; CI passed; acceptance is permitted.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "checks every CI connector claim after an earlier prohibited connector", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\nCI passed, so it does not permit acceptance; CI passed, so acceptance is permitted.\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a no-required-checks claim", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nThis repository has no required checks.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects direct protected-main push instructions", %{root: root} do
      path = Path.join(root, ".codex/skills/push/SKILL.md")
      File.write!(path, File.read!(path) <> "\ngit push origin main\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a protected-main push with Git config flags", %{root: root} do
      path = Path.join(root, ".codex/skills/push/SKILL.md")
      File.write!(path, File.read!(path) <> "\ngit -c core.sshCommand=x push origin main\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects inline protected-main push instructions", %{root: root} do
      path = Path.join(root, ".codex/skills/push/SKILL.md")
      File.write!(path, File.read!(path) <> "\nThen run git push origin main.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a protected-main push through HEAD", %{root: root} do
      path = Path.join(root, ".codex/skills/push/SKILL.md")
      File.write!(path, File.read!(path) <> "\nThen run git push origin HEAD:main.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects direct protected-main push prose", %{root: root} do
      path = Path.join(root, ".codex/skills/push/SKILL.md")
      File.write!(path, File.read!(path) <> "\nPush this branch to main now.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects the legacy Linear raw lifecycle mutation recipe", %{root: root} do
      path = Path.join(root, ".codex/skills/linear/SKILL.md")
      File.write!(path, File.read!(path) <> "\nissueUpdate(stateId: \"done\")\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects an unfenced multiline Linear lifecycle mutation recipe", %{root: root} do
      path = Path.join(root, ".codex/skills/linear/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\nmutation UpdateIssue($id: String!) {\n  issueUpdate(\n    id: $id,\n    input: { stateId: \"done\" }\n  ) { success }\n}\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a Linear recipe with long whitespace between lifecycle fields", %{root: root} do
      path = Path.join(root, ".codex/skills/linear/SKILL.md")
      padding = String.duplicate(" ", 500)

      File.write!(
        path,
        File.read!(path) <> "\nmutation UpdateIssue { issueUpdate(input: {#{padding}stateId: \"done\"}) { success } }\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a Linear lifecycle mutation in a text fence", %{root: root} do
      path = Path.join(root, ".codex/skills/linear/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\n```text\nmutation UpdateIssue($id: String!) { issueUpdate(id: $id, input: { stateId: \"done\" }) { success } }\n```\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a Linear lifecycle mutation in any scanned skill file", %{root: root} do
      path = Path.join(root, ".codex/skills/commit/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\n```text\nmutation UpdateIssue { issueUpdate(input: { stateId: \\\"done\\\" }) { success } }\n```\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a Linear lifecycle mutation in a tilde fence", %{root: root} do
      path = Path.join(root, ".codex/skills/commit/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\n~~~text\nmutation UpdateIssue { issueUpdate(input: { stateId: \\\"done\\\" }) { success } }\n~~~\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "requires an advisory land watcher marker", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, String.replace(File.read!(path), "# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY\n", "", global: false))

      assert_has_code(Check.validate(root), :land_watch_marker_missing)
    end

    test "requires the land watcher marker to be a Python comment line", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, "MARKER = \"# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY\"\n")

      assert_has_code(Check.validate(root), :land_watch_marker_missing)
    end

    test "rejects an advisory marker inside a Python docstring", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, "\"\"\"\n# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY\n\"\"\"\n")

      assert_has_code(Check.validate(root), :land_watch_marker_missing)
    end

    test "rejects an advisory marker inside a docstring with escaped quotes", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        ~S|"""escaped \"""
# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY
"""
|
      )

      assert_has_code(Check.validate(root), :land_watch_marker_missing)
    end

    test "rejects the old unqualified watcher output", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"Checks passed\")\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects lowercase unqualified watcher output", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"checks passed\")\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects Checks passed watcher output even when qualified", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"Checks passed (advisory observation only)\")\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects concatenated Checks passed watcher output", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"Checks \" + \"passed\")\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects assigned constant Checks passed watcher output", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        File.read!(path) <> "\nprefix = \"Checks \"\nsuffix = \"passed\"\nprint(prefix + suffix)\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects semicolon-separated assigned Checks passed output", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        File.read!(path) <> "\nprefix = \"Checks \"; suffix = \"passed\"; print(prefix + suffix)\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects assigned Checks passed output with print options", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        File.read!(path) <> "\nprefix = \"Checks \"; suffix = \"passed\"; print(prefix + suffix, flush=True)\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects Checks passed output from format literals", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"{} {}\".format(\"Checks\", \"passed\"))\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects Checks passed output from f-string assignments", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        File.read!(path) <> "\nprefix = \"Checks\"; suffix = \"passed\"; print(f\"{prefix} {suffix}\")\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects Checks passed output from a literal conditional assignment", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")

      File.write!(
        path,
        File.read!(path) <> "\nprefix = \"Checks \"; suffix = \"passed\" if ready else \"failed\"; print(prefix + suffix)\n"
      )

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects Checks passed output from a literal conditional expression", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.write!(path, File.read!(path) <> "\nprint(\"Checks \" + (\"passed\" if ready else \"failed\"))\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a non-regular land watcher entry", %{root: root} do
      path = Path.join(root, ".codex/skills/land/land_watch.py")
      File.rm!(path)
      File.mkdir!(path)

      assert_has_code(Check.validate(root), :skill_entry_invalid)
    end

    test "accepts explicit green-check authority prohibition", %{root: root} do
      path = Path.join(root, ".codex/skills/land/SKILL.md")
      File.write!(path, File.read!(path) <> "\nGreen checks do not grant merge or acceptance authority.\n")

      assert :ok = Check.validate(root)
    end

    test "scans the normative skills README", %{root: root} do
      path = Path.join(root, ".codex/skills/README.md")
      File.write!(path, File.read!(path) <> "\nRun gh pr merge --squash after review.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "scans every regular text file under the skills tree", %{root: root} do
      path = Path.join(root, ".codex/skills/land/notes.txt")
      File.write!(path, "Merge the pull request now.\n")

      assert_has_code(Check.validate(root), :skill_policy_violation)
    end

    test "rejects a non-text regular skill file", %{root: root} do
      path = Path.join(root, ".codex/skills/land/binary.bin")
      File.write!(path, <<0, 255, 1>>)

      assert_has_code(Check.validate(root), :skill_non_text)
    end

    test "rejects a non-regular skills tree entry", %{root: root} do
      path = Path.join(root, ".codex/skills/land/pipe")
      {_, 0} = System.cmd("mkfifo", [path])
      on_exit(fn -> File.rm(path) end)

      assert_has_code(Check.validate(root), :skill_entry_invalid)
    end

    test "rejects a symlinked skill instruction file", %{root: root} do
      path = Path.join(root, ".codex/skills/commit/SKILL.md")
      target = path <> ".target"
      File.rename!(path, target)
      File.ln_s!(target, path)

      assert_has_code(Check.validate(root), :skill_symlink)
    end

    test "accepts the Linear lifecycle mutation prohibition", %{root: root} do
      path = Path.join(root, ".codex/skills/linear/SKILL.md")

      File.write!(
        path,
        File.read!(path) <> "\nDo not use `linear_graphql` `issueUpdate` or `stateId` mutations to perform Symphony lifecycle transitions.\n"
      )

      assert :ok = Check.validate(root)
    end

    test "requires every current skill file", %{root: root} do
      File.rm!(Path.join(root, ".codex/skills/linear/SKILL.md"))

      assert_has_code(Check.validate(root), :required_skill_missing)
    end

    test "scans nested skill files", %{root: root} do
      path = Path.join(root, ".codex/skills/nested/custom/SKILL.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "nested skill without an authority marker\n")

      assert_has_code(Check.validate(root), :skill_marker_missing)
    end
  end

  describe "Mix task" do
    test "maps validation failure to a Mix error", %{root: root} do
      write_projection(root, "{")

      assert_raise Mix.Error, ~r/governance\.check failed/, fn ->
        File.cd!(root, fn -> Mix.Tasks.Governance.Check.run([]) end)
      end
    end

    test "returns :ok on a valid fixture", %{root: root} do
      assert :ok = File.cd!(root, fn -> Mix.Tasks.Governance.Check.run([]) end)
    end

    test "rejects unknown command-line options", %{root: root} do
      assert_raise Mix.Error, ~r/invalid command-line options/, fn ->
        File.cd!(root, fn -> Mix.Tasks.Governance.Check.run(["--unknown"]) end)
      end
    end

    test "requires freeze mode with a candidate phase", %{root: root} do
      assert_raise Mix.Error, ~r/candidate-phase requires --freeze/, fn ->
        File.cd!(root, fn -> Mix.Tasks.Governance.Check.run(["--candidate-phase", "PRE-080C-03"]) end)
      end
    end
  end

  test "sorts diagnostics deterministically", %{root: root} do
    projection =
      projection_map()
      |> Map.delete("decision")
      |> Map.put("unexpected", true)

    write_projection(root, Jason.encode!(projection))

    assert {:error, diagnostics} = Check.validate(root)
    assert length(diagnostics) >= 2

    assert diagnostics ==
             Enum.sort_by(diagnostics, fn diagnostic ->
               {Atom.to_string(diagnostic.code), diagnostic.path || "", diagnostic.detail}
             end)
  end

  defp projection_map do
    %{
      "schema_version" => 1,
      "projection_role" => "MACHINE_PROJECTION_OF_ACCEPTED_AUTHORITY",
      "governing_roadmap" => %{
        "id" => @roadmap_path,
        "version" => "V4.1",
        "blob_sha" => @roadmap_blob
      },
      "authority_snapshot" => %{
        "accepted_protected_main_at_decision" => %{
          "sha" => @accepted_sha,
          "tree" => @accepted_tree
        },
        "current_accepted_phase" => "H-080B",
        "current_accepted_prerequisite" => "PRE-080C-02",
        "pre_080c_02_outcome" => "LIMIT_FOUND",
        "currently_authorized_work" => %{
          "id" => "PRE-080C-03",
          "status" => "AUTHORIZED_ACTIVE_NOT_ACCEPTED",
          "scope" => "GOVERNANCE_DOCUMENTATION_RECONCILIATION_ONLY"
        },
        "pre_h080c" => "NOT_REACHED",
        "h_080c" => "NOT_AUTHORIZED",
        "next_governance_step" => "PRE-H080C",
        "next_authorized_phase" => nil
      },
      "decision" => %{
        "authority" => "Master Governance",
        "reference" => @decision_reference,
        "timestamp" => @decision_timestamp
      },
      "known_unresolved_governance_conditions" => @conditions
    }
  end

  defp projection_json do
    projection_map() |> Jason.encode!(pretty: true)
  end

  defp status_block(accepted_sha \\ @accepted_sha, accepted_tree \\ @accepted_tree) do
    conditions = Enum.join(@conditions, ",")

    """
    <!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->
    GOVERNANCE_PROJECTION_PATH=#{@projection_path}
    GOVERNING_ROADMAP_ID=#{@roadmap_path}
    GOVERNING_ROADMAP_VERSION=V4.1
    GOVERNING_ROADMAP_BLOB_SHA=#{@roadmap_blob}
    ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA=#{accepted_sha}
    ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE=#{accepted_tree}
    CURRENT_ACCEPTED_PHASE=H-080B
    CURRENT_ACCEPTED_PREREQUISITE=PRE-080C-02
    PRE_080C_02_OUTCOME=LIMIT_FOUND
    CURRENTLY_AUTHORIZED_WORK=PRE-080C-03
    CURRENTLY_AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
    PRE_H080C=NOT_REACHED
    H_080C=NOT_AUTHORIZED
    NEXT_GOVERNANCE_STEP=PRE-H080C
    NEXT_AUTHORIZED_PHASE=NONE
    DECISION_AUTHORITY=Master Governance
    DECISION_REFERENCE=#{@decision_reference}
    DECISION_TIMESTAMP=#{@decision_timestamp}
    KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=#{conditions}
    <!-- END SYMPHONY_GOVERNANCE_STATUS_V1 -->
    """
  end

  defp build_fixture!(root) do
    File.mkdir_p!(Path.join(root, "docs/symphony-hardening-playbook-v4.1"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, ".codex/skills/commit"))
    File.mkdir_p!(Path.join(root, ".codex/skills/debug"))
    File.mkdir_p!(Path.join(root, ".codex/skills/land"))
    File.mkdir_p!(Path.join(root, ".codex/skills/linear"))
    File.mkdir_p!(Path.join(root, ".codex/skills/pull"))
    File.mkdir_p!(Path.join(root, ".codex/skills/push"))
    File.mkdir_p!(Path.join(root, ".codex/skills/release"))

    copy_fixture_file!(root, @roadmap_path)
    copy_fixture_file!(root, @pre_080c_02_path)

    projection = projection_json()
    File.write!(Path.join(root, @projection_path), projection)

    File.write!(Path.join(root, "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md"), status_block())
    File.write!(Path.join(root, "docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md"), status_block())
    File.write!(Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md"), status_block())

    for skill <- ~w(commit debug land linear pull push release) do
      marker = if skill == "linear", do: "LEGACY_COMPATIBILITY_PROCEDURE", else: "PROCEDURAL_NON_AUTHORITY"

      File.write!(
        Path.join(root, ".codex/skills/#{skill}/SKILL.md"),
        "<!-- SYMPHONY_AUTHORITY_CLASS: #{marker} -->\n"
      )
    end

    File.write!(
      Path.join(root, ".codex/skills/README.md"),
      "# Repository-local skill authority\n\n<!-- SYMPHONY_AUTHORITY_CLASS: PROCEDURAL_NON_AUTHORITY -->\n"
    )

    File.write!(
      Path.join(root, ".codex/skills/land/land_watch.py"),
      "#!/usr/bin/env python3\n# SYMPHONY_AUTHORITY_CLASS: ADVISORY_NON_AUTHORITY\n"
    )
  end

  defp copy_fixture_file!(root, relative_path) do
    source = Path.join(@repo_root, relative_path)
    destination = Path.join(root, relative_path)
    File.write!(destination, File.read!(source))
  end

  defp write_projection(root, json) do
    File.write!(Path.join(root, @projection_path), json)

    case Jason.decode(json) do
      {:ok, %{"authority_snapshot" => %{"accepted_protected_main_at_decision" => %{"sha" => sha, "tree" => tree}}}} ->
        block = status_block(sha, tree)
        File.write!(Path.join(root, "docs/symphony-hardening-playbook-v4.1/README.md"), block)
        File.write!(Path.join(root, "docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md"), block)
        File.write!(Path.join(root, "docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md"), block)

      _ ->
        :ok
    end
  end

  defp init_git!(root) do
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "governance-test@example.invalid"])
    git!(root, ["config", "user.name", "Governance Test"])
    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "fixture"])
    git!(root, ["remote", "add", "source", @repo_root])
    git!(root, ["fetch", "-q", "source", @accepted_sha])
    git!(root, ["checkout", "-q", "--detach", "--force", @accepted_sha])
    build_fixture!(root)
    git!(root, ["add", "."])
    git!(root, ["commit", "-qm", "candidate"])
    :ok
  end

  defp git!(root, args) do
    System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  end

  defp temp_root do
    root = Path.join(System.tmp_dir!(), "governance-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    root
  end

  defp assert_has_code(:ok, code), do: flunk("expected diagnostic #{inspect(code)}")

  defp assert_has_code({:error, diagnostics}, code) do
    assert Enum.any?(diagnostics, &(&1.code == code)),
           "expected #{inspect(code)} in diagnostics, got: #{inspect(diagnostics)}"
  end
end
