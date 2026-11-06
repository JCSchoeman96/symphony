# Archived QualityLayer evaluation, 2026-11-03

This document is research evidence. Authority and status observations in its report
body are historical to the evaluation date; current programme and package execution
authority must be read from current scoped governance. Implementation and test
behavior hidden behind git-crypt remained UNKNOWN. QualityLayer was not built or
executed and its tests were not run. No decryption was attempted.

The supplied Master Gate adoption decision is recorded separately in
[G2 QualityLayer evidence refinement](../GATE2_QUALITYLAYER_EVIDENCE_REFINEMENT_2026-11-03.md)
and its [derivative projection](../GATE2_QUALITYLAYER_EVIDENCE_REFINEMENT.json).
The [retained reference](QUALITYLAYER_ARCHITECTURAL_REFERENCE_v1.0.0.md) records
research recommendations without governance authority.

The original report body follows byte-for-byte after the marker.

<!-- BEGIN PRESERVED QUALITYLAYER EVALUATION BODY -->
# QualityLayer evaluation for Symphony

Evaluation date: 2026-11-03. Final Symphony main identity/protection reread: 2026-11-03 at approximately 14:21 UTC. This is a read-only architecture and evidence-system evaluation. Recommendations are proposals, not implementation, policy, execution, release, merge or H-100 authority.

The principal recommendation is to use QualityLayer as a reference for acceptance-point evidence and unresolved-work presentation. Keep Symphony's existing authority owners and planned qualification records. Do not adopt QualityLayer's discretionary check model, task-output storage model or implementation.

## A. Exact baselines

```text
SYMPHONY_MAIN_SHA=86336d28671cfd6ac0a55c2ebe48094b8d8a8237
SYMPHONY_MAIN_TREE=4c362c8800c3ebb75408d1af015184f5beb04d5a
SYMPHONY_MAIN_PROTECTED=true

QUALITYLAYER_REPOSITORY=https://github.com/maxritter/qualitylayer
QUALITYLAYER_SHA=16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f
QUALITYLAYER_TREE=e8424e83395324a20fe6ea54dead993b6215ae76
QUALITYLAYER_LICENSE=QualityLayer Software License Agreement, custom proprietary terms
QUALITYLAYER_LICENSE_BLOB=467a5e40c642fc69497d1193b4405ed5eaa4f02d
QUALITYLAYER_LICENSE_SHA256=0de841524089e421084a8cb4b8e5261244d637ed6ae36d4d64b2f3b80736f180
```

GitHub's branch API independently reported Symphony's current SHA/tree, protection and required checks. The checks were `make-all` and `validate-pr-description`, each associated with GitHub App ID 15368. The protection boolean is an observed branch fact, not certification of every protection rule or bypass setting. QualityLayer's commit API reported the pinned commit/tree; its commit timestamp is 2026-11-02T12:32:25Z.

Symphony main has moved beyond the local checkout and the implementation plan's starting baseline, `c5b29a8417ae1d82db6e438716c1425ad6889761`, tree `792c0413b69a5ed4b2f40052c127bfc04f09a5af`. The new main is the merge of PR #61, which persists the scanner policy and canonical Gate 2 plan. Evaluation uses the new main. The local checkout was not updated.

Both archives were downloaded outside the repositories. Every extracted blob was hashed using Git's blob-object encoding and compared with the corresponding pinned recursive GitHub tree entry. All 337 Symphony blobs and all 6,421 QualityLayer blobs matched; neither API tree was truncated. This establishes snapshot provenance despite the exports lacking `.git` directories. It does not establish runtime behavior.

### Authority baseline

The applicable hierarchy is the V4.1 Master Roadmap, accepted Unified Execution Roadmap, accepted governance/evidence, freeze acceptance and scoped projections, immutable inventory packet as amended by the scanner decision, then production source. The Elixir instructions explicitly subordinate upstream `SPEC.md` to this authority. See [S-instructions], [S-master], [S-unified], [S-freeze], [S-addendum] and [S-plan], section B.

Independently counted in the immutable packet:

- 115 inventory rows;
- 26 obligations;
- 14 lifecycles;
- 19 bearer-readability proof entries;
- 13 evidence-transfer claims.

The packet's exact SHA-256 is `a651b1574ec0a186f6b4cd9548787cf9b67009f6692268ce5a8d0669d9d0636a`. Its combined freeze identity remains `1458bb041215c6268f2c69c01ed4198357e9561fbdc17a62e7288d0817b61911`.

**CONFIRMED_FROM_DOCS:** The inventory freeze is accepted; Gate 2 remains incomplete. The complete implementation plan has planning-level approval. Implementation, scanner implementation, local provider/Codex execution and this task's H-100 execution remain unauthorized. The scanner implementation is `UNSELECTED`. The programme's separate H-100 authorization does not override the Gate 2 task lock. [S-freeze], [S-addendum], [S-projection]

The new main proves the governance-document merge occurred. The pinned documents retain their pre-merge G00 status and require successor verification plus explicit applicability rebinding. This evaluation's identity checks do not supply that rebinding, declare G00 complete or grant implementation authority.

The 14 lifecycle contracts are LC-01 RuntimeAttempt, LC-02 Workspace ownership, LC-03 Writable state, LC-04 SIWC enrollment, LC-05 Credential refresh, LC-06 Attempt provider grant, LC-07 Upstream token validity, LC-08 Inference effect, LC-09 Source output, LC-10 Publication effect, LC-11 Plane effect, LC-12 Review/merge/completion, LC-13 Restart/recovery and LC-14 Quarantine/operator resolution. Candidate validation, external-effect reconciliation, local cleanup and upstream credential validity are separate claims with separate owners. A common task status must not collapse them. [S-packet]; [S-plan], section H.

