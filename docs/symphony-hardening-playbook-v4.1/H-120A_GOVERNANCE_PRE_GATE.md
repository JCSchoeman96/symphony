# H-120A Governance Pre-Gate

**Status:** Authorized and active, not accepted.

**Outcome:** `DOCUMENTATION_AND_GOVERNANCE_ONLY`.

This artifact records the governance gate, exact candidate freeze, required-check policy, evidence provenance, disposable proof design, and human-merge procedure required before any separately authorized live proof. It describes existing enforcement and does not grant authority beyond the Master Roadmap or a separate human Master decision.

## 1. Exact accepted entry baseline

```ini
BASE_SHA=c2b142c7ef89fb7dd2bb46c5d76732247a653f62
BASE_TREE=9db4056e3d0465128bc2c31f770bd115d636403c

PR_NUMBER=49
PR_HEAD_SHA=a43c63031ec94f81399dd22983f26b43144c0a5a
PR_MERGE_SHA=c2b142c7ef89fb7dd2bb46c5d76732247a653f62

POST_MERGE_RUN=39128370243
POST_MERGE_ATTEMPT=1
POST_MERGE_EVENT=push
POST_MERGE_RESULT=SUCCESS

H090=ACCEPTED
H120A=AUTHORIZED_ACTIVE_NOT_ACCEPTED
H100=NOT_AUTHORIZED
H110=NOT_AUTHORIZED
H120B=NOT_AUTHORIZED

NEXT_GOVERNANCE_STEP=H-100
NEXT_AUTHORIZED_PHASE=NONE

DECISION_REFERENCE=MG-2026-10-18-H090-ACCEPT-H120A-AUTH-01
DECISION_TIMESTAMP=2026-10-18T12:16:30+02:00
```

The protected `main` baseline was independently re-read immediately before plan freeze and still resolved to the exact SHA/tree above. The merge commit is signed and GitHub reports `verification.verified=true`, `reason=valid`. It has exactly the H-090 accepted baseline and PR #49 head as parents:

```text
parent 1: d8ebad76e34ef13a98bd11e70f4bd657392ff33d
parent 2: a43c63031ec94f81399dd22983f26b43144c0a5a
```

Protected `main` requires exactly:

```text
make-all                  app_id=15368
validate-pr-description   app_id=15368
```

The historical governance projection field `accepted_protected_main_at_decision` remains deliberately pinned to the H-090 decision baseline:

```text
sha:  d8ebad76e34ef13a98bd11e70f4bd657392ff33d
tree: 3c54c625571ac259fa7ecf42d65b22b8e290cf66
```

H-120A implementation MUST NOT rewrite that historical decision provenance to the current `main`.

---

## 2. Authority hierarchy and immutable interpretation

Read and preserve this order:

1. `docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md`
2. `docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md`
3. `docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md`
4. `docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json`
5. `docs/symphony-hardening-playbook-v4.1/POST-H090_PRE-H120A_GOVERNANCE_MATERIALIZATION.md`
6. Current production source and tests
7. Phase evidence and implementation/review documentation

The Master Roadmap is governing authority. The projection, checker, ledger, Unified Roadmap, implementation plan, phase evidence document, reviewer report, CI output, PR description, and agent prose are all derivative evidence or controls. None may create authority stronger than the Master Roadmap or the external human Master decision.

Current Master Roadmap blob at the accepted tree:

```text
4b0528bdc0647d889b42ebc478081d5b873898fe
```

H-120A is the sole active authorization. This H-120A governance artifact does not authorize H-100, H-110, or H-120B.

### H-120A authoritative objective

```text
Task:
Establish the pre-live-proof governance gate,
exact candidate freeze,
and human-merge proof procedure.

Objective:
Make H-100/H-110 evidence provenance-safe
and ensure Done closure can be proven
without granting auto-merge.
```

H-120A is documentation/governance-only unless a separate, independently demonstrated runtime defect makes the later proof unsafe or ambiguous. No such defect was found during this planning review.

---

## 3. Why the outcome is documentation/governance-only

The current implementation already has the runtime seams H-120A needs:

- `CandidateRef` is a deliberately thin five-field V1 identity object.
- Candidate tree and source-control policy are bound separately in typed mechanical evidence rather than bloating `CandidateRef`.
- `SourceControl` re-resolves repository, PR, base, HEAD, tree, checks, and merge state from GitHub.
- Required checks are matched by exact context, GitHub App ID, and exact lookup SHA.
- Synthetic-merge evidence has explicit parent/tree validation.
- Candidate movement fails closed.
- Independent review provenance is signed and candidate/tree/policy/runtime-attempt/lineage bound.
- `CompletionProof` already has the accepted lifecycle `merge_authorized -> merge_verified -> completed`.
- A fresh provider `Done` observation cannot close completion before merge verification.
- `WorkflowLifecycle` already requires a separate `HumanDecision(:merge_approved)` plus mechanical merge guard for `Ready to Merge -> Merging`.
- Every canonical transition records `autonomous_merge=false`.
- The SourceControl capability boundary used by agents is read-only; it does not expose a merge operation.
- Governance checking is read-only and cannot create programme authority.

Therefore H-120A must formalize the exact operating procedure and evidence contract. It must not create a new persistent Candidate resource, a second authority owner, an auto-merge seam, or a new completion token.

### Explicit non-change decisions

Do **not** modify:

- `CandidateRef`;
- `CompletionProof`;
- `MergeVerification`;
- `SourceControl` production code;
- `WorkflowLifecycle`;
- `GuardClass`;
- `Orchestrator`;
- Plane runtime code;
- governance projection;
- hardening status ledger;
- Master Roadmap;
- Unified Roadmap;
- H-100/H-110/H-120B authorization state.

A future implementation agent that believes one of those files must change must STOP and return the newly demonstrated defect for separate planning/authorization.

---

# 4. Domain/resource map

## 4.1 CandidateRef

**Truth owner:** GitHub SCM facts interpreted through Symphony `SourceControl`.

**State owner:** Symphony's typed source-control evidence; the thin value itself has no independent lifecycle authority.

**Identity:**

```text
repository_identity
base_sha
candidate_sha
pr_identity
observed_pr_head_sha
```

**Inputs:** configured repository/base branch, local candidate SHA supplied to capture, GitHub repository identity, current base ref, associated PR, fresh PR head.

**Outputs:** typed `CandidateRef`, equality result, stable fingerprint.

**Guards:** valid repository identity; full SHAs; numeric PR identity; `candidate_sha == observed_pr_head_sha`; later source-control reconciliation must still match the stored ref.

**Side effects:** none.

**Durability:** may be retained as bounded mechanical candidate evidence/recovery data. It is not Programme B Candidate persistence.

**Authority granted:** identifies the exact V1 source-control candidate that later mechanical evidence refers to.

