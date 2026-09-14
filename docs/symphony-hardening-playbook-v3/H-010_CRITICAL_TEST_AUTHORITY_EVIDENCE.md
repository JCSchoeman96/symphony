# H-010 — Critical Test Authority Evidence

This document records the H-010 coverage-authority change and the deterministic
contract tests added on top of baseline `004a2348c72ccc09ef03961bba95aa8163e47273`.
It is implementation evidence, not an independent acceptance verdict.

## Scope and baseline

- Starting commit: `004a2348c72ccc09ef03961bba95aa8163e47273`
- Production runtime behavior: unchanged
- Production modules changed: none
- Live provider credentials/resources: none
- H-020: not started

Before H-010, `elixir/mix.exs` reported a 100% threshold while excluding six
safety-critical execution modules. Removing those exclusions produced a
truthful complete baseline of 87.45% before the additional contract tests.
After the tests below, the complete aggregate is 90.18% across 452 tests, with
6 skips. The configured threshold is 90%; the one-point integer setting is the
closest lower value available to the built-in coverage summary and is below,
not above, the measured complete baseline.

The old 100% result was not a whole-control-plane result. The 90% threshold is
therefore a documented regression gate for the complete included module set;
the safety-contract matrix and pure policy-module coverage remain the primary
authority for behavior.

## Exclusion inventory

The following is the complete inventory before the H-010 change. “Include”
means the entry was removed from `ignore_modules`.

| Module | Current exclusion | Safety classification | Action | Justification |
| --- | --- | --- | --- | --- |
| `SymphonyElixir.Asana.Client` | Yes | B — review required | Keep | Legacy provider client; not the current Linear control-plane path. |
| `SymphonyElixir.Config` | Yes | B — review required | Keep | Configuration facade; schema modules are included and own normalized policy values, while this broad workflow-loading facade is not a transition authority. |
| `SymphonyElixir.GitHub.Client` | Yes | B — review required | Keep | Legacy provider client; not the current Linear control-plane path. |
| `SymphonyElixir.GitLab.Client` | Yes | B — review required | Keep | Legacy provider client; not the current Linear control-plane path. |
| `SymphonyElixir.Jira.Client` | Yes | B — review required | Keep | Legacy provider client; not the current Linear control-plane path. |
| `SymphonyElixir.Linear.Client` | Yes | A — safety critical | Include | Current provider read and dependency-completeness boundary. |
| `SymphonyElixir.SpecsCheck` | Yes | C — infrastructure | Keep | Build/specification-check task, not runtime control-plane behavior. |
| `SymphonyElixir.Orchestrator` | Yes | A — safety critical | Include | Owns running-work reconciliation, retries, stops, and dispatch claims. |
| `SymphonyElixir.Orchestrator.State` | Yes | A — safety critical | Include | Owns the orchestrator state projection used by those decisions. |
| `SymphonyElixir.AgentRunner` | Yes | A — safety critical | Include | Owns attempt execution, continuation, route refresh, and dependency-stop behavior. |
| `SymphonyElixir.Application` | Yes | C — infrastructure | Keep | OTP application/supervision startup wiring. |
| `SymphonyElixir.CLI` | Yes | C — infrastructure | Keep | Escript argument and startup entrypoint. |
| `SymphonyElixir.Codex.AppServer` | Yes | A — safety critical | Include | Runtime session, turn, approval, tool, failure, and stop boundary. |
| `SymphonyElixir.Codex.DynamicTool` | Yes | A — safety critical | Include | Responsibility-bound tool and transition authorization boundary. |
| `SymphonyElixir.HttpServer` | Yes | C — infrastructure | Keep | Optional observability endpoint startup and binding. |
| `SymphonyElixir.StatusDashboard` | Yes | C — UI/operational presentation | Keep | Terminal rendering and refresh scheduling; it does not authorize dispatch or transitions. |
| `SymphonyElixir.LogFile` | Yes | C — infrastructure | Keep | OTP rotating log-handler setup. |
| `SymphonyElixir.Workspace` | Yes | B — review required | Keep | Workspace lifecycle/cleanup facade; path authorization is covered by included `PathSafety` and AppServer boundary tests, while full local/SSH lifecycle is outside H-010. |
| `SymphonyElixirWeb.DashboardLive` | Yes | C — UI | Keep | Phoenix LiveView dashboard presentation. |
| `SymphonyElixirWeb.Endpoint` | Yes | C — infrastructure | Keep | Phoenix endpoint wiring. |
| `SymphonyElixirWeb.ErrorHTML` | Yes | C — generated presentation | Keep | Phoenix error rendering. |
| `SymphonyElixirWeb.ErrorJSON` | Yes | C — generated presentation | Keep | Phoenix error rendering. |
| `SymphonyElixirWeb.Layouts` | Yes | C — UI | Keep | Phoenix layout presentation. |
| `SymphonyElixirWeb.ObservabilityApiController` | Yes | B — review required | Keep | Read-only observability API; it projects state and cannot authorize work. |
| `SymphonyElixirWeb.Presenter` | Yes | B — review required | Keep | Read-only observability projections; lifecycle/transition authority remains in included modules. |
| `SymphonyElixirWeb.StaticAssetController` | Yes | C — UI/infrastructure | Keep | Static asset delivery. |
| `SymphonyElixirWeb.StaticAssets` | Yes | C — UI/infrastructure | Keep | Static asset loading and digesting. |
| `SymphonyElixirWeb.Router` | Yes | C — UI/infrastructure | Keep | Phoenix route declarations. |
| `SymphonyElixirWeb.Router.Helpers` | Yes | C — generated infrastructure | Keep | Generated route helpers. |