The plan's proof classes include implementation, configuration, characterization, mechanical proof, failure injection, recovery proof, evidence binding, independent review, numerical policy selection and documentation persistence. An acceptance-point view must preserve the required combination, rather than substitute one attachment or one reviewer verdict for all of them. [S-plan], section D.

H-120A's freeze doctrine binds the exact candidate, base/head/tree, required-check context/app/subject policy, reviewer provenance and candidate-specific human decision. Movement invalidates affected proof; old approval must not be edited into validity. The required response is renewed identity/freeze, fresh mechanical evidence and new review/human bindings as applicable. H-120A explicitly rejects a second candidate authority owner or completion token. [S-h120a], sections 3, 5.1 and 6.

### Evidence labels and limits

- `CONFIRMED_FROM_CODE` means readable implementation, configuration or test assertions were inspected. It does not mean tests ran.
- `CONFIRMED_FROM_DOCS` means the pinned documentation says this; executable enforcement remains a separate question.
- `INFERENCE` identifies architectural analysis or a recommendation.
- `UNKNOWN` means the inspected evidence cannot establish the behavior. It does not mean the behavior is absent.

**Material access limit:** All 1,685 files under QualityLayer's `qualitylayer/src/` and all 2,148 files under `qualitylayer/tests/` begin with the git-crypt marker. The pinned `.gitattributes` applies encryption to `qualitylayer/**`, with four metadata/configuration exceptions. Workflow phase instructions, skills, schemas and tests are therefore unavailable as readable implementation. All 27 files under `docs/docusaurus/docs/` are readable. The investigation could inspect the public workflow contract deeply, but could not certify its runtime implementation. [Q-attributes]

Examples include `qualitylayer/src/core/done-means.ts`, `core/task/machine.ts`, `core/task/store.ts`, `core/verification.ts`, `core/required-lines.ts` and `src/server/workflow-review.ts`. Their existence and ciphertext are confirmed; their symbols and behavior are unknown. No older, unpinned revision was substituted, and no decryption or access-control bypass was attempted.

## B. What QualityLayer actually is

**CONFIRMED_FROM_CODE:** The readable package manifest declares a private ESM package, version `12.8.0`, with Bun-driven build/test commands, React dependencies and workflow asset imports. This confirms packaging and declared commands, not their execution. [Q-package]

**CONFIRMED_FROM_DOCS:** QualityLayer coordinates coding agents through an app, browser or terminal workflow. It keeps planning and review documents, records project checks, runs optional independent reviews and leaves plan approval, final approval and merge with the user. Other agents follow a CLI response loop. [Q-native], [Q-other], [Q-files], [Q-review]

**INFERENCE:** It is a development-workflow and evidence-presentation product. The available evidence does not establish a fail-closed authority kernel comparable to Symphony. Its most relevant contribution is making the acceptance contract and its evidence visible together.

No claim that its state machine, evidence signatures, isolation, stale-proof rejection or release enforcement is implemented correctly is justified by this snapshot's readable source.

## C. Workflow/state model

The table describes the pinned public contract. Every behavior in it is `CONFIRMED_FROM_DOCS`; the underlying state implementation is `UNKNOWN`.

| Phase | Documented work and persistence | Documented progression/guard |
|---|---|---|
| Discuss | Records request, scope, decisions and numbered acceptance results in `01-discuss.md`. | Questions resolve choices. Research can begin while answers arrive. Later acceptance changes become visible amendments. |
| Research | `02-research.md` records the existing code, evidence, risks and diagnosis. Helpers are described as reading without the user's request. | No approval needed. Reopening cited files is a workflow instruction, not verified executable enforcement. |
| Plan | `03-plan.md` presents acceptance results and verification methods, decisions, assumptions, prerequisites and artifacts. | Explicit user approval; answers alone are not approval. The app is documented as blocking approval while required plan review runs. |
| Outline | `04-outline.md` maps the approved design to code areas, slices, checks and a proving scenario per acceptance result. | No additional workflow approval before Review. Missing human prerequisites remain unverified while other work continues. |
| Implement | `05-implement.md` records slices, checks and decisions. Test records carry commit and exit code. | The implementation session decides readiness. Unticked cards and open needs can reach Review. |
| Verify | `06-verify.md` presents per-result evidence, checks and unresolved work. | Independent review is configurable. Two review runs are documented; unresolved work then reaches Review. Red checks are not necessarily stops. |
| Review | `07-review.md` holds the change record and approval; its beginning becomes PR description material. | User can approve while open comments and unverified outcomes remain open. Approval does not change their result to passed. |
| Pull request | Reads GitHub checks/reviews, attempts bounded repairs and retains task documents. | Human controls merge. Three unsuccessful check-repair attempts cause a stop. Merge moves the task to Shipped; without `gh`, the task closes at approval. |

Sources: [Q-discuss], [Q-research], [Q-plan], [Q-outline], [Q-implement], [Q-verify], [Q-review], [Q-pr].

The docs describe persistent task state, approval state, slice progress, check records and amendments. Those are more than a bare list of suggested phases. However, the exact state enum, transition guards, persistence transactions, replay safety, failure recovery and override permissions cannot be established. `task override` appears in the command reference without enough detail to determine its reach. [Q-commands], lines 47-58

Existing-plan tasks mark Discuss and Research not run and start at Plan. A sufficiently small request can return a plain prompt and close. Consequently, phase completion, local approval, task closure, PR merge and successful verification are distinct documented events. None should map directly to Symphony's validated Done or dependency satisfaction. [Q-discuss, lines 30-32], [Q-plan, lines 57-59], [Q-pr, lines 18 and 49]

## D. Evidence model

### Requirements and acceptance

**CONFIRMED_FROM_DOCS:** The central acceptance object is a numbered list of observable outcomes agreed during Discuss and approved with Plan. Plan describes how each outcome will be checked. Outline links each outcome to a proving scenario. Verify records a verdict and evidence per outcome. Later changes remain visible as amendments. [Q-discuss, lines 24-28], [Q-plan, lines 19-27], [Q-outline, lines 15-23], [Q-verify, lines 30-55]

