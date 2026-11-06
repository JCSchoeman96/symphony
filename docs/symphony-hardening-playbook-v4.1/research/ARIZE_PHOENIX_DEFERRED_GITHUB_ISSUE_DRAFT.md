# GitHub issue draft — Arize Phoenix (create only if Issues is enabled)

**Proposed title:** `[DEFERRED / NO DISPATCH] Arize Phoenix observability and evaluation adoption decision`

> **NOT AN AUTHORISED IMPLEMENTATION ISSUE.** This is retained because the GitHub API returned `410 Issues has been disabled in this repository` on 2026-11-03. Do not enable Issues, create this issue, or assign implementation without repository-owner approval.

## Purpose and status

Track a possible future decision about Arize Phoenix tracing/evaluation (or a backend-neutral OpenTelemetry alternative) for Symphony. Independent assessment decision: **B. DEFER**.

No service, POC, installation, integration, model/API spend, agent dispatch, telemetry collection/export, source-control mutation, or programme scope expansion is authorised by the issue, spec or document-only PR. H-100 acceptance by itself does not activate this issue.

## Locked reference

- Spec: [SYM-OBS-PHX-001 v1.0.0](ARIZE_PHOENIX_DEFERRED_INTEGRATION_SPEC_v1.0.0.md)
- Symphony assessed: `main` at `0c53c732bbf68641482741c98afb25e073721ad9` (2026-11-03).
- Arize Phoenix assessed: `arize-phoenix-v21.0.0` at `6359d6388815d56f7795a3a8cd11e89a71793e01`.
- Normative authority: V4.1 Master Roadmap and current Master Governance decisions. The research specification does not supersede either.

## Preconditions for future reassessment (not executable work)

- [ ] A separately accepted Master Governance decision authorises a named Programme F tracing need or Programme E evaluation need and bounds the action.
- [ ] Accepted identity/candidate/evidence/data-custody prerequisites are established.
- [ ] An actual measurable shortfall in existing logs/evidence is demonstrated with a baseline.
- [ ] Backend-neutral OpenTelemetry, continued native logs, distributed tracing alternatives and AI-evaluation alternatives are compared.
- [ ] Independent security/privacy, network egress, access, retention and licensing reviews pass.
- [ ] A reproducible, zero-unapproved-spend, synthetic isolated experiment is approved **separately**.
- [ ] A second, separately approved host-path experiment proves telemetry cannot alter authoritative Symphony decisions.
- [ ] A new, explicit governance decision is recorded before any production integration.

## Hard constraints

- Symphony is sole authority kernel; Phoenix is at most a replaceable diagnostic/evaluation receiver.
- No Phoenix / evaluator / trace / prompt / AI score can transition work items, permit merges, alter runtime fencing, change retry limits or replace exact-candidate proof.
- No confidential code, full prompts, tool payloads, credentials or customer data may leave the authorised host boundary.
- Telemetry can drop safely on receiver outage; authoritative safety checks remain fail-closed.
- Do not claim private reasoning visibility, comprehensive Codex model-call/subagent traces, measured diagnostic improvement or production compatibility without executed evidence.

## Closure

Keep deferred until an authorised decision **rejects** the idea with rationale or transfers it to newly authorised, scoped work. Merging a research-only specification must not mark integration as completed.

**Action now:** documentation review only. No execution, no POC and no issue dispatch.
