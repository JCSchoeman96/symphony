# PRE-H080C reconciliation gate candidate

**Status:** `PRE-H080C = CANDIDATE / NOT ACCEPTED`

**H-080C:** `NOT AUTHORIZED`

This document records candidate evidence for later independent review and Master Governance adjudication. It does not record acceptance, authorize a merge, or authorize H-080C.

## Authorization and baseline

- `MASTER_GOVERNANCE_AUTHORIZATION=MG-2026-10-12-PRE-H080C-REMEDIATION-AUTH-01`.
- `AUTHORIZATION_TIMESTAMP=2026-10-12T12:33:51+02:00`.
- `IMPLEMENTATION_START_TIMESTAMP=2026-10-12T13:41:23Z`.
- Repository: `JCSchoeman96/symphony`.
- Protected `main` base SHA: `f75c400febbfcbb9b66d017e27d286ff30925e45`.
- Protected `main` base tree: `6be09bc285c7c8f8356aa9d581a26f3a59ec7531`.
- Governing roadmap blob: `4b0528bdc0647d889b42ebc478081d5b873898fe`.
- PRE-080C-02 evidence blob: `b69d46676d3286262bf7cab783654c10a08801bf`.
- Remote protected `main` matched the authorized SHA when work began.
- Required checks are `make-all` and `validate-pr-description`, both from GitHub Actions app ID `15368`.

## Reconciliation findings

- PRE-080C-01 disposition: satisfied. Its accepted status remains unchanged.
- PRE-080C-02 disposition: `LIMIT_FOUND`, resolved for this reconciliation by recording the supported V1 envelope below. The accepted finding is not reclassified as `REAL_BOTTLENECK`.
- PRE-080C-03 disposition: satisfied. Its accepted status remains unchanged.

```text
SUPPORTED_V1_PROJECT_ITEMS <= 1000
SUPPORTED_V1_DEPENDENCY_EDGES <= 5000

STABLE_COMPLETE_EPOCH_AT_1000_ITEMS:
production pacing lower bound >= 17 minutes

PROJECTS_ABOVE_SUPPORTED_ENVELOPE:
structurally characterized through 10,000 items,
but not claimed as V1 production-supported.
```

This records a support boundary. It adds no production rejection rule.

## PRE-H080C gate answers

These answers record the current candidate's reconciliation evidence. They do not constitute PRE-H080C acceptance or authorize H-080C.

1. **Can the real production path acquire every evidence class needed for V1 lifecycle advancement? YES.** PRE-080C-01 remains accepted and satisfied; its accepted evidence establishes production-path acquisition coverage for the required evidence classes.
2. **Is the supported project-size and acquisition-latency envelope known? YES.** The supported V1 boundary is at most 1,000 project items and 5,000 dependency edges, with a stable complete epoch at 1,000 items having a production pacing lower bound of at least 17 minutes. Results above that boundary, through 10,000 items, are structural characterization only.
3. **Can a fresh agent independently identify current authority without relying on stale ledger or README statements? YES.** The machine governance projection still records the last accepted PRE-080C-03 state and no currently authorized programme work; the immutable roadmap and PRE-080C-02 evidence blobs are identified above. This bounded remediation has the separate, exact authorization recorded above. That authorization applies only to this remediation and does not accept PRE-H080C or authorize H-080C.
4. **Does an unresolved finding require remediation before integrated H-080C testing? NO, based on the reviewed evidence.** The remaining items are classified as follows:
   - Restart-local pacing history: non-blocking operational debt.
   - Repeated dirty full epochs: non-blocking operational debt.
   - Baseline-reproduced epoch-test timeouts and CI nondeterminism: non-blocking reliability debt; the same timeout failures reproduced against the accepted base, while required `make-all` passed on the reviewed candidate checkpoint.
   - CI advisory set before the final H100 candidate: Bandit `1.12.5`, Decimal `2.3.0`, and Plug.Crypto `2.2.0` (reported medium). Track these for separate security adjudication; this remediation does not change dependencies.
   - Decimal `2.3.0` advisories: unresolved, separately tracked dependency debt. Current repository review found no Symphony application `Decimal` or `:decimal` usage. Remediation crosses the existing Ecto Decimal 2.x constraint and requires broader, separately authorized dependency work. The advisories are not fixed by this candidate.

These conclusions are bounded to the evidence identified in this document. They do not change any accepted programme status or authorize integrated H-080C testing.

## Dependency remediation

Only `elixir/mix.lock` changes in the dependency slice. `elixir/mix.exs` is unchanged.

