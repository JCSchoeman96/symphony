# Symphony Agent Router and Dependency Proof

Status: deterministic component proof is current through the remediation
implementation. Optional live proof remains externally blocked until named
disposable resources and explicit consent are supplied. Automatic merge
remains disabled. No Cursor runtime or second scheduler is included.

## Executable proof

The proof is implemented in
[`agent_router_dependency_proof_test.exs`](../elixir/test/symphony_elixir/agent_router_dependency_proof_test.exs).
It uses the production `AgentRunner`, `Router`, `Guard`, `Graph`, and
`Orchestrator` with disposable in-memory tracker data and contract test
doubles for Codex and the worker. The worker double receives fresh tracker
relation/state snapshots from the test fixture; it does not bypass the
dependency guard.

Command and actual output:

```text
$ cd elixir && mix test test/symphony_elixir/agent_router_dependency_proof_test.exs --seed 0
Running ExUnit with seed: 0, max_cases: 48
..
Finished in 0.7 seconds (0.00s async, 0.7s sync)
2 tests, 0 failures
```

## SYM-14 deterministic lifecycle evidence (not live completion)

The proof follows the required state sequence:

```text
Planning → Ready → In Progress → In Review → Changes Requested
          → In Review → Ready to Merge
```

The recorded assertions establish:

- `planner → builder → reviewer → fixer → reviewer` resolves deterministically;
- all executable stages use the Codex runtime route;
- every role boundary has a distinct session identity;
- the builder keeps one session for its two same-responsibility turns;
- the two review stages are within the maximum three review cycles;
- planner and reviewer routes use `read-only`, while builder and fixer use
  `workspace-write`;
- the builder receives the pull-request handoff policy, reviewers receive the
  exact-head review policy, and the fixer receives the findings-only policy;
- `Ready to Merge` resolves to the deferred `merge_gatekeeper` route and no
  `auto_merge` configuration exists.

## SYM-15 deterministic dependency-DAG evidence (not live completion)

The disposable fixture contains the required fan-out/fan-in graph plus an
independent item, a canceled blocker, and the cycle `X → Y → Z → X`.

The actual scheduler dispatch sequence asserted by the proof is:

```text
A, independent
B, C                         # A relation state is Done
D, E, F, G                   # B and C relation states are Done
H                            # only after both F and G relation states are Done
```

The proof also asserts that:

- `B`/`C` do not dispatch while `A` is unresolved;
- `H` does not dispatch after only `F` is Done;
- the canceled-blocker dependent never dispatches;
- no member of `X/Y/Z` dispatches;
- the cycle is surfaced as one stable diagnostic with sorted members;
- all dispatched issue IDs are unique, so the scheduler does not duplicate a
  claim;
- final `A` through `H` and the independent issue are `Done`, while the
  canceled-blocker dependent and cycle remain non-dispatched;
- the final Orchestrator snapshot contains the dependency decisions and cycle
  evidence without secrets.

Native Linear relation normalization is separately covered by the Linear
adapter tests. This proof intentionally does not create or mutate a live
Linear/GitHub project: no external credentials or disposable project identity
were supplied, so the result makes no unverified live-integration claim.

## Deterministic proof inventory

The local evidence is deliberately split by invariant and uses production code
with in-memory/provider-shaped fixtures:

- `agent_router_dependency_proof_test.exs` covers the routed lifecycle,
  dependency fan-out/fan-in, canceled blockers, cyclic components, independent
  progress, claims, and final diagnostics.
- `dependency_completeness_test.exs` and `dependency_graph_test.exs` cover
  complete graph acquisition, pagination, missing/malformed data, and cycle
  handling.
- `agent_router_orchestrator_test.exs` and `core_test.exs` cover poll
  interruption, stale process messages, capacity accounting, and retry/review
  limits using real OTP process boundaries.
- `role_prompt_test.exs`, `profile_runtime_test.exs`, and
  `agent_runtime_test.exs` cover role policy, reload/LKG behavior, active-attempt
  stability, and model/runtime propagation across turns.
- `transition_policy_test.exs` and `dynamic_tool_test.exs` cover the
  workflow-controlled Linear transition boundary and safe failure payloads.
- `observability_contract_test.exs` and the status/API/dashboard tests cover
  termination reasons, dependency/capacity distinctions, and redaction.
- `live_proof_gate_test.exs` covers the consent/configuration refusal path for
  optional external tests.

Run the complete deterministic gate from `elixir`:

```bash
mise exec -- make all
```

The validation matrix records the exact focused commands, test counts, and
remediation commits. These tests prove component behavior only; they do not
prove access to a real provider, a real Codex account, or a deployed topology.

## Opt-in live-proof procedure

Every provider live test is skipped unless all of the following are true at
test compilation time:

1. Its provider-specific run flag is `1`.
2. `SYMPHONY_LIVE_PROOF_CONSENT` is exactly
   `I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES`.
3. The provider credential is present.
4. The disposable provider scope is explicitly named.
5. `SYMPHONY_LIVE_CODEX_HOME` names a Codex home containing `auth.json`.

The gate reports only missing variable names and safe reasons; it never prints
credential values. It does not infer that a resource is disposable from its
name, so the operator remains responsible for supplying a scratch scope.

For the Linear proof, configure a disposable team and run:

```bash
cd elixir
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_RUN_LIVE_E2E=1
export LINEAR_API_KEY='[secret omitted]'
export SYMPHONY_LIVE_LINEAR_TEAM_KEY='[named disposable team key]'
export SYMPHONY_LIVE_CODEX_HOME='/absolute/path/to/disposable-codex-home'
mise exec -- mix test test/symphony_elixir/live_e2e_test.exs --seed 0
```

The Linear test creates a uniquely named disposable project and issue, runs a
real local and SSH worker scenario, reads issue context through read-only
`linear_graphql`, and asks Codex to use `linear_transition` to move the issue
to `In Review`. Its harness-only cleanup may use the direct API afterward; the
agent boundary still rejects raw Linear GraphQL mutations. The issue and
project cleanup are best-effort and should be checked in the named scratch
team.

For the GitHub proof, configure a scratch repository and run:

```bash
cd elixir
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_RUN_GITHUB_LIVE_E2E=1
export GITHUB_TOKEN='[secret omitted]'
export SYMPHONY_LIVE_GITHUB_REPO='owner/named-disposable-repository'
export SYMPHONY_LIVE_CODEX_HOME='/absolute/path/to/disposable-codex-home'
mise exec -- mix test test/symphony_elixir/github_live_e2e_test.exs --seed 0
```

The other optional provider smoke tests use the same consent and explicit
Codex-home gate plus their provider-specific named scope and credential. The
default `make all` run skips all six external tests; skipped is not passed and
no live Linear/GitHub/Codex claim is made without captured external artifacts.

## Observability and safety evidence

The existing projection tests cover route/profile/runtime/responsibility,
dependency reasons, route-change metadata, dashboard labels, and secret
redaction in the Presenter/API and terminal/LiveView surfaces. The proof and
projection tests assert that API keys and secrets-bearing runtime command text
are absent from the exposed metadata.

Automatic merge is still disabled: the merge route is explicitly deferred and
the agent configuration has no automatic-merge setting. The implementation
stops here pending independent architectural review and explicit authorization
for any future Cursor or merge phase.
