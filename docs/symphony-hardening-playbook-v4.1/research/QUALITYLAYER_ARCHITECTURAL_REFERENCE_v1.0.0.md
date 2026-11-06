# QualityLayer reference decisions for Symphony, v1.0.0

```text
DOCUMENT_ROLE=REFERENCE_DECISION
GOVERNANCE_AUTHORITY=NONE
GATE2_ARCHITECTURE_CHANGE=NO
GATE2_PACKAGE_CHANGE=NO
EXTERNAL_DEPENDENCY=NO
```

Retained architectural reference derived from the [full QualityLayer evaluation](QUALITYLAYER_GATE2_EVALUATION_2026-11-03.md), dated 2026-11-03. The full evaluation preserves the source research and audit trail. This document records the practical recommendations and their limits; it does not create governance authority or amend a package plan.

## A. Executive decision

```text
QUALITYLAYER_STRATEGY=REFERENCE_ONLY
PROOF_OBLIGATION_RECOMMENDATION=DO_NOT_ADD
GATE2_PLAN=UNCHANGED
```

QualityLayer is useful mainly as reference material for evidence presentation, acceptance-result traceability, unresolved-work visibility and review ergonomics. Its documented workflow makes an agreed result traceable through a proving scenario, supporting evidence and reviewer disposition. Symphony can use that relationship to make its existing proof requirements easier to inspect and audit.

QualityLayer must not become an authority layer in Symphony. Its documented flexibility around failed checks, incomplete verification and human approval does not match Symphony's mechanical authority model. Those choices may suit QualityLayer's product, but they cannot determine whether Symphony's guards are satisfied, evidence remains valid, cleanup is complete or work is Done.

Symphony already has the relevant architectural separation. The frozen obligation register defines requirements; domain-specific components own evidence; P09's planned qualification dossier resolves evidence applicability and acceptance. QualityLayer does not reveal a missing authority abstraction. A generic `ProofObligation` object would risk duplicating those responsibilities without making the proofs stronger.

The practical recommendation is to reference generic ideas only. The reviewed revision uses a restrictive custom licence. This evaluation recommends no reuse of code, schemas, prompts, templates, skills, workflow implementation or substantial architecture. Any deeper use requires separate licensing/legal review or explicit permission.

The evidence boundary is also important. QualityLayer's implementation and tests at the pinned revision were git-crypt encrypted. Public documentation supports statements about documented workflow semantics, but cannot certify runtime enforcement, evidence integrity, stale-review rejection, state-machine implementation or independent-review isolation. These findings remain `UNKNOWN`. The recommendations below preserve that uncertainty and grant no implementation authority.

## B. What QualityLayer is useful for

### 1. Acceptance result to evidence traceability

QualityLayer's documented acceptance model follows a useful chain:

```text
agreed result → proving scenario → evidence → reviewer disposition
```

The agreed result states observable behavior. The proving scenario explains how to check it. Evidence records what the check established. The reviewer disposition explains whether that evidence supports acceptance and what remains unresolved.

For Symphony, this relationship can make an obligation's coverage inspectable without replacing its definition or verifier. A reviewer should be able to identify the required claim, follow its evidence references and understand the resulting disposition. An overall favorable summary should not conceal an unproved requirement.

The useful idea is the relationship between these records. The evaluation did not establish a superior QualityLayer schema or executable resolver that Symphony should reproduce.

### 2. Unresolved evidence remains visible

QualityLayer documents a distinction between approving a change and marking its verification results as passed. Unverified outcomes remain unverified after approval.

Symphony should preserve that distinction across failed, missing, unavailable, uncertain, pending and stale evidence. These conditions should remain explicit, with their reasons and affected obligations visible. They should not disappear when a reviewer writes a favorable conclusion or a human records an approval.

Their consequences still depend on Symphony's existing authority rules. Visibility is useful for every proof class; mechanical incompleteness must continue to block the action it governs.

### 3. Independent-review visibility

Useful review presentation should identify:

- who implemented the change;
- who reviewed it;
- whether the review was independent;
- which claims the review covered;
- which claims remain unresolved.

