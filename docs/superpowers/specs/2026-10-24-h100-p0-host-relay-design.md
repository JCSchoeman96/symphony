# H100 P0 host relay design

## Status and authorization

This document records the approved H100 P0 relay design direction. Its text has been revised following Master Gate review and is pending formal spec acceptance. Approval covers specification only.

```text
DESIGN_DIRECTION=APPROVED
FORMAL_SPEC_TEXT=REVISED_PENDING_REVIEW
IMPLEMENTATION_AUTHORIZED=NO
LOCAL_QUALIFICATION_AUTHORIZED=NO
LIVE_PLANE_USE=NO
CREDENTIAL_USE=NO
GITHUB_TOKEN_MINT=NO
H100_EXECUTION=NO
H110_EXECUTION=NO
PLANE_LIFECYCLE_MUTATION=NO
```

The design is based on the accepted #58 source candidate:

```text
candidate_sha=27c2d813092a438e46505a5ddd8f50c0f787770d
candidate_tree=73b6c50b7222ccfb6c02d8f183aa3dfbcbddc78b
```

The application-side A4 witness and manifest are present in that candidate. The host relay and its egress controls are not operationally implemented or independently qualified. This design does not change the accepted candidate or authorize an implementation branch, provider operation, or H100 run.

## Goal

Provide an environment boundary that binds the existing `provider_request_id` witness to one outbound TLS connection, allows the request to reach a local qualification origin, and prevents the corresponding encrypted response from reaching Finch. The relay must do this without TLS termination, plaintext inspection, timing-only correlation, or changes to the normal production Finch transport.

## Design decision

Use a dedicated proof-only Finch transport through a one-use local HTTP CONNECT relay. The proof process is an isolated Symphony/BEAM qualification process, separate from the normal production runtime, and runs under a dedicated unprivileged proof OS identity. The relay runs under a separate unprivileged OS identity.

The host controller/launcher is the only component permitted to create or remove the dedicated egress policy. Its privilege is limited to that policy. The proof and relay identities have no capability to change firewall or routing policy. Before spawning the proof process, the launcher installs a deny-all network-egress policy for a dedicated, preselected proof identity scope (such as a dedicated UID or a pre-created cgroup/network namespace). A separate read-only policy verifier confirms that the scope is denied before the process starts. Local Unix-domain process IPC remains available for A4 control messages. If installation or independent verification fails, the proof process does not start.

After the relay binds and exposes its ephemeral port in READY, the launcher replaces or augments the proof identity's policy with one exact TCP allowance to `127.0.0.1:<bound-port>` while retaining deny-all for every other network destination, protocol, and address family. A separate read-only verification must confirm the exact port and actual proof-process identity before the host controller returns READY to A4. If this second verification fails, the controller withholds READY, leaves egress denied, stops the relay, and fails the proof session. No Finch pool, CONNECT, TLS, or provider request bytes may be emitted before the second verification passes.

The proof process may connect only to the relay's verified loopback listener. Its other IPv4 and IPv6 egress is denied. The A4 manifest and READY exchange uses local process IPC while network egress is denied. For qualification, the relay may connect only to the local TLS fixture. The normal production Finch pool, credentials, and routing remain outside this proof configuration.

The live-H100 relay egress target and address-pinning method are unresolved and non-normative here. No DNS resolution, address set, firewall allowance, or IP-pinning strategy for `api.plane.so:443` is approved by this spec. That boundary requires a separately authorized live-H100 preflight.

The relay is not a generic proxy. It accepts one connection, checks one request ID and one exact CONNECT authority, and opens at most one upstream connection. After CONNECT succeeds, it forwards TLS payload bytes unchanged and does not terminate TLS. It reads TLS record framing and content type only so it can enforce the record limits and withhold the first server application-data record.

## Components and ownership