This is a useful chain from an agreed requirement to a verification scenario, then evidence and a verdict. The blog explains the rationale and a fresh review session, but does not establish a schema or runtime contract. It should not be mistaken for code evidence. [Q-done-blog]

### Proof, status and unresolved work

The documentation permits command output, captured responses, screenshots and files as proof. It says acceptance points need evidence to pass, unavailable scans remain not checked, failed/skipped/unavailable checks do not count as passed, and unresolved work survives approval. Review puts failures and checking items ahead of points awaiting the user's confirmation. [Q-verify], [Q-health, lines 30 and 53]

These are documented semantics. The persisted status vocabulary, parser, schema validation, proof provenance, reference resolution, anti-forgery rules and requirement coverage algorithm are `UNKNOWN`. An encrypted `done-means.ts` filename does not prove a `ProofObligation` type exists.

The most useful distinction is between approving a delivery decision and recording what evidence actually establishes. Symphony should retain that distinction while imposing its stronger rule that a failed mechanical obligation prevents the relevant transition, regardless of approval.

### Storage

The documented task folder is `docs/plans/<task>/`. Its seven phase documents are committed with the change. It can also contain `original-plan.md`, `artifacts/`, `reviews/`, `records/` and `evidence/`. The docs assign command output and PR-body material to `records/`, pictures/recordings to `evidence/`, and plan review/second opinion to `reviews/`. Exact structured record formats and real task examples were not available in the inspected tree. [Q-files], lines 11-35

Documents have marked sections that QualityLayer is documented as refusing when hand-edited. The seal mechanism, authorized writers and protection against a compromised implementation agent are `UNKNOWN`. A document seal alone would not establish trusted evidence authorship. [Q-files], line 24

### Fit with Symphony's two output domains

**CONFIRMED_FROM_DOCS:** Symphony's planned P08 uses immutable root-owned evidence with a secret-free DETS index. P01's `CleanupEvidenceRef` binds the attempt, fence, resource set, verification generation and verifier implementation. P09's qualification dossier consumes package evidence and records independent applicability/acceptance. Those are plans, not implemented Gate 2 records. [S-plan], P01, P08, P09 and I.5

**INFERENCE:** Keep the two domains separate:

- The **source candidate** contains only source admitted through Symphony's governed source boundary, exact Git-tree staging and scanner validation.
- The **trusted Evidence Plane** contains approved host-produced records and bounded secret-free observations, addressed through their owning stores. It is not a generic runtime output folder.

An attachment in a task folder does not make model text, logs, HOME/XDG state, sessions, SQLite/WAL/SHM files, crash dumps or arbitrary result files promotable. QualityLayer's commit-the-task-record approach is unsuitable as Symphony's durable-output mechanism. Secret scanning or redaction does not repair an unauthorized origin. [S-policy, `provenance`, `authority` and `results`], [S-plan, OB-019, OB-020 and OB-025]

### Candidate record names

- `AttemptEvidenceRecord`: do not add as another attempt authority record. A read-only index could group existing references by `RuntimeAttempt.Identity`; resource/fence/generation truth stays with current owners.
- `ProofObligationRecord`: do not add a parallel obligation registry. The frozen packet already holds the definition; the P09 dossier can hold evidence applicability and dispositions.
- `CandidateEvidenceBundle`: potentially useful as a future read-only manifest of existing candidate verification, scanner, review and completion references. It must not create a second candidate identity, validity verdict or completion token.

All three judgments are `INFERENCE`. No new record is authorized by this report.

## E. Independent review analysis

### What QualityLayer documents

**CONFIRMED_FROM_DOCS:** Independent Verify uses an agent that did not implement the code. The supported-agent documentation says reviewers receive separate context. The settings documentation also permits a same-session helper mode, explicitly marked not independent, and disabling independent review, explicitly reported as lacking an independent judge. [Q-verify, lines 35-45], [Q-native, line 42], [Q-settings, lines 27-40]

An optional second opinion prefers a different model family. With only one family available, a fresh session can review. Finding dispositions are recorded individually as accepted or retained, and security/second-opinion findings can appear as line threads. Additional review can cover one file or the complete change, reads task documents, edits nothing and has a documented eight-minute limit. [Q-verify, line 39], [Q-settings, lines 31-40], [Q-review, lines 51-61]

This supports multiple review activities, but does not establish a quorum, unanimity rule, typed disagreement protocol or cryptographically identified reviewer. The implementing agent records second-opinion dispositions; a human can reject a finding with a reason that becomes a project lesson. That is a discretionary workflow, not independent mechanical authority.

### What remains unknown

- The exact sanitized input given to each review role, including whether implementation transcripts, hidden memory or inherited tool state are excluded.
- The exact reviewed commit/tree and when it is re-resolved.
- A signed binding among the verdict, candidate, policy, reviewer attempt and lineage.
- Automatic invalidation after candidate, requirement, environment or policy changes.
- The schema and persistence guarantees of independent-review evidence.
- Whether a runtime check prevents the implementation session from being mislabeled independent.

The docs also need role clarification: Verify says the independent reviewer adds tests, while the supported-agent page describes reviewers as read-only. These may refer to different review roles or isolated test workspaces. Encrypted implementation prevents resolving the distinction. It is not evidence that either description is false.

Relevant encrypted test files include `qualitylayer/tests/core/review-another.test.ts`, `review-source-identity.test.ts`, `review-integrity.test.ts`, `review-run-publication.test.ts`; `qualitylayer/tests/e2e/reviewer-run-ownership.test.ts`, `review-stale-gate.test.ts`; and `qualitylayer/tests/server/review-final-approval.test.ts`. Workflow/evidence filenames include `qualitylayer/tests/core/required-lines-gate.test.ts`, `done-means-latest.test.ts`, `verify-stale-record.test.ts` and `task-folder-files.test.ts`. These are confirmed file paths only. Their names do not establish tested assertions or passing behavior.

