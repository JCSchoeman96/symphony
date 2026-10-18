# POST-H090 / PRE-H120A governance materialization

## Purpose

This record materializes the externally supplied Master Governance decision MG-2026-10-18-H090-ACCEPT-H120A-AUTH-01 issued at 2026-10-18T12:16:30+02:00.

The repository projection and checker record and enforce that authority; they do not create it.

H-120A is the sole active candidate and is not accepted. The acceptance evidence below is the supplied H-090 evidence.

## H-090 acceptance evidence

```text
REPOSITORY=JCSchoeman96/symphony
H090_PR=48
H090_REVIEWED_HEAD=8d5c4ccf31ff20b110a0d12750e81896716f9319
H090_MERGE_SHA=d8ebad76e34ef13a98bd11e70f4bd657392ff33d
H090_MERGE_TREE=3c54c625571ac259fa7ecf42d65b22b8e290cf66
MERGE_SIGNATURE=VALID
PROTECTED_MAIN_MATCH=YES
POST_MERGE_RUN=39107581172
POST_MERGE_EVENT=push
POST_MERGE_HEAD_SHA=d8ebad76e34ef13a98bd11e70f4bd657392ff33d
POST_MERGE_ATTEMPT=1
POST_MERGE_STATUS=completed
POST_MERGE_CONCLUSION=success
REQUIRED_JOB_CLOSURE=SUCCESS
```

## Decision and phase boundaries

```text
DECISION_AUTHORITY=Master Governance
DECISION_REFERENCE=MG-2026-10-18-H090-ACCEPT-H120A-AUTH-01
DECISION_TIMESTAMP=2026-10-18T12:16:30+02:00
H090=ACCEPTED
H120A=AUTHORIZED_ACTIVE_NOT_ACCEPTED
H100=NOT_AUTHORIZED
H110=NOT_AUTHORIZED
H120B=NOT_AUTHORIZED
MERGE_AUTHORITY=HUMAN_ONLY
```

## Candidate boundary

The candidate only materializes H-090 acceptance, H-120A authorization, and derivative status/checker state.

It does not implement H-120A outputs, freeze an H-120A live-proof candidate, construct proof infrastructure, run H-100/H-110, accept H-120A, authorize H-100/H-110/H-120B, change runtime behavior, or grant auto-merge.

## Freeze-selector semantics

With H-120A active, the only positive phase freeze is the following command, run from `elixir/`:

```bash
mix governance.check --freeze --candidate-phase H-120A
```

This selector validates the projected active phase. It does not freeze an H-120A live-proof candidate. H-090, H-100, H-110, and H-120B phase selections fail phase matching.

Decision-materialization selection is intentionally rejected while active work exists:

```bash
mix governance.check --freeze --materialize-decision MG-2026-10-18-H090-ACCEPT-H120A-AUTH-01
```

The expected diagnostic is `:materialization_requires_no_authorized_work`. This selection requires no authorized work and must remain negative while H-120A is active.
