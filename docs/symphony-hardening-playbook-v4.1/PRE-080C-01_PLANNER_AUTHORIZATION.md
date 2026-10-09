# PRE-080C-01 — Planner output (archival copy)

> **Provenance:** Verbatim archival copy of the Planner `PLAN_VERDICT=READY FOR IMPLEMENTATION` output that was supplied to the PRE-080C-01 implementation agent in the authorized implementation handoff (before coding on accepted base `01298f55422f689be52657e85ae7f84379c2f8ab`). This file is **not** a newly authored plan and must not be edited for scope changes; supersede with a new Planner artifact if scope changes.
>
> **Review note:** Independent reviewers should corroborate this copy against the original handoff record. On conflict, the governing PRE-080C programme contract and accepted-base roadmap authority win.

## Preflight result

Protected `main` has **not moved** from the authorized baseline:

```text
CURRENT_MAIN_SHA
01298f55422f689be52657e85ae7f84379c2f8ab

CURRENT_MAIN_TREE
1b1a78af2ba1e0157ff046eaf818861f0b069096
```

`main` remains protected. The required checks remain `make-all` and `validate-pr-description`, both under GitHub Actions app ID `15368`. The Unified Roadmap, Master Roadmap, and Skills Adoption/Routing Matrix all remain present at the frozen baseline.

The planning brief explicitly authorizes PRE-080C-01 planning while leaving H-080C unauthorized. Pasted text No authority ambiguity exists, so the STOP condition does not fire.

---

# FROZEN_OBJECTIVE

Determine whether normal, unseeded Symphony execution actually **creates, observes, binds, persists where necessary, and revalidates** the trusted evidence required by `LifecycleAssessment` for Planner, Builder, Fixer, Reviewer, and mechanical-check progression. Pasted text

The investigation confirms that the validators largely already exist. The defect is on the **producer/acquisition side**.

# ACCEPTED_BASE_SHA

```text
01298f55422f689be52657e85ae7f84379c2f8ab
```

# ACCEPTED_BASE_TREE

```text
1b1a78af2ba1e0157ff046eaf818861f0b069096
```

# CHARACTERIZATION_CLASSIFICATION

```text
DEFECT_PROVEN
```

This is not an architectural suspicion. There is enough evidence in the current repository to classify it as a real production defect.

The decisive findings are:

1. `WorkflowLifecycle` correctly demands distinct evidence families. Planner needs `plan_attested` plus `planning_requirements_verified`; Builder needs `implementation_attested`, `implementation_checks_verified`, and `candidate_state_verified`; Fixer has the analogous correction guards; Reviewer requires semantic reviewer evidence plus, for acceptance, `review_acceptance_verified`.

2. `Plane.AgentTool` exposes only the semantic target state to the runtime. That is good: the runtime cannot submit arbitrary guard maps. But when it builds `SemanticTransitionIntent`, it merely copies whatever `guard_evidence` is already present in trusted host context. It does **not acquire the missing role evidence**.

3. Ordinary `AgentRunner` execution does not create these guards on turn completion. Runtime output is not automatically converted to trusted lifecycle evidence, which is also correct from a trust perspective.

4. Existing successful transition tests manually construct the missing semantic and mechanical guards and inject them into host context. The corresponding unseeded path fails with `required_guard_missing`. That is precisely the test-only shortcut PRE-080C-01 warned against.

5. Source control is only partially affected. Candidate capture already produces the exact `candidate_state_verified` evidence. Reviewer acceptance already revalidates the candidate and required GitHub checks. But Builder/Fixer candidate capture does **not** currently convert successful required-check verification into the required `implementation_checks_verified` / `correction_checks_verified` lifecycle guard.

So the correct conclusion is **not** “replace the evidence model.” The current validators and trust model are substantially correct. The missing piece is the **normal production acquisition path**.

The Master Roadmap explicitly distinguishes machine facts from semantic attestations: CI/candidate/dependency facts are `MechanicalGuard`s, while bounded Planner/Reviewer judgments are `SemanticAttestation`s. Agent claims such as “tests passed” are not machine evidence.

---

# DOMAIN_RESOURCE_MAP

| Concept | Canonical owner | Source of truth / persistence | Producer → consumer | Trust boundary |
|---|---|---|---|---|
| WorkItem / work-control identity | `WorkControl.WorkItem` | Ephemeral projection reconstructed from trusted provider/local context | Orchestrator/work-control → routing, tools, coordinator | Host |
| Workflow lifecycle | `WorkControl.WorkflowLifecycle` | Static canonical law | Repository code → `LifecycleAssessment`, routing, coordinator | Authority Kernel |
| RuntimeAttempt | `AgentRuntime.RuntimeAttempt` | Current Orchestrator running state; intentionally not persisted as the runtime object | Orchestrator → runtime/tool/coordinator | Host; exact attempt identity |
| Attempt lineage / generation | `AgentRuntime.AttemptLedger` | Durable attempt ledger | Host retry/rearm policy → RuntimeAttempt allocation | Durable host authority |
| Responsibility | `AgentRuntime.Route` + `WorkflowLifecycle` | Derived from canonical lifecycle/route | Router → runtime/tool/coordinator | Host |
| AuthorityDisposition | `WorkControl.AuthorityDisposition` | Ephemeral projection | LifecycleAssessment → Orchestrator/dispatch | Authority Kernel |
| LifecycleAssessment | `WorkControl.LifecycleAssessment` | Recomputed from observation + prior validated state + evidence | Work-control/coordinator → authority decision | Authority Kernel |
| Guard taxonomy / trusted evidence validation | `WorkControl.GuardClass` | Typed/structured evidence values | Host evidence producers → LifecycleAssessment | Host provenance + exact binding |
| CompletionProof | `WorkControl.CompletionProof` | Typed, signed proof carried through merge closure | SourceControl → LifecycleAssessment | SCM + host signatures |
| CandidateRef | `SourceControl.CandidateRef` | Immutable five-field candidate identity | GitHub SourceControl → lifecycle/review/merge | GitHub |
| Candidate evidence | `SourceControl` | Reacquired/revalidated; CandidateRef-bound | SourceControl → LifecycleAssessment | GitHub + repository probe |
| Review mechanical evidence | `SourceControl` | Revalidatable against CandidateRef/check policy | SourceControl → LifecycleAssessment / CompletionProof | GitHub |
| CI/mechanical evidence | GitHub SourceControl + `SourceControl` | GitHub is factual source; lifecycle guard is host projection | GitHub checks → SourceControl → lifecycle | GitHub |
| Semantic transition intent | `WorkControl.SemanticTransitionIntent` | Transient request bound to exact runtime authority | Plane semantic tool → coordinator | Runtime request crosses host authority boundary |
| Transition authorization | `TransitionCoordinator` | Durable `TransitionAttempt` where required | Semantic intent + fresh facts → provider mutation | Authority Kernel |
| Provider observation | `WorkControl.ProviderObservation` | Immutable observation; fresh Plane observations may carry host read attestation | Plane → LifecycleAssessment | Provider observation, not authority |
| TransitionAttempt | `WorkControl.TransitionAttempt` + ledger | Durable provider-mutation safety record | Coordinator → recovery/reconciliation | Host durable fence |
| Runtime output | `AgentRunner` / runtime adapter | Ephemeral runtime result | Runtime → host | **Not trusted evidence by itself** |
| Recovery state | `WorkControl.RecoveryLedger` | DETS checkpoint, validated lifecycle state, bounded durable evidence/suspension context | Work-control → startup reconciliation | Host durable recovery |

