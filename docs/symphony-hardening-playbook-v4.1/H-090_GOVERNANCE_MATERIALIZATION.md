# H-090 governance materialization

## Purpose

This record materializes the 2026-10-17 Master Governance decision into the derivative governance projection. It records H-080C acceptance and a bounded authorization for H-090 planning and seam assessment.

## Programme state being projected

```text
MATERIALIZATION_DECISION_REF=MG-2026-10-17-POST-H080C-PRE-H090-GOV-MATERIALIZATION-AUTH-01
DECISION_TIMESTAMP=2026-10-17T13:53+02:00
REPOSITORY=JCSchoeman96/symphony

ACCEPTED_H080C_SHA=e8d945b70c4bfc2be1db154a22d23f3c5a5f1a27
ACCEPTED_H080C_TREE=3a325b8dc8cfd515e14a4f1c6016719d980f64b2

H080C=ACCEPTED
AUTHORIZED_PHASE=H-090
AUTHORIZED_STATUS=AUTHORIZED_ACTIVE_NOT_ACCEPTED
H090_STRUCTURAL_IMPLEMENTATION=NOT_AUTHORIZED_BY_THIS_DECISION
H120A=NOT_AUTHORIZED
MERGE_AUTHORITY=HUMAN_ONLY
```

## Bounded authorization to materialize governance state

This candidate changes derivative governance state only. It does not implement H-090 structural hardening, and it changes no production or runtime code. The projection remains a record of human authority. It does not grant authority.

## Accepted H-080C identity

Master Governance accepted H-080C at PR #46 merge `e8d945b70c4bfc2be1db154a22d23f3c5a5f1a27` with tree `3a325b8dc8cfd515e14a4f1c6016719d980f64b2`. The accepted prerequisite remains PRE-H080C. This candidate records the accepted merge identity and decision; it does not change the immutable Master Roadmap or PRE-080C-02 evidence.

## H-090 planning-only authorization boundary

The active H-090 authorization covers planning and seam assessment only. H-090 structural production implementation remains unauthorized until a fresh H-090 plan is accepted and Master Governance separately authorizes implementation. H-120A is the next governance step, but it is not authorized. Merge authority remains human-only.

## Candidate boundary

The candidate changes derivative governance records, the checker-pinned accepted snapshot, its tests, and current-status prose. It makes no Orchestrator, lifecycle, runtime, provider, source-control, CandidateRef, CompletionProof, suspension, workspace, or isolation production changes. It adds no governance schema version or `h_090` field.

## Freeze-selector semantics

The target projection contains active H-090 planning authority. Its candidate freeze is:

```bash
cd elixir
mix governance.check --freeze --candidate-phase H-090
```

The decision-materialization selector intentionally fails because it requires the exact `NONE/NONE/NONE` authorized-work tuple:

```bash
mix governance.check --freeze --materialize-decision MG-2026-10-17-POST-H080C-PRE-H090-GOV-MATERIALIZATION-AUTH-01
```

The expected diagnostic is `materialization_requires_no_authorized_work`. The checker must not be changed to make this selector pass with active H-090 authority.

## Post-merge handoff

After human merge and exact post-merge verification, a fresh H-090 Planner must pin the new protected-main SHA and tree before producing an implementation plan. The earlier H-090 plan based on `e8d945b70c4bfc2be1db154a22d23f3c5a5f1a27` is not an implementation baseline.
