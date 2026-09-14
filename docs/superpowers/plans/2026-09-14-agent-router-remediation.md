# Symphony agent-router remediation implementation plan

> Execute this plan in the isolated `remediation/agent-router` worktree. The
> authoritative base is merged commit `af74d10`. Do not merge, push, open a PR,
> invoke a real Codex session, mutate a real Linear project, or mutate GitHub
> unless the user separately authorizes that action.

## Objective

Remediate the findings in `docs/AGENT_ROUTER_REMEDIATION_PROMPT.md` and the
implementation review. Every R1-R10, additional gap, and SYM-00..15 row must
end with a code/test/documentation artifact or an explicit, honest external
proof blocker. Preserve the current single-provider, single-scheduler,
workspace-safe architecture.

## Working rules for every task

1. Add the smallest regression test first.
2. Run that focused test and record the failing assertion/output.
3. Implement only the bounded fix needed for that task.
4. Run the focused test, then affected tests, then `mise exec -- make all`
   from `elixir`, and `git diff --check`.
5. Update the requirement/evidence matrix and commit one coherent task before
   starting the next task.
6. Keep errors and snapshots free of secrets, arbitrary shell commands, and
   raw provider payloads. Preserve opaque runtime/session errors internally
   only where the existing contract requires them.

## Task 0 — freeze evidence and tracking artifacts

Files:

- `docs/AGENT_ROUTER_REMEDIATION_MATRIX.md`
- `docs/superpowers/plans/2026-09-14-agent-router-remediation.md`

Steps:

- Record the current base (`af74d10`), baseline test result (`351 tests, 0
  failures, 6 skipped`), the merged PR, and the characterization probes.
- Copy the R1-R10/additional/SYM tables into a tracked matrix with columns for
  requirement, current risk, regression test, implementation evidence,
  validation evidence, live-proof status, and remaining limitation.
- Mark fake/in-memory proof as component evidence only; do not call it live
  Linear/GitHub/Codex evidence.
- Validate the matrix itself with `git diff --check` and commit the plan and
  initial matrix together.

## Task 1 — make routed profile policy authoritative (R1, R2, R10, SYM-03,
SYM-04, SYM-08, SYM-14)

Files:

- `elixir/lib/symphony_elixir/agent_runtime/profile.ex`
- `elixir/lib/symphony_elixir/agent_router.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/config/workflow_store.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/test/symphony_elixir/agent_router_test.exs`
- `elixir/test/symphony_elixir/profile_runtime_test.exs`
- new focused profile/config regression tests as needed

Design:

- Define explicit routed-mode configuration. Absence of `agent.profiles`
  remains legacy mode and must retain the pre-router read-only Codex policy;
  routed mode is enabled only by an explicit profile map (and, if needed, an
  explicit route map). Document this migration contract.
- In routed mode, resolve every effective routed profile and validate the
  cross-field tuple, not individual fields: planning/review are read-only;
  implementation/correction are workspace-write; merge is always deferred and
  read-only. Reject overrides that contradict responsibility, including a
  merge profile changed to Codex or workspace-write.
- Reject normalized-name collisions instead of letting later map entries win.
  Reject malformed, missing, or unusable routed profiles and preserve the
  last-known-good workflow state on reload.
- Make custom profiles selectable only through explicit, responsibility-aware
  state routes. Do not let an unreferenced custom profile or an alternate
  prompt silently replace a standard routed responsibility.
- Make the router validate the effective profile at the dispatch boundary and
  make the orchestrator fail closed if the profile is absent, invalid, or an
  executable merge route.
- Keep legacy no-profile configuration on its existing route/runtime behavior;
  update tests that currently assert accidental default profile materialization.

TDD cases (red before implementation):

- contradictory planner/reviewer/builder/fixer profile combinations are
  rejected;
- merge overrides with `runtime: codex`, a command, or `sandbox:
  workspace-write` are rejected and never dispatch;
- normalized keys such as `Reviewer` and `reviewer` are rejected as a
  collision;
- absent profiles preserve legacy settings and do not materialize writable
  routed defaults;
