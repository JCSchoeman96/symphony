# Symphony V4.1
## Hardened Autonomous Engineering Control Plane
### Final Architecture Authority Candidate, Roadmap & Development Specification

**Status:** Final architecture authority candidate — supersedes V4 when committed as governing documentation  
**Version:** V4.1  
**Baseline date:** 2026-09-15  
**Repository:** `JCSchoeman96/symphony`  
**Current accepted `main`:** `46cb22e33dc87729f56f1c07158992c63a84ac27`  
**Current accepted tree:** `683a27711e56830146328406db331754e6ad08d6`

---

# 1. Document Authority

This specification supersedes **Symphony V4** as the proposed governing architecture and supersedes the **future execution roadmap after H-030** once V4.1 is committed as authority documentation.

It does **not** rewrite previously accepted hardening history.

The following phases remain immutable accepted authority:

```text
H-010  Critical Test Authority             ACCEPTED
H-020  Provider Capability Contract        ACCEPTED
H-030  Durable Attempt Lineage             ACCEPTED
```

The accepted H-030 merge baseline remains:

```text
commit:
46cb22e33dc87729f56f1c07158992c63a84ac27

tree:
683a27711e56830146328406db331754e6ad08d6

parent:
8891ee624a39b99d384ec078eb73558ab4730a04
```

P-000 Plane Provider Feasibility is also accepted as architecture evidence. It established that Plane is a viable primary work-control provider under the accepted H-020 routed-provider contract, subject to explicit constraints:

```text
dependency graph completeness
= supported, with O(N) relation-read cost

conditional_transition
= unsupported

provider mutation response
= not authoritative transition proof

fresh provider reread
= mandatory after transition mutation
```

V4.1 begins at the architectural pivot immediately following H-030.

The architectural decision is:

> **Plane replaces Linear as the primary work-control provider, while Symphony remains the autonomous engineering authority kernel.**

The V4.1 hardening amendment adds five safety clarifications that are now part of the architecture:

1. provider-observed state is not automatically validated lifecycle authority;
2. automation suspension is a Symphony-owned authority state and does not depend on Plane successfully moving to `Blocked`;
3. V1 runtime identity is explicitly separated from durable retry lineage and future first-class `Execution`;
4. exact candidate binding is represented by a thin V1 `CandidateRef`;
5. successful `Done` requires lifecycle completion proof, including exact-candidate merge verification where source changes are involved.

Plane must therefore be integrated through a provider-neutral work-control domain rather than being shaped into a Linear compatibility layer or treated as Symphony's authority source.

---

# 2. Executive Product Thesis

The long-term product is:

> **Symphony is an autonomous engineering control plane.**

It is not:

- a ticket runner;
- a Plane automation;
- a GitHub bot;
- a generic agent launcher;
- a second project-management system;
- a distributed workflow engine.

Its responsibility is to determine:

```text
May autonomous engineering work execute?
Who owns that responsibility?
What authority does that responsibility possess?
Are dependencies complete and satisfied?
Is provider configuration trustworthy?
Is retry authority still available?
Is the execution current?
Is the candidate current?
Does the evidence apply to that candidate?
May the next side effect occur?
Must automation stop and escalate?
```

The mature boundary is:

```text
Plane
  = structured engineering intent

Repository Law
  = technical requirements and invariants

Symphony
  = autonomous authority

Execution Runtime
  = computation

GitHub
  = source-control / PR / CI evidence

Evidence
  = candidate acceptance basis

Humans
  = unresolved-decision authority
```

---

# 3. Ultimate Long-Term Goal

The desired mature system is:

```text
                         PLANE
                Human work-control surface
                         │
                  REST + webhooks
                         │
                         ▼
              Work Control Boundary
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│                SYMPHONY AUTHORITY KERNEL            │
│                                                     │
│  WorkflowLifecycle                                  │
│  CapabilityPolicy                                   │
│  DependencyPolicy                                   │
│  AttemptPolicy                                      │
│  RuntimeAuthority                                   │
│  ProviderProjectContract                            │
│  Reconciliation                                     │
│  Escalation                                         │
│                                                     │
│  Later:                                             │
│  Execution                                          │
│  Candidate                                          │
│  EvidenceBundle                                     │
└───────────────────┬───────────────────────┬─────────┘
                    │                       │
                    ▼                       ▼
         Source Control Boundary     Execution Runtime
                 GitHub                Codex Local
                    │                       │
                    │                Later supervisors
                    │
                    └───────────────┬───────┘
                                    ▼
                              Candidate SHA
                                    │
                                    ▼
                           Independent Review
                                    │
                                    ▼
                              Evidence Bundle
```

---

# 4. Backward Planning

Work backwards from the mature system.

## 4.1 Mature outcome requirements

To safely operate the final system, Symphony requires:

1. provider-neutral work-control semantics;
2. canonical lifecycle authority;
3. explicit separation between provider observation and validated lifecycle state;
4. Symphony-owned authority disposition and reason-specific suspension recovery;
5. stable provider identity;
6. configuration-drift detection;
7. complete dependency interpretation;
8. deterministic provider transition handling;
9. runtime capability/authority separation;
10. source-control authority separated from work-control authority;
11. thin exact-candidate identity in V1;
12. durable autonomous safety state;
13. restart reconciliation;
14. workspace ownership;
15. provider rate-limit and graph-performance controls;
16. mechanical security boundaries;
17. exact candidate/evidence identity;
18. verified completion before dependency satisfaction;
19. escalation;
20. supervised internal execution;
21. transport-independent execution events;
22. distributed execution only if measurements justify it.

## 4.2 Required dependency order

```text
Provider-neutral domain
        ↓
Canonical lifecycle + guard taxonomy
        ↓
ProviderObservation / LifecycleAssessment
        ↓
Symphony AuthorityDisposition
        ↓
Plane configuration contract
        ↓
Plane read provider
        ↓
Complete dependency graph
        ↓
Safe transitions
        ↓
Bounded provider tools
        ↓
Source-control boundary + CandidateRef
        ↓
Recovery / suspension reconciliation
        ↓
Performance + webhooks
        ↓
Security hardening
        ↓
Structural review
        ↓
Governance freeze
        ↓
Real lifecycle proof through verified Done
        ↓
Failure / restart soak
        ↓
V1 acceptance
        ↓
Execution / Candidate / Evidence
        ↓
Supervisor / subagents
        ↓
Runtime expansion
        ↓
Distribution only if measured need exists
```

## 4.3 V1 smallest viable end-state

The hardened V1 is complete when:

```text
Plane
 ↓
trusted Work Control adapter
 ↓
ProviderObservation
 ↓
canonical LifecycleAssessment
 ↓
Symphony AuthorityDisposition
 ↓
complete dependency policy
 ↓
single authoritative Orchestrator
 ↓
role-bounded Codex execution
 ↓
CandidateRef + GitHub PR / CI evidence
 ↓
independent review
 ↓
human exact-candidate merge
 ↓
trusted merge verification
 ↓
validated Done
```

can survive:

- restart;
- provider failure;
- partial provider response;
- stale provider mutation result;
- manual/external provider state changes;
- invalid forward provider transitions;
- dependency cancellation;
- retry exhaustion;
- authority suspension and reason-specific recovery;
- configuration drift;
- workspace recovery;
- stale runtime events;
- candidate movement after review;
- ambiguous provider mutation outcome;
- adversarial agent output.

V1 does **not** require the full Programme B `Execution`, `Candidate`, or `EvidenceBundle` persistence model. It does require enough typed identity to prevent exact-candidate safety from being represented as unrelated strings and maps.

---

# 5. Architectural Doctrine

## 5.1 Plane expresses intent and observation

Plane owns:

- human-visible work items;
- project organization;
- human-facing lifecycle projection;
- dependencies and relations;
- priorities;
- human approvals where used;
- human-facing operational status.

Plane also tells Symphony what the provider currently says.

Plane does **not** decide whether autonomous authority exists, whether a forward lifecycle transition is valid, or whether `Done` is dependency-satisfying.

## 5.2 Symphony grants and revokes authority

Symphony owns:

- dispatchability;
- validated lifecycle interpretation;
- responsibility routing;
- retry budgets;
- execution fences;
- dependency policy;
- transition policy;
- runtime authority;
- provider completeness evaluation;
- authority suspension;
- reconciliation;
- escalation;
- candidate/evidence validity.

An external provider observation may safely reduce, suspend, or revoke autonomous authority. It may not silently create new autonomous authority or successful completion.

## 5.3 GitHub owns source-control facts

GitHub owns:

- repository commits;
- branches;
- pull requests;
- exact PR HEAD;
- CI/check state;
- merge result.

Plane must never become the source of truth for candidate SHA, CI, or merge completion.

## 5.4 Runtime performs computation

Codex may:

- inspect authorized context;
- modify an authorized workspace;
- run authorized tests;
- produce candidate work.

Codex may not self-grant:

- provider transition authority;
- merge authority;
- reviewer acceptance;
- additional capabilities;
- recovery from suspension;
- lineage rearm.

## 5.5 Evidence decides candidate acceptability

Agent statements such as:

```text
tests passed
```

are not evidence.

Trusted machine-observed facts are evidence.

Semantic attestations by Planner/Reviewer are valid policy inputs only within their explicitly granted responsibility; they are not interchangeable with machine-observed facts.

## 5.6 Observation, lifecycle and authority are different questions

For every automation-relevant work item Symphony must be able to answer three separate questions:

```text
What does Plane currently say?
        = ProviderObservation

What lifecycle state has Symphony validated under canonical law?
        = LifecycleAssessment / validated lifecycle state

May autonomous execution act now?
        = AuthorityDisposition
```

These are related but are not interchangeable.

Example:

```text
Plane observation:
Done

Last validated lifecycle state:
In Progress

Lifecycle assessment:
invalid_external_forward_transition

Authority disposition:
Suspended

Dependency result:
NOT satisfied
```

This separation prevents manual provider changes from bypassing review, CI, candidate binding, merge verification, retry policy, or security guards.

---

# 6. Resource / Domain Map

V4.1 introduces or formalizes the following domain resources.

---

## 6.1 WorkItem

Provider-neutral representation of human-facing engineering work.

Conceptually:

```text
WorkItem
├── provider_identity
├── project_scope
├── provider_observation
├── lifecycle_assessment
├── authority_disposition
├── parent
├── dependencies
├── relations
├── provider_snapshot_metadata
└── human_intent_metadata
```

For V1, avoid prematurely adding every Plane property.

### Invariants

- Provider ID is stable and authoritative.
- Display names are descriptive, not primary identity.
- Unknown provider state mapping fails closed.
- Provider observation is preserved truthfully even when it is not accepted as a valid lifecycle advance.
- Canceled is not successful.
- Provider work-item state does not itself grant autonomous execution.
- Dependency satisfaction uses validated lifecycle/completion semantics, not raw provider state.

---

## 6.2 ProviderObservation

A factual representation of what the provider currently reports.

```text
ProviderObservation
├── provider
├── workspace_id
├── project_id
├── work_item_id
├── provider_state_id
├── provider_state_group
├── provider_updated_at
├── observed_at
└── snapshot_identity
```

ProviderObservation is not a second authority source.

It is evidence used by lifecycle reconciliation.

### Lifecycle

```text
Absent
 ↓
Observed
 ↓
SupersededByNewObservation
```

`Observed` is immutable for a given observation identity.

Terminal for that observation instance:

```text
SupersededByNewObservation
```

Side effect:

- trigger or participate in lifecycle assessment.

---

## 6.3 WorkflowLifecycle

Single canonical lifecycle authority.

Responsibilities:

```text
WorkflowLifecycle
├── canonical states
├── state classifications
├── dispatchability
├── responsibility ownership
├── permitted transitions
├── guard classes
├── transition guards
├── transition side effects
├── terminal outcomes
└── provider mapping contract
```

Router, TransitionPolicy and dependency rules consume this lifecycle.

No provider may define Symphony lifecycle semantics implicitly.

---

## 6.4 GuardClass

V1 explicitly distinguishes three guard classes.

### MechanicalGuard

Machine-verifiable facts.

Examples:

```text
provider contract valid
dependency graph complete
dependencies satisfied
retry budget available
candidate SHA matches
CI green
merge SHA verified
```

### SemanticAttestation

A bounded responsibility makes a semantic judgment within its authority.

Examples:

```text
objective is bounded
architecture ambiguity absent
implementation meets requested objective
review verdict
```

Every semantic attestation must identify at minimum:

```text
responsibility
runtime_attempt_id
lineage_generation
subject work item or CandidateRef
timestamp
```

### HumanDecision

Authority intentionally reserved to a human/operator.

Examples:

```text
rearm exhausted lineage
resolve severe security ambiguity
approve an irreversible architecture choice
authorize exceptional recovery
```

These guard classes are not evidentially equivalent.

---

## 6.5 LifecycleAssessment

Symphony's evaluation of the latest provider observation against canonical lifecycle law.

Conceptually:

```text
LifecycleAssessment
├── work_item_id
├── provider_observation
├── last_validated_state
├── observed_mapped_state
├── assessment_status
├── required_guards
├── satisfied_guards
├── missing_guards
└── assessed_at
```

### Assessment states

```text
Unassessed
 ↓
MappingResolved
 ├── Validated
 ├── AuthorityReducing
 ├── ValidationRequired
 └── Invalid
```

#### Validated

The observed state is compatible with canonical lifecycle law and all required guards are satisfied.

Side effects:

- validated lifecycle state may advance;
- authority policy may reevaluate.

#### AuthorityReducing

The observation safely removes or constrains authority, such as a human cancellation or a trusted Blocked projection.

Side effects:

- immediately suspend/revoke relevant authority;
- reconcile canonical lifecycle according to policy.

#### ValidationRequired

The provider observation appears to be a forward/promotional state change that cannot grant authority by observation alone.

Examples:

```text
Planning → Ready
In Progress → In Review
In Review → Ready to Merge
Merging → Done
```

Side effects:

