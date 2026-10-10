# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

The demo video shows upstream prototype behavior with a Linear board and autonomous PR landing. It is historical material, not the current operating contract for this hardened fork.

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works well in codebases that follow the [upstream OpenAI harness engineering practice](https://openai.com/index/harness-engineering/). It coordinates coding agents around project work.

### Upstream specification reference

The generic upstream specification is available at:

<https://github.com/openai/symphony/blob/main/SPEC.md>

For this fork, the [V4.1 Master Roadmap](docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md) and [current Unified Execution Roadmap](docs/SYMPHONY_V4_1_UNIFIED_EXECUTION_ROADMAP_v1.3.2.md) govern. `SPEC.md` is upstream/generic compatibility guidance where it does not conflict with V4.1.

### Use this hardened fork

Use the [Elixir implementation guide](elixir/README.md) to set up this repository:

```bash
git clone https://github.com/JCSchoeman96/symphony.git
cd symphony/elixir
```

## Routed agent lifecycle

The hardened V1 implementation uses Plane as its primary work-control provider. Its routed lifecycle is governed by the V4.1 roadmap and current operator documentation. Linear remains available for legacy compatibility. The upstream demo describes historical prototype behavior, including autonomous PR landing, and does not grant merge authority here.

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

Plane observations and supported transition tools operate within Symphony's authority boundaries. `conditional_transition` remains unsupported. A Plane capability does not grant Symphony authority by itself.

Before accepting a transition, Symphony rereads Plane and reassesses lifecycle authority. A provider mutation acknowledgement is not proof of an authoritative transition. Dispatch and retry paths use the immutable dependency epoch built during reconciliation, and incomplete or unavailable dependency data fails routed dispatch closed.

Explicit routed work still requires authoritative graph support for implementation and correction.
Built-in prompt names must match the configured responsibility; custom prompt content remains
operator-controlled.

## Live proof

Provider live tests are skipped unless the operator explicitly enables the test, names a disposable
provider resource, supplies the provider credential and an explicit Codex home, and sets
`SYMPHONY_LIVE_PROOF_CONSENT` to the documented exact token. A skipped test is not live proof.
See [the proof procedure](docs/symphony-agent-router-dependency-proof.md) for the required variables,
cleanup behavior, and the remaining external-proof limits.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
