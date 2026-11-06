# Gate 2 QualityLayer evidence refinement, 2026-11-03

## Authority and scope

This document persists the supplied Master Gate acceptance of QualityLayer reference
research and independent adoption of five generic supplemental mandatory Gate 2
evidence/qualification refinements. The supplied decision selects these requirements;
research, the retained reference, merge, CI and this machine projection cannot grant
themselves authority. No separate decision ID or exact decision timestamp was supplied;
none is invented. This documentation candidate requires independent Master Gate
review and human merge. It claims no implementation, qualification or Gate 2 acceptance.

The five refinements apply only to mapped existing package responsibilities. They
are mandatory when those packages are implemented and reviewed. They do not authorize
implementation, change architecture, authority ownership or P01-P09 topology, or edit
the canonical Gate 2 plan. The retained source reference remains non-authoritative;
its recommendation to adopt criteria independently is fulfilled only by this separate
supplied Master Gate decision, not retroactively by the reference itself.

Authority precedence remains the [V4.1 Master Roadmap](V4_1_MASTER_ROADMAP.md),
[Unified Execution Roadmap](../SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md),
accepted scoped governance, [canonical Gate 2 plan](../superpowers/plans/2026-11-03-gate2-v1-implementation-plan.md),
[immutable freeze packet](GATE2_INVENTORY_FREEZE_PACKET_1458bb041215c626.json),
[scanner addendum](GATE2_SCANNER_GOVERNANCE_ADDENDUM_2026-11-03.md),
[policy](GATE2_V1_CANDIDATE_VALIDATION_1.0.0.json),
[scanner projection](GATE2_SCANNER_GOVERNANCE_PROJECTION.json), and accepted
[Herdr refinement](GATE2_HERDR_QUALIFICATION_REFINEMENT_2026-11-03.md) and
[Herdr projection](GATE2_HERDR_QUALIFICATION_REFINEMENT.json), within their scopes.
Current execution authority must be read from current scoped governance. Historical
G00/pre-implementation locks are not current package execution decisions. This task
neither re-adjudicates applicability rebinding nor alters separately issued P01 authority.

## Exact baseline and research provenance

```ini
MAIN_SHA=0c53c732bbf68641482741c98afb25e073721ad9
MAIN_TREE=a9fbf6ad3d57ee24d8b4989a953e512de41cb264
MAIN_PROTECTED=true
PARENT_1=86336d28671cfd6ac0a55c2ebe48094b8d8a8237
PARENT_2=1d7deb1434011eb86803a7623d0c8823fd059498
HERDR_PR_HEAD=1d7deb1434011eb86803a7623d0c8823fd059498
REQUIRED_CHECK_1=make-all
REQUIRED_CHECK_1_APP_ID=15368
REQUIRED_CHECK_2=validate-pr-description
REQUIRED_CHECK_2_APP_ID=15368
PLAN_GIT_BLOB=bdb2840e5ea4ca8c8912d6cada3287078bbb3c72
PLAN_SHA256=a1d5cdba65c19a09e86ed814a595e8bbae0c9dcfc97afe021ab67826db09ff68
```

The [full evaluation](research/QUALITYLAYER_GATE2_EVALUATION_2026-11-03.md) preserves the supplied research body byte-for-byte
after its archive header. The [architectural reference](research/QUALITYLAYER_ARCHITECTURAL_REFERENCE_v1.0.0.md)
preserves the retained reference with only its two relative evaluation links relocated.
Its DOCUMENT_ROLE=REFERENCE_DECISION and GOVERNANCE_AUTHORITY=NONE remain true.
Research-era authority/status observations are historical. The [JSON projection](GATE2_QUALITYLAYER_EVIDENCE_REFINEMENT.json)
records exact archive/reference and unchanged governing-artifact identities. It is
a derivative Symphony-native governance projection, not a copied QualityLayer schema.

```ini
FULL_EVALUATION_GIT_BLOB=26709af1aef0f55ab7dea808a2b0505ee8756d87
FULL_EVALUATION_SHA256=f1b25fc2bf1c8552c067d5331cb507254d421ce3e2fdf8778b17adbf8d4fb615
```

