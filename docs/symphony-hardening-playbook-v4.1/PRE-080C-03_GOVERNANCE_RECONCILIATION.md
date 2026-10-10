# PRE-080C-03 governance reconciliation

## Purpose and scope

This record reconciles current governance status, operator/developer guidance, legacy compatibility
material, repository-local skills, and a derivative machine-readable projection. The scope is
documentation and repository validation only. No runtime authority or lifecycle behavior changes.

PRE-080C-03 is ACTIVE / NOT ACCEPTED.

PRE-H080C has not been reached.

H-080C is not authorized.

This document does not perform PRE-H080C adjudication.

## Decision baseline

Master Governance authorized PRE-080C-03 by decision
`MG-2026-10-10-PRE-080C-03-AUTH-01`, timestamped `2026-10-10T16:35:00+02:00`.
The accepted protected-main baseline at that decision is commit
`0640bf1135f8b5000ea29518c2c456272379e9c6`, tree
`5c6f10cc88c41f395837a930fb7ea20e0bdae0cc`. The immutable V4.1 Master Roadmap blob is
`4b0528bdc0647d889b42ebc478081d5b873898fe`. The immutable PRE-080C-02 evidence blob is
`b69d46676d3286262bf7cab783654c10a08801bf`.

## Current programme state

- H-080B is accepted.
- PRE-080C-01 is accepted.
- PRE-080C-02 is accepted with outcome `LIMIT_FOUND` at the baseline above.
- PRE-080C-03 is authorized and active, but not accepted.
- PRE-H080C is not reached. It is the next governance step, not authorized implementation.
- H-080C is not authorized.
- The next authorized phase is none.

The decision authorizes only implementation of PRE-080C-03 within its approved scope. It does not
amend the Master Roadmap or grant future authority.

## Authority hierarchy and ownership

The normative V4.1 Master Roadmap is repository law. The Unified Execution Roadmap governs current
execution and sequencing within that law. Explicit canonical companion specifications and matrices
have scope-limited authority. The hardening ledger indexes current status. The playbook README is
navigation and summary. The governance projection is a derivative machine snapshot.

Master Governance owns programme acceptance, authorization, prerequisite/phase acceptance, and
permission to advance to a later governance step. GitHub establishes source-control facts, including
repository and PR identity/state, commit/tree identity, merge facts, check-run producer identity, and
branch protection. GitHub merge does not establish programme acceptance. Plane provides observations
within its configured provider scope. Symphony's authority kernel makes runtime/work-control
decisions under the governing architecture. Trackers, backlogs, PR text, CI, skills, plans, prompts,
and agent prose cannot create authority.

## Historical, merge, acceptance, and current-authority facts

Historical evidence records what a document or PR said at the time. A merge fact records a GitHub
merge. Acceptance requires the later applicable Master Governance decision and its evidence.
Current authority is the latest accepted governance decision and bounded authorization. Therefore,
merge is not acceptance, green CI is not acceptance, tracker state is not programme authority, and
skill text or agent output is not trusted evidence.

### PR #26

PR #26 remains open and unmerged as historical superseded characterization material. Do not merge
or close it during PRE-080C-03. Preserve its branch and history. Consider closure only after
PRE-080C-03 acceptance under separate authorization.

### PR #31

The PR #31 candidate body said H-080B was not accepted and should not merge. GitHub later merged it.
Master Governance subsequently reconciled the evidence and accepted H-080B effective 2026-10-07.
Those candidate, merge, and acceptance facts remain distinct. The historical PR body is unchanged.

### PR #37 and PRE-080C-02

PR #37 candidate evidence was authored while the candidate was open and unaccepted. GitHub merged it
as `0640bf1135f8b5000ea29518c2c456272379e9c6`, tree
`5c6f10cc88c41f395837a930fb7ea20e0bdae0cc`. Master Governance later accepted PRE-080C-02 with
outcome `LIMIT_FOUND`. The historical PR body and PRE-080C-02 evidence remain unchanged.

## Plane, tracker, and backlog position

Plane is the hardened V1 primary work-control provider. Its current routed capabilities are
`current_issue_refresh`, `dependency_graph`, `dependency_completeness`, `controlled_transition`,
`transition_verification`, `agent_read_tools`, and `agent_transition_tools`.
`conditional_transition` remains unsupported. A provider mutation acknowledgement is not
authoritative transition proof. A fresh provider reread plus Symphony lifecycle reassessment is the
required verification path. Plane capability does not grant Symphony authority.

Linear remains a legacy compatibility adapter. The shipped `elixir/WORKFLOW.md` uses
`tracker.kind: linear` and `agent.routing: legacy`, so it does not activate routed role selection.
Ordinary tracker/backlog items represent work or signals. Their existence does not authorize
implementation.

## Documentation and methodology classification

The root and Elixir READMEs identify Plane as the hardened V1 primary provider, distinguish current
fork guidance from upstream references and historical demo behavior, and state that merge and
acceptance are separate. `SPEC.md` is upstream/generic compatibility guidance subordinate to V4.1
where they differ. `elixir/WORKFLOW.md` remains a legacy Linear sample. `elixir/AGENTS.md` and this
ledger point to governing documents but do not create authority.

Repository-local skills describe how an already-authorized responsibility proceeds. They cannot
grant lifecycle, source-control, merge, release, or acceptance authority. Superpowers plans and
specifications are developer methodology, planning/design history, and procedural context. They are
not current programme authority, runtime authority, trusted evidence, acceptance decisions, or
authorization.

## Governance projection and validation

`V4_1_GOVERNANCE_PROJECTION.json` records the exact Master Governance decision and accepted baseline.
It does not contain the future commit identity of the candidate that adds it. Its values mirror the
human status blocks in the ledger, playbook README, and Unified Execution Roadmap. The projection
records a decision; it does not create one.

A projection moves from Prepared to Current only after schema, metadata, immutable-roadmap,
accepted-identity, current-status, and non-escalation checks pass. Current is the steady state for
one governance snapshot. A failed projection is Invalid; Invalid is terminal for that projection
instance. A later explicit human decision may supersede a Current projection; Superseded is terminal
for that instance. CI, tracker movement, PR merge, or agent edits cannot change either terminal
state. A later decision creates a new projection snapshot.

One governance gate assessment is Unassessed and then Passed or Rejected. Those results are terminal
for that assessment. A later validation is a new assessment. The checker reads, validates, reports,
and can deny a gate. It cannot authorize, advance a phase, accept, merge, or mutate tracker/provider/
source-control state.

## Known unresolved conditions

- PRE-080C-02's `LIMIT_FOUND` outcome requires PRE-H080C adjudication.
- PRE-080C-03 is not accepted.
- PRE-H080C has not been reached.
- H-080C is not authorized.

## Explicit non-goals

This phase does not amend the Master Roadmap, perform PRE-H080C adjudication, implement H-080C,
change runtime or lifecycle behavior, alter Plane or other provider code, rewrite historical PR
bodies/evidence, merge a PR, accept PRE-080C-03, or authorize future work.

## Closure path

PRE-080C-03 can be accepted only after implementation, fresh independent review, Master Gate,
human merge, exact post-merge verification, and Master Governance acceptance. Only then may a
separately authorized governance sync record its accepted merge identity. PRE-H080C adjudication
remains a separate later governance step. H-080C still requires separate explicit authorization.
