# Canonical Work Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement P-010's provider-neutral work-control boundary so routed Symphony decisions use validated canonical lifecycle semantics and never treat a raw provider state as positive authority.

**Architecture:** Keep `Tracker.Issue` as a raw provider compatibility DTO. Build immutable `ProviderObservation` values, assess them through the exact `WorkflowLifecycle` state and transition law, then project `AuthorityDisposition` and an ephemeral `WorkItem`. `Router`, `TransitionPolicy`, dependency completion, `Orchestrator`, and routed `AgentRunner` consume that projection. Legacy provider-state dispatch remains available only on the existing legacy path.

**Tech Stack:** Elixir structs and pure functions, existing Tracker/Memory/Linear seams, ExUnit, `mise`, `mix`, and the existing H-030 DETS AttemptLedger.

---

## Scope and invariants

- Use only the exact accepted `origin/main` baseline already established for this worktree.
- Keep the canonical vocabulary to the eleven V4.1 states; provider aliases stay in raw/legacy compatibility code.
- Keep `ProviderObservation`, `LifecycleAssessment`, and `AuthorityDisposition` as separate values.
- Preserve the exact H-020 capability names/statuses and H-030 AttemptLineage, durable ordering, retry exhaustion, and explicit rearm behavior.
- Do not add Plane HTTP/project-contract code, CandidateRef/GitHub completion code, RuntimeAttempt identity, durable suspension storage, a new persistence layer, autonomous merge, or P-020+ work.

## Task 1: Canonical lifecycle law and guard classes (TDD)

Files:

- Add `elixir/lib/symphony_elixir/work_control/guard_class.ex`.
- Add `elixir/lib/symphony_elixir/work_control/workflow_lifecycle.ex`.
- Add `elixir/test/symphony_elixir/work_control_workflow_lifecycle_test.exs`.

Steps:

- [ ] Add deterministic tests for all eleven canonical states, exact parsing/display, state classification, owner/responsibility, dispatchability, terminality, and successful terminality. Assert `Blocked` is not dispatchable, `Done` and `Canceled` are both terminal, and only validated completion semantics can make `Done` successful.
- [ ] Add tests for every required legal transition and for every unspecified source/target pair. Explicitly assert `Ready -> In Review` is invalid and aliases such as `Todo`, `Open`, `Started`, `Rework`, `Closed`, and `Cancelled` do not parse as canonical states.
- [ ] Add tests that transition metadata preserves owner, responsibility, guard classes, typed guard names, and side-effect metadata; specifically assert human-controlled `Ready to Merge -> Merging` does not grant autonomous merge permission and `Merging -> Done` requires `:completion_proof_verified` as a `:mechanical_guard`.
- [ ] Add tests proving guard classes are not interchangeable: a semantic attestation cannot satisfy a mechanical requirement, a mechanical guard cannot satisfy a human decision, and an untyped/provider state string is not guard evidence.
- [ ] Run the new file with `mise exec -- mix test test/symphony_elixir/work_control_workflow_lifecycle_test.exs --seed 0` and observe the expected RED failure before adding production modules.
- [ ] Implement the smallest pure API: exact canonical atoms/display names, parsing, classification, owner/responsibility, dispatchability, terminal predicates, legal transition lookup/validity, guard requirements, and side-effect metadata. Use explicit guard classes and typed requirement names; do not add a numeric rank.
- [ ] Run the focused test again, then `mise exec -- mix format` on changed Elixir files and the focused test until GREEN.

## Task 2: Observation, assessment, disposition, suspension, and WorkItem (TDD)

Files:

- Add `elixir/lib/symphony_elixir/work_control/provider_observation.ex`.
- Add `elixir/lib/symphony_elixir/work_control/lifecycle_assessment.ex`.
- Add `elixir/lib/symphony_elixir/work_control/authority_disposition.ex`.
- Add `elixir/lib/symphony_elixir/work_control/suspension_context.ex`.
- Add `elixir/lib/symphony_elixir/work_control/work_item.ex`.
- Add `elixir/test/symphony_elixir/work_control_assessment_test.exs`.
- Add `elixir/test/symphony_elixir/work_control_work_item_test.exs`.

