# POST-H120A / PRE-H100 Governance Materialization Implementation Plan

**Repository:** `JCSchoeman96/symphony`
**Plan path:** `docs/superpowers/plans/2026-10-18-post-h120a-pre-h100-governance-materialization.md`
**Planning baseline:** `a58fee3a18eb2822f63d2ed3e44655d900f914e0`
**Planning baseline tree:** `d8b93a7dec4199cd833bad73e721131db4c2d065`

## 1. Purpose and hard boundary

Materialize the externally supplied Master Governance decision:

```text
MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01
2026-10-18T16:32:05+02:00
```

into the repository's existing governance projection, synchronized status surfaces and governance checker.

This change records:

```text
H-120A = ACCEPTED
H-100 = AUTHORIZED_ACTIVE_NOT_ACCEPTED
H-110 = NOT_AUTHORIZED
H-120B = NOT_AUTHORIZED
NEXT_GOVERNANCE_STEP = H-110
NEXT_AUTHORIZED_PHASE = NONE
PRODUCTION_ROLLOUT = NOT_AUTHORIZED
AUTOMATED_MERGE = NOT_AUTHORIZED
MERGE_AUTHORITY = HUMAN_ONLY
```

It does **not** execute H-100.

It must not:

- provision Plane resources;
- create disposable GitHub proof resources;
- launch Codex for H-100 proof;
- perform lifecycle proof;
- mutate runtime lifecycle state;
- merge any candidate;
- grant H-100 acceptance;
- authorize H-110 or H-120B;
- authorize production rollout;
- introduce automated merge;
- alter runtime production behavior;
- modify the Master Roadmap;
- rewrite the accepted H-120A contract.

Repository records are derivative enforcement/materialization. The supplied Master Governance decision creates the authority.

---

# 2. Accepted remote preflight

The implementation plan is based on the following independently verified remote facts:

```text
PROTECTED_MAIN_SHA =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

PROTECTED_MAIN_TREE =
d8b93a7dec4199cd833bad73e721131db4c2d065

MAIN_PROTECTED = YES

REQUIRED_CHECK_1 = make-all
REQUIRED_CHECK_1_APP_ID = 15368

REQUIRED_CHECK_2 = validate-pr-description
REQUIRED_CHECK_2_APP_ID = 15368
```

PR #50:

```text
H120A_PR = 50

H120A_REVIEWED_HEAD =
faff4d1e828c78d4c0474d64829c5107d0b1e7d5

H120A_MERGE_SHA =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

H120A_MERGE_TREE =
d8b93a7dec4199cd833bad73e721131db4c2d065

MERGE_PARENT_1 =
c2b142c7ef89fb7dd2bb46c5d76732247a653f62

MERGE_PARENT_2 =
faff4d1e828c78d4c0474d64829c5107d0b1e7d5

MERGE_SIGNATURE = VERIFIED_VALID
```

Post-merge closure:

```text
H120A_POST_MERGE_RUN = 39135965103
H120A_POST_MERGE_EVENT = push
H120A_POST_MERGE_HEAD = a58fee3a18eb2822f63d2ed3e44655d900f914e0
H120A_POST_MERGE_ATTEMPT = 1
H120A_POST_MERGE_STATUS = completed
H120A_POST_MERGE_RESULT = success
REQUIRED_POST_MERGE_JOB_CLOSURE = TERMINAL
```

Master Roadmap identity:

```text
PATH =
docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md

VERSION = V4.1

BLOB_SHA =
4b0528bdc0647d889b42ebc478081d5b873898fe
```

No remote prerequisite materially differs from the supplied baseline.

---

# 3. Authority hierarchy

Authority order remains:

1. `docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md`
2. Supplied Master Governance decision `MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01`
3. `docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`
4. `docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md`
5. `docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json`
6. bounded governance materialization records;
7. `SymphonyElixir.Governance.Check` and its tests as mechanical enforcement of the accepted snapshot.

The derivative repository surfaces must agree with the higher authority. They cannot manufacture, enlarge, rename or replace the human governance decision.

The Master Roadmap remains byte-identical.

---

# 4. Explicit lifecycle/state transition model

## 4.1 H-120A

Initial state:

```text
AUTHORIZED_ACTIVE_NOT_ACCEPTED
```

Transition:

```text
AUTHORIZED_ACTIVE_NOT_ACCEPTED
→ ACCEPTED
```

Required guards:

```text
PR #50 identity is exact
AND reviewed HEAD = faff4d1e828c78d4c0474d64829c5107d0b1e7d5
AND merge SHA = a58fee3a18eb2822f63d2ed3e44655d900f914e0
AND merge tree = d8b93a7dec4199cd833bad73e721131db4c2d065
AND merge parents prove reviewed HEAD as merged candidate
AND merge signature verification is valid
AND protected main equals the merge
AND post-merge push run = 39135965103
AND run attempt = 1
AND terminal conclusion = SUCCESS
AND required post-merge jobs have terminal closure
AND supplied Master decision records H120A=ACCEPTED
```

