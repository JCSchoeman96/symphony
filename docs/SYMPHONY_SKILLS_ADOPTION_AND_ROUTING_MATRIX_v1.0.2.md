# Symphony Skills Adoption & Routing Matrix

**Document ID:** `SYM-SKILLS-MATRIX-001`\
**Version:** `1.0.2`\
**Status:** **CANONICAL COMPANION — GOVERNANCE LINK ESTABLISHED**\
**Date:** 2026-10-07\
**Parent execution architecture:** `SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`\
**Repo-grounding input:** `SYMPHONY_CURRENT_BASELINE_IMPLEMENTATION_MATRIX_v1.0.0.md`\
**Historical design input:** `SYMPHONY_SKILL_ORCHESTRATION_AND_ENGINEERING_DOCTRINE_v1.0.0.md`\
**Repository:** `JCSchoeman96/symphony`\
**Scope:** Exact adoption inventory, classification, provenance, normalization, phase placement, authority restrictions, evaluation requirements, and rejection ledger for Symphony skills and skill-inspired engineering mechanisms.

---

# 1. Purpose

This document answers:

> **What exactly does Symphony intend to take, adapt, normalize, defer, or reject from Superpowers, Matt Pocock's skills, pstack/poteto, Symphony-native architecture, project-local skills, and future external skill sources?**

It deliberately does **not** answer the V4.1 sequencing question by itself.

The canonical authority hierarchy is:

```text
V4.1 Master Roadmap
    = normative V4.1 authority, hardening intent, and locked invariants
        ↓
Unified Execution Roadmap
    = current execution sequence, prerequisites, and release gates
        ↓
Canonical companion matrices / programme specifications
    = scope-specific peers beneath the Unified Execution Roadmap
        ↓
Machine contracts, including SkillContract
    = exact requirements and contracts within an authorized scope
        ↓
Runtime policy decisions
    = subordinate decisions for one authorized execution
```

Companion matrices and programme specifications are scope-specific peers. Neither may silently supersede the other outside its assigned scope. SkillContract is below this specification/matrix tier.

Governance linkage is established through
`SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`.

This Matrix is canonical only within its assigned adoption/inventory scope. It may not change V4.1 lifecycle authority, programme sequencing, release gates, or the single Symphony authority-kernel rule.

---

# 2. Non-negotiable architectural relationship

The Skills architecture remains subordinate to the V4.1 authority kernel.

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
CONTEXT PLAN
    ↓
EXECUTION REQUIREMENTS
    ↓
EXECUTION SELECTION
    ↓
RUNTIME ADMISSION / ISOLATION
    ↓
FINAL CONTEXT MATERIALIZATION
    ↓
EXECUTION
    ↓
TRUSTED EVIDENCE
    ↓
LIFECYCLE
```

Canonical distinction:

```text
ContextPlan
    = which context classes, references, governed skills, exclusions,
      provenance requirements and size/priority constraints are authorized/required.

Final context materialization
    = runtime-specific rendering of that already-authorized context after
      ExecutionSelection and Runtime Admission.
```

Final materialization may adapt representation for the selected runtime. It may **not** increase the authorized context envelope, add an unadmitted skill, or grant new authority/capability.

Never:

```text
SKILL
  ↓