### Symphony's existing stronger binding

**CONFIRMED_FROM_CODE:** `SourceControl.issue_review_provenance/6` binds work item, provider project/workspace, CandidateRef, tree, policy, semantic-attestation fingerprint, review responsibility, RuntimeAttempt fingerprint/profile, lineage and timestamp. It signs the payload with a host HMAC. `review_runtime_identity/3` checks role/attempt/lineage agreement; `validate_review_provenance_binding/6` checks current candidate/policy binding. Recovery rechecks those facts through `verify_review_acceptance_freshness/3`. [S-source], lines 633-790 and 858-943

`RuntimeAttempt` itself is not the review-provenance container. SourceControl issues the separate provenance record; `CompletionProof` retains the bound review fields. `CandidateRef` remains a thin five-field identity, with the tree and policy outside it. `CandidateVerification.verified?/1` is only a status helper, not an independent trust boundary. Its consumers perform the binding checks. [S-runtime], [S-candidate], [S-verification], [S-completion]

Relevant inspected test assertions include `source_control_coverage_test.exs`'s verified-review and builder-denial tests; `source_control_test.exs`'s stale candidate, changed policy and no-longer-green checks tests; and `source_control_merge_verification_test.exs`'s caller-built Done and stale-policy rejection tests. These files were read, not executed. [S-review-tests], [S-source-tests], [S-merge-tests]

`SourceControl.optional_review_attestation/3`, lines 540-560, rejects multiple distinct raw `review_accepted` attestations supplied together on its merge-evidence path. Current acceptance is bound to a selected attestation/provenance, not a reviewer quorum. Multiple advisory reviews can improve coverage, but cannot be aggregated into new majority-vote authority. The review findings from the earlier local baseline were checked against the new main: the only intervening changes are six governance/plan documents, so these implementation files are identical. [S-source]

**CONFIRMED_FROM_CODE:** `GuardClass` defines `mechanical_guard`, `semantic_attestation` and `human_decision`; evidence from another class cannot satisfy the same-named requirement. Its completion guard dispatch requires a valid `CompletionProof`. `CompletionProof` progresses through `merge_authorized`, `merge_verified` and `completed`; it binds candidate verification, review provenance, merge verification and provider closure. The canonical lifecycle separately requires mechanical and semantic review evidence before Ready to Merge, human approval plus a mechanical merge guard before Merging, and the completion path before validated Done. [S-guard], lines 12-25 and 133-145; [S-completion], lines 22-79; [S-lifecycle], lines 190-213.

This is why a reviewer report, a local approval, a provider Done observation and a trusted completed proof are not interchangeable. `guard_class_source_control_test.exs` includes a caller-built completion-evidence rejection assertion, and `source_control_merge_verification_test.exs` includes an assertion that caller-built Done cannot mint completion or satisfy a dependency. Those assertions were inspected, not run. [S-guard-tests]; [S-merge-tests], line 226.

**INFERENCE:** Borrow the per-obligation review presentation and explicit non-independent labeling. Preserve Symphony's fresh Reviewer RuntimeAttempt requirement, host-attested identity, lineage, candidate/tree/policy binding and separate human authority. Model-family diversity is supplementary; it cannot substitute for those requirements. Independent review output may satisfy its semantic obligation only through Symphony's accepted binding path. It cannot mint mechanical facts or human decisions.

## F. Mechanical-authority conflicts

The QualityLayer column below is `CONFIRMED_FROM_DOCS`, not verified executable behavior. The Symphony column refers to code where implemented and accepted policy/plan where Gate 2 work remains future.

| QUALITYLAYER_BEHAVIOUR | SYMPHONY_EQUIVALENT | COMPATIBLE? | WHY |
|---|---|---|---|
| A reviewer rules on a red project check. | Required CI must succeed for the exact candidate and configured check identity. | NO as authority. | Reviewer discretion cannot replace `verify_required_checks`; a failure remains a mechanical block. |
| Required lines may be skipped or unrecorded; missing tools and failed commands do not stop the task. | Required proof, bearer nondisclosure or dependency evidence is incomplete. | NO as satisfaction; YES as visibility. | Recording a reason is useful, but unknown or missing evidence cannot satisfy the guard. |
| Unresolved work reaches Review after two verification runs. | Scanner FAIL/UNCERTAIN, cleanup uncertainty or bearer nondisclosure unknown. | NO if progression grants authority. | Retry limits can bound effort. They cannot release fences, permit publication or create Gate 2 acceptance. |
| Independent review can be off or performed in the lead session, with disclosure. | Mandatory independent Reviewer responsibility and attempt provenance. | NO where required. | Accurate labeling is valuable; a non-independent assessment still fails an independent-review requirement. |
| User can approve with open comments and unverified outcomes. | Human decision plus independent mechanical and semantic guards. | CONDITIONAL. | A decision may be recorded, but all separate required guards must still hold before transition. |
| Findings may be retained with reasons or remembered as lessons. | Scanner failure/uncertainty, source-policy violation or stale evidence. | NO as waiver. | A remembered preference cannot suppress a governed rule or repair identity mismatch. |
| Task documents, command output and pictures are committed with the change. | Only admitted, validated source is durable candidate output; trusted evidence is separately governed. | NO as an output policy. | Generic attachments cannot bypass provenance, secret-safety and publication controls. |
| Task closes at approval without `gh`; otherwise merge moves it to Shipped. | Validated Done and dependency satisfaction require controlled completion proof and fresh provider reconciliation. | NO as equivalence. | Local task closure or a merge observation alone cannot establish `CompletionProof.completed`. |
| Security/code-health scans are advisory, scoped to task changes and configurable. | Frozen deterministic candidate scanner policy. | NO as replacement. | Symphony requires the complete exact staged tree, approved rules/limits and FAIL/UNCERTAIN denial. |
| Review or tests are associated with committed work. | CandidateRef/base/head/tree/policy movement. | UNKNOWN enforcement in QualityLayer; retain Symphony's rejection. | Commit-associated evidence is insufficient without fresh identity reconciliation and invalidation. |