Side effects:

```text
CURRENT_ACCEPTED_PHASE becomes H-120A

accepted_protected_main_at_decision becomes:
  SHA  a58fee3a18eb2822f63d2ed3e44655d900f914e0
  TREE d8b93a7dec4199cd833bad73e721131db4c2d065

H120A_NOT_ACCEPTED is removed

current decision snapshot becomes:
  MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01
  2026-10-18T16:32:05+02:00

H-100 becomes sole active authorization
```

Terminal state for this transition:

```text
H-120A = ACCEPTED
```

No later transition for H-120A is authorized by this materialization.

## 4.2 H-100

Initial state:

```text
NOT_AUTHORIZED
```

Transition:

```text
NOT_AUTHORIZED
→ AUTHORIZED_ACTIVE_NOT_ACCEPTED
```

Guard:

```text
supplied Master decision
MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01
```

Side effects:

```text
CURRENTLY_AUTHORIZED_WORK = H-100
CURRENTLY_AUTHORIZED_STATUS = AUTHORIZED_ACTIVE_NOT_ACCEPTED
KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS = H100_NOT_ACCEPTED
NEXT_GOVERNANCE_STEP = H-110
NEXT_AUTHORIZED_PHASE = NONE
```

Current terminal boundary for this materialization:

```text
H-100 = AUTHORIZED_ACTIVE_NOT_ACCEPTED
```

`ACCEPTED` is explicitly forbidden in this PR.

## 4.3 H-110

State remains:

```text
NOT_AUTHORIZED
```

No transition.

`NEXT_GOVERNANCE_STEP=H-110` is sequencing information, **not authorization**.

`NEXT_AUTHORIZED_PHASE` remains `NONE`.

## 4.4 H-120B

State remains:

```text
NOT_AUTHORIZED
```

No transition.

## 4.5 Rollout and merge authority

States remain:

```text
PRODUCTION_ROLLOUT = NOT_AUTHORIZED
AUTOMATED_MERGE = NOT_AUTHORIZED
MERGE_AUTHORITY = HUMAN_ONLY
```

No transition is permitted.

---

# 5. Exact schema-v1 target

Do not create schema v2.

Do not add:

```text
h_120a
h_100
h_110
h_120b
production_rollout
automated_merge
merge_authority
```

to `V4_1_GOVERNANCE_PROJECTION.json`.

The checker rejects unknown projection fields, and the existing schema already represents the required decision.

Target existing-field semantics:

```text
schema_version = 1

projection_role =
MACHINE_PROJECTION_OF_ACCEPTED_AUTHORITY

governing_roadmap.id =
docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md

governing_roadmap.version =
V4.1

governing_roadmap.blob_sha =
4b0528bdc0647d889b42ebc478081d5b873898fe

authority_snapshot.accepted_protected_main_at_decision.sha =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

authority_snapshot.accepted_protected_main_at_decision.tree =
d8b93a7dec4199cd833bad73e721131db4c2d065

authority_snapshot.current_accepted_phase =
H-120A

authority_snapshot.current_accepted_prerequisite =
PRE-H080C

authority_snapshot.pre_080c_02_outcome =
LIMIT_FOUND

authority_snapshot.currently_authorized_work.id =
H-100

authority_snapshot.currently_authorized_work.status =
AUTHORIZED_ACTIVE_NOT_ACCEPTED

authority_snapshot.currently_authorized_work.scope =
Real Disposable Live Proof only, as defined by the V4.1 Master Roadmap and the accepted H-120A Governance Pre-Gate. Use real Plane, real Codex, real GitHub and real Symphony only against explicitly approved disposable resources. Prove the canonical lifecycle through exact-candidate human merge, trusted GitHub merge verification, controlled Plane Done, fresh Plane reread, validated Done and downstream dependency satisfaction.

authority_snapshot.pre_h080c =
ACCEPTED

authority_snapshot.h_080c =
ACCEPTED

authority_snapshot.next_governance_step =
H-110

authority_snapshot.next_authorized_phase =
null

decision.authority =
Master Governance

decision.reference =
MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01

decision.timestamp =
2026-10-18T16:32:05+02:00

known_unresolved_governance_conditions =
["H100_NOT_ACCEPTED"]
```

The supplied H-100 scope must be transcribed as authority, not paraphrased into a broader permission.

---

# 6. `accepted_protected_main_at_decision` conclusion

The existing repository semantics show that `accepted_protected_main_at_decision` is the baseline associated with the **current accepted Master decision snapshot**, not an immutable H-090 history field.

Evidence in the current implementation:

- the checker pins this field together with the current decision reference and timestamp;
- all canonical status surfaces mirror it from the projection;
- freeze mode uses its SHA/tree as the accepted ancestry baseline for the current authorized candidate;
- the current value is PR #48's H-090 acceptance baseline because that was the baseline of the currently materialized Master decision.

Therefore this materialization must update it to:

```text
sha =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

tree =
d8b93a7dec4199cd833bad73e721131db4c2d065
```

The previous H-090 baseline remains historical evidence in the existing historical materialization and ledger history.

Do not overwrite historical provenance records.

---

# 7. Provenance separation

The implementation must preserve three distinct provenance layers.

## Historical H-090 decision provenance

Retain the existing record of:

```text
MG-2026-10-18-H090-ACCEPT-H120A-AUTH-01
```

and PR #48 evidence as historical state.

Do not rewrite that historical decision to appear as if it authorized H-100.

## Historical H-120A authorization provenance

Retain:

```text
POST-H090_PRE-H120A_GOVERNANCE_MATERIALIZATION.md
H-120A_GOVERNANCE_PRE_GATE.md
docs/superpowers/plans/2026-10-18-h120a-governance-pre-gate.md
```

as the provenance of H-120A authorization/design/execution.

Do not mutate them into post-hoc H-100 authority documents.

## Current H-120A acceptance / H-100 authorization provenance

Create:

```text
docs/symphony-hardening-playbook-v4.1/
POST-H120A_PRE-H100_GOVERNANCE_MATERIALIZATION.md
```

to record:

```text
decision reference
decision timestamp
PR #50
reviewed HEAD
merge SHA/tree/parents
signature verification
protected-main identity
post-merge run/attempt/result
H-120A acceptance
H-100 active authorization scope
H-110/H-120B non-authorization
human-only merge
no rollout
no automated merge
```

This new record is derivative evidence. It is not a second Master decision.

---

# 8. H-120A accepted contract remains binding

`H-120A_GOVERNANCE_PRE_GATE.md` remains unchanged.

Its accepted rules remain binding for subsequent H-100 execution, including:

```text
candidate freeze
required-check identity
rerun semantics
evidence provenance
pre-provisioning manifest
disposable Plane/GitHub resources
human-only merge
post-merge reread
MergeVerification
CompletionProof
controlled Plane closure
cleanup hold
```

There is no contradiction between the accepted H-120A contract and the new H-100 authorization.

The historical H-120A document's pre-acceptance status statements are historical evidence and are not rewritten.

This materialization must not execute any of its live-proof procedure.

If implementation discovers an actual normative contradiction rather than a historical-status difference:

```text
STOP=H120A_ACCEPTED_CONTRACT_CONTRADICTION
```

---

# 9. Resource/domain map

| Resource/domain | Authority role | Mutability in this PR | Primary/derivative | Inputs | Outputs | Required invariant |
|---|---|---|---|---|---|---|
| `V4_1_MASTER_ROADMAP.md` | Governing V4.1 phase law | Immutable | Primary normative authority | Existing accepted programme law | H-120A/H-100/H-110/H-120B phase definitions | Blob remains exactly `4b0528bd…` |
| Supplied Master decision | Human governance authorization/acceptance | External; not edited | Primary decision authority | Verified H-120A closure + human adjudication | H-120A accepted; H-100 active | Repository may record but never manufacture it |
| Unified Execution Roadmap | Human-readable synchronized execution/status view | Current-state portions mutable | Derivative | Master Roadmap + decision + projection | Current sequencing/status | Must not outrank Master Roadmap |
| Hardening Status Ledger | Concise historical/current programme index | Current section/rows mutable; historical facts preserved | Derivative | GitHub evidence + Master decision | Accepted/active phase record | Historical decisions not rewritten |
| Governance Projection | Machine-readable accepted authority snapshot | Existing values mutable | Derivative | Master decision + accepted baseline | Canonical checker snapshot | Schema v1 only; no invented authority fields |
| `Governance.Check` | Mechanical validator/enforcer | Snapshot constants only | Derivative enforcement | Projection, canonical docs, Git identity | Pass/fail diagnostics | No bypass/schema weakening |
| `Governance.Check` tests | Regression/negative-control authority | Mutable | Verification | Intended snapshot/checker behavior | Deterministic proofs | Must reject unauthorized escalation |
| New materialization record | Bounded evidence/provenance record | New | Derivative | PR #50 + post-merge closure + supplied decision | Human-readable materialization | Explicitly states it does not create authority |
| H-120A accepted artifact | Accepted pre-gate contract | Immutable here | Accepted evidence/contract | Prior H-120A authorization | Rules governing future H-100 proof | No silent rewrite |

---

# 10. Runtime domains explicitly untouched

No changes are authorized to:

```text
Orchestrator
WorkflowLifecycle
CandidateRef
CandidateVerification
MergeVerification
CompletionProof
SourceControl runtime
GitHub SourceControl runtime
Plane runtime
RuntimeAttempt
AttemptLineage
Authority Fence
SuspensionContext
workspace ownership
Codex isolation
dependency graph
transition coordinator
provider mutation logic
```

`elixir/lib/symphony_elixir/governance/check.ex` is governance validation code, not runtime authority/lifecycle implementation. Only existing snapshot constants may change unless implementation discovers a contradiction and stops.

No runtime-production behavior change is permitted.

---

# 11. Smallest exact file envelope

## Create

### 1. `docs/superpowers/plans/2026-10-18-post-h120a-pre-h100-governance-materialization.md`

Reason:

Repository convention retains approved implementation plans.

The implementation agent must materialize this approved plan verbatim; it must not redesign it.

### 2. `docs/symphony-hardening-playbook-v4.1/POST-H120A_PRE-H100_GOVERNANCE_MATERIALIZATION.md`

Reason:

A bounded decision/evidence record is required to distinguish the new H-120A acceptance/H-100 authorization from the older H-090/H-120A decision.

## Modify

### 3. `docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json`

Reason:

This is the schema-v1 machine projection of the currently accepted authority. It must move from H-090/H-120A to H-120A/H-100 and record the new decision baseline/reference/timestamp.

### 4. `elixir/lib/symphony_elixir/governance/check.ex`

Reason:

The checker currently pins the old H-090/H-120A snapshot in constants. Change only those snapshot constants needed for the new accepted state.

Do not change schema logic, freeze algorithm, status parser, immutable-artifact logic or authority rules unless a contradiction is discovered; if one is required, STOP rather than expanding scope.

### 5. `elixir/test/symphony_elixir/governance_check_test.exs`

Reason:

The current regression suite is explicitly written around H-090 accepted / H-120A active. It must be updated to the new exact snapshot and retain/add the required negative controls.

### 6. `docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md`

Reason:

This is a checker-enforced canonical status surface and the historical phase index. It must record H-120A acceptance and H-100 active authorization.

### 7. `docs/symphony-hardening-playbook-v4.1/README.md`

Reason:

The checker explicitly validates this as one of three canonical status surfaces. Its status block and current authority index must remain synchronized.

### 8. `docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`

Reason:

The checker explicitly validates this status surface. Its current-state projection must record H-120A accepted / H-100 active without changing Master Roadmap phase law.

## Explicit exclusions

Do not modify:

```text
docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
docs/symphony-hardening-playbook-v4.1/H-120A_GOVERNANCE_PRE_GATE.md
docs/symphony-hardening-playbook-v4.1/POST-H090_PRE-H120A_GOVERNANCE_MATERIALIZATION.md
docs/superpowers/plans/2026-10-18-h120a-governance-pre-gate.md
runtime production modules
live-proof harness behavior
```

If another file becomes necessary, explain the mechanical necessity before editing it. Do not expand scope for convenience.

---

# 12. Canonical status block target

All three existing `SYMPHONY_GOVERNANCE_STATUS_V1` blocks must remain identical in semantics and use only their existing keys:

```text
GOVERNANCE_PROJECTION_PATH=docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json
GOVERNING_ROADMAP_ID=docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
GOVERNING_ROADMAP_VERSION=V4.1
GOVERNING_ROADMAP_BLOB_SHA=4b0528bdc0647d889b42ebc478081d5b873898fe
ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA=a58fee3a18eb2822f63d2ed3e44655d900f914e0
ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE=d8b93a7dec4199cd833bad73e721131db4c2d065
CURRENT_ACCEPTED_PHASE=H-120A
CURRENT_ACCEPTED_PREREQUISITE=PRE-H080C
PRE_080C_02_OUTCOME=LIMIT_FOUND
CURRENTLY_AUTHORIZED_WORK=H-100
CURRENTLY_AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
PRE_H080C=ACCEPTED
H_080C=ACCEPTED
NEXT_GOVERNANCE_STEP=H-110
NEXT_AUTHORIZED_PHASE=NONE
DECISION_AUTHORITY=Master Governance
DECISION_REFERENCE=MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01
DECISION_TIMESTAMP=2026-10-18T16:32:05+02:00
KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=H100_NOT_ACCEPTED
```

Do not add rollout/merge fields to this block. The checker has a fixed key set and adding them would be a schema/status-format change.

Record these non-schema authority boundaries in prose/materialization evidence instead:

```text
H110=NOT_AUTHORIZED
H120B=NOT_AUTHORIZED
PRODUCTION_ROLLOUT=NOT_AUTHORIZED
AUTOMATED_MERGE=NOT_AUTHORIZED
MERGE_AUTHORITY=HUMAN_ONLY
```

---

# 13. Human-readable status updates

## Hardening Status Ledger

Update the current governance section to say, without ambiguity:

- Master Governance accepted H-120A under `MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01`;
- PR #50 is the accepted H-120A merge;
- reviewed HEAD is `faff4d1e…`;
- accepted merge/tree are `a58fee3a…` / `d8b93a7d…`;
- post-merge run `39135965103`, attempt 1, completed successfully;
- H-100 is sole active authorization and remains not accepted;
- H-110 and H-120B remain not authorized;
- next governance step is H-110;
- next authorized phase is NONE;
- production rollout and automated merge remain unauthorized;
- merge authority remains human-only.

Change the phase index:

```text
H-120A:
  ACCEPTED
  PR #50
  accepted merge a58fee3a...
  tree d8b93a7d...
  evidence = new materialization + post-merge run
  next authorization = H-100 Real Disposable Live Proof

H-100:
  AUTHORIZED / ACTIVE / NOT ACCEPTED
  no accepted merge
  evidence = new materialization + Master decision
  next governance step = H-110
```

Do not back-edit historical H-090 entries.

## Playbook README

Add the new materialization to the authority/evidence index.

Update current-state prose and its machine block.

Keep older materialization links as historical provenance.

## Unified Execution Roadmap

Update only the current-state/status material that is intended to mirror governance.

Do not rewrite normative Master Roadmap definitions.

Make H-100's authorization boundary explicit and H-110/H-120B non-authorization unambiguous.

---

# 14. New bounded materialization record contents

`POST-H120A_PRE-H100_GOVERNANCE_MATERIALIZATION.md` must include at least:

## Purpose

State that this file materializes an externally supplied human Master Governance decision and cannot create or enlarge authority.

## Exact H-120A acceptance evidence

```text
repository
PR #50
reviewed HEAD
merge SHA
merge tree
merge parents
signature verification
protected-main match
required branch checks
post-merge run 39135965103
push event
attempt 1
completed/success
required post-merge job closure
```

## Decision identity

Exactly:

```text
DECISION_AUTHORITY=Master Governance
DECISION_REFERENCE=MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01
DECISION_TIMESTAMP=2026-10-18T16:32:05+02:00
```

No derived or replacement decision identity.

## Phase boundary

Exactly describe:

```text
H-120A = ACCEPTED
H-100 = AUTHORIZED_ACTIVE_NOT_ACCEPTED
H-110 = NOT_AUTHORIZED
H-120B = NOT_AUTHORIZED
NEXT_GOVERNANCE_STEP = H-110
NEXT_AUTHORIZED_PHASE = NONE
```

## Rollout/merge boundary

Exactly record:

```text
PRODUCTION_ROLLOUT = NOT_AUTHORIZED
AUTOMATED_MERGE = NOT_AUTHORIZED
MERGE_AUTHORITY = HUMAN_ONLY
```

## H-100 scope

Transcribe the supplied Real Disposable Live Proof scope without broadening it.

Explicitly state that this materialization performs **none** of that proof.

## Historical provenance

Distinguish:

```text
historical H-090 acceptance / H-120A authorization decision
historical H-120A accepted pre-gate contract
current H-120A acceptance / H-100 authorization decision
```

## Freeze semantics

Record:

```text
mix governance.check --freeze --candidate-phase H-100
```

as the positive candidate-phase selector once this materialization is complete.

State that H-120A, H-110, H-120B and arbitrary phases must fail the active candidate selector.

State that decision-materialization mode remains inappropriate while H-100 is active because the current checker intentionally requires the `NONE/NONE/NONE` authorized-work tuple for that selector.

Do not weaken that rule merely to make a materialization command pass.

---

# 15. Governance.Check implementation plan

The existing checker already has the required machinery.

Update snapshot constants only:

```text
accepted baseline SHA/tree
accepted phase
authorized work ID
authorized work status if text changed
authorized scope
next governance step
decision reference
decision timestamp
unresolved conditions
```

Keep unchanged:

```text
Master Roadmap path/version/blob
current accepted prerequisite PRE-H080C
PRE-080C-02 outcome LIMIT_FOUND
PRE-H080C accepted state
H-080C accepted state
next_authorized_phase = nil
schema version
schema field set
status key set
freeze selector algorithm
materialize-decision algorithm
candidate ancestry checks
immutable blob checks
worktree integrity checks
skill-policy checks
```

The positive candidate freeze automatically changes from H-120A to H-100 because existing logic requires:

```text
candidate_phase == currently_authorized_work.id
AND authorized_work != NONE/NONE/NONE
```

No H-100 special case or bypass is justified.

---

# 16. Governance.Check test plan

First update test fixture constants to:

```text
accepted SHA =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

accepted tree =
d8b93a7dec4199cd833bad73e721131db4c2d065

accepted phase =
H-120A

authorized work =
H-100 / AUTHORIZED_ACTIVE_NOT_ACCEPTED

next governance step =
H-110

decision reference =
MG-2026-10-18-H120A-ACCEPT-H100-AUTH-01

decision timestamp =
2026-10-18T16:32:05+02:00

conditions =
["H100_NOT_ACCEPTED"]
```