`RuntimeAttempt` is explicitly host-owned and bound to `runtime_attempt_id`, WorkItem, lineage generation, responsibility, and runtime profile.  `RecoveryLedger` explicitly does not become a second runtime-authority store.

This satisfies the requirement to locate existing owners before considering changes. Pasted text

---

# EVIDENCE_FAMILY_MATRIX

| Evidence family | Current production producer | Exact binding / provenance | Durability, stale and revalidation semantics | Agent fabricable? | Ordinary production path today | Manual/test seed currently needed? |
|---|---|---|---|---|---|---|
| `plan_attested` | **None** | Validator expects WorkItem + RuntimeAttempt + lineage + planning responsibility + timestamp | Must die with attempt/lineage mismatch | Runtime cannot inject typed evidence, but no host producer exists | **NO** | **YES** |
| `planning_requirements_verified` | **None** | Should represent current machine-verifiable work-control prerequisites | Must be reacquired from current host facts | Must not come from planner prose | **NO** | **YES** |
| `implementation_attested` | **None** | WorkItem + current Builder attempt + lineage + implementation responsibility | Stale on attempt/lineage mismatch | No arbitrary evidence field exposed | **NO** | **YES** |
| `implementation_checks_verified` | GitHub facts exist, but no lifecycle producer at Builder handoff | Must be derived only after required checks verify against the exact current CandidateRef | Candidate/check changes invalidate the factual basis | Agent statement “tests passed” is insufficient | **NO** | **YES** |
| `candidate_state_verified` | `SourceControl.enrich_candidate_capture/…` | Exact CandidateRef + candidate tree + policy fingerprint | Reacquired/revalidated; candidate movement invalidates downstream acceptance | **NO** | **YES** | NO |
| `correction_attested` | **None** | WorkItem + current Fixer attempt + lineage + correction responsibility | Stale across replacement attempt/lineage | No arbitrary evidence injection | **NO** | **YES** |
| `correction_checks_verified` | GitHub facts exist, but no lifecycle producer at Fixer handoff | Same exact candidate/check boundary as Builder | Must fail closed if required checks are missing/failing/stale | Agent cannot self-certify CI | **NO** | **YES** |
| `review_changes_requested` | **None** | WorkItem/current Reviewer attempt/lineage/review responsibility | Attempt-bound semantic fact | Target-state request can be host-observed, but evidence is not created today | **NO** | YES in direct tests |
| `review_accepted` | **None** | WorkItem/current Reviewer attempt/lineage/review responsibility; downstream CandidateRef binding through acceptance proof | Candidate movement requires review re-establishment | Reviewer cannot mint arbitrary host evidence | **NO** | **YES** |
| `review_acceptance_verified` | `SourceControl` | Exact CandidateRef/tree/policy + fresh candidate unchanged + required checks | Reconciled and marked stale if candidate/check facts cease to hold | **NO** | **YES**, once semantic reviewer evidence exists | NO |
| Provider observation | Plane adapter/host read boundary | Workspace/project/WorkItem/state/read observation; signed where required | Freshness bounded; newer observation supersedes prior observation | Provider can report facts but not grant forward authority | **YES** | NO |
| CompletionProof | `SourceControl` | WorkItem + CandidateRef + tree + review evidence + merge verification + signatures | Explicit staged revalidation | **NO** | **YES**, downstream of review | NO |
| Merge/closure evidence | `SourceControl` | Exact CandidateRef and verified merge/result | Revalidated through proof stages | **NO** | **YES** | NO |

The evidence classes must remain separate: runtime output, provider observation, host observation, trusted evidence, machine result, CompletionProof, candidate evidence, and review evidence are not interchangeable. Pasted text

### Critical interpretation

A runtime's semantic transition request may legitimately be the **event being attested to**, but the trusted evidence must be constructed by the host from:

```text
current trusted route
+ current WorkItem
+ current RuntimeAttempt
+ current lineage_generation
+ route responsibility
+ target transition
+ host timestamp
```

The runtime must **not** be allowed to provide the attestation identity fields itself.

Likewise:

```text
runtime says “tests passed”
≠ implementation_checks_verified
```

The latter may only be emitted after Symphony independently obtains the required GitHub check facts for the exact candidate.

---

# STATE_MACHINES

## 1. WorkflowLifecycle — preserve unchanged

Current canonical progression includes:

```text
Backlog
→ Planning
→ Ready
→ In Progress
→ In Review
→ Ready to Merge
→ Merging
→ Done
```

