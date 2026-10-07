# Symphony V4.1 — Unified Execution Roadmap

**Document version:** **v1.3.2**\
**Status:** Canonical working roadmap for the next stage of Symphony V4.1 development\
**Purpose:** Reconcile the V4.1 hardening roadmap, current repository reality, governance decisions, the context/model-orchestration architecture, and the locked software-factory architecture into one execution sequence without creating a competing roadmap or authority kernel.\
**Primary rule:** **V4.1 remains the governing programme.** Evaluation findings and later architecture refinements are reconciled into V4.1 as completed work, bounded prerequisites, acceptance requirements for existing phases, or explicitly deferred Programme B/C/D/E/F requirements.

**v1.3.2 amendment scope:** Preserves prior architecture decisions, records the 2026-10-07 accepted governance baseline through H-080B, updates the current work to governance/documentation canonicalization, points active companion references to Skills Matrix v1.0.2, and clarifies that registry entries do not become repository law by registration. This amendment does not authorize H-080C or future programme implementation.

## Current Governance Baseline

PR #32 merged to protected `main` at `023b2269c93763a07fce0aeda541ec1adb7e0273`, tree `8be1aec5627f2b0672e44e6c53460383c3fe3110`.

Effective 2026-10-07, H-070B, REM-HI21, H-I20 remediation, H-080A, and H-080B are **ACCEPTED**. H-080C is **NOT AUTHORIZED**.

Until this roadmap and its companion Skills Matrix are canonicalized, the allowed scope is governance/documentation canonicalization only.


## Roadmap Scope Layers

The unified roadmap now distinguishes the following programme layers:

```text
Programme A / Hardened V1
    Authority kernel and proven production wiring

Programme B
    Engineering intent + execution identity + candidate + validation/evidence foundation

Programme C
    Supervised execution + Context Broker + deterministic governed skills + validator execution

Programme D1
    Optional runtime/model/adaptive execution-selection optimisation

Programme D2
    Optional remote/distributed authority expansion

Programme E
    Governed learning + engineering experience + repository-law/invariant improvement

Programme F
    Production observation + external signal intake + closed-loop outcomes
```

Programme D1 and D2 are **conditional optimisation/scaling branches**. They are not mandatory prerequisites for Programme E or F unless a concrete implementation dependency is proven. Describing a future programme in this roadmap never authorizes it to leak into V1.

## Document Authority Hierarchy

This document is the canonical **execution/sequencing** roadmap for completing V4.1 and staging later programmes. It does **not** silently supersede the normative V4.1 Master Roadmap.

The governing document hierarchy is:

```text
V4_1_MASTER_ROADMAP.md
    = normative V4.1 authority
    = hardening intent, locked invariants, programme boundaries

        ↓

SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md
    = canonical current execution/sequencing authority
    = reconciles later evidence, audits, accepted decisions and bounded prerequisites
    = may refine execution order but may not silently rewrite normative V4.1 law

        ↓

Canonical companion matrices / programme specifications (scope-specific peers)
    = detailed architecture/adoption authority only inside their assigned scope

        ↓

Machine contracts, including SkillContract
    = exact contracts within the authorized specification or matrix scope

        ↓

Runtime policy decisions
    = subordinate selection/materialization/admission decisions for one authorized execution
```

Conflict rule:

> If this Unified Execution Roadmap conflicts with the V4.1 Master Roadmap on a locked V4.1 invariant or programme boundary, the Master Roadmap governs until an explicit V4.1 amendment is accepted. This roadmap may refine execution ordering, insert bounded prerequisites discovered through later evidence, and stage future architecture without becoming a replacement authority kernel.

No programme specification, Skills Matrix row, future machine contract, skill, runtime adapter, selector, context projection, or policy decision may silently elevate itself above the governing documents that authorize it.

---

## 1. Canonical Architectural Position

Symphony is an **autonomous engineering control plane / authority kernel**.

Its job is to decide:

- what work exists;
- whether work may execute;
- which responsibility may execute it;
- which capabilities that responsibility receives;
- whether dependencies are satisfied;
- which side effects are permitted;
- which retry/review budget remains;
- which exact candidate is under consideration;
- what evidence is required;
- whether that evidence is still current;
- when autonomous work must stop;
- when human authority is required.

The coding agent is an execution runtime beneath Symphony. It is **not** Symphony's authority source.


### Long-term software-factory target

Symphony's long-term target is a **governed software-factory control plane**:

```text
authorized intent
    ↓
bounded execution
    ↓
exact candidate
    ↓
independently verifiable evidence
    ↓
controlled integration
    ↓
observable deployment/outcome
    ↓
governed learning
```

Symphony is not defined by a specific LLM, coding-agent vendor, tracker, RAG engine, number of agents, cloud, or distributed deployment. Its durable value lies in authority, policy, execution identity, candidate identity, evidence, lifecycle control, validation, reconciliation, and governed learning.

### Logical factory planes

The following are **logical responsibility/authority boundaries**, not a mandate for separate services:

```text
Signal Plane
    raw external/internal indications that work may be needed

Control Plane
    WorkControl / Orchestrator / authoritative lifecycle progression

Policy Plane
    deterministic authority, capability, risk, evidence, budget and readiness rules

Execution Plane
    bounded agent/runtime/tool execution

Context Plane
    authoritative references, bounded handoff, skills and validated knowledge projection

Evidence Plane
    trusted observations and exact-candidate proof

Observation Plane
    deployment/runtime/production facts

Learning Plane
    governed experience and improvement proposals derived from verified outcomes

Durable Data Plane
    authoritative operational state, evidence/provenance and promoted institutional knowledge
```

These planes must not collapse into competing schedulers or hidden authority stores.

### Locked doctrine

1. **Repository law defines correctness.**
2. **Symphony grants authority.**
3. **Capability is not authority.**
4. **Provider observations do not create forward authority by themselves.**
5. **Evidence must bind to the exact current identity/candidate where applicable.**
6. **Fresh independent review remains a safety boundary.**
7. **Missing safety-critical evidence fails closed.**
8. **Remote side effects are verified rather than assumed.**
9. **Restart must not recreate spent authority.**
10. **One orchestration authority remains the V1 model.**
11. **Complexity must be earned by a demonstrated invariant or bottleneck.**
12. **Programme B/C/D/E/F must not leak into V1 merely because future architecture has been described.**
13. **Least context is a safety principle.** An execution receives only the context required to perform its authorized responsibility correctly. Availability of prior context does not imply entitlement to receive it.
14. **Context propagation does not grant authority.** The existence of a provider-native conversation, transcript, prior runtime state, captured session state, or prior-agent summary does not authorize propagation into a later responsibility.
15. **Prior-agent reasoning is not trusted evidence.** A prior agent's conclusion, summary, confidence, rationale, or implementation narrative is not machine evidence merely because it was produced by an authorized execution.
16. **Responsibility boundaries are epistemic boundaries where independence matters.** Native session continuity may be preserved within the same compatible responsibility/authority envelope, but independent review must begin from clean-room context.
17. **Model/provider diversity is optional strengthening, not the definition of independence.** Clean-room context separation is mandatory where independent review is required; different model/provider families may be selected when risk or measured evidence justifies diversity.
18. **Workflow routing and execution/model selection are separate decisions.** Runtime/model selection may satisfy an already-authorized responsibility; it may not create, alter, or enlarge that responsibility or authority.
19. **Agents may request stronger execution capability but may not lower machine-mandated minimums.** Escalation is allowed; self-downgrade below policy is not.
20. **Skill text is not authority.** A skill, `SKILL.md` file, prompt fragment, developer instruction, retrieved procedure, or external skill framework cannot create, enlarge, replace, or waive Symphony authority.
21. **Skill selection is subordinate to responsibility routing.** `WorkflowLifecycle` / `Router` determines the authorized responsibility. A future `SkillSelectionPolicy` may select procedures useful inside that responsibility but may not create or change responsibility.
22. **Skill requirements do not grant capabilities.** A skill may declare required capabilities. Those requirements must fit within the execution's already-authorized capability envelope or selection must fail closed / escalate.
23. **Skill output is semantic output, not trusted evidence.** Statements, summaries, conclusions, or claimed verification emitted by a skill remain agent output unless converted into trusted evidence through an authorized evidence-acquisition path.
24. **Skills are progressively disclosed.** The existence of a skill in the catalogue does not entitle every execution to receive its full contents.
25. **Skill selection preserves least-context and clean-room boundaries.** Reviewer executions must not inherit implementation-oriented skill state, hidden reasoning, or skill-generated narrative merely because it exists.
26. **Skill version and provenance matter.** Future governed skills must have stable identity, version, content digest, and provenance sufficient to determine which procedure informed an execution.
27. **There remains one Symphony authority kernel.** Skill selection, context projection, and execution selection are subordinate policies and must not become independent schedulers, lifecycle owners, or authority sources.
28. **Success criteria precede final judgment.** Post-V1 governed implementation is judged against an explicit versioned `ValidationContract`; a fast path may use a compact contract but may not mean no contract.
29. **Fast path means less ceremony, never less proof.** Planning depth may vary; candidate identity, evidence and authority requirements remain policy-owned.
30. **Merge is not product success.** Candidate validation, integration validation, merge, deployment, observed health and intended outcome are distinct facts.
31. **Learning does not create truth.** Historical agent prose, RAG retrieval, model self-reflection and inferred lessons remain advisory until independently validated and governed.
32. **Repeated reliable judgment should become deterministic law where practical.** Recurring validated review findings should preferentially become tests, types, static checks, policy gates or explicit repository invariants.
33. **Safety-relevant governance must become machine-consumable.** Human governance remains authoritative, but critical acceptance/authorization state must not depend solely on prose that enforcement systems cannot interpret.

### Responsibility / skill / context / execution distinction

```text
Responsibility routing
= WHAT authorized engineering responsibility may act?

Skill selection
= WHICH bounded procedures may assist that responsibility?

Context projection
= WHAT authorized information and skill material may it receive?

Execution selection
= WHICH runtime/model/provider may satisfy the authorized requirements?

Authority
= WHETHER any of the above may occur at all.
```

---

### Canonical context-transfer semantics

Symphony distinguishes three context policies. These are architecture semantics first; Programme C will later own the full Context Broker implementation.

```text
resume
    Same responsibility and compatible authority/capability envelope.
    Native session continuity may be retained when the runtime proves it safely.

handoff
    New execution/responsibility/provider where prior work is useful.
    Start a new session and provide a bounded provider-neutral context package.
    Do not default to whole-transcript replay.

clean_room
    Independent verification/review.
    Start a new session with authoritative objective, repository law, exact candidate,
    trusted evidence, and acceptance criteria, while withholding prior-agent reasoning
    from the initial review context by default.
```

These policies do not themselves grant lifecycle authority. They govern how authorized executions receive information.

Skill material follows the same context law:

```text
resume
    May retain already-authorized skill context when responsibility, authority,
    capability envelope, and skill version remain compatible.

handoff
    Receives only selected skill descriptors/bodies required by the downstream
    responsibility. Prior skill narrative is not replayed automatically.

clean_room
    Starts from independently selected review/verification skills and
    authoritative ground truth. Builder/Fixer skill traces and conclusions
    are withheld by default.
```

Whole-skill-corpus injection is not an acceptable substitute for skill selection.

---

## 2. Agent-Agnostic, Linux-Targeted Runtime Rule

Symphony's **core runtime model must be agent-agnostic**.

Codex is the first supported runtime adapter, not the architectural owner of:

- RuntimeAttempt identity;
- authority;
- responsibility;
- workspace ownership;
- isolation requirements;
- credential boundaries;
- semantic tools;
- evidence;
- lifecycle;
- candidate identity;
- recovery semantics.

The current runtime-authority layering is:

```text
Symphony Authority Kernel
        ↓
RuntimeAttempt
        ↓
Responsibility + Capability Contract
        ↓
AgentRuntime
    ├── Isolation
    ├── Workspace
    ├── Credential Boundary
    ├── Semantic Tools
    └── Lifecycle / Evidence
        ↓
Agent Adapter
    ├── Codex
    ├── Claude Code
    ├── Gemini CLI
    ├── OpenCode
    └── future adapters
```


### RuntimeAttempt versus future Execution

`RuntimeAttempt` is the **ephemeral current runtime-authority identity** owned by the host/orchestrator. It is not the future durable engineering-execution domain object and must not be persisted wholesale merely because Programme B later introduces first-class `Execution`.

Durable safety history belongs in the dedicated authoritative boundaries that already own it, such as:

```text
attempt lineage / generation
RecoveryLedger
SuspensionContext
TransitionAttempt state
Workspace OwnershipLedger
other purpose-specific durable safety records
```

Programme-B `Execution` will later **supersede/generalize** the current runtime-attempt abstraction into a provider-neutral engineering identity. It must not coexist as a second competing execution-authority truth.

### CandidateRef versus future Candidate

`CandidateRef` is the **current V1 exact source-control candidate authority reference**. It binds the code candidate under consideration to the repository/source-control facts required by the current CompletionProof and review model.

At minimum, current/future candidate identity must preserve equivalent bindings for:

```text
repository identity
base SHA
candidate SHA
PR / change identity where applicable
observed remote PR/head SHA where applicable
current candidate generation/version where later policy requires it
```

Programme-B `Candidate` will later **generalize** `CandidateRef` into a durable provider-neutral software-factory candidate domain object. It must preserve the exact-candidate trust properties already established in V1 and must not coexist as a second competing candidate-authority truth. Until Programme-B `Candidate` is accepted, `CandidateRef` remains the authoritative V1 candidate identity.

The locked candidate-movement rule remains:

```text
candidate identity moves
    ↓
candidate-bound approval / evidence becomes stale
    ↓
required validation / review / evidence must be re-established
```

Preserve the distinction:

```text
Candidate
≠ merge
≠ accepted change
≠ deployment
≠ successful production/product outcome
```

A possible future Candidate lifecycle may include concepts such as `Proposed`, `Materialized`, `UnderValidation`, `Validated`, `Rejected`, `Superseded`, and `Integrated`, but the exact Programme-B lifecycle is deliberately deferred to the Programme-B domain-planning phase. This roadmap does not pre-authorize that exact state machine.

### Important limitation

**Agent-agnostic does not mean OS-agnostic.**

For V1 autonomous routed execution:

```text
SUPPORTED HOST
Linux

NOT REQUIRED / NOT CERTIFIED
macOS
iOS
Windows
```

Unsupported or unproven runtime hosts must fail closed.

Remote routed execution must also fail closed until its containment is mechanically proven.

### V1 restraint

Do **not** build multiple agent adapters now merely to prove the abstraction.

During V1:

- core contracts should be agent-neutral;
- Codex may remain the only implemented runtime adapter;
- Codex-specific sandbox controls may be used as defense in depth;
- Symphony-owned isolation remains the outer guarantee;
- no giant multi-runtime refactor is required.

A good long-term test is:

> Could a second runtime adapter be added later without redesigning WorkControl, RuntimeAttempt identity, workspace ownership, credential boundaries, semantic operations, candidate authority, or the isolation contract?

If not, a vendor-specific assumption has leaked into the kernel.

---

## 3. How the Two Evaluations Are Used

### Evaluation A — Repository / implementation audit

This audit was performed against the pre-H-080B accepted tree:

```text
COMMIT
56798754c8f6fd80d7ec53b604800873e339e030

TREE
a2770cbd2a5f4b96617b3fe18f324f0376d0cdf1
```

It identified concrete technical and governance gaps.

Important: its runtime-containment blocker predates PR #31 and therefore must be reconciled against H-080B rather than duplicated.

### Evaluation B — Unified Architecture & Operating Model

This is a working architecture/doctrine baseline.

It defines:

- Symphony as an authority/control plane;
- repository law;
- role separation;
- semantic tools;
- candidate/evidence discipline;
- one-authority orchestration;
- V1 hardening order;
- explicit deferral of Redis/distributed execution/multiple runtime implementations.

### Reconciliation rule

Do **not** create a second "AUDIT-R" development programme.

For each audit finding, classify it as one of:

```text
ALREADY RESOLVED BY V4.1
BOUNDED PRE-REQUISITE TO A V4.1 PHASE
ACCEPTANCE REQUIREMENT INSIDE A V4.1 PHASE
LATER V1 OPERATIONAL WORK
PROGRAMME B/C/D/E/F — DEFER
INVALID / SUPERSEDED
```

V4.1 remains the governing roadmap.

---

# 4. Unified Roadmap From the Current Point

```text
H-080B ACCEPTED
              ↓
CURRENT — GOVERNANCE/DOCUMENTATION CANONICALIZATION ONLY
   Unified Roadmap / companion canonicalization
              ↓
   Future PRE-080C prerequisite work, after canonicalization and normal issue authorization
              ↓
   PRE-H080C RECONCILIATION GATE
              ↓
   H-080C, only after separate authorization
                   ↓
        ┌──────────┼──────────┐
        ↓          ↓          ↓
   V1-OPS-01   V1-OPS-02   V1-OPS-03
   Observability Ledger DR   Operator
   / Readiness  & Rotation   Resolution
        └──────────┼──────────┘
                   ↓
                 H-090
       Orchestrator Structural Review
       / Refactor only if justified
                   ↓
                H-120A
         Governance / Freeze Gate
                   ↓
                 H-100
         Real Live Lifecycle Proof
                   ↓
                 H-110
        Failure / Restart Soak
                   ↓
                H-120B
      Independent Exact-Candidate
             V1 Acceptance
                   ↓
            HARDENED V1 COMPLETE
                   ↓
              Programme B
 Intent / Execution / Candidate /
 Validation / Evidence / Skills foundation
                   ↓
              Programme C
 Supervised Execution / Context Broker /
 Deterministic Skills / Validator Execution
                   ↓
        ┌──────────┼──────────┐
        ↓          ↓          ↓
   Programme E Programme F Programme D1
   governed    production  optional runtime /
   learning    observation model optimisation
   foundation  & outcomes
        └──────────┬──────────┘
                   ↓
    richer outcome-informed governed learning

Programme D2 — Remote / Distributed Expansion
= separate conditional branch only when measured operational need exists
```

Programme E, Programme F, and Programme D1 are not a mandatory serial chain. Programme E may begin from trustworthy accepted-candidate/review evidence once its prerequisites exist; Programme F may begin once accepted candidate/artifact identity can be reliably correlated with deployment/production observations; Programme-F outcomes may then strengthen Programme-E learning. Programme D1 remains optional and is not a prerequisite for E or F. Programme D2 remains a separate conditional branch.

---

# 5. H-080B Accepted Baseline

## Objective

H-080B is the accepted V4.1 response to the pre-H080B runtime-containment finding. Its acceptance is effective 2026-10-07 under the PR #32 reconciliation recorded above.

### Historical PR #31 merge and acceptance divergence

Before the 2026-10-07 reconciliation, the roadmap recorded PR #31 at `0bdd3960947bb2bafd34a7eb92e970eaae07a82a` as merged but not accepted and called for further merge/tree confirmation and an explicit acceptance decision. That was the pre-reconciliation state. PR #32 reconciled it and established H-080B acceptance. The earlier divergence remains historical provenance and is not current acceptance work.

The merged candidate carried pre-merge governance text stating that H-080B acceptance had not yet been granted and that merge should not yet occur. The PR #32 reconciliation preserved and resolved that historical contradiction.

### Accepted H-080B scope

- actual Linux runtime isolation;
- Planner/Reviewer read-only boundary;
- Builder/Fixer workspace-write-only boundary;
- sibling/parent/outside filesystem isolation;
- credential-channel denial;
- loopback / controlled socket denial;
- symlink/hard-link escape characterization;
- trusted executable/path invariant;
- PID-namespace descendant containment;
- retained authority on unconfirmed teardown;
- fail-closed unsupported platform behavior;
- fail-closed remote containment;
- actual Codex proof;
- mandatory CI proof.



### Accepted unconfirmed-containment rule

H-080B accepts the existing fail-closed behavior when termination cannot be proven:

```text
containment death not proven
    ↓
authority fence remains retained
    ↓
workspace / attempt ownership remains retained
    ↓
no replacement dispatch
```

This is a safe failure mode and does not by itself justify adding an asynchronous containment observer to H-080B. Final V1 must, however, define an authorized operator/recovery route under V1-OPS-03. Releasing this state requires positive host-owned proof that the containment unit is dead. Elapsed time, provider movement, missing heartbeat alone, agent assertion, or operator assertion alone are insufficient.

### Do not create a duplicate "runtime containment" issue

The pre-H-080B audit's `AUDIT-R-001` is mapped to H-080B / PR #31.

### H-080B acceptance and next boundary

```text
H-080B ACCEPTED — effective 2026-10-07
H-080C NOT AUTHORIZED
```

Roadmap and companion canonicalization precedes the future PRE-080C prerequisite work. Passing the PRE-H080C gate is necessary but does not authorize H-080C; H-080C requires separate explicit authorization.

---

# 6. PRE-080C-01 — Production Evidence Acquisition

**Priority:** P0/P1\
**Type:** Characterization first; remediation only if a real production gap is proven.\
**Blocks H-080C:** Yes.

## Why this exists

The implementation audit found strong evidence consumers and validators, but could not establish that the ordinary unseeded production path creates all evidence required for planner/build/fix/review lifecycle advancement.

The key distinction is:

```text
evidence validation exists
≠
production evidence acquisition exists
```

## Required investigation

Trace the real production path for at least:

```text
Planner finishes
→ where does planner semantic evidence originate?

Builder finishes
→ where does implementation completion evidence originate?

Reviewer finishes
→ where does independent-review evidence originate?

Fixer finishes
→ where does correction evidence originate?

Mechanical checks succeed
→ who observes them?
→ who converts them into trusted evidence?
```

Each safety-sensitive evidence item must answer:

- who creates it?
- who validates it?
- what WorkItem is it bound to?
- what RuntimeAttempt is it bound to?
- what lineage/generation is it bound to?
- what responsibility is it bound to?
- what candidate is it bound to, where applicable?
- can an agent fabricate an equivalent structure?
- does the production consumer revalidate provenance?

## Lifecycle to characterize

```text
runtime output
    ↓
host observation
    ↓
trusted evidence acquisition
    ↓
identity binding
    ↓
LifecycleAssessment
    ↓
transition authorization
```

## Non-goals

Do not introduce Programme B:

- EvidenceBundle;
- first-class Execution;
- first-class Candidate lifecycle;
- new V2 persistence.

Keep V1 minimal.

## STOP condition

If the default production path cannot progress without tests manually injecting fabricated evidence:

```text
DEFECT FOUND
→ preserve smallest reproducer
→ stop characterization
→ authorize bounded remediation
```

Do not let H-080C paper over this by injecting the missing evidence itself.

---

# 7. PRE-080C-02 — Production-Rate Epoch Characterization

**Priority:** P1\
**Type:** Performance / supported-envelope characterization.\
**Blocks H-080C:** Yes.

## Why this exists

H-070 proved scale/correctness behavior, but the audit identified a mismatch between aggressive scale-fixture pacing and production request pacing.

The current production-like acquisition cost can be materially larger than the fixture demonstrates.

## Required characterization

Measure production-equivalent behavior for at least:

```text
1,000 items
5,000 items
10,000 items
```

Measure:

- total epoch acquisition latency;
- provider request-start pacing;
- control-request latency while acquisition is active;
- memory behavior;
- webhook churn;
- continuous edit behavior;
- ability to publish a complete epoch;
- follow-up epoch behavior;
- dispatch availability during long acquisition.

## Required outcome

Exactly one of:

```text
PASS
→ supported V1 project envelope documented

LIMIT FOUND
→ supported envelope narrowed truthfully

REAL BOTTLENECK
→ smallest correction authorized
```

## Avoid

Do not jump directly to:

- Redis;
- a second authority node;
- distributed graph ownership;
- new persistence infrastructure.

Measure first.

---

# 8. PRE-080C-03 — Governance / Authority Documentation Reconciliation

**Priority:** P1\
**Type:** Governance/documentation correction.\
**Can run in parallel with PRE-080C-01/02:** Yes.\
**Blocks H-080C:** Yes, because fresh agents must not operate from contradictory authority.

## Scope

Reconcile:

- current accepted protected-main baseline;
- current phase status;
- merge vs acceptance distinction;
- stale hardening status ledger;
- legacy vs routed workflow documentation;
- Plane capability documentation;
- upstream-vs-fork clone guidance;
- historical vs current evidence;
- authority index;
- known unknown backlog/tracker authority;
- repository-local agent/skill instruction files, including `.codex/skills/**`;
- developer methodology documents such as Superpowers plans;
- distinction between developer convenience, runtime procedure, repository law, and trusted evidence;
- explicit precedence when skill/instruction prose conflicts with V4.1 authority;
- explicit disposition of stale/diverged PR #26 as historical, superseded, extractable-characterization material, or still-required work;
- explicit reconciliation of the PR #31 pre-merge governance state versus the actual merge event;
- a minimal machine-consumable governance status projection sufficient to detect safety-relevant roadmap/phase/baseline drift.


### Machine-consumable governance projection

PRE-080C-03 should define the smallest canonical representation necessary for tooling to consume human governance decisions without inventing a second workflow engine. The exact storage format/name is deferred, but it must be able to represent, at minimum:

```text
governing roadmap id/version
accepted protected-main SHA/tree
current accepted phase
currently authorized phase / bounded scope
decision authority/reference
decision timestamp
next authorized phase
known unresolved governance condition
```

Illustrative names such as `GovernanceAuthorityManifest` or `ProgrammeAuthorityStatus` are non-binding.

At minimum, automation should detect and surface:

```text
documented accepted baseline != canonical authority baseline
phase claimed by work/candidate != currently authorized phase
roadmap version referenced by governance state != governing roadmap version
```

Critical drift must fail closed at freeze/final-acceptance boundaries. Machine-consumable governance does not replace human governance; it makes accepted human governance enforceable by machines.

## Required principle

Repository law must not contradict itself.

A fresh agent must be able to determine:

- which roadmap is governing;
- which phases are accepted;
- which workflows are legacy compatibility;
- which workflows represent hardened routed operation;
- which evidence is historical;
- which evidence is current;
- what remains explicitly unknown;
- which skill/instruction artifacts are merely procedural guidance;
- which artifacts, if any, are canonical repository law;
- whether a skill can ever grant side-effect authority — the answer must remain **no**;
- what happens when skill prose conflicts with V4.1 authority.

Required skill/instruction outcome:

> Repository-local skill/instruction content is non-authoritative procedural context unless an explicit governing authority document says otherwise. No procedural skill may outrank WorkControl, `AuthorityDisposition`, RuntimeAuthority, SourceControl authority, or governing repository law.

## Do not

- rewrite history;
- invent missing approvals;
- declare a merge to be acceptance;
- move canonical authority from V4.1 into casual README prose;
- silently delete historical evidence.

## Relationship to H-120

This does not replace final governance.

```text
PRE-080C-03
= remove current contradiction / drift

H-120A/B
= freeze and exact-candidate final governance
```

---

# 9. PRE-H080C Reconciliation Gate

H-080C may be considered for separate authorization only after:

```text
H-080B
ACCEPTED

PRE-080C-01
ACCEPTED / NO UNRESOLVED EVIDENCE-PRODUCER GAP

PRE-080C-02
ACCEPTED / SUPPORTED ENVELOPE KNOWN

PRE-080C-03
ACCEPTED / CURRENT AUTHORITY DOCS RECONCILED
```

These prerequisites do not authorize H-080C. A separate explicit authorization is required after the gate.

At this gate, explicitly answer:

1. Can the real production path acquire every evidence class needed for V1 lifecycle advancement?
2. Is the supported project-size / acquisition-latency envelope known?
3. Can a fresh agent identify current authority without relying on stale ledger/README statements?
4. Does any unresolved finding require remediation before integration testing?

If any answer is no:

```text
STOP
```

---

# 10. H-080C — Integrated Security / Authority Reverification

**Priority:** P0 once prerequisites are complete.\
**Type:** Complete issue, one governance candidate.

## Purpose

Reverify the actual integrated production wiring after H-080A and H-080B, without mocked evidence shortcuts.

## Integrated path should cover

- real supervision path;
- Orchestrator;
- RuntimeAttempt identity;
- agent-neutral runtime isolation authority;
- Codex as the current adapter;
- workspace ownership;
- provider observation;
- lifecycle assessment;
- AuthorityDisposition;
- TransitionCoordinator;
- dependency graph;
- evidence acquisition;
- guard validation;
- semantic host tools;
- CandidateRef;
- completion verification;
- stale-event rejection;
- H-I19 through H-I24;
- positive controls;
- responsibility-bound runtime/context transitions;
- proof that Planner → Builder does not reuse planner runtime authority/session as builder authority;
- proof that Builder/Fixer → Reviewer starts an independent review execution rather than reusing implementation conversational context;
- proof that prior-agent summaries or reasoning cannot substitute for trusted evidence;
- repository-local skill/instruction authority containment;
- hostile or over-broad `SKILL.md` content;
- skill instructions requesting unavailable capabilities;
- skill instructions attempting semantic-tool expansion;
- skill instructions attempting provider transitions;
- skill instructions attempting SCM push/merge;
- skill instructions claiming machine evidence;
- skill instructions attempting to preserve Builder/Fixer context into Reviewer.

## Skill / instruction authority attack family

H-080C must demonstrate that skill or instruction content cannot:

```text
change WorkflowLifecycle responsibility
change the trusted Route/Profile
increase filesystem authority
increase network authority
obtain credentials
register arbitrary trusted semantic tools
grant provider mutation authority
grant source-control push/merge authority
release suspension
rearm lineage
create CompletionProof
satisfy MechanicalGuard from prose
substitute for trusted CI/evidence
defeat reviewer clean-room independence
```

Positive control:

> A valid skill may influence agent procedure inside the existing authorized envelope without being able to enlarge that envelope.

H-080C does **not** implement `SkillContract` persistence, `SkillSelectionPolicy`, skill scoring, AI skill routing, dynamic skill marketplace/discovery, skill-generated authority, skill-generated trusted evidence, a generic playbook engine, or a new workflow state machine. V1 proves only that existing and future skill instructions remain subordinate to the authority kernel.

## Critical rule

H-080C must use the evidence-acquisition path proven in PRE-080C-01.

It must not manufacture the exact trusted evidence it claims to verify.

## Context-boundary rule

H-080C must prove the V1 responsibility/context boundary without implementing Programme C early:

```text
Planner finishes
→ planning authority ends
→ Builder begins under a distinct authorized runtime session

Builder/Fixer finishes
→ implementation/correction authority ends
→ Reviewer begins from a distinct clean-room review execution
```

V1 does not require a Context Broker, multi-provider runtime, or dynamic model router. It does require proof that native session continuity cannot silently cross a responsibility boundary that depends on independent judgment.

## Agent-agnostic rule

H-080C should test Symphony-owned invariants.

Codex-specific tests may validate the current adapter, but the authority conclusions should not be encoded as Codex-specific semantics when the rule belongs to Symphony.

---

# 11. V1-OPS-01 — Observability Access & Readiness

**Priority:** P1/P2\
**Blocks H-080C:** No.\
**Required before final V1 freeze/live proof:** Yes.

## Purpose

Define the operational exposure model and distinguish:

```text
process liveness
≠
system readiness
≠
dispatch readiness
≠
authority readiness
```

## Scope

- snapshot access;
- refresh endpoints;
- LiveView access;
- unauthorized access behavior;
- unavailable snapshot responses;
- readiness response semantics;
- non-loopback deployment behavior.

Do not redesign the entire dashboard.

---

# 12. V1-OPS-02 — Durable Safety-State Recovery

**Priority:** P1\
**Blocks final V1 release/freeze:** Yes.

## Purpose

Define and prove coordinated backup, restore, rollback, retention, and key/credential-rotation behavior for the durable safety state.

## Scope

At minimum:

- AttemptLedger;
- TransitionAttemptLedger;
- RecoveryLedger;
- OwnershipLedger.

Define:

```text
quiesced backup
correlated restore
schema compatibility
rollback
signing-key rotation
credential rotation
retention/archive
conservative startup after restore
```

## Required safety outcomes

Restore must not:

- reset an exhausted lineage;
- replay an ambiguous provider mutation;
- release a suspension incorrectly;
- clear an authority fence incorrectly;
- adopt/delete a foreign workspace;
- treat invalidated signatures/evidence as current.

Avoid multiple concurrent ledger-schema changes without coordinated review.

---

# 13. V1-OPS-03 — Operator Suspension Resolution

**Priority:** P1/P2\
**Blocks final V1 release/freeze:** Yes.

## Purpose

Complete the minimal V1 operator contract for suspended/blocked work.

Define:

- who may acknowledge;
- who may resolve;
- required evidence;
- exact reason;
- exact resume target;
- forbidden resume cases;
- audit record;
- relationship to retry rearm.


For `containment_unconfirmed` / equivalent retained-fence cases, V1-OPS-03 must define an explicit recovery path. Recovery must require positive host-owned termination evidence before authority/workspace ownership can be released or replacement execution dispatched. Time passage, missing provider activity, or operator assertion alone do not prove containment death.

Provider movement alone must remain insufficient.

Do not implement the full Programme-B first-class Escalation resource in V1.

---

# 14. H-090 — Orchestrator Structural Review

**Priority:** After integrated behavior and V1 operational contracts stabilize.

## Rule

Do not refactor merely because `orchestrator.ex` is large.

The valid outcomes are:

```text
BOUNDED EXTRACTION JUSTIFIED
or
NO_EXTRACTION_REQUIRED
```

## If extraction is justified

- preserve one orchestration authority;
- extract pure/cohesive policy or state-handling boundaries;
- do not create a forest of competing GenServers;
- rerun affected H-080C security characterization.

No microservice/distributed rewrite.

---

# 15. H-120A — Governance / Freeze Gate

Before live proof, freeze:

- exact candidate SHA;
- exact tree;
- required configuration;
- supported Linux host contract;
- pinned runtime dependency/version;
- required checks;
- evidence requirements;
- machine-consumable governance status / governing roadmap version;
- accepted docs;
- operational procedures.

Once frozen:

```text
candidate change
→ old freeze invalid
→ affected proof must rerun
```

No live proof against one candidate and acceptance of another.

---

# 16. H-100 — Real Live Lifecycle Proof

Run one disposable, real lifecycle on the frozen candidate.

Expected shape:

```text
bounded issue
→ Planner
→ Ready
→ Builder
→ exact CandidateRef / candidate captured
→ Reviewer
→ human exact-candidate merge
→ CompletionProof
→ provider Done
→ downstream dependency unlock
```

This is real-integration evidence, not ordinary CI.

No candidate-changing work should occur while the proof is in progress.

---

# 17. H-110 — Failure / Restart Soak

Exercise the frozen candidate under failure.

At minimum include:

- restart during retry;
- restart after exhaustion;
- runtime death;
- provider throttling;
- uncertain mutation response;
- manual provider race;
- new blocker during execution;
- candidate SHA movement;
- stale runtime/provider events;
- workspace disappearance;
- containment failure;
- ledger recovery boundaries;
- operator-resolution boundaries.

Evidence must bind to the same frozen candidate.

---

# 18. H-120B — Independent Exact-Candidate V1 Acceptance

Final governance gate.

Requirements:

- exact candidate SHA/tree;
- all prior evidence traceable to that candidate;
- independent reviewer;
- reviewer runtime/session independent from the implementation/correction runtime;
- initial reviewer context contains the authoritative objective, repository law, exact candidate/diff, trusted machine evidence, and acceptance requirements, but does not inherit prior builder/fixer conversational context by default;
- prior planner/builder/fixer conclusions are not treated as machine evidence;
- no candidate self-certification;
- merge/acceptance distinction preserved;
- all required live/soak/operational evidence complete.

Only after this gate:

```text
HARDENED V1
ACCEPTED
```

---

# 19. Audit Finding → Unified Roadmap Mapping

| Audit finding | Unified disposition |
|---|---|
| Runtime containment | **H-080B / PR #31** |
| Production evidence acquisition | **PRE-080C-01** |
| Governance / documentation reconciliation | **PRE-080C-03 + H-120 final governance** |
| Production-rate epoch behavior | **PRE-080C-02** |
| Integrated authority verification | **H-080C** |
| HTTP access / readiness | **V1-OPS-01** |
| Ledger backup / restore / rotation | **V1-OPS-02** |
| Operator suspension / escalation | **V1-OPS-03** |
| Structural Orchestrator hardening | **H-090** |
| Freeze / governance pre-gate | **H-120A** |
| Disposable live lifecycle | **H-100** |
| Failure / restart soak | **H-110** |
| Independent V1 acceptance | **H-120B** |
| First-class Execution / Candidate / EvidenceBundle / workers | **Programme B/C — defer** |
| Provider-neutral handoff / bounded context transfer / clean-room review machinery | **Programme B/C — defer; V1 verifies boundaries only** |
| Runtime/model diversity and execution selection | **Programme D1 — conditional on measured quality/economics** |
| Multi-node / Redis / external coordination expansion | **Programme D2 — conditional on demonstrated distribution need** |
| Existing developer skill/instruction authority containment | **PRE-080C-03 + H-080C** |
| Governed `SkillContract` / skill catalogue | **Programme B — defer** |
| Progressive skill disclosure / skill-context projection | **Programme C — defer** |
| Deterministic authorized skill selection | **Programme C — defer** |
| Adaptive/model-assisted skill selection | **Programme D1 — conditional after behavioural evaluation** |
| Skill behavioural evaluation | **Programme B/C foundation; required before adaptive D1 routing** |
| Skill learning/RAG feedback | **Programme E — defer; only after governed evidence/outcome identity exists** |
| Planning-depth / compact-vs-spec contract | **Programme B — defer** |
| Product/Problem specification | **Programme B — defer** |
| Technical specification | **Programme B — defer** |
| Versioned `ValidationContract` / `ValidationAssessment` | **Programme B — defer** |
| Structured intent/decision provenance | **Programme B — defer** |
| Atomic trusted `EvidenceReceipt` | **Programme B — defer; composes `EvidenceBundle`** |
| Black-box / user-behaviour validation | **Programme B semantics / Programme C execution — defer** |
| Integration/synthetic-merge validation | **Programme B `EvidenceProfile` — defer** |
| Derived clean-room `ReviewPacket` | **Programme B/C — defer** |
| Structured `ReviewFinding` | **Programme B/C — defer** |
| Repository readiness/autonomy gating | **Programme B/C — defer** |
| Governed engineering learning / invariant promotion | **Programme E — defer** |
| Optional RAG/LightRAG knowledge projection | **Programme E — defer; non-authoritative** |
| Production observation / outcome assessment | **Programme F — defer** |
| External signal intake / work proposal | **Programme F — defer** |

---

# 20. Parallelism Rules

## Future PRE-080C work after canonicalization and issue authorization

The following can run largely in parallel:

```text
Lane A
PRE-080C-01 — Production Evidence Acquisition

Lane B
PRE-080C-02 — Production-Rate Epoch Characterization

Lane C
PRE-080C-03 — Governance Reconciliation
```