- do not grant authority;
- open/sustain suspension when the provider and validated lifecycle diverge in a safety-relevant way;
- require canonical transition proof or operator resolution.

#### Invalid

Unknown mapping, impossible transition, provider drift, or contradictory state semantics.

Side effects:

- fail closed;
- suspend or escalate.

Terminal states for one assessment instance:

```text
Validated
AuthorityReducing
ValidationRequired
Invalid
```

A newer provider observation creates a new assessment.

---

## 6.6 AuthorityDisposition

Symphony-owned statement of whether automation may act.

This is deliberately separate from Plane workflow state.

```text
AuthorityDisposition
├── None
├── Eligible
├── Active
├── Suspended
└── Escalated
```

### Transitions

```text
None → Eligible
```

Guard:

- lifecycle/policy makes an autonomous responsibility eligible.

```text
Eligible → Active
```

Guard:

- runtime authority granted and bounded attempt started.

```text
Eligible/Active → Suspended
```

Causes include:

- dependency invalidation;
- provider indeterminate outcome;
- configuration drift;
- retry exhaustion;
- runtime unavailable;
- security failure;
- lifecycle observation requires validation;
- repository/candidate conflict.

Side effects:

- stop new side effects;
- preserve state/evidence/workspace as policy requires;
- create or update SuspensionContext.

```text
Suspended → Eligible/Active
```

Guard:

- reason-specific recovery policy passes;
- fresh reconciliation completed;
- resume target is validated.

```text
Suspended → Escalated
```

Guard:

- automatic recovery not authorized or safety condition requires human decision.

Terminality:

- `Escalated` is terminal for autonomous recovery until a separate trusted human/operator action establishes a new disposition.
- `None` is not a lifecycle terminal; it means no autonomous authority is presently applicable.

---

## 6.7 SuspensionContext

Trusted recovery record for a suspended authority disposition.

```text
SuspensionContext
├── work_item_id
├── last_validated_lifecycle_state
├── provider_observation
├── reason
├── lineage_generation
├── created_at
├── recovery_policy
├── required_evidence
└── resume_target
```

The trusted origin/resume information must not be inferred from mutable display text.

### Lifecycle

```text
Open
 ↓
Resolving
 ├── Resolved
 └── Escalated
```

#### Open → Resolving

Guard:

- required recovery trigger has occurred.

#### Resolving → Resolved

Guard:

- reason-specific recovery requirements pass;
- fresh provider/project/runtime reconciliation succeeds.

Side effects:

- close current suspension context;
- establish validated resume disposition.

#### Resolving → Escalated

Guard:

- automatic recovery is not permitted or required evidence cannot be established.

Terminal:

```text
Resolved
Escalated
```

Examples:

```text
runtime_unavailable
→ may auto-resolve after runtime health + fresh reconciliation

provider_indeterminate
→ requires authoritative reconciliation

provider_configuration_drift
→ requires project-contract revalidation

retry_exhausted
→ requires H-030 host/operator rearm

security_boundary_failed
→ requires explicit human/security resolution
```

Plane `Blocked` is a human-visible projection where appropriate. It is not the sole mechanism that stops automation.

---

## 6.8 ProviderProjectContract

Expected configuration for one controlled work scope.

```text
ProviderProjectContract
├── provider
├── workspace_id
├── project_id
├── state_mappings
├── dependency_relation_semantics
├── required_capabilities
├── optional_capabilities
├── configuration_fingerprint
└── schema/version
```

Later optional additions may include:

```text
work_item_type_ids
property_ids
workflow_ids
custom_relation_ids
```

only when Symphony genuinely depends on them.

---

## 6.9 ProviderSnapshot

An authoritative provider read used for policy decisions.

Properties:

```text
provider
project_scope
work_items
states
dependencies
snapshot_time
completeness
provider_metadata
```

A provider snapshot is accepted only if completeness requirements pass.

It contains observations, not lifecycle grants.

---

## 6.10 DependencyGraph

Immutable graph for one reconciliation epoch.

Only the following Plane relations affect V1 dispatch:

```text
blocked_by
blocking
```

Plane scheduling relations such as:

```text
start_before
start_after
finish_before
finish_after
```

are ignored by V1 dependency policy.

### Epoch lifecycle

```text
Building
 ↓
Validating
 ├── Published
 └── Invalid
      ↓
    terminal

Published
 ↓
Superseded
```

#### Building → Validating

Guards:

- all project work-item pages enumerated;
- all required relation reads completed.

Side effects:

- freeze raw relation set for validation.

#### Validating → Published

Guards:

- completeness proven;
- referenced work items resolved;
- relation semantics valid;
- SCC/cycle analysis completed;
- no required provider read failed.

Side effects:

- publish immutable graph epoch for policy/dispatch reads.

#### Validating → Invalid

Guard:

- any completeness, relation, provider or consistency requirement fails.

Side effects:

- do not expose epoch as dispatch authority;
- suspend affected autonomous decisions where current graph authority is unavailable.

#### Published → Superseded

Guard:

- newer validated graph epoch published.

Side effects:

- old epoch remains immutable for diagnostics/evidence but is no longer current authority.

Terminal states for an epoch:

```text
Invalid
Superseded
```

---

## 6.11 Runtime.Authority

Distinct from provider capability.

```text
ProviderCapability
= what the provider/integration can safely support

RuntimeAuthority
= what the current responsibility may request or do
```

No runtime inherits every provider capability automatically.

Runtime authority may include permission to request a specific semantic lifecycle command. It never means raw Plane mutation authority.

---

## 6.12 AttemptLineage

Already accepted through H-030.

AttemptLineage is the durable safety/retry lineage. It is not a runtime session and is not future Programme B `Execution`.

### Lifecycle

```text
Absent
  ↓
Open
 ├── Closed
 └── Exhausted
       ↓ host/operator rearm
     Rearmed
       ↓
Open(new lineage_generation)
```

#### Absent → Open

Guard:

- trusted Symphony policy creates the first durable lineage for the work/responsibility scope.

Side effects:

- initialize durable retry/review counters and `lineage_generation`;
- sync before any authority depending on the record proceeds.

#### Open → Closed

Guard:

- lineage completes without further retry/review authority being required.

Side effects:

- persist closure and sync;
- reject future attempts under the closed lineage.

#### Open → Exhausted

Guard:

- durable retry/review budget reaches the configured limit.

Side effects:

- persist exhaustion and sync;
- prevent automatic creation of further RuntimeAttempts;
- suspend/escalate according to policy.

#### Exhausted → Rearmed

Guard class:

```text
HumanDecision
```

Guards:

- host/operator explicitly rearms;
- reason/operator/timestamp captured;
- prior evidence/counters remain preserved.

Side effects:

- preserve old lineage history;
- prepare a new lineage generation;
- no deletion/reset of old safety evidence.

#### Rearmed → Open(new lineage_generation)

Guard:

- durable rearm record successfully synced.

Side effects:

- increment/change `lineage_generation`;
- permit new RuntimeAttempt creation subject to all current lifecycle/authority guards.

Terminal for a specific lineage generation:

```text
Closed
Exhausted
```

`Rearmed` creates authority for a new lineage generation; it does not mutate exhausted history into success.

Manual durable-state deletion is never recovery.

Terminology:

```text
lineage_generation
```

is the durable generation changed by explicit lineage rearm.

Do not call unrelated future execution/worker fencing values merely `generation`.

---

## 6.13 RuntimeAttempt

V1 name for one bounded runtime/session attempt.

This replaces the ambiguous V4 term `AgentAttempt`.

A retry creates a **new RuntimeAttempt identity** under the same open AttemptLineage unless the lineage is exhausted. A failed session is never resurrected by reusing its runtime attempt identity.

### Lifecycle

```text
Queued
 ↓
Starting
 ↓
Running
 ├── Completed
 ├── RetryQueued
 ├── Blocked
 ├── Failed
 └── Cancelled
```

### Transition guards and side effects

#### Queued → Starting

Guards:

- current `lineage_generation` matches durable AttemptLineage;
- Runtime.Authority profile is valid;
- AuthorityDisposition permits start;
- workspace/runtime prerequisites are available.

Side effects:

- allocate runtime/session resources;
- bind `runtime_attempt_id` to work item, lineage generation and responsibility.

#### Starting → Running

Guard:

- runtime session successfully starts under required authority restrictions.

Side effects:

- mark attempt active;
- begin accepting identity-bound runtime events.

#### Starting/Running → RetryQueued

Guards:

- failure is classified retryable by AttemptPolicy;
- retry budget remains after durable policy accounting;
- no suspension/escalation condition overrides retry.

Side effects:

- terminate this runtime/session;
- persist retry decision;
- close this RuntimeAttempt identity;
- a **new** RuntimeAttempt may later enter `Queued` under the same `lineage_generation`.

#### Running → Completed

Guard:

- responsibility-specific completion criteria met.

Side effects:

- end runtime authority for this attempt;
- emit bounded semantic result to trusted Symphony boundary.

#### Starting/Running → Blocked

Guard:

- safety/external condition prevents continuation.

Side effects:

- stop runtime side effects;
- close this runtime attempt as blocked;
- preserve state required by SuspensionContext/reconciliation;
- any later resumption uses a new RuntimeAttempt identity after recovery.

#### Starting/Running → Failed

Guard:

- non-retryable runtime failure or retry is not authorized.

Side effects:

- terminate runtime authority;
- feed AttemptPolicy/AuthorityDisposition.

#### Queued/Starting/Running → Cancelled

Guard:

- trusted cancellation/revocation applies.

Side effects:

- terminate runtime/session where present;
- reject subsequent events from the cancelled attempt.

Terminal:

```text
Completed
RetryQueued
Blocked
Failed
Cancelled
```

Identity includes:

```text
runtime_attempt_id
work_item_id
lineage_generation
responsibility
runtime_profile
```

Programme B `Execution` will supersede/generalize RuntimeAttempt rather than become a parallel competing truth.

---

## 6.14 TransitionAttempt

Provider mutation safety state.

```text
Requested
 ↓
IntentAuthorized
 ↓
FreshContextLoaded
 ↓
Prepared
 ↓
MutationSubmitted
 ↓
Verifying
 ├── Verified
 ├── Rejected
 ├── Conflict
 ├── ProviderFailed
 └── Indeterminate
```

`Prepared` must become durable and successfully synced before mutation.

There is no blind mutation retry after `MutationSubmitted`.

### Transition guards and side effects

#### Requested → IntentAuthorized

Guards:

- requesting responsibility has Runtime.Authority for this exact semantic transition;
- canonical WorkflowLifecycle permits the transition in principle.

Side effects:

- bind transition request to work item, runtime attempt/responsibility and requested target state.

#### IntentAuthorized → FreshContextLoaded

Guards:

- fresh provider observation retrieved;
- provider project contract valid.

Side effects:

- run LifecycleAssessment and dependency/authority guards against current truth.

#### FreshContextLoaded → Prepared

Guards:

- all required MechanicalGuards/SemanticAttestations/HumanDecisions satisfied;
- no conflicting suspension blocks the action.

Side effects:

- durably record mutation intent, source/target states, provider observation identity and transition identity;
- `:dets.sync/1` or equivalent durability barrier must succeed.

#### Prepared → MutationSubmitted

Guard:

- durable sync confirmed.

Side effects:

- submit exactly one provider mutation.

#### MutationSubmitted → Verifying

Guard:

- submission returned or may have reached provider.

Side effects:

- perform authoritative fresh provider reread;
- ignore mutation response as final proof.

#### Verifying → Verified

Guards:

- fresh provider state equals configured target identity/group;
- LifecycleAssessment accepts target transition.

Side effects:

- close transition attempt successfully;
- permit dependent lifecycle/authority updates.

#### Any pre-submit state → Rejected

Guard:

- policy/provider explicitly denies the transition and non-commit is established.

Side effects:

- close without provider side effect.

#### Verifying → Conflict

Guard:

- authoritative reread proves incompatible external/provider state won the race.

Side effects:

- close attempt as conflict;
- suspend/reconcile before any new mutation.

#### Pre-submit failure or proven non-commit → ProviderFailed

Guard:

- mutation was not submitted, or authoritative evidence proves it did not commit.

Side effects:

- classify provider failure according to retry/reconciliation policy.

#### MutationSubmitted/Verifying → Indeterminate

Guard:

- mutation may have committed and authoritative truth cannot establish safe outcome.

Side effects:

- persist indeterminate state;
- suspend automation;
- prohibit blind mutation retry;
- require host-side reconciliation/operator resolution.

### Outcome semantics

`Rejected`:

- provider or policy explicitly rejects the requested transition;
- non-commit is established.

`ProviderFailed`:

- failure occurred before mutation submission; or
- authoritative evidence establishes that mutation could not have committed / state remained unchanged.

`Conflict`:

- authoritative reread shows another incompatible state/actor won the race.

`Indeterminate`:

- mutation may have reached Plane and commit cannot be excluded;
- current authoritative truth cannot yet establish a safe outcome.

Rule:

> **If provider commit cannot be excluded, the result is `Indeterminate`, not `ProviderFailed`.**

Terminal states:

```text
Verified
Rejected
Conflict
ProviderFailed
Indeterminate
```

---

## 6.15 ReconciliationAttempt

```text
Requested
 ↓
ProviderConfigurationValidated
 ↓
ProviderReadStarted
 ↓
ProviderSnapshotLoaded
 ↓
SnapshotValidated
 ↓
LifecycleAssessed
 ↓
PoliciesReevaluated
 ↓
Reconciled
```

Failure outcomes:

```text
ConfigurationDrift
ProviderUnavailable
SnapshotIncomplete
ProviderMalformed
SafetyStateUnavailable
LifecycleValidationRequired
```

### Transition guards and side effects

#### Requested → ProviderConfigurationValidated

Guards:

- durable safety state readable;
- configured provider/project identity available.

Side effects:

- validate ProviderProjectContract.

Failure:

- drift → `ConfigurationDrift`;
- safety-state read failure → `SafetyStateUnavailable`.