| Component | Responsibility |
| --- | --- |
| A4 application contract | Bind the durable mutation attempt, manifest, witness, candidate identity, and `provider_request_id`. |
| Host controller/launcher | Own the only policy-changing privilege; install and remove the proof egress policy, start the relay, provide manifest and READY data to A4, and stop the relay. |
| Read-only policy verifier | Independently confirm deny-all before proof-process spawn, then confirm the exact relay-port exception and actual process identity before READY is returned to A4. |
| Proof-only Finch transport | Use one fresh HTTP/1.1 connection with verified TLS 1.2, send the exact witnessed request once, retain the ID in existing Finch private metadata, and expose it on the wire only in the local CONNECT request header. |
| Local CONNECT relay | Check the manifest-bound ID and authority, pass TLS records without decrypting them, enforce one-connection and record limits, suppress the first server application-data record, and emit payload-free evidence. |
| Independent reviewer | Verify the local qualification evidence, OS egress policy, and record-model gate before any later authorization is considered. |

`A4Proof` remains the application-side owner of manifest and READY validation. The relay does not grant Plane permissions, infer provider state, or decide whether a lifecycle transition is valid. The existing test helper at [`connect_helper.py`](../../../elixir/test/support/a4/connect_helper.py) is a test fixture only; it is not the host controller, production relay, or egress enforcement.

The proof identity and relay identity are unprivileged and cannot create, change, or remove the egress policy. The policy verifier is read-only. Before spawn, qualification evidence records the preselected policy scope, its effective deny-all rule identity, and the independent verification result. After spawn, the launcher records the actual proof process PID and UID, cgroup, and/or network-namespace identity and proves that the process is inside that same policy scope. The second policy verification binds that actual process identity to the exact relay-port rule. The evidence packet links both checks, the policy scope, and the launched process; showing that some firewall rule exists is insufficient.

## A4 manifest and READY compatibility

The initial relay qualification must reuse the accepted A4 manifest and READY schemas exactly. The manifest field set is:

```text
schema
manifest_id
experiment_scope
provider_request_id
transition_attempt_id
work_item_id
workspace_id
project_id
target_state_id
method
origin_kind
origin_authority
origin_base_url
candidate_sha
candidate_tree
relay_script_blob_sha256
python_path
python_version
max_dispatch
max_connect
max_client_app_records
tls_versions
not_before
expires_at
operator_authorization_ref
manifest_sha256
```

The READY field set is:

```text
type
provider_request_id
listen_host
bound_port
python_version
script_blob_sha256
environment_names
```

The manifest keeps schema identifier `a4-v2_1` and experiment scope `single_designated_state_patch`. Existing checks for the one-dispatch, one-connect, one-client-record, TLS 1.2, canonical JSON, manifest hash, and validity window remain in force. READY remains bound to `type=READY`, the same request ID, loopback host `127.0.0.1`, a valid bound port, and the manifest's Python version and relay script hash. Existing `environment_names` validation also remains unchanged.

The names, meanings, validation rules, and canonical encodings remain those enforced by the accepted `A4Proof` contract. If implementation requires adding, removing, renaming, or reinterpreting a field, it is a source-contract change and returns to Master Gate and design review. It is not an implementation detail.

## Startup, policy, and request flow

