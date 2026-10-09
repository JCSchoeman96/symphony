# AgentRunner baseline isolation remediation execution ledger

## Run identity

- Accepted baseline: `09b72591d33fbe88243bceb584f85fca1f6fc819`
- Worktree: `.worktrees/agent-runner-isolation-baseline`
- Branch: `remediation/agent-runner-isolation-baseline`
- Comparison seed: `922982`
- PRE-080C-02 candidate diff SHA-256 before investigation: `585839c6ebda4cbd54da30c36e81787f2d04a5f3e0addbdadc47df668fd35357`
- Elixir: `1.19.5`
- Erlang/OTP: `28`

## Evidence log

| # | Admission stage / question | Hypothesis | Experiment | Result | Ruling |
|---:|---|---|---|---|---|
| 1 | Baseline reproduction | The 11 known AgentRunner failures reproduce on the clean accepted baseline at seed `922982`. | `mix test test/symphony_elixir/agent_runtime_test.exs --seed 922982` | Reproduced: 20 tests, 11 failures. The failing test names, order, and assertion sites match the recorded A/B comparison. Nine failures receive `:workspace_identity_or_runtime_unproven`; two exception assertions do not reach their expected exception. | The failure is present at the accepted baseline. Keep all test and runtime isolation assertions in scope. |
| 2 | First admission check | One of the ordered routed local admission checks rejects the `same-route` fixture. | Temporary stage diagnostic, with `TestSupport`, the actual workflow/ownership ledger setup, and the same work item and route as the failing test. | `workspace_ownership`, `credential_residue`, and `codex_executable` pass. `runtime_admission` fails as `codex_identity_failed/unsupported_codex_version`. | The first rejected check is runtime admission. Do not alter workspace ownership or credential checks. |
| 3 | Runtime identity detail | The runtime admission failure is caused by the host Codex version rather than invalid workspace or credential state. | Called `IsolationProfile.runtime_identity/1` on the resolved executable and recorded only error categories; queried that executable's version. | Identity reports `unsupported_codex_version`; resolved executable reports `codex-cli 0.162.0`. `IsolationProfile` accepts only `codex-cli 0.159.3`. | Confirmed the root cause at runtime admission: this environment's Codex version does not satisfy the production isolation verifier's pinned-version contract. Do not change the version contract. |
| 4 | Lifecycle test boundary | The lifecycle tests can exercise fake runtimes without depending on the host's Codex verifier, while existing admission tests retain fail-closed coverage. | Repeated the same routed fixture through `AgentRunner.run/3` with a self-contained fake runtime and the existing `test_runtime_isolation_admit` seam. | The test-only admission callback allowed both expected runtime turns. The direct production admission diagnostic still failed on the unsupported Codex version. | Hypothesis supported: lifecycle tests omitted the established test admission seam. Repair only the affected fake-runtime lifecycle fixtures; keep actual admission behavior in `agent_runner_isolation_test.exs` unchanged. |
| 5 | Diagnostic harness | The callback experiment needs a runtime module loaded by the focused diagnostic test. | First experiment referenced the fake runtime module defined in `agent_runtime_test.exs`, which the isolated diagnostic command did not load. Replaced it with a self-contained temporary runtime and reran the same experiment. | First experiment failed with `UndefinedFunctionError`; corrected experiment passed. | Harness-only issue. It did not change the admission-stage result or production files. |
| 6 | Targeted repair verification | Adding the established test seam to the 11 fake-runtime lifecycle fixtures restores their intended assertions. | Ran the formerly failing `same-route` case at seed `922982`, then the full module at the same seed. | Target case passed. Module result: 20 tests, 0 failures. | The repair removes the accidental dependency on the host Codex version from lifecycle tests. |
| 7 | Adjacent isolation and ownership checks | The focused fixture change preserves admission denial, workspace ownership, and credential boundary behavior. | Ran AgentRunner isolation, runtime isolation, workspace/config, workspace ownership, ownership ledger, and credential boundary suites together at seed `922982`. | 197 tests, 0 failures. Existing unsupported-version, malformed-callback, raised/thrown, unavailable, and failed-admission assertions passed. | No isolation contract or expected result was weakened. |
| 8 | Seeded coverage partition | The repository coverage partition containing AgentRunner now passes on the remediation diff. | Ran `make -C elixir coverage-partition PARTITION=1 MIX='mix test --seed 922982'`. | 217 tests, 0 failures; coverage data exported. | The original failing coverage partition is green. |
| 9 | Full gate with the ambient Codex | The local shell environment should satisfy the full gate's pinned Codex requirement. | Ran `make -C elixir all` with ambient `PATH`. | CI stopped in coverage partition 2 with 3 real-Codex tests rejected because `0.162.0` is unsupported. | Environment mismatch, not a remediation regression. The pinned root-owned `0.159.3` installation already exists and the CI workflow specifies its exact PATH. Retry the full gate with that PATH, without changing tests or the version contract. |
| 10 | Full gate with CI's pinned Codex | Using the repository's supported Codex installation should make the full gate reproducible locally. | Verified the workflow's trusted Codex directories and version, then ran `PATH='/usr/local/lib/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin:/usr/local/lib/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex-path':"$PATH" make -C elixir all`. | All targets passed. Coverage partitions: 208/0, 373/0, 232/0 (2 skipped), 227/0, 89/0 (1 skipped), 188/0 (3 skipped), 132/0, 165/0 (1 excluded), plus transition fixture 66/0. H-070A scale: 1/0 with 10,200 attempts. Total coverage: 90.18%. Dialyzer: 0 errors. Actual Codex and AppServer proof: 72 tests, 0 failures. | The baseline repair passes the complete local gate when run with the same pinned Codex PATH used by CI. |

