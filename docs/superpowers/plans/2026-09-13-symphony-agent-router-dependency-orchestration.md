# Symphony Agent Router and Dependency Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved SYM-01→SYM-15 roadmap so Symphony has a replaceable Codex runtime, deterministic role routing, fresh-session boundaries, lifecycle-aware native dependency scheduling, role permissions/prompts, safe observability, and reproducible Codex-only integration proofs.

**Architecture:** Keep the Orchestrator as the single claim/retry/concurrency authority. Put a small `AgentRuntime` behaviour and `AgentRuntime.Codex` adapter between it and `Codex.AppServer`; represent named profiles and immutable route fingerprints as pure data. Keep dependency classification, policy, graph/cycle detection, and frontier decisions pure, then feed their decisions into the existing scheduler and in-memory blocked/diagnostic state.

**Tech Stack:** Elixir 1.19 / OTP 28, Ecto embedded configuration, Phoenix PubSub/LiveView, existing Linear GraphQL adapter, Codex App Server over stdio, ExUnit, Mix/Credo/Dialyzer.

---

## Scope and invariants

- Preserve the frozen baseline behavior for legacy workflows: absent profiles resolve to a Codex builder-compatible fallback, existing `Todo`/`In Progress` work remains dispatchable, and the existing App Server protocol remains the transport implementation.
- Add the approved lifecycle aliases (`Planning`, `Ready`, `In Progress`, `In Review`, `Changes Requested`, `Ready to Merge`, `Merging`, `Blocked`) without making tracker mutation part of pure routing or dependency code.
- Only `Done` satisfies a hard dependency. Active states remain unresolved; `Canceled`/`Cancelled` and other invalid terminal outcomes fail closed.
- Planning and review can be dispatched under the policy table where appropriate, but implementation, correction, and merge authority cannot cross unresolved/invalid dependencies.
- No Cursor runtime, auto-merge, Redis, Postgres, Ash, second scheduler, or broad Orchestrator rewrite is included.

## File map

- Create `elixir/lib/symphony_elixir/agent_runtime.ex`: runtime callback contract and shared runtime types.
- Create `elixir/lib/symphony_elixir/agent_runtime/codex.ex`: thin App Server adapter.
- Create `elixir/lib/symphony_elixir/agent_runtime/profile.ex`: validated profile data and runtime/sandbox helpers.
- Create `elixir/lib/symphony_elixir/agent_runtime/route.ex`: immutable route data and fingerprint.
- Create `elixir/lib/symphony_elixir/agent_runtime/router.ex`: pure normalized-state/profile resolution.
- Create `elixir/lib/symphony_elixir/dependency/policy.ex`: blocker outcome classification and responsibility policy.
- Create `elixir/lib/symphony_elixir/dependency/guard.ex`: issue-level dependency decision and diagnostics.
- Create `elixir/lib/symphony_elixir/dependency/graph.ex`: deterministic graph construction and cycle detection.
- Create `elixir/prompts/{planner,builder,reviewer,fixer}.md`: repository-owned role policies.
- Modify `elixir/lib/symphony_elixir/config/schema.ex`, `config.ex`, and `workflow_store.ex` only as needed for profiles and validation.
- Modify `elixir/lib/symphony_elixir/codex/app_server.ex` only to accept adapter-supplied command/policy options; keep JSON-RPC code authoritative there.
- Modify `elixir/lib/symphony_elixir/agent_runner.ex` for route/runtime injection, role prompts, profile sandbox, and route-change termination.
- Modify `elixir/lib/symphony_elixir/orchestrator.ex` for route metadata, dependency frontier/cycles, safe fresh redispatch, and diagnostics.
- Modify `elixir/lib/symphony_elixir/linear/client.ex` so normalized native relations remain available to the lifecycle guard rather than precluding planning.
- Modify `elixir/lib/symphony_elixir/prompt_builder.ex`, the presenter, terminal dashboard, and PubSub update path for role/dependency metadata.
- Add focused tests beside each module and integration/proof tests under `elixir/test/symphony_elixir/`.
- Add `docs/symphony-agent-router-dependency-proof.md` with the executable proof protocol and final evidence template; populate it only with actual proof output.

## Task 1: SYM-01/SYM-02 runtime boundary

**Files:** contract, Codex adapter, AgentRunner, App Server, focused runtime/runner tests.

- [ ] Write a failing contract test with a fake runtime whose `start_session/2`, `run_turn/4`, and `stop_session/1` calls are recorded; assert `AgentRunner` uses the injected runtime and preserves `:ok`/error behavior.
- [ ] Run the focused test and confirm it fails because AgentRunner calls `Codex.AppServer` directly.
- [ ] Add the behaviour:

