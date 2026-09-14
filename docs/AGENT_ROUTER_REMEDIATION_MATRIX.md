# Agent-router remediation requirement/evidence matrix

Status: active remediation ledger. The code in this worktree is based on the
merged PR #2 commit `af74d10` (2026-09-14). This file deliberately separates
deterministic component evidence from live Linear/GitHub/Codex proof.

## Frozen base evidence

| Evidence | Result |
| --- | --- |
| `origin/main` after fetch | `af74d10f9aa799476eabfc5c856c956c03b88c4e` |
| PR #2 | merged; merge commit `af74d10`; no merge was performed by this task |
| clean baseline command | `mise exec -- mix test --seed 0` from `elixir` |
| clean baseline result | `351 tests, 0 failures, 6 skipped` |
| prior characterization probe | user-supplied `docs/router_review_probe_test.exs`; 8 tests, 0 failures, seven tests characterize unsafe behavior |
| live resources | no disposable Linear project, GitHub repository, or real Codex session has been authorized/provided |

## Review findings

The implementation and evidence columns are updated as each bounded task is
completed. “Pending” is intentional until a test and validation command exist.

| ID | Requirement / risk | Regression test | Implementation evidence | Validation evidence | Live-proof status / limitation |
| --- | --- | --- | --- | --- | --- |
| R1 | Effective responsibility must authorize runtime, sandbox, command, and prompt; normalized-name and override bypasses must fail closed; invalid reload keeps LKG. | Pending: profile policy/config reload tests | Pending | Pending | Component proof only until disposable resources exist |
| R2 | Absent profiles must preserve legacy read-only behavior; writable routed defaults require explicit migration. | Pending: legacy-vs-routed schema tests | Pending | Pending | Component proof only |
| R3 | Poll refresh must stop a running worker when a blocker/route/state becomes unsafe; completion and shutdown races are idempotent. | Pending: real long-running worker/poll race tests | Pending | Pending | Component proof only |
| R4 | Linear relations require complete pagination and explicit missing/malformed/error state; empty must be verified empty. | Pending: >50 relations, mixed types, page-info/error tests | Pending | Pending | Requires disposable Linear proof for provider confirmation |
| R5 | Effective profile model/sandbox/command must reach every runtime turn. | Pending: startup plus every `run_turn` payload | Pending | Pending | Component proof only |
| R6 | Graph acquisition must include non-dispatchable closure nodes and detect self/multi-node cycles without blocking independent work. | Pending: full-graph closure/cycle tests | Pending | Pending | Component proof only; live provider graph still unverified |
| R7 | Role prompts must be coherent, runtime-reloadable for future attempts, stable for active attempts, and packaged. | Pending: prompt reload/fallback tests | Pending | Pending | Component proof only |
| R8 | Bound ordinary retries and review cycles; separate capacity/continuation/route-change accounting; CI retry disabled or tightly bounded. | Pending: policy/counter threshold tests | Pending | Pending | Component proof only |
| R9 | Snapshot/API must retain truthful termination reasons, sandbox, attempts, dependency completeness, and safe redaction. | Pending: presenter/status/redaction tests | Pending | Pending | Component proof only |
| R10 | Merge gate must remain non-executable; fake proof must not be presented as live Codex/Linear/GitHub proof. | Pending: hard refusal/metadata tests | Pending | Pending | Live proof blocked pending explicit disposable resources |

## Additional gaps from the review