Change:

```text
candidate_phase_options()
```

to use `H-100`.

Rename outdated H-090/H-120A test descriptions so test intent matches the new state.

Retain all generic parser, immutable-artifact, status-synchronization, freeze-integrity and policy regressions.

---

# 17. Required negative-control matrix

The focused governance suite must prove all of the following.

| Negative control | Expected mechanical result |
|---|---|
| Wrong H-120A accepted merge SHA | `authority_snapshot_mismatch`, or baseline-specific mismatch under freeze |
| Wrong H-120A accepted merge tree | `authority_snapshot_mismatch`, or `baseline_tree_mismatch` under freeze |
| `current_accepted_phase != H-120A` | reject |
| Active work other than H-100 | reject |
| Wrong H-100 status | reject |
| Wrong H-100 scope | reject |
| Wrong decision reference | reject |
| Wrong decision timestamp | reject |
| `H100_NOT_ACCEPTED` missing | reject |
| unresolved condition replaced by another value | reject |
| H-100 represented as accepted active work | reject |
| `current_accepted_phase=H-100` | reject |
| H-120A remains active instead of accepted | reject |
| H-110 becomes active | reject |
| H-120B becomes active | reject |
| `next_authorized_phase=H-110` | reject |
| any non-null `next_authorized_phase` | reject |
| H-100 freeze selector | accept on clean descendant |
| H-120A freeze selector after materialization | reject |
| H-110 freeze selector | reject |
| H-120B freeze selector | reject |
| arbitrary/NONE/blank freeze selector | reject |
| decision-materialization selector while H-100 is active | reject with `materialization_requires_no_authorized_work` |
| malformed projection | reject |
| projection/status block disagreement | reject |
| missing/extra/duplicate status keys | reject |
| Master Roadmap mutation | reject |
| immutable roadmap tree entry mutation in freeze mode | reject |
| repository projection adds a `production_rollout` authority field | reject as unknown schema field |
| repository projection adds an `automated_merge` authority field | reject as unknown schema field |
| repository projection attempts to invent a merge-authority field | reject as unknown schema field |
| decision authority changed from Master Governance | reject |
| projection role changed to imply primary authority | reject |
| dirty/unresolved candidate worktree in freeze mode | reject |
| candidate not descended from accepted H-120A baseline | reject |

The rollout/automated-merge negative controls should use the existing strict schema as the guard. Do **not** add those fields merely so the checker can validate them.

This proves that the derivative projection cannot manufacture additional human authority.

---

# 18. H-I19 through H-I24 preservation

This PR must not alter any runtime implementation or characterization governing H-I19 through H-I24.

Required proof is preservation by non-change plus full regression verification.

No test should be weakened, skipped or rewritten merely because the active governance phase changed.

If satisfying the governance snapshot would require changing one of those runtime authority boundaries:

```text
STOP=H_I19_H_I24_WEAKENING_REQUIRED
```

---

# 19. Performance/scaling delta

Expected and required:

```text
provider runtime calls delta = 0
SCM runtime calls delta = 0
GenServer behavior delta = 0
Tasks delta = 0
mailboxes delta = 0
Plane epoch delta = 0
dependency graph delta = 0
Redis delta = 0
Postgres delta = 0
PubSub delta = 0
cache delta = 0
index delta = 0
runtime memory topology delta = 0
```

Any runtime-performance delta means the implementation has escaped the authorized envelope.

---

# 20. Implementation-agent local preflight

The remote Planner has no local worktree and makes no worktree-cleanliness claim.

The implementation agent must use a **fresh isolated worktree**.

Before editing:

```bash
git fetch origin
git status --short
git rev-parse HEAD
git rev-parse 'HEAD^{tree}'
git rev-parse origin/main
git rev-parse 'origin/main^{tree}'
git show --no-patch --show-signature origin/main
```

Required:

```text
WORKTREE=CLEAN

HEAD =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

HEAD_TREE =
d8b93a7dec4199cd833bad73e721131db4c2d065

ORIGIN_MAIN_SHA =
a58fee3a18eb2822f63d2ed3e44655d900f914e0

ORIGIN_MAIN_TREE =
d8b93a7dec4199cd833bad73e721131db4c2d065
```

If any differs:

```text
STOP=IMPLEMENTATION_BASE_OR_WORKTREE_MISMATCH
```

Do not silently rebase onto a moved `main`.

Also re-resolve remotely before editing:

```text
PR #50 merged identity
reviewed HEAD
merge parents/tree/signature
run 39135965103 attempt/result
branch protection
required checks
Master Roadmap blob
```

A material discrepancy is a stop, not an invitation to adapt the approved plan silently.

---

# 21. Task 1 — Pin the new governance snapshot in tests