```elixir
@callback start_session(Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
@callback run_turn(term(), String.t(), Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
@callback stop_session(term()) :: :ok
```

- [ ] Add `AgentRuntime.Codex` delegating each callback to `Codex.AppServer` and change AgentRunner to default to that adapter while accepting `runtime: module()` in options.
- [ ] Pass worker/profile options through the adapter to App Server without duplicating its JSON-RPC implementation.
- [ ] Run the focused runtime/runner tests, then `mix test`.

## Task 2: SYM-03/SYM-04 profiles and deterministic routes

**Files:** Profile/Route/Router modules, config schema/accessors, workflow fixtures, profile/router tests.

- [ ] Write failing tests for built-in profiles, user overrides, legacy Codex fallback, state normalization, unknown state, unknown profile/runtime, exact one-route selection, and route fingerprints.
- [ ] Run them red.
- [ ] Add profile fields `name`, `responsibility`, `runtime`, `command`, `model`, `prompt`, `sandbox`, `max_turns`, and optional `concurrency_class`; recognize only `codex` and deferred merge runtime, reject unknown executable runtimes, and default absent profiles to planner/builder/reviewer/fixer plus a non-executable `merge_gatekeeper`.
- [ ] Keep legacy `codex.*` settings authoritative when profile overrides are absent. Normalize names/state keys using `Config.Schema.normalize_issue_state`.
- [ ] Resolve `planning`, `ready`, legacy `todo`, `in progress`, `in review`, `human review`, `changes requested`, `rework`, and `ready to merge` deterministically; refuse backlog/blocked/terminal/unknown states. Return a route containing issue ID, starting state, profile/runtime/responsibility, and a stable string fingerprint.
- [ ] Run focused tests and `mix test`.

## Task 3: SYM-05/SYM-06 route-aware execution and fresh boundaries

**Files:** AgentRunner, Orchestrator, route-boundary tests.

- [ ] Write failing fake-runtime tests for planner→builder, builder→reviewer, reviewer→fixer, and fixer→reviewer. The test must assert the first session receives a stop/termination signal and a later dispatch starts a new session identity; unchanged active state may continue within max turns.
- [ ] Run them red.
- [ ] Capture the route before `start_session`; use the selected profile prompt/max turns/runtime options. After every successful turn refresh the issue and re-resolve its route. Emit a non-secret route-change update and return control when the fingerprint differs.
- [ ] Store route/profile/runtime/responsibility/fingerprint in running entries. Reconcile refreshed running issues with the same comparison and stop/release the current task so the next poll can claim it afresh. Mark route-change completion distinctly so it never becomes an ordinary failure retry.
- [ ] Run focused tests, affected tests, `git diff --check`, and `mix test`.

## Task 4: SYM-07/SYM-08 dependency classification and guard

**Files:** Policy/Guard modules, dependency tests, Linear normalization tests.

- [ ] Write failing unit tests covering every configured lifecycle state, `Done` satisfaction, active unresolved blockers, canceled/other invalidated blockers, malformed blocker maps, and the policy table for planning/implementation/review/correction/merge.
- [ ] Run them red.
- [ ] Implement pure classifier output `:satisfied`, `:unresolved`, `:invalidated`, or explicit error; never infer success from generic terminal status.
- [ ] Implement guard decisions with machine-readable reason, blocker identifiers/states, and responsibility. Planning is allowed for active hard blockers; implementation/correction/merge fail closed; review may inspect existing work but does not grant merge permission; invalidated or unknown blockers fail closed for all unsafe responsibilities.
- [ ] Remove only the old Linear `Todo`-specific blocker veto that prevents the normalized `blocked_by` data from reaching planning policy; keep assignee/label dispatchability and all other adapter safety checks.
- [ ] Run focused and affected tests.

## Task 5: SYM-09/SYM-10 graph, cycles, and frontier dispatch

**Files:** Graph module, Orchestrator, state/projection tests.

- [ ] Write failing deterministic graph tests for A→B→C, A→B→C→A, multiple blockers, hidden/malformed blockers, cycle member reporting, and stable cycle ordering.
- [ ] Run them red.
- [ ] Build a graph from normalized issues and direct `blocked_by` edges; detect strongly connected/cyclic members without mutating Linear. Add explicit diagnostic entries for cycle and missing/inaccessible blocker outcomes.
- [ ] Integrate guard/cycle eligibility after existing candidate/routability checks and before spawn. Preserve current priority/tie-break sort and one Orchestrator claim authority. Skip unresolved blocked implementation, do not schedule retry churn, and retain planning eligibility where allowed.
- [ ] Re-evaluate dependency diagnostics from each fresh tracker poll; clear stale cycle/blocked diagnostics only after the refreshed graph proves the issue eligible. Keep active runtime-input blockers distinct from dependency blocks.
- [ ] Test blocked skip, unlock after blocker state becomes `Done`, multiple-blocker gating, independent concurrent issues, canceled blockers, cycles, and duplicate claims.
- [ ] Run affected suite and `mix test`.