#### ProviderConfigurationValidated → ProviderReadStarted

Guard:

- project contract valid.

Side effect:

- begin bounded authoritative provider refresh.

#### ProviderReadStarted → ProviderSnapshotLoaded

Guard:

- required provider reads complete.

Failure:

- unavailable transport/provider → `ProviderUnavailable`;
- malformed provider data → `ProviderMalformed`.

#### ProviderSnapshotLoaded → SnapshotValidated

Guards:

- pagination complete;
- dependency/source data complete for required scope;
- project identity matches.

Failure:

- incomplete required data → `SnapshotIncomplete`.

#### SnapshotValidated → LifecycleAssessed

Side effects:

- create/update ProviderObservation instances;
- assess each automation-relevant work item against canonical lifecycle.

Failure:

- safety-sensitive divergence requiring explicit resolution → `LifecycleValidationRequired` while opening/maintaining suspension.

#### LifecycleAssessed → PoliciesReevaluated

Side effects:

- rebuild/choose valid dependency epoch;
- reevaluate AuthorityDisposition, AttemptPolicy and suspension recovery.

#### PoliciesReevaluated → Reconciled

Guard:

- no unresolved condition permits unsafe dispatch.

Side effects:

- publish reconciled current projections;
- only then allow eligible autonomous dispatch.

Terminal success:

```text
Reconciled
```

Failure outcomes are terminal for that reconciliation attempt and require a new attempt after the relevant trigger/recovery.

---

## 6.16 CandidateRef

Thin immutable V1 source-control identity.

It is **not** the Programme B Candidate domain and does not require a Candidate database.

```text
CandidateRef
├── repository_identity
├── base_sha
├── candidate_sha
├── pr_identity
└── observed_pr_head_sha
```

Invariants:

- approval/review is bound to exact `candidate_sha`;
- PR HEAD movement invalidates prior candidate acceptance;
- merge verification must compare GitHub's merged candidate with the approved CandidateRef;
- Plane fields may project CandidateRef for humans but never become its authority source.

CandidateRef is introduced under H-050C.

---

## 6.17 CompletionProof

V1 policy concept for validating successful completion.

It need not become a standalone persistent domain entity.

For code-producing work it must establish, where applicable:

```text
approved CandidateRef exists
required CI/check evidence applies to candidate_sha
independent review applies to candidate_sha
human/external merge occurred
GitHub merged candidate matches approved candidate_sha
provider closure was freshly verified
```

Only after CompletionProof passes may `Done` become validated completion and satisfy downstream dependencies.

---

## 6.18 Escalation

V1 needs a minimal first-class escalation concept.

Suggested reason taxonomy:

```text
provider_configuration_drift
provider_indeterminate
provider_external_transition_invalid
dependency_invalidated
dependency_incomplete
retry_exhausted
authority_ambiguous
security_boundary_failed
runtime_unavailable
repository_state_conflict
candidate_moved
completion_unproven
operator_intervention_required
```

### Lifecycle

```text
Raised
 ↓
Acknowledged
 ↓
UnderHumanResolution
 ├── Resolved
 └── Superseded
```

#### Raised → Acknowledged

Guard:

- trusted host/operator has observed the escalation record.

Side effects:

- preserve all required safety/evidence state;
- keep AuthorityDisposition `Escalated`.

#### Acknowledged → UnderHumanResolution

Guard:

- an authorized human/operator takes responsibility.

Side effects:

- record operator identity and resolution scope;
- no autonomous authority is restored.

#### UnderHumanResolution → Resolved

Guards:

- reason-specific resolution is completed;
- required recovery/revalidation steps succeed.

Side effects:

- close escalation;
- create a new eligible/suspended disposition according to policy;
- never silently reactivate prior runtime authority.

#### UnderHumanResolution → Superseded

Guard:

- escalation is replaced by a newer authoritative escalation/resolution record.

Terminal:

```text
Resolved
Superseded
```

Escalation side effects include:

```text
stop autonomous authority
preserve workspace
preserve safety state
preserve provider evidence
preserve CandidateRef where present
preserve attempt history
record reason
surface human attention
```

Programme B may later promote this minimal record into a richer escalation domain without changing V1 safety semantics.

---

# 7. Canonical WorkItem Lifecycle

Canonical states:

```text
Backlog
Planning
Ready
In Progress
In Review
Changes Requested
Ready to Merge
Merging
Blocked
Done
Canceled
```

The canonical lifecycle describes engineering progress.

`AuthorityDisposition` separately describes whether automation may act.

The provider may report a state that has not yet been accepted as a valid canonical lifecycle advance.

## 7.1 State classifications

| State | Classification | Responsibility |
|---|---|---|
| Backlog | inactive | Human |
| Planning | active | Planner |
| Ready | dispatchable | Builder |
| In Progress | active | Builder |
| In Review | active | Reviewer |
| Changes Requested | active | Fixer |
| Ready to Merge | gated | Merge Gatekeeper / Human merge |
| Merging | active/gated | Merge Gatekeeper verification |
| Blocked | human-visible suspended projection | Human/System |
| Done | terminal success, only when completion validated | None |
| Canceled | terminal invalidated | None |

## 7.2 Transition guard classes

Every canonical transition must declare required guard classes.

Use:

```text
MechanicalGuard
SemanticAttestation
HumanDecision
```

A semantic attestation cannot substitute for a mechanical fact.

A provider observation cannot substitute for either unless policy explicitly defines that external human action as an authority-reducing decision.

## 7.3 Transitions

### Backlog → Planning

Authority: human.

Required guard class:

```text
HumanDecision
```

Guard:

- work is intentionally entering autonomous preparation.

Side effects:

- Planner becomes eligible;
- authority disposition may become `Eligible`.

---

### Planning → Ready

Authority: Planner through trusted semantic lifecycle command.

Required guard classes:

```text
SemanticAttestation
MechanicalGuard where applicable
```

Guards:

- objective bounded;
- repository authority references sufficient;
- architecture ambiguity absent;
- dependencies representable;
- no required human architectural decision outstanding;
- provider/project contract valid.

Side effects:

- validated lifecycle advances to `Ready`;
- Builder may become eligible after dependency/policy reevaluation.

A manual Plane observation of `Ready` does not by itself grant Builder authority.

---

### Ready → In Progress

Authority: Symphony when Builder runtime authority actually begins.

Required guard classes:

```text
MechanicalGuard
```

Guards:

- provider contract valid;
- latest provider observation reconciled;
- dependencies complete;
- dependencies satisfied;
- attempt budget available;
- no current conflicting runtime attempt;
- runtime authority valid.

Side effects:

- create RuntimeAttempt;
- establish workspace authority;
- authority disposition becomes `Active`.

---

### In Progress → In Review

Authority: Builder semantic completion request mediated by Symphony.

Required guard classes:

```text
SemanticAttestation
MechanicalGuard
```

Guards:

- implementation responsibility completed;
- candidate state available;
- required local verification performed;
- CandidateRef established where source changes exist.

Side effects:

- terminate Builder write authority;
- validated lifecycle advances only after controlled provider transition verifies;
- fresh independent Reviewer responsibility required.

A manual Plane observation of `In Review` cannot substitute for Builder completion.

---

### In Review → Changes Requested

Authority: independent Reviewer through trusted semantic lifecycle command.

Required guard class:

```text
SemanticAttestation
```

Guard:

- independent review finds actionable defect.

Side effects:

- Reviewer authority ends;
- Fixer becomes eligible;
- approval for the prior candidate remains rejected/not granted.

---

### Changes Requested → In Review

Authority: Fixer through trusted semantic lifecycle command.

Required guard classes:

```text
SemanticAttestation
MechanicalGuard
```

Guards:

- correction candidate available;
- required local verification completed;
- CandidateRef updated when candidate SHA changed.

Side effects:

- Fixer authority ends;
- new independent review required;
- prior review approval cannot carry across a changed candidate.

---

### In Review → Ready to Merge

Authority: independent Reviewer through trusted semantic lifecycle command.

Required guard classes:

```text
MechanicalGuard
SemanticAttestation
```

Guards:

- exact CandidateRef established;
- required CI/check evidence green for `candidate_sha`;
- independent review accepts that same `candidate_sha`;
- dependencies still satisfied;
- provider contract valid;
- no post-review candidate mutation;
- PR observed head equals CandidateRef candidate SHA.

Side effects:

- review approval becomes bound to exact CandidateRef;
- Merge Gatekeeper/human merge becomes the next responsibility boundary.

A manual Plane observation of `Ready to Merge` cannot establish review acceptance.

---

### Ready to Merge → Merging

V1 merge execution authority remains human-controlled.

The `Merging` lifecycle state is entered only as a trusted projection/verification stage when Symphony has evidence that the approved candidate is undergoing or has undergone external/human merge.

Required guard classes:

```text
HumanDecision
MechanicalGuard
```

V1 does not grant Symphony autonomous merge permission.

---

### Merging → Done

Authority: trusted merge verification and controlled work-control closure.

Required guard classes:

```text
MechanicalGuard
```

Required CompletionProof for code-producing work:

- GitHub confirms the expected PR was merged;
- merged candidate matches the approved CandidateRef `candidate_sha`;
- review/CI evidence still applies to that candidate;
- no post-approval candidate mutation occurred;
- controlled Plane closure to `Done` succeeds;
- fresh Plane reread verifies configured Done UUID and expected `completed` group.

Side effects:

- validated lifecycle becomes `Done`;
- authority disposition becomes `None`;
- work item becomes dependency-satisfying.

A provider-observed `Done` without CompletionProof does **not** satisfy dependencies.

---

### Any nonterminal automation-relevant state → Authority Suspended

This is a Symphony authority transition, not necessarily a Plane lifecycle mutation.

Applicable source states include at minimum:

```text
Planning
Ready
In Progress
In Review
Changes Requested
Ready to Merge
Merging
```

Causes include:

```text
dependency invalidated
provider indeterminate
provider configuration drift
retry exhaustion
runtime unavailable
security failure
authority ambiguity
external forward transition requiring validation
candidate movement
completion proof failure
external condition
```

Side effects:

- authority disposition becomes `Suspended`;
- SuspensionContext opens;
- autonomous side effects stop.

If the provider contract remains trustworthy and `Blocked` is a meaningful safe human-facing projection, Symphony may perform a controlled transition to Plane `Blocked`.

Automation suspension does not depend on that projection succeeding.

---

### Suspension recovery → validated resume state

Authority: trusted reason-specific recovery policy or explicit human/operator action.

Required guards vary by suspension reason.

Examples:

```text
runtime_unavailable
→ MechanicalGuard: runtime healthy + reconciliation

provider_indeterminate
→ MechanicalGuard: authoritative provider reconciliation

provider_configuration_drift
→ MechanicalGuard + HumanDecision when remapping required

retry_exhausted
→ HumanDecision: H-030 explicit host/operator rearm

security_boundary_failed
→ HumanDecision + required security evidence
```

Never infer the resume state from mutable Plane display data.

The resume target comes from trusted SuspensionContext plus fresh lifecycle assessment.

---

### Any eligible nonterminal state → Canceled

Authority: human/operator policy.

Required guard class:

```text
HumanDecision
```

Side effects:

- autonomous authority is revoked immediately;
- validated lifecycle becomes `Canceled` after fresh provider reconciliation confirms the cancellation;
- terminal;
- never satisfies downstream dependencies.

Cancellation is authority-reducing and may be honored fail-safe even though it does not grant forward autonomous authority.

---

# 8. Plane Projection

Plane's stable five groups are broader than Symphony's lifecycle.

V1 mapping:

| Canonical state | Plane group |
|---|---|
| Backlog | `backlog` |
| Planning | `unstarted` |
| Ready | `unstarted` |
| In Progress | `started` |
| In Review | `started` |
| Changes Requested | `started` |
| Ready to Merge | `started` |
| Merging | `started` |
| Blocked | `started` |
| Done | `completed` |
| Canceled | `cancelled` |

State UUID identifies the intended exact lifecycle projection.

Group provides classification validation.

A configured state must satisfy both stable identity and expected group.

Example:

```text
configured Ready state UUID
must still exist
AND must still belong to expected group
```

A state renamed by a human may remain valid.

A state deleted and recreated with the same display name does not silently regain authority.

## 8.1 Projection is not lifecycle acceptance

Plane state mapping answers:

```text
Which canonical state does this configured provider state represent?
```

It does **not** answer:

```text
Has Symphony validated that the transition into that state was authorized?
```

Therefore the safe flow is:

```text
Plane state UUID/group
        ↓
ProviderObservation
        ↓
state mapping
        ↓
LifecycleAssessment
        ↓
Validated lifecycle state
        ↓
AuthorityDisposition
```

Safety-sensitive forward observations such as:

```text
Planning → Ready
In Progress → In Review
In Review → Ready to Merge
Merging → Done
```

require lifecycle revalidation.

Provider observations that only reduce authority, especially cancellation, may stop automation immediately while reconciliation determines the canonical lifecycle result.

---

# 9. Plane Provider Capability Decision

P-000 established the accepted H-020 routed capability vocabulary and Plane's support status.

V4.1 preserves H-020 vocabulary exactly; it does **not** retroactively rewrite accepted capability names.

## 9.1 Provider-native / provider-operation capabilities

| Capability | Decision |
|---|---|
| `current_issue_refresh` | Supported |
| `dependency_graph` | Supported |
| `dependency_completeness` | Supported |
| `controlled_transition` | Supported |
| `transition_verification` | Supported |
| `conditional_transition` | Unsupported |

`conditional_transition` remains explicitly unsupported.

No Plane CAS, revision, `If-Match`, expected timestamp or equivalent enforceable precondition has been proven.

## 9.2 Provider-integration exposure capabilities retained from H-020

| Capability | Decision |
|---|---|
| `agent_read_tools` | Implementable / supported by the integration |
| `agent_transition_tools` | Implementable / supported by the integration |

These names are retained because H-020 is accepted authority.

