# H-100 P0 submission correlation remediation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Persist the exact mutation submission boundary and carry one opaque correlation identity through the provider-neutral dispatch path to a synchronous, acknowledged witness immediately before transport.

**Architecture:** Preserve the existing lifecycle states and the conservative Prepared restart fence. Build and validate a provider-neutral mutation envelope from the prepared, submission-fenced attempt, persist `:mutation_submitted` with a new request ID, then carry the same envelope through Tracker and the Plane adapter. In witness-required mode, the Plane client uses Req 0.6.1's request-specific `:finch_request` hook. It checks the final Finch request object's private correlation ID and PATCH identity, waits for an exact-ID sink acknowledgment, then calls Finch once. The hook retains bounded response streaming. The private ID is not an HTTP header or body field.

**Tech Stack:** Elixir 1.19, OTP 28, DETS, Req 0.6.1, ExUnit.

---

## Scope and invariants

- Base every change on SHA `553f8717886f737a4656191c16ecb2f83e3fe76e`, tree `5dae614ac99197cf3af5d891ec76cc1a6d668239`.
- Preserve the lifecycle state set. `submission_fenced_at` remains a field on `:prepared`.
- Keep old DETS records readable when `provider_request_id` is absent. Old unresolved records remain reconciliation-only.
- Never permit automatic resubmission. Keep `retry: false`, `redirect: false`, bounded responses, and fresh verification.
- Witnesses contain no credentials, headers, request body, raw provider response, or environment values.
- A required witness must be synchronously acknowledged for the exact request ID on the final Finch request hook. Any invalid, missing, or mismatched acknowledgment prevents Finch invocation.
- The witness proves an acknowledged handoff of the exact Finch request object. It does not prove network bytes were sent or Plane received the mutation. The low-level host transport remains a separate environment design. This implementation provides an explicit synchronous sink contract and does not execute H-100 or create provider resources.
- Do not merge, push, provision resources or credentials, run H-100, or alter production rollout authority.

## Files and responsibilities

- `elixir/lib/symphony_elixir/work_control/transition_attempt.ex`: durable request ID and state transition validation.
- `elixir/lib/symphony_elixir/work_control/transition_attempt_ledger.ex`: additive validation with legacy record compatibility.
- `elixir/lib/symphony_elixir/work_control/provider_mutation_envelope.ex`: immutable provider-neutral dispatch data and opaque request ID generation.
- `elixir/lib/symphony_elixir/work_control/provider_dispatch_witness.ex`: safe witness shape, validation, and synchronous sink acknowledgment.
- `elixir/lib/symphony_elixir/transition_coordinator.ex`: envelope construction, durable `:mutation_submitted` barrier, and fail-closed dispatch ordering.
- `elixir/lib/symphony_elixir/tracker.ex`: exact envelope propagation across the provider-neutral boundary.
- `elixir/lib/symphony_elixir/plane/adapter.ex`: envelope and contract scope validation before Plane dispatch.
- `elixir/lib/symphony_elixir/plane/client.ex`: emit and await the witness immediately before the mutation transport call.
- Focused tests under `elixir/test/symphony_elixir/` for each boundary, crash recovery, and legacy records.
- `docs/symphony-hardening-playbook-v4.1/` documentation: clarify Prepared fencing, durable submission, witness meaning, and reconciliation.

## Task 1: Add durable request correlation to TransitionAttempt and ledger

**Files:** `work_control/transition_attempt.ex`, `work_control/transition_attempt_ledger.ex`, `work_control_transition_attempt_test.exs`, `transition_attempt_ledger_test.exs`.

