# V4.1 hardening authority package

This directory contains the accepted V4.1 future-roadmap authority, the current governance index, reconciliation records, and supporting evidence. It preserves the accepted V3 implementation history.

## Authority index

- [V4.1 master roadmap](V4_1_MASTER_ROADMAP.md) records the accepted normative V4.1 future-roadmap authority.
- [Hardening status ledger](HARDENING_STATUS_LEDGER.md) is the concise current phase and authorization index.
- [Governance projection](V4_1_GOVERNANCE_PROJECTION.json) is a derivative machine snapshot of accepted human governance.
- [PRE-080C-03 reconciliation](PRE-080C-03_GOVERNANCE_RECONCILIATION.md) records the current bounded governance and documentation reconciliation.
- [Historical governance reconciliation](GOVERNANCE_RECONCILIATION.md) records the reconstructed V4.1-000 through H-060A history, its evidence sources, and provenance gaps.
- [2026-10-05 governance reconciliation](GOVERNANCE_RECONCILIATION_2026-10-05.md) reconciles H-070B through H-080B against exact Git/CI facts and preserves the 2026-10-07 Master Governance adjudication that establishes their current formal acceptance states.
- [V3 accepted authority index](V3_ACCEPTED_AUTHORITY.md) links the immutable accepted H-010, H-020, and H-030 authority.
- [P-000 feasibility evidence](P-000_PLANE_PROVIDER_FEASIBILITY_EVIDENCE.md) records the accepted Plane provider feasibility assessment.
- [Superpowers methodology classification](../superpowers/README.md) explains the role and limits of planning/specification artifacts.

## Current programme state and accepted baseline

```text
LATEST_ACCEPTED_V4.1_PHASE = H-080B
LATEST_ACCEPTED_PREREQUISITE = PRE-080C-02
ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA = 0640bf1135f8b5000ea29518c2c456272379e9c6
ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE = 5c6f10cc88c41f395837a930fb7ea20e0bdae0cc
PRE-080C-01 = ACCEPTED effective 2026-10-09
PRE-080C-02 = ACCEPTED; outcome LIMIT_FOUND
PRE-080C-03 = AUTHORIZED / ACTIVE / NOT ACCEPTED
PRE-H080C = NOT REACHED
H-080C = NOT AUTHORIZED
```

The accepted protected-main baseline for the PRE-080C-02 decision is PR #37 at `0640bf1135f8b5000ea29518c2c456272379e9c6` / tree `5c6f10cc88c41f395837a930fb7ea20e0bdae0cc`. Master Governance accepted PRE-080C-02 with outcome `LIMIT_FOUND`. PRE-080C-03 is the currently authorized implementation work. PRE-H080C remains the next governance gate, not authorized implementation. H-080C remains unauthorized until that gate and separate explicit authorization.

The H-070B, REM-HI21, H-I20 remediation, H-080A, and H-080B acceptance states above are current decisions effective 2026-10-07. They are not backdated to the historical merge events. PRE-080C-01 was accepted effective 2026-10-09 after Master Governance adjudication, merge `09b72591d33fbe88243bceb584f85fca1f6fc819`, and successful protected-main `make-all` run `37904661908`.

The 2026-10-05 governance reconciliation records the earlier history through H-080B; it does not contain the 2026-10-09 PRE-080C-01 adjudication. The current repository record for that adjudication is [PRE-080C-01 production evidence](PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md), this [hardening status ledger](HARDENING_STATUS_LEDGER.md), and the current-status section of the Unified Execution Roadmap.

## Authority boundaries

- Plane is the selected V1 primary work-control provider.
- Symphony remains the autonomous authority kernel.
- GitHub is the authority for source-control, pull-request, CI, commit/tree, and merge facts.
- The runtime performs bounded computation under Symphony's authority.
- Provider observations do not establish lifecycle authority by themselves.
- Merge is not acceptance; acceptance requires the applicable governance decision plus required post-merge verification.
- Historical PR text is preserved as historical state and does not silently override a later explicit reconciliation decision.

PR #26 remains open and unmerged as superseded historical characterization material. Do not merge or close it during PRE-080C-03. PR #31's pre-merge candidate text, later GitHub merge, and subsequent Master Governance acceptance of H-080B remain distinct facts. PR #37's unaccepted candidate evidence, GitHub merge, and later PRE-080C-02 acceptance with `LIMIT_FOUND` also remain distinct facts. Historical PR bodies and evidence are not rewritten.

The V4.1 Master Roadmap defines normative future phase requirements. Current accepted phase and permission to begin work belong in the hardening ledger. Reconciliation documents explain how stale historical records were resolved; they do not rewrite the history that produced the discrepancy.

<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->
GOVERNANCE_PROJECTION_PATH=docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json
GOVERNING_ROADMAP_ID=docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
GOVERNING_ROADMAP_VERSION=V4.1
GOVERNING_ROADMAP_BLOB_SHA=4b0528bdc0647d889b42ebc478081d5b873898fe
ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA=0640bf1135f8b5000ea29518c2c456272379e9c6
ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE=5c6f10cc88c41f395837a930fb7ea20e0bdae0cc
CURRENT_ACCEPTED_PHASE=H-080B
CURRENT_ACCEPTED_PREREQUISITE=PRE-080C-02
PRE_080C_02_OUTCOME=LIMIT_FOUND
CURRENTLY_AUTHORIZED_WORK=PRE-080C-03
CURRENTLY_AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
PRE_H080C=NOT_REACHED
H_080C=NOT_AUTHORIZED
NEXT_GOVERNANCE_STEP=PRE-H080C
NEXT_AUTHORIZED_PHASE=NONE
DECISION_AUTHORITY=Master Governance
DECISION_REFERENCE=MG-2026-10-10-PRE-080C-03-AUTH-01
DECISION_TIMESTAMP=2026-10-10T16:35:00+02:00
KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=PRE080C02_LIMIT_FOUND_REQUIRES_PRE_H080C_ADJUDICATION,PRE080C03_NOT_ACCEPTED,PRE_H080C_NOT_REACHED,H080C_NOT_AUTHORIZED
<!-- END SYMPHONY_GOVERNANCE_STATUS_V1 -->
