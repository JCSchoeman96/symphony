# PRE-080C-03 governance reconciliation

## Purpose and scope

This record reconciles current governance status, operator/developer guidance, legacy compatibility
material, repository-local skills, and a derivative machine-readable projection. The scope is
documentation and repository validation only. No runtime authority or lifecycle behavior changes.

When this reconciliation was prepared for the PR #38 candidate, PRE-080C-03 was ACTIVE / NOT ACCEPTED. That is historical candidate-era state.

PRE-H080C has not been reached.

H-080C is not authorized.

This document does not perform PRE-H080C adjudication.

## Historical authorization baseline — 2026-10-10

Master Governance authorized PRE-080C-03 by decision
`MG-2026-10-10-PRE-080C-03-AUTH-01`, timestamped `2026-10-10T16:35:00+02:00`.
The accepted protected-main baseline at the authorization decision was commit
`0640bf1135f8b5000ea29518c2c456272379e9c6`, tree
`5c6f10cc88c41f395837a930fb7ea20e0bdae0cc`. The immutable V4.1 Master Roadmap blob is
`4b0528bdc0647d889b42ebc478081d5b873898fe`. The immutable PRE-080C-02 evidence blob is
`b69d46676d3286262bf7cab783654c10a08801bf`.

## Post-acceptance reconciliation — 2026-10-11

Master Governance accepted PRE-080C-03 under decision
`MG-2026-10-11-PRE-080C-03-ACCEPT-01`, timestamp
`2026-10-11T18:02:47+02:00`, effective date `2026-10-11`.

The candidate and post-merge facts are:

```text
authorized candidate baseline:
0640bf1135f8b5000ea29518c2c456272379e9c6

PR #38 reviewed head:
92d95083371767de6e04498df7f59d3cb982f40d

human merge:
e0c1592e0fdb678f001a0e5e46e9b17de8a29000

merge tree:
bc9f8a665dd93fc8fe945d070297a3dfb4638d82

protected-main make-all:
38153451643 = success
```

The sequence was PRE-080C-03 authorization, candidate preparation, independent review, Master Gate, human merge, exact post-merge verification, and Master Governance acceptance. The merge did not itself establish acceptance. The governance projection did not establish acceptance. The POST-PRE080C03-GOV-STATE-SYNC implementation does not establish acceptance; it materializes the already-issued Master Governance decision.

Master Governance separately authorized the bounded state-sync implementation under
`MG-2026-10-11-POST-PRE080C03-GOV-SYNC-AUTH-01` at
`2026-10-11T18:02:47+02:00`. That authorization does not create a programme phase or authorize later programme work.

## Current programme state

- H-080B is accepted.
- PRE-080C-01 is accepted.
- PRE-080C-02 is accepted with outcome `LIMIT_FOUND` at PR #37 merge `0640bf1135f8b5000ea29518c2c456272379e9c6` / tree `5c6f10cc88c41f395837a930fb7ea20e0bdae0cc`.
- PRE-080C-03 is accepted effective 2026-10-11.
- PRE-H080C is not reached. It is the next governance step, not authorized implementation.
- H-080C is not authorized.
- No programme work or next programme phase is currently authorized.

The acceptance decision does not amend the Master Roadmap or grant future authority. This state sync
does not perform PRE-H080C adjudication or authorize H-080C.

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

PR #26 remains open and unmerged as historical superseded characterization material. The earlier
instruction not to merge or close it during PRE-080C-03 is historical. This state sync does not
authorize action on PR #26. Preserve its branch and history.

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
- PRE-H080C has not been reached.
- H-080C is not authorized.

## Explicit non-goals

This state sync does not amend the Master Roadmap, perform PRE-H080C adjudication, implement H-080C,
change runtime or lifecycle behavior, alter Plane or other provider code, rewrite historical PR
bodies/evidence, merge a PR, create PRE-080C-03 acceptance, or authorize future work. PRE-080C-03
acceptance was issued separately by Master Governance before this sync.

## Closure path

The candidate-era closure path required implementation, fresh independent review, Master Gate,
human merge, exact post-merge verification, and Master Governance acceptance. That sequence is
complete for PRE-080C-03. PRE-H080C adjudication remains a separate next governance step, and H-080C
still requires separate explicit authorization.