Their meaning is narrowly clarified:

```text
agent_read_tools
= the adapter/integration can safely back bounded semantic host-side read operations

agent_transition_tools
= the adapter/integration can safely back bounded semantic host-side transition requests
```

They do **not** mean:

```text
the provider grants an autonomous runtime those permissions
```

H-050A owns `Runtime.Authority`.

H-050B owns which semantic host tools are actually exposed to each responsibility.

H-090 may later reassess naming, but V4.1 does not alter accepted H-020 vocabulary.

---

# 10. Mandatory Plane Transition Rule

Live testing demonstrated that a Plane mutation response can contain the new state UUID while retaining stale derived state information.

Therefore:

> **Plane mutation responses are acknowledgements, not authoritative transition proof.**

Required flow:

```text
fresh provider read
        ↓
LifecycleAssessment
        ↓
authorize semantic transition
        ↓
durable Prepared state
        ↓
sync durable state
        ↓
submit state UUID mutation
        ↓
DO NOT accept response as proof
        ↓
fresh independent provider reread
        ↓
verify state UUID + expected group
        ↓
re-run lifecycle assessment
        ↓
Verified / Rejected / Conflict / ProviderFailed / Indeterminate
```

No blind retry after submission.

## 10.1 Failure classification

Before mutation can have reached Plane:

```text
credential unavailable
local validation failure
rate limiter prevents submission
connection failure before request transmission is established
```

may classify as `ProviderFailed`.

After mutation **may** have reached Plane:

```text
timeout
connection reset
ambiguous 5xx
response body lost
runtime/client crash awaiting response
```

must classify as:

```text
Indeterminate
```

unless authoritative evidence proves non-commit or proves the resulting state.

Rule:

> **If provider commit cannot be excluded, the outcome is `Indeterminate`, not `ProviderFailed`.**

`ProviderFailed` after preparation is only safe when non-commit is established or authoritative reconciliation proves the mutation did not take effect.

`Conflict` means authoritative reread proves another incompatible state/actor won the race.

`Rejected` means the transition was explicitly denied and non-commit is established.

---

# 11. Plane Project Contract

## 11.1 Bootstrap lifecycle

Initial configuration may resolve human-readable identifiers under explicit operator control.

```text
Unconfigured
 ↓
Resolving
 ↓
Validated
 ↓
Locked
```

### Unconfigured → Resolving

Guard:

- trusted operator/configuration explicitly selects the Plane workspace/project scope.

Side effects:

- resolve required state/project/relation identities;
- collect current capability declaration;
- no autonomous dispatch yet.

### Resolving → Validated

Guards:

- all required stable IDs resolve uniquely;
- expected state groups match;
- required provider capabilities are available;
- required relation semantics are available.

Side effects:

- compute proposed configuration fingerprint.

### Validated → Locked

Guard class:

```text
HumanDecision
```

Guard:

- operator accepts the resolved provider contract.

Side effects:

- persist/activate stable IDs and configuration fingerprint;
- display names become descriptive only;
- runtime validation may begin.

Once locked:

```text
stable IDs become authority
```

Display-name discovery must no longer silently substitute missing IDs.

## 11.2 Runtime contract lifecycle

```text
Locked
 ↓
Validating
 ├── Valid
 ├── DriftDetected
 └── ProviderUnavailable
```

### Locked/Valid → Validating

Trigger:

- startup;
- periodic reconciliation;
- relevant provider event;
- explicit operator validation.

Side effects:

- fetch fresh configuration/provider capability truth.

### Validating → Valid

Guards:

- all required stable identities still exist;
- expected semantic groups/relations still match;
- required capabilities remain supported;
- fingerprint-compatible semantics established.

Side effects:

- contract becomes eligible for policy use.

### Validating → DriftDetected

Guard:

- any authority-relevant configured identity or semantic contract differs.

Side effects:

- AuthorityDisposition becomes `Suspended` for affected scope;
- open/update `SuspensionContext(reason=provider_configuration_drift)`;
- block new autonomous side effects.

### Validating → ProviderUnavailable

Guard:

- provider configuration truth cannot be loaded.

Side effects:

- fail closed for operations requiring current validation;
- preserve prior contract as historical evidence, not fresh authority.

### DriftDetected → Revalidating

Guard:

- trusted operator/configuration resolution has supplied intended corrected mapping where required.

Side effects:

- validate corrected stable identities and semantics;
- do not restore authority yet.

### Revalidating → Valid

Guards:

- corrected contract passes full validation;
- fresh provider reconciliation succeeds;
- lifecycle/dependency policy reevaluated.

Side effects:

- close relevant SuspensionContext only after reason-specific recovery passes;
- authority may become eligible again according to policy.

Optional terminal:

```text
Decommissioned
```

A contract may transition to `Decommissioned` only through trusted operator configuration.

Terminal:

```text
Decommissioned
```

Symphony must be able to suspend locally even when provider drift makes a Plane `Blocked` projection unsafe or impossible.

## 11.3 Drift examples

Fail closed if:

- configured state UUID disappears;
- expected group changes;
- project ID changes;
- dependency relation semantics become unavailable;
- required provider capability disappears;
- project scope no longer matches durable safety metadata.

Do not automatically search for a similarly named replacement.

## 11.4 Drift recovery

Recovery must:

1. establish the intended replacement mapping through trusted operator/configuration authority where required;
2. validate stable IDs and semantic groups;
3. create a new valid configuration fingerprint;
4. perform fresh provider reconciliation;
5. reevaluate lifecycle/dependency policy;
6. close the SuspensionContext only when recovery guards pass.

Changing Plane display text alone never resolves a stable-identity drift.

---

# 12. Work Control vs Source Control

The architecture must separate:

```text
WorkControl
```

from:

```text
SourceControl
```

## Work Control

Plane responsibilities:

- work-item reads;
- project scope;
- lifecycle state;
- dependencies;
- human intent;
- controlled lifecycle mutation.

## Source Control

GitHub responsibilities:

- repository read;
- commit identity;
- pull request metadata;
- exact PR HEAD;
- CI state;
- review metadata;
- trusted push/merge channels where authorized.

Example Reviewer authority:

```text
Plane read
GitHub PR read
GitHub CI read
repository read
```

Reviewer does not automatically receive:

```text
Plane transition mutation
GitHub push
GitHub merge
```

---

# 13. Plane Integration Trust Boundary

Production Symphony integration uses:

```text
Plane REST API
+
explicit provider adapter
```

Later:

```text
signed Plane webhooks
```

MCP is not the production provider trust boundary.

Plane MCP may be used for:

- human interaction;
- development investigation;
- selected read-only future agent context.

Lifecycle mutations by autonomous agents must remain behind Symphony's trusted semantic boundary.

Never query Plane's underlying Postgres directly, including in self-hosted deployments.

---

# 14. Webhook Doctrine

Later H-070 adds signed Plane webhooks.

Rule:

> Events tell Symphony **where to look**.  
> Fresh provider reads tell Symphony **what is true**.

Lifecycle:

```text
WebhookReceived
 ↓
SignatureVerified
 ↓
Deduplicated
 ↓
ReconciliationScheduled
 ↓
ProviderRead
 ↓
SnapshotValidated
 ↓
PoliciesReevaluated
 ↓
Completed
```

Failure outcomes:

```text
InvalidSignature
Duplicate
ProviderUnavailable
ConfigurationDrift
SnapshotIncomplete
```

## 14.1 Transition guards and side effects

### WebhookReceived → SignatureVerified

Guard:

- HMAC/signature validates against trusted host-side secret and raw payload.

Failure:

- invalid signature → `InvalidSignature`.

Side effects:

- no provider/lifecycle mutation.

### SignatureVerified → Deduplicated

Guard:

- delivery ID has not already been accepted within dedup retention policy.

Failure:

- known delivery ID → `Duplicate`.

Side effects:

- record delivery identity in bounded dedup store.

### Deduplicated → ReconciliationScheduled

Side effects:

- enqueue/signal reconciliation for affected project/work-item scope;
- do not update canonical lifecycle from webhook body.

### ReconciliationScheduled → ProviderRead

Guard:

- normal provider project contract allows authoritative read attempt.

Side effects:

- fetch fresh REST truth.

Failure:

- provider unavailable → `ProviderUnavailable`.

### ProviderRead → SnapshotValidated

Guards:

- required provider data complete and well formed;
- project identity/configuration valid.

Failures:

- contract mismatch → `ConfigurationDrift`;
- incomplete data → `SnapshotIncomplete`.

### SnapshotValidated → PoliciesReevaluated

Side effects:

- create fresh ProviderObservation;
- run LifecycleAssessment;
- rebuild/invalidate affected graph epoch as required;
- reevaluate AuthorityDisposition.

### PoliciesReevaluated → Completed

Guard:

- reconciliation finishes without unresolved unsafe authority.

Side effects:

- publish reconciled state;
- only canonical policy changes authority.

Terminal:

```text
Completed
InvalidSignature
Duplicate
ProviderUnavailable
ConfigurationDrift
SnapshotIncomplete
```

Webhook payload must never substitute for authoritative state.

Periodic full reconciliation remains required.

Plane retries/duplicate delivery therefore affect wake-up efficiency, not lifecycle truth.

---

# 15. Dependency Architecture

P-000 established that a complete Plane graph can be constructed but requires:

```text
ceil(N / 100)
work-item list calls

+

N relation reads
```

for a full project scan.

Therefore V1 uses immutable graph epochs.

```text
reconciliation begins
 ↓
enumerate all work items
 ↓
verify pagination complete
 ↓
bounded-concurrency relation reads
 ↓
verify every relation read succeeded
 ↓
normalize dependency edges
 ↓
validate referenced items
 ↓
build immutable graph epoch
 ↓
SCC computation once
 ↓
publish graph snapshot
 ↓
dispatch decisions consume snapshot
```

Do not perform ad-hoc provider dependency reads from every dispatch path.

## Dependency satisfaction

Dependency satisfaction is based on **validated lifecycle completion**, not raw Plane provider state.

For prerequisite P:

```text
P validated lifecycle state == Done
AND required CompletionProof passed
→ satisfied
```

For work that does not produce a source candidate, canonical policy may define a different completion proof, but raw provider `completed` observation is never enough by itself.

```text
P validated lifecycle state == Canceled
→ invalidated
```

Any other nonterminal validated state:

```text
unresolved
```

Provider observation says `Done` but lifecycle assessment has not validated completion:

```text
unresolved / suspended
NOT satisfied
```

Unknown/missing/malformed provider data, incomplete lifecycle assessment, or incomplete graph:

```text
fail closed
```

Dependency edges remain meaningful after cancellation; state semantics determine satisfaction.

---

# 16. Recommended V1 Folder / Module Structure

Current repository already has a `tracker` domain containing `capabilities.ex`, `issue.ex`, `memory.ex`, and `transition_policy.ex`.

V4.1 should evolve incrementally rather than perform a disruptive namespace migration.

Recommended target:

```text
elixir/lib/symphony_elixir/
│
├── tracker.ex
├── tracker/
│   ├── capabilities.ex
│   ├── issue.ex
│   ├── memory.ex
│   └── transition_policy.ex
│
├── work_control/
│   ├── work_item.ex
│   ├── provider_observation.ex
│   ├── workflow_lifecycle.ex
│   ├── lifecycle_assessment.ex
│   ├── guard_class.ex
│   ├── authority_disposition.ex
│   ├── suspension_context.ex
│   ├── provider_snapshot.ex
│   ├── provider_project_contract.ex
│   ├── reconciliation.ex
│   └── escalation.ex
│
├── plane/
│   ├── client.ex
│   ├── adapter.ex
│   ├── state_projection.ex
│   ├── dependency_projection.ex
│   └── project_contract.ex
│
├── dependency/
│   └── ...
│
├── source_control.ex                 # H-050C, only if seam proves useful
├── source_control/
│   └── candidate_ref.ex              # H-050C thin V1 identity
│
├── github/
│   └── ...
│
├── agent_runtime.ex
├── agent_runtime/
│   ├── authority.ex                  # H-050A
│   └── ...
│
├── orchestrator.ex
└── ...
```

Exact file extraction remains subject to existing repository patterns and P-010/H-050 seam review. Do not create modules merely to match this tree when a smaller existing seam is clearer.

### Naming rule

Use domain terminology in new core modules:

```text
WorkItem
ProviderObservation
WorkflowLifecycle
LifecycleAssessment
AuthorityDisposition
SuspensionContext
ProviderSnapshot
ProviderProjectContract
CandidateRef
RuntimeAttempt
```

not:

```text
PlaneIssue
LinearIssue
PlaneWorkflowState
GenericGeneration
```

Provider modules may naturally use provider-specific names internally.

### Important migration rule

Do not perform a mass `Tracker` → `WorkControlProvider` namespace rename during P-010.

H-020 accepted semantics already exist around `Tracker`.

Provider neutrality is required now.

Mass naming churn is not.

H-090 may reassess the public namespace once the architecture has stabilized.

---

# 17. Core V4.1 Invariants

All accepted prior invariants remain.

The following V4/V4.1 invariants are explicitly authoritative for the revised roadmap.

## H-I12 — Stable provider identity

Autonomous authority may rely only on validated stable provider identities.

Display-name equivalence does not restore authority after provider configuration drift.

## H-I13 — Mutation response is not truth

A provider mutation acknowledgement cannot establish transition success.

A fresh authoritative provider read plus lifecycle assessment is required.

## H-I14 — Human intent does not grant machine authority

Plane may express:

```text
Ready
automation allowed
high priority
```

but only Symphony policy grants autonomous execution authority.

## H-I15 — Provider events are hints

Webhook delivery may trigger reconciliation.

It may not substitute for an authoritative provider read.

## H-I16 — Work-control authority does not imply SCM authority

Plane access does not grant GitHub write/merge permissions.

GitHub access does not grant Plane lifecycle authority.

## H-I17 — Project-scope isolation

Provider reads, durable attempt state and autonomous authority must remain bound to the configured:

```text
workspace_id
project_id
repository identity
```

Cross-project authority is prohibited.

## H-I18 — No untrusted direct provider mutation

Autonomous runtime code may not bypass trusted semantic host operations to mutate Plane directly.

## H-I19 — Provider observation cannot grant authority

External provider observations may revoke, suspend, invalidate, or constrain existing autonomous authority.

They may not grant new autonomous authority, establish successful completion, approve a candidate, or satisfy downstream dependencies without canonical lifecycle validation.

Safety-sensitive forward provider observations must be reconciled against required mechanical guards, semantic attestations and human decisions.

## H-I20 — Successful completion requires completion proof

A provider-observed `completed`/`Done` state does not satisfy dependencies unless Symphony has validated the completion path required by canonical lifecycle policy.

For code-producing work, completion proof includes exact candidate binding and verified source-control closure against the approved CandidateRef where applicable.

## H-I21 — Suspension is Symphony-owned

Automation suspension must remain enforceable even when Plane is unavailable, indeterminate, or configuration-drifted.

Plane `Blocked` is a projection, not the source of suspension authority.

## H-I22 — Ambiguous provider submission is indeterminate

After a provider mutation may have been submitted, any outcome that cannot prove non-commit is `Indeterminate`.

It must not be classified as a retryable provider failure.

## H-I23 — Exact candidate movement invalidates approval

Review, CI and merge readiness apply only to the exact CandidateRef they validated.

Any post-approval candidate SHA movement invalidates readiness until required evidence is re-established.

## H-I24 — Guard classes are not interchangeable

Mechanical facts, semantic attestations and human decisions are distinct policy inputs.

No weaker guard class may silently satisfy a stronger or different required guard.

---

# 18. Security Model

Trust flow:

```text
Trusted host
   ↓
Symphony authority kernel
   ↓
bounded semantic operations
   ↓
Codex / runtime

Plane credentials
GitHub credentials
operator credentials

remain host-side
```

Agent-controlled repositories/workspaces are untrusted input.

Prompts are not controls.

Security must be mechanical.

Required controls include:

- runtime authority;
- provider capability;
- project scoping;
- network boundary;
- filesystem boundary;
- semantic provider tools;
- host-side credentials;
- trusted Git transport;
- exact-SHA governance;
- durable ownership;
- stale-generation rejection.

---

# 19. Performance & Scaling Architecture

Symphony does not need the EventSales flash-sale architecture.

V1 performance model:

## Hot

```text
OTP processes
GenServers where ownership is required
ETS for immutable/hot projections where justified
```

Examples:

- current graph epoch;
- current project snapshot metadata;
- provider throttle state;
- active runtime projection.

TTL:

- generally reconciliation-epoch based rather than time-cache based;
- never cache safety facts past their validity boundary.

## Warm

```text
None in V1
```

Redis is not justified.

## Durable

```text
Plane / GitHub
+
small DETS safety state
```

## PostgreSQL

Not required.

## Redis

Not required.

## PubSub

Not required for authority.

May later be observational only.

## Browser storage / CDN

Not applicable.

## Performance targets

V1 should aim for:

- bounded provider-call concurrency;
- no uncontrolled N+1 request storms;
- one SCC calculation per graph epoch;
- no per-dispatch full-graph reconstruction;
- provider throttling/backoff;
- deterministic memory bounds;
- periodic reconciliation frequency compatible with Plane limits.

H-070 must test at least:

```text
>= 1000 work items
>= 5000 dependency edges
```

---

# 20. Failure Modes

The V4.1 implementation must explicitly handle:

### Provider

- Plane unavailable;
- API timeout;
- rate limiting;
- malformed response;
- incomplete pagination;
- dependency relation read failure;
- renamed display state;
- deleted configured state;
- changed state group;
- provider configuration drift;
- stale mutation-derived metadata;
- read/write race;
- ambiguous mutation result;
- mutation may have committed despite transport failure;
- manual provider forward transition without canonical guards;
- manual provider `Done` without completion proof;
- duplicate webhook;
- stale webhook;
- out-of-order webhook.

### Lifecycle / Authority

- provider observation differs from last validated lifecycle state;
- forward provider observation requires validation;
- automation must suspend even if Plane cannot be mutated;
- suspension origin/resume state missing or untrusted;
- incorrect reason-specific recovery;
- retry exhaustion incorrectly auto-resumed;
- security suspension incorrectly auto-resumed;
- raw `Done` observation treated as dependency satisfaction;
- guard class substitution.

### Dependency

- canceled prerequisite;
- provider-observed but unvalidated Done prerequisite;
- deleted prerequisite;
- missing relation target;
- cycles;
- incomplete graph;
- graph epoch invalidation;
- inconsistent inverse relation.

### Runtime

- process crash;
- stale runtime event;
- retry exhaustion;
- authority profile mismatch;
- workspace disappearance;
- stale workspace;
- restart after pending close;
- restart after sync failure;
- ambiguous use of `generation`;
- RuntimeAttempt from an old lineage generation.

### GitHub / Candidate

- PR HEAD changed after approval;
- CI changed;
- candidate changed;
- CandidateRef no longer matches observed PR HEAD;
- branch protection changed;
- human merges a different SHA than approved;
- merge result cannot be tied to CandidateRef;
- Plane says Done before GitHub completion proof exists.

### Security

- agent requests raw Plane credential;
- agent tries arbitrary Plane API mutation;
- agent invokes unauthorized Git;
- agent forges success evidence;
- worker claims tests passed without trusted proof;
- agent tries to cross project scope;
- runtime attempts to clear its own suspension;
- runtime attempts lineage rearm;
- provider state is used to bypass reviewer or merge guards.

---

# 21. Multi-Tenant / Multi-Project Isolation

Initial deployment remains:

```text
1 repository
=
1 Plane project
=
1 WORKFLOW
=
1 Symphony service
```

Example:

```text
EventSales Plane Project
        ↓
EventSales Symphony service
        ↓
EventSales repository/workspaces
```

Never run multiple authoritative Symphony services against the same Plane project scope.

Project identity must include at minimum:

```text
provider
workspace_id
project_id
repository identity
```

A different checkout path must not create a different autonomous identity.

---

# 22. Revised Programme Structure

# Programme A — V4.1 Authority Foundation

This is the current implementation programme.

```text
H-010 ACCEPTED
H-020 ACCEPTED
H-030 ACCEPTED

P-000 Plane Provider Feasibility       ACCEPTED

V4.1-000 V4.1 Authority Rewrite
P-010 Canonical Work Control, Observation & Lifecycle
P-020 Plane Project Contract + Drift Protection
P-030 Plane Provider Foundation
P-040 Plane Dependency Contract

H-040 Plane Transition Race Hardening

H-050A Runtime Authority Contract
H-050B Plane Semantic Agent Tools
H-050C Source Control Authority + CandidateRef
H-050D Credential / Channel Enforcement

H-060A RuntimeAttempt Identity / Stale Events
H-060B Startup Recovery / Suspension Reconciliation
H-060C Workspace Ownership / Recovery

H-070A Graph Performance / Rate Limits
H-070B Plane Webhooks / Incremental Reconciliation

H-080A Adversarial Authority Characterization
H-080B Runtime Isolation
H-080C Integrated Security Reverification

H-090 Structural Hardening

H-120A Governance Pre-Gate
freeze exact candidate
H-100 Real Plane + Codex + GitHub Proof through verified Done
H-110 Restart / Failure Soak
H-120B Final Independent Gate
```

---

# 23. Programme A Detailed Phases

## V4.1-000 — Authority Documentation Rewrite

### Outcome

Create a single V4.1 authority package.

### Must include

- immutable H-010/H-020/H-030 acceptance;
- accepted P-000 Plane feasibility evidence;
- V4.1 invariants H-I19 through H-I24;
- provider-neutral architecture;
- ProviderObservation / LifecycleAssessment / AuthorityDisposition separation;
- SuspensionContext semantics;
- Plane as chosen V1 provider;
- RuntimeAttempt/AttemptLineage taxonomy;
- thin V1 CandidateRef;
- verified human-merge → Done closure;
- revised execution sequence;
- explicit deferred Programmes B/C/D.

### Must not

- alter production code;
- rewrite accepted historical claims;
- change accepted H-020 vocabulary;
- weaken existing invariants;
- pull full Programme B entities into V1.

---

## P-010 — Canonical Work Control, Observation & WorkflowLifecycle

### Outcome

Remove provider-specific lifecycle semantics from the authority kernel and prevent provider observation from automatically granting canonical authority.

### Deliverables

- provider-neutral `WorkItem`;
- `ProviderObservation`;
- canonical `WorkflowLifecycle`;
- `LifecycleAssessment`;
- `GuardClass`;
- `AuthorityDisposition`;
- `SuspensionContext` policy shape;
- canonical state classification;
- lifecycle transition table;
- responsibility mapping;
- tests proving Router/TransitionPolicy consume canonical semantics.

### Important constraint

Do not build Plane HTTP yet.

Do not make Plane `Blocked` the mechanism that enforces suspension.

### Required tests

- provider observation `Ready` cannot by itself grant Builder authority;
- provider observation `Ready to Merge` cannot establish reviewer acceptance;
- provider observation `Done` cannot satisfy dependencies;
- authority-reducing cancellation stops automation;
- suspension works without provider mutation;
- guard classes remain distinct.

### Acceptance

Existing Linear/Memory compatibility remains.

No change in accepted behavior except centralizing lifecycle law and enforcing the new observation/authority distinction.

---

## P-020 — Plane Project Contract + Drift Protection

### Outcome

Introduce mechanically validated provider configuration identity and fail-closed drift suspension.

### Deliverables

- `ProviderProjectContract`;
- Plane contract validator;
- configuration fingerprint;
- drift classification;
- authority suspension integration;
- operator-oriented diagnostics.

### Required tests

- rename display name, same UUID → allowed where harmless;
- delete configured state UUID → drift;
- recreate same display name with different UUID → still drift;
- change expected state group → drift;
- project mismatch → drift;
- malformed configuration → fail closed;
- drift suspends Symphony authority even when Plane cannot be moved to `Blocked`;
- recovery requires contract revalidation before suspension closes.

---

## P-030 — Plane Provider Foundation

### Outcome

Read-only Plane provider producing authoritative provider observations.

### Deliverables

- REST client;
- host-side credential loading;
- Plane adapter;
- work-item retrieval;
- project-scoped listing;
- provider observation creation;
- state mapping/projection;
- authoritative fresh refresh;
- truthful capability declaration.

### Capability graduation

At minimum:

```text
current_issue_refresh
```

No mutation yet.

Plane reads populate ProviderObservation; they do not directly overwrite validated lifecycle authority.

---

## P-040 — Plane Dependency Contract

### Outcome

Complete deterministic dependency graph whose satisfaction policy consumes validated lifecycle semantics.

### Deliverables

- paginated item enumeration;
- bounded relation reads;
- dependency normalization;
- completeness proof;
- canceled dependency invalidation;
- unvalidated Done rejection;
- missing/unknown fail closed;
- SCC cycle detection;
- immutable graph epoch.

### Capability graduation

Add:

```text
dependency_graph
dependency_completeness
```

### Required tests

- 105+ relation overflow remains complete;
- raw provider `completed` observation without validated completion does not satisfy;
- validated Done with required completion proof satisfies;
- Canceled invalidates;
- partial graph fails closed.

---

## H-040 — Plane Transition Race Hardening

### Outcome

Safe Plane lifecycle mutation without CAS.

### Required state machine

```text
Requested
IntentAuthorized
FreshContextLoaded
Prepared
MutationSubmitted
Verifying
Verified
Rejected
Conflict
ProviderFailed
Indeterminate
```

### Mandatory rules

- fresh read and lifecycle assessment before mutation;
- Prepared durable before mutation;
- durable sync succeeds before provider side effect;
- no trust in mutation response;
- fresh read after mutation;
- post-read lifecycle assessment;
- no blind retry after submission;
- conflict and indeterminate do not auto-retry;
- activity history may be supporting evidence only;
- `conditional_transition` remains unsupported;
- if commit cannot be excluded after possible submission, outcome is `Indeterminate`;
- `ProviderFailed` requires proof that mutation did not commit or could not have been submitted.

### Capability graduation

Add:

```text
controlled_transition
transition_verification
```

---

## H-050A — Runtime Authority Contract

Separate runtime authority from provider capability.

Every responsibility receives explicit semantic lifecycle-command permissions.

Examples:

```text
Planner:
repository read
Plane semantic read
request Planning → Ready
no implementation write

Builder:
repository/workspace write
Plane semantic read
request Ready → In Progress
request In Progress → In Review

Reviewer:
repository read
GitHub PR/CI read
Plane semantic read
request In Review → Changes Requested
request In Review → Ready to Merge
no source modification

Fixer:
workspace write
Plane semantic read
request Changes Requested → In Review

Merge Gatekeeper:
GitHub/Plane read
verify external/human merge closure
no autonomous GitHub merge in V1
```

These are permissions to request canonical lifecycle operations.

They are not raw Plane mutation permissions.

---

## H-050B — Plane Semantic Agent Tools

Replace raw provider access with narrow project-scoped operations.

Examples:

```text
get_current_work_item
get_dependencies
get_lifecycle_assessment
get_authority_disposition
request_lifecycle_transition
```

No generic Plane REST execution tool.

No agent credential.

A semantic transition request must pass Runtime.Authority and canonical lifecycle guards before H-040 performs any provider mutation.

---

## H-050C — Source Control Authority + CandidateRef

### Outcome

Formalize GitHub independently of work-control selection and introduce thin exact-candidate identity.

### Deliverables

- minimal SourceControl behavior/seam where justified;
- GitHub capability mapping;
- `CandidateRef`;
- exact candidate/PR-head validation;
- role-policy tests;
- merge-verification operation for V1 closure.

### CandidateRef

```text
repository_identity
base_sha
candidate_sha
pr_identity
observed_pr_head_sha
```

No Candidate database.