QualityLayer documents separate-agent review and labels review performed without an independent judge. That disclosure is worth referencing. Its exact isolation and context-construction mechanisms could not be verified.

Symphony should present independence through its own RuntimeAttempt, responsibility, lineage and signed review-provenance facts. A reviewer label or different model family is not sufficient evidence of independence.

### 4. Evidence-first review presentation

QualityLayer documents presenting failed and checking acceptance points before less urgent results. Symphony can reference this ordering principle when presenting incomplete, uncertain, stale or otherwise unresolved claims.

The purpose is to direct attention to evidence that affects acceptance. The display must preserve domain-specific meanings rather than reduce every condition to one generic status or score.

### 5. Per-claim review scope

A useful review states what was checked, which evidence was considered, what could not be verified and what remains open.

This makes the substantive coverage of a review easier to assess. A provenance-bound review can establish who made an assessment and what it targets; explicit claim scope explains what that reviewer actually assessed. Symphony benefits from both.

These patterns are documented ideas, not certified QualityLayer enforcement guarantees.

## C. Where these ideas already fit in Symphony

Symphony already separates obligation definitions, evidence production, verification and authority. QualityLayer's useful ideas fit within that separation.

### Obligation definitions and qualification

The Gate 2 obligation register already records obligation IDs, scope through inventory links, acceptance owners, preconditions, pass conditions, required proof, failure dispositions and status. The canonical plan maps the obligations to packages and proof classes.

P09 already calls for a qualification manifest and obligation acceptance dossier. Its planned `QualificationIdentity` and `EvidenceApplicability` records provide the place to identify the qualified implementation and determine which evidence supports which claim.

The opportunity is to make those relationships resolvable and reviewable. A second obligation registry would create another definition to synchronize.

### Scanner and cleanup evidence

The planned `ValidationEvidence` record belongs to candidate validation. The governed scanner policy already requires policy and implementation identities, exact candidate/stage/tree bindings, rule results and uncertainty reasons.

The planned `CleanupEvidence` and `CleanupEvidenceRef` direction belongs to trusted cleanup verification. It binds the relevant attempt, fence, resource set, verification generation and verifier identity. A model-provided attachment or caller-supplied verdict cannot substitute for that evidence.

P09 should consume these owner-issued records and their applicable results. It should not recreate their verification logic.

### Candidate, review and completion identity

`CandidateRef` supplies the existing candidate identity. Candidate tree and policy bindings remain separate. Review provenance binds the assessment to the candidate, tree, policy, reviewer responsibility, RuntimeAttempt fingerprint and lineage.

`MergeVerification` establishes the relevant merge facts. `CompletionProof` carries the controlled completion path through merge authorization, verified merge and completed closure. Local task closure, a review summary or a provider Done observation cannot replace that path.

These records can support a clearer evidence view without introducing a second candidate identity or completion token.

### Evidence classes

`GuardClass` preserves the distinction between:

```text
mechanical_guard
semantic_attestation
human_decision
```

A presentation can show these classes together, but evidence from one class cannot satisfy another. Semantic review does not establish mechanical truth, and human approval does not repair a failed guard.

**QualityLayer does not reveal a missing Symphony authority abstraction. It mainly suggests better ways to present and resolve evidence already owned by existing Symphony components.**

The distinction between existing runtime structures and planned Gate 2 records must remain explicit. This reference does not assert that the planned evidence contracts are already implemented.

## D. Gate 2 recommendations

### Use during Gate 2

These are quality criteria and presentation expectations inside existing package scopes; they are not new implementation requirements unless independently adopted by the relevant package plan/review. They require no new subsystem, generic Evidence Framework or package-topology change. They do not amend the canonical Gate 2 plan or authorize execution.

**Resolve evidence per obligation in P09.** Each disposition should identify the frozen obligation, required proof classes, applicable evidence references and unresolved requirements. Completeness depends on resolving the expected claims, not counting attachments or accepting an overall model verdict.

**Keep unresolved evidence explicit in P08 and P09.** Missing observations, uncertain cleanup, unavailable verification and incomplete qualification must retain their reasons and consequences after review. P08's evidence must remain bounded, secret-free and attributable to the relevant attempt and resources.