plus `Changes Requested`, `Blocked`, and `Canceled`.

Relevant guarded transitions remain exactly as currently modelled:

```text
Planning → Ready
  plan_attested
  planning_requirements_verified

In Progress → In Review
  implementation_attested
  implementation_checks_verified
  candidate_state_verified

In Review → Changes Requested
  review_changes_requested

Changes Requested → In Review
  correction_attested
  correction_checks_verified
  candidate_state_verified

In Review → Ready to Merge
  review_accepted
  review_acceptance_verified

Ready to Merge → Merging
  merge_approved
  merge_guard_verified

Merging → Done
  completion_merge_verified
  CompletionProof required
```

No guard is to be removed or weakened.

## 2. RuntimeAttempt — preserve unchanged

The code's actual lifecycle is richer than the simplified roadmap:

```text
Queued
→ Starting
→ Running
   ├─ Completed
   ├─ RetryQueued
   ├─ Blocked
   ├─ Failed
   ├─ Cancelled
   └─ Stopping
      ├─ ContainmentUnconfirmed
      └─ ContainmentProvenDead
           ├─ Running
           └─ terminal outcome
```

A replacement RuntimeAttempt must never inherit the previous attempt's semantic evidence. The roadmap says `Running → Completed` requires responsibility-specific completion criteria and emits a bounded semantic result to the trusted Symphony boundary.

PRE-080C-01 supplies the currently missing acquisition side of that doctrine without introducing Programme-B Execution.

## 3. ProviderObservation — preserve unchanged

Conceptually:

```text
Absent
→ Observed
→ SupersededByNewObservation
```

Observation can reduce authority but cannot grant a forward transition.

## 4. TransitionAttempt — preserve unchanged

```text
Requested
→ IntentAuthorized
→ FreshContextLoaded
→ Prepared
→ MutationSubmitted
→ Verifying
   ├─ Verified
   ├─ Rejected
   ├─ Conflict
   ├─ ProviderFailed
   └─ Indeterminate
```

`Prepared` remains the final point before provider side effects and the durable submission fence remains mandatory.

## 5. CompletionProof — preserve unchanged

```text
merge_authorized
→ merge_verified
→ completed
```

with guard identities:

```text
merge_authorized → merge_guard_verified
merge_verified   → completion_merge_verified
completed        → completion_proof_verified
```



## 6. Candidate-bound evidence

Conceptual lifecycle only; **do not implement another state object**:

```text
Unacquired
→ CandidateCaptured
→ CandidateVerified
→ ReviewVerified
→ MergeVerified

CandidateCaptured/Verified/ReviewVerified
  └─ candidate movement → Stale
                           → reacquisition / re-review required
```

Candidate identity is already properly defined by immutable `CandidateRef`.

## 7. PRE-080C-01 acquisition chain

This is also conceptual, not a new resource:

```text
runtime makes authorized semantic lifecycle request
→ host observes that request
→ host binds semantic attestation to exact RuntimeAttempt authority
→ host independently acquires required mechanical facts
→ LifecycleAssessment revalidates all evidence
→ TransitionCoordinator may authorize provider mutation
→ fresh provider observation verifies resulting state
```

Failure anywhere produces rejection/validation-required/suspension according to existing law.

A stale attempt, wrong responsibility, wrong WorkItem, wrong lineage, stale candidate, failed CI, incomplete dependencies, unavailable external observation, or candidate movement must therefore fail closed.

---

# ARCHITECTURE_DECISION

The smallest correct repair uses **three existing ownership boundaries**. No EvidenceBundle, new ledger, second authority kernel, or new lifecycle type is justified.

### A. `Plane.AgentTool` owns acquisition of role semantic attestations

When the runtime invokes the existing authorized semantic transition tool, the runtime continues to supply only:

```text
targetState
```

After all existing trusted-route, current RuntimeAttempt, WorkItem, responsibility, source-state, and authority validation succeeds, the **host** constructs the appropriate `GuardClass.semantic_attestation/2`.

Exact mapping:

```text
Planning → Ready
  plan_attested

In Progress → In Review
  implementation_attested

Changes Requested → In Review
  correction_attested

In Review → Ready to Merge
  review_accepted

In Review → Changes Requested
  review_changes_requested
```

The host supplies:

```text
responsibility
runtime_attempt_id
lineage_generation
subject = exact WorkItem
timestamp
```

The runtime must not be given parameters for any of those fields.

This does not treat arbitrary agent prose as trusted evidence. It records the fact that the **currently authorized bounded responsibility made the semantic judgment represented by its semantic transition request**.

### B. `TransitionCoordinator` owns Planner's machine guard

`planning_requirements_verified` must not be created merely because the Planner claims its plan is done.

During the existing fresh-context phase, the coordinator should emit this guard only when the machine-verifiable planning handoff prerequisites it already owns are current and acceptable, including the applicable:

```text
valid provider/project contract
current WorkItem/source state
current authorized RuntimeAttempt identity
complete/current dependency epoch
dependency decision permitting the handoff
absence of a blocking suspension/conflict
```

Do **not** parse Planner prose and call that mechanical verification.

This keeps `SemanticAttestation` responsible for the Planner's bounded judgment and `MechanicalGuard` responsible for machine facts.

### C. `SourceControl` owns Builder/Fixer mechanical-check acquisition

For:

```text
In Progress → In Review
Changes Requested → In Review
```

extend the existing candidate capture path so the **same exact CandidateRef** is also sent through the existing required-check verifier.

Only after:

```text
CandidateRef captured
AND candidate tree validated
AND configured required GitHub checks verified
```

may SourceControl append:

```text
implementation_checks_verified
```

or:

```text
correction_checks_verified
```

alongside the already-produced:

```text
candidate_state_verified
```

There must be no second CI/check truth and no agent-provided “tests passed” shortcut.

### D. Reviewer mechanical evidence stays where it is

Do not redesign `review_acceptance_verified`.

Current SourceControl behavior already revalidates:

```text
exact CandidateRef
candidate unchanged
required GitHub checks
```