**Authority explicitly NOT granted:** no review approval, no CI approval by itself, no human merge decision, no merge authority, no completion authority, no phase authorization.

## 4.2 Candidate tree + source-control policy snapshot

**Truth owner:** GitHub commit object for tree identity; Symphony configuration/policy for required-check rules.

**State owner:** candidate mechanical evidence and review/completion provenance.

**Identity:** `candidate_tree_sha` plus canonical policy fingerprint.

**Inputs:** exact CandidateRef, fetched commit tree, repository/project/base-branch configuration, canonical required checks.

**Outputs:** tree SHA, policy fingerprint, candidate verification.

**Guards:** CandidateRef still current; fetched tree must match the candidate commit; policy must canonicalize to the same fingerprint.

**Side effects:** none.

**Durability:** bounded mechanical evidence may persist; movement/policy mismatch makes it stale.

**Authority granted:** mechanical identity/binding only.

**Authority explicitly NOT granted:** cannot replace semantic review or HumanDecision.

## 4.3 SourceControl boundary

**Truth owner:** GitHub for repository/PR/commit/check/merge observations; Symphony for interpretation policy.

**State owner:** no independent authority state; results are typed mechanical evidence consumed by lifecycle/governance layers.

**Identity:** repository identity + CandidateRef + candidate tree + policy fingerprint.

**Inputs:** GitHub API rereads, current source-control config, prior bounded candidate/review evidence.

**Outputs:** CandidateRef, CandidateVerification, check verification, MergeVerification, CompletionProof stage advancement.

**Guards:** exact repo identity, base/head/tree, PR identity, ancestry, check context/app/subject/SHA, review provenance, merge structure.

**Side effects:** read-only verification. No agent merge mutation.

**Durability:** selected typed mechanical evidence is retained by Symphony's existing recovery machinery.

**Authority granted:** mechanical guard evidence.

**Authority explicitly NOT granted:** no semantic reviewer authority, no human merge decision, no Master authority.

## 4.4 CI/check evidence

**Truth owner:** GitHub Checks + GitHub Actions.

**State owner:** GitHub; Symphony retains candidate-bound normalized evidence/fingerprints as required.

**Identity:** check context + app ID + configured subject + exact lookup SHA; audit manifest additionally records workflow run ID, run attempt, workflow path, event, jobs and timestamps.

**Inputs:** frozen candidate, frozen required-check policy, GitHub check/action rereads.

**Outputs:** pass/pending/failure/ambiguous mechanical result.

**Guards:** exact app ID; exact context; exact subject SHA; only success qualifies; pending/non-success/ambiguous fails closed.

**Side effects:** none from verification.

**Durability:** retain identifiers and normalized proof through H-120B and programme acceptance; GitHub remains system of record for raw run data.

**Authority granted:** mechanical CI condition only.

**Authority explicitly NOT granted:** no review acceptance, no Master decision, no merge power, no completion.

## 4.5 Independent review authorization / provenance

**Truth owner:** independent Reviewer semantic assessment plus host-created signed/mechanical review binding.

**State owner:** Symphony review provenance/evidence.

**Identity:** exact work item/project/workspace, CandidateRef, candidate tree, policy fingerprint, reviewer responsibility, reviewer RuntimeAttempt fingerprint/profile/lineage/timestamp, semantic-attestation fingerprint.

**Inputs:** exact frozen candidate, passing mechanical evidence, Reviewer semantic result.

**Outputs:** semantic `review_accepted` plus mechanical `review_acceptance_verified` provenance.

**Guards:** reviewer independence; exact candidate/tree/policy; current runtime-attempt/lineage binding; valid provenance signature.

**Side effects:** enables canonical `In Review -> Ready to Merge` only when all required classes are satisfied.

**Durability:** bounded mechanical review provenance may persist; raw semantic authority is not interchangeable with recovered mechanical evidence.

**Authority granted:** exact-candidate review acceptance only.

**Authority explicitly NOT granted:** Reviewer cannot grant itself Master authority and cannot merge.

## 4.6 Master Final Gate / HumanDecision

**Truth owner:** human Master Governance authority external to agent automation.

**State owner:** human governance decision record.

**Identity:** decision reference/timestamp + exact candidate fingerprint/tree/policy/check snapshot being approved.

**Inputs:** fresh independent re-resolution of candidate, review provenance, current required checks, current authorization state.

**Outputs:** candidate-specific `HumanDecision(:merge_approved)` / human merge instruction.

**Guards:** H-100 must separately be authorized before the live proof; exact candidate must still match; reviewer cannot be the authority source for the Master decision; movement invalidates the decision.

**Side effects:** permits a human to perform one controlled merge attempt and permits canonical `Ready to Merge -> Merging` only alongside the mechanical merge guard.

**Durability:** retain decision identity through H-120B/acceptance.

**Authority granted:** candidate-specific human merge action.

**Authority explicitly NOT granted:** does not prove merge truth, completion, H-100 acceptance, H-110 authorization, or H-120B authorization.

## 4.7 Human merge action

**Truth owner:** human actor for the decision to act; GitHub for resulting SCM state.

**State owner:** GitHub PR/default-branch state after the action.

**Identity:** exact PR/CandidateRef + candidate-specific Master decision + intended merge strategy.

**Inputs:** current Master approval and fresh exact candidate.

**Outputs:** a mutation response/receipt only; later GitHub state may show a merge.

**Guards:** merge-capable credential must be separate from Symphony/agent automation; candidate still exact immediately before action.

**Side effects:** mutates only the designated disposable GitHub proof target during H-100.

**Durability:** GitHub audit history plus evidence manifest.

**Authority granted:** none by the mutation response itself.

**Authority explicitly NOT granted:** `merge action != merge verification`; `MERGED != ACCEPTED`.

## 4.8 MergeVerification

**Truth owner:** GitHub reread interpreted by Symphony.

**State owner:** typed `MergeVerification` / `CompletionProof`.

**Identity:** CandidateRef + strategy + merge commit SHA/tree + current main SHA + containment result + observation time.

**Inputs:** approved exact candidate, post-action PR/commit/default-branch rereads.

**Outputs:** `verified | not_merged | mismatch | unsupported | unavailable | ambiguous`.

**Guards:** PR really merged; PR head still equals authorized candidate; fetched merge object matches supported strategy/tree; current default branch contains the result as required; exact candidate evidence still valid.

**Side effects:** when verified, allows `CompletionProof` to advance to `merge_verified`.

**Durability:** typed proof/evidence via existing recovery path.

**Authority granted:** mechanical proof of source-control merge closure.

**Authority explicitly NOT granted:** no human approval and no final provider completion by itself.

## 4.9 CompletionProof

**Truth owner:** Symphony typed proof construction from already trusted evidence.

**State owner:** Symphony work-control/recovery state.

**Identity:** exact work item/project contract + CandidateRef + candidate tree + policy fingerprint + review provenance + merge verification + closure observation/signatures.