**Make reviewer scope and disposition explicit in P09.** Independent review should state which obligations and evidence it considered, which claims it accepts within its responsibility and which remain unverified. Evidence-transfer review must preserve claim-specific limitations rather than broaden historical or synthetic proof.

**Keep evidence classes visibly separate in P07 and P09.** Mechanical check results, semantic assessments and human decisions should be identifiable as different records with different powers. Presenting them together must not imply interchangeability.

**Show independence status through existing provenance.** P07 review/completion evidence and P09 acceptance material should identify the bound reviewer responsibility and provenance. This is clarity in existing records and dossiers, not a requirement to build a new interface during Gate 2.

**Preserve scanner evidence through P06.** The accepted policy and `G2-SCAN-EVIDENCE-1.0.0` remain governing. QualityLayer contributes no reason to change scanner selection, rules, suppressions, output classes or PASS/FAIL/UNCERTAIN semantics.

The same approach applies to the important obligation groups. OB-006 needs bearer-channel proof; OB-015 needs exact candidate validation; OB-019 preserves the durable-source boundary; OB-020 and OB-025 require safe, attributable evidence; OB-023 requires claim-specific transfer review. Their evidence can be presented consistently while their proof conditions remain distinct.

### Defer to V1.1 / refinement

Presentation mechanisms should wait until the actual evidence contracts justify them. Useful candidates include:

- a candidate evidence manifest or joined view;
- an evidence-first operator interface;
- navigation between obligations, attempts, candidates and evidence;
- clearer reviewer independence and provenance display;
- current-versus-historical evidence browsing;
- a human-readable obligation dashboard.

These must be read-only projections over existing authority records. They may locate records and explain their relationships, but must obtain validity from the owning components. A view must not mint a verdict, preserve expired authority or become a prerequisite authority service of its own.

Gate 2 should retain exact identities, dispositions and evidence relationships. Refinement can improve how people navigate them.

## E. Explicit rejects

Symphony should not carry forward the following:

- **QualityLayer as authority kernel.** It must not decide guard satisfaction, dependency completion, candidate freshness, cleanup, Gate 2 acceptance, merge authorization or CompletionProof validity.
- **Reviewer discretion over mechanical failures.** Required CI failure, scanner FAIL or UNCERTAIN, cleanup uncertainty, bearer nondisclosure failure or uncertainty, and incomplete dependencies remain mechanical blocks.
- **Generic task closure as Done.** Approval, local closure or a merged PR is not equivalent to Symphony's controlled completion proof and reconciliation.
- **Generic task-output promotion.** Logs, screenshots and task folders cannot become candidate output merely because they are attached or committed.
- **Optional independence satisfying mandatory review.** Turning independent review off does not fulfill an independent-review requirement.
- **Model diversity replacing provenance.** A different model family does not establish a fresh reviewer attempt, isolation, lineage or candidate binding.
- **Proprietary material reuse.** Do not copy QualityLayer code, prompts, schemas, skills or templates.
- **Workflow cloning.** Do not adopt its complete workflow engine or substantially imitate its architecture.
- **A generic `ProofObligation` authority layer.** Do not create another owner of obligation definitions, evidence validity or acceptance decisions.

These are suitability decisions for Symphony's authority model, not claims that QualityLayer's product choices are defects.

## F. Why `ProofObligation` should not be added

Symphony already separates the static definition of an obligation from the evidence that may satisfy it.

The static definition identifies the obligation, scope, acceptance owner, required proof classes, pass condition, failure disposition and applicability. The frozen register and approved package contracts provide those definitions.

Evidence belongs to domain-specific authorities:

- scanner results belong to `ValidationEvidence`;
- cleanup results belong to `CleanupEvidence`;
- review assessments retain their review provenance;
- merge facts belong to `MergeVerification`;
- controlled completion belongs to `CompletionProof`;
- provider effects remain with their dedicated request/effect ledgers and reconciliation owners;
- integrated qualification belongs to P09's dossier and `EvidenceApplicability` direction.