QualityLayer sources: [Q-verify], [Q-required], [Q-settings], [Q-review], [Q-files], [Q-pr], [Q-health]. Symphony sources: [S-source], [S-guard], [S-completion], [S-policy], [S-h120a], [S-plan].

Symphony must explicitly reject any adoption that lets QualityLayer or a model decide whether a mechanical guard is waived, dependencies are satisfied, the candidate is unchanged, CI remains valid, cleanup is complete, Gate 2 passed, merge is authorized or CompletionProof is valid.

This does not imply QualityLayer bypasses GitHub branch protection. Its docs separately say PR check repair must not weaken or skip a check. The conflict is between its local review discretion and Symphony's authority semantics, not a demonstrated ability to override GitHub. [Q-pr], lines 22-30

### Freshness and invalidation

| Change | What the pinned QualityLayer docs establish | What Symphony requires |
|---|---|---|
| Candidate changes after verification | Tests carry commit/exit code; Verify starts on committed work; fixes are committed before a second review. Universal stale-proof rejection is UNKNOWN. | Fresh CandidateRef/tree/check binding; movement invalidates affected evidence and review. |
| Tests must rerun | Affected work is rechecked after feedback. General rerun-selection and complete stale-check detection are UNKNOWN. | Required checks must be freshly established for the exact allowed lookup SHA and policy. |
| Review becomes stale | Code-health findings need renewed review when the function, analyzer config, duplicate or metric changes. General independent-review invalidation is UNKNOWN. | Signed review provenance must match current candidate/tree/policy and approved attempt lineage. |
| Acceptance requirement changes | Amendments remain visible. Whether prior proof automatically becomes invalid is UNKNOWN. | Future evidence assessment must identify the exact obligation/acceptance definition; no silent proof transfer across changed requirements. |
| Policy changes | Required instructions are snapshotted per task; edits affect later tasks. Analyzer-config changes can require a finding review. General policy-digest invalidation is UNKNOWN. | Source-control fingerprint drift invalidates review; scanner semantic changes need a governed new version; implementation replacement needs fresh qualification. |

Sources: [Q-implement], lines 43-51, [Q-verify], lines 43-55, [Q-discuss], line 26, [Q-required], line 40, [Q-health], line 47, [S-source], lines 858-943, [S-h120a], section 5.1, [S-policy].

Do not state that QualityLayer has no freshness mechanism. The public docs establish limited finding-level freshness and commit-associated records. The encrypted modules/tests prevent judging its wider machinery.

## G. Licensing/provenance assessment

**CONFIRMED_FROM_DOCS:** The pinned licence covers code, documentation, skills, commands, configuration and UI. Sections 2 and 3 condition inspection/use and internal modification on subscription/trial terms. Redistribution is prohibited. Derivative works are restricted; the definition includes substantial architecture/structure reuse. Competitive and hosted substitution are prohibited. Enterprise internal source rights do not grant external redistribution. Generated output rights exclude the Software itself. [Q-license], sections 1-5

No subscription, permission or separate agreement was established in this investigation. Public GitHub access is not evidence of a reuse grant. This is a conservative engineering/provenance assessment, not a legal opinion or a finding that any particular contractual term is enforceable.

| Material or activity | Engineering/provenance classification | Consequence |
|---|---|---|
| Discussing generic ideas, such as observable acceptance criteria and showing missing evidence | SAFE_TO_REFERENCE_CONCEPT | Comparative reference only; the label is not legal clearance to implement QualityLayer's design. |
| Independently solving a Symphony requirement with Symphony-native definitions and no copied expression or structure | REQUIRES_CLEAN_ROOM_REIMPLEMENTATION | Maintain independent requirements and provenance. Clean-room process does not automatically resolve competitive-use or broad derivative restrictions. |
| Reproducing QualityLayer's substantial workflow architecture, exact evidence schemas or record structure | REQUIRES_EXPLICIT_PERMISSION | Do not implement based on this report alone, even with newly written code. |
| Copying code, prompts, skills, templates, documentation or UI into distributed Symphony | DO_NOT_USE under established rights | No applicable redistribution permission was demonstrated. Seek an explicit suitable grant before reconsidering. |
| Using/modifying QualityLayer privately | REQUIRES_EXPLICIT_PERMISSION or verified applicable entitlement | Internal-use rights differ from distributed-product rights; this task establishes neither entitlement nor compatibility of a proposed adaptation. |
| Treating generated-output ownership as permission to copy QualityLayer material | DO_NOT_USE | Output rights do not turn the Software itself into unrestricted output. |
| Decrypting inaccessible implementation or bypassing licence controls | DO_NOT_USE | No such authority was supplied; no attempt was made. |

The public docs can support a comparative report. They cannot establish that Symphony may distribute a derivative product. This report is not a clean-room implementation specification, because its investigators have read QualityLayer documentation. Any future Symphony design should start from Symphony's own frozen obligations and accepted record contracts; a proposal substantially tracking QualityLayer needs separate licensing review or permission.

## H. Gate 2 applicability

The starting point is already machine-readable. Each frozen obligation includes its ID, inventory links, acceptance owner, precondition, pass condition, required proof, failure disposition, status and authorization constraints. The canonical plan maps every obligation to packages and proof classes. P09 already calls for a qualification manifest, obligation acceptance dossier, `QualificationIdentity` and `EvidenceApplicability`. [S-packet, `obligations`], [S-plan, D, P09 and I.5]