**Inputs:** exact-candidate review/mechanical evidence, separate human merge approval, trusted merge verification, final fresh provider observation.

**Outputs/states:**

```text
merge_authorized
  -> merge_verified
  -> completed
```

**Guards:** each stage requires the exact prior-stage identity/bindings; completion requires a fresh attested provider `Done` observation after merge verification and exact project/work-item contract match.

**Side effects:** exposes typed mechanical guard evidence to canonical lifecycle assessment.

**Durability:** typed proof may persist via existing durable mechanical evidence.

**Authority granted:** only the matching mechanical completion guard for its exact stage.

**Authority explicitly NOT granted:** no self-merge, no semantic review, no Master programme acceptance.

## 4.10 Plane work-item identity / provider observations

**Truth owner:** Plane REST for provider state observations; Symphony for canonical lifecycle interpretation.

**State owner:** Plane for provider record; Symphony for canonical validated lifecycle/authority.

**Identity:** exact workspace/project/work-item identifiers plus provider project contract/read attestation.

**Inputs:** fresh Plane REST reads and bounded mutation intents.

**Outputs:** provider observations.

**Guards:** project contract, identity mapping, read provenance/freshness, canonical transition guards.

**Side effects:** only H-100 may later perform designated disposable mutations; H-120A performs none.

**Durability:** Plane retains provider history; Symphony retains only the authority/evidence it owns.

**Authority granted:** provider observations may constrain/revoke/suspend.

**Authority explicitly NOT granted:** provider observation cannot grant forward autonomous authority, approve a candidate, prove completion, or satisfy dependencies by itself.

## 4.11 RuntimeAttempt

**Truth owner:** Symphony host/Orchestrator.

**State owner:** active Orchestrator running state; durable lineage/fence facts are owned by the existing attempt ledger rather than by `RuntimeAttempt` itself.

**Identity:**

```text
runtime_attempt_id
work_item_id
lineage_generation
responsibility
runtime_profile
```

**Inputs:** routed work item + route + current lineage generation.

**Outputs:** host-owned bounded runtime attempt identity/state.

**Guards:** exact identity match and allowed state transitions.

**Side effects:** bounds a role execution and its provenance.

**Durability:** `RuntimeAttempt` object itself is not persisted; durable lineage/authority facts remain in existing ledgers.

**Authority granted:** none in isolation; it scopes whose semantic evidence is current.

**Authority explicitly NOT granted:** cannot approve its own candidate, merge, or create Master authority.

## 4.12 Lineage generation / AttemptLedger

**Truth owner:** Symphony.

**State owner:** durable AttemptLedger.

**Identity:** work item + generation + attempt/fence correlation.

**Inputs:** attempt reservation/start/retry/rearm/recovery events.

**Outputs:** durable current lineage and authority-fence facts.

**Guards:** exact generation/attempt/fence identity; stale generations fail closed.

**Side effects:** controls whether prior attempt evidence is current or stale.

**Durability:** durable by design.

**Authority granted:** preserves one current attempt lineage and prevents stale authority reuse.

**Authority explicitly NOT granted:** no source-control review/merge authority.

## 4.13 TransitionAttempt / ambiguous mutation boundary

**Truth owner:** Symphony transition coordinator plus fresh provider reread.

**State owner:** transition-attempt ledger.

**Lifecycle:**

```text
requested
-> intent_authorized
-> fresh_context_loaded
-> prepared
-> mutation_submitted
-> verifying
-> verified | rejected | conflict | provider_failed | indeterminate
```

**Inputs:** canonical transition intent, guards, provider mutation/reread.

**Outputs:** verified transition or a fail-closed terminal/indeterminate outcome.

**Guards:** durable Prepared restart fence; durable correlated Submitted boundary before dispatch; no blind resubmission after possibly committed mutation.

**Side effects:** provider mutation only in designated authorized execution phases.

**Durability:** the `prepared` record with `submission_fenced_at` is synced first. The coordinator then records and syncs `mutation_submitted` with an immutable `provider_request_id` before dispatch.

**Authority granted:** none from a mutation response; only reconciled truth may advance canonical state.

**Authority explicitly NOT granted:** no retry merely because a response was missing/ambiguous.

The Prepared fence and Submitted boundary serve distinct purposes. A fenced Prepared record remains reconciliation-only after restart. The Submitted record binds the attempt to one opaque request identity; it does not make the provider mutation idempotent. The typed envelope passes that identity and the bound transition scope through Tracker and the Plane adapter.

When explicit witness-required mode is enabled, Req's request-specific `:finch_request` hook places the ID in Finch private metadata, validates the final PATCH request, and requires the synchronous sink to acknowledge the same ID before invoking Finch. This witness proves an acknowledged application handoff of that request object. It does not prove network transmission, provider receipt, or provider commit. Fresh provider reread remains mandatory.

Legacy records without `provider_request_id` remain readable and reconciliation-only. A host environment that suppresses responses must still independently prove how it binds the witness to the exact encrypted response path; application correlation alone does not authorize or complete H-100 P0 execution.

## 4.14 SuspensionContext

**Truth owner/state owner:** Symphony.

**Identity:** exact suspended work/attempt/reason/correlation identity.

**Inputs:** authority-reducing condition, fresh reconciliation.

**Outputs:** open/resolving/resolved/escalated suspension state.

**Guards:** provider projection alone cannot clear suspension; resolution requires exact Symphony-owned conditions.

**Side effects:** removes or constrains autonomous authority until safe resolution.

**Durability:** durable.

**Authority granted:** safe local suspension and controlled resolution.

**Authority explicitly NOT granted:** Plane `Blocked` is not Symphony suspension authority.

## 4.15 Governance projection/checker

**Truth owner:** external human Master decision / Master Roadmap.

**State owner:** derivative projection file.

**Identity:** accepted Master Roadmap blob, historical accepted decision baseline, active/accepted phase fields, decision references.

**Inputs:** materialized already-authorized governance facts.

**Outputs:** read-only consistency/freeze validation.

**Guards:** derivative state must exactly match Master authority; banned/later phases may not become active.

**Side effects:** none.

**Durability:** repository documents.

**Authority granted:** none. The checker detects contradictions; it does not authorize.

**Authority explicitly NOT granted:** cannot self-authorize H-100/H-110/H-120B.

## 4.16 Evidence artifacts/documentation

**Truth owner:** underlying system of record for each fact; human authors for explanatory prose.

**State owner:** repository documentation for retained audit manifest.

**Identity:** phase/proof identifier plus exact cited system identities.

**Inputs:** normalized fields from GitHub, Plane, Symphony, Reviewer, Master.

**Outputs:** reviewable evidence manifest.

**Guards:** every claim must trace to the correct authority class/source.

**Side effects:** none.

**Durability:** retain through H-120B and final acceptance.