AUTHORITY
```

A skill may describe a procedure, declare requirements, request context, or propose a tool need. SkillContract requirements are predicates for admission and do not grant capabilities.

It may **not**:

- grant capabilities, credentials, provider access, or SCM access;
- advance lifecycle, approve a candidate, resolve suspension, or merge;
- create or enlarge `WorkflowLifecycle` responsibility;
- change `AuthorityDisposition`;
- rearm retry/authority lineage;
- widen filesystem/network/credential access;
- register a trusted semantic tool;
- create source-control merge authority;
- create provider-transition authority;
- create or mint trusted evidence from prose;
- waive clean-room review;
- redefine WorkControl lifecycle;
- become a second scheduler or orchestration authority.

---

# 3. Source snapshot and provenance rule

The adoption decisions in this document come primarily from the previously locked Symphony design discussions and the repo-grounded reconciliation.

A lightweight current-upstream check was also performed on 2026-10-05 so that exact external names are not accidentally stale.

External source families:

```text
obra/superpowers
mattpocock/skills
backnotprop/pstack
```

Important distinction:

> **Current upstream existence does not equal Symphony adoption.**

Where an upstream project now contains a skill that was not part of the earlier locked Symphony decisions, this document marks it:

```text
DISCOVERED — NOT LOCKED
```

rather than silently adopting it.

---

# 4. Classification taxonomy

Every imported idea belongs to one primary Symphony classification.

## 4.1 `DOCTRINE`

A durable engineering principle or decision rule.

Examples:

- evidence over claims;
- attack the premise;
- smallest sufficient change;
- foundational thinking;
- subtract before adding.

Doctrine is not an executable skill and does not grant authority.

## 4.2 `SKILL`

A bounded reusable procedure.

Examples:

- systematic debugging;
- requirement grilling;
- `how` investigation;
- exact-diff review;
- TDD.

A future governed skill becomes a versioned `SkillContract`.

## 4.3 `SUPERVISOR_PATTERN`

A method for coordinating more than one execution/worker.

Examples:

- subagent-driven development;
- parallel/swarm investigation;
- architecture arena.

These belong primarily to Programme C and remain subordinate to the single Symphony authority kernel.

## 4.4 `CONTEXT_PATTERN`

A rule for what information an execution receives.

Examples:

- progressive disclosure;
- bounded handoff;
- clean-room review.

These are primarily Context Broker concerns.

## 4.5 `EVALUATION_METHOD`

A way to test skills, selectors, prompts, or agent behaviour.

Examples:

- blind behavioural evaluation;
- skill pressure tests;
- artifact/transcript inspection.

## 4.6 `DEVELOPER_TOOLING`

A useful repository-development procedure that is not automatically a production-governed skill.

Examples:

- current `.codex/skills/*`;
- setup helpers;
- local source-control convenience procedures.

## 4.7 `PROJECT_LOCAL`

A language/framework/domain-specific procedure that belongs to a repository rather than the global Symphony platform.

## 4.8 `REJECTED`

An external pattern that conflicts with V4.1 or would create competing authority.

---

# 5. Adoption decision taxonomy

| Decision | Meaning |
| --- | --- |
| LOCKED ADOPTION | Architecture/adoption decision has already been agreed and is carried forward by this matrix. |
| ADOPT | Preserve core procedure/idea in Symphony-normalized form. |
| ADAPT | Preserve useful mechanism but change boundaries/semantics to fit V4.1. |
| NORMALIZE | Multiple sources map to one Symphony-native skill/pattern. |
| DEVELOPER TOOLING ONLY | May be used for repo work but is not a production governed SkillContract. |
| PROJECT-LOCAL | May become a project-governed skill, not a platform-global skill. |
| DISCOVERED — NOT LOCKED | Exists upstream/currently but has not been adopted by prior Symphony decisions. |
| OPTIONAL / NOT CORE | Can exist as user convenience without becoming a required Symphony capability. |
| DEFER | Useful idea intentionally sequenced to a later programme. |
| REJECT | Explicitly incompatible with Symphony authority or architecture. |

---

# 6. Programme placement

```text
V1
    current: prove that skill/instruction prose cannot enlarge authority
    no production SkillSelectionPolicy

Programme B — FUTURE
    SkillContract, SkillCatalogue, identity/version/digest, provenance, evaluation, handoff

Programme C — FUTURE
    deterministic SkillSelectionPolicy, Context Broker materialization, runtime admission, clean-room/subagent rules

Programme D1 — FUTURE, OPTIONAL
    adaptive/model-assisted proposals after deterministic admission and behavioural evaluation
    not a prerequisite for Programme E or F

Programme D2 — FUTURE, SEPARATE OPTIONAL EXPANSION
    distributed authority only if measured operational need justifies it

Programme E — FUTURE
    governed learning and invariant promotion

Programme F — FUTURE
    production observation and outcome assessment
    does not depend on Programme D1
```

---

# 7. Locked doctrine matrix

| Doctrine | Primary provenance | Status | Symphony interpretation |
| --- | --- | --- | --- |
| Evidence over claims | Symphony-native + Superpowers/pstack reinforcement | LOCKED | Agent prose never substitutes for trusted machine evidence. |
| Smallest sufficient process | Symphony-native | LOCKED | Rigor proportional; no ceremony for trivial changes. |
| Smallest sufficient change / Laziness Protocol | Symphony + pstack | LOCKED | Prefer deletion/simplification/reuse/local change before additive abstraction. |
| Attack the premise | pstack | LOCKED | Challenge requested mechanism/assumption where material. |
| Foundational thinking / model the domain | pstack + Symphony lifecycle doctrine | LOCKED | Data shape and lifecycle ownership before procedural sprawl. |
| Subtract before adding | pstack | LOCKED | Do not introduce new layers if existing ownership can be clarified. |
| Minimise reader load | pstack | LOCKED | Prefer clear ownership/interfaces and reduce cognitive burden. |
| Prove it works | pstack + Superpowers + Symphony | LOCKED | Claims require independently inspectable evidence. |
| How vs Why | pstack | LOCKED | Separate current mechanism from historical/rationale investigation. |
| Progressive disclosure | Matt + Symphony | LOCKED | Do not preload the skill corpus; load descriptor/body/reference on demand. |
| Independent review | Symphony + Superpowers/pstack | LOCKED | Higher-risk work requires fresh/clean-room review. |
| Frameworks are sources, not authorities | Symphony | LOCKED | No external framework controls V4.1 lifecycle/authority. |

---

# 8. Superpowers exact adoption matrix

## 8.1 Governing interpretation

Superpowers is retained as a strong **execution-methodology and procedure source**, especially for:

- isolated work;
- TDD;
- systematic debugging;
- implementation planning;
- subagent execution;
- review;
- verification-before-completion;
- skill testing.

It is **not** Symphony's global controller.

Its useful procedures must be normalized beneath V4.1 responsibility/authority.

| Upstream item | Classification | Symphony decision | Target phase | Normalized Symphony destination | Invocation/authority note |
| --- | --- | --- | --- | --- | --- |
| using-superpowers | Framework-control pattern | REJECT AS GLOBAL CONTROLLER | None | Would require skill invocation before essentially every response/action and would compete with V4.1 authority/routing. Individual useful procedures are normalized separately. | No |
| brainstorming | Skill / design procedure | ADAPT | B/C | `sym.design.brainstorm` | Yes, after admission |
| using-git-worktrees | Execution discipline / skill | ADOPT/ADAPT | Current developer tooling; later governed B/C | `sym.workspace.git_worktree` | Yes |
| writing-plans | Skill | ADOPT/ADAPT | B/C | `sym.plan.implementation` | Yes |
| executing-plans | Supervisor/execution pattern | ADAPT | C | `sym.supervise.execute_plan` | Policy-selected |
| test-driven-development | Skill / engineering procedure | ADOPT | B/C | `sym.implement.tdd` | Yes |
| systematic-debugging | Skill | ADOPT | B/C | `sym.debug.systematic` | Yes |
| dispatching-parallel-agents | Supervisor pattern | ADAPT | C | `sym.supervise.parallel_agents` | No direct authority |
| subagent-driven-development | Supervisor pattern | ADAPT | C | `sym.supervise.subagent_development` | No direct authority |
| requesting-code-review | Review orchestration pattern / skill | ADAPT | B/C | `sym.review.request` | Yes |
| receiving-code-review | Skill | ADAPT | B/C | `sym.review.receive_feedback` | Yes |
| verification-before-completion | Evidence discipline + verification skill | ADOPT | B/C | `sym.verify.completion` | Yes |
| finishing-a-development-branch | Developer/source-control procedure | ADAPT WITH V4.1 RESTRICTIONS | Developer tooling; later C | `sym.source_control.finish_branch` | Human/external merge remains authoritative in V1 |
| writing-skills | Skill-authoring + evaluation method | ADAPT | B/C | `sym.skills.authoring_tdd` | Governed authoring only |
| diagnosing-superpowers | Framework diagnostic | DISCOVERED — NOT LOCKED | Evaluation backlog | None yet | No |

## 8.2 Explicit Superpowers boundary

Symphony deliberately does **not** adopt the upstream global rule:

```text
invoke a relevant skill before every response/action
```

as platform law.

Why:

- V4.1 already owns responsibility routing;
- trivial/bounded work must not acquire ceremonial process;
- skill text cannot outrank authority;
- future selection belongs to `SkillSelectionPolicy`.

Superpowers remains an important source of proven procedures, not a governing shell around Symphony.

---

# 9. Matt Pocock exact adoption matrix

## 9.1 Governing interpretation

Matt Pocock's system is primarily used as a source for:

- skill ergonomics;
- human-invoked versus automatic invocation distinction;
- progressive disclosure;
- requirement interrogation;
- project/domain vocabulary;
- conversation → spec;
- spec → dependency-aware work;
- codebase architecture surveys;
- bounded handoffs.

Its skill router or issue-state machinery does not become Symphony authority.

| Upstream item/pattern | Classification | Symphony decision | Target phase | Normalized Symphony destination | Authority note |
| --- | --- | --- | --- | --- | --- |
| ask-matt | User-facing router over Matt skills | DO NOT ADOPT AS PRODUCTION ROUTER | Developer UX only / optional | Potential dev helper only | Would compete conceptually with Symphony SkillSelectionPolicy if promoted |
| grill-with-docs | Requirement interrogation + domain docs | ADOPT/ADAPT | B/C | `sym.requirements.grill_with_docs` | Yes |
| grilling / grill-me pattern | Requirement interrogation | ADOPT/ADAPT | B/C | `sym.requirements.grill` | Yes |
| to-spec | Conversation → spec | ADOPT/ADAPT | B/C | `sym.spec.conversation_to_spec` | Human-invoked or policy-selected |
| to-tickets | Spec/plan → tracer-bullet work graph | ADOPT/ADAPT | B/C | `sym.plan.to_work_graph` | Human/policy-selected |
| improve-codebase-architecture | Architecture survey + guided deepening | ADOPT CONCEPT / ADAPT | B/C | `sym.design.codebase_architecture_survey` | Yes |
| domain-modeling | Domain vocabulary/model sharpening | ADOPT CONCEPT / ADAPT | B | `sym.design.domain_model` | Yes |
| codebase-design | Design vocabulary / deep module discipline | ADAPT | B/C | `sym.design.codebase` | Yes |
| prototype | Throwaway experiment to settle observable design question | ADOPT CONCEPT / ADAPT | B/C | `sym.design.prototype_experiment` | Policy-selected |
| diagnosing-bugs | Disciplined diagnosis loop | NORMALIZE WITH SYSTEMATIC DEBUGGING | B/C | `sym.debug.systematic` | One Symphony skill, multiple provenance inputs |
| tdd | TDD | NORMALIZE WITH SHARED TDD SKILL | B/C | `sym.implement.tdd` | One Symphony skill, multiple provenance inputs |
| code-review | Standards + spec review | ADOPT CONCEPT / SPLIT | B/C | `sym.review.exact_diff`, `sym.review.contract_compliance` | Clean-room where required |
| implement | Spec/ticket implementation orchestration | DO NOT ADOPT AS SECOND ORCHESTRATOR | C patterns only | Useful implementation steps may be normalized beneath Supervisor | No |
| wayfinder | Large-work decision-map planning | DISCOVERED — NOT YET LOCKED | Evaluation backlog | Possible future planning/supervisor pattern | No current commitment |
| triage | Issue-state triage roles | DO NOT ADOPT AS WORKFLOW AUTHORITY | Developer helper only / evaluate | None | WorkControl owns lifecycle |
| setup-matt-pocock-skills | Repository setup helper | DEVELOPER TOOLING ONLY | Developer tooling | None | Not production skill architecture |
| research | Primary-source research | DISCOVERED — NOT YET LOCKED | Evaluation backlog | Possible `sym.research.primary_sources` | No current commitment |
| resolving-merge-conflicts | Git merge/rebase conflict procedure | DISCOVERED — NOT YET LOCKED | Developer tooling backlog | Possible source-control skill | Must obey SourceControl authority |
| wizard | Human-guided external setup/cutover helper | DISCOVERED — NOT YET LOCKED | Operational tooling backlog | None | No current commitment |

## 9.2 Matt-specific locked rules

1. A user may explicitly request a skill/procedure.
2. A model/runtime may request a skill later.
3. Neither path bypasses skill admission.
4. Progressive disclosure is mandatory for governed skill material.
5. Conversation-to-spec captures settled decisions; it must not quietly invent missing product semantics.
6. Spec-to-work preserves blocking/dependency edges but does not redefine WorkControl.
7. Domain-vocabulary/document updates are project writes and require the appropriate authorization.
8. Whole-transcript replay is not the default handoff mechanism.

---

# 10. pstack / poteto exact adoption matrix

## 10.1 Governing interpretation

pstack/poteto is primarily used as a source for:

- engineering judgement;
- premise challenge;
- domain/data-first reasoning;
- `how` versus `why`;
- architecture alternatives;
- parallel design exploration;
- adversarial review;
- behavioural evaluation;
- proof discipline.

`poteto-mode` itself does not become the Symphony master router.

| Upstream item/pattern | Classification | Symphony decision | Target phase | Normalized Symphony destination | Authority note |
| --- | --- | --- | --- | --- | --- |
| poteto-mode | Master router/playbook controller | REJECT AS SYMPHONY CONTROLLER | None | Ideas decomposed into doctrine, skills, supervisor patterns, and evals | Would compete with V4.1 authority |
| how | Subsystem/runtime-flow investigation | ADOPT | B/C | `sym.investigate.how` | Yes |
| why | Historical/rationale investigation | ADOPT | B/C | `sym.investigate.why` | Yes; provenance-aware |
| architect | Architecture exploration | ADOPT CONCEPT / ADAPT | B/C | `sym.design.architecture_alternatives` | Yes |
| arena | Independent design/code bakeoff | ADOPT AS SUPERVISOR PATTERN | C | `sym.supervise.architecture_arena` | Not a lifecycle authority |
| swarm | Parallel coverage/fan-out | ADOPT AS SUPERVISOR PATTERN | C | `sym.supervise.swarm` | Dependency-safe only |
| interrogate | Adversarial multi-model review | ADOPT CONCEPT / ADAPT | C | `sym.review.adversarial` | Independent-context requirement |
| tdd | TDD | NORMALIZE WITH SHARED TDD SKILL | B/C | `sym.implement.tdd` | One Symphony skill, multiple provenance inputs |
| laziness-protocol principle | Doctrine | ADOPT | B doctrine | `smallest sufficient change` policy | Not a skill authority |
| foundational thinking / model-the-domain | Doctrine | ADOPT | B doctrine | `foundational thinking` / lifecycle-model discipline | Not a skill authority |
| attack the premise | Doctrine + optional procedure | ADOPT | B doctrine; B/C skill | `sym.design.attack_premise` | Yes as procedure; doctrine remains higher-level |
| subtract before you add | Doctrine | ADOPT | B doctrine | Policy/invariant | No |
| minimise reader load | Doctrine | ADOPT | B doctrine | Policy/invariant | No |
| prove it works | Doctrine / evaluation rule | ADOPT | B/C | Evidence-over-claims + verification | No self-certification |
| parallel alternatives | Supervisor pattern | ADOPT | C | `sym.supervise.architecture_arena` / swarm | No direct authority |
| blinded behavioural evaluation | Evaluation method | ADOPT | B/C eval foundation | Skill/router behavioural eval harness | Required before adaptive promotion |
| observable transcript/artifact evaluation | Evaluation method | ADOPT | B/C | Behavioural evaluation | Agent self-description not evidence |
| recall | Context reconstruction | DISCOVERED — NOT LOCKED | C evaluation backlog | Possible Context Broker utility | High provenance/authority risk |
| reflect | Capture lessons into process/skill | ADAPT ONLY AFTER GOVERNED EVIDENCE | Post-B/C learning | Possible FUT learning loop | No automatic promotion |
| teach | How+why explanation | OPTIONAL / NOT CORE | Developer UX | Could compose `how` + `why` | No production dependency |
| no-comments | Comment cleanup/review | DISCOVERED — NOT LOCKED | Skill backlog | Possible code-cleanup skill | No current commitment |
| unslop | Prose cleanup | OPTIONAL / NOT CORE | Developer UX | None | Not architecture-critical |
| technical-writing | Documentation discipline | DISCOVERED — NOT LOCKED | Developer/docs skill backlog | Possible docs skill | No current commitment |
| show-me-your-work | Decision trail | ADOPT CONCEPT ONLY | B evidence/eval | Decision/provenance logging; never trusted merely because agent wrote it | Must bind to trusted evidence |
| figure-it-out | Dynamic playbook generation | DO NOT ADOPT AS AUTHORITY | Experimental only | None | Could create ungoverned workflow authority |
| create-verification-skill | Project verification-skill authoring | ADAPT CONCEPT | B/C | `sym.skills.authoring_tdd` / project-governed verification skill | Requires governance/eval |
| maintain-verification-skill | Verification skill maintenance | ADAPT CONCEPT | B/C | Skill maintenance lifecycle | Versioned/digest-bound |
| typescript-best-practices | Language-specific discipline | PROJECT-LOCAL, NOT GLOBAL | Project-governed | Project SkillContract if needed | No platform-global requirement |
| bro | Plain-language rewrite | OPTIONAL / NOT CORE | Developer UX | None | No architecture role |

## 10.2 pstack principle boundary

Only principles explicitly carried into prior Symphony decisions are locked here.

The current upstream pstack principle catalogue is larger than this matrix.

Unreviewed current upstream principles remain:

```text
DISCOVERED — NOT LOCKED
```

until separately evaluated.

---

# 11. Cross-source normalization rules

Multiple external projects often teach the same useful engineering procedure.

Symphony should not create duplicate global skills merely to preserve source branding.

Examples:

```text
Superpowers TDD
Matt TDD
pstack TDD
    ↓
sym.implement.tdd
```

```text
Superpowers systematic-debugging
Matt diagnosing-bugs
    ↓
sym.debug.systematic
```

```text
pstack arena
Superpowers independent subagent alternatives
    ↓
sym.supervise.architecture_arena
```

A normalized Symphony skill may preserve multiple provenance inputs:

```yaml
provenance:
  sources:
    - obra/superpowers:test-driven-development
    - mattpocock/skills:tdd
    - backnotprop/pstack:tdd
```

but has one governed Symphony identity/version/digest.

---

# 12. Normalized Symphony candidate skill catalogue

This is the **goal catalogue**, not an implementation claim.

Rows marked for B/C do not authorize premature V1 implementation.

| Normalized ID | Family | Classification | Source inspiration | Decision | Phase | Applicable responsibility | Typical capability needs | Core restriction | Expected semantic/evidence output | Runtime-requestable? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| sym.requirements.grill | Requirements | Skill | Matt | ADOPT/ADAPT | B/C | Planning/product-intent contexts | repository_read | No external mutation | Resolved decision branches / questions | No |
| sym.requirements.grill_with_docs | Requirements | Skill | Matt | ADOPT/ADAPT | B/C | Planning | repository_read + governed project-doc write if authorized | Project docs only when authorized | Updated domain vocabulary/ADR proposals | No |
| sym.spec.conversation_to_spec | Specification | Skill | Matt | ADOPT/ADAPT | B/C | Planning | repository_read; tracker write only if separately authorized | Cannot invent undecided semantics | Spec artifact | No |
| sym.plan.to_work_graph | Planning | Skill | Matt + Symphony tracer-bullet doctrine | ADOPT/ADAPT | B/C | Planning | repository_read; work-control write only if authorized | Cannot change WorkControl lifecycle law | Dependency-aware task graph | No |
| sym.design.codebase_architecture_survey | Design | Skill | Matt | ADOPT CONCEPT | B/C | Planning | repository_read | Read-only by default | Architecture survey | No |
| sym.design.domain_model | Design | Skill | Matt + Symphony lifecycle doctrine | ADOPT CONCEPT | B | Planning | repository_read; governed docs write if authorized | Cannot override repository law | Domain model/vocabulary | No |
| sym.design.brainstorm | Design | Skill | Superpowers | ADAPT | B/C | Planning | repository_read | No required invocation for trivial tasks | Design options | No |
| sym.design.attack_premise | Design | Skill + doctrine | pstack | ADOPT | B/C | Planning | repository_read | No authority change | Premise challenge / alternative | No |
| sym.design.architecture_alternatives | Design | Skill | pstack | ADOPT/ADAPT | B/C | Planning | repository_read | No mutation by default | Alternative designs/tradeoffs | No |
| sym.design.prototype_experiment | Design | Skill | Matt | ADOPT CONCEPT | B/C | Planning/implementation when explicitly authorized | bounded workspace_write/test_execution | Throwaway/bounded side effects | Experimental evidence | No |
| sym.investigate.how | Investigation | Skill | pstack | ADOPT | B/C | Planning/review | repository_read | Read-only | Call/data/state/ownership map | Yes |
| sym.investigate.why | Investigation | Skill | pstack | ADOPT | B/C | Planning/review | repository_read + approved history/connectors | Read-only | Rationale with provenance/confidence | Yes |
| sym.debug.systematic | Debugging | Skill | Superpowers + Matt | ADOPT/NORMALIZE | B/C | Planning/implementation/correction | repository_read + test_execution; workspace_write only when authorized | No provider/merge authority | Reproducer, hypotheses, root cause, regression proof | Yes |
| sym.workspace.git_worktree | Execution setup | Skill | Superpowers | ADOPT/ADAPT | Current dev; later B/C | Implementation/correction | workspace/source-control local setup within authority | No remote merge authority | Isolated workspace receipt | No |
| sym.plan.implementation | Planning | Skill | Superpowers | ADOPT/ADAPT | B/C | Planning | repository_read | No implementation authority | Task-sized implementation plan | No |
| sym.implement.tdd | Implementation | Skill | Superpowers + Matt + pstack | ADOPT/NORMALIZE | B/C | Implementation/correction | repository_read + workspace_write + test_execution | Only inside authorized workspace | Red/green/refactor evidence expectations | Yes |
| sym.supervise.execute_plan | Execution | Supervisor pattern | Superpowers | ADAPT | C | Implementation/correction | Delegated child capabilities only | Cannot widen child authority | Task execution events/evidence | No |
| sym.supervise.parallel_agents | Execution | Supervisor pattern | Superpowers | ADAPT | C | Any role where DAG permits | Child subset only | Independent scopes; deterministic reconciliation | Parallel result set | No |
| sym.supervise.subagent_development | Execution | Supervisor pattern | Superpowers | ADAPT | C | Implementation | Child subset only | Spec then code-quality review separation | Candidate work + review outputs | No |
| sym.supervise.architecture_arena | Design | Supervisor pattern | pstack | ADOPT/ADAPT | C | Planning | read-only child contexts by default | No candidate sees competitor output initially | Independent design candidates + synthesis | No |
| sym.supervise.swarm | Investigation/verification | Supervisor pattern | pstack | ADOPT/ADAPT | C | Planning/review/verification | Child subset only | Partitioned scopes | Coverage matrix/results | No |
| sym.review.adversarial | Review | Skill/supervisor pattern | pstack | ADOPT/ADAPT | C | Review | repository_read + trusted evidence | Clean-room / no candidate mutation | Adversarial findings | No |
| sym.review.request | Review | Skill/pattern | Superpowers | ADAPT | B/C | Implementation→review handoff | repository_read | Cannot certify own work | Review request package | No |
| sym.review.receive_feedback | Review | Skill | Superpowers | ADAPT | B/C | Correction | repository_read + workspace_write if authorized | Feedback must be technically validated | Response/correction plan | Yes |
| sym.review.exact_diff | Review | Skill | Matt + Symphony-native | ADOPT/ADAPT | B/C | Review | repository_read + source-control evidence | Read-only; exact candidate | Diff findings | No |
| sym.review.contract_compliance | Review | Skill | Matt + Symphony-native | ADOPT/ADAPT | B/C | Review | repository_read + authority refs | Read-only | Spec/contract traceability findings | No |
| sym.review.lifecycle | Review | Skill | Symphony-native | ADOPT | B/C | Review | repository_read + authority refs | Read-only | Lifecycle invariant findings | No |
| sym.review.security | Review | Skill | Symphony-native | ADOPT | B/C | Review | repository_read + trusted evidence | Read-only unless separate correction execution | Security findings | No |
| sym.review.migration | Review | Skill | Symphony-native | ADOPT | B/C | Review | repository_read + DB/migration evidence when authorized | Read-only review | Migration findings | No |
| sym.review.sql | Review | Skill | Old skill doctrine / Symphony-native | ADOPT CONCEPT | B/C | Review | repository_read | Read-only by default | SQL correctness/safety findings | No |
| sym.verify.completion | Verification | Skill + evidence discipline | Superpowers + Symphony-native | ADOPT | B/C | Verification | trusted evidence access | Cannot trust agent prose | Completion proof inputs | No |
| sym.verify.tests | Verification | Skill | Symphony-native | ADOPT | B/C | Verification | test_execution | Exact execution/candidate binding | Test receipt | No |
| sym.verify.ci | Verification | Skill | Symphony-native | ADOPT | B/C | Verification/review | source-control evidence read | Exact SHA required | CI receipt | No |
| sym.verify.browser | Verification | Skill | Symphony-native / earlier architecture | ADOPT WHEN RELEVANT | B/C | Verification | browser_control if authorized | No hidden authority | Browser assertions/screenshots | No |
| sym.verify.visual | Verification | Skill | Symphony-native / earlier architecture | ADOPT WHEN RELEVANT | B/C | Verification | vision/browser evidence | Rendered-state evidence only | Visual receipt | No |
| sym.verify.performance | Verification | Skill | Symphony-native | ADOPT WHEN RELEVANT | B/C | Verification | benchmark execution | Defined envelope only | Performance receipt | No |
| sym.source_control.finish_branch | Source control | Developer/governed procedure | Superpowers adapted | ADAPT | Current dev / later C | Implementation/review handoff | source-control capabilities as separately authorized | V1 human/external exact-candidate merge remains authoritative | Merge-ready handoff/post-merge verification | No |
| sym.skills.authoring_tdd | Skill governance | Skill-authoring/eval method | Superpowers + pstack verification-skill ideas | ADAPT | B/C | Skill governance | skill repo write in authorized governance context | No auto-promotion | Skill candidate + pressure/eval cases | No |
| sym.handoff.prepare | Handoff | Skill | Matt + Symphony-native | ADOPT | B/C | Any cross-execution handoff | authorized context refs | Bounded context; no whole transcript by default | Provider-neutral handoff | No |
| sym.handoff.clean_room | Handoff | Context pattern / skill | Symphony-native + Matt progressive disclosure | ADOPT | B/C | Independent review | authoritative objective/evidence only | Withhold prior-agent reasoning initially | Clean-room review package | No |

---

# 13. Supervisor, context, and evaluation patterns

These are intentionally **not all SkillContracts**.

| Pattern | Classification | Primary source | Phase | Locked rule |
| --- | --- | --- | --- | --- |
| Architecture arena | SUPERVISOR_PATTERN | pstack | C | Independent candidates, no initial cross-contamination, evidence-driven comparison. |
| Parallel/swarm investigation | SUPERVISOR_PATTERN | pstack + Superpowers | C | Only dependency-safe, partitioned scopes. |
| Subagent-driven development | SUPERVISOR_PATTERN | Superpowers | C | Bounded delegation + independent review stages. |
| Progressive disclosure | CONTEXT_PATTERN | Matt | C | Descriptor → contract metadata → body → references/tools on demand. |
| resume / handoff / clean_room | CONTEXT_PATTERN | Symphony-native with Matt influence | B/C | Preserve least-context and epistemic independence. |
| Blind behavioural evaluation | EVALUATION_METHOD | pstack | B/C | Judge execution/artifacts rather than claimed compliance. |
| Skill pressure tests / skill TDD | EVALUATION_METHOD | Superpowers | B/C | Demonstrate failure without skill, success with skill, close loopholes. |
| Different-model second opinion | EVALUATION_METHOD / optional strengthening | pstack + Symphony | C/D1 | Diversity is strengthening, not definition of independence. |

---

# 14. Explicit reject / do-not-adopt ledger

This section is first-class governance.

An idea being available upstream is not enough reason to keep reconsidering it.

| Pattern | Decision | Reason |
| --- | --- | --- |
| External framework as global controller | REJECT | Would create competing authority above/beside V4.1. |
| Superpowers `using-superpowers` always-first rule as Symphony law | REJECT | Skill invocation cannot outrank WorkControl/authority. |
| pstack `poteto-mode` as Symphony master router | REJECT | Symphony already owns lifecycle/responsibility routing. |
| Matt `ask-matt` as production Skills Router | REJECT | Future `SkillSelectionPolicy` is Symphony-owned and subordinate to responsibility. |
| Generic risk/playbook workflow engine in Programme A | REJECT | Duplicates WorkControl/Orchestrator and violates repo-grounded architecture. |
| Skill prose granting capability/authority | REJECT | Requirements are admissibility checks, not grants. |
| Agent/skill output treated as machine evidence | REJECT | Trusted evidence acquisition remains separate. |
| Whole skill corpus injected by default | REJECT | Violates least-context/progressive disclosure. |
| Model unrestricted self-loading of skills | REJECT | Runtime requests must pass admission. |
| Automatic merge because a skill says so | REJECT FOR V1 | Human/external exact-candidate merge remains V1 authority. |
| Automatic skill modification/promotion from one successful run | REJECT | Requires versioning, evaluation, and governance promotion. |
| External upstream updates silently replacing governed skills | REJECT | Approved `(id, version, digest)` is immutable. |
| Triage skill redefining WorkControl lifecycle | REJECT | Lifecycle authority remains V4.1. |
| Dynamic `figure-it-out` workflow as authority | REJECT | Generated procedure cannot create a new authority/lifecycle layer. |

---

# 15. Invocation architecture

Future governed skills support three invocation classes.

## 15.1 Human-requested

The human explicitly requests a procedure.

Examples:

```text
grill the requirement
investigate how this subsystem works
turn this conversation into a spec
perform a security review
```

This is a request for procedure, not an authority grant.

## 15.2 Policy-selected

`SkillSelectionPolicy` selects a skill for an already-authorized Execution.

This is the primary production path.

## 15.3 Runtime-requested

An executing runtime may request a skill:

```text
systematic-debugging
SQL review
migration safety
browser verification
```

but the request returns to the host for deterministic admission.

The runtime does not self-load arbitrary governed skills.

---

# 16. Skill admission invariants

For every future governed selection:

```text
skill.required_capabilities
⊆
execution.authorized_capabilities
```

```text
skill.requested_context
⊆
execution.authorized_context
```

```text
skill.applicable_responsibilities
contains
execution.responsibility
```

If false:

```text
SKILL_NOT_ADMISSIBLE
```

Allowed outcomes:

```text
reject
select compatible alternative
request explicit escalation
```

Never:

```text
skill requests capability
→ capability automatically granted
```

SkillContract requirements remain predicates and requirements. They do not grant capabilities, credentials, provider/SCM access, or authority.

---

# 17. Governed SkillContract target

Programme B should eventually define a machine-readable contract approximately like:

```yaml
skill:
  id: sym.debug.systematic
  version: 2.1.0
  digest: sha256:...

  provenance:
    class: EXTERNAL_ADAPTED
    sources:
      - obra/superpowers:systematic-debugging
      - mattpocock/skills:diagnosing-bugs

  classification: SKILL

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
      - relevant_candidate_context

  forbids:
    - provider_transition
    - source_control_merge
    - authority_rearm

  side_effect_class: WORKSPACE_MUTATING_CONDITIONAL

  outputs:
    semantic:
      - reproduction
      - hypotheses
      - root_cause
      - correction_rationale

  evidence_expectations:
    - reproduction_receipt
    - regression_test_receipt

  failure_mode: fail_closed
```

---

# 18. Skill lifecycle

Governed catalogue lifecycle:

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

Exceptional:

```text
Rejected
Revoked
```

Rules:

- content is immutable once approved;
- `(skill_id, version, digest)` identifies exact content;
- an edit creates a new version/digest;
- revoked versions cannot begin new governed executions;
- running-execution handling after revocation must be explicit and risk-specific;
- upstream source changes never silently alter an approved Symphony skill.

---

# 19. Progressive disclosure

Future skill materialization should follow:

```text
LEVEL 0
repository / Symphony law

LEVEL 1
authorized responsibility + capability/context envelope

LEVEL 2
compact catalogue descriptors for admissible candidates

LEVEL 3
selected SkillContract metadata

LEVEL 4
selected skill body

LEVEL 5
skill-specific references/examples

LEVEL 6
authorized tools
```

Important:

```text
tool availability is not created by skill text
```

Tools remain host/capability concerns.

---

# 20. Skill / tool / evidence separation

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

Examples:

- `sym.verify.ci` can require current CI evidence;
- it cannot mint CI truth by saying "CI passed";
- a review skill can recommend a provider transition;
- WorkControl decides whether a transition is allowed;
- a source-control skill can prepare a merge-ready handoff;
- V1 human/external merge authority is not created by the skill.

---

# 21. Clean-room skill projection

Clean-room review means more than a clean conversation.

It includes an independently constructed **skill set**.

Example:

```text
Builder
    sym.implement.tdd
    sym.debug.systematic
    sym.plan.implementation

Reviewer
    sym.review.exact_diff
    sym.review.contract_compliance
    sym.review.lifecycle
    sym.verify.ci
```

Reviewer initial context should not inherit:

- Builder skill scratch state;
- Builder debugging narrative;
- Builder confidence;
- Builder self-review;
- hidden prior reasoning.

The reviewer may later inspect prior narrative as clearly labelled semantic input when useful, but it is not initial clean-room evidence.

---

# 22. Subagent skill inheritance

Programme C rule:

```text
child.authorized_capabilities
⊆
delegated parent capability envelope
```

```text
child.authorized_context
⊆
delegated parent context envelope
```

```text
child.selected_skills
⊆
skills admissible for child responsibility + envelope
```

A parent cannot grant a child a skill that requires authority the child does not possess.

---

# 23. Skill conflict/composition vocabulary

Possible metadata relations:

```text
requires
suggests
supersedes
conflicts_with
incompatible_with
must_precede
must_follow
```

Conflict rules:

1. mandatory safety procedure outranks optional convenience procedure;
2. narrower applicable skill may supersede a broad generic one;
3. duplicate normalized procedures collapse;
4. substantive unresolved conflict fails closed or escalates;
5. never resolve safety conflict by concatenating contradictory prompts.

Important:

```text
skill dependency/composition graph
≠
WorkflowLifecycle
```

Skill composition remains inside one authorized responsibility.

---

# 24. Deterministic selection first

Initial Programme C selection should be deterministic.

Example:

```text
responsibility = review
candidate exists
lifecycle-sensitive modules changed
    ↓
sym.review.exact_diff
sym.review.lifecycle
sym.verify.ci
```

Example:

```text
responsibility = correction
failure_class = reproducible_regression
    ↓
sym.debug.systematic
sym.implement.tdd
```

Do not begin with:

```text
ask a model which skills it feels like using
```

---

# 25. Adaptive/model-assisted selection later

Programme D1 may later use a fast/System-One model only as a proposal generator:

```text
task metadata
    ↓
fast model
    ↓
proposed skill set
    ↓
deterministic admission
    ↓
authorized selected skill set
```

The model output is:

```text
PROPOSAL
```

not:

```text
AUTHORITY
```

Promotion requires representative benchmark evidence.

---

# 26. Behavioural evaluation contract

Evaluate actual behaviour, not claimed adherence.

For each skill/selector candidate measure:

- correct trigger/selection;
- unnecessary-selection rate;
- critical-skill omission;
- capability-violation requests;
- context-leak attempts;
- files actually read;
- files actually changed;
- tool requests versus granted tools;
- evidence produced;
- review findings;
- correction loops;
- final independent acceptance;
- token/context cost;
- latency;
- total cost per independently accepted candidate where meaningful.

Evaluation identity should bind:

```text
skill id
skill version
skill digest
selection-policy version
runtime/model
benchmark-case identity
repository/candidate identity
result/evidence
```

This avoids attributing a model improvement to a skill change, or vice versa.

---

# 27. Skill authoring and promotion

A future governed authoring flow should resemble:

```text
need identified
    ↓
baseline/pressure cases
    ↓
draft SkillContract
    ↓
validate schema + references
    ↓
behavioural evaluation
    ↓
authority/capability review
    ↓
governance approval
    ↓
Approved
    ↓
Active
```

The Superpowers idea of testing a skill against pressure scenarios is adopted as an **evaluation method**, not as automatic production authority.

No skill is promoted merely because its author claims it improves behaviour.

---

# 28. External source ingestion

External procedures should enter through:

```text
external source
    ↓
review
    ↓
classify:
    doctrine / skill / supervisor / context / eval / reject
    ↓
normalize to Symphony semantics where applicable
    ↓
declare provenance
    ↓
declare capability/context/side effects
    ↓
behavioural evaluation
    ↓
governance approval
    ↓
versioned governed artifact
```

Never:

```text
install external framework
→ all instructions become Symphony law
```

---

# 29. External-source update rule

Upstream frameworks evolve independently.

Therefore:

- upstream name changes do not rename an active Symphony skill automatically;
- upstream content changes do not mutate an approved digest;
- new upstream skills are `DISCOVERED — NOT LOCKED` until reviewed;
- removed upstream skills do not automatically remove a Symphony-governed derivative;
- provenance may point to a historical upstream commit/version when eventually implemented;
- licence/redistribution implications must be checked before copying external skill text verbatim;
- Symphony should generally normalize ideas/procedures rather than vendor-lock its runtime to upstream layout.

---

# 30. Current developer skills versus future governed skills

Current repository-local files such as:

```text
.codex/skills/commit
.codex/skills/debug
.codex/skills/land
.codex/skills/linear
.codex/skills/pull
.codex/skills/push
.codex/skills/release
```

remain developer/runtime convenience instructions unless individually normalized, evaluated, versioned, and promoted into the future governed catalogue.

They are not production SkillContracts merely because they exist.

The V1 security obligation is only to prove such instruction text cannot enlarge authority.

---

# 31. Phase matrix

| Phase | Skills responsibility |
|---|---|
| **V1 / Programme A** | Prove skill/instruction containment. No production Skills Router. |
| **Programme B** | FUTURE. Define `SkillContract`, catalogue identity/provenance/lifecycle, evaluation identity, handoff references. |
| **Programme C** | FUTURE. Implement deterministic `SkillSelectionPolicy`, Context Broker materialization, runtime requests, subagent/clean-room skill rules. |
| **Programme D1** | FUTURE and optional. Evaluate adaptive/model-assisted proposals and runtime/model/skill co-selection; not a prerequisite for E or F. |
| **Programme E** | FUTURE. Governed learning and invariant promotion. |
| **Programme F** | FUTURE. Production observation and outcome assessment; does not depend on D1. |
| **Post-B/C governed learning** | Propose skill/policy improvements from evidence; blind eval + governance before promotion. |
| **Programme D2** | FUTURE, separate optional remote/distributed expansion only when measured need justifies it. |

---

# 32. Candidate implementation sequence

```text
HARDENED V1 ACCEPTED
        ↓
B-SKILL-01
SkillContract schema + identity/version/digest
        ↓
B-SKILL-02
SkillCatalogue + provenance + lifecycle
        ↓
B-SKILL-03
Skill behavioural-evaluation identity / fixtures
        ↓
B-SKILL-04
Handoff references to selected governed skills
        ↓
C-SKILL-01
Deterministic SkillSelectionPolicy
        ↓
C-SKILL-02
Progressive materialization through Context Broker
        ↓
C-SKILL-03
Runtime-requested skill admission
        ↓
C-SKILL-04
Clean-room/subagent skill projection
        ↓
C-SKILL-05
Skill observability + conflict/composition enforcement
        ↓
BEHAVIOURAL BASELINE ACCEPTED
        ↓
D1-SKILL-01
Optional model-assisted skill proposals
        ↓
D1-SKILL-02
Measured promotion / policy tuning
```

These identifiers are planning labels linked by the canonical roadmap. Linkage does not make them current V4.1 phase authority or implementation authorization. Each future implementation issue still requires its normal explicit governance/phase authorization.

---

# 33. Acceptance criteria for the future skill architecture

The future governed system is not accepted until it demonstrates:

1. skill selection cannot create responsibility;
2. skill selection cannot enlarge authority;
3. capability requirements are subset-checked;
4. context requirements are subset-checked;
5. irrelevant skills are not materialized;
6. exact skill id/version/digest is observable;
7. runtime-requested skills pass admission;
8. reviewer skill sets are clean-room constructed;
9. child skill sets obey delegation bounds;
10. skill prose cannot satisfy machine-evidence guards;
11. skills cannot register trusted host capabilities by themselves;
12. conflicts fail closed or resolve through governed metadata;
13. revoked skills cannot start new governed executions;
14. stale selection is invalidated when relevant bindings move;
15. external framework updates cannot silently change active skills;
16. behavioural evaluation precedes promotion;
17. adaptive selectors remain proposals until deterministic admission;
18. SkillSelectionPolicy remains subordinate to WorkControl/Orchestrator;
19. provenance is retained across normalization;
20. outcome quality is judged by independent acceptance, not number of skills invoked.

---

# 34. Matrix maintenance rules

Update this document when:

- an external idea is formally adopted/rejected;
- a candidate normalized skill is added, merged, split, or superseded;
- classification changes between doctrine/skill/supervisor/context/eval;
- a skill moves between planned/evaluating/active/deprecated/revoked;
- provenance changes;
- a future SkillContract is approved;
- behavioural evaluation changes the adoption decision.

Do **not** change V4.1 sequencing here.

If a matrix change requires:

- a different Programme B/C/D order;
- a new authority boundary;
- a new lifecycle owner;
- a V1 scope change;
- a release-gate change;

then the Unified Execution Roadmap must be amended separately.

---

# 35. Governance linkage and cross-document consistency invariants

Governance linkage is established by
`SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`.

The complete authority relationship is:

```text
V4.1 Master Roadmap
    ↓
Unified Execution Roadmap
    ↓
canonical companion matrices / programme specifications
    ↓
machine contracts, including SkillContract
    ↓
runtime policy decisions
```

Canonical companion matrices and programme specifications are scope-specific peers beneath the Unified Execution Roadmap. Neither may silently supersede the other outside its assigned scope. SkillContract remains below this tier.

The relationship is scope-specific:

- the **V4.1 Master Roadmap** governs normative V4.1 hardening authority and locked invariants;
- the **Unified Execution Roadmap** governs current execution order, inserted prerequisites, programme sequencing, and release gates;
- this **Skills Matrix** governs source/adoption inventory, classification, normalization, provenance, target phase, and explicit rejection/defer decisions;
- a future **SkillContract** governs the exact machine-readable contract for one approved governed skill;
- `SkillSelectionPolicy` selects only admissible governed skills inside an already-authorized Execution.

If this Matrix conflicts with the Unified Execution Roadmap on sequencing, V1 scope, lifecycle/authority, clean-room review, evidence semantics, release gates, or the Skills Router architecture, the Unified Execution Roadmap governs until an explicit accepted roadmap amendment says otherwise.

If the Unified Execution Roadmap conflicts with the V4.1 Master Roadmap on a locked V4.1 invariant or normative programme boundary, the Master Roadmap governs until an explicit authority amendment is accepted.

## Cross-document consistency invariants

### `INV-DOC-01` — Parent roadmap linkage

```text
Matrix.parent_execution_architecture
==
current canonical V4.1 Unified Execution Roadmap version
```

### `INV-DOC-02` — Authority precedence

```text
V4.1 Master Roadmap
>
Unified Execution Roadmap
>
canonical companion matrices / programme specifications
>
machine contracts, including SkillContract
>
runtime policy decisions
```

### `INV-DOC-03` — Context/execution ordering

Every live architecture description must preserve:

```text
authority / responsibility
→ authorized capability + context envelope
→ skill selection + admission
→ ContextPlan
→ Execution requirements
→ ExecutionSelection
→ Runtime Admission / Isolation
→ final context materialization
→ Execution
```

A preliminary `ContextPlan` may exist before runtime selection. Final runtime-specific rendering must not.

### `INV-DOC-04` — Skill non-authority

```text
Skill
≠
Authority
```

A skill may request requirements or procedures. It may never grant authority, capability, credentials, trusted tools, lifecycle progression, or trusted evidence.

### `INV-DOC-05` — Execution identity non-competition

Current `RuntimeAttempt` and future durable Programme-B `Execution` must not become competing authority truths. Future `Execution` must generalize/supersede the current abstraction under the Unified Execution Roadmap's migration rules.

### `INV-DOC-06` — Candidate identity non-competition

Current V1 `CandidateRef` and future Programme-B `Candidate` must not become competing candidate-authority truths. Future `Candidate` must preserve/generalize exact current candidate-binding semantics.

### `INV-DOC-07` — D1 conditionality

```text
Programme D1
is not a mandatory prerequisite for
Programme E or Programme F
```

unless a later explicit accepted dependency proves otherwise.

### `INV-DOC-08` — D2 conditionality

Programme D2 remains a separate conditional remote/distributed-expansion branch and is not implied by multi-runtime/model support.

### `INV-DOC-09` — V1 containment

No Programme B/C/D/E/F item becomes implementation authority during V1 merely because it is described in this Matrix or the Unified Execution Roadmap.

---

# 35A. Historical v1.0.1 amendment record

```text
VERSION
1.0.1

STATUS CHANGE
- promoted from CANONICAL COMPANION CANDIDATE to CANONICAL COMPANION
- roadmap governance linkage is now established

LINKAGE
- parent execution architecture updated from v1.2.0 to v1.3.1
- full Master Roadmap → Unified Roadmap → Matrix → machine-contract hierarchy made explicit

ARCHITECTURE CORRECTION
- ContextPlan now precedes ExecutionSelection
- final runtime-specific context materialization now occurs only after Runtime Admission / Isolation
- final materialization cannot enlarge the authorized context envelope

CONSISTENCY
- cross-document authority, execution/candidate identity, D1/D2 conditionality,
  and V1 non-leak invariants added

ADOPTION INVENTORY
- no locked skill adoption/rejection decision changed
- no normalized Symphony skill identity changed
- no future skill implementation is authorized by this patch

V1 AUTHORITY
- unchanged
```

This is a metadata/governance-consistency patch. It does not reopen the source/adoption inventory and does not authorize Programme B/C/D/E/F implementation.

---

## 35B. v1.0.2 amendment record

```text
VERSION
1.0.2

CHANGES
- corrected the authority hierarchy, with companion matrices and programme specifications as scope-specific peers below the Unified Execution Roadmap and SkillContract below that tier
- linked the parent execution roadmap to v1.3.2 and recorded established governance linkage
- clarified that planning-label linkage does not create phase authority or implementation authorization; each future issue requires explicit governance/phase authorization
```


# 36. Final doctrine

> **External skill frameworks are source material, not Symphony authority.**

> **Symphony adopts ideas by classification and normalization, not by installing a competing controller.**

> **Doctrine guides judgement. Skills provide bounded procedures. Supervisor patterns coordinate bounded workers. Context patterns control information flow. Evaluation methods test behaviour. None of them create lifecycle authority.**

> **The future Skills Router is a subordinate `SkillSelectionPolicy`: it selects the smallest sufficient admissible procedure set for an already-authorized Execution and can never turn skill prose into authority, capability, or trusted evidence.**

---

# 37. Amendment rule

This document is versioned independently from the execution roadmap.

Any successor must:

1. increment SemVer in filename and metadata;
2. preserve explicit adoption/rejection history;
3. distinguish newly discovered upstream material from locked adoption;
4. preserve normalized skill provenance;
5. state whether a prior row is amended, superseded, deprecated, or revoked;
6. never silently turn a discovered upstream skill into a Symphony commitment;
7. keep `Parent execution architecture` synchronized with the current canonical Unified Execution Roadmap when governance linkage changes;
8. preserve `INV-DOC-01` through `INV-DOC-09` unless an explicit accepted higher-authority amendment changes them;
9. require a separate Unified Execution Roadmap amendment when a Matrix change would alter V1 scope, programme order/prerequisites, lifecycle/authority ownership, capability/context boundaries, clean-room independence, evidence semantics, the Skills Router architecture, or release/freeze/acceptance gates.

A Matrix patch does **not** require a roadmap version change when it only adds/evaluates source material, changes adoption status inside already-authorized programme boundaries, normalizes provenance, or deprecates/revokes/supersedes skills without changing sequencing or authority.

---

**End of `SYM-SKILLS-MATRIX-001 v1.0.2`**