1. Before spawning the proof process, the host controller/launcher installs a deny-all network-egress policy for the dedicated, preselected proof OS identity scope. A separate read-only verifier confirms that scope is denied. Local Unix-domain IPC remains available for A4 control messages.
2. The launcher spawns the isolated Symphony/BEAM proof process under that unprivileged identity and records its PID and selected UID, cgroup, and/or network-namespace identity. The deny-all network policy remains active.
3. A4 requests a manifest over local process IPC. The host controller returns it, and A4 validates the candidate, target authority, request ID, relay script hash, expiry, and one-use limits against the bound mutation attempt and witness.
4. A4 requests READY over local process IPC. The host controller starts the relay under its separate unprivileged identity. The relay binds its loopback listener to an ephemeral port and returns READY to the host controller, binding the port, script hash, runtime version, and request ID to the manifest. READY is not yet returned to A4.
5. The launcher replaces or augments the proof identity's deny-all policy with one exact TCP allowance to `127.0.0.1:<bound-port>`, retaining denial for every other network destination, protocol, and address family. The read-only verifier confirms the active rules match the exact listener port and the actual proof-process identity. On failure, the controller withholds READY, leaves the proof identity denied, stops the relay, and fails the proof session.
6. Only after that second verification succeeds does the host controller return the existing READY message to A4. A4 validates READY and consumes the proof session. The Plane client then starts its dedicated Finch pool with HTTP/1.1 only, pool size and count one, the local proxy, a `x-symphony-provider-request-id` CONNECT header, peer-verified TLS 1.2, no retry, and no redirect. The pool is new for the request and is stopped afterwards.
7. The final Finch request retains `provider_request_id` in its existing private metadata. The Plane client validates that metadata against the envelope immediately before `ProviderDispatchWitness.dispatch`; the witness sink acknowledges that ID before the exact request is dispatched once. This private metadata is not sent on the wire. No Finch pool or transport bytes are emitted before the second policy verification.
8. Finch sends one CONNECT to the manifest authority. The relay requires exactly one matching request-ID header and the exact authority before it opens the upstream socket. The proxy header ends at the relay; it is not sent as part of the TLS tunnel. CONNECT establishes a tunnel whose intermediary forwards data between both sides ([RFC 9110, Section 9.3.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6)).
9. Finch performs TLS 1.2 end-to-end with certificate and hostname verification. The relay never holds TLS keys and never reads or writes TLS plaintext. It forwards TLS handshake records and the single permitted client application-data record unchanged.
10. Once the relay observes the first server application-data record, it withholds that record and closes both tunnel sockets. It records only the record length and a SHA-256 digest of the encrypted fragment, not the fragment itself. No part of that record is forwarded to Finch.

The request ID is bound mechanically through the A4 manifest, the final Finch request's private metadata, the witness acknowledgement, the proof transport's CONNECT header, and the relay's one-use connection check. The ID remains in the existing Finch private metadata and is additionally exposed on the wire only in the local CONNECT request header. It never enters the tunneled origin request headers or body. Connection timing is not used as identity evidence. CONNECT's request headers are outside the tunnel; after CONNECT, the relay sees TLS record metadata but not the encrypted application content.

## TLS record gate

The accepted A4 manifest currently requires TLS 1.2 and `max_client_app_records == 1`. This limit is a qualification gate, not a behavior to relax when an integration fails.

```text
EXACT LOCAL FINCH REQUEST FITS REQUIRED TLS 1.2 RECORD MODEL
    ├─ YES -> qualification may continue
    └─ NO or request spans multiple application-data records
             -> STOP
             -> fail qualification
             -> return to design review
```