- [x] Add failing tests that `mark_mutation_submitted/2` binds a non-empty request ID, rejects malformed IDs, and leaves `submission_fenced_at` as a field rather than a state.
- [x] Run `mix test test/symphony_elixir/work_control_transition_attempt_test.exs`; confirm the new assertions fail because no ID field or validation exists.
- [x] Add optional `provider_request_id` to the struct. Validate it when present. Bind it exactly once when moving from fenced `:prepared` to `:mutation_submitted`; use an opaque generated ID when a caller omits one.
- [x] Add a ledger test that a new submitted attempt with an ID survives close/reopen and that a legacy map record without the field remains readable and non-resubmittable.
- [x] Run `mix test test/symphony_elixir/work_control_transition_attempt_test.exs test/symphony_elixir/transition_attempt_ledger_test.exs`; require all tests to pass.

## Task 2: Persist submitted state before invoking the submit callback

**Files:** `transition_coordinator.ex`, `transition_coordinator_test.exs`, `transition_coordinator_default_path_test.exs`.

- [x] Add an ordering test whose durable ledger callbacks and submit callback append events to one process-local recorder. Assert `prepared_sync < fenced_prepared_sync < submitted_sync < provider_callback` and assert the submitted attempt contains the request ID.
- [x] Add write-failure and sync-failure tests for the submitted write. Assert the provider callback count stays zero and the attempt remains unresolved/fenced when durability is uncertain.
- [x] Run the focused coordinator tests and confirm the ordering tests fail on the existing in-memory-only transition.
- [x] Move `mark_mutation_submitted` out of `submit_once`. Create the provider request ID, pass it to the transition, persist and sync, then call the submit callback.
- [x] Keep failures on the normal reconciliation/fencing path. Never start transport after a failed submitted write or sync.
- [x] Run both coordinator test files; require all tests to pass.

## Task 3: Create and validate ProviderMutationEnvelope

**Files:** new `work_control/provider_mutation_envelope.ex`, `transition_coordinator.ex`, new or focused envelope tests.

- [x] Add tests for envelope creation from a fenced Prepared attempt and matching context, including exact work item, edge, workspace, project, target state, and contract fingerprint.
- [x] Add mismatch tests for each binding field and assert no envelope is returned.
- [x] Run the new focused test and confirm it fails because the module is absent.
- [x] Implement the immutable envelope with a version, opaque request ID, attempt ID, provider, work item, provider scope, requested edge, target state, contract fingerprint, submission timestamp, and `:lifecycle_transition` operation.
- [x] Reject raw credential, header, body, and provider-response fields. Keep the envelope free of authority methods.
- [x] Build and validate the envelope before transitioning to `:mutation_submitted`; pass its exact request ID into the durable attempt.
- [x] Run the focused envelope and coordinator suites; require all tests to pass.

## Task 4: Propagate the same envelope through Tracker and Plane.Adapter

**Files:** `tracker.ex`, `plane/adapter.ex`, `tracker_capabilities_test.exs`, `plane_adapter_test.exs`.

- [x] Add failing tests that the exact envelope reaches the selected adapter unchanged and that a work-item, target-state, or Plane-contract mismatch blocks dispatch.
- [x] Run the focused Tracker and Plane adapter tests to confirm the new propagation assertions fail.
- [x] Pass the typed envelope in the existing controlled-transition options path. Keep capability checks in Tracker and Plane-specific project, state-map, and target checks in Plane.Adapter.
- [x] Do not move lifecycle policy into the adapter or client.
- [x] Run both focused suites; require all tests to pass.

## Task 5: Add the synchronous acknowledged dispatch witness

**Files:** new `work_control/provider_dispatch_witness.ex`, `transition_coordinator.ex`, `plane/adapter.ex`, `plane/client.ex`, focused witness and client tests.