After the change, the six Category A entries above are no longer in
`ignore_modules`. No replacement exclusion or no-cover directive was added.
The remaining 23 exclusions are exactly the Category B/C entries marked
“Keep” in the table.

## Safety-contract evidence

Existing deterministic suites and the H-010 additions cover the required
contracts as follows:

| Contract | Evidence |
| --- | --- |
| WorkItem transition authority | `transition_policy_test.exs`, `dependency_policy_test.exs`, `agent_router_orchestrator_test.exs`, and `dynamic_tool_test.exs` cover allowed handoffs, denied responsibility changes, reviewer paths, merge non-executability, stale/incomplete dependency denial, and fixer context. |
| AgentAttempt / AttemptPolicy | `agent_runtime_test.exs`, `agent_router_dependency_proof_test.exs`, and orchestrator tests cover failure/stop accounting, fresh-session responsibility boundaries, continuation, route changes, dependency stops, retry claims, and reviewer-cycle evidence. |
| RuntimeSession | `app_server_test.exs`, `app_server_edge_test.exs`, and `agent_runtime_test.exs` cover startup success/failure, active turns, turn failures, cancellation/input blockers, explicit stop, closed/stopped behavior, and fresh-session boundaries. |
| Running Orchestrator reconciliation | `agent_router_orchestrator_test.exs`, `agent_router_dependency_proof_test.exs`, `agent_runtime_test.exs`, and `orchestrator_status_test.exs` cover route-change stops, dependency reappearance, stale worker messages, retry refresh, and capacity/stop observability. |
| Dependency completeness | `dependency_completeness_test.exs`, `dependency_graph_test.exs`, `dependency_policy_test.exs`, `agent_router_dependency_proof_test.exs`, and `linear_client_test.exs` cover verified empty graphs, incomplete/provider-error states, pagination, missing/malformed blockers, self- and multi-node cycles, and independent components. |
| Dynamic tool / transition boundary | `dynamic_tool_test.exs`, `app_server_test.exs`, and `app_server_edge_test.exs` cover raw mutation denial, bound responsibility authorization, stable session binding, provider-secret isolation, unsupported calls, approval policy, and safe tool-result normalization. |

The new H-010 tests are meaningful contract tests rather than line-execution
probes:

- `linear_client_test.exs` uses injected GraphQL functions and a disposable
  local TCP HTTP server to exercise public read/error/pagination contracts
  without a live provider.
- `app_server_edge_test.exs` uses a deterministic fake app-server process and
  explicit protocol lines to exercise startup, turn, failure, approval, and
  tool boundaries without arbitrary sleeps.
- `dynamic_tool_test.exs` covers the default-options facade arity.
- `orchestrator_status_test.exs` covers fail-closed, redacted observability
  projections for malformed and sensitive values.

The new tests add no `Process.sleep/1`. Existing sleeps remain in the suite
only as bounded observation windows, timeout behavior, or live-provider/SSH
coverage and were reviewed rather than mechanically removed.

## Coverage authority

With all Category A modules included, the final measured module coverage is:

| Module | Coverage |
| --- | ---: |
| `SymphonyElixir.Orchestrator` | 79.55% |
| `SymphonyElixir.Orchestrator.State` | 100.00% |
| `SymphonyElixir.AgentRunner` | 88.41% |
| `SymphonyElixir.AgentRuntime` | 100.00% |
| `SymphonyElixir.AgentRuntime.Codex` | 100.00% |
| `SymphonyElixir.AgentRuntime.AttemptPolicy` | 100.00% |
| `SymphonyElixir.AgentRuntime.Profile` | 100.00% |
| `SymphonyElixir.AgentRuntime.Route` | 100.00% |
| `SymphonyElixir.AgentRuntime.Router` | 100.00% |
| `SymphonyElixir.Tracker` | 100.00% |
| `SymphonyElixir.Tracker.TransitionPolicy` | 100.00% |
| `SymphonyElixir.Dependency.Policy` | 100.00% |
| `SymphonyElixir.Dependency.Guard` | 100.00% |
| `SymphonyElixir.Dependency.Graph` | 100.00% |
| `SymphonyElixir.Linear.Adapter` | 100.00% |
| `SymphonyElixir.Linear.Client` | 89.22% |
| `SymphonyElixir.Linear.AgentTool` | 100.00% |
| `SymphonyElixir.Codex.AppServer` | 85.16% |
| `SymphonyElixir.Codex.DynamicTool` | 100.00% |
| `SymphonyElixir.PromptBuilder` | 100.00% |
| Complete included module set | **90.18%** |

Pure policy modules remain at 100%. Process/provider modules are included and
their invariant tests are authoritative even where line coverage is below
100%; aggregate line coverage is the 90% regression signal, not a substitute
for those behavioral assertions.

## Validation record

The configured coverage command is:

```text
mise exec -- mix test --cover --seed 0
```

The final validation record for this branch is:

- focused AppServer boundary tests: 9 passed;
- complete seeded suite: 452 passed, 0 failures, 6 skipped;
- `mix format --check-formatted`: passed;
- `mix lint`: specs check passed and strict Credo found no issues;
- `mix dialyzer`: passed with 0 errors;
- `mise exec -- make all`: passed on the rerun, including the configured 90%
  coverage gate;
- `git diff --check`: passed.

One earlier `make all` attempt hit an existing timing-sensitive assertion in
`core_test.exs:1127` (8,739 ms observed against a 9,000 ms lower bound). The
test passed in isolation and the complete target passed on rerun; H-010 did not
modify that test or any production module.

This evidence is included in the local H-010 implementation commit. No remote
branch update, PR, or merge was performed.