Steps:

- [ ] Write tests first for immutable observation construction from a raw issue, mapping without authorization, missing stable IDs remaining unvalidated identity, and unknown/malformed provider state failing closed.
- [ ] Write assessment tests for `Unassessed -> MappingResolved ->` each terminal result, new observation creating a new assessment, corroborated trusted state validating, initial `Backlog` being accepted without authority, cancellation and recognized `Blocked` reducing authority, bare/forward `Ready`, `In Review`, and `Ready to Merge` requiring validation, raw `Done` requiring completion proof, impossible transitions being invalid, and legal forward transitions missing guards being validation-required.
- [ ] Write guard/evidence tests for exact class/name matching and for validated `Done` only with `:completion_proof_verified`.
- [ ] Write disposition tests for `None`, `Eligible`, `Active`, `Suspended`, and `Escalated`, including reason-specific recovery and terminal autonomous recovery prohibition. Write suspension tests for `Open -> Resolving -> Resolved|Escalated` and the required policy fields.
- [ ] Write WorkItem tests proving composition of provider identity/metadata, observation, assessment, canonical state, disposition, optional suspension, and dependency metadata; assert raw forward states do not become dispatchable and raw `Done` does not satisfy completion.
- [ ] Run the new tests and observe RED failures before creating the modules.
- [ ] Implement the structs and pure constructors/transition functions. Use explicit timestamps supplied by tests where needed; default timestamps must not affect deterministic assertions. Keep WorkItem ephemeral and do not introduce persistence.
- [ ] Run the focused assessment and WorkItem tests, then format and re-run all new work-control tests.

## Task 3: Migrate Router and TransitionPolicy to canonical law

Files:

- Modify `elixir/lib/symphony_elixir/agent_runtime/router.ex`.
- Modify `elixir/lib/symphony_elixir/tracker/transition_policy.ex`.
- Modify `elixir/test/symphony_elixir/agent_router_test.exs`.
- Modify `elixir/test/symphony_elixir/transition_policy_test.exs`.
- Inspect `elixir/lib/symphony_elixir/agent_runtime/route.ex` and change it only if required by the compatibility seam.

Steps:

- [ ] Add failing routed tests showing Router accepts only a validated canonical WorkItem, derives responsibility from WorkflowLifecycle, and rejects raw provider `Ready`, `In Review`, and `Ready to Merge` as authority. Assert route overrides can choose a profile only when its responsibility matches the canonical owner and cannot redefine lifecycle ownership.
- [ ] Preserve/cover the legacy compatibility path separately; aliases and configured provider active/terminal lists may continue there but must not be used by canonical routed resolution.
- [ ] Add failing TransitionPolicy tests for every canonical transition owner/guard requirement and for rejection of `Ready -> In Review`. Assert it delegates to WorkflowLifecycle and does not keep a private handoff table.
- [ ] Implement Router's canonical WorkItem seam and keep profile selection separate from lifecycle ownership. Remove the competing routed alias/handoff semantics; leave legacy behavior explicit and isolated.
- [ ] Implement TransitionPolicy delegation to WorkflowLifecycle while retaining existing dependency checks and bounded semantic intent behavior. Ensure canonical context is required for routed authorization and raw provider text alone cannot authorize a forward transition.
- [ ] Run `mise exec -- mix test test/symphony_elixir/agent_router_test.exs test/symphony_elixir/transition_policy_test.exs --seed 0` and the new work-control tests.

## Task 4: Tracker/Memory and Linear semantic transition boundary

Files:

- Modify `elixir/lib/symphony_elixir/tracker/memory.ex` only around canonical transition validation.
- Modify `elixir/lib/symphony_elixir/linear/agent_tool.ex` only where fresh observation is reconciled with trusted canonical context.
- Modify `elixir/lib/symphony_elixir/tracker/issue.ex` only if a compatibility constructor/helper is necessary.
- Leave `elixir/lib/symphony_elixir/tracker.ex`, `elixir/lib/symphony_elixir/linear/adapter.ex`, and `elixir/lib/symphony_elixir/linear/client.ex` unchanged unless compilation proves a tiny observation bridge is required.
- Modify `elixir/test/symphony_elixir/tracker_memory_test.exs` and `elixir/test/symphony_elixir/transition_freshness_test.exs` only for the intentional authority contract.

Steps:

- [ ] Add a failing Memory/transition-freshness test that a fresh provider observation is checked against trusted canonical current state before semantic transition authorization.
- [ ] Add a failing test that provider `Blocked` or unsafe divergence suspends local authority without calling `Tracker.transition_state`.
- [ ] Preserve exact H-020 capability tests and existing controlled mutation/verification behavior. Do not add mutation retries or durable transition attempts.
- [ ] Implement the narrow observation/context check in Linear AgentTool and delegate final transition law to TransitionPolicy. Keep provider reads at existing refresh points and do not add a persistence layer.
- [ ] Run `tracker_memory_test.exs`, `transition_freshness_test.exs`, `dynamic_tool_test.exs`, and the complete capability suite with seed zero.

## Task 5: Dependency completion semantics

Files:

- Modify `elixir/lib/symphony_elixir/dependency/policy.ex`.
- Modify `elixir/lib/symphony_elixir/dependency/guard.ex`.
- Leave `elixir/lib/symphony_elixir/dependency/graph.ex` unchanged except for a mechanical compatibility adjustment if compilation requires it.
- Modify `elixir/test/symphony_elixir/dependency_policy_test.exs`, `dependency_completeness_test.exs`, and related dependency tests.

Steps:

- [ ] Add failing tests asserting raw provider `Done` is unresolved/not satisfied, raw or canonical `Canceled` is invalidated and never satisfied, and unknown/malformed/unassessed state fails closed.
- [ ] Add failing tests asserting a WorkItem with validated canonical `Done` plus typed `:completion_proof_verified` satisfies a prerequisite, while a validated-looking `Done` without that mechanical guard does not.
- [ ] Implement Policy/Guard support for canonical WorkItem/assessment inputs while preserving legacy provider compatibility for non-routed dependency evaluation. Remove raw provider `Done` as a successful completion path.
- [ ] Run all dependency policy, guard, graph, completeness, and Orchestrator dependency tests with seed zero.

## Task 6: Routed Orchestrator authority projection and reconciliation

Files:

- Modify `elixir/lib/symphony_elixir/orchestrator.ex` narrowly.
- Modify `elixir/test/symphony_elixir/agent_router_orchestrator_test.exs` and other Orchestrator route/dependency tests as required by the new contract.
- Do not modify AttemptLedger or AttemptPolicy.

Steps:

- [ ] Add failing routed tests for derived ephemeral WorkItem storage, conservative initial dispatch, validated dispatch, retry revalidation, running-worker reconciliation, dependency changes, and authority-reducing/validation-required/invalid observations stopping local work without provider mutation.
- [ ] Add a restart/failure test or state-level assertion proving positive routed authority is not reconstructed from raw provider state after restart; existing H-030 state remains untouched.
- [ ] Implement the minimal `work_control` map in existing Orchestrator state. Reuse existing fresh issue reads; derive observations/assessments/WorkItems at those points only. Gate routed dispatch, retry, running reconciliation, blocked reconciliation, and dependency decisions on the WorkItem disposition/lifecycle.
- [ ] Keep legacy dispatch on configured active/terminal provider lists and aliases. Preserve existing claim/retry/lineage ordering and do not make lifecycle recovery rearm attempts.
- [ ] Run Orchestrator route/dependency tests plus all AttemptLedger, lineage, rearm, and observability suites.

## Task 7: Routed AgentRunner continuation

Files:

