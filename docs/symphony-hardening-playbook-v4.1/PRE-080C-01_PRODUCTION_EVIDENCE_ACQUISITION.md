# PRE-080C-01 — Production Evidence Acquisition

**Status:** Implementation complete — independent review pending (not accepted in programme ledger)

## Accepted baseline

| Field | Value |
|---|---|
| Base SHA | `01298f55422f689be52657e85ae7f84379c2f8ab` |
| Base tree | `1b1a78af2ba1e0157ff046eaf818861f0b069096` |
| Characterization | `DEFECT_PROVEN` |

## Defect (pre-fix)

Ordinary runtime transition execution validated lifecycle guards but did not acquire every required evidence family in production:

- `Plane.AgentTool` copied `guard_evidence` from host context without host-built semantic attestations.
- `TransitionCoordinator` did not emit `planning_requirements_verified` after fresh-context authorization.
- `SourceControl` candidate capture produced `candidate_state_verified` but not `implementation_checks_verified` / `correction_checks_verified`.

Candidate capture, reviewer mechanical acceptance, and CompletionProof producers were already correct and were not redesigned.

## Repair ownership (post-fix)

| Evidence | Owner |
|---|---|
| Role semantic attestations (`plan_attested`, `implementation_attested`, `correction_attested`, `review_accepted`, `review_changes_requested`) | `Plane.AgentTool` |
| `planning_requirements_verified` | `TransitionCoordinator` (fresh-context path) |
| `implementation_checks_verified` / `correction_checks_verified` | `SourceControl` (candidate capture + required-check verification) |

## Focused regression

```bash
cd elixir
mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs
mix test test/symphony_elixir/plane_agent_tool_test.exs test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/source_control_test.exs
```

## Negative proofs covered

- Stale runtime attempt identity rejects semantic binding.
- Runtime-supplied semantic attestations in host `guard_evidence` are rejected.
- Failed required GitHub checks block Builder candidate enrichment.

## Final gates (run on candidate)

```bash
cd elixir && mix specs.check && make all && git diff --check
```

Record exact command output in the PR handoff; do not self-accept PRE-080C-01.
