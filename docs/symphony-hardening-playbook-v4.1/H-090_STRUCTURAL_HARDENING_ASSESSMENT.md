# H-090 structural hardening assessment

## Assessment record

| Field | Value |
|---|---|
| Phase | H-090, Structural Hardening |
| Outcome | ASSESSMENT_ONLY |
| Planning base SHA | bbe56c871335d6c7db658c1d37e0b2d1a875ae2f |
| Planning base tree | 82c2874845ba4f3201bb85e50e6384024417f58b |
| Master Roadmap blob | 4b0528bdc0647d889b42ebc478081d5b873898fe |
| Post-merge run 39046187708 | SUCCESS |
| Governance check | PASS |
| Planning-base H-090 freeze check | PASS |
| Candidate H-090 freeze gate | PENDING TASK 3 |
| Plan | [H-090 structural hardening implementation-grade plan](../superpowers/plans/2026-10-17-h090-structural-hardening.md) |
| Workflow decision | MG-2026-10-17-H090-WORKFLOW-DELEGATION-01 |
| Merge authority | HUMAN_ONLY |
| H-120A | NOT_AUTHORIZED |

The workflow decision authorizes implementation only within the exact plan after its verdict is READY FOR IMPLEMENTATION. This assessment and plan do not mark H-090 accepted. Human merge authority remains unchanged.

## Finding

The V1 architecture has one mutable orchestration owner in SymphonyElixir.Orchestrator. Policy, durable ledgers, provider reads, source-control verification, workspace ownership, and transition sequencing already sit behind focused subordinate modules.

The reviewed extractions either move mutable authority or duplicate state, or they add a module without a demonstrated correctness or security gain. File length alone does not justify splitting Orchestrator. No candidate extraction meets all ten H-090 extraction criteria.

The bounded result is two documentation files. Production behavior, tests, governance enforcement, provider reads, source-control reads, and runtime coordination remain unchanged.

## Domain and resource map

