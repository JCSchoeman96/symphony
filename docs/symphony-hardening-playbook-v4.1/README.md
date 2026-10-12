# V4.1 hardening authority package

This directory contains the accepted V4.1 future-roadmap authority, the current governance index, reconciliation records, and supporting evidence. It preserves the accepted V3 implementation history.

## Authority index

- [V4.1 master roadmap](V4_1_MASTER_ROADMAP.md) records the accepted normative V4.1 future-roadmap authority.
- [Hardening status ledger](HARDENING_STATUS_LEDGER.md) is the concise current phase and authorization index.
- [Governance projection](V4_1_GOVERNANCE_PROJECTION.json) is a derivative machine snapshot of accepted human governance.
- [PRE-080C-03 reconciliation](PRE-080C-03_GOVERNANCE_RECONCILIATION.md) preserves its candidate-era record and the post-acceptance reconciliation.
- [H-080C governance materialization](H-080C_GOVERNANCE_MATERIALIZATION.md) records the PRE-H080C acceptance, the separate H-080C authorization, and their distinct authority references.
- [Historical governance reconciliation](GOVERNANCE_RECONCILIATION.md) records the reconstructed V4.1-000 through H-060A history, its evidence sources, and provenance gaps.
- [2026-10-05 governance reconciliation](GOVERNANCE_RECONCILIATION_2026-10-05.md) reconciles H-070B through H-080B against exact Git/CI facts and preserves the 2026-10-07 Master Governance adjudication that establishes their current formal acceptance states.
- [V3 accepted authority index](V3_ACCEPTED_AUTHORITY.md) links the immutable accepted H-010, H-020, and H-030 authority.
- [P-000 feasibility evidence](P-000_PLANE_PROVIDER_FEASIBILITY_EVIDENCE.md) records the accepted Plane provider feasibility assessment.
- [Superpowers methodology classification](../superpowers/README.md) explains the role and limits of planning/specification artifacts.

## Current programme state and accepted baseline

```text
LATEST_ACCEPTED_V4.1_PHASE = H-080B
LATEST_ACCEPTED_PREREQUISITE = PRE-H080C
ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA = 81be62410f5ab6c5ac9c7f6aad13e15cd4b8363b
ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE = 272ac528e83db332060c1b17cc89753021c7cee9
PRE-080C-01 = ACCEPTED effective 2026-10-09
PRE-080C-02 = ACCEPTED; outcome LIMIT_FOUND
PRE-080C-03 = ACCEPTED effective 2026-10-11
PRE-H080C = ACCEPTED
H-080C = AUTHORIZED / ACTIVE / NOT ACCEPTED
```

PR #40's merge at `81be62410f5ab6c5ac9c7f6aad13e15cd4b8363b` / tree `272ac528e83db332060c1b17cc89753021c7cee9` is the accepted baseline for the PRE-H080C acceptance and H-080C authorization decision. Master Governance accepted PRE-H080C and authorized H-080C under `MG-2026-10-12-H080C-AUTH-01`. H-080C is active and not accepted. See the [materialization record](H-080C_GOVERNANCE_MATERIALIZATION.md) for the exact scope and authority boundary.

The H-070B, REM-HI21, H-I20 remediation, H-080A, and H-080B acceptance states above are current decisions effective 2026-10-07. They are not backdated to the historical merge events. PRE-080C-01 was accepted effective 2026-10-09 after Master Governance adjudication, merge `09b72591d33fbe88243bceb584f85fca1f6fc819`, and successful protected-main `make-all` run `37904661908`.

The 2026-10-05 governance reconciliation records the earlier history through H-080B; it does not contain the 2026-10-09 PRE-080C-01 adjudication. The current repository record for that adjudication is [PRE-080C-01 production evidence](PRE-080C-01_PRODUCTION_EVIDENCE_ACQUISITION.md), this [hardening status ledger](HARDENING_STATUS_LEDGER.md), and the current-status section of the Unified Execution Roadmap.

## Authority boundaries

- Plane is the selected V1 primary work-control provider.
- Symphony remains the autonomous authority kernel.
- GitHub is the authority for source-control, pull-request, CI, commit/tree, and merge facts.
- The runtime performs bounded computation under Symphony's authority.
- Provider observations do not establish lifecycle authority by themselves.
- Merge is not acceptance; acceptance requires the applicable governance decision plus required post-merge verification.
- The governance projection is a derivative snapshot of human authority, not programme authority.
- Historical PR text is preserved as historical state and does not silently override a later explicit reconciliation decision.

PR #26 remains open and unmerged as superseded historical characterization material. The earlier instruction not to merge or close it during PRE-080C-03 is historical; this status sync does not authorize action on PR #26. PR #31's pre-merge candidate text, later GitHub merge, and subsequent Master Governance acceptance of H-080B remain distinct facts. PR #37's unaccepted candidate evidence, GitHub merge, and later PRE-080C-02 acceptance with `LIMIT_FOUND` also remain distinct facts. PR #38's candidate-era statements remain historical; its merge and the later Master Governance acceptance are separate facts. Historical PR bodies and evidence are not rewritten.

The V4.1 Master Roadmap defines normative future phase requirements. Current accepted phase and permission to begin work belong in the hardening ledger. Reconciliation documents explain how stale historical records were resolved; they do not rewrite the history that produced the discrepancy.

<!-- BEGIN SYMPHONY_GOVERNANCE_STATUS_V1 -->
GOVERNANCE_PROJECTION_PATH=docs/symphony-hardening-playbook-v4.1/V4_1_GOVERNANCE_PROJECTION.json
GOVERNING_ROADMAP_ID=docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md
GOVERNING_ROADMAP_VERSION=V4.1
GOVERNING_ROADMAP_BLOB_SHA=4b0528bdc0647d889b42ebc478081d5b873898fe
ACCEPTED_PROTECTED_MAIN_AT_DECISION_SHA=81be62410f5ab6c5ac9c7f6aad13e15cd4b8363b
ACCEPTED_PROTECTED_MAIN_AT_DECISION_TREE=272ac528e83db332060c1b17cc89753021c7cee9
CURRENT_ACCEPTED_PHASE=H-080B
CURRENT_ACCEPTED_PREREQUISITE=PRE-H080C
PRE_080C_02_OUTCOME=LIMIT_FOUND
CURRENTLY_AUTHORIZED_WORK=H-080C
CURRENTLY_AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
PRE_H080C=ACCEPTED
H_080C=AUTHORIZED_ACTIVE_NOT_ACCEPTED
NEXT_GOVERNANCE_STEP=H-090
NEXT_AUTHORIZED_PHASE=NONE
DECISION_AUTHORITY=Master Governance
DECISION_REFERENCE=MG-2026-10-12-H080C-AUTH-01
DECISION_TIMESTAMP=2026-10-12T17:54:02+02:00
KNOWN_UNRESOLVED_GOVERNANCE_CONDITIONS=H080C_NOT_ACCEPTED
<!-- END SYMPHONY_GOVERNANCE_STATUS_V1 -->