**INFERENCE:** The missing connection is an executable assessment of the right evidence for those definitions, not another Markdown checklist or another generic evidence store. A dossier can establish completeness by resolving expected obligation IDs, required proof classes and current owner-issued references. It should reject missing/duplicate IDs, wrong subject or policy, stale generations, incomplete observation coverage and unaccepted transfer claims. Counting 26 attached files or obtaining an overall model verdict would prove neither coverage nor validity.

| Obligation | Useful reference pattern | Symphony-specific evidence requirement | Timing |
|---|---|---|---|
| OB-006 Bearer non-disclosure | Show evidence and unresolved status per acceptance point. | Preserve BP-01 through BP-19 coverage, positive detector controls and negative unauthorized-channel controls. Bind holder, attempt, credential/resource generation and secrecy-safe observations. Unknown remains quarantine/block-reuse. | Gate 2 now as an interpretation of existing P04/P08/P09 work; richer navigation in V1.1. |
| OB-015 Candidate validation | Link outcome to the exact proving scenario and record. | Resolve existing SourceManifest/stage/ValidationEvidence identity; preserve the accepted scanner sequence and post-scan reconfirmation. A screenshot cannot replace the host verdict. | Gate 2 now through existing P06/P09; presentation in V1.1. |
| OB-019 Durable output restriction | Keep evidence organized and explain exclusions. | Prove only the validated source candidate is promotable; prohibit generic/private-state export. Keep evidence attachments out of source promotion. | Gate 2 now for existing boundary; QualityLayer-style committed task folders are not appropriate. |
| OB-020 Diagnostic evidence safety | Expose missing evidence rather than marking it passed. | P08's bounded secret-free evidence must retain exact attempt/resource attribution. Raw diagnostic retention is not proof; possible disclosure keeps quarantine. | Gate 2 now through existing P08; improved inspection later. |
| OB-023 Evidence-transfer review | Give each claim its own reviewer disposition and evidence references. | Review ET-001 through ET-013 individually against exact version/topology and limitations. Historic, synthetic or diagnostic evidence must not silently become integrated acceptance proof. | Gate 2 now through already planned P09. |
| OB-025 Secret-safe evidence | Keep verification status separate from approval. | Use synthetic-secret controls for diagnostics/config/crash/operator evidence, with positive detection controls and precise safe metadata. No raw secret-bearing attachment collection. | Gate 2 now through existing P08/P09; presentation in V1.1. |

Exact acceptance contracts are in [S-plan] at lines 457, 574, 626, 639, 678 and 704, respectively. These are required proofs, not observed passing results.

### Scanner-policy relevance

The selected policy already specifies `G2-SCAN-EVIDENCE-1.0.0`, rule results, uncertainty reasons, policy and implementation identities, exact candidate/stage/tree bindings and completion metadata. Its digest was independently recomputed as `0d67fe1c0c532294dd3e946618d5bfd40c3d5ce6f50804e4bd20823ae5f756b7`. [S-policy]

QualityLayer contributes a possible presentation pattern: show incomplete rules first, attach bounded safe proof, distinguish unavailable from passed and let an independent reviewer inspect coverage. It does not supply a reason to replace Symphony's policy, choose a scanner, add online rule feeds, permit model-selected suppressions, accept opaque content or change PASS/FAIL/UNCERTAIN. The policy permits neither reviewer override nor rewriting evidence to PASS. Its currently unselected implementation and unaccepted finite resource values remain future governed work, not defects this report may fix.

## I. Candidate concepts

All proposed benefits and adoption judgments below are `INFERENCE`, grounded in the documented sources. `GATE2_NOW` means useful within an already approved plan's existing obligations after separate execution authority; it does not authorize work now. All concepts remain reference-only in this evaluation.

### 1. Acceptance-point evidence traceability

- CONCEPT: Link each frozen obligation to its proving scenario, current evidence and explicit disposition.
- QUALITYLAYER_SOURCE: [Q-discuss], [Q-outline], [Q-verify].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: P09 obligation dossier and `EvidenceApplicability`.
- GAP_IN_SYMPHONY: No implemented Gate 2 end-to-end resolver was established; definition and planned dossier already exist.
- BENEFIT: Makes missing or misbound proof inspectable at the claim level.
- AUTHORITY_IMPACT: None if existing evidence owners resolve truth and the view grants no transition authority.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT for the generic relationship. Future implementation must have independent Symphony provenance; do not copy schemas or templates.
- TIMING: GATE2_NOW for existing dossier intent; V1.1 for richer projections.

### 2. Unresolved evidence survives approval

- CONCEPT: Preserve failed, unavailable, incomplete and human-pending outcomes after a review decision.
- QUALITYLAYER_SOURCE: [Q-verify], [Q-review], [Q-required].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: P08/P09 dossiers and future Evidence Plane views.
- GAP_IN_SYMPHONY: Consolidated operator presentation; fail-closed semantics already exist or are planned.
- BENEFIT: Prevents a favorable summary from hiding incomplete evidence.
- AUTHORITY_IMPACT: Mechanical incompleteness must still block its relevant action.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT. Any future projection requires independent implementation; exact layouts/status schema are not proposed for reuse.
- TIMING: GATE2_NOW for accurate dispositions; V1.1 for display.

### 3. Review verdict per obligation

- CONCEPT: Require the reviewer to identify what was checked, its evidence and what could not be verified for each assigned claim.
- QUALITYLAYER_SOURCE: [Q-verify], [Q-review].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: Reviewer evidence presentation and P09 independent acceptance dispositions.
- GAP_IN_SYMPHONY: Human-readable coverage associated with already stronger provenance.
- BENEFIT: Makes a signed review's substantive scope easier to audit.
- AUTHORITY_IMPACT: Preserve fresh RuntimeAttempt, signed binding, guard-class separation and exact-candidate invalidation. Review text grants no mechanical authority.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT; future work requires independent requirements and code. No prompt reuse.
- TIMING: GATE2_NOW for P09 review scope; V1.1 for general task-level use.

### 4. Explicit independence and review-role disclosure