TLS 1.2 exposes record type and length outside encryption, while the record payload is protected. TLS 1.2 also permits a higher-level message to span several records ([RFC 5246, Section 6.2](https://www.rfc-editor.org/rfc/rfc5246.html#section-6.2)). Therefore, neither the Finch pool size nor the protocol guarantees the one-record property.

The exact local Finch integration must independently demonstrate that the complete bounded PATCH is emitted as one TLS 1.2 application-data record. The current [`a4_transport_proof_test.exs`](../../../elixir/test/symphony_elixir/a4_transport_proof_test.exs) fixture records one complete PATCH and one client application-data record; that is useful regression coverage, but it does not qualify the host firewall or constitute independent host-relay qualification. If the exact integration request splits across records, stop. Do not increase the record limit, buffer records based on timing, or otherwise broaden relay behavior without a new design review.

## Local TLS trust

The local origin certificate is generated for the qualification run and signed by a generated local CA. TLS verification remains enabled with `verify_peer`, and hostname verification must match the local fixture authority. `verify_none` is prohibited.

The generated CA may be added only to a TLS trust context isolated to the dedicated proof process, or supplied through an equivalent per-connection trust context. It must not be added to a shared host or normal-runtime trust store. Teardown must restore the proof process's exact prior trust anchors and destroy the generated CA, server certificate, and private key material, including on failure.

## Failure behavior

| Condition | Required result |
| --- | --- |
| Invalid, stale, malformed, or mismatched manifest or READY | Reject before dispatch; do not start the proof request. |
| Missing, duplicate, or incorrect CONNECT request ID; wrong authority | Reject before opening an upstream connection. |
| Firewall policy absent, unverifiable, or broader than the approved identity rules | Do not start the proof dispatch. |
| Duplicate CONNECT or upstream connection | Reject or close; no second request and no retry. |
| Wrong TLS version, malformed or truncated record, unexpected TLS framing, or a second client application-data record | Close the tunnel and fail qualification. Never widen limits automatically. |
| First server application-data record | Withhold the whole record, close both sockets, and report response suppression. |
| Transport failure after request bytes have been forwarded | Do not retry or replay. Treat remote outcome as unresolved until the existing fresh provider read establishes state. |

The guarantee is one Finch dispatch attempt and at most one upstream connection. The relay does not claim that Plane committed a mutation. The existing fresh provider reread remains the authority for provider state.

## Local qualification plan

Qualification is local-only and uses the exact accepted candidate, a generated test certificate, and a local TLS origin. The relay's qualification manifest must permit only that fixture. It must contain no live Plane authority or real credential. If the exact client requires an authorization header, use only a non-secret, nonfunctional fixture sentinel that the local test origin accepts. The local generated CA must satisfy the isolated trust requirements above, with peer and hostname verification left enabled.

Qualification must establish all of the following:

- The exact Finch integration passes the TLS record gate above.
- The local origin receives one complete PATCH over one CONNECT and one upstream connection.
- The helper observes the server application-data record, forwards none of it to Finch, and closes the tunnel.
- Missing, duplicate, or mismatched request IDs and wrong authorities produce no upstream connection.
- A forced multi-record client request fails qualification and is not retried; this negative test does not change the one-record requirement.
- Duplicate connections, malformed or truncated records, wrong TLS versions, and watchdog expiry fail closed.
- The proof identity can reach the relay listener but cannot reach a separate local egress canary directly over IPv4 or IPv6. Evidence binds the actual proof PID and selected UID/cgroup/network-namespace identity to the active policy identity, and captures the read-only verification result and drop counters.
- A separate non-proof process remains outside the relay policy and completes an unrelated local control exchange, showing the restriction is scoped to the proof identity.
- The evidence contains no TLS payload, request body, credential, key material, or response body.

An independent reviewer must inspect the candidate SHA/tree, relay script hash, manifest binding, firewall rule identity, direct-egress denial evidence, local-origin request count, TLS record counts, suppression evidence, and exit status. The evidence packet must be reproducible and contain no secrets.

Passing this local qualification proves the relay capability only. It does not authorize a live Plane preflight, a permission change, token minting, proof-resource creation, lifecycle mutation, H100 execution, or H110 execution.

## Alternatives

- Kernel socket interception would require new witness-to-socket correlation and encrypted response suppression machinery. It is outside this design.
- TLS termination would expose plaintext and change the trust boundary. It is prohibited.
- Reusing normal production Finch with a global proxy would affect unrelated traffic. It is prohibited.

## References

- [H100 P0 application-side correlation contract](../../symphony-hardening-playbook-v4.1/H100_P0_SUBMISSION_CORRELATION_IMPLEMENTATION.md)
- [RFC 9110, Section 9.3.6, CONNECT](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6)
- [RFC 5246, Section 6.2, TLS 1.2 record protocol](https://www.rfc-editor.org/rfc/rfc5246.html#section-6.2)
