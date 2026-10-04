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

The current remediation candidate is the PR #31 head. Its exact HEAD/tree and synthetic merge
SHA/tree/parents are recorded in the PR description and repeated by the required Linux CI checkout
steps. Those values identify the candidate that reviewers should evaluate; the historical rows
above are not evidence for it.

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

The local Linux proof command is:

```sh
PATH=/home/jcschoeman96/.local/share/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin:/home/jcschoeman96/.local/share/symphony-codex-0.159.3/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex-path:$PATH \
  make -C elixir isolation-proof
```

The local developer installation is user-owned, so the test-only actual-Codex proof uses its
explicit test bypass for the host ownership precondition. A separate regression asserts that the
same user-owned path is rejected when that precondition is enforced. CI installs the pinned native
Codex package under `/usr/local/lib/symphony-codex-0.159.3` as root and enables the precondition in
the pinned actual-Codex test.

## Verification state

| Gate | Result |
|---|---|
| Linux split-read actual-Codex feasibility | Passed on pinned 0.159.3 |
| Actual-Codex four-role proof | Passed on pinned 0.159.3; all four roles |
| `make -C elixir isolation-proof` | Passed on the remediation candidate; 72 tests, 0 failures |
| Focused AgentRunner, Orchestrator runtime isolation, AppServer, and RuntimeIsolation suites | Passed; 114 tests, 0 failures |
| Retained-containment lifecycle and stale-identity regressions | Passed in focused suites; the production timeout result retains the exact RuntimeAttempt, fence, and workspace record without retry or replacement |
| `make -C elixir all` | Passed with exported coverage aggregation: non-scale shard 1,649 tests, 0 failures, 6 skipped; H-070A shard 1 test, 0 failures; aggregate 90.00%; Dialyzer clean; actual-Codex proof 72 tests, 0 failures |
| H-070A scale characterization | Mandatory shard passed: 1,000 items / 5,000 edges (1.392 s), 5,000 / 25,000 (34.818 s), and 10,000 / 50,000 (140.615 s) |
| Coverage split probe | Before aggregation, non-scale coverage alone varied from 89.99% to 90.02%. The gate now aggregates exports from both test shards and enforces 90.00% across all accepted tests. |
| Dialyzer | Passed; 0 errors, 0 skipped, 0 unnecessary skips |
| `mix format --check-formatted` | Passed |
| `git diff --check` | Passed |
| Protected Linux CI jobs and PR checks | Pending the pushed aggregate-coverage candidate. The superseded run `37200799277` passed isolation proof, was canceled during coverage reporting, and correctly failed `make-all`. |
| macOS/iOS support | Unsupported and not certified; no macOS proof runs |
| H-080B acceptance | Not granted |

The repository workflow installs Codex 0.159.3 under `/usr/local/lib/symphony-codex-0.159.3` with
root ownership and non-writable package ancestry. Protected `make-all` requires the Linux
`linux-isolation-proof` job (`make isolation-proof`, including path-trust enforcement) and the
`linux-full-gate` job. That gate runs format, lint, exports coverage from the non-scale test shard,
executes and exports the mandatory H-070A 1,000/5,000/10,000 item scale shard, aggregates both
exports with `mix test.coverage` at the fixed 90% threshold, and then runs Dialyzer. Both local
`make all` and protected `make-all` require each step. A failed or skipped proof, test shard,
coverage aggregation, or quality check fails `make-all`. macOS and iOS are unsupported and not
certified, so no macOS proof runs.

If a hosted runner terminates a coverage run, that run is recorded as terminated by the runner;
this evidence does not infer a generic time limit. The H-070A test is assigned to a separate
mandatory test shard, and its exported coverage is aggregated with the rest of the suite before
the 90% threshold is applied. No accepted test is dropped from the required Linux quality gate.
