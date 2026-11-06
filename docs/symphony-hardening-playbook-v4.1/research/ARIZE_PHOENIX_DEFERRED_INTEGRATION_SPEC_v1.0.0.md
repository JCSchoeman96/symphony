# Arize Phoenix for Symphony — Deferred Integration Specification

**Document ID:** SYM-OBS-PHX-001  
**Version:** 1.0.0 — frozen evaluation/design baseline (not accepted implementation authority)  
**Status:** **DEFERRED / RESEARCH-ONLY / REVIEW PROPOSAL / NOT AUTHORIZED TO EXECUTE**  
**Decision:** B. DEFER (2026-11-03)  
**Prepared:** 2026-11-03  
**Repository baseline:** `JCSchoeman96/symphony`, protected `main` at `0c53c732bbf68641482741c98afb25e073721ad9`  
**Vendor baseline:** Arize Phoenix `arize-phoenix-v21.0.0` at `6359d6388815d56f7795a3a8cd11e89a71793e01`  
**Future possible ownership:** Programme F (observability), Programme E (governed evaluations); no programme assignment or implementation authorization is granted.

> **AUTHORITY FIREBREAK — READ BEFORE USE**
>
> This is a version-locked, self-contained record of research and **conditional future design constraints**, placed in the V4.1 research area for review. It is **not** a V4.1 amendment, a canonical runtime contract, a Master Governance decision, a new roadmap, a task-dispatch instruction, an approval for a POC, or approval to install anything. Committing/merging this document, creating an issue, finishing H-100, or passing CI **does not** authorize development, telemetry collection/export, services, external network access, API spend, Phoenix integration, or merge automation. In any conflict, currently accepted Symphony governance and the normative V4.1 Master Roadmap prevail.

## 1. Purpose and decision

Capture a stable, auditable decision record for potential **future** Arize Phoenix use with the Symphony autonomous engineering control plane. Preserve the evaluation's constraints so later agents cannot convert exploratory proposals into uncontrolled implementation.

**Current disposition: DEFER.** Symphony already offers structured logs, current and bounded status/attempt views, lifecycle/lineage evidence, guard verification, dependency diagnostics and selected Codex usage data. It does **not** yet offer a general OpenTelemetry span tree, retained trace query system or versioned experiment/dataset facility. Absence of those features is not, by itself, evidence of an authorized unmet requirement. A separate production service, retention system, data-protection surface and integration effort are not presently justified.

**Do not integrate Phoenix immediately after H-100.** Formal acceptance of H-100 establishes only its own required proof. It does not authorize Phoenix. This future research track must remain independently gated.

### 1.1 Sources of truth and precedence

1. Normative: [V4.1 Master Roadmap](../V4_1_MASTER_ROADMAP.md).
2. Current acceptance/authorization: [V4.1 authority index](../README.md), [hardening ledger](../HARDENING_STATUS_LEDGER.md), and separately accepted human governance decisions.
3. Sequencing: [Unified Execution Roadmap v1.3.2](../../SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md), where not in conflict with normative authority.
4. Scope-specific future programme contracts, **only when separately accepted and authorized**.
5. This research specification: **non-authoritative** evidence and conditional design proposal; it cannot raise the authority of any numbered item above.

At the pinned evaluation baseline, H-120A was accepted, H-100 was **AUTHORIZED / ACTIVE / NOT ACCEPTED** for Real Disposable Live Proof only; H-110 and H-120B were not authorized; production rollout and automatic merging were not authorized; merge authority remained human-only. These facts must be reread from current authority records when this document is considered later, not treated as permanently current.

**V1-OPS-01** is a separately scoped application-level Observability Access & Readiness requirement covering snapshot/refresh, LiveView access, unauthorized and unavailable-snapshot behaviour, readiness semantics, and non-loopback deployment. It is not an Arize Phoenix feature or a justification to deploy Arize; its own authorization and acceptance are separate.

### 1.2 What “locked” means

The `1.0.0` content fixes this **evaluation baseline and conditional future constraints**, not implementation scope or programme permission. Do not silently edit or overwrite it after review. Change proposals must:
- identify the exact affected sections and current source commit;
- classify a correction as evidence update, threat-model change, conditional design change, scope expansion, or authority change;
- append a dated amendment/supersession entry and bump SemVer (patch for factual/evidence correction; minor for backward-compatible future design refinement; major for changed invariants/interfaces);
- refresh vendor version/security/licence evidence before any design decision;
- undergo independent architecture/security review; and
- obtain explicit Master Governance authority if a change would affect accepted controls or authorize work.