```ini
ARCHITECTURAL_REFERENCE_GIT_BLOB=0bf5f5d074d45fe21bb4cdda169662099ec31744
ARCHITECTURAL_REFERENCE_SHA256=ddd3d2d6305c75b3dd084b5b96c8bf7c4d27812509e0e89d60bd4e048aceb056
```

```ini
QUALITYLAYER_REPOSITORY=https://github.com/maxritter/qualitylayer
QUALITYLAYER_SHA=16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f
QUALITYLAYER_TREE=e8424e83395324a20fe6ea54dead993b6215ae76
QUALITYLAYER_LICENSE=QualityLayer Software License Agreement, custom proprietary terms
QUALITYLAYER_LICENSE_BLOB=467a5e40c642fc69497d1193b4405ed5eaa4f02d
QUALITYLAYER_LICENSE_SHA256=0de841524089e421084a8cb4b8e5261244d637ed6ae36d4d64b2f3b80736f180
```

- Implementation and tests under qualitylayer/ were git-crypt encrypted at the pinned revision.
- Readable public documentation supports documented workflow semantics only.
- Runtime enforcement, state-machine implementation, evidence integrity, general stale-review rejection and independent-review isolation remain UNKNOWN where source access was unavailable.
- Infer no behavior from encrypted filenames; no QualityLayer build, execution, test run, decryption or access-control circumvention occurred.

Documented semantics are CONFIRMED_FROM_DOCS; inaccessible runtime behavior is
UNKNOWN; research recommendations are INFERENCE. Research acceptance is not
executed implementation qualification. No encrypted filename establishes behavior.

## Master Gate disposition

```ini
QUALITYLAYER_RESEARCH_STATUS=ACCEPTED_AS_REFERENCE_RESEARCH
QUALITYLAYER_STRATEGY=REFERENCE_ONLY
QUALITYLAYER_AUTHORITY_DELTA=NONE
QUALITYLAYER_RUNTIME_DEPENDENCY=NO
QUALITYLAYER_CODE_REUSE=NO
QUALITYLAYER_SCHEMA_REUSE=NO
QUALITYLAYER_PROMPT_TEMPLATE_REUSE=NO
QUALITYLAYER_SKILL_REUSE=NO
QUALITYLAYER_WORKFLOW_REUSE=NO
QUALITYLAYER_ARCHITECTURE_CLONING=NO
PROOF_OBLIGATION_RECOMMENDATION=DO_NOT_ADD
GATE2_ARCHITECTURE_CHANGE=NO
GATE2_AUTHORITY_MODEL_CHANGE=NO
GATE2_PACKAGE_TOPOLOGY_CHANGE=NO
GATE2_PACKAGE_TOPOLOGY=P01-P09
GATE2_CANONICAL_PLAN_CHANGE=NO
QUALITYLAYER_EVIDENCE_QUALIFICATION_REFINEMENT=YES
```

## Mandatory qualification refinements


### G2-QL-Q01

```ini
NAME=OBLIGATION_EVIDENCE_DISPOSITION_TRACEABILITY
PRIMARY_TARGET_PACKAGES=P09
SECONDARY_TARGETS=P06,P07,P08
IMPLEMENTATION_STATUS=NOT_IMPLEMENTED
QUALIFICATION_STATUS=NOT_PROVEN
```

Source research concept: Acceptance result, proving scenario, evidence and reviewer disposition traceability.


#### Invariants

- Follow frozen obligation definition -> required proof classes -> owner-issued applicable evidence references -> current applicability -> unresolved requirements -> claim-specific disposition.
- P09 assesses the expected frozen obligation set. Completeness is not 26 files, one attachment per obligation or an overall reviewer PASS.
- P09 consumes owner-issued results without reimplementing scanner, cleanup, provider-effect, review or merge verification.

#### Mandatory qualification expectations

- Detect and expose missing expected obligation IDs.
- Detect and expose duplicate or ambiguous obligation assessments.
- Detect and expose wrong evidence subjects.
- Detect and expose wrong policy/version.
- Detect and expose wrong implementation/configuration identity where relevant.
- Detect and expose stale generations.
- Detect and expose missing required proof classes.
- Detect and expose incomplete coverage.
- Detect and expose unsupported evidence-transfer applicability.
- Detect and expose unresolved required evidence.