**Authority granted:** none.

**Authority explicitly NOT granted:** documents do not become lifecycle or programme authority merely by recording facts.

---

# 5. Explicit lifecycles

## 5.1 Candidate/evidence binding lifecycle

```text
candidate produced
-> candidate identity known
-> candidate frozen
-> evidence collected
-> independent review bound
-> Master merge authorization bound
-> human merge attempted
-> merge verified
-> CompletionProof merge_verified
-> provider closure freshly verified
-> CompletionProof completed
-> validated Done
```

### Invalidation transitions

Any of the following invalidates candidate-bound evidence and prevents forward reuse:

- HEAD/candidate SHA changes;
- observed PR head no longer equals candidate SHA;
- base SHA changes under current V1 policy;
- candidate tree changes or does not match the candidate commit;
- synthetic-merge SHA changes where synthetic-merge checks are the configured subject;
- synthetic-merge parents differ from the exact frozen base/head;
- synthetic-merge tree is inconsistent with the expected candidate result;
- required-check context/app/subject policy changes;
- check evidence belongs to another lookup SHA or becomes pending/non-success/ambiguous;
- reviewer provenance targets another candidate/tree/policy/runtime attempt/lineage;
- Master approval targets another candidate;
- merge result does not correspond to the exact approved candidate;
- fresh reconciliation reports candidate/policy movement.

**Result of invalidation:** do not “patch” the old approval. Return to candidate identity/freeze, recollect mechanical evidence, obtain a new independent review binding, and obtain a new candidate-specific Master decision as applicable.

## 5.2 Review lifecycle

```text
candidate mechanically verified
-> reviewer RuntimeAttempt current
-> semantic review result produced
-> host validates provenance
-> exact-candidate review acceptance mechanically bound
-> ready-to-merge eligible
```

If candidate/tree/policy/lineage changes:

```text
accepted review -> stale/invalid
```

A stale review cannot be revived by copying fields into another map.

## 5.3 Master human-decision lifecycle

```text
no merge decision
-> candidate freshly re-resolved
-> review/mechanical evidence current
-> Master approves exact candidate A
-> human action may be attempted once against A
```

Movement before the action:

```text
approved A -> invalid for B
```

The decision does not migrate to a new HEAD, new base, new synthetic merge, new policy, or new PR.

## 5.4 CI/check lifecycle

```text
required check identity known
-> exact subject SHA resolved
-> pending | terminal
-> success | non-success | ambiguous
```

Only unambiguous success on the exact frozen subject qualifies.

Reruns are audit events, not authority shortcuts. See Section 7.

## 5.5 Human merge lifecycle

```text
candidate-specific HumanDecision exists
-> human performs merge action
-> action response recorded as receipt only
-> GitHub PR/commit/default-branch reread
-> structural merge identity verified
-> governance signature evidence verified
-> relevant post-merge CI verified
-> typed MergeVerification accepted
```

`merge action != merge verification`

`MERGED != ACCEPTED`

## 5.6 CompletionProof lifecycle

Preserve exactly:

```text
merge_authorized
-> merge_verified
-> completed
```

Disallowed substitutions:

```text
PR says merged                  != completed proof
Plane says Done                 != completed proof
agent reports success           != completed proof
CI passed on an old HEAD        != completed proof
human merge response succeeded  != merge verification
```

## 5.7 Provider mutation ambiguity lifecycle

```text
mutation intended
-> durable pre-submit fence
-> mutation submitted
-> response known OR outcome ambiguous
-> fresh provider reread/reconciliation
-> verified | conflict | provider_failed | indeterminate
```

An ambiguous/potentially committed mutation is never blindly retried.

---

# 6. Exact CandidateRef freeze procedure

The H-100 freeze is a **governance/evidence operation around** the existing thin `CandidateRef`. It is not permission to redesign `CandidateRef`.

## 6.1 Field classification

| Field | Classification | Why | Truth owner | Freshness rule | Invalidation rule |
|---|---|---|---|---|---|
| Repository display name | Required descriptor in freeze manifest; not an extra CandidateRef identity field | Human/audit readability | Config/GitHub | Resolve at freeze | Config/repo mismatch stops |
| `repository_identity` | **Required in CandidateRef** | Immutable repository binding | GitHub repo ID via SourceControl | Fresh at capture/review/Master gate | Any repo identity mismatch invalidates |
| `base_sha` | **Required in CandidateRef** | Current V1 requires exact base stability | GitHub base ref | Fresh at capture and every candidate re-verification | Any base movement invalidates current candidate-bound trust |
| Base tree | **Derived audit evidence**; do not add to CandidateRef | Proves exact base content without creating second identity owner | GitHub commit object | SHA immutability after correct fetch | Tree not matching base commit means malformed/incorrect evidence |
| `candidate_sha` / HEAD SHA | **Required in CandidateRef** | Principal candidate code identity | GitHub/local candidate then GitHub PR | Fresh at capture/review/Master/merge verification | Any HEAD movement invalidates |
| `observed_pr_head_sha` | **Required in CandidateRef** | Proves PR head matched candidate at observation | GitHub PR reread | Fresh each verification | Must equal `candidate_sha`; otherwise invalid |
| Candidate/HEAD tree | **Required outside CandidateRef** | Existing verification/review/CompletionProof binds exact tree | GitHub commit object | Re-fetch at capture/review/merge boundaries | Mismatch invalidates |
| PR number/identity | **Required in CandidateRef** | Binds GitHub PR identity | GitHub | Fresh enough to prove same open/merged PR | Different PR invalidates |
| Synthetic merge SHA | **Derived and conditional outside CandidateRef** | Only needed when a configured required check uses `synthetic_merge` subject | GitHub PR merge ref/commit | Re-resolve immediately for each check proof; never trust a stale saved value | Base/head/ref change invalidates |
| Synthetic merge tree | **Derived and conditional outside CandidateRef** | Validates the synthetic result for the frozen pair | GitHub commit object | Same observation as synthetic SHA | Wrong tree or parents rejects proof |
| Required-check identities | **Required outside CandidateRef** in frozen policy | Context/app/subject are policy, not candidate identity | Source-control config + protected-branch facts | Freeze before review and re-read before Master merge decision | Policy/check identity movement invalidates downstream review/merge evidence |
| Reviewer authorization identity | **Required after candidate freeze, outside CandidateRef** | Semantic/human classes must remain separate from candidate identity | Reviewer + Symphony provenance | Must be current at Ready-to-Merge and Master gate | Candidate/tree/policy/attempt mismatch invalidates |
| Master merge decision identity | **Required outside CandidateRef** | Human authority is not SCM identity | Human Master decision | Issued only after fresh re-resolution | Approval for A cannot authorize B |

## 6.2 Freeze algorithm for later H-100

Only after H-100 receives a separate Master authorization:

1. Establish the designated disposable GitHub proof repository/PR and exact Plane proof item.
2. Read GitHub repository identity.
3. Read the configured base ref and resolve exact `base_sha`; fetch its tree for audit.
4. Resolve the exact candidate/HEAD SHA and candidate tree.
5. Find/read the exact PR; require PR head == candidate SHA.
6. Build the existing five-field `CandidateRef`.
7. Freeze the source-control policy fingerprint: repository/project/base branch plus canonical required checks, including each `context`, `app_id`, and configured `subject`.
8. If any check uses `synthetic_merge`, re-resolve the current synthetic merge commit and prove:
   - exact parent pair is the frozen base and candidate as required by current SourceControl semantics;
   - tree is the expected candidate result;
   - the required check lookup is against that exact synthetic-merge SHA.
9. Record the freeze manifest: CandidateRef fingerprint, candidate tree, base tree audit field, policy fingerprint, required-check identities, PR identity, and any conditional synthetic-merge observation.
10. Re-resolve the entire freeze before independent review acceptance.
11. Re-resolve again immediately before the Master Final Gate.
12. Any movement invalidates candidate-bound evidence; do not carry forward the old review or Master approval.

### CandidateRef V1 boundary

Do **not** add:

- base tree;
- candidate tree;
- synthetic merge SHA/tree;
- check run IDs;
- workflow run attempts;
- reviewer identity;
- Master decision;
- merge result;

to `CandidateRef`.

Those are separate evidence/authority layers already modelled by the current design.

---

# 7. Required-check policy for later H-100

## 7.1 Current protected-main baseline

At H-120A planning time:

```text
make-all                  app_id=15368
validate-pr-description   app_id=15368
```

These names/app IDs are the current baseline, not hard-coded future run IDs.

H-100 MUST re-read protected-branch/check policy at its own freeze. If policy has changed from the accepted H-120A gate, STOP and return for governance adjudication rather than silently accepting a new requirement set.

## 7.2 Mechanical identity

A required check is identified by:

```text
context
GitHub App ID
configured subject (head | synthetic_merge)
exact lookup SHA derived from that subject
```

A same-name check from another GitHub App cannot substitute.

A successful check on another SHA cannot substitute.

Branch protection tells us the required context/app identity. It does **not** by itself establish whether Symphony's policy should interpret a PR workflow run as `head` or `synthetic_merge`. H-100 must use the actual frozen SourceControl configuration and prove that the workflow's actual checkout semantics match it.

## 7.3 Authoritative workflow evidence

For every required CI result retained in H-100 evidence, capture:

- check context;
- check-run app ID;
- check lookup SHA;
- configured subject;
- GitHub Actions workflow name/path;
- run ID;
- `run_attempt`;
- event;
- `head_sha`;
- status;
- conclusion;
- job/check identity;
- started/completed timestamps;
- exact checkout evidence from workflow logs where relevant.

For `make-all`, retain the workflow's existing exact `HEAD`/tree/subject logging and `HEAD == GITHUB_SHA` assertion. If `GITHUB_SHA` is a GitHub synthetic merge, do not relabel it as head evidence. The configured source-control check subject must correspond to what was actually checked.

Symphony's GitHub adapter treats these as separate facts for `synthetic_merge` required checks:

- check-run records may attach to the PR head SHA and expose only `check_suite.id` (not a nested `workflow_run.id`);
- Actions workflow-run listings for pull-request CI are keyed by PR head SHA (`workflow_run.head_sha`), not the synthetic merge ref SHA;
- the synthetic merge ref commit must still be re-resolved and validated (exact base/candidate parents and candidate tree) before binding;
- the required check must bind `check_run.check_suite.id` to `workflow_run.check_suite_id` on a successful `pull_request` / `pull_request_target` run whose `pull_requests[]` entry matches the exact PR number, candidate head, and frozen base;
- the checked-out commit for that execution is proven mechanically from the **same bound workflow run** by reading the designated `linux-static-quality` job, requiring a successful `Record exact candidate checkout` step, and parsing the stable `CI checkout SHA` / `CI checkout tree` log lines to match the validated synthetic merge ref SHA and candidate tree;
- H-100 evidence must still retain those checkout log lines in the evidence bundle for human audit even though SourceControl now enforces them mechanically;
- a green check on the head alone, without merge-ref validation, workflow-run binding, and checkout-log execution proof, is insufficient when the configured subject is `synthetic_merge`.

For `validate-pr-description`, retain its exact check identity and candidate binding required by the frozen policy.

## 7.4 Terminal classification

Only an unambiguous completed `success` qualifies.

The following do **not** authorize merge:

```text
pending / queued / in_progress
failure
cancelled
timed_out
skipped
action_required
neutral
stale
startup_failure
any other non-success
missing
wrong app
wrong SHA
ambiguous duplicate observations
```

## 7.5 Staleness

CI is stale if any relevant binding moved after the evidence was collected:

- CandidateRef/HEAD changed;
- base changed;
- policy fingerprint changed;
- synthetic-merge subject changed;
- current check lookup SHA differs;
- required context/app changed;
- review was performed against another mechanical evidence set.

Stale CI must be recollected and downstream candidate-bound review authorization reacquired.

## 7.6 Rerun / `run_attempt > 1` policy

H-120A must not invent a “latest attempt always wins” rule because current SourceControl check verification does not model Actions `run_attempt` as an authority primitive.

For a rerun:

1. retain **all** attempt IDs/results in the audit manifest;
2. require same frozen candidate, policy, workflow, event/subject;
3. perform a fresh mechanical SourceControl check reread;
4. accept the rerun only if the current check observations presented to SourceControl are unambiguously successful for the exact required context/app/SHA;
5. if GitHub exposes conflicting same-identity observations such that SourceControl reports `:ambiguous_check`, STOP;
6. never manually discard a failed old observation merely to manufacture a successful mechanical result;
7. prior failed/cancelled/timed-out attempts remain retained as audit history even if a later unambiguous current run succeeds.

This preserves existing fail-closed behavior without unauthorized runtime redesign.

## 7.7 Pre-merge vs post-merge runs

A post-merge `push` run on the resulting default-branch commit is **post-merge verification evidence**.

It cannot retrospectively authorize the human merge.

Pre-merge authorization requires exact current candidate-bound required-check evidence before the Master decision.

---

# 8. Evidence location and provenance policy

## 8.1 Planned evidence manifests

H-120A creates only:

```text
docs/symphony-hardening-playbook-v4.1/H-120A_GOVERNANCE_PRE_GATE.md
```

H-100 and H-110 must not be created/executed under H-120A. When separately authorized, the repository-standard evidence locations should be:

```text
docs/symphony-hardening-playbook-v4.1/H-100_LIVE_PROOF_EVIDENCE.md
docs/symphony-hardening-playbook-v4.1/H-110_RESTART_FAILURE_SOAK_EVIDENCE.md
```

