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
PATH=/home/jcschoeman96/.codex/packages/standalone/releases/0.159.3-x86_64-unknown-linux-musl/bin:/home/jcschoeman96/.codex/packages/standalone/releases/0.159.3-x86_64-unknown-linux-musl/codex-path:$PATH \
  make -C elixir isolation-proof
```

The local developer installation is user-owned, so the test-only actual-Codex proof uses its
explicit test bypass for the host ownership precondition. A separate regression asserts that the
same user-owned path is rejected when that precondition is enforced. CI installs the pinned native
Codex package under `/opt` as root and enables the precondition in the pinned actual-Codex test.

## Verification state

| Gate | Result |
|---|---|
| Linux split-read actual-Codex feasibility | Passed on pinned 0.159.3 |
| Actual-Codex four-role proof | Passed on pinned 0.159.3; all four roles |
| `make -C elixir isolation-proof` | Passed; 72 tests, 0 failures |
| Focused RuntimeIsolation, Orchestrator isolation, AppServer, and AgentRuntime suites | Passed; 114 tests, 0 failures |
| Escaped descendant, state retention, executable replacement, path trust, and stop-result regressions | Passed within the focused and proof suites |
| `make -C elixir all` | Passed; 1,641 tests, 0 failures, 6 skipped; 90.00% coverage |
| Dialyzer | Passed; 0 errors, 0 skipped, 0 unnecessary skips |
| `mix format --check-formatted` | Passed |
| `git diff --check` | Passed |
| Protected Linux CI jobs and PR checks | Pending push of this candidate |
| macOS/iOS support | Unsupported and not certified; no macOS proof runs |
| H-080B acceptance | Not granted |

The repository workflow installs Codex 0.159.3 under root-owned `/opt`, enables the launch-path
invariant in the pinned actual-Codex test, runs the Linux actual-Codex proof, and then runs the Linux
full gate. Protected `make-all` requires both Linux jobs to succeed; a skipped proof or gate fails
`make-all`. macOS and iOS are unsupported and not certified, so no macOS proof runs.