#### Failure and unresolved semantics

- Missing, ambiguous, inapplicable, stale or incomplete required evidence remains unresolved and blocks qualification wherever the owning obligation requires it.
- An overall favorable review cannot substitute for claim-specific coverage.

#### Authority limits

- No new subsystem, package, obligation registry or authority owner.
- Consume owner-issued evidence/results; do not copy domain truth into a second store or recompute domain verdicts.
- No implementation or execution authority is granted.

#### Licensing and provenance boundary

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.

### G2-QL-Q02

```ini
NAME=UNRESOLVED_EVIDENCE_PERSISTENCE
PRIMARY_TARGET_PACKAGES=P08,P09
SECONDARY_TARGETS=NONE
IMPLEMENTATION_STATUS=NOT_IMPLEMENTED
QUALIFICATION_STATUS=NOT_PROVEN
```

Source research concept: Unresolved verification state survives favorable review or approval.


#### Invariants

- A favorable semantic review or human approval does not erase unresolved evidence state.
- Preserve domain vocabulary where it is stronger; do not impose a universal evidence-result enum.
- An explanation for missing evidence is not the evidence. Human approval cannot convert UNKNOWN, UNCERTAIN or STALE to PASS.

#### Mandatory qualification expectations

- Preserve and expose conditions equivalent to FAILED, MISSING, UNAVAILABLE, UNCERTAIN, STALE, PENDING, INCOMPLETE and NOT_APPLICABLE_WITHOUT_ACCEPTED_JUSTIFICATION.
- Preserve each unresolved condition and its owning-contract consequence through review, approval and retained evidence presentation.

#### Failure and unresolved semantics

- Mechanical incompleteness remains a mechanical block wherever the owning contract says it blocks.
- Unjustified non-applicability remains unresolved, not a satisfied obligation.

#### Authority limits

- No new subsystem, package, obligation registry or authority owner.
- Consume owner-issued evidence/results; do not copy domain truth into a second store or recompute domain verdicts.
- No implementation or execution authority is granted.

#### Licensing and provenance boundary

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.

### G2-QL-Q03

```ini
NAME=PER_CLAIM_REVIEW_SCOPE_AND_DISPOSITION
PRIMARY_TARGET_PACKAGES=P09
SECONDARY_TARGETS=P07
IMPLEMENTATION_STATUS=NOT_IMPLEMENTED
QUALIFICATION_STATUS=NOT_PROVEN
```

Source research concept: Per-claim review coverage and explicit independence/provenance visibility.


#### Invariants

- A single global REVIEW_ACCEPTED=true is not sufficient evidence of substantive coverage.
- Preserve fresh Reviewer RuntimeAttempt, responsibility, lineage, candidate/tree/policy binding, signed host provenance, freshness/invalidation and separate human authority.
- Reviewer narrative cannot mint mechanical truth. A different model family does not prove independence.
- A disclosed non-independent review cannot satisfy mandatory independent review.

#### Mandatory qualification expectations

- For each assigned claim, retain or derive the obligation/claim reviewed and applicable evidence references considered.
- Expose what the reviewer established within their responsibility, what remained unresolved, their disposition and the reviewer provenance already required by Symphony.

#### Failure and unresolved semantics

- Missing scope, unresolved required coverage or invalid/missing independence/provenance cannot be replaced by a global acceptance flag.
- Apply existing review authority and invalidation rules; change no accepted review path.

#### Authority limits

- No new subsystem, package, obligation registry or authority owner.
- Consume owner-issued evidence/results; do not copy domain truth into a second store or recompute domain verdicts.
- No implementation or execution authority is granted.
- No reviewer quorum, new review authority or model-family substitution is introduced.

#### Licensing and provenance boundary

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.

### G2-QL-Q04

```ini
NAME=GUARD_CLASS_VISIBLE_SEPARATION
PRIMARY_TARGET_PACKAGES=P07,P09
SECONDARY_TARGETS=NONE
IMPLEMENTATION_STATUS=NOT_IMPLEMENTED
QUALIFICATION_STATUS=NOT_PROVEN
```