**File:**

```text
elixir/test/symphony_elixir/governance_check_test.exs
```

Actions:

1. Replace old H-090/H-120A fixture values with the exact H-120A/H-100 snapshot.
2. Change the positive freeze helper to H-100.
3. Rewrite obsolete assertions such as “rejects H-100 as active” into the new correct negative controls.
4. Add explicit rejection of H-100 acceptance.
5. Add explicit H-110/H-120B active-authority rejection.
6. Add explicit `next_authorized_phase=H-110` rejection.
7. Add exact decision ref/timestamp regressions.
8. Add exact accepted SHA/tree regressions.
9. Change unresolved condition expectation to only `H100_NOT_ACCEPTED`.
10. Add focused “projection cannot manufacture rollout/automated-merge/merge authority” strict-schema regressions.
11. Retain malformed projection, status mismatch, immutable Master Roadmap, ancestry and worktree-integrity tests.

Run:

```bash
cd elixir
mix test test/symphony_elixir/governance_check_test.exs
```

At the deliberate test-first point, failures attributable to the old checker snapshot are expected.

Do not alter generic checker logic to make the tests easier to satisfy.

---

# 22. Task 2 — Materialize the machine snapshot

**Files:**

```text
docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json
elixir/lib/symphony_elixir/governance/check.ex
```

Actions:

1. Update only existing projection fields to the target schema-v1 state.
2. Update the accepted decision baseline to the H-120A merge SHA/tree.
3. Set `current_accepted_phase=H-120A`.
4. Set H-100 as sole active authorized work.
5. Use the supplied bounded H-100 scope.
6. Set `next_governance_step=H-110`.
7. Keep `next_authorized_phase=null`.
8. Set the exact new Master decision identity.
9. Replace unresolved condition with `H100_NOT_ACCEPTED`.
10. Update matching checker constants.
11. Do not change schema/freeze/status validation algorithms.

Focused verification:

```bash
cd elixir
mix test test/symphony_elixir/governance_check_test.exs
```

Expected:

```text
PASS
```

If supporting H-100 requires checker bypass logic, schema v2 or runtime authority changes:

```text
STOP=H100_CANNOT_BE_ISOLATED_IN_EXISTING_GOVERNANCE_SCHEMA
```

---

# 23. Task 3 — Synchronize all human/status surfaces

**Files:**

```text
docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md

docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md

docs/symphony-hardening-playbook-v4.1/README.md

docs/symphony-hardening-playbook-v4.1/
POST-H120A_PRE-H100_GOVERNANCE_MATERIALIZATION.md

docs/superpowers/plans/
2026-10-18-post-h120a-pre-h100-governance-materialization.md
```

Actions:

1. Materialize this approved plan verbatim at its exact path.
2. Add the bounded post-H120A/pre-H100 record.
3. Update ledger current state and phase index.
4. Update README authority index/current status.
5. Update Unified Roadmap current-state projection.
6. Synchronize all three `SYMPHONY_GOVERNANCE_STATUS_V1` blocks exactly.
7. Preserve prior H-090 and H-120A provenance as history.
8. Explicitly retain:
   - H-100 not accepted;
   - H-110 not authorized;
   - H-120B not authorized;
   - no production rollout;
   - no automated merge;
   - human-only merge.
9. Do not change Master Roadmap or accepted H-120A artifact.

Focused verification:

```bash
cd elixir
mix test test/symphony_elixir/governance_check_test.exs
mix governance.check
mix format --check-formatted
cd ..
git diff --check
```

Expected:

```text
all pass
```

---

# 24. Task 4 — Candidate commit and H-100 freeze verification

Before freeze verification, all intended changes must be reviewed and committed with a signed commit so the candidate worktree is clean.

Review:

```bash
git diff --check
git diff --stat origin/main...HEAD
git diff origin/main...HEAD -- \
  docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md \
  docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md \
  docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json \
  docs/symphony-hardening-playbook-v4.1/README.md \
  docs/symphony-hardening-playbook-v4.1/POST-H120A_PRE-H100_GOVERNANCE_MATERIALIZATION.md \
  docs/superpowers/plans/2026-10-18-post-h120a-pre-h100-governance-materialization.md \
  elixir/lib/symphony_elixir/governance/check.ex \
  elixir/test/symphony_elixir/governance_check_test.exs
```

Verify there are no additional files.

Create signed commit(s) according to repository convention.

Then require:

```bash
git status --short
```

to be empty.

Now run the positive freeze against the committed candidate:

```bash
cd elixir
mix governance.check --freeze --candidate-phase H-100
```

Expected:

```text
PASS
```

This command must **not** be run as evidence while the candidate has uncommitted edits, because freeze mode intentionally validates candidate worktree integrity.

No `--materialize-decision` bypass is needed or permitted.

---

