# H-080B Implementation Evidence

## Candidate status

| Field | Result |
|---|---|
| `BASE_SHA` | `56798754c8f6fd80d7ec53b604800873e339e030` |
| `CODEX_VERSION` | `codex-cli 0.159.3` |
| `CODEX_RELEASE_COMMIT` | `01fc69f4026735edfdf6789820549727a4867b11` (`rust-v0.159.3`) |
| `CANDIDATE_STATE` | Proof-gate checkpoint only. The draft PR is not an implementation-complete or approval candidate. |
| `H-080B_AUTHORITY` | Implementation is authorized. H-080B remains under review and is not accepted. |
| `H-080C` | Not authorized or changed. |

## Boundary implemented

Routed local Codex admission resolves the direct executable and requires a cached, supervised
`RuntimeIsolation` proof for its executable fingerprint before session creation. Unproven or changed
Codex runtimes fail closed as `runtime_isolation_blocked`; these failures do not enter ordinary retry
accounting. Admission checks all four named role profiles against separate fresh fixtures. Immediately
before launch, Symphony checks the executable files against the captured identity and the verifier's
cached fingerprint. Remote workers remain blocked because the SSH launch path has no verified
containment boundary.

Session-home setup creates its root exclusively and records its filesystem identity. Cleanup refuses
to remove an existing or replaced path. This prevents a configured root from adopting pre-existing
data and then recursively deleting it.

The shutdown review found an open process-containment issue. `AppServer` signals the Codex process
group but checks only the app-server PID before deleting the session home. A child that creates a new
session can outlive the group and keep access to the assigned workspace. This checkpoint must not be
merged until teardown proves descendant termination or fails closed. `AppServer.run/4` also needs to
propagate teardown errors instead of discarding them. The executable identity check and `Port.open/2`
still use separate pathname operations, so a same-host replacement in that gap remains under review.

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

These are the roots the pinned Codex source may mount for the `:minimal` permission token; they are
runtime support paths, not host-HOME, project, or workspace-parent read grants.

| Platform | Pinned-source materialization |
|---|---|
| Linux | Existing directories from `/bin`, `/sbin`, `/usr`, `/etc`, `/lib`, `/lib64`, `/nix/store`, and `/run/current-system/sw` are read-only bound in split-read mode. `/proc` is read-only when the sandbox inherits the PID namespace. `/dev` is a Bubblewrap baseline mount rather than a `:minimal` grant. The actual-Codex proof has passed on Linux. |
| macOS | Pinned Seatbelt source lists `/Library/Apple`, `/Library/Filesystems/NetFSPlugins`, `/Library/Preferences/Logging`, `/Library/Preferences`, `/private/var/db`, `/private/var/db/DarwinDirectory/local/recordStore.data`, `/private/var/db/timezone`, `/var/db`, `/usr/lib`, `/usr/share`, `/etc`, `/private/etc`, `/Library/Apple/System/Library/Frameworks`, `/Library/Apple/System/Library/PrivateFrameworks`, `/Library/Apple/usr/lib`, `/System/Library/Extensions`, `/System/Library/Frameworks`, `/System/Library/PrivateFrameworks`, `/System/Library/SubFrameworks`, `/System/iOSSupport/System/Library/Frameworks`, `/System/iOSSupport/System/Library/PrivateFrameworks`, `/System/iOSSupport/System/Library/SubFrameworks`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/libexec`, `/opt/homebrew/lib`, and `/usr/local/lib`. The source also grants selected directory metadata and literal system paths, including `/`, `/tmp`, `/var`, `/private/var`, `/private/etc/localtime`, `/System/Library/CoreServices`, `/System/Volumes`, `/System/Volumes/Data`, `/System/Volumes/Data/Users`, selected `/dev` nodes, and selected system password/configuration files. This is a source audit only; the actual macOS proof is pending CI. |

Pinned source references:

- [`:minimal` permission definition](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/protocol/src/permissions.rs)
- [Linux Bubblewrap split-read mounts](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/linux-sandbox/src/bwrap.rs)
- [macOS Seatbelt policy builder](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/sandboxing/src/seatbelt.rs)
- [macOS read-only platform defaults](https://github.com/openai/codex/blob/rust-v0.159.3/codex-rs/sandboxing/seatbelt_read_only_platform_defaults.sbpl)

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

The Linux feasibility command is:

```sh
PATH=/home/jcschoeman96/.codex/packages/standalone/releases/0.159.3-x86_64-unknown-linux-musl/bin:$PATH \
  mix test test/symphony_elixir/runtime_isolation_actual_codex_test.exs
```

## Verification state

| Gate | Result |
|---|---|
| Linux split-read actual-Codex feasibility | Passed on pinned 0.159.3 |
| Linux actual-Codex role proof | Passed on pinned 0.159.3; 29 tests, 0 failures, all four roles |
| Focused session-root and executable-replacement regressions | Passed |
| AppServer focused suite | Passed with pinned 0.159.3; 34 tests, 0 failures |
| Format check | Passed after the latest edits |
| Credo and full Linux `make all` | Pending the post-macOS proof sequence |
| Full Linux `make all` | Pending final clean run |
| Actual macOS 0.159.3 proof | Pending the required `macos-isolation-proof` CI job |
| H-080B acceptance | Not granted |

The repository workflow installs Codex 0.159.3 in both Linux and macOS jobs. A draft PR runs the
macOS actual-Codex proof while skipping the Linux full gate. The Linux full gate runs after the PR
leaves draft. Passing Linux evidence does not certify macOS isolation.