Source research concept: Presentation distinguishes mechanical verification, semantic assessment and human decision.


#### Invariants

- Keep mechanical_guard, semantic_attestation and human_decision visibly distinct with their different powers explicit.
- Mechanical evidence cannot be satisfied by semantic review; semantic review cannot manufacture a mechanical fact.
- Human approval cannot repair a failed mechanical guard; one passing class cannot silently satisfy another required class.

#### Mandatory qualification expectations

- Qualification/review material identifies which required guard classes actually hold.
- Do not collapse proof into APPROVED, PASS or GREEN where that presentation hides required-class satisfaction.

#### Failure and unresolved semantics

- A missing or failed required class remains unsatisfied despite success or approval in another class.
- Presentation ambiguity cannot establish satisfaction of a required guard.

#### Authority limits

- No new subsystem, package, obligation registry or authority owner.
- Consume owner-issued evidence/results; do not copy domain truth into a second store or recompute domain verdicts.
- No implementation or execution authority is granted.
- This is qualification/presentation over the existing GuardClass model, not a new guard model.

#### Licensing and provenance boundary

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.

### G2-QL-Q05

```ini
NAME=HISTORICAL_RESULT_CURRENT_APPLICABILITY_SEPARATION
PRIMARY_TARGET_PACKAGES=P09
SECONDARY_TARGETS=P06,P07,P08
IMPLEMENTATION_STATUS=NOT_IMPLEMENTED
QUALIFICATION_STATUS=NOT_PROVEN
```

Source research concept: Historical recorded result remains separate from currently resolved applicability.


#### Invariants

- recorded_result != current_applicability; RECORDED_RESULT=PASS with CURRENT_APPLICABILITY=STALE is representable without rewriting historical PASS.
- Current applicability follows the owning contract relevant invalidation dependencies, not one universal identity tuple.
- Historical evidence is immutable. STALE can become newly assessed CURRENT only through fresh owner-resolution/reconciliation under a new assessment generation or equivalent current binding.
- Timestamps alone never restore applicability. Memory retention and document age are not evidence freshness.

#### Mandatory qualification expectations

- Resolve relevant candidate/tree, policy/version, implementation, configuration, RuntimeAttempt/lineage, resource/fence/recovery generation, credential/holder/channel, topology/version and evidence-transfer scope dependencies.
- Qualify the complete applicability lifecycle below, including owner, guard, side effect, failure, restart and state meaning.
- Permit NOT_APPLICABLE only with explicit governed justification for the exact subject/current scope, never merely to close the dossier.

#### Failure and unresolved semantics

- Any required invalidation dependency that moves or becomes uncertain invalidates current applicability.
- Failed resolution remains UNRESOLVED; lost current applicability fails closed as STALE/UNRESOLVED, not restored authority.
- Preserve historical results; create a fresh assessment rather than editing an old result into validity.

#### Authority limits

- No new subsystem, package, obligation registry or authority owner.
- Consume owner-issued evidence/results; do not copy domain truth into a second store or recompute domain verdicts.
- No implementation or execution authority is granted.

#### Licensing and provenance boundary

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.

#### Derived applicability lifecycle

States: UNRESOLVED, CURRENT, STALE, NOT_APPLICABLE. These are applicability
assessment states, not a universal enum for domain evidence results.

Relevant invalidation dependencies:

- candidate identity/tree
- policy identity/version
- implementation identity
- configuration identity
- RuntimeAttempt/lineage
- resource/fence/recovery generation
- credential/holder/channel
- topology/version applicability
- evidence-transfer scope

##### UNRESOLVED -> CURRENT

- Owner: P09 applicability resolver consuming current owner-issued evidence
- Guard: Required obligation definition, proof classes, subject identities, policy/implementation/configuration identities and owner verification resolve without unresolved dependency.
- Side effect: Record a current applicability assessment referencing immutable historical evidence rather than copying its truth.
- Failure transition: Remain UNRESOLVED.
- Restart semantics: Re-resolve current dependencies; never assume previous process-memory state or restore current authority from it.
- Current/terminal meaning: CURRENT is a revocable derived applicability assessment, not execution authority or a terminal evidence verdict.