- CONCEPT: Show who implemented, who reviewed, whether review was independent and which review roles ran.
- QUALITYLAYER_SOURCE: [Q-settings], [Q-native], [Q-verify].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: Existing provenance projections, not a new identity owner.
- GAP_IN_SYMPHONY: Presentation of RuntimeAttempt/role/lineage facts.
- BENEFIT: Prevents self-review from appearing equivalent to independent review.
- AUTHORITY_IMPACT: A disclosed non-independent review still cannot fulfill a mandatory independent-review obligation. Different model family is supplementary only.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT. Recreating reviewer selection or orchestration structure would need separate analysis and potentially explicit permission.
- TIMING: V1.1.

### 5. Candidate evidence manifest

- CONCEPT: A read-only manifest groups existing evidence references for one candidate and exposes current validity separately from historic results.
- QUALITYLAYER_SOURCE: [Q-files], [Q-implement], [Q-verify].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: CandidateVerification, CandidateValidationBinding direction, review provenance and P09 manifests.
- GAP_IN_SYMPHONY: A joined audit view, not missing candidate identity semantics.
- BENEFIT: Easier inspection of candidate, scanner, CI and review agreement.
- AUTHORITY_IMPACT: It must resolve owners' records and never become a parallel CandidateRef, proof issuer or CompletionProof replacement.
- LICENSING_IMPACT: REQUIRES_CLEAN_ROOM_REIMPLEMENTATION for any future product mechanism. QualityLayer's precise record structure is unknown and must not be reconstructed or copied. Substantial architectural imitation requires explicit permission review.
- TIMING: LATER, after actual record contracts justify it.

### 6. Evidence-first review ordering

- CONCEPT: Put failing, uncertain, missing and stale items before satisfied claims; make safe supporting evidence reachable from the claim.
- QUALITYLAYER_SOURCE: [Q-verify], lines 49-55, [Q-review].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: Future read-only Evidence Plane presentation.
- GAP_IN_SYMPHONY: Review ergonomics across typed records.
- BENEFIT: Directs reviewer attention to unresolved delivery risk.
- AUTHORITY_IMPACT: Display order cannot alter scanner or guard results; preserve proof-class differences.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT. Use Symphony's own interface and labels; no layout/template reuse.
- TIMING: V1.1.

### 7. Separate mechanical and semantic review lanes

- CONCEPT: Present scanner/check records and semantic/security assessments together while identifying their different authors and powers.
- QUALITYLAYER_SOURCE: [Q-verify], [Q-health].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: Existing `GuardClass`, P07/P09 review dossier.
- GAP_IN_SYMPHONY: Visibility, not a new guard model.
- BENEFIT: Readers can see why one passing assessment cannot satisfy another class.
- AUTHORITY_IMPACT: Reject QualityLayer's advisory treatment for Symphony's mandatory scanner/CI results. No reviewer discretion over those results.
- LICENSING_IMPACT: SAFE_TO_REFERENCE_CONCEPT; implement any future view from Symphony's existing classes.
- TIMING: GATE2_NOW for dossier clarity; V1.1 for UI.

### 8. Task-level evidence navigation

- CONCEPT: Organize authorized evidence by attempt, obligation and candidate so readers can navigate it without copying raw output into source.
- QUALITYLAYER_SOURCE: [Q-files].
- CLASSIFICATION: REFERENCE.
- SYMPHONY_TARGET: Trusted Evidence Plane and existing owner-issued references.
- GAP_IN_SYMPHONY: Cross-record navigation.
- BENEFIT: Makes relationships inspectable without broadening the admitted output class.
- AUTHORITY_IMPACT: A read-only index may locate records but cannot establish their validity or alter retention authority.
- LICENSING_IMPACT: REQUIRES_CLEAN_ROOM_REIMPLEMENTATION for a future mechanism; QualityLayer's directory/schema design is not proposed for copying.
- TIMING: LATER.

### Rejected and irrelevant directions

| Direction | Recommendation | Licensing/provenance classification | Reason |
|---|---|---|---|
| Reviewer waiver of required CI, scanner or cleanup failure | REJECT | DO_NOT_USE | Incompatible with fail-closed mechanical law, independently of licence. |
| Raw command output/screenshots/task folders automatically committed as evidence | REJECT | DO_NOT_USE | Incompatible output and secret-safety assumptions. |
| Turning independent review off while still satisfying a required Reviewer obligation | REJECT | DO_NOT_USE | Disclosure does not satisfy the missing independent proof. |
| Copying QualityLayer schemas, skills, prompts, code or templates | REJECT under established rights | REQUIRES_EXPLICIT_PERMISSION; DO_NOT_USE until granted | No suitable distribution/derivative grant established. |
| Adopting its complete workflow/state architecture | REJECT for this scope | REQUIRES_EXPLICIT_PERMISSION | Unnecessary second workflow owner; broad derivative/competitive restrictions. |
| Model-family diversity as a substitute for attempt provenance | REJECT | DO_NOT_USE as authority evidence | Diversity does not prove isolation, candidate binding or reviewer responsibility. |
| Product mockups, cost estimates, personal/project memory and workflow branding | NOT_RELEVANT | DO_NOT_USE in this evaluation's adoption scope | They do not resolve Gate 2 proof obligations. |
| Memory expiration as proof freshness | REJECT | DO_NOT_USE | Evidence validity is identity/policy/generation dependent, not a memory-retention interval. |

## J. ProofObligation recommendation

```text
PROOF_OBLIGATION_RECOMMENDATION=DO_NOT_ADD
```

This means do not introduce a new first-class generic evidence/authority abstraction on the evidence available. It does not mean abandon obligation-level proof.

Symphony already has the static obligation register, proof classes, package ownership and P09's dynamic applicability/acceptance direction. A new `ProofObligation` that repeats those definitions, embeds copies of candidate/cleanup/CI evidence and computes another verdict would create duplicate policy and another authority owner. QualityLayer's readable docs demonstrate the value of the relationship, not a superior typed schema or resolver.

