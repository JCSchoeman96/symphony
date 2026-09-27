# H-070B Implementation Evidence

## Candidate identity

| Field | Result |
|---|---|
| `BASE_SHA` | `05fac06e771bbf1928e4975092741db0c94ecede` |
| `BASE_TREE` | `09c4f133ee53e685e5d0f5a427f7df72e0985c8f` |
| `TESTED_IMPLEMENTATION_HEAD` | `17bf5ebf45dc23aa4106381a48b5fb4970db71cf` |
| `TESTED_IMPLEMENTATION_TREE` | `11cf73f914858a595d5f1f0ebd168d36fa032b63` |
| `CURRENT_PR_HEAD` | `17bf5ebf45dc23aa4106381a48b5fb4970db71cf` — PR candidate used for this verification snapshot. |
| `CURRENT_PR_TREE` | `11cf73f914858a595d5f1f0ebd168d36fa032b63` |
| `CURRENT_SYNTHETIC_MERGE_HEAD` | `54b046620c4094b9efa7d1895743301a6edab30f` |
| `CURRENT_SYNTHETIC_MERGE_TREE` | `11cf73f914858a595d5f1f0ebd168d36fa032b63` |
| `CURRENT_SYNTHETIC_MERGE_PARENTS` | accepted base `05fac06e771bbf1928e4975092741db0c94ecede`, PR head `17bf5ebf45dc23aa4106381a48b5fb4970db71cf` |
| `EVIDENCE_SNAPSHOT` | The identities above are the exact source candidate and synthetic merge used for this verification. This documentation-only refresh advances the PR; the live identity is recorded in the PR description. |
| `COMMITS` | `be761300f99d8f9c6d86e16f0614a6145c8e9f0e`, `0a36322bb8807ea02f7fd2c13319b49f21468fc2`, `f45de883c6ccaf0fbf2e3693bc9c782333c75c9d`, `8245e0be2457f1b53cc834b29f33905066886a06`, `94c555566b4a539cd809178ddd2380d867719eab`, and `17bf5ebf45dc23aa4106381a48b5fb4970db71cf` (tested implementation candidate). |
| `PR_NUMBER` | [#24](https://github.com/JCSchoeman96/symphony/pull/24) — open against `main`. |
| Governance | H-070A remains accepted at PR #23. H-070B is under review at PR #24 and is not accepted. H-080A remains unauthorized. |

## Implementation

| Field | Result |
|---|---|
| `WEBHOOK_ENDPOINT` | `POST /api/v1/webhooks/plane` |
| `SIGNATURE_SCHEME` | Plane v2 HMAC-SHA256 over the exact raw request bytes; fixed-length decoded digest comparison uses a constant-time primitive. `PLANE_WEBHOOK_SECRET` is host-only and missing configuration fails closed. |
| `REQUEST_PARSER_ORDER` | Ordinary requests are parsed before method override. Plane webhook POST bodies bypass both until the raw-body HMAC check succeeds. |
| `RAW_BODY_TESTS` | Tests cover exact-byte signing, one-byte tampering, reserialized-body mismatch, missing/invalid signatures, invalid media type and content length, malformed envelopes, bounded chunked reads, overflow during a `:more` body read, and zero Orchestrator calls for pre-authentication failures. A validly signed request with unavailable host secret returns 503; an invalid signature returns 401. The limit is 1,048,576 bytes. |
| `DEDUP_KEYS` | Delivery `{workspace_id, webhook_id, delivery_id}` and logical event `{workspace_id, webhook_id, event_id}`. Logical event identity suppresses Plane retries with new delivery IDs. |
| `DEDUP_STORAGE` | Private Orchestrator-owned ETS registry; in-memory and empty after restart. |
| `TTL` | 24 hours, based on monotonic time. |
| `MAX_ENTRIES` | 20,000 combined delivery and event keys, with oldest-entry eviction. |
| `REPLAY_TESTS` | Concurrent retry test sends 20 delivery attempts for one logical event: one admission and one scheduler-backed REST read; 19 attempts are classified as duplicate events. Tests also cover duplicate delivery IDs, TTL expiry, bounded eviction, restart behavior, and admission rollback. |
| `OUT_OF_ORDER_TESTS` | A full epoch begun before a webhook is discarded as stale and followed by one covering epoch. A same-item burst of 1,000 newer events while a read is blocked coalesces to one latest rerun; the provider-read counter is exactly 2. A preserving targeted result leaves an unrelated in-flight full epoch valid. |
| `PROVIDER_READ_COUNTS` | Targeted work-item reconciliation makes singleton reads through the existing `Plane.ReadScheduler`. The concurrent duplicate test makes exactly 1 read. The 1,000-event same-item coalescing test makes exactly 2 reads. A distinct-item burst holds at 2 targeted reads in flight and 64 pending intents; overflow marks one full-epoch reconciliation dirty. |
| `QUEUE_BOUNDS` | Repeated bursts with both targeted read slots held open publish full epochs while superseding pending work. The regression verifies that two successive 64-item queues are cleared at publication and remain bounded while both reads stay in flight. Queue compaction also removes duplicate IDs while preserving FIFO order for surviving intents. |
| `FULL_EPOCH_COUNTS` | The epoch overlap test observes 2 graph fetches and 4 project-snapshot fetches: the stale in-flight epoch and one follow-up that covers webhook generations. Existing scale tests also completed at 1,000, 5,000, and 10,000 items; the 10,000-item run reported 10,200 calls, peak scheduler concurrency 3, and 149,211 ms elapsed. |

Targeted results can preserve or reduce current authority. Verified exact Plane 404 is represented as explicit absence and may reduce existing authority. Timeouts, throttling, server errors, malformed or wrong-scope responses do not become absence. Targeted reconciliation cannot create work-control state, restore or advance authority, satisfy dependencies, prove completion, mutate Plane, or patch the dependency graph. Graph-sensitive events request a complete immutable epoch. A fresh Plane `Done` value still cannot satisfy completion without `CompletionProof`.

The existing periodic Plane polling path remains available as the recovery backstop. Pre-authentication events use bounded Telemetry metadata, and signature rejections increment a node-local atomic counter; neither path calls the Orchestrator. Other Orchestrator webhook metrics are recorded only after HMAC verification. Webhook status exposes fixed counters and bounded counts, not event identities, payloads, signatures, or event history. Temporarily unavailable host verification configuration returns 503 so Plane can retry; an invalid signature returns 401. Ordinary request parsing still runs before method override, while Plane webhook POST bodies remain unread until HMAC verification.

## Changed files

```text
docs/symphony-hardening-playbook-v4.1/HARDENING_STATUS_LEDGER.md
docs/symphony-hardening-playbook-v4.1/H-070B_IMPLEMENTATION_EVIDENCE.md
elixir/README.md
elixir/lib/symphony_elixir/credential_boundary.ex
elixir/lib/symphony_elixir/orchestrator.ex
elixir/lib/symphony_elixir/plane/adapter.ex
elixir/lib/symphony_elixir/plane/client.ex
elixir/lib/symphony_elixir/plane/dependency_reader.ex
elixir/lib/symphony_elixir/plane/reconciliation_intent.ex
elixir/lib/symphony_elixir/plane/state_projection.ex
elixir/lib/symphony_elixir/plane/webhook_dedup_registry.ex
elixir/lib/symphony_elixir/plane/webhook_delivery.ex
elixir/lib/symphony_elixir/plane/webhook_ingress_metrics.ex
elixir/lib/symphony_elixir/plane/webhook_signature.ex
elixir/lib/symphony_elixir/work_control/lifecycle_assessment.ex
elixir/lib/symphony_elixir/work_control/provider_observation.ex
elixir/lib/symphony_elixir/work_control/recovery_ledger.ex
elixir/lib/symphony_elixir_web/controllers/plane_webhook_controller.ex
elixir/lib/symphony_elixir_web/endpoint.ex
elixir/lib/symphony_elixir_web/plugs/plane_webhook_ingress.ex
elixir/lib/symphony_elixir_web/plugs/request_parsers.ex
elixir/lib/symphony_elixir_web/router.ex
elixir/mix.lock
elixir/test/symphony_elixir/credential_boundary_test.exs
elixir/test/symphony_elixir/orchestrator_plane_epoch_test.exs
elixir/test/symphony_elixir/orchestrator_plane_webhook_test.exs
elixir/test/symphony_elixir/plane_adapter_test.exs
elixir/test/symphony_elixir/plane_client_test.exs
elixir/test/symphony_elixir/plane_webhook_test.exs
elixir/test/symphony_elixir/work_control_recovery_ledger_test.exs
```

`mix.lock` updates Bandit to 1.12.5 and its compatible transport dependencies. This addresses the upstream chunked-body length-cap issue reported for Bandit versions below 1.11.1; see the [Bandit security advisory](https://github.com/advisories/GHSA-9q9q-324x-93r2) and [upstream changelog](https://github.com/mtrudel/bandit/blob/main/CHANGELOG.md). `mix setup` still reports advisories for the unchanged locked versions of Phoenix 1.8.4, Phoenix LiveView 1.1.25, Decimal 2.3.0, LazyHTML 0.1.10, and Mint 1.10.0. Those packages need a separate dependency review.

The Plane v2 contract adjudication records that `event_id` is the retry-stable logical identity while `delivery_id` changes per attempt. It also records the current documentation mismatch: the event reference lists dot-notation names, while one `workitem.updated` payload example uses an enum-style value. The implementation does not add speculative aliases. See [Plane webhooks](https://developers.plane.so/dev-tools/intro-webhooks) and the [Plane issue detail API](https://developers.plane.so/api-reference/issue/get-issue-detail).

## Verification

| Field | Result |
|---|---|
| `FULL_TEST_RESULTS` | `make -C elixir all` passed: 1,444 tests, 0 failures, 6 skipped. |
| `COVERAGE` | 90.02% total; project threshold passed. |
| `CREDO` | Clean; all 204 source files checked and all public functions have specs or an exemption. |
| `DIALYZER` | Passed with 0 errors, 0 skips, and 0 unnecessary skips. |
| Formatting | `mix format --check-formatted` passed. |
| Diff validation | `git diff --check` passed; the new evidence file was checked for trailing whitespace. |