| Domain or resource | Truth and state owner | Role and authority boundary | Durability |
|---|---|---|---|
| Orchestrator | SymphonyElixir.Orchestrator; one GenServer state aggregate | Composes dispatch, live runtime state, recovery, WorkControl projections, Plane epoch acceptance, and task ordering. It does not create provider truth or approve merges. | Coordinates dedicated ledgers; live aggregate is process state. |
| WorkflowLifecycle | WorkControl.WorkflowLifecycle | Pure, provider-neutral lifecycle law and guard requirements. It does not mutate providers or persist state. | Code. |
| LifecycleAssessment | WorkControl.LifecycleAssessment | Interprets one provider observation with prior validated state and trusted evidence. An observation alone grants no authority. | Held by its owning WorkControl or recovery path. |
| AuthorityDisposition | WorkControl.AuthorityDisposition | Derives local none, eligible, active, suspended, or escalated status. It does not mutate provider state. | Held by its owning state or checkpoint. |
| CompletionProof | WorkControl.CompletionProof and SourceControl verification | Bounded V1 proof stages bind exact candidate, review provenance, merge verification, and provider closure. It does not approve a merge. | Typed evidence in existing checkpoints. |
| RecoveryLedger | WorkControl.RecoveryLedger | Persists validated WorkControl and recovery checkpoints. It is not a scheduler or lifecycle authority. | Disk-backed ledger. |
| SuspensionContext and SuspensionRecovery | WorkControl suspension values and recovery path | Preserve Symphony-owned suspension and require fresh trusted reconciliation before resume. Provider state cannot release suspension. | Recovery and attempt ledger paths. |
| TransitionCoordinator and TransitionAttempt | TransitionCoordinator, TransitionAttemptLedger | Sequence an already-authorized intent, durable submit fence, one provider mutation, and fresh verification. Lifecycle policy remains with WorkControl and Orchestrator. | TransitionAttemptLedger. |
| Dependency Graph, Guard, and Policy | Dependency modules; Orchestrator holds the current epoch graph | Normalize provider reads and evaluate dependency policy. These modules do not own scheduling or dispatch. | Current graph in Orchestrator state. |
| Router, Route, and Profile | AgentRuntime routing and profile policy | Select responsibility and runtime profile for a validated WorkItem. They do not create lifecycle authority. | Code and configuration. |
| RuntimeAttempt | AgentRuntime.RuntimeAttempt value; Orchestrator running map owns live authority | Binds one runtime attempt to work item, lineage, responsibility, and profile. It does not persist retry or fence truth. | AttemptLedger preserves durable safety facts. |
| AttemptLedger and authority fence | AgentRuntime.AttemptLedger | Preserves attempt lineage, exhaustion, and fence facts so restart cannot recreate spent authority. | Synchronized durable ledger. |
| Tracker | SymphonyElixir.Tracker adapter boundary | Provides issue-tracker reads and bounded provider-native tools. It does not define canonical lifecycle truth or local authority. | Provider-owned remote state. |
| Plane readers and webhooks | Plane read components | Schedule provider reads and translate or deduplicate signals. They do not decide whether an epoch is current for dispatch. | Bounded read and deduplication state where defined. |
| Orchestrator Plane epoch | SymphonyElixir.Orchestrator | Owns accepted epoch identity and whether the snapshot and graph can influence coordination. | Process state; restart acquires a fresh epoch. |
| SourceControl | SymphonyElixir.SourceControl | Verifies exact candidate, checks, review provenance, and merge facts. It does not merge or grant lifecycle authority. | Typed verification values and existing evidence checkpoints. |
| CandidateRef | SourceControl.CandidateRef | Thin five-field identity for repository, base SHA, candidate SHA, PR, and observed PR head. It is not a generic Candidate domain. | Embedded in evidence. |
| Workspace ownership | Workspace.Ownership and OwnershipLedger | Enforces identity-bound workspace ownership and release. Filesystem existence alone does not prove ownership. | Durable OwnershipLedger plus workspace effects. |
| Runtime adapter and isolation boundary | Host runtime adapter under Symphony policy | Executes an already-authorized responsibility. It does not approve provider transitions, reviews, merges, or recovery. | Runtime process state; no independent authority store. |

## Lifecycle preservation map

### WorkflowLifecycle

States: backlog, planning, ready, in_progress, in_review, changes_requested, ready_to_merge, merging, blocked, done, canceled.

| Transition | Required guard classes |
|---|---|
| backlog to planning | HumanDecision(:planning_started) |
| planning to ready | SemanticAttestation(:plan_attested); MechanicalGuard(:planning_requirements_verified) |
| ready to in_progress | MechanicalGuard(:dispatch_guard) |
| in_progress to in_review | SemanticAttestation(:implementation_attested); MechanicalGuard(:implementation_checks_verified); MechanicalGuard(:candidate_state_verified) |
| in_review to changes_requested | SemanticAttestation(:review_changes_requested) |
| changes_requested to in_review | SemanticAttestation(:correction_attested); MechanicalGuard(:correction_checks_verified); MechanicalGuard(:candidate_state_verified) |
| in_review to ready_to_merge | MechanicalGuard(:review_acceptance_verified); SemanticAttestation(:review_accepted) |
| ready_to_merge to merging | HumanDecision(:merge_approved); MechanicalGuard(:merge_guard_verified) |
| merging to done | MechanicalGuard(:completion_merge_verified) |
| Any nonterminal state to canceled | HumanDecision(:cancellation_authorized) |

Same-state and unlisted transitions fail. Done and canceled are terminal; only done is successful. WorkflowLifecycle is pure policy. The owning state and ledgers recover current work after restart.

### AuthorityDisposition

| From | To | Condition |
|---|---|---|
| none | eligible | Locally validated eligibility |
| eligible | active | Authorized attempt started |
| eligible or active | suspended | Authority-reducing, validation-required, or invalid condition |
| suspended | eligible or active | Fresh reconciliation and canonical resume target; active also requires attempt_started |
| suspended | escalated | Human decision |