# 25. Task 5 — Full verification matrix

Run on the exact committed candidate:

```bash
cd elixir

mix test test/symphony_elixir/governance_check_test.exs

mix governance.check

mix governance.check --freeze --candidate-phase H-100

mix format --check-formatted

cd ..

git diff --check

make -C elixir ci

make -C elixir all
```

All must pass.

Then confirm:

```bash
git status --short
```

is empty.

Also mechanically inspect:

```bash
git diff --name-only origin/main...HEAD
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
```

Required changed-path set is exactly the authorized eight-file envelope unless a previously identified and justified repository-convention necessity exists.

Explicitly verify the candidate has **not** modified:

```text
V4_1_MASTER_ROADMAP.md
H-120A_GOVERNANCE_PRE_GATE.md
POST-H090_PRE-H120A_GOVERNANCE_MATERIALIZATION.md
Orchestrator/runtime domains
SourceControl runtime
Plane runtime
CompletionProof
CandidateRef
WorkflowLifecycle
Authority/Suspension domains
workspace ownership
Codex isolation
```

---

# 26. Final candidate authority checks

Before opening the PR, re-resolve:

```text
origin/main SHA/tree
candidate HEAD/tree
Master Roadmap blob at candidate HEAD
PR #50 merge identity
post-merge run 39135965103
```

If `origin/main` moved from:

```text
a58fee3a18eb2822f63d2ed3e44655d900f914e0
```

STOP.

Do not silently rebase this materialization onto a newer base.

A fresh planner/governance decision is required if the accepted base becomes ambiguous.

---

# 27. PR contract

Open exactly one bounded PR.

PR description must identify:

```text
accepted base SHA/tree
candidate HEAD/tree
Master decision reference/timestamp
H-120A PR/reviewed HEAD/merge SHA/tree
post-merge run/attempt/result
exact changed-file list
H-120A acceptance being materialized
H-100 authorization being materialized
H-100 acceptance NOT granted
H-110 NOT authorized
H-120B NOT authorized
production rollout NOT authorized
automated merge NOT authorized
merge authority HUMAN_ONLY
runtime production change = NO
Master Roadmap change = NO
H-100 live proof executed = NO
```

State that the PR is awaiting independent review/human governance handling.

Never merge it.

Do not enable auto-merge.

---

# 28. Implementation execution contract

The implementation agent must:

```text
use a fresh isolated worktree
fetch origin before editing
verify exact accepted base
require a clean implementation worktree
stop if origin/main moved
materialize this exact approved plan
keep the diff within the bounded file envelope
execute one task at a time
use test-first snapshot changes
run focused governance tests after each relevant task
retain every existing generic negative control
add the required new negative controls
keep schema version 1
change checker constants rather than bypass logic
leave Master Roadmap byte-identical
leave accepted H-120A artifact unchanged
leave runtime production code unchanged
not execute H-100
not provision Plane resources
not create disposable GitHub proof resources
not mutate Plane lifecycle state
not perform a merge
not authorize H-110
not authorize H-120B
not authorize production rollout
not add automated merge
sign commits
review the exact full diff
run the full verification matrix
open one bounded PR
never merge
```

---

# 29. Planner STOP conditions carried into implementation

Stop for any of:

```text
protected main moved unexpectedly

PR #50 reviewed-head / merge identity cannot be reproduced

post-merge run 39135965103 no longer resolves as
attempt 1 completed-success on the exact accepted merge

Master Roadmap blob differs from
4b0528bdc0647d889b42ebc478081d5b873898fe

supplied Master decision conflicts with normative Master Roadmap

H-120A acceptance cannot be represented in schema v1

H-100 cannot be isolated as the sole active authorization

Master Roadmap modification becomes necessary

runtime production code modification becomes necessary

accepted H-120A contract modification becomes necessary

H-I19 through H-I24 would weaken

H-110 would become authorized

H-120B would become authorized

production rollout would become authorized

automated merge would become authorized

deterministic negative controls cannot be retained/designed

candidate requires a new authority/schema architecture rather than
a snapshot materialization
```

Planner-local worktree absence is not a stop condition.

---

# 30. Planning conclusion

The current repository already contains the necessary schema and freeze machinery.

This materialization requires:

```text
one new governance decision/evidence record
one new retained plan
one schema-v1 projection snapshot update
one checker snapshot-constant update
one governance regression update
three synchronized human/status surface updates
```

It does **not** require:

```text
schema v2
new phase fields
H-100 bypass logic
runtime code
provider calls
SCM runtime calls
live proof
resource provisioning
Master Roadmap changes
H-120A contract changes
H-110 authority
H-120B authority
rollout authority
automated merge authority
```

The accepted-baseline field should move to the H-120A merge because its existing checker semantics make it the current Master-decision baseline. Older H-090 provenance remains intact in historical records.

No substantive planner STOP condition was found.