No EvidenceBundle.

Reviewer and merge roles receive only required SCM capabilities.

Required negative tests:

- candidate moves after review → readiness invalidated;
- PR head differs from CandidateRef → fail closed;
- human merges non-approved SHA → cannot become validated Done.

---

## H-050D — Credential / Channel Enforcement

Mechanically prove:

- Plane credentials stay host-side;
- GitHub credentials stay host-side;
- agent workspace cannot redirect credentialed transport;
- raw provider mutation channels unavailable;
- runtime network/tool permissions match authority;
- runtime cannot clear SuspensionContext or rearm lineage through an untrusted channel.

---

## H-060A — RuntimeAttempt Identity / Stale Event Rejection

Every authority-bearing runtime event must be bound to current identity.

At minimum:

```text
work_item_id
runtime_attempt_id
lineage_generation
responsibility
```

Do not use ambiguous bare `generation`.

Stale events fail closed.

Programme B `Execution` will supersede/generalize RuntimeAttempt.

---

## H-060B — Startup Recovery / Suspension Reconciliation

At startup:

```text
load durable safety state
 ↓
load open SuspensionContext records
 ↓
validate Plane configuration
 ↓
refresh provider observations
 ↓
rebuild dependency graph
 ↓
reassess lifecycle
 ↓
reconcile AttemptLineage / RuntimeAttempt
 ↓
reconcile runtime state
 ↓
apply reason-specific suspension recovery rules
 ↓
allow dispatch only when safe
```

Do not restore stale sessions blindly.

Do not clear suspension merely because Plane state was manually moved.

Retry exhaustion requires H-030 host/operator rearm.

Configuration drift requires project-contract revalidation.

Provider indeterminate requires authoritative reconciliation.

Security suspension requires explicitly authorized recovery.

---

## H-060C — Workspace Ownership / Shutdown Recovery

Workspace enters coverage authority.

Destructive cleanup requires trusted ownership evidence.

Agent-writable markers are never sufficient proof of ownership.

---

## H-070A — Dependency Performance / Rate Limits

Test realistic large project graphs.

Minimum synthetic envelope:

```text
1000 work items
5000 edges
```

Requirements:

- bounded concurrency;
- backoff;
- throttle visibility;
- immutable graph epoch;
- one SCC pass per epoch;
- no repeated provider read storm;
- lifecycle assessment does not create per-dispatch provider N+1 reads.

---

## H-070B — Signed Webhooks / Incremental Reconciliation

Add Plane webhooks as wake-up signals.

Required:

- signature verification;
- delivery-ID deduplication;
- replay/out-of-order safety;
- reconciliation scheduling;
- fresh REST reread;
- new ProviderObservation;
- lifecycle reassessment;
- periodic full reconciliation.

Webhooks never become truth and cannot directly advance canonical lifecycle.

---

## H-080A — Adversarial Authority Characterization

Attack:

- provider tool bypass;
- lifecycle bypass;
- manual Plane forward-transition bypass;
- fake Plane Done;
- project-scope escape;
- dependency manipulation;
- configuration drift;
- fake completion;
- retry reset attempt;
- suspension clearing attempt;
- GitHub authority escalation;
- CandidateRef substitution;
- human merge of wrong candidate.

---

## H-080B — Runtime Isolation

Prove actual Codex isolation.

Release blocking if required read/write isolation cannot be mechanically established or externally contained.

Prove that runtime cannot directly obtain provider/SCM credentials or bypass semantic host tools.

---

## H-080C — Integrated Security Reverification

Repeat security tests after all authority seams are integrated.

Must include H-I19 through H-I24.

---

## H-090 — Structural Hardening

Evaluate architectural seams only after behavior is stable.

Possible extraction only where justified.

No aesthetic refactor.

Keep one scheduler/Orchestrator authority.

Reassess whether `Tracker` namespace should eventually become `WorkControl`.

Reassess whether CandidateRef/CompletionProof representation is still minimal and not accidentally becoming Programme B early.

---

## H-120A — Governance Pre-Gate

Verify:

- documentation current;
- V4.1 invariants current;
- required CI enforced;
- evidence collection ready;
- disposable Plane resources ready;
- disposable GitHub merge proof ready;
- exact production-proof procedure defined;
- human merge step defined without auto-merge authority;
- exact candidate freeze procedure defined.

---

## Candidate Freeze

Freeze:

```text
exact SHA
exact tree
exact workflow/config
exact dependency set
exact CandidateRef where proof uses a PR
```

No evidence from another candidate may be substituted.

---

## H-100 — Real Disposable Live Proof

Use:

```text
real Plane
real Codex
real GitHub
real Symphony
```

against disposable resources.

Prove:

```text
Planning
→ Ready
→ In Progress
→ In Review
→ Changes Requested
→ In Review
→ Ready to Merge
→ external/human exact-candidate merge
→ Symphony GitHub merge verification
→ Merging / closure verification
→ controlled Plane Done
→ fresh Plane reread
→ validated Done
→ downstream dependency satisfaction
```

Also prove:

- dependency blocking;
- cancellation;
- provider failure;
- provider indeterminate outcome;
- manual/external Plane Done cannot bypass completion proof;
- manual Ready-to-Merge cannot bypass review;
- exact candidate binding;
- candidate movement invalidates approval;
- reviewer independence;
- authority suspension independent of Plane Blocked.

No production rollout yet.

---

## H-110 — Restart / Failure Soak

Same exact frozen candidate SHA.

Test:

- Symphony restart;
- Plane timeout;
- ambiguous mutation response;
- failed durable sync;
- delayed runtime event;
- provider drift;
- relation-read failure;
- manual provider forward transition;
- open SuspensionContext across restart;
- stale workspace;
- retry exhaustion;
- GitHub candidate movement;
- human merges wrong candidate;
- Plane Done appears before completion proof.

---

## H-120B — Final Independent Release Gate

Independent reviewer evaluates exact frozen candidate.

Only outcomes:

```text
ACCEPTED
REJECTED
BLOCKED
```

No self-attestation.

Acceptance requires explicit confirmation that:

- provider observation cannot grant unsafe forward authority;
- suspension/recovery is reason-specific;
- exact candidate closure works;
- Done requires completion proof;
- ambiguous provider submission never becomes blind retry.

---

# 24. Programme B — Engineering Identity & Evidence

Begins only after V1 is accepted.

## B-010 Execution

Programme B promotes the V1 `RuntimeAttempt` into a first-class autonomous `Execution` domain.

`Execution` **supersedes/generalizes RuntimeAttempt**; it must not become a parallel competing truth.

Separate:

```text
WorkItem != Execution
```

### Lifecycle

```text
Queued
 ↓
Starting
 ↓
Running
 ├── Completed
 ├── Escalated
 ├── Failed
 └── Cancelled
```

#### Queued → Starting

Guards:

- current work item/lifecycle/authority is eligible;
- execution generation is current;
- runtime chosen satisfies capability requirements.

Side effects:

- allocate execution identity and authority snapshot.

#### Starting → Running

Guard:

- runtime/supervision boundary successfully established.

Side effects:

- execution becomes current authority for its responsibility.

#### Running → Completed

Guard:

- responsibility-specific completion criteria met and trusted result collected.

Side effects:

- close active execution authority;
- permit candidate/result processing.

#### Starting/Running → Escalated

Guard:

- unresolved condition exceeds autonomous authority.

Side effects:

- stop child/runtime authority;
- preserve execution state/context/evidence;
- open escalation.

#### Starting/Running → Failed

Guard:

- terminal execution failure under execution policy.

Side effects:

- end authority and record failure.

#### Queued/Starting/Running → Cancelled

Guard:

- trusted cancellation/revocation.

Side effects:

- terminate execution and reject stale events.

Terminal:

```text
Completed
Escalated
Failed
Cancelled
```

Each execution has:

```text
execution_id
work_item_id
lineage_generation
execution_generation
responsibility
runtime
authority_snapshot
started_at
ended_at
```

`lineage_generation` remains the H-030 retry-lineage generation.

`execution_generation` is introduced only if Programme B proves a distinct execution fencing lifecycle is required.

---

## B-020 Candidate

Programme B promotes the thin V1 `CandidateRef` into a first-class Candidate domain.

Separate:

```text
Execution != Candidate
```

### Lifecycle

```text
Proposed
 ↓
UnderReview
 ├── Accepted
 ├── Rejected
 └── Invalidated
        ↓ new candidate required

Accepted
 ↓
Merged
```

#### Proposed → UnderReview

Guards:

- exact candidate identity established;
- candidate belongs to current execution/work item;
- required review inputs available.

Side effects:

- bind review/evidence collection to exact candidate SHA.

#### UnderReview → Accepted

Guards:

- required evidence profile satisfied;
- independent review accepts exact candidate;
- no candidate movement.

Side effects:

- mark candidate acceptable for next controlled lifecycle step.

#### UnderReview → Rejected

Guard:

- review/evidence establishes candidate unacceptable.

Side effects:

- preserve rejection evidence;
- require correction/new candidate.

#### Proposed/UnderReview/Accepted → Invalidated

Guard:

- candidate SHA/diff/base authority changes or governing authority is superseded.

Side effects:

- invalidate candidate-bound evidence/readiness;
- no automatic carry-forward.

#### Accepted → Merged

Guard:

- trusted SourceControl verification proves merged repository state corresponds to this exact accepted candidate.

Side effects:

- bind merge result to Candidate.

Terminal:

```text
Rejected
Invalidated
Merged
```

Candidate is bound to:

```text
base_sha
candidate_sha
diff_identity
execution_id
```

---

## B-030 EvidenceBundle

Evidence attaches to Candidate, not WorkItem.

### Lifecycle

```text
Pending
 ↓
Collecting
 ↓
Complete
 ├── Valid
 ├── Invalid
 └── Inconclusive
```

#### Pending → Collecting

Guard:

- candidate identity fixed for the evidence collection cycle.

Side effects:

- start trusted evidence capture under required EvidenceProfile.

#### Collecting → Complete

Guard:

- all required evidence categories have produced a result or explicit limitation.

Side effects:

- freeze evidence set against candidate identity.

#### Complete → Valid

Guard:

- every required evidence rule passes for exact candidate.

Side effects:

- permit policy that depends on valid evidence.

#### Complete → Invalid

Guard:

- required evidence fails or candidate identity no longer matches.

Side effects:

- block acceptance;
- preserve failure evidence.

#### Complete → Inconclusive

Guard:

- required evidence cannot establish pass/fail truth safely.

Side effects:

- block automatic acceptance;
- escalate or request additional evidence.

Any candidate SHA change invalidates candidate-bound evidence and requires a new bundle/collection cycle.

Terminal for one bundle instance:

```text
Valid
Invalid
Inconclusive
```

Evidence includes:

- tests;
- CI;
- static analysis;
- review;
- security proof;
- live proof;
- limitations.

---

## B-040 EvidenceProfile

Examples:

```text
standard
security
concurrency
migration
provider-integration
live-proof
architecture-only
```

---

## B-050 Full Escalation

Promote the minimal V1 escalation record into a richer first-class domain without weakening V1 semantics.

The V1 lifecycle:

```text
Raised
→ Acknowledged
→ UnderHumanResolution
→ Resolved / Superseded
```

remains the minimum authority model.

Programme B may add:

- structured resolution evidence;
- affected Execution/Candidate references;
- SLA/ownership metadata;
- operator audit history;
- resumability policy.

It must not make autonomous resumption easier than the V1 reason-specific recovery rules.

---

## B-060 Hot ↔ Autonomous Handoff

Formal readiness contract before autonomous control.

---

## B-070 Plane Operator Projection

Project selected Symphony information back into Plane:

```text
Execution ID
Candidate SHA
Evidence status
Escalation reason
Last verified CI
```

These remain projections, not canonical authority.

---

# 25. Programme C — Supervised Autonomous Execution

Only after Programme B.

## C-010 ExecutionSupervisor

Role-local supervisor.

Example:

```text
Builder Execution Supervisor
├── repository research worker
├── test worker
├── implementation worker
└── verification worker
```

Child capabilities must satisfy:

```text
child_capabilities ⊆ parent_capabilities
```

---

## C-020 Context Broker

Bound context:

```text
authority manifest
repository map
changed files
failures
architecture refs
dependency snapshot
worker findings
open questions
```

Do not copy the entire conversation to every worker.

---

## C-030 Transport-Neutral Execution Events

```text
execution_started
worker_started
worker_progressed
worker_result
worker_failed
candidate_created
execution_completed
execution_escalated
```

Every event includes current explicit identity/fencing fields. Do not use an ambiguous bare `generation`; distinguish `lineage_generation`, `execution_generation`, and any later worker-specific fence only when their lifecycle semantics genuinely differ.

---

## C-040 OTP / ETS First

Use:

```text
Supervisor
DynamicSupervisor
Task.Supervisor
Registry
GenServer
ETS
```

No Redis.

---

## C-050 Worker Security

Test:

- capability escalation;
- forged worker identity;
- stale generation;
- malicious worker result;
- context poisoning;
- cross-execution leakage;
- provider/SCM bypass;
- fake evidence.

Independent Reviewer remains outside Builder supervisor.

---

# 26. Programme D — Runtime & Distribution Expansion

Only after measured need exists.

## D-010 Pluggable ExecutionRuntime

Possible future providers:

```text
CodexLocal
ManagedCodex
OtherAgentRuntime
```

Runtime replacement must not alter authority policy.

## D-020 Remote execution

Only after local supervisor model is proven.

## D-030 Redis evaluation

Redis is evaluated, not assumed.

Potential uses:

```text
heartbeats
presence
ephemeral queue
rate limits
event transport
short-lived leases
```

Never:

```text
canonical lifecycle
retry lineage
review verdict
candidate approval
autonomous authority
```

## D-040 Multi-node authority

Deferred until single-node measurements demonstrate necessity.

Requires deliberate:

```text
leader election
fencing
lease ownership
split-brain protection
cross-node generation
durable coordination
```

---