No source text here constitutes accepted repository law unless separately elevated by the governing process.

## 2. Baseline capability inventory (static evidence, not runtime acceptance)

| Area | Verified source shape at inspected SHA | What is **not** established |
|---|---|---|
| Work lifecycle | `WorkControl.WorkflowLifecycle` has canonical states, transition owners, guards, side-effect metadata and terminal classifications | No Phoenix-derived authority is permitted |
| Provider observations | `WorkControl.LifecycleAssessment` validates observations rather than trusting provider state directly | Observed provider state is not lifecycle approval |
| Dependencies | `Dependency.Graph` creates immutable epochs with completeness diagnostics and cycle detection | Trace parentage is not a dependency graph |
| Runtime isolation | `AgentRuntime` / `AgentRunner` / Codex App Server integration expose host-owned runtime attempts, selected session, turn, tool and error events | Complete hidden reasoning, every provider model call and nested subagent path are **not** evidenced |
| Safety durability | `WorkControl.RecoveryLedger` and suspension/retry policy support bounded durability and recovery | Session/timer restoration and arbitrary telemetry replay are **not** established/authorized |
| Source control | `CandidateRef`, `CandidateVerification`, `CompletionProof` bind candidate/review/CI/merge evidence | Neither spans nor evaluation scores can substitute for original verification |
| Operations | Structured logs, bounded status snapshots, LiveView dashboard, selected usage counters | No demonstrated retained cross-session trace backend, experiments store or acceptance of the complete V1-OPS-01 contract |
| Instrumentation | No OpenTelemetry exporter/SDK or Arize dependencies in the inspected Elixir dependency baseline | Export performance, gRPC compatibility and live Codex coverage are **untested** |

Relevant implementations include `elixir/lib/symphony_elixir/work_control/`, `dependency/graph.ex`, `source_control/`, `agent_runtime.ex`, `agent_runner.ex`, `codex/app_server.ex`, `orchestrator.ex`, `elixir/docs/logging.md`, and `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`. Reinspect at the future candidate SHA. Test file existence alone is not proof of live behaviour.

## 3. Product capability and limitations (Phoenix v21.0.0 research)

Phoenix is a self-hostable AI-oriented observability/evaluation service with inbound OTLP trace ingestion, trace/span exploration, versioned datasets, evaluations, experiments and prompt tooling. Phoenix does not automatically instrument the Symphony Elixir host or Codex App Server.

- **Documented and source-supported:** OTLP/HTTP ingestion, stored/queryable traces, datasets and experiments, prompt-management interfaces, SQLite for small/local use, PostgreSQL for production-class use.
- **Plausible, not tested in Symphony:** Direct Elixir/Erlang OpenTelemetry-to-Phoenix OTLP/HTTP export. Erlang exporter and vendor receiver support compatible general protocols; an actual handshake is required.
- **Not established:** Complete model-call/subagent tracing; private reasoning; token-level provider internals; Phoenix’s general forwarding of arbitrary inbound traces; Phoenix receiver gRPC compatibility with the selected client/runtime; actual resources/overhead/diagnostic gain; production HA and specific backend minima.
- **Important distinction:** The Phoenix framework used by Symphony's Elixir/LiveView stack is unrelated to **Arize Phoenix**.
- **Security/licence:** Pinned Phoenix core is Elastic License 2.0; package licences vary. The evaluated v21 release includes listen-address-dependent authentication defaults, a potential default initial admin password, optional stored-credential secret protection, outbound telemetry/external-resource controls, and additional assistant/MCP/OAuth surfaces. Version-pinned sources must be checked again before any future build. Vendor material describes a single instance as single-tenant; project labels are not isolation boundaries. Trace retention defaults require explicit review.

