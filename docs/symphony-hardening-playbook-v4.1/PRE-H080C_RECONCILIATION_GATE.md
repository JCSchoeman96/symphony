# PRE-H080C reconciliation gate candidate

**Status:** `PRE-H080C = CANDIDATE / NOT ACCEPTED`

**H-080C:** `NOT AUTHORIZED`

This document records candidate evidence for later independent review and Master Governance adjudication. It does not record acceptance, authorize a merge, or authorize H-080C.

## Authorization and baseline

- Authorization reference: user-provided **PRE-H080C — Bounded Remediation and Gate-Closure Plan** in this thread.
- Authorization timestamp recorded at execution start: `2026-10-12 13:41:23 UTC`.
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

GitHub required-check evidence on the frozen PR head: pending. Record each check conclusion, run ID, and tested commit SHA before handoff.

## Governance state

- `PRE-H080C = CANDIDATE / NOT ACCEPTED`.
- `H-080C = NOT AUTHORIZED`.
- No machine governance projection or immutable Master Roadmap is changed by this candidate.
- Merge and acceptance remain separate human governance decisions.