## Changes and verification

The temporary diagnostic test was removed. The only remediation diff is in `agent_runtime_test.exs`: it defines a test-only successful admission callback and passes it to the 11 fake-runtime lifecycle cases that failed on this baseline. No production source, expected assertion, or dedicated isolation test changed.

## Baseline failure order

The seeded module run failed at these tests in this order:

1. `routed AgentRunner suspends for a provider Blocked observation`, line 878.
2. `routed AgentRunner suspends instead of rerouting after an unsafe forward observation`, line 837.
3. `AgentRunner terminates a session when the refreshed state changes its route`, line 315.
4. `Plane continuation fails closed when the host snapshot reader is missing`, line 667.
5. `AgentRunner continues when a state refresh keeps the same route`, line 401.
6. `routed AgentRunner passes the refreshed WorkItem to the next turn context`, line 446.
7. `routed Plane continuation starts a fresh catalogue for the refreshed route`, line 538.
8. `AgentRunner stops when a refreshed implementation becomes dependency-blocked`, line 797.
9. `Plane continuation stops on complete epoch absence without a provider read`, line 605.
10. `AgentRunner keeps effective profile options on continuation turns`, line 723.
11. `Plane continuation fails closed when the complete epoch is unavailable`, line 629.

The module's installed test runtime reported `codex-cli 0.162.0`; no credentials or environment values are recorded here.

## Repair evidence

- Before the fixture change, the seeded module run was red at `20 tests, 11 failures`.
- A temporary same-fixture `AgentRunner.run/3` experiment with the test admission callback reached both expected fake-runtime turns.
- The repository already has dedicated admission tests that assert invalid, raised, thrown, unavailable, and failed callbacks block startup. `runtime_isolation_test.exs` separately proves an unsupported Codex version is rejected. These tests were not changed.
- After applying the callback to only the 11 failing fake-runtime lifecycle cases, `mix test test/symphony_elixir/agent_runtime_test.exs --seed 922982` was green at `20 tests, 0 failures`.
- The callback seam is test-environment-only in `AgentRunner`; production still calls `RuntimeIsolation.admit/3` and retains its pinned-version check.
- The first full-gate attempt exposed that ambient PATH selected `codex-cli 0.162.0`. The exact root-owned Codex 0.159.3 CI installation was already available. Rerunning with the workflow's two Codex PATH entries passed the full gate, including the actual Codex proof; no environment setting or version policy was changed.
- Final `mix format --check-formatted` ran as part of the full gate. `git diff --check` passed on the remediation diff. No commit, push, pull request, or merge was performed.
