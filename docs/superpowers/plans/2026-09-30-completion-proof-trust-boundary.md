# CompletionProof trust boundary implementation plan

> **For agentic workers:** Use the approved design in `docs/superpowers/specs/2026-09-30-completion-proof-trust-design.md`. Implement each task test first, verify the regression, then make the smallest change that passes it.

**Goal:** Require typed, candidate-bound SourceControl verification and a fresh provider closure before a `Done` WorkItem validates or satisfies dependencies.

**Architecture:** `CompletionProof` carries verified evidence through merge authorization, exact merge verification, and provider closure. SourceControl creates the first two stages. LifecycleAssessment binds the final stage to the current provider observation and contract. The transition coordinator checks merge verification before submission and accepts completion only after its post-submit reread.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, existing GitHub SourceControl request injection, Plane `ProviderProjectContract`.

---

## File map

- Create `elixir/lib/symphony_elixir/work_control/completion_proof.ex` for typed proof stages and their binding checks.
- Modify `elixir/lib/symphony_elixir/work_control/guard_class.ex` so completion and merge-closure guards accept only the matching typed proof stage.
- Modify `elixir/lib/symphony_elixir/work_control/workflow_lifecycle.ex` so the pre-submit `Merging → Done` guard means merge closure is verified; final completion remains a LifecycleAssessment requirement.
- Modify `elixir/lib/symphony_elixir/source_control.ex` to create merge-authorization evidence from the approved candidate, review evidence, and fresh checks, then verify exact merge and checks.
- Modify `elixir/lib/symphony_elixir/work_control/lifecycle_assessment.ex` to close merge proof against the fresh provider observation and contract.
- Modify `elixir/lib/symphony_elixir/transition_coordinator.ex` to build the accepted WorkItem from post-verification satisfied evidence, including the closed proof.
- Modify `elixir/lib/symphony_elixir/orchestrator.ex` and `elixir/lib/symphony_elixir/work_control/recovery_ledger.ex` so typed completion evidence can be retained and rechecked after restart while legacy name-only records remain readable but unauthoritative.
- Update `elixir/test/symphony_elixir/guard_class_source_control_test.exs`, `work_control_assessment_test.exs`, `work_control_work_item_test.exs`, `source_control_merge_verification_test.exs`, `transition_coordinator_default_path_test.exs`, and recovery tests.

## Task 1: Reject caller-built completion tokens

- [x] Change lifecycle tests so the bare completion requirement map and an `outcome: :verified` map both leave `Done` in `:validation_required` from `:merging`.
- [x] Add guard tests proving only the matching typed completion proof stage satisfies each completion-specific guard.
- [x] Run the focused tests and confirm the new assertions fail against the current code.
- [x] Add `CompletionProof` stage types and strict `GuardClass` handling.
- [x] Run the focused lifecycle and guard tests.

Run from `elixir/`:

```bash
mix test test/symphony_elixir/work_control_assessment_test.exs test/symphony_elixir/guard_class_source_control_test.exs
```

## Task 2: Issue candidate-bound merge evidence

- [x] Add a SourceControl test that requests merge authorization from a verified review acceptance and checks the issued proof binds the same CandidateRef, tree, and policy fingerprint.
- [x] Add a SourceControl test that rejects missing, stale, or mismatched review/candidate evidence.
- [x] Run the new SourceControl tests and confirm they fail before implementation.
- [x] Implement `Ready to Merge → Merging` proof issuance using fresh candidate and required-check reads.
- [x] Implement `Merging → Done` merge verification using the proof's CandidateRef, review snapshot, policy fingerprint, and required post-merge checks.
- [x] Add a distinct `completion_merge_verified` pre-submit guard and keep human merge authority unchanged.
- [x] Run SourceControl and lifecycle transition tests.

Run from `elixir/`:

```bash
mix test test/symphony_elixir/source_control_merge_verification_test.exs test/symphony_elixir/work_control_workflow_lifecycle_test.exs
```

## Task 3: Bind proof to provider closure

- [x] Add tests that reject a merge-verified proof for a wrong work item or renamed Done state and bind closure to the provider project contract.
- [x] Add a positive test using the existing GitHub request seam, an exact verified merge, and a fresh Plane `Done` observation.
- [x] Run the tests and confirm the positive and negative assertions fail before implementation.
- [x] Close the typed proof in LifecycleAssessment only after the fresh observation maps to configured `Done`.
- [x] Feed post-verification `assessment.satisfied_guards` into the WorkItem created after a verified transition.
- [x] Verify `WorkItem.dependency_satisfying?/1` returns true only for the fully closed proof.
- [x] Run completion, transition default-path, and dependency tests.

Run from `elixir/`:

```bash
mix test test/symphony_elixir/work_control_assessment_test.exs test/symphony_elixir/work_control_work_item_test.exs test/symphony_elixir/transition_coordinator_default_path_test.exs test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/dependency_policy_test.exs
```

## Task 4: Preserve typed proof safely

- [x] Add recovery tests showing a typed completion proof survives a checkpoint and must match a fresh observation before it satisfies dependencies.
- [x] Add a legacy-record test showing a bare completion map loads but cannot validate `Done`.
- [x] Run the recovery tests and confirm the required behavior fails before implementation.
- [x] Preserve only validated typed completion proof fields in durable mechanical evidence; keep legacy maps readable and fail closed at assessment.
- [x] Run focused recovery tests and `git diff --check`.

## Task 5: Final verification

- [x] Run all affected tests together, including companion default-path test files needed by the coordinator suite.
- [x] Run `make -C elixir all` and confirm format, specs, Credo, coverage, and Dialyzer pass.
- [x] Review the diff against the approved design and verify no H-080A, H-080B, H-080C, or H-100 work entered the change.