These future paths are planned retention locations, not authority and not H-120A outputs.

Raw external truth remains in its system of record. The evidence documents retain immutable identifiers and the minimum normalized fields needed for independent replay/review. Do not dump credentials, secret headers, or tokens into repository evidence.

## 8.2 Evidence-class matrix

| Evidence class | Source | Authoritative fields | Freshness | Candidate binding | Retention | Can grant forward authority? |
|---|---|---|---|---|---|---|
| GitHub SCM facts | GitHub repo/PR/git commit/compare/default-branch rereads | repo ID, PR, base/head SHA, commit tree, merge SHA/tree/parents, merged flag, current default-branch SHA, GitHub commit verification | Capture; review; Master gate; immediately after merge | Exact CandidateRef/tree | IDs + normalized snapshot through H-120B; GitHub raw record remains SoR | Mechanical facts only; **not** human/semantic authority |
| GitHub Actions CI | GitHub check runs/actions runs/jobs/logs | context, app ID, lookup SHA, subject, workflow/path, run ID/attempt, event, status/conclusion, checkout identity | After freeze and again before Master gate as required | Exact frozen subject | Through H-120B | Mechanical guard only |
| Plane provider observations | Plane REST + trusted read attestation | workspace/project/item, provider state identity, observed_at/read provenance | Fresh reread after mutation and at closure | Work item/project contract rather than SCM candidate directly; CompletionProof bridges exact candidate to final closure | Retain normalized timeline/IDs | **No.** May constrain/revoke; never create forward authority |
| Symphony durable authority | AttemptLedger, transition ledgers, RecoveryLedger, typed CompletionProof/candidate evidence | lineage/fence, typed proof fingerprints/stages, exact mechanical provenance | Current Symphony reconciliation | Exact work item + candidate/proof | Existing durable policy + evidence manifest identifiers | Yes only through canonical typed guard/lifecycle rules; cannot invent HumanDecision |
| Planner/Reviewer semantic attestations | Host-created role semantic evidence | responsibility, RuntimeAttempt ID, lineage, subject, timestamp, semantic fingerprint | Current exact attempt | Review provenance binds candidate/tree/policy | Retain signed/mechanical provenance as designed | Only its semantic requirement; cannot substitute mechanical/human |
| Human Master decisions | Master Governance | decision ref/time, exact approved candidate fingerprint/tree/policy/check snapshot, scope | Must follow fresh re-resolution | Exact candidate-specific | Through final acceptance | **Yes, but only the explicit human decision it represents** |
| Evidence documents | Repository docs | cited identifiers and explanatory conclusions | Update only from truth-owner data | Must state exact binding | Through programme closure | **No** |

### Non-negotiable evidence rules

```text
provider observation cannot grant forward authority
mutation response is not truth
agent prose is not machine evidence
documentation is not authority
CI is not semantic review
review is not Master approval
Master approval is not merge verification
merge verification is not provider closure
```

---

# 9. Disposable H-100 Plane/GitHub proof plan — DESIGN ONLY

H-120A MUST NOT execute this section. It is the deterministic procedure to use only after a separate human Master decision authorizes H-100.

## 9.1 Isolation requirements

### Pre-provisioning manifest

After a separate Master decision authorizes H-100, and before any external resource is created or mutated, the human resource administrator must record a proof setup manifest. The manifest is a run-specific evidence record, not an authority source. Record planned names, the approved non-production owner/workspace, the human provisioning and cleanup administrator, the runtime read-credential scope, the separate human merge identity, the evidence-retention location, and the cleanup hold conditions. Append each immutable provider ID and creation timestamp as the resource is provisioned, before using it for another mutation. Append the Master cleanup decision reference and time only after cleanup is permitted. Do not record secret values.

Use one proof key and candidate binding across both providers. Set `proof_key` to `<YYYYMMDD>-<candidate-short-sha>-<sequence>` using the H-100 authorization date in UTC. Start the sequence at `01`; if a proposed name already exists, stop and record the next unused sequence in the H-100 authorization record before provisioning. Set `proof_id` to `H100-<proof_key>`. The manifest must include:

| Resource | Name pattern | Identifier to retain |
|---|---|---|
| Plane project | `H100-PROOF-<proof_key>` | Workspace ID/key, project ID/key, and resource owner |
| Primary Plane work item | `H100-PROOF-ITEM-<proof_key>` | Work-item ID and project contract |
| Downstream Plane work item | `H100-DEPENDENT-<proof_key>` | Work-item ID and dependency relation |
| GitHub proof repository | `<approved-owner>/symphony-h100-proof-<proof_key>` | Repository ID and full name |
| GitHub proof branch | `proof/h100-<proof_key>` | Branch ref and candidate SHA |
| GitHub proof PR | `H-100 disposable lifecycle proof - <candidate-short-sha>` | PR number, URL, base SHA, and head SHA |

The H-100 authorization must identify or approve the target owner and non-production Plane workspace. The resource administrator only provisions and cleans up those named resources; this role grants no review, merge, lifecycle, or acceptance authority. If the owner, scope, credentials, retention path, or immutable resource IDs cannot be established before execution, do not begin H-100 and return for Master review.

### Plane

Use a named disposable test workspace/project, or a dedicated isolated project inside a non-production workspace, with:

- exact workspace ID/key recorded;
- exact project ID/key recorded;
- one uniquely named primary H-100 work item;
- one uniquely named downstream dependent work item;
- canonical state/project contract compatible with the frozen candidate;
- no production work items;
- credentials scoped to the disposable workspace/project as narrowly as supported.

Suggested identifier pattern:

```text
H100-PROOF-<proof_key>
H100-PROOF-ITEM-<proof_key>
H100-DEPENDENT-<proof_key>
```

Do not create these resources during H-120A.

### GitHub

Use a **disposable GitHub proof repository** or an equivalently bounded disposable target, not a production-impacting live merge.

Preferred deterministic mode:

1. seed/mirror the exact authorized H-100 candidate commit object/history into a disposable repository;
2. create an internal branch/PR entirely inside that disposable repository;
3. reproduce the required CI workflow/protection semantics there;
4. configure the H-100 Symphony proof deployment to that disposable repository;
5. capture that repository's own immutable `repository_identity` in the proof `CandidateRef`.

The code under proof must remain the exact frozen H-100 candidate SHA for the entire H-100/H-110 proof. H-110 must reuse that same frozen candidate. If the commit/object cannot be mirrored without changing the intended candidate identity or if proof configuration cannot safely target the disposable repository, STOP and return for Master replanning; do not fall back to a production `main` merge merely to finish H-100.

Suggested branch pattern:

```text
proof/h100-<proof_key>
```

Suggested PR title:

```text
H-100 disposable lifecycle proof - <candidate-short-sha>
```

## 9.2 Credentials/capabilities