Primary public evidence (version must be reverified):
- [Phoenix v21 release](https://github.com/Arize-ai/phoenix/releases/tag/arize-phoenix-v21.0.0)
- [Pinned v21 migration/configuration guidance](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v21.0.0/MIGRATION.md)
- [Pinned core license](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v21.0.0/LICENSE)
- [Official tracing documentation](https://arize.com/docs/phoenix/tracing/concepts-tracing/how-tracing-works)
- [Official datasets and experiments](https://arize.com/docs/phoenix/datasets-and-experiments/concepts-datasets)
- [Official retention guidance](https://arize.com/docs/phoenix/settings/data-retention)
- [OpenTelemetry Erlang exporters](https://opentelemetry.io/docs/languages/erlang/exporters/)

## 4. Alternatives and baseline decision

Compare all future candidates against the **same defined requirement**, not feature counts:

| Option | Future role | Current disposition |
|---|---|---|
| A. Existing logs/dashboard only | Preserve existing bounded diagnostics and low operating burden | **Preferred now** |
| B. Backend-neutral OpenTelemetry, no committed receiver | Standardize approved emitted observations; keep vendor choices replaceable | **Preferred first investigation if a trace requirement arises** |
| C. Self-hosted Phoenix | Optional trace search, AI datasets and experiments behind a read-only boundary | Deferred; requires measured value |
| D. OTel + Tempo/Jaeger; compare Langfuse independently | Distributed trace-only vs AI-evaluation alternatives | Reassess once requirement defined; not functionally identical |
| E. Phoenix for evaluation datasets only | Frozen reviewer/model experiments without runtime trace export | Future Programme E question only |

At the original evaluation, indicative weighted fit scores were A=3.95/5, B=3.90/5, C=3.30/5, D=3.45/5, E=3.30/5. These were **subjective current-fit judgements**, not measurements; no scoring can override a security or authority disqualifier. A future comparison must rescore against then-authorized requirements, cost, available products and threat model.

**Recommendation:** never make Phoenix a prerequisite to H-100, H-110, V1-OPS-01, acceptance gates, or the authority kernel.

## 5. Future eligibility and admission gates (all must pass)

A Phoenix-related proposal cannot advance from `deferred` into an execution-ready scope until:

**G01 — Authorization:** A current signed/recorded Master Governance decision names a future programme, responsible owner, bounded permitted actions and explicit POC scope. A GitHub issue, research-spec merge or H-100 acceptance is insufficient.

**G02 — Demonstrated requirement:** An operator-owned diagnostic/evaluation problem is precisely defined, with baseline failure rate, time-to-diagnosis, reviewer accuracy or other measurable criterion and documented insufficiency of simpler tools.

**G03 — Identity foundation:** Required execution, candidate, review, CI and evidence identities have accepted contracts; future joined observability facts cannot impersonate authority records.

**G04 — Privacy/security:** Data owner approves an allowlist, threat model, on-host redaction, authenticated private service, egress denial, retention/deletion, incident response and verified no-secret-canary leakage.

**G05 — Licensing/commercial:** Exact package and transitive licences verified against intended internal or future commercial use; qualified legal review addresses Elastic License 2.0 where necessary.

**G06 — Test design:** Independent baseline/experimental protocol is preregistered, with success/failure thresholds, representative synthetic fixtures, isolated execution and zero unapproved model/API spend.

**G07 — Alternatives:** Side-by-side value/cost comparison against existing logging, backend-neutral OTel, Tempo/Jaeger and appropriate AI-evaluation alternatives; no technology-selection bias.

**G08 — Separate execution decision:** Authorized POC only after G01-G07; production integration requires a later distinct authorization following measured POC and independent review.

Missing, conflicting or stale evidence means **remain deferred / do not dispatch**.

## 6. Hard authority and data boundaries (conditional design MUSTs)

The following constraints apply to any future authorised design:

1. **Symphony is the sole control/authority kernel.** Plane supplies tracker observations; GitHub supplies source-control/CI/merge facts. Phoenix is a **replaceable, non-authoritative diagnostic/evaluation receiver**.
2. Phoenix shall have **no write path** to Symphony lifecycle, Plane work-control state, source repositories, GitHub PRs/CI/merge, runtime isolation controls, policy, prompt source-of-truth or operator approvals.
3. Phoenix trace IDs, annotations, prompt versions, scores and experiment records are never guards for `ready_to_merge`, `done`, dispatch admission, retry rearm, candidate verification or completion proof.
4. Lifecycle, dependency, candidate, approval, review and CI guard decisions remain in Symphony's independent trusted contracts; any missing or stale authority evidence fails **closed** under existing policy.
5. Optional diagnostics may drop/disable on collector failure but **must never cause an authoritative transition, hide a safety violation, release a runtime fence, grant new retries or block required safety cleanup**.
6. No speculative capture of unobservable Codex internals; all span sources and coverage limits are declared.
7. No raw source code, prompts, complete model context, transcripts, tool arguments/results, workspace paths, environment values, secrets, personal/customer data, raw exception payloads or reviewer reasoning in telemetry. Restrict export to explicitly permitted, pre-redacted fields.
8. Backend-neutral OTLP event contracts are preferable to hard coupling to the Phoenix client, datastore or API; an OpenTelemetry Collector is optional, not mandatory.
9. Research evidence remains marked as source observation, inference, proposal or unverified. No mock-only test may be represented as production proof.
10. No automated learning, prompt promotion, evaluator-as-gate, hidden external inference, or Phoenix MCP access without a separately authorized design that preserves all existing authority boundaries.

A violation of any hard invariant is a **disqualifier**, not a low point in a weighted feature comparison.

## 7. Proposed one-way architecture (not implemented)

```text
Plane observations ──> Symphony Orchestrator / authority guards ──> Runtime / Codex
                              │                            │
GitHub candidate+CI evidence ─┘                            │
                              │                            │
                     approved host-owned event facts <─────┘
                              │
                  application-side allowlist + redaction
                              │
                  bounded async OTel span exporter
                              │  OTLP HTTP (future test)
                 replaceable receiver (Phoenix / Tempo / Jaeger)
                              │
                    read-only diagnostic/query UI

NO BACK-EDGE to Symphony/Plane/GitHub authority.
```

Keep original authority IDs and proof records in their source systems. An opaque correlation token may join spans to authority records but must not prove a transition or substitute for a hash/signature.

### 7.1 Minimal prospective event contract (allowlisted)

Each emitted event, if authorised, may include: event schema version, approved operation/role enum, sanitized event class/status, event timestamp, bounded duration, trace/span/parent IDs, opaque Symphony project/work-item/attempt/correction-cycle identifiers, and approved privacy-classified error category. CI and candidate joins may use **opaque reference keys**; exact commit SHAs only if approved by the data owner. Explicitly differentiate observed vs derived timing and “absent/unobservable” vs zero.

Trace span candidates, depending on actually observed App Server events: host attempt start/end; Codex session/turn boundaries; selected tool/approval events; host runtime error; review/correction cycle. Model-call details and nested subagent structure must remain `unknown` until actual event semantics and propagation are proven.

Schema versioning must specify: producer version, field allowlist version, unit/time conventions, source authority, redaction policy revision and stable join identity. Use strict reject-on-unknown-field validation before export.

## 8. Telemetry exporter lifecycle — conditional policy

**Separate lifecycle:** The exporter below is not a Symphony work-item or execution lifecycle. It cannot change the canonical `WorkflowLifecycle` contract.

| State | Allowed next state(s) | Entry / transition guard | Side effects | Terminal? |
|---|---|---|---|---|
| `disabled` | `ready` | Explicit separate authorization; approved configuration, exact versions, allowlist, isolation and secrets | Create only optional diagnostic worker | No; remains disabled on unmet guard |
| `ready` | `buffered`, `rejected` | Approved event source/schema; valid safe fields | Prepare immutable sanitized record or reject | No |
| `buffered` | `delivered`, `retry_wait`, `dropped` | Valid event, bounded queue and deadline | Async send; local bounded counters | No |
| `retry_wait` | `delivered`, `retry_wait`, `dropped` | Retry budget and total deadline remain | Bounded jittered retry; preserve event identity | No |
| `delivered` | — | Transport acknowledgment received | Diagnostic result only; **not** durable-storage or authority proof | Yes |
| `rejected` | — | Payload/field/config invalid | Safe local diagnostic; no raw fallback | Yes |
| `dropped` | — | Queue, timeout, receiver error, or retry budget exhausted | Local drop counter; no lifecycle effect | Yes |

Owners: operator authorizes `disabled→ready`; host telemetry adapter owns `ready→buffered/rejected`; bounded export worker owns delivery/retry/drop. No arbitrary agent is allowed to operate the exporter authority controls. New event identity is stable across retries; no backend deduplication guarantee is assumed. Crash or queue loss can drop **diagnostic** data but must not affect safety ledger, authoritative candidate review or retry budgets.

**Specific receiver failure rules:** unreachable/slow/error → bounded async retry then drop; incompatible protocol → disable exporter; malformed/unapproved event → reject before send; unexpected egress/secret leak → stop exporter and initiate incident controls. Host safety failures remain fail-closed even if diagnostic export is unavailable.

## 9. Security, tenancy, operation and licensing requirements (future only)

Before any service is started:
- Pin image digest, release tag/commit, dependency and configuration source; independently verify availability of all named v21 flags on the **then-selected** release. Never rely on mutable “latest”.
- Set explicit authentication and unpredictable initial admin password; set distinct secret for protected stored credentials; create minimal, expiring service access keys. Verify actual auth behaviour, not merely environment names.
- Bind to loopback or a separately approved isolated network; use TLS for cross-host traffic; deny external egress at network level and inspect egress logs.
- Disable unneeded product analytics, external resource fetching, agent assistant, MCP and OAuth surfaces; verify actual release settings and all outbound traffic.
- Treat Phoenix projects as labels rather than tenant/access boundaries; for real isolation require independently approved instance/database/access design.
- Configure finite retention, deletion, backups/restores, encryption, access audit and incident response with a named operator. Document default indefinite retention and actual storage-growth tests.
- Prohibit source/prompt/tool contents and secret-bearing fields **at the host before export**; do not rely on receiver-side redaction. Include synthetic secret canary tests.
- Assess licence: Phoenix core ELv2; package-level licenses may differ. Internal-use expectations do not resolve future commercial managed-service limits; obtain qualified review before commercialising.
- Establish capacity budget, CPU/RAM/storage consumption, upgrade/rollback procedure, DB migrations, orphan-data cleanup, and on-call responsibility. No invented resource minima or prices.
- Preserve US$0 incremental model/API spend unless a separate decision explicitly changes the bound.

## 10. Evaluation independence and experiment custody (future Programme E only)

A dataset UI does not establish valid experiments. A legitimate future reviewer/model benchmark must have:
- independent, concealed ground-truth/oracle custody; no benchmark contamination by agent prompts or retrieval;
- preregistered tasks, mutation/control pairs, sample definition and exclusion criteria;
- explicit precision/recall, false-acceptance, false-rejection and reviewer-disagreement metrics as appropriate;
- frozen dataset/content hashes, evaluator hashes, model/prompt settings, run IDs, candidate IDs, attempt IDs and adjudicator provenance;
- independent adjudication of disputed cases with uncertainty surfaced;
- protection against cherry-picked retries and leakage between training and testing;
- no authority promotion from an experiment outcome or LLM-as-judge score.

External or paid evaluators are not authorised by this record. Reuse existing Symphony benchmark/evidence contracts rather than redefining completion proof in an experiment product.

## 11. Bounded POC contract (proposal, **not authorized**)

**Phase 1 — isolated synthetic transport and usefulness proof:** disposable Linux environment, pinned Phoenix release, local SQLite, synthetic Elixir OTel sender, no real Symphony/Codex/Plane/GitHub live paths, no production source/prompt/credential/data. Cap proposed: 4 vCPU, 8 GiB RAM, 20 GiB encrypted temporary disk, one receiver and one sender, zero cloud/model/API spend. Obtain image in a separately permitted way before denying external egress.

Test: 100 valid synthetic spans with known parent/child relationships; five fixed failure scenarios; available/offline/slow/error/malformed receiver; token/secret canaries; telemetry egress and deletion; comparison with an equivalent baseline log view by a blinded independent reviewer.

Provisional Phase-1 criteria:
- at least 99/100 valid spans accepted and all expected parent/child joins inspectable;
- at least 4/5 fixed scenarios correctly diagnosed; at least 20% median diagnosis-time improvement **or** one otherwise unsolvable baseline scenario;
- no unapproved attribute, canary, external egress, model/API call, unauthorized authentication bypass or resource-cap breach.

**Phase 2 — actual host noninterference proof (requires a second, separate authorisation):** an isolated disposable checkout of the exact reviewed Symphony SHA with test-only telemetry seam, synthetic Plane observations, fake AgentRuntime and App Server, and **no** production infrastructure. Compare full host-side lifecycle/attempt/retry/review/candidate/evidence/merge state sequences with receiver healthy, offline, delayed, erroring and malformed. Require identical authoritative outcomes. Proposed host elapsed-time overhead cap: ≤5% at matched synthetic event volume, measured and qualified; exporter failure must never block governed work or safety cleanup. Phase 1 alone **cannot** prove this.

**Stop conditions:** any unapproved data/export/egress, scope expansion, mutation authority, safety-state difference, hidden paid calls, broken isolation, unresolved licence/configuration mismatch, unreproducible evidence, or failure to demonstrate useful diagnostic gain.

**Cleanup:** remove service, process, listeners, volumes, temp code, test credentials and network allowances; retain only sanitized evidence and measurements. A POC success is **not** production integration approval.

## 12. Decision after a future experiment

An independently reviewed decision packet must contain:
1. Approved initiating requirement and programme authority reference.
2. Current Symphony exact candidate SHA/tree and current vendor version/digest.
3. Executed protocol/host-path test matrix, raw **sanitized** evidence hashes and measured results.
4. Failures and incomplete criteria; absence of evidence never scored as pass.
5. Threat model, redaction/egress/auth/retention validation and legal assessment.
6. Baseline-versus-Phoenix diagnostic utility and five-year maintenance/TCO rationale.
7. Independence checks and explicit disqualifier review.
8. One of **REJECT**, **CONTINUE DEFERRED**, **AUTHORIZE FOLLOW-ON DESIGN REQUEST**, or **RECOMMEND SEPARATE IMPLEMENTATION AUTHORIZATION**.

Only a separate Master Governance decision may allocate implementation authority. No decision can be derived from this document's presence on `main`.

## 13. Provenance and limitations of the original assessment

The following five research artifacts were supplied as the source assessment set. Their SHA-256 digests fix the **received bytes** as of 2026-11-03; they are **not** asserted to have been committed to Symphony or independently runtime-validated. This specification is self-contained on required controls, while those files preserve more detailed comparisons and claims.

| Assessment artifact | SHA-256 |
|---|---|
| `ARIZE_PHOENIX_EXECUTIVE_ASSESSMENT.md` | `223903aa6a3accaeba92896f68d51897a0397ce57685ba5ef1d748d1048942fe` |
| `SYMPHONY_PHOENIX_GAP_MATRIX.md` | `371d459fb31d710877a3a5fb22cbf74ec123828df7ad41ded99f78e4f523ee1e` |
| `PHOENIX_INTEGRATION_ARCHITECTURE.md` | `c1cd69110fed8b1b9755054a4c308b9a8215a8361cb487d62d8761190c47c9a6` |
| `PHOENIX_POC_PROPOSAL.md` | `c83fb96ab9bda8dc17159a4f502082f1dccbcaa55cb9c114a6b4b34376a6679d` |
| `SOURCE_AND_EVIDENCE_REGISTER.md` | `7cbc5d64decb13d80eda0027938f443b6d1a3bbafcdba27c0cb4507f29e3feb6` |

Research classes used by the source register: repository authority record; static implementation; vendor documentation; pinned vendor source/release; bounded live-provider observation; inference/estimate; not verified. The source evaluation ran **no Symphony tests, Phoenix installation, POC, runtime session, service, telemetry export or paid API calls**. Actual Codex event coverage, host integration overhead, gRPC receiver interoperability, runtime scale and diagnostic improvement remain unknown.

## 14. Independent review checklist for this document-only PR

Reviewers must independently verify:
- [ ] Exact PR diff contains **only** deferred research/spec/issue-draft documentation; no app code, dependencies, CI, gates or configuration.
- [ ] No conflict with current V4.1 authority hierarchy, H-100 scope or Gate 2 activity.
- [ ] No text accidentally grants POC, spending, data export, service or merge authority.
- [ ] Research baseline IDs, exact vendor pin, relevant code/module references and supplied artifact digests are correct.
- [ ] Every hard invariant, lifecycle transition, guard, owner, side effect, terminal state and POC stop condition is explicit.
- [ ] Safety fail-closed remains distinct from optional telemetry export failure behaviour.
- [ ] No unverified runtime capability, minimum resource requirement or measured benefit is promoted to fact.
- [ ] No new obligation to complete this research before existing authorised V4.1 phases.
- [ ] All required exact-head CI and PR template checks succeed **before any merge recommendation**; CI success is not itself acceptance/authority.

**Document acceptance:** A reviewer may accept this as an accurate *deferred reference*, but doing so does not accept Phoenix as an architectural dependency, authorize its implementation, or modify the governing roadmap.

## 15. Amendment log (append-only)

| Date | Version | Change | Authority effect |
|---|---|---|---|
| 2026-11-03 | 1.0.0 | Initial frozen research and conditional design baseline from the five-file Phoenix assessment | **NONE** — deferred, non-authoritative, no runtime or programme action |

No later amendment exists at initial publication.
