# H-080B Implementation Evidence

## Candidate status

| Field | Result |
|---|---|
| `BASE_SHA` | `56798754c8f6fd80d7ec53b604800873e339e030` |
| `CODEX_VERSION` | `codex-cli 0.159.3` |
| `CODEX_RELEASE_COMMIT` | `01fc69f4026735edfdf6789820549727a4867b11` (`rust-v0.159.3`) |
| `CANDIDATE_STATE` | Remediation candidate for fresh independent review. H-080B is not accepted. |
| `H-080B_AUTHORITY` | Remediation implementation is authorized for review. H-080B acceptance is not granted. |
| `H-080C` | Not authorized. No H-080C implementation or change is included. |
| `PLATFORM_CERTIFICATION` | Linux only. macOS and iOS are unsupported and not certified. |

## Evidence history

| Candidate | Evidence | Status |
|---|---|---|
| `c61f248711cb99f65ce1e899c903ec40d5089150` | Historical local result: 1,641 tests, 0 failures, 6 skipped, approximately 90.01% coverage. | Historical only; not verification of a later candidate. |
| `03c3b9d343ff93c7c1cf60d1e5d903b70716dbff` | Hosted result: 1,640 tests, 0 failures, 6 skipped, 1 excluded, 89.97% coverage. | Superseded and rejected because it weakened accepted H-070A and 90% coverage authority. |
| `9643cc5f39dd6b7d4b09348accbdce7e1992d489` | Hosted run `37200799277`: 1,424 tests, 0 failures, 6 skipped; all three H-070A scale epochs passed; runner canceled Mix while it generated the coverage report. No coverage result was produced. | Superseded. `make-all` correctly failed because the Linux full gate did not complete. |
| `0973eb4` | Non-scale coverage probe: 1,649 tests, 0 failures, 6 skipped, 1 assigned to the H-070A shard; coverage varied between 89.99% and 90.02% across runs. | Insufficient alone to certify the fixed threshold; the next candidate aggregates both coverage exports. |
| `7e8ad45a10fcadbd75a600fddf0faf2dbe4b84bb` | Local `make all` passed: 1,649 non-scale tests, 1 H-070A test, 6 skipped, 90.02% aggregate coverage, Dialyzer clean, and 72 isolation-proof tests passed. Hosted run `37202957994` was canceled during the non-scale test step before ExUnit produced a summary; H-070A and coverage aggregation were skipped. | Superseded; `make-all` correctly failed. |
| `3afae77f9abb2e2e91716e1d790a87736ae8f0e6` | Hosted run `37204294595`, attempt 1: 1,526 tests, 0 failures, 6 skipped, 1 excluded; attempt 2: 1,253 tests, 0 failures, 6 skipped, 1 excluded. Both attempts were canceled during coverage export. H-070A, aggregate coverage, and Dialyzer did not run. | Superseded; `make-all` correctly failed because the Linux full gate did not complete. No generic runner time limit is inferred. |

The locally verified implementation snapshot is commit `9e081f88dc72d37ec7bf6de78bb574d10eb71b49`,
tree `4b641db7a4be167c75de5964c764015d99a8019f`, based on the accepted `main` commit above. The
PR description and required Linux CI checkout steps record the exact final PR head and synthetic
merge identity. The historical rows above are not evidence for the current candidate.

## Boundary implemented

Routed local Codex admission requires a cached, supervised `RuntimeIsolation` proof for the admitted
executable fingerprint before session creation. Unproven or changed Codex runtimes fail closed as
`runtime_isolation_blocked`; these failures do not enter ordinary retry accounting. Admission checks
all four named role profiles against separate fresh fixtures. Remote workers remain blocked because
the SSH launch path has no verified containment boundary.

**H-080B routed runtime isolation is certified for Linux.** macOS/iOS are not certified deployment
targets for this phase. Unsupported or unproven platforms fail closed rather than inheriting Linux
certification.

Linux launch also requires the Codex executable, its resolved native executable, and the `unshare`
and `python3` launcher tools to be root-owned regular executables under root-owned ancestor
directories with no group/world write permission or set-id bits. Symphony checks this invariant
mechanically and revalidates the admitted Codex file identity before spawning. A user-owned or
otherwise mutable installation fails closed. The root-owned path hierarchy prevents the routed
runtime from replacing those files during launch; the host root remains the trusted principal. Codex
retains its own-path re-exec behavior under this host-trust assumption.