- explicit custom profile plus explicit route selects the intended profile,
  while an unreferenced/custom responsibility mismatch is rejected;
- invalid reload keeps the prior valid settings and rejects the new policy.

Validation: focused profile/schema/router/workflow-store tests, affected
orchestrator tests, `mise exec -- make all`, and `git diff --check`.

## Task 2 — preserve effective runtime options on every turn (R5, SYM-05)

Files:

- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/test/symphony_elixir/agent_runtime_test.exs`
- `elixir/test/symphony_elixir/profile_runtime_test.exs`

Steps:

- Add a fake-runtime regression that captures startup options and every
  `run_turn` options map, including a non-default profile model and sandbox.
- Store the effective, normalized runtime options in the session context, not
  the original caller options. Reuse those options for each turn and retain
  the captured role/prompt policy for the active attempt.
- Verify continuation, route-change, shutdown, and runtime restart paths do
  not drop model, command, profile, responsibility, sandbox, or worker host.
- Keep AppServer’s explicit turn payload model forwarding covered by a direct
  test.

Validation: focused runtime/profile tests, affected orchestrator tests,
`mise exec -- make all`, and `git diff --check`.

## Task 3 — make dependency data complete and fail closed (R4, R6, SYM-06,
SYM-07, SYM-09, SYM-10, SYM-11)

Files:

- `elixir/lib/symphony_elixir/tracker/issue.ex`
- `elixir/lib/symphony_elixir/linear/client.ex`
- `elixir/lib/symphony_elixir/linear/adapter.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/lib/symphony_elixir/tracker/memory.ex`
- `elixir/lib/symphony_elixir/dependency/policy.ex`
- `elixir/lib/symphony_elixir/dependency/guard.ex`
- `elixir/lib/symphony_elixir/dependency/graph.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- corresponding dependency, Linear, memory, and orchestrator tests

Design:

- Extend the issue/adapter boundary with explicit dependency-data
  completeness (`complete`, `incomplete`, or unavailable with a safe reason).
  A missing/malformed relation connection is never equivalent to `blocked_by:
  []`.
- Update Linear GraphQL relation queries to request `pageInfo` and page
  relation connections per issue until `hasNextPage` is false. Cover more than
  50 relations, mixed relation types, empty-but-complete connections,
  malformed/missing page info, and request errors. Verify the field shape
  against the authoritative Linear schema/documentation before finalizing the
  query.
- Add a dependency-graph acquisition boundary separate from dispatch
  candidates. Linear and memory adapters return the full project graph (all
  states); adapters without that capability return an explicit incomplete
  graph so implementation/merge dispatch is denied.
- Build graph closure over every returned issue, detect self-cycles and
  multi-node cycles even when nodes are Backlog/Blocked/non-dispatchable, and
  report missing nodes/relations explicitly. Do not mutate tracker state.
- Re-fetch/rebuild the graph before a final dispatch decision and fail closed
  for incomplete graph data. Preserve the existing planning/review allowances
  where the policy explicitly permits them, while never permitting
  implementation/merge on unknown dependency data.

TDD cases (red before implementation):

- relation pagination walks all pages and retains only `blocks` relations;
- a connection without valid page info is marked incomplete, not empty;
- a provider error is surfaced and prevents unsafe dispatch;
- a cycle through Backlog/Blocked is diagnosed and produces no implementation
  dispatch;
- missing graph closure nodes and self-cycles are diagnosed;
- an independent issue still dispatches when another graph component cycles;
- a stale candidate is denied after the final graph refresh finds a blocker.

Validation: dependency/Linear/memory/adapter/orchestrator focused and affected
tests, `mise exec -- make all`, and `git diff --check`.

## Task 4 — reconcile long-running workers against fresh tracker/dependency
state (R3, SYM-12, SYM-15)

Files:

- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/test/symphony_elixir/agent_runtime_test.exs`
- `elixir/test/symphony_elixir/agent_router_orchestrator_test.exs`
- new process/race regression tests as needed

Steps:

- Add a real long-running test worker/runtime that remains alive while a poll
  refresh changes the issue or blocker; do not rely only on a turn-boundary
  fake.
- During every poll refresh of a running issue, evaluate current state, route,
  and dependency guard using fresh graph data. If implementation/correction
  becomes unsafe, stop the task promptly and retain a blocked/human-attention
  record with the reason and attempt metadata.
- Reconcile route changes without dropping the claim/attempt history or
  accidentally resetting failure/review counters. Ensure a stale `:DOWN`, a
  completion message, and a shutdown stop are idempotent and cannot resurrect
  a stopped worker.
- Re-check dependency state after a successful turn and at poll/completion
  boundaries, preserving the existing safe stop behavior.

Validation: focused process/race/orchestrator tests, affected test set,
`mise exec -- make all`, and `git diff --check`.

## Task 5 — make role prompts coherent, reloadable, and packaged (R7, SYM-01,
SYM-02, SYM-13)

Files:

- `elixir/lib/symphony_elixir/prompt_builder.ex`
- `elixir/prompts/planner.md`
- `elixir/prompts/builder.md`
- `elixir/prompts/reviewer.md`
- `elixir/prompts/fixer.md`
- `elixir/WORKFLOW.md`
- `README.md`
- `elixir/README.md`
- `elixir/test/symphony_elixir/role_prompt_test.exs`
- new prompt reload/packaging tests as needed

Steps:

- Remove compile-time-only behavior as the source of truth: read the shipped
  prompt at runtime with the embedded prompt as a packaged fallback. Capture
  the role policy at attempt start so an active attempt is stable; future
  attempts see a valid prompt reload.
- Define a single responsibility policy for each role. Planner/reviewer never
  write source; builder/fixer implement only their scoped work; reviewer
  returns exact PASS/FAIL/BLOCKED evidence; fixer validates findings and does
  not self-approve; merge remains deferred/no-op.
- Replace the conflicting monolithic workflow body with routed lifecycle
  instructions and an explicit routed profile configuration/migration example.
  Remove Human Review/Rework/full-reset/Merging instructions that conflict with
  the role router. Keep tracker, workspace, security, retry, and merge limits
  honest.
- Test prompt edits between two attempts and verify active-attempt stability,
  missing prompt failure/fallback, role alias mapping, and packaged fallback.

Validation: role/prompt/config tests, docs checks, `mise exec -- make all`, and
`git diff --check`.

## Task 6 — bound retries and review cycles without charging capacity waits
to failure limits (R8, SYM-03, SYM-04, SYM-14)

Files:

- `elixir/lib/symphony_elixir/orchestrator.ex`
- new `elixir/lib/symphony_elixir/agent_runtime/attempt_policy.ex` (or an
  equally small policy module if the existing layout is a better fit)
- `elixir/test/symphony_elixir/agent_router_orchestrator_test.exs`
- `elixir/test/symphony_elixir/agent_runtime_test.exs`
- new attempt-policy tests

Design:

- Track separate counters for ordinary runtime/spawn failures, review
  correction cycles, capacity waits, normal continuations, and route changes.
- Enforce at most three ordinary retries per issue/attempt lineage. At the
  limit, stop automatic work and expose a human-attention termination record.
- Count a reviewer→changes-requested cycle once per independent reviewer
  failure; enforce the three-cycle cap without treating a route change or
  continuation as a failure.
- Do not implement automatic CI retry; expose a policy value of `disabled` and
  document that CI infrastructure must be retried by a human/provider path.
  If a future CI retry hook is added, its pure policy must allow only one
  infrastructure-only retry.
- Preserve counters across role boundaries, reloads, and route changes within
  the live orchestrator; reset only on a genuinely new issue lineage or an
  explicit terminal completion. Apply stricter reloaded limits to current
  state.

TDD cases: ordinary retry 1/2/3 then human attention; capacity pressure leaves
failure count unchanged; reviewer/fixer loops 1/2/3 then stop; route changes
retain counters; CI retry is disabled; restarts do not fabricate extra retries.

Validation: policy/orchestrator tests, affected tests, `mise exec -- make all`,
and `git diff --check`.

## Task 7 — expose truthful, safe observability (R9, SYM-06, SYM-07, SYM-12,
SYM-15)

Files:

- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir_web/presenter.ex`
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`
- `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- presenter/dashboard tests and new redaction tests

