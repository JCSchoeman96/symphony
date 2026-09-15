# H-020 provider capability contract evidence

This document records the H-020 provider capability contract only. It is
acceptance evidence for PR #5, not a plan for later hardening phases.

## Scope and baseline

- Accepted starting SHA: a1c60f1e8cb39233d89c341936947547d272891d
- H-020 responsibility: define and enforce a truthful provider capability
  contract before routed dispatch.
- H-020 does not grant runtime authority, persist runtime state, or change the
  retry and review policy.
- H-030 is not part of H-020 acceptance.

## Capability vocabulary

Tracker.Capabilities owns this local vocabulary:

- current_issue_refresh
- dependency_graph
- dependency_completeness
- controlled_transition
- transition_verification
- agent_read_tools
- agent_transition_tools
- conditional_transition

The one authoritative required routed set is:

- current_issue_refresh
- dependency_graph
- dependency_completeness
- controlled_transition
- transition_verification
- agent_read_tools
- agent_transition_tools

conditional_transition is in the vocabulary but is not in the required routed
set. It must not be inferred from another capability.

## Ownership boundary

Tracker.Capabilities answers two questions:

1. Which capabilities does the selected adapter declare?
2. Does each declaration have the required callback shape?

It does not authorize a runtime transition, dispatch, retry, review action, or
other agent responsibility. A future Runtime.Authority boundary owns runtime
authority decisions. H-020 does not implement or accept that future boundary.

## Local, network-free resolution

Tracker.capabilities_for_kind/1 selects an adapter from the local adapter map
and validates its declaration. It does not call a provider client or make a
network request. The capability test uses a probe client and asserts that no
provider_request message is received.

Absent optional capabilities/0 callbacks resolve to an empty declaration.
Invalid, unknown, duplicate, structurally unsupported, raising, and throwing
declarations return validation errors instead of escaping startup validation.

## Per-adapter capability matrix

| Adapter | H-020 declaration | Routed posture | Evidence and limits |
| --- | --- | --- | --- |
| Linear | current_issue_refresh, dependency_graph, dependency_completeness, controlled_transition, agent_transition_tools | Rejected for routed mode at H-020 | Missing transition_verification and agent_read_tools. conditional_transition is unsupported unless separately proven. |
| Memory | The complete required routed set | Simulation and test evidence only | It is a deterministic local adapter. It is not external-provider proof. |
| Asana | No H-020 capability declaration | Legacy-only | Routed validation rejects the missing required set. |
| GitHub | No H-020 capability declaration | Legacy-only | Routed validation rejects the missing required set. |
| GitLab | No H-020 capability declaration | Legacy-only | Routed validation rejects the missing required set. |
| Jira | No H-020 capability declaration | Legacy-only | Routed validation rejects the missing required set. |

Linear therefore supports the following H-020 behavior:

- current issue refresh
- dependency graph
- dependency completeness
- controlled transition
- agent transition tools

Linear does not support the following at H-020:

- transition verification
- agent read tools
- conditional transition unless separately proven

The external adapters without the H-020 contract remain legacy-only.

## Routed rejection and legacy behavior

Config.validate_settings/1 calls the capability gate for routed settings.
When a required capability is missing, validation returns an explicit
routed_provider_capabilities_missing error before dispatch.

There is no silent routed-to-legacy fallback. The routed configuration is
rejected, and the legacy dispatch path is not invoked. Existing runtime
fail-closed graph behavior remains in place:

- legacy graph dispatch keeps its per-issue blocker checks;
- an unsupported graph returns the existing
  dependency_graph_unsupported error;
- unresolved blockers continue to stop the affected work.

The deterministic evidence is in:

- elixir/test/symphony_elixir/tracker_capabilities_test.exs, which checks the
  local resolution, Linear's missing capabilities, declaration failures, and
  legacy bypass;
- elixir/test/symphony_elixir/legacy_graph_test.exs, which checks routed
  rejection without dispatch and preserves legacy blocker enforcement;
- elixir/test/symphony_elixir/tracker_memory_test.exs, which covers the
  deterministic Memory simulation.

## Last-known-good reload evidence

H-020 preserves the existing last-known-good reload behavior.

- agent_router_test.exs, test "workflow reload retains the last valid routed
  policy after an invalid override", verifies that WorkflowStore retains the
  previous valid settings.
- core_test.exs, test "runtime restart keeps last good settings after an
  invalid reload", verifies that an invalid reload does not replace the valid
  settings used by the running system.

The capability gate participates in validation and does not introduce a
silent fallback during reload.

## Temporary shipped workflow posture

elixir/WORKFLOW.md is intentionally configured as routing: legacy during this
intermediate hardening state because current Linear does not satisfy the
complete routed capability set.

This is an explicit configuration change. It is not an automatic runtime
fallback. Routed Linear remains intentionally fail-closed. H-040 and H-050
own the missing capabilities. The routed reference configuration may be
restored only after those phases pass their acceptance requirements.

## Validation record

The canonical validation command is:

    make -C elixir all

Observed result for the H-020 branch:

- 468 tests
- 0 failures
- 6 skipped
- 90.06% total coverage
- format check passed
- strict Credo and specs check passed with no issues
- Dialyzer passed with 0 errors

The H-020 coverage gate remains at the configured 90% threshold.

## Exact changed-file inventory

After removing the mixed plan, PR #5 contains these files:

- docs/symphony-hardening-playbook-v3/H-020_PROVIDER_CAPABILITY_CONTRACT_EVIDENCE.md
- elixir/WORKFLOW.md
- elixir/lib/symphony_elixir/config.ex
- elixir/lib/symphony_elixir/linear/adapter.ex
- elixir/lib/symphony_elixir/tracker.ex
- elixir/lib/symphony_elixir/tracker/capabilities.ex
- elixir/lib/symphony_elixir/tracker/memory.ex
- elixir/test/support/test_support.exs
- elixir/test/symphony_elixir/agent_router_test.exs
- elixir/test/symphony_elixir/dynamic_tool_test.exs
- elixir/test/symphony_elixir/extensions_test.exs
- elixir/test/symphony_elixir/legacy_graph_test.exs
- elixir/test/symphony_elixir/retry_refresh_test.exs
- elixir/test/symphony_elixir/role_prompt_test.exs
- elixir/test/symphony_elixir/tracker_capabilities_test.exs
- elixir/test/symphony_elixir/tracker_memory_test.exs

No H-030 implementation is part of this inventory. H-030 is not part of
H-020 acceptance, and PR #6 remains provisional and frozen while H-020 is
reviewed.
