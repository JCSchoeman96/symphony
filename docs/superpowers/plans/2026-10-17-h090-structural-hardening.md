# H-090 Structural Hardening — Implementation-Grade Plan

**Repository:** `JCSchoeman96/symphony`<br>
**Phase:** `H-090 — Structural Hardening`<br>
**Workflow decision:** `MG-2026-10-17-H090-WORKFLOW-DELEGATION-01`<br>
**Decision timestamp:** `2026-10-17T17:45:46+02:00`<br>
**Planning base SHA:** `bbe56c871335d6c7db658c1d37e0b2d1a875ae2f`<br>
**Planning base tree:** `82c2874845ba4f3201bb85e50e6384024417f58b`<br>
**Master Roadmap blob:** `4b0528bdc0647d889b42ebc478081d5b873898fe`<br>
**Plan path:** `docs/superpowers/plans/2026-10-17-h090-structural-hardening.md`<br>
**Chosen outcome:** `ASSESSMENT_ONLY`<br>
**Merge authority:** `HUMAN_ONLY`<br>
**H-120A:** `NOT_AUTHORIZED`

---

## 0. Executive decision

H-090 MUST NOT manufacture a structural code change merely because `Orchestrator` is large.

The current V1 production architecture already has the critical state laws, identity values, durable ledgers, provider transport, source-control verification, dependency policy, workspace ownership law, and controlled provider mutation sequencing separated behind subordinate modules. The remaining large `Orchestrator` body is primarily the single mutable coordination owner that composes those seams. Moving a meaningful subset of that mutable coordination into a second autonomous owner would increase authority ambiguity; moving only small pure helpers would fail H-090's correctness/security-benefit threshold and amount to churn.

Accordingly:

```text
OUTCOME=ASSESSMENT_ONLY
PRODUCTION_CODE_CHANGE=NO
TEST_CODE_CHANGE=NO
STRUCTURAL_EXTRACTION=NO
TRACKER_WORKCONTROL_RENAME=NO
CANDIDATEREF_EXPANSION=NO
COMPLETIONPROOF_EXPANSION=NO
H120A_WORK=NO
```

The bounded H-090 candidate is documentation/evidence only. It records the structural assessment against current production code, proves that no extraction clears the H-090 threshold, re-runs the accepted behavioral characterization on the untouched production tree, and leaves all production semantics unchanged.

This plan is implementation-authorizing under `MG-2026-10-17-H090-WORKFLOW-DELEGATION-01` once its final verdict is `READY FOR IMPLEMENTATION`. There is no separate Master plan-review gate. The implementation agent still has no merge authority and MUST hand the resulting candidate to a fresh reviewer and then the Master Final Gate before human merge.

---

## 1. Verified planning baseline and authority

### 1.1 Protected main

The planner independently resolved protected `main` to:

```text
BASE_SHA=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
BASE_TREE=82c2874845ba4f3201bb85e50e6384024417f58b
```

The branch remains protected. The required status checks are exactly:

```text
make-all                  app_id=15368
validate-pr-description   app_id=15368
```

The merge commit is signature-verified.

### 1.2 Post-merge verification

Workflow run `39046187708` is:

```text
STATUS=completed
CONCLUSION=success
RUN_ATTEMPT=1
HEAD_SHA=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
```

Its terminal `make-all` job succeeded.

### 1.3 Governance projection

The repository projection currently establishes:

```text
CURRENT_ACCEPTED_PHASE=H-080C
CURRENTLY_AUTHORIZED_WORK=H-090
CURRENTLY_AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
H_080C=ACCEPTED
NEXT_AUTHORIZED_PHASE=NONE
KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=H090_NOT_ACCEPTED
```

The checked-in projection still contains the earlier `2026-10-17T13:53+02:00` planning-only wording that said a later separate Master implementation authorization would be required. That clause is superseded for workflow purposes by the later human governance decision supplied for this planning task:

```text
DECISION_REF=MG-2026-10-17-H090-WORKFLOW-DELEGATION-01
DECISION_TIMESTAMP=2026-10-17T17:45:46+02:00
PLANNER_READY_EFFECT=DIRECT_IMPLEMENTATION_AUTHORIZATION_WITHIN_THE_EXACT_APPROVED_PLAN
SEPARATE_MASTER_PLAN_GATE=NO
```

This is not a request to rewrite governance projection machinery inside H-090. `SymphonyElixir.Governance.Check` is explicitly a derivative checker of accepted human authority, not an authority source. H-090 implementation remains bounded by this exact plan and H-120A remains unauthorized.

### 1.4 Governance command evidence

The exact base tree has independent evidence that normal governance validation passes. The PR #47 candidate that produced the current tree also recorded a clean-HEAD pass for:

```bash
mix governance.check
mix governance.check --freeze --candidate-phase H-090
```

Its candidate tree was exactly `82c2874845ba4f3201bb85e50e6384024417f58b`, identical to the current protected-main tree. The implementation agent MUST nevertheless re-run both commands in its own fresh H-090 worktree before any substantive candidate work and again at final verification.

### 1.5 Normative authority order

Implementation and review MUST use this hierarchy:

1. `docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md`
2. `docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`
3. `docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md`
4. accepted H-080C evidence
5. current production code
6. current tests
7. this H-090 plan, only within the scope delegated by the human governance decision above

The Master Roadmap MUST remain byte-identical at blob:

```text
4b0528bdc0647d889b42ebc478081d5b873898fe
```

---

## 2. Backward-planned architectural target

The mature V1 target is not “many small files.” It is:

```text
one understandable authority kernel
+ clear subordinate boundaries
+ unchanged production semantics
+ unchanged lifecycle law
+ unchanged durability/recovery
+ unchanged security authority
```

Working backwards from that target, the following properties must remain true now:

1. Exactly one mutable orchestration authority owns dispatch/runtime coordination: `SymphonyElixir.Orchestrator`.
2. Provider state remains an observation. It never grants forward authority by itself.
3. Canonical lifecycle policy remains pure and provider-neutral under `WorkControl.WorkflowLifecycle`.
4. Provider mutation is sequenced through the narrow `TransitionCoordinator`; it does not become a second lifecycle/dispatch authority.
5. Runtime identity and attempt law remain host-owned; durable retry/fence safety remains in `AttemptLedger`, not reconstructed from provider state.
6. Recovery remains fail-closed across `AttemptLedger`, `RecoveryLedger`, `SuspensionContext`, `SuspensionRecovery`, and workspace ownership records.
7. Candidate/review/merge/completion proof remains exact-candidate-bound and source-control-verified.
8. Dependency Graph/Guard/Policy remain subordinate policy/data, not an independent scheduler.
9. Plane read scheduling remains provider-read infrastructure; Orchestrator remains owner of the accepted epoch used for dispatch/control decisions.
10. Workspace ownership remains identity-bound and durable; filesystem existence alone is never ownership proof.
11. H-090 must not import Programme B abstractions such as generic Execution/Candidate/EvidenceBundle domains.
12. Any structural change must lower correctness/security risk more than it adds boundary/state complexity.

No candidate extraction inspected for H-090 satisfies all twelve properties plus the ten mandatory extraction-threshold criteria with a concrete benefit. Therefore the mature target is best preserved by assessment-only closure.

---

## 3. Domain / resource map