- Modify `elixir/lib/symphony_elixir/agent_runner.ex` narrowly.
- Modify `elixir/test/symphony_elixir/agent_runtime_test.exs` and route/continuation tests.

Steps:

- [ ] Add failing tests that a routed runner carries WorkItem context, continues only when a fresh observation corroborates the trusted validated state, stops/suspends on cancellation, Blocked, or unsafe forward divergence, and never silently reroutes from raw provider state.
- [ ] Implement the narrow continuation/reconciliation check and an explicit narrow Orchestrator notification if needed. Keep legacy runner behavior and profile execution intact.
- [ ] Run AgentRunner/runtime tests, Router tests, transition freshness tests, and dynamic-tool tests.

## Task 8: Configured routed route validation and compatibility audit

Files:

- Modify `elixir/lib/symphony_elixir/config/schema.ex` only for routed route-state validation.
- Inspect/update `elixir/lib/symphony_elixir/workflow.ex` only if a compile-time compatibility seam requires it; it remains the config/prompt loader, not lifecycle law.
- Do not alter `WORKFLOW.md` or authority documents.

Steps:

- [ ] Add or update tests proving configured `active_states` and `terminal_states` remain valid legacy/provider fetch-scope data but cannot grant routed canonical authority.
- [ ] Reject routed route states that are provider aliases or unknown canonical names; retain legacy route validation behavior where required.
- [ ] Run config, workflow, Router, and compatibility tests.

## Task 9: Full regression and exact diff review

From `elixir/`, run each command independently and record the exact result:

- [ ] `mise exec -- mix test --cover --seed 0`.
- [ ] `mise exec -- mix format --check-formatted`.
- [ ] `mise exec -- mix lint`.
- [ ] `mise exec -- mix dialyzer`.
- [ ] `mise exec -- make all`.

Run the focused regression set, at minimum:

- [ ] `work_control_*` tests.
- [ ] `agent_router_test.exs`, `transition_policy_test.exs`, `dependency_policy_test.exs`, `agent_router_orchestrator_test.exs`, `agent_runtime_test.exs`, `tracker_memory_test.exs`.
- [ ] `tracker_capabilities_test.exs`, `transition_freshness_test.exs`, `dynamic_tool_test.exs`, `dependency_graph_test.exs`, `dependency_completeness_test.exs`.
- [ ] `attempt_ledger_test.exs`, `orchestrator_attempt_lineage_test.exs`, `mix/tasks/attempt_rearm_task_test.exs`, `observability_contract_test.exs`.

From the repository root:

- [ ] Run `git diff --check`.
- [ ] Review `git status --short`, `git diff --stat origin/main`, and `git diff origin/main`.
- [ ] Confirm no aliases entered canonical law, no second lifecycle authority remains, raw `Done` cannot satisfy dependencies, H-020/H-030 semantics are unchanged, and no P-020+ artifacts exist.

## Task 10: Commit, push, PR, and CI inspection

- [ ] Commit only the coherent P-010 changes with the required conventional message/body and record `git rev-parse HEAD`.
- [ ] Fetch `origin` immediately before push and verify the authorized main SHA/tree are unchanged; stop if either moved.
- [ ] Push only `hardening/p-010-canonical-work-control`.
- [ ] Read `.github/pull_request_template.md`, create a temporary PR body with exactly its five sections and required test-plan entries, and validate it with `cd elixir && mise exec -- mix pr_body.check --file /path/to/pr_body.md`.
- [ ] Open exactly one PR against `main` with `gh`; never merge it.
- [ ] Inspect PR metadata and exact candidate SHA with `gh`; confirm base `main`, head branch, head SHA, and authorized base SHA.
- [ ] Inspect all PR checks to completion where possible. If a P-010-owned failure occurs, fix only within scope, rerun all affected gates, push, reverify head/base, and inspect CI again. Report unrelated/environmental/scope-expanding failures without improvisation.
- [ ] Independently review `origin/main...HEAD` and the exact PR diff. Confirm only P-010 was implemented and report that the PR was not merged.