- [x] Add tests proving that a witness contains the envelope's exact correlation and lifecycle identity, contains no request secrets or payload, and validates against the envelope.
- [x] Add client tests proving required sink absence, sink exceptions, failed acknowledgments, and mismatched request IDs result in zero transport calls.
- [x] Add a success test proving acknowledgment occurs before exactly one mutation callback invocation.
- [x] Run the focused tests and confirm they fail before the witness module and dispatch barrier exist.
- [x] Implement the typed witness and an explicit synchronous sink callback contract. A required sink must return an acknowledgment for the same `provider_request_id`.
- [x] Add explicit coordinator options for required-witness mode and the sink. Reject invalid startup configuration; do not use PubSub, logs, hidden application globals, or an unbounded event process.
- [x] Carry these options to Plane.Client with the envelope. Store the request ID in Finch private metadata and emit/validate the witness inside Req's `:finch_request` callback for the final `Finch.Request`, immediately before the callback invokes Finch. Preserve the existing bounded response limit when handling the callback.
- [x] In witness-required mode, pin Req to its Finch adapter, clear global plug/plugin/parameter defaults, and reject query changes so Req-level defaults cannot bypass the witness.
- [x] Preserve `retry: false`, `redirect: false`, raw bounded response handling, and fresh post-mutation verification.
- [x] Run witness, Plane client, adapter, and default-path tests; require all tests to pass.

## Task 6: Characterize restart windows and compatibility

**Files:** `transition_attempt_ledger_test.exs`, `transition_coordinator_test.exs`, `transition_coordinator_default_path_test.exs`.

- [x] Add focused tests for W1 through W6: pre-submitted Prepared, durable Submitted before witness, acknowledged witness before Finch invocation, possible send before response, response before verification persistence, and persisted Verifying during fresh reread.
- [x] Assert the durable state and provider invocation count for each window. Assert every recovered unresolved attempt remains non-resubmittable.
- [x] Add a legacy DETS record without `provider_request_id` and prove it remains readable and eligible only for reconciliation.
- [x] Run these focused tests and confirm failures for any missing crash-window behavior.
- [x] Add only the minimal test support needed to simulate restart boundaries; do not add test-only branches to production modules.
- [x] Run the ledger and coordinator suites; require all tests to pass.

## Task 7: Update lifecycle and proof-contract documentation

**Files:** `elixir/README.md` and the relevant accepted hardening/transition documentation under `docs/symphony-hardening-playbook-v4.1/`.

- [x] Add documentation assertions or a focused repository check for the terms `Prepared`, `submission_fenced_at`, `mutation_submitted`, `provider_request_id`, and `ProviderDispatchWitness`.
- [x] Run the documentation check and confirm it fails before the contract is recorded.
- [x] Document Model C: Prepared with `submission_fenced_at` remains the conservative restart fence; durable `:mutation_submitted` is a separate write-ahead boundary.
- [x] State that a dispatch witness proves the application dispatch boundary was acknowledged, not provider receipt or commit. Keep mutation response provisional and fresh reread required.
- [x] State that legacy uncorrelated records are reconciliation-only and that the host transport must bind the witness to one exact network request before H-100 can resume.
- [x] Run `mix specs.check` and the focused documentation check; require both to pass.

## Task 8: Full verification and independent review

**Files:** no additional production surface beyond Tasks 1 through 7.

- [x] Run targeted TDD suites across TransitionAttempt, ledger, coordinator, Tracker, Plane adapter, and Plane client.
- [x] Run `make all` from `elixir/`, including formatting, lint, coverage, dialyzer, and the isolation proof.
- [x] Review the final diff for unchanged lifecycle states, legacy record compatibility, exact same-ID propagation into the final Finch request, pre-transport sync ordering, and zero Finch calls on witness failure.
- [x] Request an independent review against the design and fix all critical or important findings.
- [x] Verify `git diff --check`, final SHA/tree for the candidate, and the absence of resource creation, provider calls, H-100 execution, merge, or rollout actions.

## Terminal state

Implementation is complete only when the full required checks pass and the source contract is reviewable. H-100 remains blocked until a separate environment design proves that its host witness consumer can correlate the acknowledged application dispatch to the exact response bytes without plaintext inspection or timing-only inference. This plan does not create that environment transport or authorize H-100 execution.