| Domain / resource | Truth owner | State owner | Primary inputs | Primary outputs | Side effects | Durability | Authority granted | Authority explicitly NOT granted |
|---|---|---|---|---|---|---|---|---|
| `Orchestrator` | Symphony authority kernel | Single `GenServer` `%Orchestrator.State{}` aggregate | validated WorkItems, provider epochs/webhooks, runtime results, durable ledgers, config | dispatch/continuation decisions, runtime coordination, suspensions, diagnostics, work-control projections | starts/stops tasks/runtimes, coordinates ledger/workspace calls | delegates durable safety state to dedicated ledgers | dispatch/runtime coordination inside accepted policy | provider truth creation, autonomous merge, human approval, source-control truth |
| `WorkflowLifecycle` | repository lifecycle law | none; immutable module data | canonical source/target | transition metadata, guards, classifications | none | code | defines legal lifecycle transitions/required guards | provider mutation, dispatch, persistence |
| `LifecycleAssessment` | Symphony interpretation of one provider observation | value instance only | `ProviderObservation`, prior validated state, trusted evidence, project contract | validated/blocked/invalid assessment | no remote effects; may close an in-memory typed CompletionProof using trusted evidence | assessment is held/persisted only through owning work-control/recovery paths | validates whether an observation may support local authority | cannot grant authority solely from provider state |
| `AuthorityDisposition` | local authority policy | value instance only | `LifecycleAssessment`, prior disposition, explicit recovery facts | `none/eligible/active/suspended/escalated` | none | via owning state/checkpoint only | local eligibility/activity/suspension status | provider transition, merge, retry recreation |
| `CompletionProof` | source-control + provider closure evidence law | immutable staged value | exact CandidateRef, candidate verification, review provenance, human/merge path, merge verification, fresh provider observation | `merge_authorized`, `merge_verified`, `completed` proof | cryptographic signing only | carried as typed evidence/checkpoint | satisfies exact mechanical guards at matching stage | generic evidence persistence, execution identity, provider authority |
| `RecoveryLedger` | durable work-control checkpoint facts | disk-backed ledger | validated work-control/recovery snapshots | restart checkpoints | DETS/file I/O | durable | preserves facts needed to recover safely | scheduler/lifecycle authority |
| `SuspensionContext` / `SuspensionRecovery` | Symphony suspension law | context value + owning recovery checkpoint | prior validated state, provider observation, exact lineage/suspension ID, required evidence | resolving/resolved/escalated decision and resume target | policy only; persistence handled by owner | via recovery path | permits resume only after trusted reconciliation | blind resubmit, provider-owned resume |
| `TransitionCoordinator` | controlled transition sequencing | narrow coordinator GenServer + `TransitionAttemptLedger` | semantic intent, route, fresh context, provider contract, guard evidence | verified/rejected/conflict/provider_failed/indeterminate TransitionAttempt | durable pre-submit fence, one provider mutation call, fresh verification callback | `TransitionAttemptLedger` | serialization and safe execution of an already-authorized transition | lifecycle policy, dispatch authority, autonomous retry of ambiguous mutation |
| `TransitionAttempt` | provider-mutation attempt state law | typed value; durable attempt record through ledger | intent/context/evidence | attempt state/outcome | none by itself | ledger owned | state-machine legality | permission to mutate without coordinator/fence |
| `Dependency.Graph` | normalized dependency snapshot | value held by Orchestrator for current Plane epoch | provider dependency reads | graph nodes/edges/completeness | none | not an independent authority store | data for policy evaluation | scheduling/dispatch authority |
| `Dependency.Guard` / `Policy` | repository dependency policy | none | issue/WorkItem, responsibility, graph/blockers | safe allow/block diagnostics | none | code | policy result only | lifecycle mutation or scheduler ownership |
| `AgentRuntime.Router` / `Route` / `Profile` | routing/profile policy | pure values/config | validated WorkItem + profiles | route/profile selection | none | config/code | selects runtime responsibility/profile under existing authority | creates lifecycle authority |
| `RuntimeAttempt` | host-owned runtime attempt identity/law | typed value stored in Orchestrator running map | route, work item, lineage | runtime state/identity | none by itself | not persisted as independent current truth | binds one runtime attempt to exact responsibility/lineage | durable retry/fence truth |
| `AttemptLedger` / Authority Fence | durable attempt lineage/fence safety | disk-backed ledger | attempt counters, runtime identity, suspension intent | open/exhausted lineage facts, fence states | DETS/file I/O + sync | durable | preserves spent/held authority so restart cannot recreate it | tracker truth, scheduling, provider mutation |
| `Tracker` | provider adapter/read boundary | no independent lifecycle state | configured adapter/settings | issues, dependency reads, project snapshots, signed tracker observations, provider-native tool binding | provider reads and adapter delegation | provider-owned remote state | transport/read capability only | canonical lifecycle truth or local authority |
| Plane read components (`ReadScheduler`, `DependencyReader`, webhooks) | Plane transport/read behavior | bounded scheduler/task/dedup state | Plane API/webhook signals | rate-limited reads, dependency/project snapshots, read intents | provider reads, task scheduling | only dedicated dedup/read state where implemented | read orchestration only | second control-plane scheduler or lifecycle owner |
| Orchestrator Plane epoch | accepted current provider snapshot for coordination | fields inside `%Orchestrator.State{}` | Plane snapshot/dependency task results, webhook dirtiness | `unavailable/refreshing/current/failed` epoch state + current graph | supervised tasks; state promotion/cancellation | no new durable store | determines whether current provider data is usable | provider mutation authority |
| `SourceControl` | provider-neutral SCM authority seam | stateless typed verification values | repository/PR/check/merge observations | CandidateVerification, review provenance, MergeVerification, CompletionProof stages | GitHub reads / verification; signing | evidence values/checkpoints, provider is source of remote truth | validates exact candidate/check/review/merge facts | autonomous merge or lifecycle authority |
| `SourceControl.AgentTool` | bounded Reviewer-facing SCM reads | bound host tool context | reviewer route/runtime identity | read-only SCM facts | SCM reads | none | reviewer read capability only | write/merge authority |
| `CandidateRef` | exact candidate identity law | immutable five-field value | repository identity, base SHA, candidate SHA, PR identity, observed PR head | fingerprint/equality/validation | none | embedded in evidence | candidate identity only | generic Candidate/Execution domain |
| `Workspace.Ownership` | workspace ownership state law | pure record/value | ownership record/state | legal transitions/key derivation | none | `OwnershipLedger` owns persistence | identity-bound ownership law | filesystem adoption by existence |
| `Workspace` / `OwnershipLedger` | workspace side-effect and durable ownership boundary | ledger + filesystem/remote host | project/tracker identity, host/root identity, runtime request | provisioned/released workspace | filesystem/SSH I/O | durable ledger | workspace possession for the exact identity | runtime/lifecycle authority |
| Codex / isolation boundary | runtime adapter behavior under Symphony policy | child process/session only | authorized profile, workspace, credentials, prompt/tool envelope | bounded execution result | child process/tool calls | not authority truth | executes already-authorized responsibility | provider transition/merge/review/rearm/recovery authority |

### Domain-map conclusion

The architecture already follows the desired split: policy and typed state laws are narrow; durable truth is held by purpose-built ledgers; provider/SCM/workspace adapters own side effects; the Orchestrator composes those parts as the one mutable coordination authority. H-090 should not create another owner simply to reduce file length.

---

## 4. Lifecycle preservation map

### 4.1 WorkflowLifecycle

**States**

```text
backlog
planning
ready
in_progress
in_review
changes_requested
ready_to_merge
merging
blocked
done
canceled
```

**Ordinary transitions and guards**

```text
backlog -> planning
  HumanDecision(:planning_started)

planning -> ready
  SemanticAttestation(:plan_attested)
  MechanicalGuard(:planning_requirements_verified)

ready -> in_progress
  MechanicalGuard(:dispatch_guard)

in_progress -> in_review
  SemanticAttestation(:implementation_attested)
  MechanicalGuard(:implementation_checks_verified)
  MechanicalGuard(:candidate_state_verified)

in_review -> changes_requested
  SemanticAttestation(:review_changes_requested)

changes_requested -> in_review
  SemanticAttestation(:correction_attested)
  MechanicalGuard(:correction_checks_verified)
  MechanicalGuard(:candidate_state_verified)

in_review -> ready_to_merge
  MechanicalGuard(:review_acceptance_verified)
  SemanticAttestation(:review_accepted)

ready_to_merge -> merging
  HumanDecision(:merge_approved)
  MechanicalGuard(:merge_guard_verified)

merging -> done
  MechanicalGuard(:completion_merge_verified)
```

Any nonterminal state may transition to `canceled` only with `HumanDecision(:cancellation_authorized)`. `done` and `canceled` are terminal; only `done` is successful. Same-state and unlisted transitions fail.

