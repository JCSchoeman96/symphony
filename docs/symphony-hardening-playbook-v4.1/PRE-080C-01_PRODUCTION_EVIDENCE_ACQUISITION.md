# PRE-080C-01 — Production Evidence Acquisition

**Status:** PRE-080C-01A was replanned and implementation-authorized. Its implementation remains a candidate on PR #34 and is not Master-accepted. Fresh independent review of candidate `0c58525a30ec741486afae1b1ab581051c7485d4` returned `CHANGES_REQUESTED` because context-free `GuardClass` dispatch validation can accept a dispatch guard without trusted context. Remediation and fresh review remain required.

**PR #34 disposition:** Open and unmerged. Do not merge until the review blocker is corrected, a new exact candidate passes required checks, and fresh independent re-review returns `READY_FOR_MASTER_GATE`. H-080C remains unauthorized.

## Accepted baseline

| Field | Value |
|---|---|
| Base SHA | `01298f55422f689be52657e85ae7f84379c2f8ab` |
| Base tree | `1b1a78af2ba1e0157ff046eaf818861f0b069096` |
| Characterization | `DEFECT_PROVEN` |

## Defect (pre-fix)

Ordinary runtime transition execution validated lifecycle guards but did not acquire every required evidence family in production:

- `Plane.AgentTool` copied `guard_evidence` from host context without host-built semantic attestations.
- `TransitionCoordinator` did not emit `planning_requirements_verified` after fresh-context authorization.
- `SourceControl` candidate capture produced `candidate_state_verified` but not `implementation_checks_verified` / `correction_checks_verified`.

Candidate capture, reviewer mechanical acceptance, and CompletionProof producers were already correct and were not redesigned.

## Repair ownership (post-fix)

| Evidence | Owner |
|---|---|
| Role semantic attestations (`plan_attested`, `implementation_attested`, `correction_attested`, `review_accepted`, `review_changes_requested`) | `Plane.AgentTool` |
| `planning_requirements_verified` | `TransitionCoordinator` (fresh-context path) |
| `implementation_checks_verified` / `correction_checks_verified` | `SourceControl` (candidate capture + required-check verification) |

## Focused regression

```bash
cd elixir
mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs
mix test test/symphony_elixir/plane_agent_tool_test.exs test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/source_control_test.exs
```

## Negative proofs covered

- Stale / mismatched / wrong-generation RuntimeAttempt identity fails closed before semantic minting.
- Prior retry or rearm lineage cannot satisfy a replacement RuntimeAttempt.
- Forged **current-transition** semantic attestation in trusted host context is rejected; historical semantic evidence from prior verified transitions is ignored, not treated as forgery.
- Failed required GitHub checks block Builder candidate enrichment.
- Sequential Builder→Reviewer handoff retains full prior-role evidence (including `implementation_attested`) while minting fresh reviewer semantic evidence.

## Documented production gap (PRE-080C-01 frozen-plan STOP boundary)

- Reproducer `pre_080c` test tagged `:documented_production_gap`: after Planner→Ready, a production-shape Ready WorkItem does **not** supply `dispatch_guard` for unseeded Ready→In Progress via `AgentTool` + `canonical_host_guard_evidence/1`. No fourth production owner was added; Master/Planner scope is required before inventing a dispatch producer.

That was the candidate state at the PRE-080C-01 frozen-plan STOP boundary. The later PRE-080C-01A authorization resumes this exact gap with the corrected incremental scope below; it does not change the historical finding.

## Historical PRE-080C-01A implementation

PRE-080C-01A was replanned and implementation-authorized after the historical frozen-plan STOP boundary above. Its accepted implementation scope added the changes described below. The text records that authorization and implementation; it does not authorize merging or acceptance after the independent review finding.

Dispatch authority is produced only by the Orchestrator from the current running RuntimeAttempt and the current open, in-flight AttemptLedger record with an exact `:bound` fence. The fence RuntimeAttempt identity is compared with the running identity. Route fingerprint remains separate from RuntimeAttempt identity and must match the record, fence, running entry, and trusted Route. The running identity runtime profile must match the Route profile.

The Orchestrator returns fresh proof in `dispatch_authority_evidence`, separate from historical LifecycleAssessment `guard_evidence`. For Ready→In Progress, TransitionCoordinator strips dispatch-guard lookalikes from intent and historical evidence, validates the fresh field against the intent and trusted current Route, and appends one canonical guard for ordinary GuardClass validation. A caller-supplied or historical guard cannot substitute for this fresh proof.

Recovery serialization excludes `dispatch_guard`. Previously stored checkpoints are sanitized when loaded and rewritten durably before becoming recovery state. A restart, retry, rearm, or replacement RuntimeAttempt must acquire new current dispatch evidence.

The production-path regression dispatches a planned Ready WorkItem through the Orchestrator, begins and binds the AttemptLedger record, starts AgentRunner with a fake runtime, requests Ready→In Progress through AgentTool and the default Coordinator context loader, then verifies the controlled mutation. It inserts no dispatch guard. Focused tests also cover unseeded/no-dispatch, armed, released, suspension-pending, stale/replaced identity, lineage, WorkItem, responsibility, route, profile, dependency, source-state, historical evidence, and recovery rejection cases.

## Independent review of candidate `0c58525`

The fresh independent review returned `REVIEW_VERDICT=CHANGES_REQUESTED`. It found that context-free public `GuardClass` APIs could accept a dispatch-shaped guard because dispatch satisfaction fell back to class/name matching whenever the context had no dispatch fields. A dispatch proof cannot authorize itself. The remediation must make every dispatch satisfaction attempt require complete trusted context.

| Evidence | Identity or result |
|---|---|
| Reviewed HEAD | `0c58525a30ec741486afae1b1ab581051c7485d4` |
| Reviewed tree | `eeae30eb4b7d51f6e633ddf897890c84f2596f54` |
| Reviewed synthetic merge | `f10e456e5ba45a06c7379d37905b0e092b3dc000` |
| `make-all` | Run `37762756397`, success |
| `validate-pr-description` | Run `37762759043`, success |
| Earlier `make-all` run | `37642063509`, failed; historical and superseded |

Both successful checks belonged to the reviewed candidate. Green CI did not close the independent-review GuardClass blocker. The checks required for the remediation candidate are `make-all` and `validate-pr-description`, both from GitHub Actions app ID `15368`; they must succeed on the new exact HEAD. Fresh independent re-review must then return `READY_FOR_MASTER_GATE`. PRE-080C-01 remains unaccepted, and H-080C remains unauthorized.

## Final gates (run on candidate)

```bash
cd elixir && mix specs.check && mix format --check-formatted && mix lint
make -C elixir all
git diff --check
```

Record the remediation candidate's exact identities and new required-check run IDs in the external implementation and re-review handoff. Do not put the containing commit, tree, or synthetic merge identities in this file because editing it changes those identities. Do not self-accept PRE-080C-01.