before review acceptance evidence is produced.

Only the missing semantic `review_accepted` / `review_changes_requested` acquisition needs repair.

### E. Existing persistence remains sufficient

Do not introduce another evidence database.

Use:

- `TransitionAttempt` for durable transition/mutation state;
- existing source-control proof types for candidate/merge evidence;
- `RecoveryLedger` only within its current validated-checkpoint role;
- AttemptLedger for retry/lineage authority.

Attempt-bound semantic attestations must not be resurrected as authority for a replacement RuntimeAttempt. If restart loses a transient role attestation before successful transition closure, it is safer to require reacquisition under the new current attempt.

This directly respects the brief's “do not create a duplicate authority store” requirement. Pasted text

---

# EXACT_SCOPE

Expected production changes are limited to:

```text
elixir/lib/symphony_elixir/plane/agent_tool.ex
elixir/lib/symphony_elixir/transition_coordinator.ex
elixir/lib/symphony_elixir/source_control.ex
```

Expected characterization/regression work:

```text
elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs
elixir/test/symphony_elixir/plane_agent_tool_test.exs
elixir/test/symphony_elixir/transition_coordinator_test.exs
elixir/test/symphony_elixir/source_control_test.exs
```

Existing authority-binding tests may be adjusted **only where their manually seeded evidence would otherwise obscure the newly established production route**:

```text
elixir/test/symphony_elixir/runtime_transition_authority_binding_test.exs
```

Do not broadly rewrite H-050A tests merely because they use explicit fixtures; those tests still legitimately isolate route-authority behavior.

Evidence documentation:

```text
docs/symphony-hardening-playbook-v4.1/PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md
```

No change to `GuardClass`, `LifecycleAssessment`, `WorkflowLifecycle`, `RuntimeAttempt`, `CandidateRef`, or `CompletionProof` is presently justified. If implementation discovers one is actually necessary, the coding agent must stop and report the exact invariant it cannot satisfy using the frozen architecture.

---

# EXPLICIT_NON_SCOPE

The implementation must not include:

- H-080C, PRE-080C-02, or PRE-080C-03;
- Programme-B `EvidenceBundle`, first-class `Execution`, or first-class Candidate lifecycle;
- a new evidence ledger/database;
- Redis or distributed authority;
- a new scheduler or authority kernel;
- another runtime adapter;
- dynamic model routing or Context Broker work;
- persistence of RuntimeAttempt as a new V2 resource;
- changes to canonical lifecycle guard requirements merely to make tests pass;
- making Plane a candidate/CI authority;
- using agent output text as mechanical evidence;
- adding guard/provenance parameters to the runtime-facing transition tool;
- general H-080C implementation;
- status-ledger acceptance of PRE-080C-01;
- authorization of subsequent roadmap phases.

This is consistent with the frozen issue boundary. Pasted text

---

# IMPLEMENTATION_SEQUENCE

### Phase 1 — Preserve the characterization

Create the focused production-acquisition regression **before remediation**.

It must exercise an ordinary runtime-authority context with **no manually seeded completion guards** and demonstrate the current `required_guard_missing` failure.

The characterization must cover at least:

```text
Planner → Ready
Builder → In Review
Fixer → In Review
Reviewer → Ready to Merge
Reviewer → Changes Requested
```

For Builder/Fixer, distinguish the existing candidate producer from the missing check-evidence producer.

### Phase 2 — Repair semantic acquisition

Change only the existing semantic tool boundary.

The host constructs the semantic attestation after exact route/runtime authority validation and before creating the `SemanticTransitionIntent`.

Do not parse text output.

Do not accept runtime evidence parameters.

### Phase 3 — Repair Planner machine evidence

At the coordinator's fresh-context authority boundary, produce `planning_requirements_verified` only from current machine facts.

If dependencies, provider contract, current WorkItem identity, authority, or fresh context are unavailable, the guard remains absent and progression fails closed.

### Phase 4 — Repair Builder/Fixer check acquisition

Extend SourceControl candidate capture to verify configured required GitHub checks on the exact captured CandidateRef and create the role-specific mechanical guard.

Avoid performing the same check query twice in one enrichment flow.

### Phase 5 — Prove hostile/stale cases

Prove the repaired path rejects:

```text
stale RuntimeAttempt
wrong lineage
wrong responsibility
foreign WorkItem
failed/pending CI
candidate movement
runtime-provided forged guard fields
missing/incomplete dependency authority
```

### Phase 6 — Prove recovery behaviour

Verify:

- no new durable evidence store exists;
- rejected evidence does not create forward authority;
- a replacement RuntimeAttempt cannot reuse stale semantic evidence;
- TransitionAttempt fencing still prevents duplicate provider mutation;
- candidate movement still requires revalidation/re-review.

### Phase 7 — Update PRE-080C-01 evidence document

Record:

```text
frozen base
pre-fix reproducer
actual defect
exact producer ownership
post-fix production acquisition path
negative proofs
focused command results
final command results
candidate identity once available
```

Do not mark PRE-080C-01 accepted; that belongs to independent review/governance.

---

# EXACT_EXPECTED_FILES

| Path | Expected purpose |
|---|---|
| `elixir/lib/symphony_elixir/plane/agent_tool.ex` | Host-create role semantic attestations from already-authorized transition requests |
| `elixir/lib/symphony_elixir/transition_coordinator.ex` | Acquire Planner mechanical handoff evidence from fresh machine context |
| `elixir/lib/symphony_elixir/source_control.ex` | Convert exact candidate + required-check verification into Builder/Fixer mechanical guards |
| `elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs` | Primary unseeded characterization/regression |
| `elixir/test/symphony_elixir/plane_agent_tool_test.exs` | Semantic acquisition and anti-forgery boundary tests |
| `elixir/test/symphony_elixir/transition_coordinator_test.exs` | Planner fresh-context mechanical evidence tests |
| `elixir/test/symphony_elixir/source_control_test.exs` | Candidate/check acquisition and failed-check/candidate-movement tests |
| `elixir/test/symphony_elixir/runtime_transition_authority_binding_test.exs` | Only if narrowly needed for production evidence wiring regressions |
| `docs/symphony-hardening-playbook-v4.1/PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md` | Frozen characterization and implementation evidence |