Escalated is terminal. Canceled work cannot be reactivated. Provider observations do not recreate authority.

### Authority Fence

| State | Allowed next state | Guard |
|---|---|---|
| ARMED | BOUND or RELEASED | Bind exact RuntimeAttempt, or safely release an unused reservation. |
| BOUND | SUSPENSION_PENDING or RELEASED | Match exact RuntimeAttempt and suspension intent, or release that exact bound identity. |
| SUSPENSION_PENDING | RELEASED | Match the terminal SuspensionContext correlation. |
| RELEASED | None | Terminal for this fence instance. |
| LEGACY_AMBIGUOUS | None | Unresolved compatibility state; never auto-promote. |

The AttemptLedger writes and syncs fence changes. An unresolved fence keeps in_flight protected. Identity mismatch, invalid transition, or ledger failure closes the path.

### TransitionAttempt

| Current state | Legal next state(s) | Boundary or guard |
|---|---|---|
| `requested` | `intent_authorized`, `rejected` | Rejection is allowed before intent authorization. |
| `intent_authorized` | `fresh_context_loaded`, `rejected`, `conflict`, `provider_failed` | Fresh provider context must be loaded before preparation. |
| `fresh_context_loaded` | `prepared`, `rejected`, `conflict`, `provider_failed` | Preparation follows fresh context validation. |
| `prepared` | `mutation_submitted`, `rejected`, `conflict`, `provider_failed` | The durable submit fence may be armed here while state remains `prepared`. |
| `mutation_submitted` | `verifying`, `conflict`, `provider_failed`, `indeterminate` | A provider mutation may have occurred; `rejected` is not legal. |
| `verifying` | `verified`, `conflict`, `provider_failed`, `indeterminate` | Fresh verification selects the outcome; `rejected` is not a verification result. |
| `verified`, `rejected`, `conflict`, `provider_failed`, `indeterminate` | None | Terminal states. |

Before the provider call, the coordinator persists and syncs `submission_fenced_at` while the attempt remains `prepared`. `submit_once` then advances `mutation_submitted` in memory and invokes the provider. The durable fence is the no-blind-resubmit boundary. Restart reconciliation treats a fenced attempt as a possible submission even without provider acknowledgement and does not retry it blindly. `rejected` is legal only from `requested`, `intent_authorized`, `fresh_context_loaded`, or `prepared`; it is not legal from `mutation_submitted` or `verifying`. Evidence-backed verification accepts only `verified`, `conflict`, `provider_failed`, or `indeterminate`, so post-submission uncertainty cannot be converted into a clean rejection.

### RuntimeAttempt

Identity fields: runtime_attempt_id, work_item_id, lineage_generation, responsibility, runtime_profile.

State transitions from the accepted code:

| State | Allowed next states |
|---|---|
| queued | starting |
| starting | running, stopping, retry_queued, blocked, failed, cancelled |
| running | stopping, completed, retry_queued, blocked, failed, cancelled |
| stopping | containment_unconfirmed, containment_proven_dead |
| containment_proven_dead | running, completed, retry_queued, blocked, failed, cancelled |
| containment_unconfirmed | None |
| completed, retry_queued, blocked, failed, cancelled | None |

containment_unconfirmed intentionally has no outgoing transition and is not included in terminal?/1. This distinction is part of the accepted runtime law and must remain unchanged. RuntimeAttempt values do not persist independent authority; the AttemptLedger retains durable fence and lineage safety.

### Workspace Ownership

States: reserved, provisioning, owned, release_pending, released.

Allowed transitions: reserved to provisioning; provisioning to owned or release_pending; owned to release_pending; release_pending to owned or released; released has no outgoing transition.

Transitions require exact project, tracker, work item, workspace, host, root, and filesystem identity. Only proven identity-bound recovery can return release_pending to owned. Directory existence alone is not ownership evidence.

