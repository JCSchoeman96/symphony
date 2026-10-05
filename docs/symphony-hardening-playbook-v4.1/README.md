# V4.1 hardening authority package

This directory contains the accepted V4.1 future-roadmap authority, the current governance index, reconciliation records, and supporting evidence. It preserves the accepted V3 implementation history.

## Authority index

- [V4.1 master roadmap](V4_1_MASTER_ROADMAP.md) records the accepted normative V4.1 future-roadmap authority.
- [Hardening status ledger](HARDENING_STATUS_LEDGER.md) is the concise current phase and authorization index.
- [Historical governance reconciliation](GOVERNANCE_RECONCILIATION.md) records the reconstructed V4.1-000 through H-060A history, its evidence sources, and provenance gaps.
- [2026-10-05 governance reconciliation](GOVERNANCE_RECONCILIATION_2026-10-05.md) reconciles H-070B through H-080B against exact Git/CI facts and current external Master-governance decisions.
- [V3 accepted authority index](V3_ACCEPTED_AUTHORITY.md) links the immutable accepted H-010, H-020, and H-030 authority.
- [P-000 feasibility evidence](P-000_PLANE_PROVIDER_FEASIBILITY_EVIDENCE.md) records the accepted Plane provider feasibility assessment.

## Current reconciled programme state

```text
CURRENT_ACCEPTED_PHASE = H-080B
CURRENT_ACCEPTED_BASELINE_SHA = 0bdd3960947bb2bafd34a7eb92e970eaae07a82a
CURRENT_ACCEPTED_BASELINE_TREE = 1cbb9dfa6a74aaf868ddf6e55b3e54232b4f6b60
H-080C = NOT AUTHORIZED
```

The current follow-on authorization is governance/documentation canonicalization only. Do not infer H-080C authorization from H-080B acceptance. Future implementation authorization must follow the canonically adopted Unified Execution Roadmap and its prerequisite gates.

## Authority boundaries

- Plane is the selected V1 primary work-control provider.
- Symphony remains the autonomous authority kernel.
- GitHub is the authority for source-control, pull-request, CI, commit/tree, and merge facts.
- The runtime performs bounded computation under Symphony's authority.
- Provider observations do not establish lifecycle authority by themselves.
- Merge is not acceptance; acceptance requires the applicable governance decision plus required post-merge verification.
- Historical PR text is preserved as historical state and does not silently override a later explicit reconciliation decision.

The V4.1 Master Roadmap defines normative future phase requirements. Current accepted phase and permission to begin work belong in the hardening ledger. Reconciliation documents explain how stale historical records were resolved; they do not rewrite the history that produced the discrepancy.
