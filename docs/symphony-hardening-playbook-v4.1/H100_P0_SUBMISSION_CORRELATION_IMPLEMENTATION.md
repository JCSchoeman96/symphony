# H-100 P0 Submission Correlation Implementation

This document records the application-side remediation for the H-100 P0 submission-correlation gap. It describes source behavior only. It does not authorize H-100 execution, provider resource creation, credential provisioning, acceptance, rollout, merge, or push.

## Lifecycle and durable ordering

The lifecycle state set is unchanged. Model C has two related, distinct guarantees:

- A durable `prepared` attempt with `submission_fenced_at` is the conservative restart and no-resubmit fence. It remains a reconciliation candidate.
- A durable `mutation_submitted` attempt records the dispatch boundary and an immutable `provider_request_id`.

The coordinator now follows this order:

```text
prepared
-> persist and sync
-> prepared with submission_fenced_at
-> persist and sync
-> validate the final bound provider context
-> build the provider-neutral mutation envelope
-> mutation_submitted with provider_request_id
-> persist and sync
-> provider dispatch
-> verifying with fresh provider reread
-> verified | conflict | provider_failed | indeterminate
```

The provider callback is never invoked if envelope validation, the submitted-record write, or its sync fails. Failed submitted persistence leaves the item fenced for reconciliation. No failure grants automatic resubmission authority.

## Correlation identity and compatibility

`provider_request_id` is a separately generated opaque `preq_<UUID>` value. It is unique in the transition ledger and immutable once recorded. It is not a provider idempotency key and does not change Plane's mutation semantics.

Legacy ledger records without `provider_request_id` remain readable and are normalized with a nil field when they use the older struct shape. They remain fenced and reconciliation-only. `TransitionAttemptLedger.resubmit_allowed?/1` remains false.

`ProviderMutationEnvelope` binds the request identity to the transition attempt, work item, requested lifecycle edge, provider, workspace, project, target provider state, provider contract fingerprint, and submission time. It contains no credentials, headers, request body, or provider response.

## Exact Finch request witness

The same envelope passes through `Tracker` and the Plane adapter. Req 0.6.1 constructs the final `Finch.Request` with `provider_request_id` in Finch private metadata. In explicit witness-required mode, the Plane client's Req `:finch_request` callback:

1. checks that the final request is the expected PATCH for the bound path and body;
2. checks the private correlation ID against the envelope;
3. creates a secret-free `ProviderDispatchWitness`;
4. waits for the configured sink to acknowledge the same request ID; and
5. invokes Finch once with that exact request object, retaining bounded response streaming.

The ID is not placed in an HTTP header or body. Enable the mode with `dispatch_witness_required?: true` and a `dispatch_witness_sink` callback in `transition_coordinator_opts`; the default is not proof-required. Required mode also requires `require_durable?: true`, an available transition ledger, and the ledger's standard DETS insert and sync callbacks. Missing, failing, throwing, malformed, or mismatched acknowledgments stop the request before `Finch.stream_while` is called. Witness-required mode rejects a missing envelope and alternate request-function transport. It pins Req to its Finch adapter, clears global Req plug, plugin, and query-parameter defaults, and rejects a final request with a query string. The Plane client checks the envelope's work item, provider, workspace, project, and target state against the mutation arguments before building the request. Coordinator startup rejects required mode without a valid sink, durable ledger, or the standard DETS callbacks. It also rejects custom submit or verify callbacks that could bypass the witnessed Plane request or fresh provider reread.

The Plane client validates the final Finch request against the envelope, then sends a secret-free witness with the same request ID to the sink. The sink receives the witness fields only, not the Finch request, URL, headers, or body. After the sink acknowledges that ID, the client passes the validated request object to Finch once. This application boundary does not prove that TLS bytes left the host, that Plane received the PATCH, or that Plane committed it. A successful mutation response remains provisional; only the normal fresh provider reread resolves the outcome.

## H-100 boundary

This source change does not implement the host relay, bind encrypted response bytes to the witness, suppress a response, or satisfy H-100 P0 execution evidence. A separate environment design must prove that it can consume this contract and suppress the response for the correlated request without timing-only inference or TLS plaintext inspection. H-100 remains blocked until that design is authorized, implemented, and independently qualified.

## Verification

Focused suites cover attempt identity and legacy records, durable coordinator ordering and failed persistence, envelope scope binding, Tracker/Plane propagation, witness acknowledgments, and Plane client fail-closed behavior. The full repository verification record belongs with the implementation candidate and must not be read as H-100 acceptance.