### SuspensionContext

State path: open to resolving to resolved or escalated. Resolved and escalated are terminal.

Resolution requires fresh reconciliation, a trusted canonical resume target, required evidence, matching work-item identity, and exact suspension/lineage correlation where carried by durable recovery. Missing evidence or stale identity fails closed. Suspension remains Symphony-owned across restart.

### CompletionProof V1

Stages: merge_authorized to merge_verified to completed.

Each applicable stage binds the work item, provider project fingerprint, workspace/project, exact five-field CandidateRef, candidate tree SHA, policy fingerprint, candidate verification, and signed independent review provenance with Reviewer responsibility, runtime attempt, lineage, and time.

merge_authorized requires MechanicalGuard(:merge_guard_verified). merge_verified requires MechanicalGuard(:completion_merge_verified) and actual source-control merge verification. completed requires MechanicalGuard(:completion_proof_verified), a fresh post-merge provider observation, exact contract and identity match, and canonical done mapping.

Candidate movement, policy or check movement, review provenance mismatch, missing merge verification, or stale provider closure invalidates downstream trust. Evidence is revalidated after restart. Human approval remains required for merge.

### Plane epoch

| Current status | Possible next status | Trigger or meaning |
|---|---|---|
| `unavailable` | `refreshing` | Startup or a dispatch/reconciliation path requests an epoch acquisition. |
| `refreshing` | `current` | A complete snapshot and graph pass the current-epoch checks. |
| `refreshing` | `failed` | Acquisition, task start, cancellation, or fingerprint validation fails. |
| `current` | `refreshing` | A refresh, dirty-generation follow-up, or reconciliation starts a new acquisition. |
| `current` | `failed` | Cancellation or configuration/contract invalidation makes the accepted epoch unusable. |
| `failed` | `refreshing` | A later dispatch, reconciliation, or refresh needs an epoch and Orchestrator starts a new acquisition when no task is active. |

`failed` is not terminal. A failed epoch remains unusable and dispatch remains fail-closed until a new acquisition succeeds. `plane_epoch_current?/1` requires a matching epoch ID, a complete graph, no active acquisition task, and `plane_epoch_status == :current`. Orchestrator owns reacquisition and epoch acceptance; `Plane.ReadScheduler` owns bounded provider-read scheduling. Restart initializes Orchestrator with `unavailable` and acquires a fresh epoch instead of restoring an old epoch as current. No status is terminal during the live Orchestrator lifecycle.

## Seam assessment

| Seam | Finding | Decision |
|---|---|---|
| A. Orchestrator authority ownership | The shared GenServer aggregate coordinates live WorkItems, runtime and claimed state, Plane epoch, ledgers, dispatch capacity, and task/mailbox ordering. Moving these fields would require a second mutable owner or passing the aggregate wholesale. | Keep one Orchestrator owner. |
| B. Durable attempt, recovery, and startup | AttemptLedger, RecoveryLedger, SuspensionContext/Recovery, and Workspace Ownership already own distinct laws and durable facts. Startup remains cross-resource coordination against live Orchestrator state. | No recovery extraction. |
| C. Plane epoch and reconciliation | ReadScheduler owns read scheduling. Adapters own provider read mechanics. Orchestrator owns epoch acceptance. LifecycleAssessment interprets individual observations. Another epoch process would mirror control state. | Keep current ownership. |
| D. WorkControl and TransitionCoordinator | WorkControl determines lawful transitions. TransitionCoordinator sequences an already-authorized intent, durable fence, provider mutation, and fresh verification. | Keep complementary boundaries. |
| E. Tracker and WorkControl naming | Tracker docs and call boundaries identify provider reads/tools. WorkControl names provider-neutral lifecycle and authority policy. No correctness defect was found; renaming would cause broad caller churn. | No rename. |
| F. CandidateRef and CompletionProof | CandidateRef is the bounded five-field V1 identity. CompletionProof is a three-stage exact-candidate proof chain. Generic candidate/evidence domains are outside H-090. | Keep bounded V1 concepts. |
| G. Pure and diagnostic helpers in Orchestrator | Moving helpers would add a module/API without reducing authority ambiguity or making an invariant easier to enforce. Tests would prove relocation only. | No helper-only extraction. |