##### CURRENT -> STALE

- Owner: Applicability/reconciliation boundary
- Guard: Any required invalidation dependency moves or becomes uncertain.
- Side effect: Preserve historical result and record stale applicability with explicit invalidation reason.
- Failure transition: Fail closed as STALE/UNRESOLVED; never preserve current authority when invalidation or assessment persistence is uncertain.
- Restart semantics: Restore no current applicability unless dependencies re-resolve.
- Current/terminal meaning: STALE is unusable as current applicable proof; historical results remain unchanged.

##### STALE -> CURRENT

- Owner: P09 applicability resolver consuming fresh owner-issued evidence/reconciliation
- Guard: Fresh owner-issued evidence/reconciliation proves applicability under present identities, policies and generations.
- Side effect: Create a fresh applicability assessment under a new generation or equivalent current binding; do not mutate historical result.
- Failure transition: Remain STALE or UNRESOLVED under existing reconciliation semantics; do not reuse an old current assessment.
- Restart semantics: Re-resolve present dependencies; process restart or restored assessment history is not renewed applicability.
- Current/terminal meaning: Newly assessed CURRENT is revocable; the old assessment and immutable evidence remain historical.

##### UNRESOLVED -> NOT_APPLICABLE

- Owner: P09 applicability resolver applying frozen/governed applicability rules
- Guard: Frozen/governed applicability rules establish non-applicability for the exact subject and current scope.
- Side effect: Record explicit governed justification and the subject/scope/rules it depends on.
- Failure transition: Remain UNRESOLVED when justification is missing, ambiguous, unsupported or merely a model/reviewer preference.
- Restart semantics: Re-resolve governed justification and its dependencies; scope/rule movement or uncertainty requires fresh UNRESOLVED assessment.
- Current/terminal meaning: NOT_APPLICABLE resolves this assessment only within its justified governed scope; it is not PASS, a waiver or authority.

##### State and restart meanings

- UNRESOLVED: Required applicability is not established; no qualification satisfaction follows.
- CURRENT: Revocable derived assessment for current owner-verified dependencies; no execution authority.
- STALE: Prior assessment is not usable as current applicability; retain historical result.
- NOT_APPLICABLE: Scoped governed justification, not a passing proof or waiver. Dependency movement/uncertainty requires a new UNRESOLVED assessment.

If governed justification for NOT_APPLICABLE moves or becomes uncertain, start a new UNRESOLVED assessment and preserve the previous justified assessment as history.

This lifecycle describes derived applicability within existing P09 responsibilities. It creates no independent runtime authority owner or universal subject identity.

## Explicit rejects

- `G2-QL-R01` QUALITYLAYER_AS_AUTHORITY_KERNEL: REJECT. QualityLayer cannot determine guard/dependency satisfaction, candidate freshness, cleanup completeness, Gate 2 acceptance, merge authority or CompletionProof validity.
- `G2-QL-R02` REVIEWER_WAIVER_OF_MECHANICAL_FAILURES: REJECT. Required CI, scanner FAIL/UNCERTAIN, cleanup uncertainty, bearer nondisclosure failure/uncertainty and incomplete mandatory proof remain governed mechanical conditions.
- `G2-QL-R03` GENERIC_TASK_CLOSURE_AS_SYMPHONY_DONE: REJECT. Plan/review approval, local closure or merged PR is not CompletionProof.completed.
- `G2-QL-R04` GENERIC_TASK_OUTPUT_PROMOTION: REJECT. Logs, screenshots, task folders, command output and attachments do not become candidate output merely through task persistence.
- `G2-QL-R05` OPTIONAL_INDEPENDENCE_SATISFYING_MANDATORY_REVIEW: REJECT. Disclosure of missing independence does not satisfy an independent-review requirement.
- `G2-QL-R06` MODEL_DIVERSITY_REPLACING_PROVENANCE: REJECT. Different model family is supplementary only and does not establish reviewer RuntimeAttempt or provenance.
- `G2-QL-R07` GENERIC_PROOF_OBLIGATION_AUTHORITY_ABSTRACTION: REJECT. Create no additional owner of obligation definition, evidence validity or acceptance.
- `G2-QL-R08` PROPRIETARY_IMPLEMENTATION_OR_EXPRESSION_REUSE: REJECT_ABSENT_EXPLICIT_SUITABLE_PERMISSION. No QualityLayer code, schemas, prompts, templates, skills, UI expression or workflow implementation reuse absent explicit suitable permission.
- `G2-QL-R09` QUALITYLAYER_WORKFLOW_OR_ARCHITECTURE_CLONING: REJECT. Do not reproduce its complete workflow/state architecture or create a second workflow owner for Gate 2.