**Side effects / durability:** module is pure policy; side effects are executed by owners after guard validation.<br>
**Restart:** law is code-stable; current work state is recovered through owning state/ledgers.<br>
**Authority owner:** Symphony WorkControl + Orchestrator composition.<br>
**H-090 action:** no change.

### 4.2 AuthorityDisposition

**States**

```text
none -> eligible -> active
                 \-> suspended -> eligible
                              \-> active
                              \-> escalated
```

`eligible/active -> suspended` on authority-reducing/validation-required/invalid conditions. `suspended -> eligible|active` requires fresh reconciliation and a canonical resume target; `active` additionally requires `attempt_started`. `suspended -> escalated` requires human decision. `escalated` is terminal. Canceled work cannot be reactivated.

**Side effects:** none.<br>
**Durability:** through owning work-control/recovery state only.<br>
**Restart:** no provider observation recreates authority.<br>
**Authority owner:** Symphony.<br>
**H-090 action:** no change.

### 4.3 Authority Fence (`AttemptLedger`)

**States / transitions**

```text
ARMED
  -> BOUND
  -> RELEASED                 # only safe unused armed reservation

BOUND
  -> SUSPENSION_PENDING       # exact RuntimeAttempt + suspension intent
  -> RELEASED                 # exact bound RuntimeAttempt identity

SUSPENSION_PENDING
  -> RELEASED                 # exact terminal SuspensionContext correlation

RELEASED                       # terminal

LEGACY_AMBIGUOUS               # unresolved compatibility condition; not auto-promoted
```

**Guards:** exact work item, lineage generation, RuntimeAttempt identity, route/fence identity, suspension ID and terminal context where applicable.<br>
**Side effects:** durable ledger write and sync; unresolved fence keeps `in_flight` protected.<br>
**Durability:** `AttemptLedger`.<br>
**Failure states:** unresolved/identity mismatch/transition invalid/ledger unavailable fail closed.<br>
**Terminal:** `RELEASED` for one fence instance.<br>
**Restart:** open lineages and unresolved fences are restored; restart must not recreate spent authority.<br>
**Authority owner:** Orchestrator coordinates; AttemptLedger preserves durable fence truth.<br>
**H-090 action:** no change.

### 4.4 TransitionAttempt

**States**

```text
requested
-> intent_authorized
-> fresh_context_loaded
-> prepared
-> mutation_submitted
-> verifying
-> verified
 | rejected
 | conflict
 | provider_failed
 | indeterminate
```

**Important durable boundary:** the coordinator persists/syncs `submission_fenced_at` while the attempt is prepared before the provider call. `submit_once` then advances `mutation_submitted` in memory and invokes the provider. The durable pre-submit fence—not provider acknowledgement—is the no-blind-resubmit boundary.

**Guards:** semantic transition intent, current route/authority, fresh provider context, current project contract, required guard evidence, exact transition/runtime/lineage identities, durable fence before submission, fresh verification after possible submission.<br>
**Side effects:** exactly one provider submission per safely prepared attempt; verification reread; ledger writes.<br>
**Durability:** `TransitionAttemptLedger`.<br>
**Failure/terminal:** `verified`, `rejected`, `conflict`, `provider_failed`, `indeterminate` are terminal.<br>
**Restart:** fenced possible submissions become reconciliation candidates; no blind resubmit.<br>
**Authority owner:** TransitionCoordinator sequences; policy authority remains WorkControl/Orchestrator.<br>
**H-090 action:** no change.

### 4.5 RuntimeAttempt

**Current accepted state machine from code**

```text
queued -> starting

starting -> running
         | stopping
         | retry_queued
         | blocked
         | failed
         | cancelled

running -> stopping
        | completed
        | retry_queued
        | blocked
        | failed
        | cancelled

stopping -> containment_unconfirmed
         | containment_proven_dead

containment_proven_dead -> running
                         | completed
                         | retry_queued
                         | blocked
                         | failed
                         | cancelled

containment_unconfirmed -> <no outgoing transition>

completed     -> <terminal>
retry_queued  -> <terminal>
blocked       -> <terminal>
failed        -> <terminal>
cancelled     -> <terminal>
```

`containment_unconfirmed` intentionally has no outgoing transition but is **not** included in `terminal?/1`. That accepted distinction MUST remain unchanged.

**Identity:** `runtime_attempt_id + work_item_id + lineage_generation + responsibility + runtime_profile`.<br>
**Side effects:** none by value itself; Orchestrator/runner owns process effects.<br>
**Durability:** current runtime attempt truth is not independently persisted; AttemptLedger preserves the durable safety/fence lineage.<br>
**Restart:** must not reconstruct active authority from provider state.<br>
**Authority owner:** Orchestrator.<br>
**H-090 action:** no change.

### 4.6 Workspace Ownership

**States**

```text
reserved -> provisioning -> owned -> release_pending -> released
                           \-------------------------> release_pending

release_pending -> owned     # only proven recovery / exact identity path
release_pending -> released
released -> <terminal>
```

More exactly: `provisioning` may move to either `owned` or `release_pending`; `owned -> release_pending`; `release_pending -> owned|released`; `released` terminal.

**Guards:** exact project/tracker/work-item/workspace ownership identity; trusted host/root/filesystem identity.<br>
**Side effects:** workspace provisioning/removal are outside pure `Ownership`; ledger/file system boundary owns them.<br>
**Durability:** `Workspace.OwnershipLedger`.<br>
**Failure:** changed/missing identity fails closed; directory existence alone is insufficient.<br>
**Restart:** only proven identity-bound recovery may return `release_pending -> owned`.<br>
**Authority owner:** Workspace ownership subsystem under Orchestrator coordination.<br>
**H-090 action:** no change.

### 4.7 SuspensionContext

**States**

```text
open -> resolving -> resolved
                 \-> escalated
```

`resolved` and `escalated` are terminal.

**Guards to resolve:** fresh reconciliation, canonical trusted resume target, all required evidence, matching work-item identity; exact suspension/lineage correlation where carried by durable recovery.<br>
**Side effects:** none in the pure value.<br>
**Durability:** durable suspension facts are retained through H-060B recovery/attempt ledger paths; the context value itself is policy shape.<br>
**Failure:** missing evidence/freshness/target fails closed.<br>
**Restart:** unresolved suspension remains Symphony-owned; provider Blocked/other projection does not release it.<br>
**Authority owner:** Symphony.<br>
**H-090 action:** no change.

### 4.8 CompletionProof V1

**Stages**

```text
merge_authorized
-> merge_verified
-> completed
```

**Bindings at all applicable stages:** work item, provider project fingerprint, workspace/project, exact five-field `CandidateRef`, candidate tree SHA, policy fingerprint, candidate verification, signed independent review provenance including Reviewer responsibility/runtime attempt/lineage/time.

**Stage guards**

```text
merge_authorized -> MechanicalGuard(:merge_guard_verified)
merge_verified   -> MechanicalGuard(:completion_merge_verified)
completed        -> MechanicalGuard(:completion_proof_verified)
```

`merge_verified` requires actual source-control merge verification. `completed` additionally requires a fresh provider observation after merge verification, exact contract/identity match, and canonical `done` mapping.

**Side effects:** source-control/provider reads happen in the owning seams; proof creation/closure signs evidence.<br>
**Durability:** typed evidence may be stored/recovered only in the existing bounded evidence/checkpoint paths.<br>
**Failure:** candidate movement, policy/check movement, review provenance mismatch, missing merge verification, stale/mismatched provider closure all invalidate downstream trust.<br>
**Terminal:** `completed` for the bounded V1 proof chain.<br>
**Restart:** recovered evidence is revalidated; stale candidate-bound trust is not accepted.<br>
**Authority owner:** SourceControl verifies source-control facts; WorkControl decides whether proof satisfies lifecycle guard; human still owns merge approval.<br>
**H-090 action:** no expansion.

### 4.9 Plane epoch control state

Although not a separate domain authority, the current Orchestrator epoch state is structurally relevant:

```text
unavailable -> refreshing -> current
                         \-> failed
current -> refreshing     # refresh/follow-up
refreshing/current -> failed on cancellation/fingerprint drift/task failure
```

The accepted graph is current only when the epoch ID matches, the graph is complete, no acquisition task remains, and `plane_epoch_status == :current`.

**State owner:** Orchestrator.<br>
**Side effects:** supervised read task plus Plane `ReadScheduler`.<br>
**Durability:** no new independent durable authority store.<br>
**Restart:** a fresh epoch is acquired; stale graph state is not promoted as current.<br>
**H-090 action:** no extraction into another scheduler/control owner.

---

## 5. Mandatory seam assessment

### A. Orchestrator authority ownership

**Observed structure**

`%Orchestrator.State{}` deliberately contains the shared mutable coordination aggregate: running/completed/claimed/blocked sets, dependency graph/diagnostics, attempt counters/lineages, durable-ledger handles/status, recovery checkpoints, work-control projections, Plane epoch/task state, webhook queues/tasks/generations, scheduler handles and timing state.

The source includes an explicit design comment that the GenServer owns this shared orchestration aggregate and splitting the fields would duplicate state ownership.

**What must remain inside the one mutable owner**

- accepted current WorkItem projections used for routing/continuation;
- running runtime table and relationship to claimed/completed/blocked state;
- current Plane epoch identity/status/graph and webhook generation ordering;
- coordination of durable attempt/recovery/workspace ledgers with live runtime state;
- dispatch ordering/capacity and retry/review counters as used by dispatch policy;
- task/mailbox ordering decisions.

**Verdict:** KEEP. No second lifecycle/dispatch/runtime/recovery authority and no independently mutable state copy may be introduced.

### B. Durable attempt / recovery / startup

The relevant behavior is already split by responsibility:

- `AttemptLedger`: durable retry/exhaustion + authority fence facts;
- `RecoveryLedger`: durable validated work-control checkpoints;
- `SuspensionContext` / `SuspensionRecovery`: suspension policy;
- `Workspace.Ownership` / `OwnershipLedger`: ownership law and durable identity;
- Orchestrator: composes all of them against live state and startup sequencing.

The remaining Orchestrator startup/recovery code is cross-resource coordination. Extracting it as another mutable service would require shared access to the same WorkItem/running/ledger/epoch state or passing the full `%Orchestrator.State{}`—both fail the H-090 threshold. A pure calculation-only extraction would be too small to deliver a concrete correctness/security benefit.

**Verdict:** KEEP; no extraction.

### C. Plane epoch / reconciliation

Existing separation:

- `Plane.ReadScheduler` owns bounded provider-read scheduling/rate discipline;
- Plane reader/adapter components own provider-specific read mechanics;
- webhook components translate/deduplicate external signals;
- `Orchestrator` owns whether an epoch is current and whether its graph/snapshot may influence coordination;
- `LifecycleAssessment` decides whether one provider observation is trusted for lifecycle authority.

A new “Plane epoch controller” would either become a second control-plane owner or require a mirrored copy of Orchestrator epoch/work-control state. Moving only fingerprint/metric helpers would be file-shuffling without correctness benefit.

**Verdict:** KEEP current ownership.

### D. WorkControl / TransitionCoordinator

The flow is already explicit:

```text
provider observation
-> LifecycleAssessment
-> AuthorityDisposition
-> already-authorized semantic transition intent
-> TransitionCoordinator durable preparation/fence
-> provider mutation
-> fresh provider verification
-> verified result applied back through the authority owner
```

`TransitionCoordinator` is a sequencing boundary, not a lifecycle-policy owner. It serializes a work item, writes the durable no-resubmit boundary, emits at most the authorized provider mutation, then fresh-verifies. That is a justified subordinate mutable boundary and should not be collapsed into Orchestrator or expanded into a second authority kernel.

**Verdict:** ownership is complementary, not harmful duplication. No change.

### E. Tracker / WorkControl naming

Answers required by H-090:

```text
Does Tracker accurately represent provider transport/read tooling?
YES. Its module contract is explicitly the adapter boundary for issue-tracker reads and provider-native agent tooling.

Does WorkControl represent provider-neutral lifecycle/authority domain?
YES. WorkflowLifecycle, LifecycleAssessment, AuthorityDisposition, GuardClass, CompletionProof,
ProviderObservation/Contract and recovery values are provider-neutral policy/evidence concepts.

Is public naming materially dangerous or misleading?
NO. There is historical breadth in Tracker (reads plus bound provider-native tools), but the
moduledoc and call boundaries make the distinction explicit. No correctness defect was found.

Would renaming improve correctness or merely create churn?
CHURN. A broad rename would touch adapters/tests/docs/callers without changing authority ownership.
```

**Verdict:** NO RENAME.

### F. CandidateRef / CompletionProof

`CandidateRef` is already exactly the bounded five-field H-050C identity:

```text
repository_identity
base_sha
candidate_sha
pr_identity
observed_pr_head_sha
```

`CompletionProof` is already a three-stage bounded V1 proof chain binding exact candidate + review provenance + merge verification + provider closure.

Neither needs to become `Execution`, a generic `Candidate` domain, `EvidenceBundle`, or generic evidence persistence in H-090. Those expansions belong to later programmes if separately authorized.

**Verdict:** KEEP bounded V1 concepts exactly as-is.

### G. Pure / diagnostic helpers embedded in Orchestrator

There are pure projections/fingerprint/diagnostic helpers that *could* mechanically be moved. They do not clear the threshold because:

- no authority ambiguity is removed;
- no lifecycle/recovery invariant becomes easier to enforce;
- moving them adds a new module/API surface;
- tests would prove only relocation, not a correctness improvement;
- the extraction would be justified by file size/organization rather than a demonstrated risk.

**Verdict:** DO NOT PAD H-090 WITH HELPER MOVES.

---

## 6. Extraction-threshold matrix

Every material criterion must pass. A single material failure rejects the extraction.

| Candidate seam | Cohesive responsibility | No authority transfer | No mutable copy | Lifecycle unchanged | Fail-closed unchanged | Durability/restart unchanged | Concrete correctness/security benefit | Independently characterizable | Narrow typed API | One bounded change | Decision |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Move durable startup/recovery coordination out of Orchestrator | yes | **no/risky** | **no/risky** | risky | risky | **risky** | uncertain | yes | **no without State leakage** | no | REJECT |
| Create Plane epoch controller/service | yes | **no/risky** | **no** | yes | risky | yes | uncertain | yes | **no without mirrored state** | no | REJECT |
| Extract only Plane fingerprints/metrics/projections | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes | REJECT — helper churn |
| Rename Tracker / split naming surface | partly | yes | yes | yes | yes | yes | **no concrete defect** | yes | no (broad caller churn) | **no** | REJECT |
| Expand CandidateRef/CompletionProof into generic evidence/candidate domain | yes | **no/risky** | risky | risky | risky | **risky** | not V1 | no | no | no | REJECT — Programme B leakage |
| Extract observability/status helper group | yes | yes | yes | yes | yes | yes | **no** | yes | yes | yes | REJECT — not H-090 justification |

**Conclusion:** no extraction clears all ten criteria. Outcome A is mandatory.

---

## 7. H-I19 through H-I24 preservation map