## Extraction threshold matrix

Each proposal must pass all ten material criteria: cohesive responsibility, no authority transfer, no duplicate mutable state, unchanged lifecycle law, unchanged fail-closed behavior, unchanged durability and restart behavior, concrete correctness/security gain, independent characterization, narrow typed API, and one bounded change.

| Candidate | Cohesive responsibility | No authority transfer | No mutable copy | Lifecycle and fail-closed preserved | Durable restart preserved | Concrete benefit | Independently characterized | Narrow API | One bounded change | Decision |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| Move durable startup/recovery coordination from Orchestrator | Yes | No, risky | No, risky | Risky | Risky | Unclear | Yes | No without State leakage | No | Reject |
| Create Plane epoch controller | Yes | No, risky | No | Risky | Yes | Unclear | Yes | No without mirrored state | No | Reject |
| Extract Plane fingerprints, metrics, or projections | Yes | Yes | Yes | Yes | Yes | No | Yes | Yes | Yes | Reject, helper churn |
| Rename Tracker or split its name | Partial | Yes | Yes | Yes | Yes | No concrete defect | Yes | No, broad caller churn | No | Reject |
| Generalize CandidateRef/CompletionProof | Yes | No, risky | Risky | Risky | Risky | Not a V1 gain | No | No | No | Reject, future-programme scope |
| Extract observability/status helpers | Yes | Yes | Yes | Yes | Yes | No | Yes | Yes | Yes | Reject, no H-090 gain |

No extraction clears all ten criteria. File size is not a correctness or security benefit.

## H-I19 through H-I24 preservation map

| Invariant | Current enforcement seam | Assessment and evidence |
|---|---|---|
| H-I19. Provider observation cannot grant forward authority | ProviderObservation, LifecycleAssessment, AuthorityDisposition, AttemptLedger fence, Orchestrator routing | Keep observations separate from authority. Baseline provider, lifecycle, assessment, and fence suites pass. No source changes. |
| H-I20. Trusted CompletionProof is required | CompletionProof, LifecycleAssessment.completion_validated?/1, SourceControl merge verification | Keep the exact three-stage proof. Baseline source-control and completion suites pass. |
| H-I21. Suspension remains Symphony-owned | AuthorityDisposition, SuspensionContext, SuspensionRecovery, AttemptLedger, Orchestrator startup | Do not add another recovery/resume owner. Baseline suspension, restart, and fence suites pass. |
| H-I22. Ambiguous provider mutation cannot be blindly retried | TransitionAttempt, TransitionAttemptLedger, TransitionCoordinator | Keep the durable pre-submit fence and reconciliation path. Baseline transition and startup suites pass. |
| H-I23. Candidate movement invalidates candidate-bound trust | CandidateRef, CandidateVerification, SourceControl reconciliation, signed review provenance, CompletionProof | Keep exact candidate identity and evidence binding. Baseline candidate, recovery, and review-provenance suites pass. |
| H-I24. Guard and evidence classes remain distinct | GuardClass, WorkflowLifecycle, host evidence acquisition, CompletionProof | Do not replace HumanDecision, SemanticAttestation, MechanicalGuard, review provenance, and proof with a generic evidence type. Baseline workflow, guard, and source-control suites pass. |

## Performance and scaling matrix