## Task 6: SYM-11/SYM-12 prompts and sandbox enforcement

**Files:** role prompt files, PromptBuilder, Profile/Codex adapter/App Server, prompt/sandbox/security tests.

- [ ] Write failing tests that each route receives only its role policy and that effective sandbox settings are read-only for planner/reviewer and workspace-write for builder/fixer.
- [ ] Run them red.
- [ ] Add concise role policies: planner plans and stops; builder implements and stops at review; reviewer returns PASS/FAIL/BLOCKED without writes; fixer addresses findings without approval. Combine the role policy with the existing workflow prompt deterministically for routed attempts; preserve legacy prompt-only behavior when no route is supplied.
- [ ] Make profile sandbox override thread and turn policy safely. Map read-only to Codex read-only policies and workspace-write to the existing workspace-root policy; never default to danger-full-access. Pass profile command/model aliases to the Codex adapter as configuration, not domain logic.
- [ ] Preserve secret-environment stripping and workspace path validation, and add tests for no secret leakage and no path-safety regression.
- [ ] Run focused tests and affected suite.

## Task 7: SYM-13 observability

**Files:** Orchestrator snapshot, Presenter/API, dashboard, PubSub, observability tests.

- [ ] Write failing projection tests asserting route/profile/runtime/responsibility, dependency status/reasons, attempt/session data, and route-change termination reason appear in snapshots/API/dashboard-safe rows without tokens or command environments.
- [ ] Run them red.
- [ ] Add normalized non-secret metadata to running/retry/blocked/diagnostic projections. Reuse `ObservabilityPubSub.broadcast_update/0` for start/end, route changes, and dependency graph changes; do not add a polling mechanism.
- [ ] Add compact role/dependency columns/labels to the existing terminal and LiveView dashboard while keeping snapshot compatibility for old fields.
- [ ] Run focused, snapshot, API, and `mix test` checks.

## Task 8: SYM-14 Codex-only lifecycle proof

**Files:** integration tests/proof document, test support fixtures.

- [ ] Add a disposable fake-tracker/fake-Codex proof harness that records session IDs, route fingerprints, transitions, PR/review evidence placeholders, and auto-merge configuration.
- [ ] Run the proof red until it demonstrates the complete sequence: Planning→Ready→In Progress→In Review→Changes Requested→In Review→Ready to Merge.
- [ ] Execute the green proof with fresh session identities at every responsibility boundary, maximum three review cycles, exact updated-review sequencing, no source writes in planner/reviewer, and auto-merge disabled.
- [ ] Record actual command output and evidence in `docs/symphony-agent-router-dependency-proof.md`; do not claim live Linear/GitHub proof unless credentials and disposable resources were actually used.

## Task 9: SYM-15 full dependency-DAG proof

**Files:** integration proof harness/documentation only; no production bypasses.

- [ ] Create disposable graph fixtures with independent frontier items, a planning-allowed dependent, a hard implementation dependent, a canceled blocker, and a cycle.
- [ ] Run the end-to-end harness against fresh tracker relation/state refreshes and assert dispatch sequence, blocked reasons, unlock only after `Done`, canceled-blocker refusal, cycle diagnostic/no churn, concurrency limits, and no duplicate claim.
- [ ] Capture final states, route/session IDs, dependency snapshots, PubSub/API evidence, and automatic-merge-disabled evidence in the proof document.
- [ ] Run the full required gates: focused tests, affected tests, `make -C elixir all`, `git diff --check`; inspect for unexpected dependencies, migrations, secrets, Cursor code, or automatic merge.

## Final verification audit

- [ ] Re-read every numbered MVP invariant and SYM-01→SYM-15 output against current files and test/proof evidence.
- [ ] Run `git status --short --branch`, `git diff --check`, `make -C elixir all`, and inspect the complete diff.
- [ ] Confirm no unverified live external claim is presented as proof, no role boundary reuses a runtime session, no unresolved hard implementation blocker dispatches, cycles do not churn, and auto-merge/Cursor remain disabled.
- [ ] Request an independent code review of the final exact HEAD before any integration/merge action.