| Gap | Requirement | Regression test | Implementation evidence | Validation evidence | Limitation |
| --- | --- | --- | --- | --- | --- |
| A1 | Preserve a single authority per concern and do not add Redis/Postgres/Ash/second scheduler. | Architecture/doc review plus full suite | Pending | Pending | Live deployment topology not exercised |
| A2 | Enforce workflow-controlled tracker transitions at the existing agent-tool boundary, including unresolved `In Review` → `Ready to Merge`. | Pending: role/dependency transition authorization tests | Pending | Pending | Provider-native clients outside Symphony cannot be controlled; document boundary |
| A3 | Make custom profiles selectable only through explicit responsibility-aware routes. | Pending: custom route selection/mismatch tests | Pending | Pending | Component proof only |
| A4 | Use concurrency class/capacity semantics or remove misleading configuration. | Pending: capacity classification/status tests | Pending | Pending | Real multi-host capacity not available |
| A5 | Keep opaque runtime/session errors and workspace cleanup safe while redacting public payloads. | Pending: runtime cleanup/error-redaction tests | Pending | Pending | Real Codex process unavailable |
| A6 | Update root README, Elixir README, and workflow documentation when behavior/config changes. | Pending: docs review/check | Pending | Pending | Docs cannot substitute for live operational proof |
| A7 | Add opt-in live-proof harness with named disposable resources and a hard consent gate. | Pending: no-consent refusal test | Pending | Pending | Not runnable without explicit resources/authorization |

## SYM micro-prompts

| ID | Required evidence | Current status at merged base | Final evidence |
| --- | --- | --- | --- |
| SYM-00 | Freeze base and avoid merging an unverified PR. | Historical blocker cleared: PR #2 is now merged at `af74d10`; work is isolated on `remediation/agent-router`. | Pending final audit |
| SYM-01 | Planner reads and produces a bounded plan without source writes. | Existing local deterministic role tests; prompt/workflow coherence still under review. | Pending |
| SYM-02 | Reviewer is read-only and reports exact PASS/FAIL/BLOCKED evidence. | Existing local deterministic role tests; effective policy was permissive. | Pending |
| SYM-03 | Ready/In Progress implementation dispatch obeys dependencies and profile policy. | Existing tests cover happy path; characterization exposed writable legacy defaults. | Pending |
| SYM-04 | Changes Requested correction is bounded, reviewed, and retry-limited. | Existing route tests; no hard retry/review threshold. | Pending |
| SYM-05 | Profile runtime options survive into each turn. | Characterization exposed `nil` model in later turn payload. | Pending |
| SYM-06 | Dependency policy distinguishes Done, active, and invalidated blockers. | Existing unit tests pass; completeness/closure is insufficient. | Pending |
| SYM-07 | Blocker reappearance/reconciliation stops unsafe work. | Existing turn-boundary stop test; poll-level interruption missing. | Pending |
| SYM-08 | Merge route is deferred/non-executable. | Characterization exposed executable override. | Pending |
| SYM-09 | Relation pagination/completeness is authoritative. | Characterization exposed missing relation data becoming `[]`; current query caps at 50. | Pending |
| SYM-10 | Full project graph catches cycles outside active candidates. | Characterization exposed active-only graph omission. | Pending |
| SYM-11 | Independent graph components continue while cyclic components stop. | Existing partial component proof; full graph acquisition absent. | Pending |
| SYM-12 | Poll/completion/shutdown races do not resurrect workers. | Existing tests are mostly fake/turn-boundary. | Pending |
| SYM-13 | Prompt reload and shipped workflow are coherent. | Compile-time prompt embedding and conflicting workflow remain. | Pending |
| SYM-14 | Retry/review/CI limits are explicit and enforced. | No ordinary retry/review cap; CI retry path not explicit. | Pending |
| SYM-15 | Observability accurately distinguishes dependency, capacity, retry, and termination states. | Snapshot lacks effective sandbox/complete termination history; classifier conflates states. | Pending |

## Validation ledger

Each completed task must add its focused command/result here and retain the
full-suite result in the handoff. Until then, no row above is a completion
claim.

| Task | Focused/affected result | `mise exec -- make all` | `git diff --check` |
| --- | --- | --- | --- |
| Baseline | `351 tests, 0 failures, 6 skipped` | Pending after remediation | Clean at base |
| 1–10 | Pending | Pending | Pending |

## External-proof boundary

No live claim is made in this ledger. A live proof run may be added only after
the user identifies disposable resources and explicitly authorizes the run.
The local evidence will remain honest about fake runtimes, in-memory trackers,
and provider-shaped fixtures. The implementation introduces no Cursor path,
automatic merge, Redis, Postgres, Ash, or second scheduler.