The suggested field list mixes an obligation definition with a verification instance. If a future P09 refinement needs an assessment shape, distinguish:

- The immutable obligation definition: frozen ID, definition/version digest, scope, acceptance owner, required proof classes, pass/failure conditions and applicability.
- One assessment: subject identity, relevant policy/implementation/configuration identities, owner-resolved evidence references, verifier provenance, current result, unresolved reasons and invalidation dependencies.

That is a design test for the existing dossier, not an authorized new schema. CandidateRef/tree binding applies to candidate claims. Cleanup instead needs attempt/grant/fence/resource-set/recovery generation; bearer claims need holder/credential/channel scope; transfer claims need exact implementation/topology applicability. A universal candidate field cannot correctly express every obligation. A lone verifier name, timestamp or copied verdict cannot substitute for provenance and current owner verification.

Preserve domain outcomes. Scanner UNCERTAIN is not the same thing as pending human semantic review; historical PASS is not current satisfaction; local cleanliness is not provider-token invalidity or resolved external effects. Timestamps explain when a record was made but do not establish exact-candidate freshness.

**Would ProofObligation simplify Symphony?** Not as another first-class record today. A narrow derived obligation-assessment view inside the planned P09 dossier could simplify audit and completeness checks. Reconsider a new type only after concrete duplication across implemented producers is demonstrated and a proposal removes existing semantics rather than copying them. Any such refinement belongs after separate authorization, with V1.1 as the earliest generalization target.

## K. Overall strategy

```text
QUALITYLAYER_STRATEGY=REFERENCE_ONLY
```

Use the pinned public documentation to compare observable acceptance criteria, per-claim evidence, independence disclosure and unresolved-work presentation. Base any future Symphony design on Symphony's own frozen obligations and existing typed records. Do not copy source or expressive material, install QualityLayer, reproduce its architecture, or treat this evaluation as clean-room or legal clearance.

The unavailable implementation prevents a source-grounded endorsement of QualityLayer's actual guards, storage integrity, review isolation or stale-proof machinery. That is an evaluation limit, not proof those mechanisms do not exist. Deeper implementation assurance would require authorized readable source for the same pinned revision and appropriate licensing rights.

## L. Gate 2 plan consequence

```text
GATE2_PLAN=UNCHANGED
```

No QualityLayer-dependent amendment is needed. The accepted plan already includes obligation-level acceptance, exact identity, independent applicability review, scanner evidence and cleanup evidence with trusted ownership. The useful ideas fit its existing intent. Presentation improvements and any general cross-record evidence view can be considered in V1.1 or later, under a separate decision.

This evaluation does not pass Gate 2, choose or execute a scanner, authorize P01/P06 or provider/model operations, consume AUTH-07, authorize H-100, rebind plan applicability, authorize merge/release or copy QualityLayer implementation. No Symphony or QualityLayer source was modified; no branch, commit, push, PR or tracker mutation was made. Tests and product workflows were not executed. Existing local untracked work was left in place.

## Pinned source register

All QualityLayer references below are at `16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f`. All Symphony references are at `86336d28671cfd6ac0a55c2ebe48094b8d8a8237`.

[Q-attributes]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/.gitattributes
[Q-package]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/qualitylayer/package.json
[Q-license]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/LICENSE
[Q-discuss]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/discuss.md
[Q-research]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/research.md
[Q-plan]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/plan.md
[Q-outline]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/outline.md
[Q-implement]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/implement.md
[Q-verify]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/verify.md
[Q-review]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/review.md
[Q-pr]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/steps/pull-request.md
[Q-required]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/required-lines.md
[Q-settings]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/reference/settings.md
[Q-files]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/reference/files.md
[Q-health]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/reference/code-health.md
[Q-commands]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/reference/commands.md
[Q-native]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/agents/native.md
[Q-other]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/docs/agents/other.md
[Q-done-blog]: https://github.com/maxritter/qualitylayer/blob/16ec3e148a0a4aeb28bbbe053ae3b690ea9e9c4f/docs/docusaurus/blog/2026-10-26-done-means.md
[S-instructions]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/AGENTS.md
[S-master]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
[S-unified]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md
[S-freeze]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/GATE2_INVENTORY_FREEZE_ACCEPTANCE_2026-11-02.md
[S-packet]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/GATE2_INVENTORY_FREEZE_PACKET_1458bb041215c626.json
[S-addendum]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/GATE2_SCANNER_GOVERNANCE_ADDENDUM_2026-11-03.md
[S-projection]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/GATE2_SCANNER_GOVERNANCE_PROJECTION.json
[S-policy]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/GATE2_V1_CANDIDATE_VALIDATION_1.0.0.json
[S-plan]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/superpowers/plans/2026-11-03-gate2-v1-implementation-plan.md
[S-h120a]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/docs/symphony-hardening-playbook-v4.1/H-120A_GOVERNANCE_PRE_GATE.md
[S-runtime]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/agent_runtime/runtime_attempt.ex
[S-candidate]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/source_control/candidate_ref.ex
[S-verification]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/source_control/candidate_verification.ex
[S-source]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/source_control.ex
[S-completion]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/work_control/completion_proof.ex
[S-guard]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/work_control/guard_class.ex
[S-lifecycle]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/lib/symphony_elixir/work_control/workflow_lifecycle.ex
[S-guard-tests]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/test/symphony_elixir/guard_class_source_control_test.exs
[S-review-tests]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/test/symphony_elixir/source_control_coverage_test.exs
[S-source-tests]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/test/symphony_elixir/source_control_test.exs
[S-merge-tests]: https://github.com/JCSchoeman96/symphony/blob/86336d28671cfd6ac0a55c2ebe48094b8d8a8237/elixir/test/symphony_elixir/source_control_merge_verification_test.exs