- Plane REST credential: scoped to the named disposable proof target.
- Symphony runtime GitHub credential: read/check/PR observation capability as required by current SourceControl, plus bounded **`Actions: read`** on the frozen H-100 GitHub App installation so `GET /actions/runs` (and single-run hydration when `pull_requests[]` is absent) can bind synthetic-merge checks on private repositories.
- Codex/agent runtime: no GitHub merge/admin credential.
- Human merge identity: separate interactive/human credential that is **not** available to Symphony or child agents.
- Setup/cleanup administrator credential, if required: held outside runtime and used only for disposable-resource setup/cleanup.
- Never record secret values in evidence.

The existing generic `LiveProofGate` pattern demonstrates explicit consent/named-resource/credential/run-flag safety, but its current provider map does not include Plane. Therefore H-100 MUST NOT falsely claim that this helper itself gates the Plane proof. H-120A does not extend it. H-100 authorization/setup must explicitly establish equivalent named-disposable-resource consent and scope for Plane.

## 9.3 Minimum real proof sequence

```text
real disposable Plane work item
-> authorized autonomous Symphony execution
-> real bounded Codex execution path
-> real disposable GitHub candidate/PR
-> exact CandidateRef freeze
-> real candidate-bound CI
-> independent Reviewer
-> exact candidate-bound review acceptance
-> fresh Master Final Gate
-> candidate-specific HumanDecision
-> human merge
-> trusted GitHub reread
-> exact MergeVerification
-> post-merge CI evidence
-> CompletionProof merge_verified
-> controlled Plane Done mutation
-> fresh Plane Done observation
-> CompletionProof completed
-> validated Done
-> downstream dependent becomes satisfiable
```

The proof must also deliberately attempt the already-required negative provider bypasses (for example manual Plane Ready-to-Merge/Done movement) and prove those observations cannot bypass canonical guards.

## 9.4 No source modification during proof

No source modification is permitted during proof. Once the H-100 candidate is frozen:

- no source edits;
- no fixup commit;
- no dependency update;
- no workflow tweak;
- no “evidence only” candidate amendment.

Any candidate movement invalidates the proof run. Stop, return to governance, establish a new freeze/review/Master authorization, and start a new proof lineage.

## 9.5 Failure/rollback

Before merge:

- on any uncertain or failed condition, stop the proof;
- do not human-merge;
- reconcile Plane mutations before considering retry;
- revoke/suspend automation if required;
- retain failure evidence.

After merge:

- because the target is disposable, do not attempt to “undo” truth merely to make the report green;
- record the actual merge outcome;
- complete only if exact verification succeeds;
- if completion cannot be proven, leave the proof failed/blocked and retain evidence.

Credential leakage or scope uncertainty:

- immediately stop execution;
- revoke/rotate the affected disposable credential;
- do not continue from prior authority state.

## 9.6 Cleanup

Cleanup is a human-controlled post-evidence action.

Do not delete the disposable Plane project/items, GitHub repository/PR, or CI records until:

- H-100 evidence is complete;
- H-110 has finished against the same frozen candidate;
- H-120B has had access to the required external records, or an accepted archive preserves them;
- Master Governance explicitly permits cleanup.

After permitted cleanup:

- revoke/delete proof-only credentials;
- archive/delete disposable provider resources as appropriate;
- preserve immutable identifiers, timestamps, fingerprints and final evidence report;
- do not rewrite the historical evidence document to pretend deleted resources never existed.

## 9.7 H-100 artifacts to retain

- proof ID;
- frozen CandidateRef + fingerprint;
- base/candidate trees;
- source-control policy fingerprint;
- required-check identities;
- conditional synthetic-merge SHA/tree/parents;
- Plane workspace/project/item IDs;
- provider state timeline/read attestations;
- RuntimeAttempt IDs/responsibilities/profiles;
- lineage generation(s);
- CI run/check IDs, attempts, events, SHAs, conclusions and checkout proof;
- independent review semantic/provenance fingerprints;
- Master decision ref/timestamp/exact candidate;
- human merge actor/time/strategy;
- GitHub post-merge PR/commit/default-branch reread;
- merge commit parents/tree;
- GitHub commit signature verification result/reason;
- post-merge CI run identity/result;
- typed MergeVerification identity;
- CompletionProof stage/fingerprint transitions;
- final fresh Plane Done observation;
- downstream dependency release proof;
- required negative-control outcomes.

---

# 10. Human merge proof procedure

## Step 1 — Reviewer binds the exact candidate

The independent Reviewer must review the exact frozen CandidateRef/tree/policy and produce:

- its semantic attestation;
- the signed candidate-bound review provenance;
- mechanical review acceptance for that same candidate.

If candidate/tree/policy moves, invalidate and re-review.

## Step 2 — Master independently re-resolves

Immediately before granting merge authority, Master Gate must independently reread/re-resolve:

- current repository identity;
- PR identity;
- base SHA;
- candidate/PR HEAD SHA;
- candidate tree;
- frozen source-control policy;
- configured check subjects;
- conditional synthetic-merge identity/parents/tree;
- required check context/app/SHA/conclusion;
- reviewer provenance exact binding;
- current governance authorization.

Do not rely on the Reviewer’s prose summary as the source of these mechanical facts.

## Step 3 — Master grants candidate-specific human merge authority

Master creates a HumanDecision bound to the exact candidate evidence.

The record must make clear:

```text
approved candidate fingerprint = A
approved candidate tree = T
approved policy fingerprint = P
approved PR = N
decision reference = D
decision timestamp = ...
```

This is not a reusable blanket approval.

## Step 4 — Human performs the merge

A human using a separately held merge-capable identity performs the merge.

No Symphony agent, Reviewer, governance checker, Plane state, CI status, or evidence document invokes merge.

Capture the intended merge strategy and the mutation response as a receipt.

Do **not** treat the response as truth.

## Step 5 — Reread GitHub and verify actual merge truth

Freshly read GitHub after the action and require:

- PR is actually merged;
- PR head still equals the exact authorized candidate;
- merge commit SHA is reread, not trusted merely because it appeared in the mutation response;
- merge commit object is fetched;
- supported merge strategy is structurally verified;
- parent/tree relationship matches the authorized candidate as required by current SourceControl;
- current default branch contains the verified merge result;
- no wrong-candidate result is accepted;
- GitHub commit `verification.verified=true` with acceptable `reason`, retained as governance merge-signature evidence.

The existing runtime `MergeVerification` remains structurally source-control-bound. H-120A does **not** add signature fields to `CandidateRef` or `CompletionProof`. Signature verification is an explicit external mechanical evidence prerequisite in the H-100 human/Master proof procedure. If future authority requires the runtime typed proof itself to cryptographically bind that GitHub signature field, that is a separate executable change requiring separate authorization.

## Step 6 — Verify required source-control closure

