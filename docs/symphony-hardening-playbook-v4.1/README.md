# V4.1 hardening authority package

This directory contains the accepted V4.1 future-roadmap authority, the current governance index, reconciliation records, and supporting evidence. It preserves the accepted V3 implementation history.

## Authority index

- [V4.1 master roadmap](V4_1_MASTER_ROADMAP.md) records the accepted normative V4.1 future-roadmap authority.
- [Hardening status ledger](HARDENING_STATUS_LEDGER.md) is the concise current phase and authorization index.
- [Historical governance reconciliation](GOVERNANCE_RECONCILIATION.md) records the reconstructed V4.1-000 through H-060A history, its evidence sources, and provenance gaps.
- [2026-10-05 governance reconciliation](GOVERNANCE_RECONCILIATION_2026-10-05.md) reconciles H-070B through H-080B against exact Git/CI facts and preserves the 2026-10-07 Master Governance adjudication that establishes their current formal acceptance states.
- [V3 accepted authority index](V3_ACCEPTED_AUTHORITY.md) links the immutable accepted H-010, H-020, and H-030 authority.
- [P-000 feasibility evidence](P-000_PLANE_PROVIDER_FEASIBILITY_EVIDENCE.md) records the accepted Plane provider feasibility assessment.

## Reconciled programme state and GOV-STATE-SYNC input baseline

```text
LATEST_ACCEPTED_V4.1_PHASE = H-080B
LATEST_ACCEPTED_PREREQUISITE = PRE-080C-01
GOV_STATE_SYNC_INPUT_BASELINE_SHA = 84a2fbfdaece47d5dd87ca37c2e25e85afe39880
GOV_STATE_SYNC_INPUT_BASELINE_TREE = 799ef67d3c4124e76f37b4e31251b9c974695455
PRE-080C-01 = ACCEPTED effective 2026-10-09
PRE-080C-02 = AUTHORIZED / ACTIVE / NOT ACCEPTED
PRE-080C-03 = NOT STARTED
PRE-H080C = NOT REACHED
H-080C = NOT AUTHORIZED
```

PR #35 is an accepted non-phase baseline remediation. Its merge `84a2fbfdaece47d5dd87ca37c2e25e85afe39880` / tree `799ef67d3c4124e76f37b4e31251b9c974695455` is the accepted protected-main input baseline entering GOV-STATE-SYNC; post-merge `make-all` run `37931419995` succeeded. The GOV-STATE-SYNC candidate cannot record its own future accepted merge identity. Master Governance establishes that identity only after candidate review, human merge, exact merge resolution, protected-main post-merge verification, and Master Governance acceptance. PRE-080C-02 must then be re-pinned or rebased to that verified accepted merge, not to this input baseline, and candidate-bound evidence must be regenerated. PRE-080C-02 is the only currently authorized implementation prerequisite. Do not infer H-080C authorization from prerequisite acceptance; H-080C remains unauthorized until the PRE-H080C gate and separate explicit authorization.

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

The V4.1 Master Roadmap defines normative future phase requirements. Current accepted phase and permission to begin work belong in the hardening ledger. Reconciliation documents explain how stale historical records were resolved; they do not rewrite the history that produced the discrepancy.