Session-home setup creates its root exclusively and records its filesystem identity. Cleanup refuses
to remove an existing or replaced path. This prevents a configured root from adopting pre-existing
data and then recursively deleting it. Default session-home names include a random suffix so separate
BEAM runs cannot reuse a stale numeric path.

Routed runtimes run under a per-session Linux PID namespace. Its PID 1 supervisor proxies stdio,
tracks and reaps descendants (including children that call `setsid`), and exits only after `/proc`
shows no remaining namespace processes and wait/reap reports no children. Symphony waits for the
outer launcher to exit before cleaning the ephemeral home. If the bounded stop wait expires, the
supervisor remains in containment, the session home is retained, and `stop_session/1` returns the
typed `containment_unconfirmed` failure.

The successful lifecycle is `admitted -> running -> stopping -> containment proven dead -> cleanup
-> stopped`. If the stop wait expires, the lifecycle is `stopping -> containment unconfirmed -> state
retained -> typed failure`.

AgentRunner reports those transitions with the exact RuntimeAttempt identity. On timeout, Orchestrator
keeps that attempt in its active runtime map, retains the authority fence and workspace ownership,
and blocks retries and replacement dispatch without recording an ordinary failure. A stale proof
for another RuntimeAttempt is ignored. There is no safe post-timeout observer today, so an unconfirmed
attempt stays retained until an authorized reconciliation path can positively establish namespace
death.

`AppServer.run/4` captures the turn and stop outcomes explicitly. A stop failure overrides a
successful turn; when both fail, it preserves a safe turn-failure tag without returning response
content. The fresh regressions cover a detached child, retained state on unconfirmed stop, runtime
identity/path admission, and execution/stop result combinations.

The named permission profiles use Codex 0.159.3 split-read mode. They contain no `:root` rule, grant
`:minimal` read access for platform runtime support, and grant the exact canonical workspace read
access for Planner/Reviewer or write access for Builder/Fixer. The `.git` subtree remains read-only,
network stays disabled, and shell environment inheritance is limited to the explicit safe-name list.
Each routed session receives private `HOME`, `CODEX_HOME`, and XDG directories. Credentials are
removed from the Codex process environment; approved semantic tools continue to execute in the
host-side app-server with host credentials.

The host-vs-synthetic discriminator permits synthetic ancestor directories in Codex's private
filesystem view. The fixture records the host common-root entries, sentinel bytes, sibling snapshot,
and workspace snapshot before launch. It then attempts parent and synthetic-sibling writes in the
sandbox. The host-side snapshots after exit prove those writes did not reach the common root or its
sibling. The host parent and sibling contents must remain absent from the sandbox view, including
direct reads of known paths.

## Codex `:minimal` source audit

The pinned Codex source audit below covers the Linux roots it may mount for the `:minimal` permission
token. These are runtime support paths, not host-HOME, project, or workspace-parent read grants. It
does not certify macOS or iOS, which are unsupported.

| Platform | Pinned-source materialization |
|---|---|
| Linux | Existing directories from `/bin`, `/sbin`, `/usr`, `/etc`, `/lib`, `/lib64`, `/nix/store`, and `/run/current-system/sw` are read-only bound in split-read mode. `/proc` is read-only when the sandbox inherits the PID namespace. `/dev` is a Bubblewrap baseline mount rather than a `:minimal` grant. The actual-Codex proof has passed on Linux. |

Pinned source references:

- [`:minimal` permission definition](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/protocol/src/permissions.rs)
- [Linux Bubblewrap split-read mounts](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/linux-sandbox/src/bwrap.rs)

## Actual-Codex Linux evidence

The proof ran with the standalone executable installed from the pinned 0.159.3 package. The test
resolves the executable, checks the reported version, and exercises the generated named profiles
against real Codex sandbox commands.