These are Symphony Gate 2 suitability boundaries, not findings that QualityLayer
is insecure or defective for its own product. General stale-review enforcement
could not be verified from available readable evidence; do not claim it is absent.

## Licensing and provenance boundary

```ini
QUALITYLAYER_GENERIC_CONCEPT_REFERENCE=PERMITTED_FOR_THIS_COMPARATIVE_GOVERNANCE_USE
QUALITYLAYER_CODE_REUSE=NO
QUALITYLAYER_SCHEMA_REUSE=NO
QUALITYLAYER_PROMPT_REUSE=NO
QUALITYLAYER_TEMPLATE_REUSE=NO
QUALITYLAYER_SKILL_REUSE=NO
QUALITYLAYER_UI_COPYING=NO
QUALITYLAYER_WORKFLOW_CLONING=NO
QUALITYLAYER_ARCHITECTURE_CLONING=NO
```

- Generic Master Gate-selected Symphony evidence/qualification principle only; no QualityLayer expression, structure, schema or workflow is adopted.
- Implementation must derive from Symphony frozen obligations, canonical package contracts and existing typed evidence owners.
- This is not a clean-room implementation specification or legal clearance. Deeper expressive/structural similarity requires separate licensing/legal review or explicit suitable permission.
- Restrictive custom licence covers code, documentation, skills, commands, configuration and UI; public GitHub visibility establishes no redistribution or derivative rights.
- Redistribution, derivative works and competitive use are restricted; the derivative-work definition includes substantial architecture or structure reuse. Internal-use rights do not establish distributed-product reuse rights.
- No definitive legal enforceability claim or legal clearance is made.

## Existing evidence ownership and P09 qualification

- ValidationEvidence: candidate scanner/validation owner.
- CleanupEvidence / CleanupEvidenceRef: cleanup verifier owner.
- review provenance: SourceControl/reviewer binding.
- MergeVerification: merge verification owner.
- CompletionProof: controlled completion owner.
- provider request/effect records: provider-effect owner.
- QualificationIdentity / EvidenceApplicability / P09 dossier: integrated qualification/applicability layer.

P09 may join and refer to owner-issued records. It must not:

- copy owner records into another truth store
- recompute domain verdicts
- create another candidate identity
- create another completion token
- create another cleanup verdict
- create another scanner verdict
- create another provider-effect verdict

All five applicable refinements are supplemental mandatory Gate 2 qualification requirements in their mapped existing package responsibilities. P09 final qualification verifies applicability, evidence and disposition for each.

A stronger Symphony-native mechanism may satisfy a refinement; no applicable requirement may be silently omitted.

If satisfying a refinement requires a new authority owner, package, workflow engine, changed candidate identity, completion authority, scanner semantics, credential authority or publication authority, STOP and return to Master Gate.

## V1.1 deferred, non-Gate-2-blocking scope

- read-only evidence dashboard
- evidence-first operator presentation
- candidate/obligation/evidence navigation
- reviewer provenance/independence UI
- current-vs-historical evidence browsing
- human-readable obligation dashboard
- read-only candidate evidence joined view

- Read-only projections over existing authority records.
- May locate or explain records; cannot mint validity, preserve stale authority or become a new prerequisite authority service.
- Not Gate 2 acceptance prerequisites.

## Complementary Herdr and QualityLayer inputs

Herdr contributes runtime/cleanup qualification patterns:

- process replacement
- stable kernel process handles
- event loss/resynchronization
- observer-before-effect
- bounded diagnostic drainage
- resource replacement cleanup races

