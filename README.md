# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

## Routed agent lifecycle

The reference Elixir implementation can route each tracker state to a bounded
role: planning, implementation, review, correction, or a deferred merge gate.
Use the explicit `agent.routing: routed` configuration, a stable
`symphony.project_id`, and the shipped `elixir/prompts/` role policies when
enabling this mode. Workflows without `agent.profiles` remain on the legacy
runtime path for compatibility. The current Linear adapter is intentionally
rejected in routed mode until it can truthfully satisfy the complete capability
contract; the deterministic memory adapter is used for routed local tests.

The orchestrator bounds ordinary runtime/spawn retries to three per issue
lineage. Capacity waits, normal continuations, and route changes are tracked
separately; reviewer-to-correction loops stop after three cycles. CI
infrastructure is not retried automatically. In routed mode, safety-relevant
attempt lineage state is stored in a project-scoped DETS ledger outside the
repository and workspaces, synced before automatic follow-up, and reconciled
against fresh tracker state after restart. Runtime sessions and retry timers
are never restored.

An exhausted lineage requires an explicit host-only rearm:

```bash
mix symphony.attempt_rearm --project-id symphony-main --issue-id ENG-123 \
  --reason "provider state verified" --operator alice \
  --timestamp "$(date +%s%3N)"
```

Manual DETS deletion is unsupported because it can destroy safety history.

For Linear workflows, read-only `linear_graphql` queries remain available to every role. Lifecycle
state changes use the session-bound `linear_transition` tool, which authorizes only role-owned
handoffs and denies implementation/correction or merge handoffs when dependency data is unsafe.
Raw Linear GraphQL mutations are rejected at this boundary; provider-native mutation tools for
other adapters remain provider-specific permission boundaries.

Linear handoffs revalidate current issue state and the dependency graph with the session's bound
provider settings. A session may attempt one handoff; an uncertain mutation response requires a
fresh attempt. This is a fresh authorization check, not an atomic transaction with concurrent
tracker edits. Retry dispatch also rechecks eligibility, capacity, and role after its final graph
refresh, and counts review-to-correction transitions observed while waiting for retry.

Legacy adapters without graph support retain their per-issue dependency checks. Explicit routed
work still requires authoritative graph support for implementation and correction. Built-in prompt
names must match the configured responsibility; custom prompt content remains operator-controlled.

## Live proof

Provider live tests are skipped unless the operator explicitly enables the test, names a disposable
provider resource, supplies the provider credential and an explicit Codex home, and sets
`SYMPHONY_LIVE_PROOF_CONSENT` to the documented exact token. A skipped test is not live proof.
See [the proof procedure](docs/symphony-agent-router-dependency-proof.md) for the required variables,
cleanup behavior, and the remaining external-proof limits.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