| Assertion | Result |
|---|---|
| Assigned workspace sentinel readable | Pass |
| Planner/Reviewer workspace create, modify, rename, and delete denied | Pass |
| Builder/Fixer workspace create, modify, rename, and delete allowed | Pass |
| Existing sibling names and contents unavailable, including direct known-path read | Pass |
| Host common-root sentinel name and bytes unavailable | Pass |
| Synthetic parent writes confined to the sandbox; host common-root and sibling snapshots unchanged | Pass |
| Outside and fake credential-home sentinels unavailable | Pass |
| Workspace symlink escape read and write denied | Pass |
| Hard-link escape creation denied | Pass |
| Controlled loopback and Unix-socket connections denied | Pass |
| Credential and parent-sentinel environment variables absent; HOME/XDG/CODEX_HOME bound to session state | Pass |
| Pinned Codex timeout path terminates and cleans the probe process | Pass |
| Host-side semantic tool retains authorized host control without copying its credential to Codex | Covered by the passing credential-channel and app-server tests |

The Linux proof command uses the root-owned pinned executable path and enforces the trusted-path
precondition:

```sh
PATH=/usr/local/lib/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin:/usr/local/lib/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex-path:$PATH \
SYMPHONY_ENFORCE_TEST_RUNTIME_PATH_TRUST=1 make -C elixir isolation-proof
```

Both local verification and CI use the root-owned package under
`/usr/local/lib/symphony-codex-0.159.3` and enforce the trusted-path precondition. The tests also
reject user-owned or writable executable hierarchies.

## Verification state

| Gate | Result |
|---|---|
| Linux split-read actual-Codex feasibility | Passed on pinned 0.159.3 |
| Actual-Codex four-role proof | Passed on pinned 0.159.3; all four roles |
| `make -C elixir isolation-proof` | Passed on the pinned, root-owned Codex 0.159.3 path with path-trust enforcement; 72 tests, 0 failures |
| Focused AgentRunner, Orchestrator runtime isolation, RuntimeIsolation, teardown, and AppServer suites | Passed; 156 tests, 0 failures |
| Retained-containment lifecycle and stale-identity regressions | Passed in the focused suite; the production timeout result retains the exact RuntimeAttempt, fence, and workspace record without retry or replacement |
| `make -C elixir all` | Passed on implementation snapshot `9e081f8`: 1,649 non-scale tests, 0 failures, 6 skipped; one H-070A test passed; 90.03% aggregated coverage; Dialyzer clean; actual-Codex proof 72 tests, 0 failures |
| H-070A scale characterization | Mandatory shard passed: 1,000 items / 5,000 edges (1.433 s), 5,000 / 25,000 (35.955 s), and 10,000 / 50,000 (145.577 s) |
| Coverage policy | Eight native Mix test partitions plus the paired transition fixture shard export coverage; the mandatory H-070A shard exports separately. `mix test.coverage` imports all ten exports and passes the fixed 90% threshold. No accepted test is omitted. |
| Dialyzer | Passed; 0 errors, 0 skipped, 0 unnecessary skips |
| `mix format --check-formatted` | Passed |
| `git diff --check` | Passed |
| Protected Linux CI jobs and PR checks | The preceding candidate runs are recorded above. The partitioned Linux gate is pending on this implementation snapshot; `make-all` must pass `linux-isolation-proof` and `linux-full-gate`, and `validate-pr-description` remains required. |
| macOS/iOS support | Unsupported and not certified; no macOS proof runs |
| H-080B acceptance | Not granted |

The repository workflow installs Codex 0.159.3 under `/usr/local/lib/symphony-codex-0.159.3` with
root ownership and non-writable package ancestry. Protected `make-all` requires the Linux
`linux-isolation-proof` job (`make isolation-proof`, including path-trust enforcement) and the
`linux-full-gate` job. That gate runs format and lint, then eight required Mix test partitions and a
required paired transition-fixture shard. It runs and exports the mandatory H-070A
1,000/5,000/10,000 item scale shard, aggregates every coverage export with `mix test.coverage` at
the fixed 90% threshold, and runs Dialyzer. Local `make all` runs the same tests and checks. A
failed or skipped proof, partition, fixture shard, scale shard, coverage aggregation, or quality
check fails `make-all`. macOS and iOS are unsupported and not certified, so no macOS proof runs.

Prior hosted coverage runs ended with runner cancellation after ExUnit reported passing tests. The
logs do not establish a general runner time limit. The current gate keeps every accepted test in a
required partition and runs the H-070A test in its own required shard. It aggregates all exports
before applying the 90% threshold. No accepted test is dropped from the required Linux quality gate.