They converge at the PRE-H080C Reconciliation Gate.

## After H-080C

These can be planned independently:

```text
V1-OPS-01 — Observability / Readiness
V1-OPS-02 — Durable Safety-State Recovery
V1-OPS-03 — Operator Suspension Resolution
```

However:

- do not let separate agents concurrently mutate overlapping recovery/ledger/orchestrator code without coordinated sequencing;
- OPS-02 and OPS-03 require extra care because both can touch safety recovery semantics;
- OPS-01 is the safest independent lane.

## Freeze/live proof/soak

Do not overlap candidate-changing implementation with:

- H-120A freeze;
- H-100 live proof;
- H-110 soak;
- H-120B final acceptance.

Any candidate movement invalidates affected proof.

---

# 21. Permanent STOP Conditions

STOP if:

- a second "audit roadmap" starts competing with V4.1;
- an audit finding already solved by an accepted phase is reimplemented;
- H-080C begins before evidence acquisition and production-rate envelope are settled;
- H-080C relies on manually fabricated evidence that PRE-080C-01 was supposed to prove;
- Programme B/C/D/E/F entities leak into V1 remediation;
- "agent-agnostic" is used to justify implementing multiple runtime adapters during V1;
- a Symphony invariant can only be expressed as a Codex-specific setting when it can reasonably be enforced by Symphony;
- RuntimeAttempt identity becomes coupled to an agent session/thread ID;
- a vendor-native sandbox becomes the sole authority boundary for a Symphony invariant;
- unsupported runtime capability silently downgrades a required profile;
- macOS/iOS work or CI is added to H-080B/V1 without a new explicit platform decision;
- a non-Linux host silently falls back to unisolated routed execution;
- remote execution proceeds without proven containment;
- H-090 refactoring creates multiple mutable orchestration authorities;
- pre-H080C characterization prematurely turns into infrastructure expansion;
- Redis/Postgres/multi-node authority is added without a demonstrated requirement;
- governance reconciliation rewrites history rather than preserving provenance;
- live proof/soak is reused after candidate movement;
- merge is treated as acceptance without the required post-merge/final governance evidence;
- prior-agent reasoning, summaries, or confidence are promoted to trusted evidence without an authorized evidence-acquisition path;
- a Reviewer inherits Builder/Fixer conversational state in a way that defeats independent review;
- whole-transcript replay becomes the default handoff mechanism merely because the transcript is available;
- model/runtime selection is allowed to create or enlarge lifecycle responsibility or authority;
- an agent lowers a machine-mandated minimum capability/reasoning tier on its own authority;
- runtime/model diversity is coupled to Redis, multi-node authority, or distributed execution without a demonstrated reason;
- a skill can create or enlarge `WorkflowLifecycle` responsibility;
- a skill can enlarge `AuthorityDisposition` or RuntimeAuthority;
- a skill's declared requirements automatically grant unavailable capabilities;
- a skill can add trusted semantic tools outside the authorized host-side catalogue;
- a skill can expose host/provider/SCM credentials to the agent runtime;
- skill output is accepted as machine evidence without an authorized evidence-acquisition path;
- the complete skill library is injected into every execution by default;
- Reviewer receives Builder/Fixer skill narrative/state in a way that compromises clean-room review;
- `SkillSelectionPolicy` becomes a second lifecycle router, scheduler, workflow engine, or authority owner;
- adaptive/model-assisted skill selection becomes authoritative before behavioural evaluation establishes its safety and quality;
- skill version movement can occur invisibly inside an execution whose reproducibility/evidence depends on that skill.
- Fast Path is interpreted as no `ValidationContract` or weaker candidate/evidence requirements;
- an implementation worker silently weakens the `ValidationContract` judging its candidate;
- Product/Problem or Technical specification becomes a second `WorkflowLifecycle` authority;
- `ValidationContract` becomes a lifecycle router rather than a success/evidence contract;
- an `EvidenceReceipt` is trusted without provenance and exact-subject binding appropriate to its class;
- worker-produced evidence is treated as independent evidence where independence is required;
- a derived `ReviewPacket` becomes an independent authority store;
- black-box validation accepts Builder rationale instead of observable behavior;
- candidate-bound evidence is reused after candidate movement without explicit deterministic equivalence;
- integration evidence is reused after relevant target-base movement without revalidation;
- a RAG result or agent reflection becomes repository law;
- a learning proposal self-promotes;
- an invariant becomes active without governance;
- a production signal automatically creates code-mutation authority;
- merge is treated as successful product outcome without the required observation/assessment;
- a repository-readiness score overrides a missing mandatory capability;
- adaptive routing/selection is promoted without independent outcome evidence and the required shadow/offline evaluation.

---

# 22. Near-Term Development Workflow

```text
NOW
1. Canonicalize this roadmap and its companion Skills Matrix against the accepted PR #32 governance baseline.
2. Keep H-080C unauthorized.

NEXT, AFTER CANONICALIZATION AND NORMAL ISSUE AUTHORIZATION
3. PRE-080C-01 — Production Evidence Acquisition
4. PRE-080C-02 — Production-Rate Epoch Characterization
5. PRE-080C-03 — Governance / Authority Reconciliation, including repository-local skill/instruction authority classification

GATE
6. Reconcile all three results at the PRE-H080C gate.

THEN
7. Obtain separate explicit H-080C authorization after the gate.
8. H-080C — Integrated Security / Authority Reverification, only after separate explicit authorization, including responsibility/context-boundary proof and skill/instruction authority-containment attacks

AFTER H-080C
9.  V1-OPS-01 — Observability / Readiness
10. V1-OPS-02 — Durable Safety-State Recovery
11. V1-OPS-03 — Operator Suspension Resolution

THEN
12. H-090 — Structural Review / Bounded Refactor if justified
13. H-120A — Freeze
14. H-100 — Live Lifecycle Proof
15. H-110 — Failure / Restart Soak
16. H-120B — Independent Exact-Candidate V1 Acceptance using clean-room review context

THEN
17. Enter Programme B — first run the dedicated Programme-B backward-planning/domain-modeling pass, then implement bounded issue families for engineering intent, Execution/Candidate identity, ValidationContract, EvidenceBundle/Receipt/Profile, handoff and governed SkillContract foundations
18. Enter Programme C — first derive bounded issue families, then implement supervised execution, Context Broker, deterministic SkillSelectionPolicy, independent validator executions and progressive materialization
19. Once B/C foundations provide trustworthy accepted-candidate/review telemetry, begin Programme E foundation where prerequisites exist — governed EngineeringExperience, learning proposals and repository invariants
20. Begin Programme F when accepted Candidate/artifact identity can be reliably correlated with deployment/production observations; feed trustworthy OutcomeAssessments back into Programme E only through the governed learning path
21. Evaluate Programme D1 runtime/model/adaptive selection independently if measured quality/economics justify it; D1 is optional and is not a prerequisite for E or F
22. Evaluate Programme D2 distribution only if measured operational need justifies it
```

---

# 23. Hardened V1 Success Definition

At V1 completion we should be able to state, with evidence:

```text
Authority kernel
PROVEN



Governance status
MACHINE-CONSUMABLE / RECONCILED

Linux runtime isolation
PROVEN

Evidence acquisition
PROVEN

Production scale envelope
KNOWN

Workspace ownership
PROVEN

Candidate/completion binding
PROVEN

Provider mutation uncertainty
BOUNDED

Recovery / operator procedures
DEFINED AND TESTED

Integrated authority/security wiring
PROVEN

Structural ownership
REVIEWED

Real lifecycle
PROVEN

Failure/restart behavior
SOAKED

Exact candidate
INDEPENDENTLY ACCEPTED

Agent runtime
REPLACEABLE IN PRINCIPLE

Responsibility/context boundaries
PROVEN

Independent review context
CLEAN-ROOM BY CONTRACT

Skill/instruction authority containment
PROVEN

Production Skills Router
DEFERRED POST-V1

Multi-model/runtime diversity
DEFERRED UNTIL MEASURED

Distributed architecture
NOT ADDED WITHOUT DEMONSTRATED NEED
```

---

# 24. Programme B / C / D / E / F Boundary

Do not schedule these as V1 fixes merely because they appear in architectural planning. V1 proves responsibility/context boundaries and clean-room review semantics; the richer intent/specification, first-class execution/candidate/evidence, validator, handoff, context-broker, skill-selection, learning, production-feedback, model-selection, and multi-runtime machinery remains deferred.

## Programme B — Engineering Intent, Identity, Validation, Evidence, Handoff & Skill Contract Foundation

Programme B is an **architectural programme, not a single implementation issue or PR**. Before Programme-B implementation begins, a dedicated backward-planning/domain-modeling pass must derive the dependency order and decompose the programme into bounded governed issues.

Non-binding capability-family guidance for that future planning pass:

```text
B-FAMILY-1 — Execution / Candidate / Evidence identity foundation
B-FAMILY-2 — Intent / Product / Technical specification / planning depth
B-FAMILY-3 — ValidationContract / ValidationAssessment / integration validation
B-FAMILY-4 — ReviewFinding / ReviewPacket / independent verification structure
B-FAMILY-5 — Handoff / RepositoryReadiness
B-FAMILY-6 — SkillContract / SkillCatalogue / behavioural-evaluation identity
```

These labels are planning aids only. They do not establish final issue numbers, final dependency order, or implementation authority. The final order must be derived after Hardened V1 acceptance from the then-current repository/domain state.

Potential future work includes:

- `PlanningDepthAssessment` / compact-vs-spec planning selection;
- versioned Product/Problem specification;
- versioned Technical specification;
- first-class `ValidationContract` and per-candidate `ValidationAssessment`;
- structured `IntentDecision` / `IntentLedger`;
- first-class Execution;
- first-class Candidate lifecycle;
- atomic `EvidenceReceipt`;
- EvidenceBundle;
- EvidenceProfile;
- structured `ReviewFinding`;
- derived clean-room `ReviewPacket`;
- integration/synthetic-merge validation;
- richer Escalation;
- provider-neutral handoff readiness;
- RepositoryReadinessAssessment / autonomy gating;
- verified status projection;
- execution-cost and outcome observation sufficient to evaluate later routing policy;
- immutable/versioned `SkillContract`;
- governed `SkillCatalogue`;
- skill identity/version/digest and provenance;
- skill capability requirements and context requirements;
- skill evidence expectations and side-effect classification;
- skill applicability by responsibility and compatibility metadata;
- skill deprecation/supersession/revocation semantics;
- skill behavioural-evaluation identity.


### Planning-depth assessment and fast/spec paths

Programme B should add a subordinate planning assessment that chooses the **smallest sufficient planning contract** without becoming a lifecycle authority. It must not replace `WorkflowLifecycle` / Planner responsibility.

Conceptual outcomes:

```text
COMPACT
SPEC_REQUIRED
HUMAN_CLARIFICATION_REQUIRED
```

Inputs should include at least:

```text
ambiguity
architectural impact
security sensitivity
state/data impact
blast radius
reversibility
novelty
validation availability
repository readiness
```

Difficulty alone is insufficient to select the compact path.

The compact path means:

```text
minimal explicit intent where needed
+ compact sealed ValidationContract
+ normal execution authority
+ exact candidate identity
+ required trusted evidence
```

Never:

```text
FAST PATH
→ NO PROOF
```

This assessment changes planning depth only. It does not create new `WorkflowLifecycle` states or execution authority.

### Product / Problem specification

For work whose desired behavior is materially ambiguous, product-sensitive, high-risk, or cross-domain, Programme B should support a versioned Product/Problem specification describing **what should become true and why**.

Minimum content should include:

```text
problem statement
affected users/systems
desired outcomes
in-scope behavior
out-of-scope behavior
product/domain invariants
assumptions
open questions
```

Conceptual lifecycle:

```text
Draft
  ↓
Reviewed
  ↓
Approved
  ↓
Superseded

Rejected
```

An approved version is immutable. Amendment creates a new version with explicit supersession history.

### Technical specification

Programme B should support a versioned Technical specification for the intended engineering approach where the change is architecture-sensitive or sufficiently non-trivial.

Minimum content should cover, where applicable:

```text
architecture impact
domain/state ownership
interfaces/data contracts
migration/data effects
failure behavior
concurrency/recovery
security
observability
testing strategy
rollback/recovery strategy
```

Conceptual lifecycle:

```text
Draft
  ↓
Reviewed
  ↓
Approved
  ↓
Superseded

Rejected
```

A Technical specification cannot override repository law or silently change product intent.

### ValidationContract and ValidationAssessment

Programme B must introduce a versioned `ValidationContract` describing **how an independent evaluator will determine whether the intended change is correct**.

At minimum, bind:

```text
validation_contract_id
version
work_item identity
governing Product/Problem spec version where applicable
governing Technical spec version where applicable
required claims
required EvidenceProfile
required validator independence
required invariants
integration requirements
human-gate requirements
sealed_at / sealed_by
supersession reference
```

Contract lifecycle:

```text
Draft
  ↓
Reviewed
  ↓
Sealed
  ↓
Active
  ↓
Superseded / Retired

Rejected
```

The contract defines the test. Candidate pass/fail belongs to a separate assessment:

```text
ValidationAssessment

Pending
  ↓
Evaluating
  ├──→ Satisfied
  ├──→ Unsatisfied
  └──→ Inconclusive
```

The worker being judged may propose an amendment when implementation reveals a legitimate new fact, but may not silently weaken or approve the criteria by which its own candidate is judged. Any material amendment creates a new contract version and must preserve why the prior version changed.

### IntentDecision / IntentLedger

Implementation often discovers material facts that were not knowable at initial planning time. Those decisions must not live only in chat history.

Use an append-only `IntentDecision` record, with `IntentLedger` as the ordered projection of accepted/superseded decisions.

Minimum decision shape:

```text
decision_id
trigger / question
alternatives considered
selected option
reason
references / evidence
Product/Problem spec impact
Technical spec impact
ValidationContract impact
status
actor / authority reference
```

Conceptual lifecycle:

```text
Proposed
  ├──→ Accepted
  │      ↓
  │   Superseded
  └──→ Rejected
```

Material accepted decisions that change governing intent or success criteria must trigger explicit versioned amendment rather than silent implementation drift.

### Evidence architecture — from CompletionProof to Programme-B Evidence

Programme-B evidence must **generalize the trust properties already established by CandidateRef and CompletionProof**, not discard them. Preserve exact subject identity, provenance, freshness, authority binding, provider verification, integrity/signature semantics, and the rule that caller-built prose/structures are not equivalent to trusted proof.

The core relationship is:

```text
EvidenceReceipt
    = one atomic immutable observation / proof item

EvidenceBundle
    = candidate-bound collection of EvidenceReceipts

EvidenceProfile
    = policy declaring which evidence classes are required
```

Potential receipt classes include:

```text
TEST_RESULT
CI_RUN
STATIC_ANALYSIS
CODE_REVIEW
BROWSER_TRACE
SCREENSHOT
VIDEO
API_PROBE
BENCHMARK
LOG_CAPTURE
DATABASE_ASSERTION
SECURITY_SCAN
INTEGRATION_VALIDATION
MERGE_VERIFICATION
TRACKER_OBSERVATION
DEPLOYMENT_CHECK
HUMAN_ACCEPTANCE
```

A receipt should bind, where applicable:

```text
receipt identity
work item / execution identity
candidate identity / exact subject
producer type and identity
authority / policy identity
evidence class
observed_at
result
artifact references
freshness / expiry semantics
signature / provenance
```

Conceptual receipt lifecycle:

```text
Captured
  ├──→ Verified
  │      ├──→ Stale
  │      └──→ Superseded
  └──→ Rejected
```

Agent prose alone cannot transition evidence to `Verified`.

`EvidenceBundle` lifecycle may begin as:

```text
Pending
  ↓
Collecting
  ↓
Complete
  ↓
Evaluating
  ├──→ Valid
  ├──→ Invalid
  └──→ Inconclusive
```

Candidate movement invalidates candidate-bound conclusions unless a deterministic equivalence rule explicitly permits reuse.

`EvidenceProfile` should select required proof by change/risk class, including where relevant UI, API, backend logic, concurrency/recovery, database/migration, performance, security, and integration requirements. It also declares required independence, freshness, exact-candidate binding, and human gates.

Each receipt must preserve its producer class, for example:

```text
WORKER_PRODUCED
INDEPENDENTLY_PRODUCED
HOST_OR_PROVIDER_PRODUCED
HUMAN_PRODUCED
```

Worker-produced evidence is useful but cannot satisfy an independent-evidence requirement by itself.

### Structured ReviewFinding

Programme B/C should normalize independent reviewer findings rather than relying only on conversational prose.

Minimum shape:

```text
finding_id
candidate identity
review execution identity
category
severity
spec / ValidationContract / invariant references
evidence references
disposition
resolution candidate where applicable
```

Conceptual lifecycle:

```text
Raised
  ├──→ CorrectionRequired → Resolved
  ├──→ AcceptedRisk
  ├──→ Dismissed
  └──→ Superseded
```

Critical unresolved findings block `ValidationAssessment = Satisfied`.

### Repository readiness / autonomy gating

Before Symphony grants broad Programme-C autonomy to a repository, it should assess whether the repository can be operated and verified reliably.

Minimum capability gates may include:

```text
reproducible build
known test entrypoint
static checks
CI visibility
development/runtime startup
fixtures/test data
repository-law discoverability
migration procedure
observability
browser/API validation ability where relevant
sandbox compatibility
```

Conceptual lifecycle:

```text
Unknown
  ↓
Assessed
  ├──→ Ready
  ├──→ ReadyWithLimits
  └──→ NotReady

Ready / ReadyWithLimits
  ↓
Degraded
```

Readiness is a capability/gate assessment, not a vanity percentage. Missing mandatory capabilities may reduce autonomy regardless of aggregate score.

### Provider-neutral handoff contract

Programme B must establish a bounded handoff representation sufficient for a downstream authorized execution without replaying the entire prior conversation. At minimum, where applicable, it must be able to bind:

```text
work_item identity
execution identity
responsibility
authority identity / digest
base SHA
candidate identity
dependency snapshot / epoch reference
governing authority references
acceptance criteria
evidence references
validated facts
known limitations
open questions
context provenance
skill_selection_reference where applicable
selected skill ids / versions / digests where applicable
skill selection policy version where applicable
skill context provenance where applicable
```

Prior-agent narrative remains semantic input, not machine evidence. A handoff should normally reference governed skill identity rather than copying arbitrary prior skill-generated prose.

The handoff representation should initially remain the smallest immutable derived contract that satisfies these invariants. Do not create a new heavyweight persistent ContextSnapshot domain unless later lifecycle/recovery requirements demonstrate the need.

A handoff becomes stale when a binding it depends on changes. Examples include:

```text
base SHA movement
candidate movement
authority supersession
material dependency snapshot change
approved-plan supersession
responsibility/authority change
```

Do not silently mutate a stale handoff into a new truth. Recompute/reissue the bounded context under the new bindings.


### ReviewPacket as a derived clean-room projection

`ReviewPacket` should be a **derived view**, not a second authority store. It assembles the minimum authoritative material required for an independent review/verification execution:

```text
authoritative objective / approved specs
exact Candidate / diff / base identity
ValidationContract version
trusted EvidenceBundle / required receipts
applicable repository law / active invariants
known machine-observed limitations
open required decisions
```

Builder/Fixer narrative, confidence and debugging story are withheld from the initial clean-room packet. They may be requested later as clearly labelled semantic context.

A ReviewPacket becomes stale when any binding that affects its truth changes, including candidate identity, governing spec/contract version, authority digest, material dependency state, or required evidence status.

### Governed Skill Contract foundation

Programme B defines **what a governed Symphony skill is**. It does not yet own runtime skill selection.


The YAML shape below is an **illustrative architecture contract**, not the eventual canonical machine schema. The exact schema belongs in a future Programme-B SkillContract specification; the Skills Matrix remains the source/adoption inventory, not the runtime schema authority.

A future `SkillContract` should be an immutable/versioned execution-procedure contract, conceptually:

```yaml
skill:
  id: sym.debug.systematic
  version: 2.1.0
  digest: sha256:...
  provenance:
    source: symphony
    authority_class: governed_procedure

  purpose: >
    Systematically investigate a reproducible implementation defect.

  applicable_responsibilities:
    - planning
    - implementation
    - correction

  prohibited_responsibilities:
    - merge

  requires:
    capabilities:
      - repository_read
      - test_execution
    optional_capabilities:
      - workspace_write
    context_classes:
      - repository_law
      - task_objective
      - candidate_context

  forbids:
    capabilities:
      - merge
      - provider_transition
      - authority_rearm

  side_effect_class:
    repository_write: conditional
    external_write: false

  outputs:
    semantic:
      - hypotheses
      - root_cause_analysis

  evidence_expectations:
    - reproduction_receipt
    - discriminating_test_receipt

  failure_mode: fail_closed
```

The governing admission invariants are:

```text
skill.required_capabilities
⊆
execution.authorized_capabilities

skill.requested_context
⊆
execution.authorized_context

skill.applicable_responsibilities
contains
execution.responsibility
```

If any invariant fails:

```text
SKILL_NOT_ADMISSIBLE
→ reject skill
→ select compatible alternative
or
→ raise explicit escalation request
```

Never silently upgrade authority or capability to satisfy a skill.

### Skill definition / catalogue lifecycle

The skill content itself should remain immutable once approved; lifecycle is represented through governed catalogue status:

```text
Draft
  ↓
Evaluating
  ↓
Approved
  ↓
Active
  ↓
Deprecated
  ↓
Retired
```

Exceptional states:

```text
Rejected
Revoked
```

Transition expectations:

- `Draft → Evaluating`: schema valid, identity/version assigned, provenance known, capabilities/context declared;
- `Evaluating → Approved`: behavioural evaluation and safety review pass; no undeclared capability dependence remains;
- `Approved → Active`: explicit governance promotion;
- `Active → Deprecated`: successor exists or use is discouraged;
- `Active/Deprecated → Revoked`: unsafe behaviour or authority violation is established.

Terminal catalogue states:

```text
Retired
Rejected
Revoked
```

A revoked skill version must not be selected for new governed executions. Whether an already-running execution may finish must be explicit and risk/policy-specific.

Once approved, `(skill_id, version, digest)` identifies immutable content. Editing a skill creates a new version/digest rather than silently mutating an existing governed skill.

The governed `SkillCatalogue` should expose lightweight discovery metadata only, such as:

```text
id
version
digest
purpose
applicable responsibilities
required capabilities
context classes
side-effect class
evidence classes
tags/domains
status
provenance
```

The complete skill body is not automatically loaded with catalogue discovery.

### Skill provenance classes

Future provenance classification may include:

```text
SYMPHONY_GOVERNED
PROJECT_GOVERNED
PROJECT_ADVISORY
EXTERNAL_ADAPTED
RUNTIME_REQUESTED
DEVELOPER_ONLY
EXPERIMENTAL
```

Production autonomous selection may restrict admissible provenance classes by policy.

### Developer skills versus governed Symphony skills

Repository developer skills such as `.codex/skills/commit`, `.codex/skills/pull`, or `.codex/skills/debug` are developer/runtime convenience instructions unless separately normalized, evaluated, approved, and admitted as governed `SkillContract`s. The presence of a `.codex/skills` directory does not create the production `SkillCatalogue`.

### External skill-framework ingestion

External material from Superpowers, Matt Pocock-style skills, pstack/poteto, project-local libraries, or future sources should enter the governed system only through a promotion path such as:

```text
external procedure
      ↓
review
      ↓
normalize into SkillContract
      ↓
declare capabilities/context/side effects
      ↓
behavioural evaluation
      ↓
governance approval
      ↓
active Symphony skill
```

Never:

```text
git clone framework
→ all instructions become platform law
```

## Programme C — Supervised Execution, Context Broker & Governed Skill Selection

Programme C is also an **architectural programme, not one implementation issue or PR**. Its future planning pass must derive bounded issues around supervision, context projection/materialization, independent validator execution, deterministic skill selection, delegation, and runtime-requested procedures without creating another authority kernel.

Indicative non-binding capability families include:

```text
C-FAMILY-1 — ExecutionSupervisor / bounded worker ownership
C-FAMILY-2 — ContextPlan / Context Broker / resume-handoff-clean_room materialization
C-FAMILY-3 — Independent scrutiny and black-box validator executions
C-FAMILY-4 — Deterministic SkillSelectionPolicy / progressive disclosure
C-FAMILY-5 — Subagent delegation / runtime-requested skill admission / observability
```

Final Programme-C decomposition remains deferred until Programme-B foundations and Hardened V1 are accepted.

Potential future work includes:

- role-local worker supervision;
- bounded subagents;
- Context Broker;
- transport-neutral worker events;
- capability subset enforcement;
- context-subset enforcement;
- canonical `resume` / `handoff` / `clean_room` policy execution;
- role-specific context views;
- context invalidation and cross-execution leakage prevention;
- deterministic `SkillSelectionPolicy`;
- progressive skill disclosure and skill-context projection;
- skill-set identity per Execution;
- skill compatibility/admission validation;
- child/subagent skill-subset rules;
- clean-room skill isolation;
- runtime-requested skill admission;
- skill invalidation/reselection;
- independent scrutiny-validator executions;
- independent black-box/user-behaviour validator executions;
- ReviewPacket / VerificationView materialization;
- runtime-specific context materialization from an already-authorized ContextPlan.


### Independent validator executions

Programme C should supervise independent validation as first-class bounded executions rather than treating validation as Builder self-report.

At minimum, support two orthogonal validator modes:

```text
Scrutiny Validator
    source-aware
    exact candidate / diff / architecture / tests / invariants
    asks whether the implementation is technically correct

Black-box / User-Behaviour Validator
    behavior-first
    does not rely on Builder implementation rationale
    asks whether the product/system actually behaves as required
```

Depending on the `EvidenceProfile`, black-box validation may use CLI, API clients, browser/computer use, screenshots, video, service execution, runtime probes, failure/restart scenarios, or performance measurements. Visual evidence must not be required merely for theatre when it proves nothing material.

Validator executions receive an independently constructed ContextPlan/ReviewPacket and remain subordinate to the same authority/capability model.