| Measure | Expected H-090 delta | Reason |
|---|---|---|
| Provider-read count | No change | No adapter or runtime change. |
| Source-control read count | No change | No SourceControl change. |
| GenServer blocking | No change | Orchestrator and TransitionCoordinator code stay unchanged. |
| Dependency graph copies | No change | No state or read-path change. |
| Tasks spawned | No change | No task or scheduler change. |
| Mailbox ordering | No change | Orchestrator message handling stays unchanged. |
| Epoch work and stale-work lifetime | No change | Epoch ownership and acceptance stay unchanged. |
| Polling and retained memory | No change | No polling, state, or cache change. |

The accepted V1 envelope remains at most 1,000 items and 5,000 edges. H-090 adds no Redis, Postgres, distributed state, PubSub, cache, scheduler, or persistence layer.

## Verification record

The commands below ran from the untouched planning base before either document was created. Their exact suites are listed in Task 1 of the linked plan.

| Baseline check | Result |
|---|---|
| mix governance.check | PASS |
| mix governance.check --freeze --candidate-phase H-090 | PASS |
| Task 1 characterization group A | 235 tests, 0 failures, seed 254132 |
| Task 1 characterization group B | 113 tests, 0 failures, seed 565688 |
| Task 1 characterization group C | 232 tests, 0 failures, seed 533431 |
| Task 1 characterization group D | 129 tests, 0 failures, seed 166094 |
| Adjacent Orchestrator attempt-lineage, startup-reconciliation, and Plane-epoch suites | 134 tests, 0 failures, seed 994299 |

### Post-documentation checks

| Check | Result |
|---|---|
| WorkflowLifecycle and WorkControl assessment suites, seed 50432 | 32 tests, 0 failures |
| TransitionCoordinator and TransitionAttemptLedger suites, seed 76909 | 78 tests, 0 failures |
| Authority fence and suspension recovery suites, seed 727440 | 41 tests, 0 failures |
| CandidateRef and review provenance suites, seed 627888 | 12 tests, 0 failures |
| Orchestrator Plane epoch suite, seed 898337 | 71 tests, 0 failures |
| mix format --check-formatted | PASS |
| make -C elixir ci | PASS; 90.47% total coverage; dedicated H-070A scaling test passed at 1,000, 5,000, and 10,000 items |
| make -C elixir all | PASS; 90.48% total coverage; runtime-isolation and app-server suites passed with 72 tests, 0 failures |

The full CI and all gates passed after both documents were first created. Final edits only corrected the freeze-check order and Markdown formatting. After those edits, git diff --check and mix governance.check passed. The H-090 freeze check passed on the exact clean planning base before either document was created. A post-documentation freeze attempt returned dirty_worktree because freeze mode requires a clean candidate. Task 3 requires the implementation agent to run that selector on the clean signed candidate. The candidate diff contains only the two authorized Markdown files.

## Scope and final disposition

| Field | Value |
|---|---|
| PRODUCTION_CODE_CHANGED | NO |
| TEST_CODE_CHANGED | NO |
| OUTCOME | ASSESSMENT_ONLY |
| STRUCTURAL_ASSESSMENT_COMPLETE | YES |
| DOMAIN_MAP_COMPLETE | YES |
| LIFECYCLE_PRESERVATION_MAPPED | YES |
| H_I19_H_I24_MAPPED | YES |
| TRACKER_WORKCONTROL_REVIEW | COMPLETE |
| CANDIDATEREF_COMPLETIONPROOF_REVIEW | COMPLETE |
| TASK_LOCAL_VERIFICATION_COMPLETE | YES |
| FINAL_VERIFICATION_MATRIX_COMPLETE | YES |
| IMPLEMENTATION_EXECUTION_CONTRACT_INCLUDED | YES |
| H120A | NOT_AUTHORIZED |
| MERGE | NOT_PERFORMED |
| PLAN_VERDICT | READY FOR IMPLEMENTATION |

The authorized candidate contains only this assessment and the linked plan. Do not edit the Master Roadmap, governance projection, status ledger, enforcement code, production code, tests, or CI workflows. Do not claim H-090 acceptance. Any production defect found during later characterization must be reproduced and reported for separate remediation.