# 27. V1 Non-Goals

Do not introduce during Programme A:

- Redis;
- PostgreSQL authority database;
- multiple Symphony authority nodes;
- Cursor runtime;
- automatic merge;
- supervisor/subagents;
- first-class Programme B `Execution` persistence;
- Candidate database;
- EvidenceBundle database;
- rich evidence-profile engine;
- Plane database access;
- paid Plane workflow dependency;
- Plane MCP as trusted provider boundary;
- multiple work-item lifecycle families;
- elaborate work-item taxonomy;
- broad UI/dashboard work.

The following thin V1 concepts are explicitly **not** violations of these non-goals:

```text
RuntimeAttempt
CandidateRef
CompletionProof policy
ProviderObservation
LifecycleAssessment
AuthorityDisposition
SuspensionContext
```

They exist only to make V1 authority, recovery and exact-candidate safety explicit.

Programme B remains responsible for promoting execution/candidate/evidence into richer first-class domains.

---

# 28. Testing Strategy

Every implementation phase must include the relevant layers below.

## Unit

Pure policy/projection functions.

Especially:

- lifecycle transition legality;
- guard classification;
- ProviderObservation mapping;
- LifecycleAssessment;
- AuthorityDisposition;
- reason-specific suspension recovery;
- dependency satisfaction;
- CandidateRef comparisons.

## Contract

Provider capability and lifecycle contract.

Preserve accepted H-020 vocabulary and prove V4.1 interpretation does not silently alter prior semantics.

## Failure

Malformed/partial/unavailable provider states.

Include:

- external/manual forward provider transition;
- provider `Done` without completion proof;
- configuration drift;
- ambiguous provider submission.

## Concurrency

Where side effects or races exist.

Mandatory for H-040 transition submission/verification.

## Restart

Where durable authority exists.

Include open AttemptLineage and open SuspensionContext.

## Integration

Provider adapter against deterministic test doubles.

Source-control candidate binding against deterministic GitHub test seams.

## Live proof

Only designated H-100/H-110 phases may satisfy release claims using real external resources.

H-100 must include external/human exact-candidate merge → verified Done → downstream dependency satisfaction.

## Security / negative authority tests

Explicitly prove:

- ProviderObservation cannot directly grant Ready/Ready-to-Merge/Done authority;
- runtime cannot clear its own suspension;
- RuntimeAttempt from stale lineage generation cannot act;
- candidate movement invalidates prior readiness.

## Coverage

H-010 coverage authority remains mandatory.

Any module entering destructive lifecycle/recovery work becomes coverage-authoritative.

---

# 29. Performance Review Checklist

Every phase must explicitly answer:

```text
What layer does this data belong to?
hot / durable / external?

Does it cause unnecessary provider calls?

Can data be represented as one reconciliation epoch?

Can it be streamed/batched instead of loaded repeatedly?

Does it create N+1 provider access?

Is bounded concurrency required?

What invalidates the projection?

Can restart reconstruct it safely?
```

For V1:

```text
Redis:      N/A
Postgres:   N/A
DB indexes: N/A
Cachex:     N/A unless a measured need appears
PubSub:     observational only if introduced
ETS:        permitted for hot non-authoritative projections
DETS:       narrow durable safety authority only
```

---

# 30. Global Security STOP Conditions

STOP implementation immediately on:

- baseline/authority conflict;
- unexpected `main` movement;
- dirty implementation worktree;
- scope crossing into later programme;
- invariant weakening;
- direct Plane credential inside repo;
- raw agent Plane mutation;
- direct Plane database access;
- silent routed → legacy downgrade;
- claiming Plane CAS support;
- trusting Plane mutation response as success;
- classifying a possibly-submitted mutation as retryable `ProviderFailed`;
- trusting webhook payload as current truth;
- treating provider observation as automatic canonical lifecycle advancement;
- treating raw Plane `Done` as dependency satisfaction;
- making Plane `Blocked` the only automation-stop mechanism;
- clearing suspension without reason-specific recovery guards;
- auto-resuming retry exhaustion without H-030 rearm;
- ambiguous bare `generation` introduced where lineage/execution semantics differ;
- incomplete dependency graph;
- credentialed Git through agent-controlled repo;
- manual DETS deletion as recovery;
- trusting agent-writable workspace ownership marker;
- CandidateRef mismatch ignored;
- candidate SHA movement after approval ignored;
- human merge of non-approved candidate accepted as Done;
- H-080 runtime isolation failure;
- production resource before H-100;
- evidence produced from a different candidate SHA;
- automatic merge without separately accepted authority;
- need for Redis/Postgres/multi-node authority before its programme.

---

# 31. Programme A Scaffolding TOON Prompt

| Field | Content |
|---|---|
| **Task** | Implement the V4.1 Authority Foundation programme incrementally on top of accepted Symphony `main` `46cb22e33dc87729f56f1c07158992c63a84ac27`, preserving H-010/H-020/H-030 authority while replacing Linear as the target primary routed provider with Plane through provider-neutral work-control semantics and explicit separation of provider observation, validated lifecycle and autonomous authority. |
| **Objective** | Produce a hardened V1 where Plane supplies structured work intent and observations, Symphony validates lifecycle and owns autonomous authority/suspension, GitHub owns SCM evidence, Codex remains bounded execution, exact candidate identity is explicit, and restart/provider/manual-state/security failures fail closed. |
| **Output** | Separate reviewed branches/PRs for V4.1-000, P-010, P-020, P-030, P-040, H-040, H-050A-D, H-060A-C, H-070A-B, H-080A-C, H-090, H-120A, H-100, H-110 and H-120B. |
| **Note** | Do one phase/subphase only per authorized task. Never self-authorize the next phase. Preserve accepted historical provenance and accepted H-020 capability vocabulary. Plane REST is the trusted provider boundary; MCP is not. Provider observations, mutation responses and webhooks are not lifecycle authority. Symphony must suspend locally without depending on Plane `Blocked`. `conditional_transition` remains unsupported. Use minimal clean Elixir/OTP implementation and existing repo conventions. CandidateRef is a thin V1 value object, not Programme B Candidate persistence. Performance: OTP/ETS hot projection where justified; DETS narrow durable safety state; Redis/Postgres/indexes/CDN/browser cache/PubSub N/A unless a later explicitly authorized phase establishes need. STOP on baseline mismatch, scope crossing, invariant weakening, credential exposure, provider observation granting unsafe forward authority, incomplete provider evidence, candidate mismatch, ambiguous mutation misclassification, unexpected architecture dependency, or failed required verification. Tools: `git`, `rg`, `mix`, `mise`, `gh`; Plane MCP read-only only where provider comparison evidence is necessary. |

---

# 32. Programme A TOON Micro-Prompts

## V4.1-000

| Field | Content |
|---|---|
| **Task** | Create the V4.1 hardening authority documentation without changing production Elixir code. |
| **Objective** | Preserve H-010/H-020/H-030 accepted history and establish one deterministic Plane-based roadmap with explicit observation/lifecycle/authority separation, suspension recovery, exact candidate binding and verified completion. |
| **Output** | `docs/symphony-hardening-playbook-v4.1/README.md`, `HARDENING_STATUS_LEDGER.md`, `V3_ACCEPTED_AUTHORITY.md`, revised phase documents, invariant summary, and P-000 Plane evidence summary. |
| **Note** | Do not rewrite accepted historical facts or H-020 vocabulary. No implementation. Include accepted SHA/tree. Record P-000 as accepted feasibility. Performance/cache/TTL/Redis/Postgres/indexes/PubSub: N/A documentation phase. Tools: `git`, `rg`. STOP if historical acceptance would need alteration, Programme B must be pulled forward, or any production code change is required. |

## P-010

| Field | Content |
|---|---|
| **Task** | Introduce provider-neutral WorkItem, ProviderObservation, canonical WorkflowLifecycle, LifecycleAssessment, GuardClass, AuthorityDisposition and SuspensionContext policy semantics while preserving existing provider behavior. |
| **Objective** | Make lifecycle authority independent of Linear/Plane and prevent provider observations from silently granting forward autonomous authority or successful completion. |
| **Output** | Minimal modules under `elixir/lib/symphony_elixir/work_control/`, focused tests under `elixir/test/symphony_elixir/work_control/`, and minimal integrations with existing Router/TransitionPolicy seams. |
| **Note** | Do not add Plane HTTP. Avoid mass Tracker renaming. One canonical lifecycle only. Plane `Blocked` is not the suspension mechanism. Provider observation `Ready`, `Ready to Merge` or `Done` must not grant corresponding authority without canonical guards. Keep code minimal; use pure policy functions where possible. Redis/Postgres/indexes/TTL/PubSub N/A; pure policy has no cache. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if existing provider behavior must be redesigned, a second lifecycle truth emerges, or Orchestrator restructuring becomes necessary. |

## P-020

| Field | Content |
|---|---|
| **Task** | Add the provider-neutral project contract plus Plane-specific validation, configuration-drift classification and local authority suspension. |
| **Objective** | Prevent autonomous execution against renamed/deleted/remapped provider configuration even when Plane cannot safely be mutated. |
| **Output** | `elixir/lib/symphony_elixir/work_control/provider_project_contract.ex`, `elixir/lib/symphony_elixir/plane/project_contract.ex`, focused validation/drift/suspension tests and configuration parsing changes. |
| **Note** | Stable IDs are authority; names are descriptive. No automatic similarly-named replacement. No Plane mutation required to suspend. Drift opens SuspensionContext and fails closed. Fingerprint only semantics Symphony depends upon. Redis/Postgres/indexes/TTL/PubSub N/A. Invalidation trigger: provider contract mismatch forces local authority suspension. Tools: `git`, `rg`, `mix`, `mise`, `gh`; Plane MCP read-only if needed. STOP on ambiguous bootstrap semantics, reliance on Plane Blocked for safety, or need for paid Plane-only feature. |

## P-030

| Field | Content |
|---|---|
| **Task** | Implement the read-only Plane REST provider foundation producing ProviderObservation and provider-neutral state mapping. |
| **Objective** | Support authoritative Plane refresh without allowing provider reads to directly advance validated lifecycle or authority. |
| **Output** | `elixir/lib/symphony_elixir/plane/client.ex`, `adapter.ex`, `state_projection.ex`, configuration support, HTTP test doubles and focused tests. |
| **Note** | Token host-side only. REST, not MCP, is production boundary. Declare only capabilities actually implemented. Plane reads create observations; LifecycleAssessment decides meaning. No dependency graph or state mutation. Cache: none for safety reads; fresh reads required. TTL N/A. Redis/Postgres/indexes/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP on credential-in-repo requirement, provider ambiguity, direct observation→authority coupling, or silent legacy fallback. |

## P-040

| Field | Content |
|---|---|
| **Task** | Implement complete Plane dependency graph projection and immutable reconciliation epochs using validated lifecycle/completion semantics. |
| **Objective** | Give Symphony deterministic dependency safety over Plane `blocked_by`/`blocking` relations without allowing raw provider Done to satisfy prerequisites. |
| **Output** | `elixir/lib/symphony_elixir/plane/dependency_projection.ex`, dependency epoch integration and focused completeness/cycle/completion tests. |
| **Note** | Enumerate all paginated work items; fetch all relations with bounded concurrency; any failed relation read invalidates epoch. Validated Done + required CompletionProof satisfies; Canceled invalidates; raw observed Done does not satisfy. SCC once per epoch. Hot layer may use immutable OTP/ETS projection; invalidation on new reconciliation/provider event. Redis/Postgres/indexes/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if completeness cannot be proven or dependency policy needs raw provider state. |

## H-040

| Field | Content |
|---|---|
| **Task** | Harden Plane lifecycle mutation using durable TransitionAttempt state, canonical lifecycle assessment and mandatory post-mutation verification. |
| **Objective** | Safely operate despite Plane lacking provider-side conditional/CAS transitions and prevent ambiguous submissions from becoming blind retries. |
| **Output** | TransitionAttempt implementation/tests integrated with existing `tracker/transition_policy.ex` and durable safety state. |
| **Note** | Fresh read → assess → authorize → durable Prepared+sync → mutate → fresh reread → reassess. Ignore mutation response as proof. If mutation may have reached Plane and non-commit cannot be proven, classify `Indeterminate`, never retryable `ProviderFailed`. Conflict/Indeterminate suspend automation. `conditional_transition` stays unsupported. Redis/Postgres/indexes/PubSub N/A. No safety caching. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if CAS is assumed, mutation must be retried blindly, durable Prepared cannot be proven before side effect, or ambiguous outcome is classified retryable. |

## H-050A

| Field | Content |
|---|---|
| **Task** | Introduce the mechanical `Runtime.Authority` contract for each responsibility profile, including exact semantic lifecycle commands each role may request. |
| **Objective** | Separate what Plane/integration can support from what Planner/Builder/Reviewer/Fixer may request or do. |
| **Output** | Authority modules under `elixir/lib/symphony_elixir/agent_runtime/`, profile integration, lifecycle-command permission map and negative capability tests. |
| **Note** | Planner may request Planning→Ready; Builder Ready→In Progress and In Progress→In Review; Reviewer In Review→Changes Requested/Ready to Merge; Fixer Changes Requested→In Review; Merge Gatekeeper may verify external merge but not auto-merge in V1. These are semantic requests, not raw Plane mutation. Child/runtime authority never derives implicitly from provider capabilities. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if prompts rather than code become the only enforcement or a role receives raw provider mutation. |

## H-050B

| Field | Content |
|---|---|
| **Task** | Expose project-scoped semantic Plane read and lifecycle-request operations through the trusted host boundary. |
| **Objective** | Remove the need for raw Plane API authority inside autonomous runtime sessions. |
| **Output** | Narrow host tool modules/tests for current work item, dependencies, lifecycle assessment, authority disposition and authorized lifecycle requests. |
| **Note** | No arbitrary REST/MCP passthrough. Credentials remain host-side. Every operation project-scoped. Lifecycle requests must pass Runtime.Authority and canonical guards before H-040 mutation. Redis/Postgres/indexes/TTL/PubSub N/A. Provider snapshot invalidation follows reconciliation/transition events. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if agent needs raw token, generic mutation, or direct suspension/rearm control. |