### Integration validation

Parallel isolated workspaces prevent filesystem interference but do not prove semantic compatibility. Programme B/C should therefore support integration evidence against an exact target state where the EvidenceProfile requires it.

Conceptually:

```text
CandidateRef
+ integration target/base identity
+ synthetic merge/rebase tree identity
+ required tests/checks on that integrated tree
= IntegrationReceipt / integration evidence
```

Relevant target-base movement makes that evidence stale and requires revalidation.

### Context Broker contract

The Context Broker must not default to copying the whole conversation to every worker. It must project the least context needed for the authorized responsibility.


Before runtime/model selection, the Context Broker / planning layer may produce a lightweight `ContextPlan` describing **what context is authorized and required**, not the fully rendered payload. A ContextPlan may identify authorized context classes, selected governed skills, required references, clean-room exclusions, priority/size constraints and provenance requirements. It is not trusted evidence and grants no authority.

Final **context materialization** occurs after execution selection/runtime admission so the representation can be rendered for the selected runtime without changing the underlying authorized context envelope.

Expected views may include:

```text
PlannerView
BuilderView
FixerView
ReviewerView
VerificationView
ReviewPacket projection
```

The exact data model is deferred, but the invariants are not:

- `resume` may preserve provider-native context only inside the same compatible responsibility/authority/capability envelope;
- `handoff` starts a new execution/session and receives a bounded provider-neutral context package;
- `clean_room` starts a new independent execution with authoritative ground truth while withholding prior-agent reasoning from the initial context by default;
- reviewer context may not inherit Builder/Fixer conversational state merely because it is technically available;
- child context may not exceed parent-authorized context without a new authority decision;
- cross-work-item and cross-execution context leakage must fail closed;
- stale authority/candidate/dependency bindings invalidate dependent context;
- context propagation does not itself satisfy an evidence or lifecycle guard;
- selected skill bodies are materialized only after skill admission;
- reviewer skill/context sets are independently constructed and do not inherit Builder/Fixer skill narrative by default;
- a skill may request context, but may not obtain context outside the authorized context envelope;
- whole-skill-library injection is not an acceptable default.

### Governed SkillSelectionPolicy / future Skills Router

The future human-facing **Skills Router** goal is implemented as a subordinate `SkillSelectionPolicy` or `SkillResolver`, not as a second `AgentRuntime.Router`.

The long-term boundary is:

```text
                 WorkflowLifecycle
                        │
                        ▼
                AgentRuntime.Router
                        │
             authorized Responsibility
                        │
                        ▼
              Authority / Capability
                + Context Envelope
                        │
                        ▼
                SkillSelectionPolicy
                        │
            ┌───────────┴───────────┐
            │                       │
       Skill Catalogue        Task / Execution
       metadata only          requirements
            │                       │
            └───────────┬───────────┘
                        ▼
                Skill Admission
                        │
                        ▼
               Selected Skill Set
                        │
                        ▼
             ContextPlan + Execution
                   Requirements
                        │
                        ▼
           ExecutionSelectionPolicy
                        │
       runtime / provider / model / tier
                        │
                        ▼
          Runtime Admission / Isolation
                        │
                        ▼
                 Context Broker
              final materialization
                        │
                        ▼
                    Execution
                        │
                        ▼
             trusted evidence path
                        │
                        ▼
             Lifecycle reassessment
```

The `SkillSelectionPolicy` may decide which bounded procedures help an already-authorized responsibility. It must **not** decide:

```text
whether the WorkItem may execute
which lifecycle responsibility exists
whether authority is suspended
whether a retry budget resets
whether dependencies are satisfied
whether a provider transition is legal
whether a candidate is accepted
whether evidence is true
whether merge authority exists
whether human authority can be bypassed
```


### Skill selection versus validation requirements

Skills may help **perform** validation, but skill admission does not satisfy a `ValidationContract` or `EvidenceProfile` by itself.

```text
selected verification skill
≠
trusted verification evidence
≠
ValidationAssessment satisfied
```

For example, `sym.verify.browser` is a governed procedure; the resulting trusted browser/behavior receipts are evidence; the `ValidationContract` determines whether that evidence is required and sufficient.

### Skill-selection inputs and output

Potential inputs include:

```text
authorized responsibility
task type / objective
repository/domain metadata
required capability envelope
available capability envelope
context policy
EvidenceProfile
risk class
uncertainty
candidate state
previous failure class
known defect class
language/framework/domain
available approved skills
skill compatibility
clean-room requirement
```

Conceptual output:

```yaml
skill_selection:
  policy_version: ...
  execution_id: ...
  responsibility: review
  authority_digest: ...

  selected:
    - skill_id: sym.review.exact_diff
      version: 3.0.0
      digest: ...
      reason: exact_candidate_review_required

    - skill_id: sym.review.lifecycle
      version: 1.4.0
      digest: ...
      reason: lifecycle_domain_present

  rejected:
    - skill_id: sym.fix.auto
      reason: responsibility_incompatible
```

### Progressive skill disclosure

The future Context Broker / SkillSelection boundary should use progressive disclosure:

```text
LEVEL 0 — repository / Symphony law
LEVEL 1 — authorized responsibility + capability envelope
LEVEL 2 — compact admissible SkillCatalogue descriptors
LEVEL 3 — selected SkillContract metadata
LEVEL 4 — selected skill body when execution requires it
LEVEL 5 — skill-specific references/examples loaded on demand
LEVEL 6 — tools remain separately authorized; skill text cannot instantiate them
```

### Invocation classes

Future skill invocation should distinguish:

```text
Human-requested
    Requests a procedure; does not grant authority.

Policy-selected
    SkillSelectionPolicy selects skills for an already-authorized Execution.

Runtime-requested
    The executing model may request an additional skill, but the request returns
    through SkillSelectionPolicy/admission and cannot self-load unrestricted material.
```

A runtime-requested skill follows a bounded lifecycle:

```text
NotRequested
    ↓
Requested
    ↓
AdmissionChecking
   ├──→ Denied
   ├──→ EscalationRequired
   └──→ Approved
             ↓
          Materialized
             ↓
            Used
             ↓
          Completed
```

Terminal outcomes include `Denied`, `Completed`, and `Cancelled`. `Approved` means only that the skill is compatible with existing authority; it does not create additional authority.

### Skill-selection lifecycle and invalidation

For reproducibility, a selection should progress conceptually through:

```text
Unresolved
   ↓
Computed
   ↓
Validated
   ↓
BoundToExecution
   ↓
Active
   ↓
Superseded
```

A selection is stale/superseded when materially relevant bindings change, including:

```text
responsibility
authority digest
capability envelope
candidate identity
EvidenceProfile
context policy
approved skill version
risk classification
```

Do not silently mutate the skill set underneath an existing Execution.

### Clean-room skill selection

Independent review requires not only a clean conversation but a clean skill projection. For example:

```text
Builder
  TDD
  implementation
  systematic-debugging

Reviewer
  exact-diff-review
  contract-compliance
  concurrency-review
  evidence-verification
```

Reviewer does not begin with Builder debugging notes, Builder skill scratch state, Builder implementation rationale, or Builder self-assessment merely because those artifacts exist. Such material may later be requested explicitly as non-authoritative context after the independent pass.

### Subagent skill inheritance

When Programme C adds bounded subagents:

```text
child.authorized_capabilities
⊆
parent.authorized_capabilities

child.authorized_context
⊆
parent/delegated authorized context

child.skills
⊆
skills admissible under child responsibility/capability envelope
```

A parent may not grant a child a skill that the child cannot independently admit under the delegated authority envelope.

### Skill side-effect classes

Governed skills may be classified as:

```text
PURE_GUIDANCE
READ_ONLY_ANALYSIS
WORKSPACE_MUTATING
HOST_TOOL_USING
EXTERNAL_MUTATING
AUTHORITY_SENSITIVE
```

`AUTHORITY_SENSITIVE` means the procedure operates near an authority seam and requires stronger admission/verification; it does **not** mean the skill itself possesses authority.

### Skill / tool / evidence separation

Preserve:

```text
Skill
= procedure / knowledge / discipline

Semantic Tool
= trusted host-mediated capability

Runtime Tool
= capability available inside isolated execution

Evidence Producer
= trusted mechanism producing machine evidence
```

A skill may recommend an action such as verifying CI or requesting a provider transition, but the trusted SourceControl/WorkControl/evidence path remains responsible for authorization and proof.

### Skill conflict and composition rules

Skills do not compete for global authority. Conflict/composition should use governed metadata rather than contradictory prompt concatenation. Future relationships may include:

```text
requires
suggests
supersedes
conflicts_with
incompatible_with
must_precede
must_follow
```

Safety guidance:

1. reject mutually exclusive skills;
2. mandatory safety skill outranks optional convenience skill;
3. a narrower applicable skill may replace a broader generic one;
4. duplicate procedures collapse;
5. substantive unresolved conflict fails selection / escalates;
6. never solve a safety-policy conflict by concatenating contradictory prompts.

The skill dependency graph is not `WorkflowLifecycle` and must not evolve into a general workflow engine.

### Initial deterministic selection rule

Programme C should start with deterministic predicates/rules, not an AI selector. Example:

```text
responsibility = review
candidate exists
lifecycle domain changed
→ exact_diff_review
→ lifecycle_review
→ evidence_verification
```

or:

```text
responsibility = correction
failure_class = regression
→ systematic_debugging
→ regression_tdd
```

Do not begin by asking a model which skills it feels like using.

### Same-responsibility model escalation

Programme C may permit native same-session model switching when all relevant boundaries remain compatible:

```text
same responsibility
same authority envelope
same workspace/candidate scope
compatible capability contract
provider/runtime can prove safe continuation semantics
```

Example:

```text
Builder on a lower-cost model
→ discovers a local high-complexity implementation problem
→ escalates to a stronger model in the same Builder session
```

This must not be reused across a Planner → Builder or Builder/Fixer → Reviewer independence boundary.

### Execution escalation vocabulary

Future execution protocols should be able to surface explicit reasons such as:

```text
PLAN_DIVERGENCE
ARCHITECTURE_AMBIGUITY
UNEXPECTED_INVARIANT
EVIDENCE_CONTRADICTION
OUT_OF_SCOPE_REQUIRED
INSUFFICIENT_REASONING_CAPABILITY
```

A local implementation-complexity escalation may remain within the same responsibility. A finding that invalidates the approved plan must stop implementation and return control to an authorized planning path.

## Programme D1 — Runtime & Model Diversity

Programme D1 is distinct from distributed execution. It may be valuable on one Linux host under one Symphony authority kernel.

Potential future work includes:

- pluggable AgentRuntime adapters;
- multiple provider/model families;
- `ExecutionSelectionPolicy`;
- reasoning-tier selection;
- same-responsibility model escalation;
- cross-provider bounded handoff;
- optional epistemic/model-family diversity for selected high-risk reviews;
- model/runtime benchmark characterization;
- cost/quality telemetry and policy tuning;
- optional adaptive/model-assisted skill proposals after deterministic skill selection has been evaluated;
- runtime/model/skill co-characterization without collapsing authority boundaries.

### Selection boundary

Preserve:

```text
WorkflowLifecycle
        ↓
Router
        ↓
Responsibility
        ↓
Authority / Capability + Context Envelope
        ↓
SkillSelectionPolicy
        ↓
Skill Admission
        ↓
ContextPlan + Execution Requirements
        ↓
ExecutionSelectionPolicy
        ↓
runtime / provider / model / reasoning tier
        ↓
Runtime Admission / Isolation
        ↓
Context Broker final materialization
```

`ExecutionSelectionPolicy` may choose how an already-authorized responsibility executes. It may not create, change, or enlarge lifecycle responsibility or authority. `SkillSelectionPolicy` is likewise subordinate: skills describe procedural/runtime requirements but cannot grant them.

Example:

```text
Skill says:
"I require browser_control"

Authority says:
"browser_control is / is not permitted"

ExecutionSelectionPolicy says:
"which approved runtime can provide it?"
```

Never:

```text
Skill says browser
→ browser access automatically appears
```

Potential inputs include:

```text
responsibility
required capabilities
EvidenceProfile
risk class
task novelty
prior execution/review failures
available runtime capabilities
cost policy
diversity requirement
```

An execution may request a stronger tier when it discovers unexpected complexity. It may not lower a machine-mandated minimum tier on its own authority.

### Capability-driven runtime admission

Do not evolve the kernel into vendor-name policy branches. Future runtime adapters should advertise capabilities and be admitted against responsibility requirements.

Conceptually:

```text
planning
    repository_read
    read_only
    tool_calls

implementation
    repository_read
    workspace_write
    test_execution

review
    repository_read
    read_only
    source_control_evidence
```

Vendor/runtime identity may be relevant evidence about implementation provenance, but it is not the authority rule itself.


### Probabilistic proposal providers — authority boundary

Future fast/System-One systems such as Jev-like classifiers should be treated as **proposal providers**, not Symphony routing authority. Useful conceptual seams include:

```text
ExecutionSelectionProposalProvider
SkillSelectionProposalProvider
```

The authoritative pattern remains:

```text
deterministic policy / eligible set
    ↓
probabilistic proposal or ranking
    ↓
deterministic admission / policy revalidation
    ↓
authorized selection
```

The existing `WorkflowLifecycle` / Router continues to determine whether a responsibility exists. A proposal provider may optimize how an already-authorized responsibility is executed; it cannot create or enlarge that responsibility.

### Shadow-mode promotion for adaptive selectors

Adaptive selectors should progress through an explicit evaluation lifecycle before influencing production decisions:

```text
OfflineEvaluation
  ↓
Shadow
  ↓
AdvisoryCandidate
  ↓
EnabledForProposal
  ↓
Suspended / Retired
```

`EnabledForProposal` still does not mean authority. Deterministic admission remains mandatory. Promotion must use representative Symphony outcomes rather than vendor claims or self-reported quality.

### Adaptive/model-assisted skill proposal — later only

After deterministic skill selection and governed skill evaluation are mature, Programme D1 may evaluate a low-latency/System-One selector:

```text
Task metadata
    ↓
fast model
    ↓
proposed skill set
    ↓
deterministic admission
    ↓
authorized skill set
```

The model output is a **proposal**, not an authority decision.

Before adaptive selection is promoted, measure at least:

```text
correct skill recall
unnecessary skill rate
missing critical skill rate
authority-violation proposal rate
context/token overhead
execution success
review rejection
correction loops
final independent acceptance
total cost per accepted candidate
```

### Model/runtime characterization gate

Do not optimize routing from vendor claims or raw token price alone. Before automatic cost/quality routing becomes authoritative policy, evaluate candidate models/runtimes against frozen representative Symphony tasks and known defects.

Measure at minimum:

```text
correct issue discovery
false-positive findings
plan correctness
first-pass implementation success
review rejection rate
correction-loop count
input/output/cached tokens
tool activity
elapsed time
total monetary cost
final independent acceptance result
```

The primary economic metric should approximate:

```text
total cost per independently accepted candidate
```

not merely cost per token or cost per model call.


Once Programme F provides outcome-confirmed production data, a stronger downstream metric may be evaluated:

```text
total cost per independently accepted and outcome-confirmed change
```

This must not replace the nearer-term independently accepted-candidate metric before production outcome attribution is trustworthy.

Expensive semantic review should occur only after candidate identity, required CI/tests, static checks, authority bindings, and dependency state are mechanically eligible.

A successful Programme-D1 evaluation may conclude:

```text
SINGLE-RUNTIME POLICY REMAINS BEST
```

That is a valid outcome.

### Skill behavioural evaluation and promotion gate

Skill and selector quality must be judged from observable execution, not self-report. Bind evaluations to:

```text
skill id
skill version
skill digest
selection policy version
runtime/model
benchmark case identity
repository/candidate identity
result/evidence
```

Evaluate at minimum:

```text
Was the skill selected when required?
Was it omitted when irrelevant?
What context did it receive?
What files did the execution read?
What files changed?
Which tools were requested?
Which tools were actually authorized?
Were side-effect limits respected?
Was expected evidence produced?
Did it improve independent acceptance?
Did it cause over-processing?
Did it leak context?
Did it conflict with another skill?
```

Future structured telemetry may include:

```text
skill.selection.computed
skill.selection.rejected
skill.selection.bound
skill.materialized
skill.requested_by_runtime
skill.request.denied
skill.started
skill.completed
skill.failed
skill.superseded
```

Useful metrics include skill-selection precision/recall, irrelevant-skill rate, critical-skill omission rate, average skills per execution, skill-context tokens, materialization latency, conflict rate, runtime-requested/denied rates, correction loops, review findings, final independent acceptance, and total cost per independently accepted candidate. Do not optimize for the number of skills invoked.

A future governed learning loop may use independently accepted outcomes to propose new skill/selector versions, but historical agent output must never automatically become repository law or a promoted skill:

```text
Execution
   ↓
trusted EvidenceBundle
   ↓
independent outcome
   ↓
behavioural analysis
   ↓
proposed SkillContract / selector change
   ↓
offline evaluation
   ↓
independent/governance approval
   ↓
new version
```

## Programme D2 — Remote / Distributed Execution Expansion

Conditional only after measured operational need exists.

Potential future work includes:

- remote execution expansion;
- Redis/Streams coordination;
- multi-node authority;
- leader election;
- distributed fencing/leases;
- split-brain protection;
- cross-node generation/ownership semantics.

Runtime/model diversity does not justify distributed authority by itself. A single-node Symphony may support multiple local runtimes/providers while preserving one authority kernel.

A successful Programme-D2 evaluation may conclude:

```text
NO DISTRIBUTED EXPANSION REQUIRED
```

That is a valid outcome.


## Programme E — Governed Learning, Engineering Experience & Repository Law

Programme E begins only after first-class Candidate/Evidence identity, independent acceptance data, structured findings and trustworthy telemetry exist. It is **not** a V1 feature and does not require Programme D1 optimisation or Programme D2 distribution. Programme E may begin from independently accepted engineering outcomes before Programme F is mature, but any learning claim that depends on deployed/product outcomes requires trustworthy Programme-F observation/outcome evidence.

Core rule:

```text
agent reflection
≠
institutional knowledge
```

### EngineeringExperience

Validated institutional lessons should be represented as governed experience rather than raw agent narrative.

Minimum provenance should include:

```text
experience identity
scope / applicability
source executions
candidate identities
evidence references
confirmations
contradictions
confidence
supersession history
```

Conceptual lifecycle:

```text
Observed
  ↓
Evaluated
  ↓
Distilled
  ↓
Validated
  ↓
Promoted
  ↓
Superseded / Retired

Quarantined
Rejected
```

Promotion requires independently trustworthy outcomes. Raw model self-reflection may be an input hypothesis but is insufficient for promotion.

### Generalized LearningProposal

A validated pattern may propose a governed change to:

```text
SkillContract
SkillSelectionPolicy
ExecutionSelectionPolicy
Context rule
EvidenceProfile
regression test
benchmark case
repository invariant
repository documentation / ADR
```

No proposal may self-promote. Every target keeps its own authority/lifecycle.

### Invariant Registry / repository law promotion

Invariant Registry != repository-law authority. It is subordinate to V4.1/repository law, accepted governance, and repository tests, types, static checks, and policy gates.

A proposed or evidenced registry entry may not create law by itself, waive existing repository law, grant lifecycle authority, or become trusted evidence merely by being registered. Promotion into repository law requires the normal accepted repository/governance mechanism.

Repeated reliable reviewer or production knowledge should move toward deterministic enforcement where practical.

Conceptual invariant lifecycle:

```text
Proposed
  ↓
Evidenced
  ↓
Approved
  ↓
Active
  ↓
Superseded / Retired

Rejected
```

An active invariant may materialize as a test, type rule, static check, policy gate, schema rule, compiler rule, or runtime assertion. A RAG system is never the authority store for active invariants.

### Holdout and adversarial evaluation

Proposed changes to skills, selectors, routing, validation policy or invariants should be evaluated against held-out evidence such as:

```text
historical incidents
known difficult tasks
adversarial cases
private/held-out benchmark cases
```

This reduces self-overfitting of the software factory to the examples used to propose the change.

### Optional RAG / LightRAG projection

A graph/RAG system such as LightRAG may later act as a **rebuildable retrieval projection** over promoted/validated engineering knowledge. It is not required technology and may be replaced.

Preferred source material includes:

```text
approved specs / decisions
active invariants
validated EngineeringExperience
resolved ReviewFindings
verified postmortems
accepted EvidenceBundle projections
```

Raw transcripts remain lower-trust semantic material.

Never:

```text
RAG result
→ repository law / authority / trusted evidence
```

## Programme F — Production Observation, Signals & Closed-Loop Outcomes

Programme F extends the factory beyond merge. It begins only when accepted candidate/artifact identity can be correlated reliably with deployments and operational observations. It does not require Programme D1. Once trustworthy Programme-F outcomes exist, they may feed Programme-E learning through the governed evidence/promotion path rather than through automatic reflection.

### DeploymentObservation

Production/deployment facts must bind to the exact accepted artifact/candidate where applicable.

Conceptual lifecycle:

```text
Pending
  ↓
Deployed
  ↓
Observing
  ├──→ Healthy
  ├──→ Degraded
  ├──→ Failed
  └──→ RolledBack
```

### OutcomeAssessment

A merged/deployed change is not automatically a successful product outcome.

Conceptual lifecycle:

```text
Pending
  ↓
Assessing
  ├──→ Confirmed
  ├──→ Partial
  ├──→ Failed
  └──→ Unknown
```

`Unknown` is valid. Absence of alerts is not automatically proof of success unless an explicit observation policy defines that as sufficient.

### WorkSignal / external intake

Future signals may include:

```text
production incident
monitoring alert
security finding
user/customer feedback
support issue
dependency advisory
performance regression
human engineering idea
```

Signal lifecycle:

```text
Detected
  ↓
Normalized
  ↓
Assessed
  ├──→ WorkProposed
  ├──→ Dismissed
  └──→ Deduplicated
```

A signal may propose work. It may not silently authorize code mutation or bypass WorkControl.

### Closed-loop factory model

```text
Signal
  ↓
authorized WorkItem
  ↓
planning depth + governed specs / ValidationContract
  ↓
Execution
  ↓
exact Candidate
  ↓
trusted EvidenceBundle
  ↓
independent ValidationAssessment
  ↓
integration / merge / deploy
  ↓
Production Observation
  ↓
OutcomeAssessment
  ↓
validated EngineeringExperience
  ↓
governed improvement proposal
```

Never:

```text
agent acts
→ agent reflects
→ system automatically learns
```

### Programme acceptance summaries

**Programme B acceptance requires, at minimum:** versioned intent/spec identity; sealed `ValidationContract`; first-class Execution/Candidate; trustworthy EvidenceReceipt/Bundle/Profile semantics; integration evidence support; structured ReviewFinding; bounded handoff; governed SkillContract identity.

**Programme C acceptance requires, at minimum:** bounded supervisors; least-context Context Broker; clean-room scrutiny and black-box validator executions; deterministic SkillSelectionPolicy; trusted validator receipts; subagent capability/context subset enforcement.

**Programme E acceptance requires, at minimum:** only verified outcomes can enter promotion; invariant lifecycle/governance; holdout evaluation; optional RAG projections remain rebuildable and non-authoritative.

**Programme F acceptance requires, at minimum:** deployments bind exact candidates/artifacts; production observations are trustworthy; OutcomeAssessment exists; signals re-enter governed intake; merge and product outcome remain distinct.

## Cross-Programme Skills Architecture Sequencing

The Skills architecture is intentionally staged:

```text
HARDENED V1 ACCEPTED
        ↓
Programme B
First-class Execution / Candidate / Evidence / Handoff
        ↓
B-SKILL-01
SkillContract + immutable identity/version/digest
        ↓
B-SKILL-02
Governed SkillCatalogue + provenance/evaluation state
        ↓
Programme C
ExecutionSupervisor + Context Broker
        ↓
C-SKILL-01
Deterministic SkillSelectionPolicy
        ↓
C-SKILL-02
Progressive skill disclosure/materialization
        ↓
C-SKILL-03
Runtime-requested skill admission
        ↓
C-SKILL-04
Clean-room/subagent skill-context rules
        ↓
Behavioural evaluation proves baseline
        ↓
Programme D1
Optional adaptive/model-assisted skill proposal
        ↓
Measured promotion only
```

Future Skills Router acceptance requires, at minimum:

1. authority non-expansion;
2. progressive disclosure;
3. exact skill version/digest identity;
4. capability-subset enforcement;
5. context-subset enforcement;
6. clean-room reviewer skill/context construction;
7. skill-output versus machine-evidence separation;
8. semantic-tool authorization separation;
9. deterministic initial selection;
10. conflict-safe skill composition;
11. governed runtime-requested skill admission;
12. revocation support;
13. staleness/invalidation on authority/responsibility/candidate change;
14. behavioural evaluation before promotion;
15. external-framework isolation;
16. one Symphony authority kernel;
17. runtime portability through capability requirements rather than vendor policy where practical;
18. reproducibility of the exact skill set that informed an execution;
19. no skill-soup/default whole-library injection;
20. independent engineering outcome as the primary quality measure.

---

## Canonical Skills Adoption Authority

The exact inventory of proposed/adopted engineering doctrine, governed skill candidates, supervisor patterns, context patterns, evaluation methods, source provenance, normalization decisions, and explicit rejections is maintained in the canonical companion:

```text
SYMPHONY_SKILLS_ADOPTION_AND_ROUTING_MATRIX_v1.0.2.md
Document ID: SYM-SKILLS-MATRIX-001
```

This roadmap and the Skills Matrix have different authority scopes:

```text
Unified Execution Roadmap
    = WHEN / programme sequencing / lifecycle and authority boundaries / release gates

Skills Adoption & Routing Matrix
    = WHAT / WHY / SOURCE / CLASSIFICATION / ADOPTION STATUS / TARGET PHASE

future SkillContract
    = exact machine-readable contract for one approved governed skill

future SkillSelectionPolicy
    = selects admissible governed skills inside an already-authorized Execution
```

Governance precedence is:

```text
V4.1 Master Roadmap
        ↓
Unified Execution Roadmap
        ↓
canonical companion matrices / programme specifications (scope-specific peers)
        ↓
machine contracts, including SkillContract
        ↓
runtime policy decisions
```

This precedence applies only where the documents overlap in authority. In particular:

- the Skills Matrix may classify, adopt, adapt, defer, reject, normalize, or version skill-related ideas;
- the Skills Matrix may not change WorkControl lifecycle, responsibility authority, capability boundaries, Programme B/C/D/E/F sequencing where applicable, V1 scope, release gates, or the single-authority-kernel rule;
- if the Skills Matrix conflicts with this roadmap on programme sequencing or authority, this roadmap governs until an explicit roadmap amendment is accepted;
- a future SkillContract cannot grant authority beyond the Execution envelope in which it is admitted;
- a runtime `SkillSelectionPolicy` decision is lower-order execution policy, not repository law.

The two documents version independently. The canonical Skills Matrix v1.0.2 points to this roadmap and records that governance linkage is established. Its independent patch preserves the ContextPlan → execution selection → runtime admission → final materialization ordering and does not reopen locked adoption/rejection decisions.

A Skills Matrix update does **not** require a roadmap version bump when it only:

- adds or evaluates a candidate skill;
- records new external provenance;
- normalizes duplicate external procedures;
- changes a skill's evaluation/adoption status within already-authorized Programme B/C/D/E/F boundaries where applicable;
- adds a newly discovered upstream skill as `DISCOVERED — NOT LOCKED`;
- deprecates, revokes, or supersedes a skill without changing programme sequencing or authority.

A corresponding roadmap amendment **is required** when a proposed skill/matrix change would alter:

- V1 scope;
- Programme B/C/D/E/F order or prerequisites;
- WorkControl / `WorkflowLifecycle` authority;
- responsibility routing;
- capability or context authority boundaries;
- clean-room independence requirements;
- evidence/trust semantics;
- merge/release authority;
- the future Skills Router / `SkillSelectionPolicy` architecture;
- release/freeze/live-proof/acceptance gates.

The Skills Matrix is therefore the canonical **skills inventory and adoption record**, while this roadmap remains the canonical **execution-sequencing and authority record**.

---


## Architecture Specification Graduation

While future architecture is still being formed, this Unified Execution Roadmap may contain enough detailed future-domain design to preserve intent, dependencies, authority boundaries, and acceptance semantics. It should not remain the permanent home for every mature domain contract.

Once a future programme/domain becomes stable enough for implementation, detailed contracts should graduate into dedicated canonical programme specifications. The roadmap should then retain only:

```text
programme objective
activation/dependency gates
authority boundaries
programme-level acceptance boundary
links to the canonical detailed specification
```

Illustrative future structure (names are non-binding):

```text
docs/software-factory/
  ENGINEERING_INTENT_AND_VALIDATION.md
  EXECUTION_CANDIDATE_EVIDENCE.md
  CONTEXT_AND_HANDOFF.md
  SKILLS_GOVERNANCE.md
  LEARNING_AND_INVARIANTS.md
  PRODUCTION_OUTCOMES.md
```

Graduated specifications remain subordinate to the V4.1 Master Roadmap and this Unified Execution Roadmap for programme sequencing/authority. A detailed specification cannot change programme activation, V1 scope, release gates, or higher-order authority without an explicit roadmap/authority amendment.

## Cross-Document Consistency Invariants

The following are maintenance invariants for this roadmap and canonical companions:

```text
DOC-01
A companion document's declared parent roadmap version must match the canonical roadmap version it claims to target.

DOC-02
V4.1 Master Roadmap
> Unified Execution Roadmap
> canonical companion matrices / programme specifications (scope-specific peers)
> machine contracts, including SkillContract
> runtime policy decisions

DOC-03
Canonical execution/context ordering is:
authority/responsibility
→ authorized capability + context envelope
→ skill selection
→ skill admission
→ ContextPlan
→ execution requirements
→ ExecutionSelection
→ Runtime Admission / Isolation
→ final context materialization
→ Execution
→ trusted evidence
→ lifecycle reassessment

DOC-04
Skill ≠ Authority.

DOC-05
RuntimeAttempt ≠ future durable Execution; Programme-B Execution must generalize/supersede rather than compete.

DOC-06
CandidateRef ≠ a second future candidate truth; Programme-B Candidate must generalize/preserve current exact-candidate authority semantics.

DOC-07
Programme D1 is not a prerequisite for Programme E or Programme F unless a future explicit dependency is proven.

DOC-08
Programme D2 remains conditional on demonstrated distribution need.

DOC-09
Describing Programme B/C/D/E/F does not authorize implementation during V1.
```

A maintenance pass that finds a violation must correct the documentation or STOP for an explicit governance amendment; it must not silently choose a conflicting interpretation.

## Historical v1.3.1 Architecture Amendment Record

This patch classifies its changes as follows:

```text
CLARIFICATION
- explicit V4.1 Master Roadmap → Unified Execution Roadmap authority hierarchy
- CandidateRef versus future Candidate relationship
- ContextPlan versus final runtime-specific context materialization consistency
- Programme B/C are programmes that require future bounded issue decomposition
- architecture-specification graduation rule

CORRECTION
- Programme E / Programme F / optional Programme D1 sequencing ambiguity
- skills-governance precedence now includes the V4.1 Master Roadmap
- cross-document consistency invariants make parent/version and ordering drift explicit

NO CHANGE TO V1 AUTHORITY
- current H-080B / PRE-080C / H-080C / V1-OPS / H-090 / H-120A / H-100 / H-110 / H-120B sequence
- one Symphony authority kernel
- agent-agnostic core
- Linux-only V1 routed execution
- human/external exact-candidate merge authority
- clean-room independent review
- H-I19 through H-I24
- Programme B/C/D/E/F remain unauthorized during V1
- Programme D1 and D2 remain conditional
```

No future programme described by this amendment is authorized for implementation merely by appearing here.

## v1.3.2 Amendment Record

```text
VERSION
v1.3.2

GOVERNANCE BASELINE
- records the 2026-10-07 PR #32 reconciliation and acceptance through H-080B
- sets current allowed scope to roadmap and companion canonicalization
- keeps H-080C unauthorized

CANONICAL REFERENCES AND REPOSITORY LAW
- updates the active Skills Matrix reference to v1.0.2
- makes the Invariant Registry subordinate to repository law and accepted governance
```

# 25. Maintenance Rule for This Document

This document is a **canonical working roadmap**, not immutable historical evidence.

Update it only when:

- a phase is formally accepted;
- a new governance decision changes sequencing;
- a characterization issue discovers a real prerequisite;
- V4.1 authority is formally amended;
- a finding is proven obsolete/superseded;
- a Skills Matrix change requires different programme sequencing, authority boundaries, V1 scope, or release gates.

Do **not** update this roadmap merely because the Skills Matrix adds, evaluates, renames, normalizes, deprecates, or rejects a skill inside already-approved architectural boundaries. Those changes belong to the independently versioned Skills Matrix.

Every update should preserve:

- the explicit V4.1 Master Roadmap → Unified Execution Roadmap → subordinate specification/matrix → machine contract → runtime policy hierarchy;
- prior accepted decisions;
- exact distinction between merged and accepted;
- historical provenance;
- explicit unknowns;
- agent-agnostic / Linux-targeted runtime doctrine;
- V1 vs Programme B/C/D/E/F boundaries;
- least-context and clean-room review doctrine;
- separation between workflow responsibility routing, skill selection, execution/model selection, and distributed execution;
- skill-text/non-authority doctrine;
- progressive skill disclosure;
- capability/context subset enforcement;
- clean-room skill projection;
- deterministic-before-adaptive skill selection;
- skill/output versus trusted-evidence separation;
- roadmap-over-matrix precedence for sequencing and authority;
- independent versioning between the roadmap and Skills Matrix;
- exact source/adoption inventory ownership by `SYM-SKILLS-MATRIX-001`;
- success-criteria-before-judgment / ValidationContract doctrine;
- exact EvidenceReceipt → EvidenceBundle → EvidenceProfile separation;
- independent scrutiny and black-box validation semantics;
- machine-consumable governance status;
- learning/RAG non-authority and governed invariant promotion;
- merge/deploy/outcome separation.

Do not silently rewrite past decisions to make the roadmap appear cleaner.

---

# 26. Source Inputs / Provenance

This unified roadmap was derived from:

1. **Symphony V4.1 hardening authority and the accepted H-010 through H-080B history, including the 2026-10-07 reconciliation of H-080B acceptance.**
2. **Pre-H-080B repository audit** against commit `56798754c8f6fd80d7ec53b604800873e339e030`, which identified runtime containment, evidence acquisition, production-rate epoch behavior, governance drift, operational recovery, observability/readiness, structural review, live proof, soak, and final acceptance gaps.
3. **Symphony Autonomous Engineering Control Plane — Unified Architecture & Operating Model**, a working architecture baseline defining Symphony as the authority/control plane, repository law, role/capability separation, semantic tools, exact-candidate evidence, one-authority orchestration, V1 hardening sequence, replaceable runtimes, and deferred distributed infrastructure.
4. **Repo-grounded skill-orchestration reconciliation**, including the current-baseline implementation matrix and the earlier skill-orchestration doctrine, with the explicit correction that generic policy/playbook/workflow machinery does not supersede or duplicate the V4.1 WorkControl/Orchestrator authority kernel.
5. **`SYMPHONY_SKILLS_ADOPTION_AND_ROUTING_MATRIX_v1.0.2.md` (`SYM-SKILLS-MATRIX-001`)**, the canonical companion inventory for exact source-by-source skill/doctrine/pattern adoption, normalization, provenance, target phase, and explicit rejection decisions. Its inventory authority is subordinate to this roadmap's sequencing and authority boundaries.
6. **`SYMPHONY_SOFTWARE_FACTORY_ARCHITECTURE_REQUIREMENTS_v1.0.0.md`**, used as a design input for post-V1 software-factory requirements and reconciled into this roadmap rather than established as a competing sequencing authority.
7. **Historical 2026-10-05 current-repository recon**, including the then-current protected-main/PR #31 merge-versus-acceptance divergence, stale governance state, CandidateRef/CompletionProof maturity, SourceControl/provider-evidence boundaries, runtime isolation, RuntimeAttempt semantics, and workspace ownership. The acceptance divergence was resolved by the 2026-10-07 PR #32 reconciliation.
8. **Subsequent locked governance decisions**, including:
   - Symphony core must remain agent-agnostic;
   - Codex is an adapter/runtime implementation, not the authority owner;
   - V1 autonomous routed execution is Linux-only;
   - macOS/iOS certification is not required;
   - unsupported/unproven routed platforms fail closed;
   - remote routed execution remains fail-closed until containment is mechanically proven;
   - V4.1 remains the governing roadmap;
   - audit findings are reconciled into V4.1 rather than becoming a competing programme.
9. **2026-10-07 PR #32 governance reconciliation**, merged at `023b2269c93763a07fce0aeda541ec1adb7e0273`, tree `8be1aec5627f2b0672e44e6c53460383c3fe3110`, recording H-070B, REM-HI21, H-I20 remediation, H-080A, and H-080B as accepted.

---

# 27. Future Skills Router Goal

The locked future goal is:

> **Symphony's future Skills Router is a subordinate, governed `SkillSelectionPolicy` that selects the smallest sufficient set of versioned, evaluated, capability-declared procedures for an already-authorized Execution. It must preserve V4.1 lifecycle authority, capability boundaries, evidence provenance, least-context semantics, clean-room independence, and exact execution identity. It may propose or select how an authorized responsibility should perform its work; it may never decide whether that responsibility exists, enlarge its authority, create trusted evidence from prose, or become a second workflow/orchestration authority.**

The exact source-by-source adoption inventory feeding that future governed catalogue is maintained in `SYM-SKILLS-MATRIX-001`. This roadmap intentionally does not duplicate the full Superpowers / Matt Pocock / pstack-poteto matrix; it governs the architecture and sequencing under which those normalized skills may later become active.

The compact invariant is:

```text
AUTHORITY
    ↓
RESPONSIBILITY
    ↓
AUTHORIZED CAPABILITY + CONTEXT ENVELOPE
    ↓
SKILL SELECTION
    ↓
SKILL ADMISSION
    ↓
CONTEXT PLAN + EXECUTION REQUIREMENTS
    ↓
EXECUTION SELECTION
    ↓
RUNTIME ADMISSION / ISOLATION
    ↓
CONTEXT MATERIALIZATION
    ↓
EXECUTION
    ↓
TRUSTED EVIDENCE
    ↓
LIFECYCLE
```

Never:

```text
SKILL
  ↓
AUTHORITY
```

# 28. One-Sentence Development Doctrine

> **Harden and independently prove one Symphony authority kernel first; then evolve that kernel into a governed software factory in which authorized intent is converted into bounded execution, exact candidates, candidate-bound trusted evidence, independent technical and behavioural validation, controlled integration and observable outcomes, with skills, context, runtime/model selection, learning and production feedback remaining subordinate to explicit authority, deterministic policy and independently verifiable evidence.**