| Package | Before | After |
| --- | --- | --- |
| `phoenix` | 1.8.4 | 1.8.15 |
| `phoenix_live_view` | 1.1.25 | 1.1.33 |
| `mint` | 1.10.0 | 1.11.0 |
| `lazy_html` | 0.1.10 | 0.1.13 |

No other locked dependency changed. Decimal remains `2.3.0` with its original lock entry.

### Decimal advisory disposition

Decimal was explicitly excluded from this authorization, so this candidate does not change it. The locked `decimal 2.3.0` is in the affected range for CVE-2026-32686 and CVE-2026-97853. Hex records both advisories as moderate severity. CVE-2026-32686 has a patched 3.x release; the newer CVE-2026-97853 affects versions below 3.1.2. A fix therefore requires work outside this bounded dependency slice and crosses the repository's current Decimal 2.x dependency constraints. Record this as unresolved security debt for separate authorization; do not infer that this candidate fixes it. See [Hex Decimal advisories](https://hex.pm/packages/decimal/advisories) and [CVE-2026-32686](https://github.com/advisories/GHSA-rhv4-8758-jx7v).

## Operational and reliability debt

- Restart pacing history remains process-local. This is non-blocking operational debt for PRE-H080C and is not redesigned here.
- Repeated dirty full epochs can amplify reads. This is non-blocking operational debt for PRE-H080C and is not redesigned here.
- CI nondeterminism remains non-blocking reliability debt unless candidate-specific failures reproduce on the exact candidate.

## Candidate identity

The dependency implementation checkpoint is commit `4db1ab0797043ce636eb5afad6762bed7a4a7fa8`, tree `767b50f0f9bae9c4501add7b8cc0a1ce349022c5`. It contains only the approved lockfile changes and is based directly on the authorized SHA/tree above.

The final PR head SHA/tree will be recorded in the PR description after the evidence commit is frozen. The tracked document cannot contain its own final commit or tree identity without changing that identity. The PR must remain open and unmerged for independent review.

## Verification evidence

Local verification on 2026-10-12:

| Command | Result |
| --- | --- |
| `mix compile --warnings-as-errors` | Pass |
| `mix specs.check` | Pass, all public functions have a spec or exemption |
| `mix format --check-formatted` | Pass |
| `mix credo --strict` | Pass, 7,894 functions and macros, no issues |
| `mix dialyzer` | Pass, 0 errors |
| `mix lint` | Pass, including `governance.check` |
| `make -C elixir all` | Pass with `codex-cli 0.159.3`; coverage report 90.42%, all coverage partitions and scale checks passed, isolation proof 72 tests with 0 failures |
| `git diff --check` | Pass before commit; rerun after evidence edits |

The first `make -C elixir all` attempt used the machine's default `codex-cli 0.162.1` and stopped at the repository's pinned-version isolation checks. The rerun used the repository-required `0.159.3` binary and passed.

Focused regressions also passed: `extensions_test.exs` with `plane_webhook_test.exs` reported 40 tests and 0 failures; the Linear Client, Plane Client, dependency reader, ReadScheduler, and project contract suite reported 126 tests and 0 failures. PRE-080C-02 characterization passed for 1,000, 5,000, and 10,000 items, with 5,000, 25,000, and 50,000 edges respectively, and 1,024, 5,104, and 10,204 logical requests. The supported 1,000-item epoch retained the 17-minute modeled pacing lower bound.

An additional direct run of `orchestrator_plane_epoch_test.exs` reported 3 timeouts in 71 tests. The same three tests failed when run against the authorized base with its original lockfile, and one failed again when run alone on the candidate. The full `make -C elixir all` passed afterward. Keep this baseline-reproduced test issue visible for review; it is not counted as a passing focused run or silently waived.

GitHub required-check evidence for the frozen implementation candidate checkpoint `21e395964e16baf55d9947a9e259074064e1a7ed`, tree `44e1eb50fe9dfdda40689978a440468113f0e25e`:

| Required check | Conclusion | App ID | Workflow run | Check/job ID |
| --- | --- | --- | --- | --- |
| `make-all` | success | 15368 | `38261321921` | `114854303373` |
| `validate-pr-description` | success | 15368 | `38261321919` | `114852254713` |

Both checks tested the SHA above. The final PR head and its fresh required-check evidence are recorded in the PR description after this evidence commit, since recording a new source document changes the PR head identity.

## Governance state

- `PRE-H080C = CANDIDATE / NOT ACCEPTED`.
- `H-080C = NOT AUTHORIZED`.
- No machine governance projection or immutable Master Roadmap is changed by this candidate.
- Merge and acceptance remain separate human governance decisions.