Any additional production file is a scope warning and requires justification before editing.

---

# FOCUSED_TEST_PLAN

Development should remain narrow.

Start with:

```bash
cd elixir

mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs
```

Then the ownership boundaries:

```bash
mix test \
  test/symphony_elixir/plane_agent_tool_test.exs \
  test/symphony_elixir/transition_coordinator_test.exs \
  test/symphony_elixir/source_control_test.exs
```

Then authority/identity regressions:

```bash
mix test \
  test/symphony_elixir/runtime_transition_authority_binding_test.exs \
  test/symphony_elixir/runtime_attempt_production_path_test.exs
```

The principal regression must prove ordinary acquisition **without** a helper that preconstructs:

```text
plan_attested
implementation_attested
correction_attested
review_accepted
review_changes_requested
planning_requirements_verified
implementation_checks_verified
correction_checks_verified
```

Required negative proofs:

```text
current RuntimeAttempt       succeeds
stale RuntimeAttempt         fails

current lineage              succeeds
wrong lineage                fails

correct responsibility       succeeds
wrong responsibility         fails

correct WorkItem             succeeds
foreign WorkItem             fails

current candidate + green CI succeeds
moved candidate              fails/reacquires
failed CI                    fails
pending/missing CI           fails

host-bound semantic request  can produce semantic attestation
runtime-supplied evidence    cannot enter the trusted boundary
```

No sleeps should be added merely to synchronize the characterization; use process messages, synchronous calls, or stable state/effects in line with repository testing doctrine.

---

# FINAL_CHECK_PLAN

During development, do **not** repeatedly invoke the complete suite.

Once the candidate is stable, run:

```bash
cd elixir
mix specs.check
make all
git diff --check
```

`make all` is the repository's full local gate and includes build, format checking, lint, partitioned coverage, H-070A scaling coverage, Dialyzer, and the Codex isolation proof.

After the PR exists, the implementation agent must report but **must not self-approve or merge**:

```text
base SHA/tree
candidate HEAD/tree
exact PR diff
synthetic merge identity if applicable
make-all result
validate-pr-description result
```

Independent review must then re-resolve the exact PR diff, CI and governing authority before any merge recommendation.

---

# RISKS_AND_FAILURE_MODES

| Risk | Owner | Required proof |
|---|---|---|
| Runtime semantic request mistaken for machine truth | `Plane.AgentTool` / `GuardClass` | Semantic evidence remains `SemanticAttestation`; CI/dependency facts remain independent MechanicalGuards |
| Agent fabricates evidence fields | `Plane.AgentTool` | Runtime schema stays target-state-only; unknown evidence/provenance args rejected |
| Stale RuntimeAttempt | AgentTool + coordinator | Exact current attempt ID required |
| Wrong lineage | AgentTool + GuardClass | Exact current `lineage_generation` required |
| Wrong responsibility | Route/Authority + GuardClass | Host route responsibility must equal attestation responsibility |
| Wrong WorkItem | AgentTool + GuardClass | Host supplies exact `{:work_item, id}` subject |
| Planner mechanical guard becomes self-assertion | TransitionCoordinator | Emit only from machine-verifiable fresh context; never from plan prose |
| CI claim fabricated by Builder/Fixer | SourceControl | Only successful GitHub required-check verification emits check guard |
| Candidate moves between build/review | SourceControl | CandidateRef revalidation; stale candidate blocks/requires re-review |
| Runtime finishes before evidence acquisition | AgentTool/coordinator | Semantic lifecycle request itself is acquisition trigger; plain process exit does not mean lifecycle completion |
| Duplicate semantic request | TransitionCoordinator | Existing transition attempt/authority/provider verification prevents duplicate forward mutation |
| Crash before provider mutation | TransitionAttempt ledger | No provider side effect absent prepared/fenced mutation |
| Crash after mutation may have committed | TransitionAttempt | Preserve existing `Indeterminate`/reconciliation semantics; no blind retry |
| Restart with old semantic evidence | Work-control recovery | Attempt-bound semantic evidence cannot grant authority to a replacement RuntimeAttempt |
| Late provider event | ProviderObservation/LifecycleAssessment | Event remains observation only; cannot mint guards |
| Candidate/check read multiplication | SourceControl | One required-check verification per candidate capture; no polling/sleep loop |
| New DETS/process leak | N/A | No new ledger/process is introduced |
| Credential leakage | SourceControl | Existing host credential boundary only; evidence contains no token |
| Test-only seam becomes production authority | All three owners | Main regression enters through production functions and carries no manual evidence seed |
| H-080C scope leakage | Planner/reviewer | STOP if implementation introduces later-phase orchestration or architecture |

These risks cover the required crash, race, stale identity, wrong authority, duplication, persistence and performance cases from the planning brief. Pasted text

---

# SCAFFOLDING_PROMPT

The implementation agent should receive the following frozen prompt.

You are the implementation agent for exactly one Symphony V4.1 issue:

# PRE-080C-01 — Production Evidence Acquisition

Implementation is authorized under this frozen plan. You may implement, test, commit, push and open/update the review PR. You may NOT merge the PR, mark the issue accepted, authorize H-080C, or broaden the architecture.

## Frozen repository authority

Repository:

`JCSchoeman96/symphony`

Accepted base:

`01298f55422f689be52657e85ae7f84379c2f8ab`

Accepted tree:

`1b1a78af2ba1e0157ff046eaf818861f0b069096`

Before editing, verify protected `main` and report any movement. If movement materially changes the files or assumptions below, STOP instead of silently rebasing the architecture.

Canonical authority remains:

`docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md`

`docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`

`docs/SYMPHONY_SKILLS_ADOPTION_AND_ROUTING_MATRIX_v1.0.2.md`

H-080C remains NOT AUTHORIZED.

## Frozen characterization

