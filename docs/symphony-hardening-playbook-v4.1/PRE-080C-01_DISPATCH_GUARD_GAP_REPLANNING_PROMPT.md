# PRE-080C-01 — Bounded replanning prompt: `dispatch_guard` acquisition

**Purpose:** Handoff for a **fresh Planner/Master decision only**. Not implementation authorization.

**Frozen candidate:** PR #34 @ `acd59d83a6fdbbe870f201aab175f4853f52734a` (synthetic merge `6abe77229a39d2b5b94d4eadf5d25569423bf348`, base `01298f55422f689be52657e85ae7f84379c2f8ab`).

**Do not** implement on the current branch without a new `PLAN_VERDICT=READY FOR IMPLEMENTATION` that explicitly covers this gap.

---

## What is already proven (do not re-litigate)

| Area | Result on `acd59d8` |
|------|---------------------|
| RuntimeAttempt binding for runtime-owned semantic attestations | Sound (`AgentTool` + scoped `TransitionCoordinator`) |
| Ordinary-path acquisition for Planner/Builder/Fixer/Reviewer semantic + coordinator/SourceControl mechanical guards | Covered by `pre_080c_production_evidence_acquisition_test.exs` (with noted limitations below) |
| Historical semantic evidence in trusted host context | Not treated as forgery; only **current-transition** semantic names are rejected if pre-supplied |
| AgentTool mechanical-only transitions | Semantic minting gated on `WorkflowLifecycle.guard_requirements/2` |
| Exact CI (`make-all`, `validate-pr-description`) | Green on `acd59d8` |

## Frozen reproducer (production shape)

**Test:** `SymphonyElixir.Pre080cProductionEvidenceAcquisitionTest`
`"reproducer: planner-ready work item does not supply dispatch_guard for unseeded ready to in progress"`
(tag `:documented_production_gap`)

**Steps exercised:**

1. Planner→Ready via real `AgentTool` → production `TransitionCoordinator` path (unseeded semantic/mechanical proof for planning).
2. Build Ready `WorkItem` with **projected handoff guards** from the verified transition (`plan_attested`, `planning_requirements_verified`, etc.) — same shape as `build_verified_work_item/2` projection intent.
3. Builder route Ready→`"In Progress"` via `AgentTool.execute/3` with **AgentRunner-shaped** host context (`canonical_host_guard_evidence/1` on that WorkItem). **No** manually inserted `dispatch_guard`.
4. **Observed:** `required_guard_missing` — canonical law requires `dispatch_guard` for `Ready → In Progress`; nothing in the current production path mints or carries it from Planner handoff evidence.

**Explicit non-goal of this reproducer:** It does **not** claim the full Planner→Builder chain is complete; it isolates the dispatch boundary.

## Canonical law (authority)

- Transition: `Ready → In Progress`
- Owner: Symphony (`responsibility: "implementation"` for dispatch policy context)
- Guard requirement: mechanical `dispatch_guard` only (no semantic attestation)

## Planning questions (must be answered before coding)

1. **Which existing production owner** (if any) may mint or surface `dispatch_guard` from machine facts already available at Ready (dependency epoch, dispatch policy, tracker observation, contract binding, etc.)?
2. If no existing owner can do so without a **fourth production module**, is PRE-080C-01 scope expanded, split (e.g. PRE-080C-01b), or stopped pending Programme-B architecture?
3. Where must `dispatch_guard` appear in the evidence lifecycle (WorkItem `satisfied_guards`, coordinator fresh-context only, AgentTool host mechanical merge, or other) so that **unseeded** Builder dispatch matches H-050A grants?
4. What is the **smallest** regression that proves unseeded Ready→In Progress after a real Planner→Ready projection (no manual `dispatch_guard` in `agent_tool_context`)?

## Hard constraints (frozen PRE-080C-01)

- Do **not** add a new production owner (Orchestrator dispatch producer, AgentRunner shortcut, etc.) under the current Planner authorization without a new plan verdict.
- Do **not** add `Ready → In Progress` to `@semantic_transition_guards` or invent a semantic attestation for dispatch.
- Preserve: fail-closed RuntimeAttempt binding, historical-vs-forged semantic distinction, and existing SourceControl/TransitionCoordinator repairs.

## Evidence / governance still open

- **Planner provenance:** `PRE-080C-01_PLANNER_AUTHORIZATION.md` remains an archival copy; independent corroboration against the original handoff is still required for a full Master Gate.
- **Evidence package:** Expand negative-proof matrix per frozen Planner contract when scope is re-opened (wrong responsibility, foreign WorkItem, moved candidate, pending checks, etc.) — only after dispatch ownership is decided.

## Expected Planner output

- `PLAN_VERDICT` either `READY FOR IMPLEMENTATION` with **exact** files/owners/tests for dispatch acquisition, or `STOP` / deferral with programme reference.
- If `READY`: explicit non-scope reaffirmation (no H-080C leakage, no Programme-B EvidenceBundle, no Redis authority, no extra runtime adapters).
- Reproducer test name/tag must remain green or be updated in the same change set as the production fix.