One generic object would either repeat those records or conceal their differences behind a common verdict. Repetition creates competing definitions and synchronization work. Concealment risks treating unlike proofs as interchangeable.

The subject identities also differ. Candidate claims bind candidate, tree and policy. Cleanup claims bind RuntimeAttempt, grant, fence, resources and verification generation. Bearer claims concern holder, credential and channel scope. Provider effects concern particular requests and external effects. Transfer claims depend on implementation, topology and version.

A universal candidate-centric schema cannot express all of these correctly. A generic verifier name, timestamp or PASS field cannot replace the owner-specific checks. Historical PASS does not establish current satisfaction. Local cleanliness does not establish upstream token invalidity or resolution of an external effect.

The preferred direction is:

> Let P09 resolve existing owner-issued evidence against the frozen obligation definitions.

That resolution should expose missing evidence, wrong subjects, stale generations, incomplete coverage and unsupported applicability. It should consume the owning components' results rather than recompute them through a second policy engine.

QualityLayer demonstrates the usefulness of linking requirements, evidence and review. It does not establish that Symphony needs another first-class abstraction to represent that relationship.

If implemented producers later demonstrate real repeated semantics, reconsider abstraction during V1.1. The proposal should remove duplication or replace an existing responsibility, not introduce a parallel registry or authority owner. There is no basis for doing that before such evidence exists.

## G. Mechanical authority boundary

The governing rule remains:

```text
Mechanical failure cannot be waived by semantic or human review.
```

QualityLayer's documented flexibility can inform how Symphony presents evidence, but not how Symphony grants authority.

**Red project check.** QualityLayer documents a reviewer assessing a red check. In Symphony, required CI must succeed for the exact candidate and configured check identity. A reviewer explanation may accompany the failure; it cannot satisfy the guard.

**Missing evidence.** QualityLayer allows missing tools, skipped required lines and unresolved work to reach Review. Symphony can preserve that visibility, but missing mandatory proof remains unsatisfied. An explanation of why evidence is absent is not the evidence itself.

**Independent review disabled.** QualityLayer documents disclosure when no independent judge ran. Symphony should also disclose the condition, while refusing to treat it as fulfillment of a mandatory independent-review obligation.

**Human approval with open issues.** QualityLayer allows approval without changing unverified results to passed. Symphony may record a human decision while other matters remain open, but the relevant transition still requires every separate mechanical and semantic guard.

**Candidate changed after review.** General stale-review enforcement in QualityLayer could not be verified from the readable evidence. Symphony retains exact candidate/tree/policy binding and invalidation. A previous review cannot remain valid merely because its record still exists.

**Generic attached evidence.** QualityLayer documents task folders containing output and pictures. Symphony's source candidate remains restricted to admitted, validated source. Trusted evidence has separate provenance, storage and safety requirements; attachment does not confer trust.

These boundaries preserve `mechanical_guard`, `semantic_attestation` and `human_decision` as non-interchangeable classes. They do not imply that QualityLayer bypasses GitHub protection or is insecure. They identify where its documented workflow cannot substitute for Symphony's law.

## H. Licensing and provenance

```text
QUALITYLAYER_CODE_REUSE=NO
QUALITYLAYER_SCHEMA_REUSE=NO
QUALITYLAYER_PROMPT_TEMPLATE_REUSE=NO
QUALITYLAYER_ARCHITECTURE_CLONING=NO
```

The reviewed revision uses a restrictive custom licence. It restricts redistribution, derivative works and competitive use, and its derivative-work definition includes substantial architecture or structure reuse. Internal-use rights do not establish permission to distribute an adaptation in Symphony.

The practical boundary is:

```text
REFERENCE GENERIC IDEAS ONLY
```

Generic ideas may inform Symphony's thinking about observable acceptance results, unresolved evidence and review presentation. Any implementation must derive from Symphony's own accepted requirements, architecture and evidence contracts.

This evaluation recommends no code, schema, prompt, template or skill reuse; no workflow cloning; and no substantial architectural imitation. Public repository access does not establish a reuse grant. Newly written code alone would not establish that a substantially similar design is permitted.