| Invariant | Current enforcement seam | H-090 assessment | Required evidence in H-090 candidate |
|---|---|---|---|
| **H-I19** Provider observation cannot grant forward authority | `ProviderObservation` + `LifecycleAssessment` + `AuthorityDisposition` + AttemptLedger fence + Orchestrator routing | Any state split near WorkControl/Orchestrator would make this harder to reason about; no split | Re-run provider/lifecycle + authority-fence characterization; document no source change |
| **H-I20** Trusted CompletionProof required | `CompletionProof`, `LifecycleAssessment.completion_validated?/1`, SourceControl merge verification | CompletionProof already bounded and exact; expansion would weaken class boundaries | Re-run source-control/completion suites; record three-stage chain |
| **H-I21** Suspension remains Symphony-owned | `AuthorityDisposition`, `SuspensionContext`, `SuspensionRecovery`, AttemptLedger fence, Orchestrator recovery | Moving recovery ownership risks second resume authority | Re-run suspension/restart/fence suites; record no provider-owned release |
| **H-I22** Ambiguous mutation cannot be blindly retried | `TransitionAttempt`, `TransitionAttemptLedger`, `TransitionCoordinator` pre-submit fence/reconciliation | Current subordinate boundary is already the correct seam | Re-run transition coordinator/ledger + startup reconciliation tests |
| **H-I23** Candidate movement invalidates candidate-bound trust | `CandidateRef`, CandidateVerification, SourceControl reconciliation, signed review provenance, CompletionProof | No expansion/rename needed; keep exact identity chain | Re-run candidate/ref/recovery/review provenance suites |
| **H-I24** Guard/evidence classes remain non-interchangeable | `GuardClass`, WorkflowLifecycle guard requirements, host evidence acquisition, CompletionProof | Generic evidence abstraction would be harmful | Re-run GuardClass/source-control/workflow tests; document distinct HumanDecision/SemanticAttestation/MechanicalGuard/provenance/proof classes |

If any re-run weakens, flakes nondeterministically, or exposes a current-production defect, STOP H-090 and preserve the reproducer. Do not “fix while refactoring.”

---

## 8. Performance / scaling conclusion

Because the selected outcome changes no production/test code, the expected delta is exactly:

```text
provider-read count:          NO CHANGE
SCM-read count:               NO CHANGE
GenServer blocking:           NO CHANGE
Dependency graph copies:      NO CHANGE
Tasks spawned:                NO CHANGE
Mailbox ordering:             NO CHANGE
Epoch work:                   NO CHANGE
Stale-work lifetime:          NO CHANGE
Polling:                      NO CHANGE
Additional retained memory:   NO CHANGE
```

The accepted V1 envelope remains:

```text
items <= 1000
edges <= 5000
```

No Redis, Postgres, distributed state, PubSub, new cache, scheduler, or persistence layer is introduced.

A change to any item above means the implementation has exceeded `ASSESSMENT_ONLY` and MUST STOP.

---

## 9. Expected candidate files

Exactly these two files are authorized for the H-090 assessment-only candidate:

```text
docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md
```

No file under any of these paths may change:

```text
elixir/lib/**
elixir/test/**
.github/**
Makefile
elixir/Makefile
elixir/mix.exs
docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json
docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md
docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md
```

The assessment document records evidence; it MUST NOT self-accept H-090 or authorize H-120A.

---

# 10. Implementation tasks

## Task 1 — Establish the exact fresh worktree and re-run pre-change structural characterization

### Objective

Prove the coding agent is operating from the exact planning base, with current governance and accepted production behavior, before creating either authorized document.

### Exact files

Read only; **no file changes in this task**.

Primary production files inspected:

```text
elixir/lib/symphony_elixir/orchestrator.ex
elixir/lib/symphony_elixir/transition_coordinator.ex
elixir/lib/symphony_elixir/tracker.ex
elixir/lib/symphony_elixir/source_control.ex
elixir/lib/symphony_elixir/source_control/candidate_ref.ex
elixir/lib/symphony_elixir/agent_runtime/attempt_ledger.ex
elixir/lib/symphony_elixir/agent_runtime/runtime_attempt.ex
elixir/lib/symphony_elixir/agent_runtime/router.ex
elixir/lib/symphony_elixir/dependency/graph.ex
elixir/lib/symphony_elixir/dependency/guard.ex
elixir/lib/symphony_elixir/dependency/policy.ex
elixir/lib/symphony_elixir/work_control/workflow_lifecycle.ex
elixir/lib/symphony_elixir/work_control/lifecycle_assessment.ex
elixir/lib/symphony_elixir/work_control/authority_disposition.ex
elixir/lib/symphony_elixir/work_control/completion_proof.ex
elixir/lib/symphony_elixir/work_control/recovery_ledger.ex
elixir/lib/symphony_elixir/work_control/suspension_context.ex
elixir/lib/symphony_elixir/work_control/suspension_recovery.ex
elixir/lib/symphony_elixir/work_control/transition_attempt.ex
elixir/lib/symphony_elixir/workspace/ownership.ex
elixir/lib/symphony_elixir/workspace/ownership_ledger.ex
```

### Existing functions/modules

Characterize, do not redesign:

- `Orchestrator.State` and Plane epoch/recovery/runtime coordination helpers;
- `WorkflowLifecycle.transition/2` and classifications;
- `LifecycleAssessment.assess/4`, completion validation and candidate reconciliation;
- `AuthorityDisposition.derive/2`, `transition/3`, `suspend/2`;
- `AttemptLedger.begin_attempt/3`, `bind_runtime_attempt/3`, suspension/release fence paths;
- `TransitionAttempt` state-transition functions and `submission_fenced?/1`;
- `TransitionCoordinator.request_transition/3` execution/fence/verify path;
- `RuntimeAttempt.transition/2`, `terminal?/1`;
- `Workspace.Ownership.transition/2`;
- `SuspensionContext.begin_resolution/1`, `resolve/2`, `escalate/2`;
- `CompletionProof.new_merge_authorized*`, `with_merge_verification/2`, `close/3`, `valid_evidence?/1`;
- `CandidateRef.new/1`, `validate/1`, `fingerprint/1`, `equal?/2`;
- `Tracker` read/adapter/controlled-transition boundary;
- `Router.resolve/*` canonical WorkItem routing.

### Interfaces consumed

Repository git identity, governance projection/checker, current production code, accepted tests, GitHub required-check configuration.

### Interfaces produced

No code interface. Produce only captured command results for Task 2 evidence.

### Lifecycle / invariant impact

None. This task is characterization only.

### TEST / CHARACTERIZATION FIRST

From a fresh worktree created from exactly the planning base:

```bash
git fetch origin
git rev-parse origin/main
git rev-parse 'origin/main^{tree}'
git merge-base HEAD origin/main
git status --short
```

Required before proceeding:

```text
origin/main=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
origin/main^{tree}=82c2874845ba4f3201bb85e50e6384024417f58b
HEAD=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
merge-base=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
WORKTREE=CLEAN
```

Then:

```bash
cd elixir
mix governance.check
mix governance.check --freeze --candidate-phase H-090
```

Both must exit 0.

Run the accepted focused groups on the untouched base:

```bash
mix test \
  test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs \
  test/symphony_elixir/plane_agent_tool_test.exs \
  test/symphony_elixir/transition_coordinator_test.exs \
  test/symphony_elixir/transition_coordinator_default_path_test.exs \
  test/symphony_elixir/transition_freshness_test.exs \
  test/symphony_elixir/work_control_workflow_lifecycle_test.exs \
  test/symphony_elixir/work_control_assessment_test.exs \
  test/symphony_elixir/runtime_transition_authority_binding_test.exs \
  test/symphony_elixir/tracker_read_attestation_test.exs \
  test/symphony_elixir/provider_project_contract_test.exs \
  test/symphony_elixir/plane_webhook_test.exs \
  test/symphony_elixir/orchestrator_plane_webhook_test.exs
```

```bash
mix test \
  test/symphony_elixir/source_control_test.exs \
  test/symphony_elixir/source_control_candidate_ref_test.exs \
  test/symphony_elixir/source_control_coverage_test.exs \
  test/symphony_elixir/source_control_merge_verification_test.exs \
  test/symphony_elixir/source_control_agent_tool_test.exs \
  test/symphony_elixir/guard_class_source_control_test.exs \
  test/symphony_elixir/work_control_assessment_test.exs \
  test/symphony_elixir/work_control_workflow_lifecycle_test.exs \
  test/symphony_elixir/rem_h080c_candidate_evidence_recovery_test.exs \
  test/symphony_elixir/rem_h080c_ready_to_merge_review_provenance_test.exs
```

