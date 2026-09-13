# Symphony Agent Router and Dependency Proof

Status: local deterministic proof complete for SYM-14 and SYM-15. Automatic
merge remains disabled. No Cursor runtime or second scheduler is included.

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

## SYM-14 lifecycle evidence

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

## SYM-15 dependency-DAG evidence

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