This document is not a clean-room implementation specification or a definitive legal judgment. Deeper use requires separate licensing/legal review or explicit permission. `REFERENCE_ONLY` must not be reinterpreted as approval for clean-room adoption.

## I. Recommended actionable takeaways

### Carry into Gate 2

1. Maintain obligation-to-evidence-to-disposition traceability in the existing P09 dossier.
2. Preserve unresolved evidence and its consequences after review or approval.
3. Make reviewer independence, claim scope and unverified work explicit.
4. Keep mechanical evidence, semantic attestations and human decisions visibly distinct.
5. Separate historical results from current evidence validity using existing identity and invalidation rules.

These quality criteria inform existing package work. They do not create new implementation requirements unless independently adopted by the relevant package plan/review, and they authorize no new subsystem or interface.

### Carry into V1.1

1. Consider a read-only evidence dashboard over existing records.
2. Present unresolved and risky claims before already-satisfied claims.
3. Improve candidate, obligation and evidence navigation.
4. Improve independence and provenance presentation.
5. Support current-versus-historical evidence browsing without restoring stale authority.

Each proposal must justify its value against the implemented record contracts and preserve existing ownership.

### Do not carry forward

1. A generic `ProofObligation` authority abstraction.
2. QualityLayer's workflow engine or complete workflow architecture.
3. Discretionary treatment of Symphony's required mechanical checks.
4. QualityLayer's task-output storage model as candidate publication policy.
5. Copied proprietary implementation, schemas, prompts, skills or templates.

### Short provenance appendix

This reference condenses the original read-only evaluation dated 2026-11-03. It introduces no additional research or implementation findings. The [full evaluation](QUALITYLAYER_GATE2_EVALUATION_2026-11-03.md) remains the forensic record; this versioned reference records what future Symphony work should use conceptually, reject and defer.

```text
SYMPHONY_MAIN_SHA=86336d28671cfd6ac0a55c2ebe48094b8d8a8237
SYMPHONY_MAIN_TREE=4c362c8800c3ebb75408d1af015184f5beb04d5a

QUALITYLAYER_SHA=16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f
QUALITYLAYER_TREE=e8424e83395324a20fe6ea54dead993b6215ae76
```

These are the evaluated baselines, not a claim about either repository's later state. The Gate 2 inventory comprised 115 rows, 26 obligations and 14 lifecycles. Planned Gate 2 evidence records remain distinguished from existing runtime implementation.

The principal retained references are QualityLayer's pinned [Verify documentation](https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/verify.md), [Review documentation](https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/review.md) and [licence](https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/LICENSE), together with Symphony's pinned [Gate 2 implementation plan](https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/superpowers/plans/2026-11-03-gate2-v1-implementation-plan.md) and [H-120A authority contract](https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/H-120A_GOVERNANCE_PRE_GATE.md).

## J. Final disposition

QualityLayer does not change Symphony's Gate 2 architecture. Its useful contribution is a reference for presenting and reviewing evidence within the existing authority model.

```text
QUALITYLAYER_STRATEGY=REFERENCE_ONLY

QUALITYLAYER_AUTHORITY_DELTA=NONE
QUALITYLAYER_RUNTIME_DEPENDENCY=NO
QUALITYLAYER_CODE_REUSE=NO
QUALITYLAYER_ARCHITECTURE_REUSE=NO

PROOF_OBLIGATION_RECOMMENDATION=DO_NOT_ADD

GATE2_ARCHITECTURE_AMENDMENT_REQUIRED=NO
GATE2_PACKAGE_TOPOLOGY_CHANGE_REQUIRED=NO
GATE2_PLAN=UNCHANGED

QUALITYLAYER_GATE2_USE=
  EVIDENCE_PRESENTATION_AND_REVIEW_REFERENCE_ONLY

QUALITYLAYER_REFINEMENT_USE=
  V1_1_EVIDENCE_UX_REFERENCE

IMPLEMENTATION_AUTHORIZED_BY_THIS_REPORT=NO
H100_AUTHORIZED_BY_THIS_REPORT=NO
```