```bash
mix test \
  test/symphony_elixir/h080a_authority_fence_characterization_test.exs \
  test/symphony_elixir/attempt_ledger_test.exs \
  test/symphony_elixir/transition_attempt_ledger_test.exs \
  test/symphony_elixir/orchestrator_startup_reconciliation_test.exs \
  test/symphony_elixir/workspace_ownership_ledger_test.exs \
  test/symphony_elixir/suspension_recovery_test.exs \
  test/symphony_elixir/rem_hi21_restart_gap_test.exs \
  test/symphony_elixir/runtime_attempt_identity_test.exs \
  test/symphony_elixir/runtime_attempt_teardown_test.exs \
  test/symphony_elixir/rem_h080c_candidate_evidence_recovery_test.exs \
  test/symphony_elixir/rem_h080c_ready_to_merge_review_provenance_test.exs
```

```bash
mix test \
  test/symphony_elixir/rem_h080c_03_backlog_planning_dependency_route_coupling_test.exs \
  test/symphony_elixir/dependency_graph_test.exs \
  test/symphony_elixir/dependency_policy_test.exs \
  test/symphony_elixir/dependency_completeness_test.exs \
  test/symphony_elixir/agent_router_dependency_proof_test.exs \
  test/symphony_elixir/transition_policy_test.exs \
  test/symphony_elixir/orchestrator_plane_epoch_test.exs
```

### Expected pre-change result

All commands exit 0 with zero failures. Exact test counts/seeds MUST be recorded, not pre-invented.

### Minimal implementation

None.

### Focused verification

Confirm `git status --short` remains empty after characterization.

### Expected result

Production behavior is characterized before any candidate file exists.

### Negative controls

At minimum verify the existing suites still exercise:

- stale/forged provider observation does not grant forward authority;
- missing CompletionProof does not validate Done;
- unresolved authority fence blocks release/lineage close;
- transition submission fence prevents blind replay;
- candidate movement invalidates review/candidate evidence;
- stale/mismatched runtime/workspace identity fails closed.

Do not weaken a negative assertion to make the suite pass.

### Adjacent regression

Run:

```bash
mix test \
  test/symphony_elixir/orchestrator_attempt_lineage_test.exs \
  test/symphony_elixir/orchestrator_startup_reconciliation_test.exs \
  test/symphony_elixir/orchestrator_plane_epoch_test.exs
```

Expected: exit 0, zero failures.

### Performance / concurrency check

No code changed; compare command behavior only. Do not add sleeps or timing tolerances. Any newly exposed deterministic regression or accepted-production defect is a STOP condition.

### STOP conditions

STOP immediately if:

- `origin/main` moved from the planning SHA/tree;
- worktree is not clean before work starts;
- either governance command fails;
- Master Roadmap blob differs;
- any focused/adjacent baseline test fails deterministically;
- a production defect is discovered;
- evidence suggests a structural code change is necessary to close H-090.

Preserve the reproducer and request a separate bounded remediation; do not fix it under H-090.

---

## Task 2 — Materialize the assessment-only candidate documents, with no production/test changes

### Objective

Create the repository plan file and one H-090 assessment/evidence record that captures the verified domain map, lifecycle map, seam decisions, invariant preservation and performance conclusion. Make no behavior change.

### Exact files

Create exactly:

```text
docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md
```

### Existing functions/modules

No function is modified. The assessment document references the production modules/functions enumerated in Task 1.

### Interfaces consumed

- this approved plan content;
- Task 1 exact command output;
- current authoritative roadmap/ledger/projection;
- current production code and accepted tests;
- H-080C accepted evidence.

### Interfaces produced

No runtime interface. Two documentation artifacts only.

The H-090 assessment file MUST contain, at minimum:

```text
BASE_SHA
BASE_TREE
MASTER_ROADMAP_BLOB
POST_MERGE_RUN_39046187708
GOVERNANCE_CHECK
H090_FREEZE_CHECK
DOMAIN_RESOURCE_MAP
LIFECYCLE_PRESERVATION_MAP
SEAM_A_ORCHESTRATOR
SEAM_B_RECOVERY
SEAM_C_PLANE_EPOCH
SEAM_D_WORKCONTROL_TRANSITIONCOORDINATOR
SEAM_E_TRACKER_WORKCONTROL_NAMING
SEAM_F_CANDIDATEREF_COMPLETIONPROOF
SEAM_G_PURE_DIAGNOSTIC_HELPERS
EXTRACTION_THRESHOLD_MATRIX
H_I19_H_I24_MATRIX
PERFORMANCE_SCALING_MATRIX
FOCUSED_TEST_RESULTS
ADJACENT_TEST_RESULTS
PRODUCTION_CODE_CHANGED=NO
TEST_CODE_CHANGED=NO
OUTCOME=ASSESSMENT_ONLY
H120A=NOT_AUTHORIZED
MERGE=NOT_PERFORMED
```

### Lifecycle / invariant impact

None. The document records current state machines; it must not redefine them.

### TEST / CHARACTERIZATION FIRST

Before creating files, retain the Task 1 clean-baseline evidence. Then confirm the plan/evidence paths do not already contain conflicting accepted content:

```bash
git ls-files --error-unmatch docs/superpowers/plans/2026-10-17-h090-structural-hardening.md 2>/dev/null || true
git ls-files --error-unmatch docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md 2>/dev/null || true
```

If either file already exists on the exact base with materially different H-090 content, STOP rather than overwriting silently.

### Expected pre-change result

Both paths are absent on the planning base.

### Minimal implementation

1. Copy this approved plan **verbatim in substance** to the plan path. Formatting-only adaptation to repository Markdown convention is allowed; scope/outcome/tasks/commands/stop conditions MUST NOT be weakened.
2. Create `H-090_STRUCTURAL_HARDENING_ASSESSMENT.md` from Task 1 actual evidence.
3. State explicitly that no extraction cleared all ten criteria.
4. State explicitly that file size was not treated as extraction justification.
5. State explicitly that Tracker/WorkControl naming was reviewed and no rename is justified.
6. State explicitly that CandidateRef/CompletionProof remain bounded V1 concepts.
7. Include the current code-derived RuntimeAttempt state machine, including the nonterminal/no-outgoing `containment_unconfirmed` distinction.
8. Include Authority Fence, TransitionAttempt, Workspace Ownership, SuspensionContext and CompletionProof lifecycle tables.
9. Include H-I19–H-I24 and performance matrices.
10. Do **not** edit governance projection/ledger/current-status docs to self-accept H-090.

### Focused verification

From repository root:

```bash
git diff --check
git diff --name-only
```

Expected `git diff --name-only` set exactly:

```text
docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md
```

Then enforce a source/test negative control:

```bash
test -z "$(git diff --name-only -- elixir/lib elixir/test .github Makefile elixir/Makefile elixir/mix.exs)"
```

Expected: exit 0.

### Expected result

Exactly two documentation files changed; no production, test, workflow, governance-enforcement or authority-source file changed.

### Negative controls

The assessment MUST NOT contain claims that:

- H-090 is accepted;
- H-120A is authorized;
- the implementation agent may merge;
- provider state grants authority;
- TransitionCoordinator is a second lifecycle owner;
- CandidateRef/CompletionProof are generic future-programme abstractions;
- a later Master plan gate is still required under the newer delegation decision.

### Adjacent regression

Re-run one representative suite from each safety cluster after the docs are written:

```bash
cd elixir
mix test test/symphony_elixir/work_control_workflow_lifecycle_test.exs test/symphony_elixir/work_control_assessment_test.exs
mix test test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/transition_attempt_ledger_test.exs
mix test test/symphony_elixir/h080a_authority_fence_characterization_test.exs test/symphony_elixir/suspension_recovery_test.exs
mix test test/symphony_elixir/source_control_candidate_ref_test.exs test/symphony_elixir/rem_h080c_ready_to_merge_review_provenance_test.exs
mix test test/symphony_elixir/orchestrator_plane_epoch_test.exs
```

Expected: all exit 0 with zero failures.

### Performance / concurrency check

Because the diff is documentation-only, verify by diff inspection that no provider reads, SCM reads, GenServer calls, tasks, mailbox handling, graph copying, polling or memory structures changed.

### STOP conditions

STOP if:

- any file outside the two authorized paths changes;
- a doc assertion cannot be tied to current code/test evidence;
- an implementation agent proposes “small cleanup” in production code;
- a production defect becomes apparent;
- current behavior differs from the lifecycle maps in this plan;
- H-120A concepts become necessary.

---

## Task 3 — Exact-candidate verification, signed handoff and one bounded PR

### Objective

Prove the assessment-only candidate is exactly the intended two-file diff, all repository gates remain green, and the resulting PR is ready for a fresh independent reviewer—not for merge.

### Exact files

No new files beyond Task 2. No further substantive edits unless correcting factual evidence inside the two authorized docs.

### Existing functions/modules

No runtime function changes.

### Interfaces consumed

Git, Mix, Make, GitHub PR/check state, exact candidate identity.

### Interfaces produced

One signed candidate commit/history, one bounded PR, and implementation handoff fields.

### Lifecycle / invariant impact

None. If verification reveals any runtime/lifecycle delta, the candidate is invalid.

### TEST / CHARACTERIZATION FIRST

Before commit:

```bash
git diff --check
git diff --name-only
cd elixir
mix governance.check
mix format --check-formatted
```

Then execute the focused/adjacent suites from Tasks 1 and 2 as required by the final matrix below.

### Expected pre-change result

All checks pass and only the two authorized docs are dirty.

### Minimal implementation

1. Review the entire diff manually.
2. Confirm the Master Roadmap blob is still `4b0528bdc0647d889b42ebc478081d5b873898fe`.
3. Create a signed commit.
4. Confirm clean worktree after commit.
5. Run final gates on the exact committed HEAD.
6. Open one PR against protected `main`.
7. Never merge.

### Focused verification

From repository root, after the exact signed candidate commit:

```bash
git diff --check origin/main...HEAD

git diff --name-only origin/main...HEAD

git rev-parse HEAD
git rev-parse 'HEAD^{tree}'
git merge-base HEAD origin/main
git status --short

git log --show-signature --format=fuller origin/main..HEAD

git rev-parse 'bbe56c871335d6c7db658c1d37e0b2d1a875ae2f:docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md'
```

The last command MUST return:

```text
4b0528bdc0647d889b42ebc478081d5b873898fe
```

The H-090 freeze selector requires a clean candidate worktree. Run it after the signed candidate commit and clean-status check, not while the two documentation files are uncommitted. A dirty worktree returns `dirty_worktree`.

Run:

```bash
cd elixir
mix governance.check
mix governance.check --freeze --candidate-phase H-090
mix format --check-formatted
cd ..
make -C elixir ci
make -C elixir all
```

Notes:

- `make -C elixir all` already includes the repository isolation-proof target. The selected H-090 seam does **not** introduce a new runtime-isolation change, so no additional H-090-specific isolation proof is required beyond the repository's existing all-gate.
- Do not hide or discard failed/flaky runs. Record every final-gate run used for the handoff.

### Expected result

All required commands exit 0. Worktree is clean. Signed history is verified. Exact diff remains two documentation files.

### Negative controls

After the PR exists:

```bash
# Re-resolve base and candidate; do not rely on pre-PR identity.
git fetch origin
git rev-parse origin/main
git rev-parse 'origin/main^{tree}'
git rev-parse HEAD
git rev-parse 'HEAD^{tree}'
```

STOP if protected main moved. Do not silently rebase or redefine the plan base.

The PR description MUST state:

```text
OUTCOME=ASSESSMENT_ONLY
PRODUCTION_CODE_CHANGED=NO
TEST_CODE_CHANGED=NO
MERGE_AUTHORITY=HUMAN_ONLY
H120A=NOT_AUTHORIZED
MERGE=NOT_PERFORMED
```

### Adjacent regression

No separate late “cleanup” commit is permitted. If evidence text must be corrected after final gates, update only the authorized docs, create a new signed candidate HEAD, and re-run the gates required by the changed candidate.

### Performance / concurrency check

Final diff inspection MUST demonstrate no executable file changed; therefore runtime read/task/mailbox/memory behavior is byte-identical to the accepted base.

### STOP conditions

STOP if:

- main moved;
- any required check fails;
- any unsigned candidate commit exists;
- worktree is dirty after final commit;
- PR contains any file outside the two authorized docs;
- exact candidate changes after reviewer evidence is produced;
- a code/test modification becomes necessary;
- H-120A work becomes necessary.

---

# 11. Final verification matrix

| Requirement | Production seam | Changed file | Test / evidence | Command | Expected result | Failure meaning |
|---|---|---|---|---|---|---|
| Single Orchestrator authority | `Orchestrator.State`, dispatch/runtime/epoch/recovery composition | H-090 assessment doc only | source inspection + Orchestrator regressions | `mix test ...orchestrator_attempt_lineage... ...startup_reconciliation... ...plane_epoch...` | 0 failures; no prod diff | structural ownership assumption invalid; STOP |
| WorkflowLifecycle unchanged | `WorkControl.WorkflowLifecycle` | assessment only | lifecycle suite | `mix test test/symphony_elixir/work_control_workflow_lifecycle_test.exs` | 0 failures | lifecycle law regression/defect; STOP |
| Authority Fence unchanged | `AgentRuntime.AttemptLedger` | assessment only | H080A fence + ledger suites | `mix test ...h080a_authority_fence_characterization... ...attempt_ledger...` | 0 failures | restart/authority safety defect; STOP |
| TransitionAttempt unchanged | TransitionAttempt + Coordinator + ledger | assessment only | coordinator/ledger/freshness | focused commands in Task 1/2 | 0 failures | H-I22 risk; STOP |
| RuntimeAttempt unchanged | `AgentRuntime.RuntimeAttempt` + Orchestrator runtime binding | assessment only | identity + teardown | `mix test ...runtime_attempt_identity... ...runtime_attempt_teardown...` | 0 failures | runtime ownership/containment defect; STOP |
| Workspace ownership unchanged | Ownership + OwnershipLedger | assessment only | ownership suite | `mix test test/symphony_elixir/workspace_ownership_ledger_test.exs` | 0 failures | workspace identity/recovery defect; STOP |
| Suspension semantics unchanged | SuspensionContext/Recovery + AttemptLedger + Orchestrator startup | assessment only | suspension/restart suites | focused recovery command | 0 failures | H-I21 defect; STOP |
| CompletionProof unchanged | CompletionProof + LifecycleAssessment + SourceControl | assessment only | source-control/completion suites | focused source-control command | 0 failures | H-I20/H-I23 defect; STOP |
| CandidateRef remains thin | `SourceControl.CandidateRef` | assessment only | CandidateRef tests + code shape | `mix test test/symphony_elixir/source_control_candidate_ref_test.exs` | 0 failures; still five fields | scope leaked toward Programme B; STOP |
| Tracker/WorkControl reviewed | Tracker adapter boundary vs WorkControl domain | assessment only | code inspection | diff/evidence review | explicit no-rename conclusion | unsupported naming conclusion; correct evidence before PR |
| H-I19 | observation/assessment/disposition/fence | assessment only | Suite A/D representatives | Task 1 focused runs | pass | provider observation may be granting authority; STOP |
| H-I20 | trusted CompletionProof | assessment only | Suite C | Task 1 SCM/completion run | pass | completion trust defect; STOP |
| H-I21 | Symphony-owned suspension | assessment only | Suite D | Task 1 recovery run | pass | suspension ownership defect; STOP |
| H-I22 | no blind ambiguous retry | Coordinator/TransitionAttemptLedger | assessment only | transition + startup tests | Task 1/2 | pass | replay defect; STOP |
| H-I23 | candidate movement invalidates trust | CandidateRef/SourceControl/review provenance | assessment only | candidate/recovery/provenance tests | Task 1 SCM run | pass | stale candidate trust defect; STOP |
| H-I24 | evidence classes distinct | GuardClass + WorkflowLifecycle + source control | assessment only | GuardClass/workflow suites | Task 1 SCM/lifecycle runs | pass | guard class collapse; STOP |
| Provider-read count unchanged | Tracker/Plane | assessment only | executable diff negative control | `git diff --name-only origin/main...HEAD -- elixir/lib` | empty | executable change exceeded outcome |
| SCM-read count unchanged | SourceControl/GitHub | assessment only | executable diff negative control | same | empty | executable change exceeded outcome |
| GenServer blocking unchanged | Orchestrator/Coordinator | assessment only | executable diff negative control | same | empty | concurrency behavior may differ; STOP |
| Task/mailbox behavior unchanged | Orchestrator Plane/runtime tasks | assessment only | executable diff negative control + regressions | same + Orchestrator tests | empty / pass | concurrency behavior may differ; STOP |
| Governance remains valid | governance checker/projection | none | normal/freeze checks | `mix governance.check`; `mix governance.check --freeze --candidate-phase H-090` | PASS | candidate not authorized under current projection; STOP |
| Master Roadmap immutable | normative authority | none | blob check | `git rev-parse '<base>:docs/.../V4_1_MASTER_ROADMAP.md'` | pinned blob | authority changed; STOP |
| Repository full gate | all | docs only | CI/all | `make -C elixir ci`; `make -C elixir all` | exit 0 | candidate not review-ready |