`CHARACTERIZATION_CLASSIFICATION=DEFECT_PROVEN`

The current repository validates lifecycle evidence but ordinary unseeded execution does not create every required evidence family.

The current production gaps are:

- Planner semantic `plan_attested` has no ordinary host producer.
- Planner mechanical `planning_requirements_verified` has no ordinary host producer.
- Builder semantic `implementation_attested` has no ordinary host producer.
- Builder `implementation_checks_verified` is not produced at the Builder handoff even though GitHub is capable of supplying the underlying check truth.
- Fixer semantic `correction_attested` has no ordinary host producer.
- Fixer `correction_checks_verified` is not produced at the Fixer handoff.
- Reviewer semantic `review_accepted` and `review_changes_requested` have no ordinary host producer.
- Candidate capture, reviewer mechanical acceptance and CompletionProof already have legitimate SourceControl producers and must not be redesigned.

Existing successful tests manually seed guards that production does not create. Preserve a focused unseeded characterization before remediation.

## Frozen architecture

Do not introduce a new Evidence resource, evidence ledger, scheduler, authority kernel, runtime adapter or lifecycle state.

Use the existing owners.

### 1. Semantic evidence owner — `Plane.AgentTool`

File:

`elixir/lib/symphony_elixir/plane/agent_tool.ex`

Keep the runtime-facing transition schema restricted to its existing semantic target-state input.

Do not let the runtime supply:

- guard evidence;
- RuntimeAttempt ID;
- lineage generation;
- WorkItem subject;
- evidence timestamp;
- provenance fields.

After the existing trusted-route, current RuntimeAttempt, WorkItem, source-state, responsibility and authority checks succeed, have the host construct the role semantic attestation using existing `SymphonyElixir.WorkControl.GuardClass.semantic_attestation/2`.

Exact mapping:

- Planning → Ready = `plan_attested`
- In Progress → In Review = `implementation_attested`
- Changes Requested → In Review = `correction_attested`
- In Review → Ready to Merge = `review_accepted`
- In Review → Changes Requested = `review_changes_requested`

Bind every semantic attestation to the exact current:

- responsibility;
- RuntimeAttempt ID;
- lineage generation;
- WorkItem subject;
- host timestamp.

The semantic transition request is the bounded role judgment being observed. It is NOT mechanical proof that tests passed or that dependencies/candidate facts are correct.

### 2. Planner mechanical evidence owner — `TransitionCoordinator`

File:

`elixir/lib/symphony_elixir/transition_coordinator.ex`

Acquire `planning_requirements_verified` only on the Planning → Ready path and only from current machine-verifiable host facts during the existing fresh-context phase.

Use the current architecture and existing APIs. Do not parse Planner prose.

At minimum, do not issue the guard unless the existing fresh-context path establishes the applicable current provider/project contract, exact WorkItem/source, current authorized runtime identity, complete/current dependency information and an allowed dependency/policy decision.

Failure or absence of any required fact leaves the guard absent and the lifecycle advancement fail-closed.

Do not create a new persistent store for this evidence.

### 3. Builder/Fixer machine evidence owner — `SourceControl`

File:

`elixir/lib/symphony_elixir/source_control.ex`

Extend the existing candidate-capture path for:

- In Progress → In Review
- Changes Requested → In Review

Continue using the existing repository probe and exact CandidateRef capture.

On that same exact candidate, call the existing GitHub required-check verifier.

Only after candidate/tree validation and successful required-check verification append:

- `implementation_checks_verified` for Builder; or
- `correction_checks_verified` for Fixer;

alongside the existing `candidate_state_verified`.

Do not trust runtime statements that checks passed.

Do not add a second Candidate truth.

Avoid duplicate check reads inside one enrichment flow.

### 4. Reviewer and CompletionProof

Do not redesign current `review_acceptance_verified`, CandidateRef, merge verification or CompletionProof logic.

The current SourceControl path already revalidates candidate/check facts for review acceptance and merge.

The only Reviewer repair in this issue is acquisition of the role's semantic attestation through the host boundary.

### 5. Persistence/restart

Use the existing:

- AttemptLedger;
- TransitionAttempt / TransitionAttemptLedger;
- RecoveryLedger;
- SourceControl proof types.

Do not persist RuntimeAttempt as a new durable resource.

Do not allow semantic evidence from a stale/replaced RuntimeAttempt to grant authority after restart.

No new DETS table is authorized.

## Expected production files

Production scope is expected to be exactly:

`elixir/lib/symphony_elixir/plane/agent_tool.ex`

`elixir/lib/symphony_elixir/transition_coordinator.ex`

`elixir/lib/symphony_elixir/source_control.ex`

If a fourth production file appears necessary, STOP and report why the existing owner cannot implement the required property before broadening scope.

In particular, do not weaken:

`work_control/guard_class.ex`

`work_control/lifecycle_assessment.ex`

`work_control/workflow_lifecycle.ex`

`work_control/completion_proof.ex`

`source_control/candidate_ref.ex`

## Expected tests

Add:

`elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs`

Update only as needed:

`elixir/test/symphony_elixir/plane_agent_tool_test.exs`

`elixir/test/symphony_elixir/transition_coordinator_test.exs`

`elixir/test/symphony_elixir/source_control_test.exs`

`elixir/test/symphony_elixir/runtime_transition_authority_binding_test.exs`

The primary regression must exercise the production acquisition route with no manually seeded completion guards.

Explicitly prove:

- Planner acquisition;
- Builder acquisition;
- Fixer acquisition;
- Reviewer accepted acquisition;
- Reviewer changes-requested acquisition;
- exact candidate/check acquisition;
- stale RuntimeAttempt rejection;
- stale lineage rejection;
- wrong responsibility rejection;
- wrong WorkItem rejection;
- failed/pending/missing required-check rejection;
- moved-candidate rejection/revalidation;
- runtime attempts to supply trusted evidence cannot succeed.

Do not add sleep/poll synchronization where process messages or synchronous effects can prove the result.

## Evidence document

Create:

`docs/symphony-hardening-playbook-v4.1/PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md`