Steps:

- Add effective sandbox, responsibility/profile, attempt/failure/review
  counters, session/workspace identifiers, dependency completeness, and
  termination reason to running/retrying/blocked/recent-attempt snapshots.
- Retain a bounded recent terminal/stop history so route changes, dependency
  stops, retry exhaustion, shutdown, and normal completion are distinguishable
  after the running entry disappears.
- Classify dependency-blocked only when dependency policy denied work; expose
  capacity waiting, retry exhausted, route changed, terminal, and runtime
  unavailable separately.
- Redact secrets, tokens, environment values, raw GraphQL, arbitrary commands,
  and unbounded provider/runtime error data in all API/dashboard payloads.
- Add snapshot/API contract tests that assert fields and safe rendering.

Validation: focused status/presenter/API tests, affected tests, `mise exec --
make all`, and `git diff --check`.

## Task 8 — enforce lifecycle responsibility at the existing tool boundary
(additional gap: transition authority)

Files:

- `elixir/lib/symphony_elixir/linear/agent_tool.ex`
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- new small transition-policy module/tests, if needed
- `elixir/test/symphony_elixir/dynamic_tool_test.exs`
- relevant Linear/agent-runtime tests

Steps:

- Pass the effective responsibility, current issue state, and dependency
  decision from the bound session into the existing agent-tool boundary.
- Reject unauthorized lifecycle mutations at that boundary, especially merge
  transitions and implementation/correction work when dependencies are
  unresolved or incomplete. Keep read-only GraphQL available to all roles.
- Prefer a small structured transition authorization path over parsing arbitrary
  mutation documents. Do not add a second lifecycle scheduler or silently
  mutate tracker state from the orchestrator. If provider-native/raw GraphQL
  mutations remain an unavoidable bypass, deny or explicitly document the
  bypass rather than implying full enforcement.
- Test planner/reviewer/merge mutation denial, builder/fixer allowed scoped
  transitions, unresolved dependency denial, and safe error payloads.

Validation: dynamic-tool/transition focused tests, affected tests,
`mise exec -- make all`, and `git diff --check`.

## Task 9 — complete proof artifacts and documentation

Files:

- `docs/AGENT_ROUTER_REMEDIATION_MATRIX.md`
- `docs/symphony-agent-router-dependency-proof.md`
- `docs/AGENT_ROUTER_REMEDIATION_PROMPT.md` only if a factual cross-reference
  is needed; preserve the user-supplied prompt otherwise
- root and Elixir READMEs/WORKFLOW as required by the AGENTS instructions
- new disposable proof tooling under `elixir/test/support` or `scripts/`

Steps:

- Update every matrix row with exact test paths/commands and commit evidence.
- Add deterministic component proof for the full lifecycle, full graph/cycle
  behavior, poll interruption, retry/review caps, tool boundary, reload/LKG,
  model propagation, and observability. Keep fake runtimes/tracker adapters
  clearly labeled as component proof.
- Add opt-in live-proof scaffolding that requires explicitly named disposable
  Linear/GitHub/Codex resources and refuses to run without a consent/config
  gate. Do not claim live proof if credentials/resources are unavailable.
- Record SYM-00 as historical/branch-base evidence and SYM-01..15 as current
  evidence or an explicit external-proof blocker. State that no Cursor,
  automatic merge, Redis, Postgres, Ash, or second scheduler was used.

Validation: proof tests, docs review, `mise exec -- make all`, and
`git diff --check`.

## Task 10 — final verification and handoff

- Run a clean `mise exec -- mix test --seed 0` and confirm the complete count.
- Run `mise exec -- make all` from `elixir` and `git diff --check`.
- Inspect `git status`, the final diff, and the matrix for every unchecked row.
- Use the verification-before-completion skill before claiming completion.
- Use requesting-code-review for a final review of the diff and tests.
- Use finishing-a-development-branch to present integration options. Do not
  merge or publish without separate authorization.
