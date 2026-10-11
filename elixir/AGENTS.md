# Symphony Elixir agent instructions

This directory contains a provider-neutral orchestration service that reads work from its configured adapter, creates per-issue workspaces, and runs Codex in app-server mode. Plane is the hardened V1 primary provider. Linear remains supported for legacy compatibility.

## Governing documents

Follow the V4.1 [Master Roadmap](../docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md), then the [Unified Execution Roadmap](../docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md) and the [current governance status](../docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md). `SPEC.md` is upstream/generic guidance and is subordinate when it differs from V4.1.

These documents and this file guide authorized work. They do not grant implementation, lifecycle, merge, release, or acceptance authority. Preserve exact scope and evidence requirements.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Follow V4.1 repository law and accepted governance where they differ from upstream/generic
  [`../SPEC.md`](../SPEC.md). Update the spec only when doing so preserves that precedence.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Simplicity is a project constraint: prefer the smallest coherent design with one clear owner and
  invariant. Push back on extra abstractions, duplicated policy, and speculative flexibility.
- For stateful changes, check startup, reload, restart, and failure recovery together before editing.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

- Prefer narrow tests that exercise real OTP processes and observable behavior over mock-only or
  broad end-to-end coverage; prove health with a synchronous call or stable effect, not only a PID.
- For non-trivial changes, use an adversarial review early to challenge complexity and try to break
  adjacent lifecycle paths; a reproducible failure blocks landing even if other reviews are clean.
- If tests need repeated global restarts or bespoke cleanup, first fix the shared harness or
  ownership boundary.

```bash
make all
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Evaluate proposed directions instead of agreeing reflexively; surface simpler designs and material
  trade-offs early.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Merge and acceptance

Green checks prove only that required checks succeeded for a candidate. They do not grant merge
permission or programme acceptance. Merge authority is human/external. Merge and acceptance are
separate facts.

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