Record the frozen baseline, original reproducer, exact defect, repair ownership, focused tests, adversarial tests and final checks.

Do not mark PRE-080C-01 accepted in the programme ledger.

## Development sequence

First make the unseeded characterization RED against the accepted baseline.

Then implement semantic host acquisition.

Then Planner mechanical acquisition.

Then Builder/Fixer check acquisition.

Then add stale/forgery/candidate-movement/restart regressions.

Keep each phase minimal.

## Focused commands

Start with:

`cd elixir && mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs`

Then:

`mix test test/symphony_elixir/plane_agent_tool_test.exs test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/source_control_test.exs`

Then:

`mix test test/symphony_elixir/runtime_transition_authority_binding_test.exs test/symphony_elixir/runtime_attempt_production_path_test.exs`

Do not repeatedly run `make all` while iterating.

When implementation is stable, run once:

`mix specs.check`

`make all`

`git diff --check`

## Permanent STOP conditions

STOP and report rather than improvising if:

- the accepted authority becomes ambiguous;
- a fourth production owner appears necessary;
- fulfilling the plan would require weakening an existing evidence validator;
- Planner mechanical evidence would need to be based on agent prose rather than machine facts;
- RuntimeAttempt must become a new durable resource;
- another mutable authority/evidence store appears necessary;
- raw Plane state would need to grant forward authority;
- the runtime would need permission to submit trusted evidence/provenance fields;
- candidate movement would cease to invalidate downstream review evidence;
- another roadmap issue is required;
- H-080C work would begin;
- Programme B/C/D/E/F concepts are required;
- secrets/live unsafe production mutation are required.

## Handoff

After focused and final checks pass, commit/push and open or update the review PR using the repository's normal PR template.

Report:

- base SHA/tree;
- candidate HEAD/tree;
- exact changed-file list;
- characterization evidence;
- focused check results;
- full final check results;
- PR identity;
- required GitHub check state.

Do not merge your own PR and do not represent PRE-080C-01 as accepted. Independent reviewer and Master Governance remain downstream authorities.

That prompt deliberately prevents the implementation agent from “solving” the problem by weakening the evidence contract.

---

# TOON_MICRO_PROMPTS

These are intentionally smaller than the scaffolding prompt so work can be executed and reviewed in bounded phases.

## Phase A — Characterization

### A1 — Freeze the ordinary-path reproducer

| Field | Content |
|---|---|
| Task | Add the PRE-080C-01 unseeded production-acquisition characterization. |
| Objective | Prove that ordinary role transition execution currently lacks trusted evidence producers rather than merely showing that validators exist. |
| Output | Create `elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs` covering Planner, Builder, Fixer and Reviewer handoffs without manually constructing the guards under test. Preserve the initial RED result and exact `required_guard_missing`/equivalent failure evidence for the issue document. |
| Note | Use production functions and real host identity binding. Do not insert `plan_attested`, `implementation_attested`, `correction_attested`, `review_accepted`, `review_changes_requested`, or their missing mechanical companions into test host context. Run only this focused test. STOP if the failure is not reproducible or if ordinary production already acquires the evidence. |

### A2 — Freeze the evidence-family baseline

| Field | Content |
|---|---|
| Task | Record the proven pre-remediation evidence acquisition matrix. |
| Objective | Keep the characterization distinct from the later fix and prevent future tests from disguising test-only seeding as production behavior. |
| Output | Create the initial sections of `docs/symphony-hardening-playbook-v4.1/PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md` with accepted base, reproducer, current producer/consumer/validator map, and `CHARACTERIZATION_CLASSIFICATION=DEFECT_PROVEN`. |
| Note | Record CandidateRef, reviewer mechanical evidence and CompletionProof as already working producers rather than calling the entire evidence system broken. Do not modify the status ledger or canonical roadmap. STOP if source evidence contradicts DEFECT_PROVEN. |

## Phase B — Semantic evidence acquisition

### B1 — Acquire role semantic attestations at the trusted tool boundary

| Field | Content |
|---|---|
| Task | Add host-owned semantic-attestation acquisition to `elixir/lib/symphony_elixir/plane/agent_tool.ex`. |
| Objective | Turn an already-authorized bounded role transition request into provenance-bound SemanticAttestation evidence without trusting arbitrary agent structures. |
| Output | Update `plane/agent_tool.ex` so Planning→Ready produces `plan_attested`, InProgress→InReview produces `implementation_attested`, ChangesRequested→InReview produces `correction_attested`, InReview→ReadyToMerge produces `review_accepted`, and InReview→ChangesRequested produces `review_changes_requested`; bind each using existing `GuardClass.semantic_attestation/2` to exact host WorkItem, RuntimeAttempt, lineage, responsibility and timestamp. Update `elixir/test/symphony_elixir/plane_agent_tool_test.exs`. |
| Note | Runtime input must remain semantic target-state only. Do not add evidence, provenance, runtime ID or lineage parameters. Do not treat the attestation as CI/dependency proof. Preserve all existing route/current-attempt/authority validation before issuance. STOP if the fix requires changing `GuardClass` validation semantics. |

## Phase C — Planner machine evidence

### C1 — Acquire planning machine evidence from fresh coordinator context

| Field | Content |
|---|---|
| Task | Produce `planning_requirements_verified` from the existing fresh TransitionCoordinator authority path. |
| Objective | Satisfy Planner's MechanicalGuard from machine-observed facts rather than Planner prose or a fabricated map. |
| Output | Update `elixir/lib/symphony_elixir/transition_coordinator.ex` and focused cases in `elixir/test/symphony_elixir/transition_coordinator_test.exs` so Planning→Ready receives `planning_requirements_verified` only when the existing current provider/project contract, WorkItem/source, RuntimeAttempt authority, dependency epoch/completeness and allowed policy decision are all acceptable. |
| Note | Keep the evidence ephemeral within the normal transition path and existing persistence boundaries. Do not parse runtime text or create a new plan/evidence database. Missing, incomplete or stale machine context must leave the guard absent and reject advancement. STOP if “planning requirements” can only be established by trusting unstructured agent output. |