QualityLayer contributes evidence/review qualification patterns:

- obligation/evidence traceability
- unresolved evidence persistence
- per-claim review scope
- guard-class separation
- historical result/current applicability separation

- Complementary research inputs, not external runtime dependencies.
- Neither external project gains authority or changes P01-P09 topology.

Herdr refinement QualityLayer-pending wording remains historical. This supplied Master Gate decision selects supplemental refinements; canonical plan amendment is not required. Do not rewrite the accepted Herdr artifacts.

## P01 and unchanged governing artifacts

```ini
P01_CHANGE_REQUIRED_BY_QUALITYLAYER=NO
P01_BLOCKED_BY_QUALITYLAYER=NO
P01_AUTHORITY_CHANGED_BY_THIS_TASK=NO
```

Existing separately issued P01 authority is neither revoked nor expanded. No P01
implementation worktree, source, tests or corrections are part of this task. The
canonical plan, immutable freeze, all three scanner artifacts and both accepted
Herdr refinement artifacts remain byte-identical to the verified baseline.

## Narrow documentation authority and execution locks

The CI-only exception permits the existing required GitHub Actions for this exact
QualityLayer research/governance PR. It does not permit local Codex or any
QualityLayer, decryption, scanner, OAuth, provider or H-100 execution. P02-P09
implementation remains unauthorized by this task. These task locks do not revoke
or extend separate programme or P01 decisions. Merge remains human-only and is
not authorized here.

```ini
QUALITYLAYER_RESEARCH_MATERIALIZATION_AUTHORIZED=YES
CREATE_WORKTREE_AUTHORIZED=YES
CREATE_GOVERNANCE_BRANCH_AUTHORIZED=YES
EDIT_QUALITYLAYER_RESEARCH_AND_REFINEMENT_DOCS_AUTHORIZED=YES
LOCAL_DOCUMENT_VALIDATION_AUTHORIZED=YES
COMMIT_QUALITYLAYER_DOCS_AUTHORIZED=YES
PUSH_QUALITYLAYER_BRANCH_AUTHORIZED=YES
OPEN_QUALITYLAYER_PR_AUTHORIZED=YES
QUALITYLAYER_DOCS_PR_REQUIRED_CI_CODEX_EXECUTION_AUTHORIZED=YES
QUALITYLAYER_DOCS_PR_REQUIRED_CI_CODEX_SCOPE=EXISTING_REQUIRED_GITHUB_ACTIONS_FOR_THIS_EXACT_QUALITYLAYER_RESEARCH_GOVERNANCE_PR_ONLY
LOCAL_CODEX_EXECUTION_AUTHORIZED=NO
QUALITYLAYER_EXECUTION_AUTHORIZED=NO
QUALITYLAYER_DECRYPTION_AUTHORIZED=NO
SCANNER_EXECUTION_AUTHORIZED=NO
OAUTH_EXECUTION_AUTHORIZED=NO
PROVIDER_EXECUTION_AUTHORIZED=NO
H100_EXECUTION_AUTHORIZED=NO
AUTH_07_CONSUMED=NO
MERGE_AUTHORIZED=NO
P02_IMPLEMENTATION_AUTHORIZED=NO
P03_IMPLEMENTATION_AUTHORIZED=NO
P04_IMPLEMENTATION_AUTHORIZED=NO
P05_IMPLEMENTATION_AUTHORIZED=NO
P06_IMPLEMENTATION_AUTHORIZED=NO
P07_IMPLEMENTATION_AUTHORIZED=NO
P08_IMPLEMENTATION_AUTHORIZED=NO
P09_IMPLEMENTATION_AUTHORIZED=NO
AUTH_07=SUSPENDED_UNCONSUMED
GATE_2_STATUS=INCOMPLETE
P01_CHANGE_REQUIRED_BY_QUALITYLAYER=NO
P01_BLOCKED_BY_QUALITYLAYER=NO
P01_AUTHORITY_CHANGED_BY_THIS_TASK=NO
```

Stop for independent Master Gate review. No Gate 2 acceptance or legal clearance
is claimed.