Run the existing exact-candidate merge verification from the trusted pre-merge evidence and require current required checks to remain valid under the existing SourceControl policy.

Only then advance the typed proof to `merge_verified`.

## Step 7 — Verify post-merge CI

Capture the relevant default-branch `push` workflow run for the exact verified merge/default-branch commit.

Require unambiguous success.

This is post-merge assurance, not retroactive merge authority.

## Step 8 — Controlled Plane closure and fresh reread

Only after merge verification:

1. request the controlled canonical `Merging -> Done` provider transition;
2. treat the provider mutation response as provisional;
3. perform the required fresh Plane reread;
4. require the exact work item/project contract and fresh observation to map to canonical `Done`;
5. close the exact `CompletionProof` to `completed`.

## Step 9 — Validate Done/dependency satisfaction

Only the completed typed proof may validate successful `Done` and satisfy downstream dependencies.

## Step 10 — Preserve programme distinction

```text
MERGED != ACCEPTED
```

A successful H-100 disposable merge/proof does not itself Master-accept H-100.

Likewise, merging an eventual H-120A documentation PR does not allow that PR, its author, or its checks to self-authorize H-100.

A later explicit Master decision is still required.

---

# 11. H-I19 through H-I24 mapping

| Invariant | H-120A rule |
|---|---|
| **H-I19 — provider observation cannot grant forward authority** | Plane evidence is classified as observation only. Provider Ready-to-Merge/Done/manual movement cannot create review, merge, completion, or dependency authority. Fresh observations can constrain/revoke and are used only inside canonical guarded reconciliation. |
| **H-I20 — trusted CompletionProof required** | Preserve typed `merge_authorized -> merge_verified -> completed`; no PR merged flag, provider Done, CI success, or agent claim substitutes. Final Done requires fresh provider closure after merge verification. |
| **H-I21 — suspension is Symphony-owned** | H-120A changes no suspension logic. H-100/H-110 must treat Symphony `SuspensionContext`/authority fence as canonical; Plane `Blocked` cannot create/clear suspension authority. |
| **H-I22 — ambiguous mutation cannot be blindly retried** | Human merge and Plane mutation responses are receipts, not truth. Every possibly committed mutation is followed by authoritative reread/reconciliation; uncertainty is fail-closed. |
| **H-I23 — candidate movement invalidates candidate-bound trust** | Freeze/review/Master/merge verification all bind exact CandidateRef/tree/policy/check subject. HEAD/base/policy/synthetic/check/review movement invalidates downstream trust. |
| **H-I24 — guard classes are non-interchangeable** | MechanicalGuard, SemanticAttestation and HumanDecision remain separate. CI cannot be review; Reviewer cannot be Master; Master decision cannot be mechanical merge truth; provider state cannot be any of them. |

H-I23 and H-I24 are the central H-120A gate properties.

---

# 12. Small-agent failure controls

The implementation/review instructions must explicitly reject these shortcuts:

1. **Review HEAD A, merge HEAD B** — Master must re-resolve immediately before approval/action.
2. **Trust `merge_commit_sha` alone** — fetch the commit and validate actual merge structure/state.
3. **Reuse a stale synthetic merge** — re-resolve and verify exact parents/tree.
4. **Use CI from an old HEAD/base/policy** — stale evidence is invalid.
5. **Ignore rerun semantics** — record `run_attempt`; use current unambiguous SourceControl result; conflict means STOP.
6. **Accept agent-written “tests passed” prose** — use GitHub/CI mechanical records.
7. **Treat Plane Done as completion** — require completed `CompletionProof`.
8. **Treat merge API/UI response as truth** — reread GitHub.
9. **Give runtime automation merge credentials** — forbidden.
10. **Let Reviewer grant Master authority** — forbidden by guard-class separation.
11. **Let Master approval A cover B** — exact candidate-specific decision only.
12. **Copy candidate fields into arbitrary maps** — use typed existing evidence/provenance structures.
13. **Expand CandidateRef into Programme B Candidate** — forbidden.
14. **Treat H-120A/H-100 evidence docs as authority** — documents are audit artifacts only.
15. **Create another lifecycle/merge authority owner** — preserve one Orchestrator/canonical work-control path.
16. **Assume branch-protection check names define the CI subject** — they do not; use frozen SourceControl check `subject` and actual workflow checkout semantics.
17. **Resolve reruns by manually selecting the nicer result** — forbidden; ambiguous mechanical observations fail closed.
18. **Modify governance projection/ledger to “finish” H-120A** — H-120A remains not accepted until separate Master governance materialization.
19. **Execute live Plane/GitHub proof during H-120A** — forbidden.
20. **Start H-110 because H-100 is the next roadmap step** — forbidden; no later phase is authorized.

---

# 13. Performance and scaling review

Because the selected outcome is documentation/governance-only:

```ini
PROVIDER_RUNTIME_READS=UNCHANGED
SCM_RUNTIME_READS=UNCHANGED
GENSERVER_BEHAVIOR=UNCHANGED
TASKS_MAILBOXES=UNCHANGED
PLANE_EPOCH_BEHAVIOR=UNCHANGED
DEPENDENCY_GRAPH_BEHAVIOR=UNCHANGED
REDIS=N/A
POSTGRES=N/A
PUBSUB=N/A
CACHE=N/A
INDEX=N/A
DISTRIBUTED_ARCHITECTURE=NO
```

No runtime performance benchmark is required for H-120A itself.

The later H-100 evidence procedure will perform deliberate proof-time rereads. Those are human-governed live-proof evidence operations, not a new steady-state runtime architecture.

---

# 14. Required negative controls

The H-120A governance artifact must enumerate these as mandatory H-100/H-110 proof controls, and existing deterministic tests covering the underlying runtime seam must remain passing:

| Negative control | Required result |
|---|---|
| old HEAD evidence presented for new HEAD | reject / re-freeze |
| candidate movement after review | invalidate review authorization |
| wrong synthetic merge | reject |
| wrong base/head pair | reject |
| stale CI | cannot authorize merge |
| failed required check | cannot authorize merge |
| cancelled required check | cannot authorize merge |
| timed-out required check | cannot authorize merge |
| skipped required check | cannot authorize merge |
| same check name from wrong GitHub App | reject |
| Plane `Done` without completed CompletionProof | validation required / reject |
| merge mutation response without reread | cannot advance proof |
| agent/automation attempts merge | no authority/capability |
| Reviewer attempts to grant itself Master authority | reject |
| Master approval for candidate A used for B | reject |
| H-100 active/authorized during H-120A | governance check fail |
| H-110 active/authorized during H-120A | governance check fail |
| H-120B active/authorized during H-120A | governance check fail |

Additional fail-closed rule:

If a negative control reveals behavior that does **not** match this required result, H-120A implementation must STOP. Do not quietly patch production code inside the documentation phase. Return the demonstrated defect for a separately authorized bounded enforcement change.

---