## Phase D — Candidate/check acquisition

### D1 — Acquire Builder/Fixer required-check guards from SourceControl

| Field | Content |
|---|---|
| Task | Extend candidate capture in `elixir/lib/symphony_elixir/source_control.ex` to acquire the role-specific required-check MechanicalGuard. |
| Objective | Ensure Builder/Fixer lifecycle advancement depends on GitHub's exact candidate/check facts rather than agent claims or test seeding. |
| Output | For InProgress→InReview, verify configured required checks for the exact captured CandidateRef/tree and append `implementation_checks_verified` with `candidate_state_verified`; for ChangesRequested→InReview do the same for `correction_checks_verified`. Extend `elixir/test/symphony_elixir/source_control_test.exs` for green, failed, pending/missing and moved-candidate cases. |
| Note | Reuse the existing CandidateRef, repository probe and GitHub required-check verifier. Avoid duplicate check reads in the same enrichment. Do not change review-acceptance or CompletionProof semantics. Failed/unavailable verification must fail closed. STOP if this requires a second candidate truth or a weakened required-check policy. |

## Phase E — Adversarial identity and freshness proof

### E1 — Prove evidence cannot cross authority identities

| Field | Content |
|---|---|
| Task | Add stale/foreign evidence regressions across the repaired acquisition path. |
| Objective | Prove host acquisition does not accidentally turn role completion into reusable bearer authority. |
| Output | Extend `elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs` and, only where necessary, `elixir/test/symphony_elixir/runtime_transition_authority_binding_test.exs` with current-vs-stale RuntimeAttempt, current-vs-stale lineage, correct-vs-wrong responsibility, correct-vs-foreign WorkItem and runtime-forged evidence cases. |
| Note | Reuse current host identity validation and `GuardClass` binding rules. A replacement RuntimeAttempt must require newly acquired semantic evidence. Do not add a generic persistent evidence cache. STOP on any case where stale/foreign evidence can authorize a forward transition. |

### E2 — Prove candidate movement and reviewer acquisition remain safe

| Field | Content |
|---|---|
| Task | Exercise Reviewer acquisition together with existing candidate revalidation. |
| Objective | Ensure host-created `review_accepted` does not weaken exact-candidate review doctrine. |
| Output | Add focused tests showing unseeded InReview→ReadyToMerge succeeds only when host semantic review evidence and current SourceControl `review_acceptance_verified` both exist; candidate movement or failing checks blocks/stales acceptance. Also prove InReview→ChangesRequested requires only correctly bound `review_changes_requested` and performs no inappropriate candidate approval. |
| Note | Preserve existing `SourceControl.reconcile_stored_evidence/…`, CandidateRef equality and CompletionProof behavior. Do not make `review_accepted` itself a machine check. STOP if moved-candidate review can remain valid without fresh re-review. |

## Phase F — Recovery and final evidence

### F1 — Prove restart/crash behavior uses existing persistence boundaries

| Field | Content |
|---|---|
| Task | Verify PRE-080C-01 does not create a restart or double-mutation regression. |
| Objective | Ensure acquisition integrates with existing RuntimeAttempt, RecoveryLedger and TransitionAttempt semantics rather than bypassing them. |
| Output | Focused tests or existing-test extensions showing rejected/pre-submit evidence does not mutate the provider, stale attempt evidence is not reusable after replacement/restart, and existing TransitionAttempt fencing still prevents duplicate mutation after the submission boundary. Update the PRE-080C-01 evidence document with the results. |
| Note | Do not add sleeps, new DETS tables, durable RuntimeAttempt persistence or blind mutation retry. Reuse existing recovery tests where they already prove a property. STOP if safe recovery would require a new authority store. |

### F2 — Run final repository gates and freeze candidate evidence

| Field | Content |
|---|---|
| Task | Run final validation and prepare the independent-review handoff. |
| Objective | Establish that the bounded remediation satisfies repository quality gates without authorizing its own merge or subsequent roadmap work. |
| Output | Run `mix specs.check`, `make all`, and `git diff --check`; update `docs/symphony-hardening-playbook-v4.1/PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md` with exact results; commit/push and open or update the review PR; report base SHA/tree, candidate HEAD/tree, exact diff, PR identity and required-check state. |
| Note | Run the expensive full gate only after focused tests are stable. Do not merge. Do not mark PRE-080C-01 accepted. Do not authorize H-080C. STOP if final checks fail, protected main movement invalidates the frozen candidate, or the PR diff contains unauthorized files. |

The implementation package is therefore frozen around **producer repair, not validator redesign**.

# STOP_CONDITIONS

Implementation must stop immediately if any of the following occurs:

```text
protected main moves in a way that invalidates this plan
authority becomes ambiguous
DEFECT_PROVEN cannot be reproduced
a fourth production owner becomes necessary without prior review
GuardClass/LifecycleAssessment would need weakening
Planner machine evidence would rely on agent prose
runtime evidence fields would need exposure
raw provider state would gain forward authority
candidate movement would cease invalidating review
another mutable authority/evidence store is proposed
RuntimeAttempt would need new V2 persistence
manual fabricated evidence is proposed as the production solution
live secrets or unsafe provider mutation become necessary
H-080C implementation begins
PRE-080C-02 or PRE-080C-03 is entered
Programme B/C/D/E/F architecture leaks into the V1 repair
Redis/distributed authority is introduced
another runtime adapter is added for proof symmetry
the implementation agent would merge or self-accept its PR
```

These preserve the permanent stops specified by the planning authority. Pasted text

The key architectural conclusion is narrow: **Symphony already knows how to validate trustworthy evidence; ordinary execution simply fails to acquire several required evidence families.** Repair those producers at their existing trust boundaries—AgentTool for bounded semantic judgments, TransitionCoordinator for Planner machine facts, and SourceControl for exact candidate/CI facts—and leave the hardened authority model intact.

PLAN_VERDICT=READY FOR IMPLEMENTATION