---

# 12. Explicit rejected alternatives

## 12.1 “Orchestrator is large, split it”

Rejected. Size is inspection evidence, not proof that mutable authority should move. The current file coordinates multiple already-separated policy/durability/side-effect seams. A structural split that passes `%Orchestrator.State{}` wholesale would be cosmetic; a split that owns a mutable subset would risk duplicate authority.

## 12.2 New recovery coordinator process

Rejected. Recovery crosses live runtime state, attempt fence, checkpoint, suspension and workspace ownership. A second process would need duplicated/current-state synchronization and could become a second recovery authority.

## 12.3 New Plane epoch process

Rejected. `ReadScheduler` already owns provider-read scheduling while Orchestrator owns epoch acceptance. Another process would create ambiguous control ownership or state mirroring.

## 12.4 Tracker rename

Rejected. Current name accurately denotes the provider adapter/tool boundary. WorkControl already names the canonical provider-neutral lifecycle/authority domain. Broad rename is churn without a correctness fix.

## 12.5 CandidateRef / CompletionProof generalization

Rejected. The current concepts are intentionally thin V1 safety primitives. General execution/evidence/candidate architecture belongs to later programmes, not H-090.

## 12.6 Pure helper extraction

Rejected. No inspected helper group yielded a concrete authority/correctness/security benefit sufficient to justify a new module/API. Do not use H-090 to tidy file organization.

---

# 13. Production-defect rule

If implementation-time characterization discovers an accepted-production defect:

```text
STOP
PRESERVE_REPRODUCER
DO_NOT_FIX_AS_H090_REFACTOR
REPORT_EXACT_FINDING
REQUEST_SEPARATE_BOUNDED_REMEDIATION
```

Do not weaken tests, alter the plan outcome, or hide a behavior fix inside the assessment candidate.

---

# 14. Copy/paste implementation execution contract

```text
You are the H-090 IMPLEMENTATION agent for JCSchoeman96/symphony.

Authority:
DECISION_REF=MG-2026-10-17-H090-WORKFLOW-DELEGATION-01
PHASE=H-090
OUTCOME=ASSESSMENT_ONLY
BASE_SHA=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
BASE_TREE=82c2874845ba4f3201bb85e50e6384024417f58b
PLAN_PATH=docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
MERGE_AUTHORITY=HUMAN_ONLY
H120A=NOT_AUTHORIZED

The Planner verdict directly authorizes implementation only inside this exact plan.
There is no separate Master plan-review gate.

Use a fresh worktree from the exact planning base.
Execute tasks in order.
Use the smallest implementation.
Do not redesign.
Do not broaden H-090.
Do not create a second authority owner.
Do not modify production or test code for this ASSESSMENT_ONLY outcome.
Do not skip task-local verification.
Do not hide failed/flaky runs.
Do not use arbitrary sleeps.
Do not fix unrelated production defects.
If a production defect is found: preserve the reproducer, STOP, and request a separate bounded remediation.
Review the entire diff.
Use signed commits.
Require a clean final worktree.
Open one bounded PR.
Never merge.

Authorized candidate paths only:
- docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
- docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md

Required implementation handoff:

BASE_SHA=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
BASE_TREE=82c2874845ba4f3201bb85e50e6384024417f58b
PLAN_PATH=docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
OUTCOME=ASSESSMENT_ONLY

HEAD_SHA=<exact 40-char candidate SHA>
HEAD_TREE=<exact candidate tree>

SYNTHETIC_MERGE=<exact GitHub synthetic merge SHA>
SYNTHETIC_TREE=<exact synthetic merge tree>

CHANGED_FILES=
- docs/superpowers/plans/2026-10-17-h090-structural-hardening.md
- docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md

FOCUSED_TESTS=<commands + exact counts/seeds/results>
ADJACENT_TESTS=<commands + exact counts/seeds/results>
MAKE_CI=<run/result>
MAKE_ALL=<run/result>
GOVERNANCE_CHECK=PASS
H090_FREEZE=PASS

SIGNED_HISTORY=<verification output/summary>
WORKTREE=CLEAN

PR=<URL/number>
MERGE=NOT_PERFORMED

Do not request H-120A authorization from this candidate.
Hand the exact candidate to a FRESH_REVIEWER next.
```

---

# 15. Required implementation-agent PR evidence

The implementation agent MUST make the PR description independently reviewable. Include:

```text
BASE_SHA
BASE_TREE
PLAN_PATH
OUTCOME=ASSESSMENT_ONLY
PRODUCTION_CODE_CHANGED=NO
TEST_CODE_CHANGED=NO
HEAD_SHA
HEAD_TREE
SYNTHETIC_MERGE
SYNTHETIC_TREE
CHANGED_FILES
FOCUSED_TESTS
ADJACENT_TESTS
MAKE_CI
MAKE_ALL
GOVERNANCE_CHECK
H090_FREEZE
SIGNED_HISTORY
WORKTREE=CLEAN
MERGE=NOT_PERFORMED
H120A=NOT_AUTHORIZED
```

The PR MUST NOT claim H-090 accepted. Acceptance occurs only after fresh review, Master Final Gate, human merge, post-merge verification and the relevant governance decision/materialization.

---

# 16. Planner final report

```text
BASE_SHA=bbe56c871335d6c7db658c1d37e0b2d1a875ae2f
BASE_TREE=82c2874845ba4f3201bb85e50e6384024417f58b

POST_MERGE_RUN_39046187708=SUCCESS

GOVERNANCE_CHECK=PASS
H090_FREEZE_CHECK=PASS

PLAN_PATH=docs/superpowers/plans/2026-10-17-h090-structural-hardening.md

STRUCTURAL_ASSESSMENT_COMPLETE=YES
DOMAIN_MAP_COMPLETE=YES
LIFECYCLE_PRESERVATION_MAPPED=YES
H_I19_H_I24_MAPPED=YES
TRACKER_WORKCONTROL_REVIEW=COMPLETE
CANDIDATEREF_COMPLETIONPROOF_REVIEW=COMPLETE

OUTCOME=ASSESSMENT_ONLY

EXPECTED_CHANGED_FILES=docs/superpowers/plans/2026-10-17-h090-structural-hardening.md,docs/symphony-hardening-playbook-v4.1/H-090_STRUCTURAL_HARDENING_ASSESSMENT.md

TASK_LOCAL_VERIFICATION_COMPLETE=YES
FINAL_VERIFICATION_MATRIX_COMPLETE=YES
IMPLEMENTATION_EXECUTION_CONTRACT_INCLUDED=YES

PLAN_VERDICT=READY FOR IMPLEMENTATION
```

`READY FOR IMPLEMENTATION` directly authorizes the separate implementation agent within this exact plan under `MG-2026-10-17-H090-WORKFLOW-DELEGATION-01`.

Do not send this plan through another Master plan gate. Do not merge the implementation candidate without the required Fresh Reviewer -> Master Final Gate -> Human Merge sequence.
