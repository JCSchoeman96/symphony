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
Use the explicit `agent.routing: routed` configuration and the shipped
`elixir/prompts/` role policies when enabling this mode. Workflows without
`agent.profiles` remain on the legacy runtime path for compatibility.

The orchestrator bounds ordinary runtime/spawn retries to three per issue
lineage. Capacity waits, normal continuations, and route changes are tracked
separately; reviewer-to-correction loops stop after three cycles. CI
infrastructure is not retried automatically. Attempt counters are live OTP
state and survive workflow reloads; restart recovery remains tracker/filesystem
driven and does not synthesize prior retry history.

For Linear workflows, read-only `linear_graphql` queries remain available to every role. Lifecycle
state changes use the session-bound `linear_transition` tool, which authorizes only role-owned
handoffs and denies implementation/correction or merge handoffs when dependency data is unsafe.
Raw Linear GraphQL mutations are rejected at this boundary; provider-native mutation tools for
other adapters remain provider-specific permission boundaries.

## Live proof

Provider live tests are skipped unless the operator explicitly enables the test, names a disposable
provider resource, supplies the provider credential and an explicit Codex home, and sets
`SYMPHONY_LIVE_PROOF_CONSENT` to the documented exact token. A skipped test is not live proof.
See [the proof procedure](docs/symphony-agent-router-dependency-proof.md) for the required variables,
cleanup behavior, and the remaining external-proof limits.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