## H-050C

| Field | Content |
|---|---|
| **Task** | Formalize Source Control authority independently from Plane and introduce thin immutable V1 `CandidateRef` plus merge-verification support. |
| **Objective** | Allow Reviewer/Merge Gatekeeper to reason about exact GitHub candidate/CI/merge facts without gaining unrelated provider/source mutation authority. |
| **Output** | Minimal SourceControl behavior/seam where justified, `CandidateRef`, GitHub capability mapping, exact PR-head/candidate checks, merge-verification operation and role-policy tests. |
| **Note** | CandidateRef contains repository identity, base SHA, candidate SHA, PR identity and observed PR head SHA. No Candidate database or EvidenceBundle. Candidate movement invalidates review/merge readiness. V1 human merge must be verified against approved CandidateRef before Done. Do not perform large GitHub directory migration unless required. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP on aesthetic refactor, CandidateRef mismatch being tolerated, or unexpected tracker coupling requiring broader redesign. |

## H-050D

| Field | Content |
|---|---|
| **Task** | Mechanically enforce provider/SCM credential, recovery and trusted-channel boundaries. |
| **Objective** | Prevent autonomous runtime or agent-controlled repositories from acquiring/redirecting trusted credentials or clearing durable safety controls. |
| **Output** | Credential/channel/recovery guards plus adversarial negative tests. |
| **Note** | No Plane token in agent env/workspace. No credentialed Git launched from untrusted repo configuration. No raw provider mutation channel. Runtime cannot clear SuspensionContext, rearm lineage or forge CandidateRef acceptance. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP on credential leakage or inability to mechanically isolate trusted channel. |

## H-060A

| Field | Content |
|---|---|
| **Task** | Bind autonomous runtime events to current RuntimeAttempt identity, `lineage_generation` and responsibility, and reject stale events. |
| **Objective** | Prevent delayed prior authority from affecting current execution while keeping V1 taxonomy compatible with future Programme B Execution. |
| **Output** | RuntimeAttempt identity propagation, terminology cleanup and stale-event tests in runtime/orchestrator seams. |
| **Note** | Use explicit `runtime_attempt_id` and `lineage_generation`; avoid ambiguous bare `generation`. Programme B Execution supersedes/generalizes RuntimeAttempt later. Identity validation is mechanical. Hot state may use OTP/ETS; invalidated when lineage generation changes. Redis/Postgres/indexes/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if event identity cannot be verified before side effect or future Execution is introduced prematurely. |

## H-060B

| Field | Content |
|---|---|
| **Task** | Implement startup reconciliation across durable safety state, open SuspensionContext, Plane observations, dependency graph and runtime state with reason-specific recovery. |
| **Objective** | Ensure restart never silently restores stale autonomous authority or clears a safety suspension. |
| **Output** | Startup reconciliation state machine, durable suspension integration where required, and restart/fault/recovery tests. |
| **Note** | Do not restore runtime sessions blindly. Provider contract validates first. Snapshot completeness required. Retry exhaustion requires H-030 host rearm; configuration drift requires contract revalidation; provider indeterminate requires fresh reconciliation; security suspension requires explicit authorized recovery. Hot projections rebuilt after restart. Redis/Postgres/indexes/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP on any path dispatching before reconciliation completes or any generic “clear Blocked” recovery path. |

## H-060C

| Field | Content |
|---|---|
| **Task** | Harden workspace ownership, shutdown and destructive recovery. |
| **Objective** | Prevent stale/foreign workspaces from being treated as safely owned. |
| **Output** | Workspace ownership metadata/guards and destructive-operation tests. |
| **Note** | Agent-writable marker alone is never trusted ownership evidence. Workspace module enters coverage authority. Suspension may require workspace preservation. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if cleanup cannot prove trusted ownership or violates SuspensionContext preservation policy. |

## H-070A

| Field | Content |
|---|---|
| **Task** | Prove Plane dependency/lifecycle reconciliation performance and provider-rate safety at the V1 scale envelope. |
| **Objective** | Prevent full-graph and lifecycle correctness from causing API storms or scheduler starvation. |
| **Output** | Synthetic >=1000 item / >=5000 edge tests, bounded request scheduling and metrics/evidence. |
| **Note** | O(N) provider relations are accepted but bounded. One SCC computation per epoch. Lifecycle assessment must consume snapshot data rather than create per-dispatch N+1 reads. Hot graph may live OTP/ETS and is invalidated per new epoch. Redis/Postgres/indexes/PubSub N/A. No Cachex unless measurement proves need. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if provider calls are unbounded or reconciliation causes unsafe scheduler behavior. |

## H-070B

| Field | Content |
|---|---|
| **Task** | Add signed Plane webhook wake-ups with deduplication, fresh ProviderObservation and authoritative REST reconciliation. |
| **Objective** | Improve freshness/reduce unnecessary polling without making events or webhook state a second truth source. |
| **Output** | Webhook verification/dedup/reconciliation modules and duplicate/out-of-order/replay/lifecycle-bypass tests. |
| **Note** | Verify signature; dedup delivery ID; webhook only schedules reread. Fresh REST read creates new observation; lifecycle is reassessed. Periodic full reconciliation remains. Event cache TTL only as required for dedup and bounded retention; Redis/Postgres unnecessary in single-node V1; ETS/DETS may be used if justified by restart semantics. PubSub N/A for authority. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if webhook content directly advances canonical lifecycle or authority. |

## H-080A

| Field | Content |
|---|---|
| **Task** | Execute adversarial characterization of the integrated authority boundaries including external-provider-state and exact-candidate bypass attempts. |
| **Objective** | Find authority bypasses before production proof. |
| **Output** | Security evidence for project-scope escape, provider bypass, manual state bypass, fake Done, suspension clearing, dependency manipulation, configuration drift, retry reset, CandidateRef substitution and SCM escalation attempts. |
| **Note** | Evidence only from trusted test harness. Include H-I19 through H-I24. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP and classify release-blocking if a mechanical boundary is absent. |

## H-080B

| Field | Content |
|---|---|
| **Task** | Prove actual runtime filesystem/network/tool isolation for each responsibility profile and prove runtime cannot bypass semantic provider/SCM/recovery boundaries. |
| **Objective** | Ensure runtime capabilities match `Runtime.Authority`. |
| **Output** | Isolation evidence and negative tests. |
| **Note** | Prompt instructions are insufficient. External containment may satisfy the requirement only when explicitly evidenced. Runtime must not access Plane/GitHub credentials, raw mutation channels, suspension clearing or lineage rearm. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: minimal runtime/security tools plus `git`/`mix`. STOP if required isolation cannot be proven. |

## H-080C

| Field | Content |
|---|---|
| **Task** | Re-run integrated security proofs after all authority seams, candidate binding and isolation changes. |
| **Objective** | Detect regressions introduced by integration. |
| **Output** | One consolidated exact-head security verdict covering H-I12 through H-I24. |
| **Note** | No source change unless separately authorized from a finding. Performance infrastructure N/A. Tools: verification only. STOP on any unresolved critical/high authority bypass. |

## H-090

| Field | Content |
|---|---|
| **Task** | Review structural seams and perform only correctness-driven extraction required for maintainability/security. |
| **Objective** | Keep the Orchestrator understandable without introducing unnecessary architecture. |
| **Output** | Seam assessment and narrowly-scoped extraction only if evidence justifies it. |
| **Note** | No aesthetic refactor. One Orchestrator authority remains. Reassess Tracker/WorkControl naming here. Confirm CandidateRef/CompletionProof have not become premature Programme B domains. Redis/Postgres/indexes/TTL/PubSub N/A. Tools: `git`, `rg`, `mix`, `mise`, `gh`. STOP if proposed extraction changes semantics or expands scope. |

## H-120A

| Field | Content |
|---|---|
| **Task** | Establish the pre-live-proof governance gate, exact candidate freeze and human-merge proof procedure. |
| **Objective** | Make H-100/H-110 evidence provenance-safe and ensure Done closure can be proven without granting auto-merge. |
| **Output** | Governance checklist, exact required checks, evidence locations, CandidateRef freeze procedure, disposable Plane/GitHub proof plan and human merge procedure. |
| **Note** | Documentation/governance only unless a separate defect is discovered. Infrastructure cache/index/Redis/Postgres/PubSub N/A. Tools: `git`, `gh`. STOP if candidate cannot be uniquely frozen or merge verification cannot distinguish the approved SHA. |

## H-100

| Field | Content |
|---|---|
| **Task** | Execute the complete real disposable Plane → Symphony → Codex → GitHub lifecycle proof against the exact frozen candidate through validated Done and downstream dependency release. |
| **Objective** | Prove the architecture outside deterministic test doubles, including provider-observation safety and human merge closure. |
| **Output** | External evidence for Planning→Ready→In Progress→In Review→Changes Requested→In Review→Ready to Merge→human exact-candidate merge→verified Done; dependency blocking/release; cancellation; provider failure/indeterminate; manual state bypass rejection; exact CandidateRef/CI; reviewer independence. |
| **Note** | No source modifications during proof. Use disposable Plane/GitHub resources only. Same exact SHA throughout. Deliberately test manual Plane Ready-to-Merge/Done attempts and prove they cannot bypass guards. Human, not Symphony, performs V1 merge. Symphony verifies merged SHA then performs controlled Done closure and fresh reread. Performance/cache/Redis/Postgres/PubSub remain as implemented by frozen candidate; do not add infrastructure during proof. Tools: deployed Symphony, Plane REST/test workspace, Codex, GitHub/`gh`. STOP immediately if tested SHA changes or merge candidate differs from CandidateRef. |

## H-110

| Field | Content |
|---|---|
| **Task** | Execute restart, failure, provider, suspension and candidate-integrity soak against the same frozen candidate used by H-100. |
| **Objective** | Prove durable authority under realistic interruption, external state changes and uncertainty. |
| **Output** | Soak evidence for restart, timeout, ambiguous mutation, stale events, configuration drift, dependency failures, open SuspensionContext, workspace recovery, retry exhaustion, manual provider forward transitions, candidate movement and wrong-candidate merge. |
| **Note** | No implementation changes. Evidence from any different SHA is invalid. Tools: controlled test/failure harness plus Plane/GitHub/Codex. STOP on SHA mismatch, unreconciled authority ambiguity, suspension cleared without its guard, or possibly-committed mutation treated as retryable failure. |

## H-120B

| Field | Content |
|---|---|
| **Task** | Perform final independent release acceptance over the exact frozen V1 candidate and its external evidence. |
| **Objective** | Decide whether the hardened Plane-based Symphony authority kernel is fit for controlled production adoption. |
| **Output** | `ACCEPTED`, `REJECTED`, or `BLOCKED`, with exact SHA/tree/CandidateRef/evidence references and known limitations. |
| **Note** | Reviewer must be independent of implementation evidence authorship. No self-attestation. Explicitly verify H-I19 through H-I24, reason-specific suspension recovery, ProviderFailed/Indeterminate classification and human merge→verified Done. No code changes. Performance infrastructure N/A. Tools: `git`, `gh`, evidence readers only. STOP after verdict; do not self-authorize rollout. |

---

# 33. V1 Success Definition

Programme A succeeds only when all of the following are true:

```text
Plane provider contract validated

provider observations are preserved truthfully
but cannot silently grant forward autonomous authority

canonical lifecycle centralized

guard classes explicit and non-interchangeable

AuthorityDisposition is Symphony-owned

reason-specific SuspensionContext recovery works

dependencies complete and deterministic

raw Plane Done never satisfies dependencies

validated Done requires CompletionProof

Plane transitions verified by fresh reread + lifecycle reassessment

possibly-submitted provider mutation is Indeterminate unless non-commit is proven

read→write race explicitly classified

runtime authority mechanical

Planner/Builder/Reviewer/Fixer lifecycle-command permissions explicit

provider tools semantic and project-scoped

GitHub authority independent

CandidateRef binds review / PR head / merge readiness

candidate movement invalidates approval

human exact-candidate merge is independently verified

controlled Plane closure produces freshly verified validated Done

downstream dependency release occurs only after validated Done

credentials mechanically bounded

AttemptLineage survives restart

RuntimeAttempt uses explicit runtime_attempt_id + lineage_generation

stale runtime events rejected

suspension survives restart when required

workspaces safely owned

graph performance bounded

webhooks reconciliatory only

runtime isolation proven

exact frozen candidate passes full live lifecycle through Done

same candidate passes failure / suspension / candidate-integrity soak

independent release gate accepts it
```

Only then may V1 be considered hardened.

---

# 34. Future Success Definition

The mature product succeeds when Symphony can eventually support:

```text
multiple work-control providers
multiple execution runtimes
first-class execution identity
candidate-bound evidence
risk/evidence profiles
human escalation
bounded role-local subagents
local OTP coordination
remote execution where justified
```

without altering:

```text
canonical lifecycle law
dependency law
review independence
candidate identity
authority boundaries
evidence requirements
```

Compute is replaceable.

Provider UI is replaceable.

The authority kernel is the product.

---

# 35. Final V4.1 Doctrine

> **Plane expresses structured engineering intent and provider observation.**

> **Provider observation is not lifecycle authority.**

> **Repository law defines technical correctness.**

> **Symphony validates lifecycle, grants/revokes autonomous authority, and owns suspension.**

> **GitHub establishes source-control, candidate, merge and CI facts.**

> **Execution runtimes perform bounded computation.**

> **Evidence and guard class determine what may be trusted.**

> **Successful completion requires validated completion proof.**

> **Humans retain unresolved-decision and V1 merge authority.**

And the sequencing rule remains:

> **Harden authority first.**

> **Make execution identity and evidence explicit second.**

> **Add supervised autonomy third.**

> **Add distributed infrastructure only when measured need demands it.**
