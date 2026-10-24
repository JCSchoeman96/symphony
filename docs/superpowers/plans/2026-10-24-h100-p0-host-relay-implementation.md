# H100 P0 Host Relay Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use `subagent-driven-development` to carry out this plan. Use `test-driven-development` for every source behavior and `systematic-debugging` for unexpected failures.

**Goal:** Implement the accepted H100 P0 host-relay boundary and qualify it locally with real, temporary OS egress policy, isolated TLS trust, complete encrypted response suppression, and secret-free evidence.

**Architecture:** Keep the accepted A4 schemas and proof Finch contract. An unprivileged in-BEAM controller remains A4's same-node PID and talks over a private Unix socket to an external, narrowly scoped launcher. The launcher establishes a rootless user/network namespace with dedicated mapped UIDs, installs UID-scoped nftables rules only inside that disposable network namespace, and uses a separate read-only verifier to inspect effective rules and process identity. A separate standard-library Python relay runs as its own UID, listens on loopback, validates one CONNECT correlation ID and authority, then parses TLS record framing only and suppresses the first complete server application-data record. The local qualification runs the real proof Finch through that relay to a local TLS 1.2 fixture with per-connection CA trust.

**Tech Stack:** Elixir/OTP and Finch already in the repository; Python standard library; Linux user, mount, and network namespaces; scoped nftables; OpenSSL CLI for ephemeral local certificates. No new runtime dependency.

---

## Task 1: Isolated baseline and plan review

**Files:**
- Review only: `elixir/AGENTS.md`, accepted design spec, two governance documents, A4 proof/client/tests/fixtures, witness/envelope/attempt modules, CI workflows, and `elixir/Makefile`.
- Create: `docs/superpowers/plans/2026-10-24-h100-p0-host-relay-implementation.md`.

**Tests/verification:**
- Verify exact implementation base, parent, tree, clean status, and `git diff --check`.
- Run the canonical baseline command `make -C elixir all` in an environment that suppresses unrelated global Git signing configuration; record exact result before source changes.
- Review this plan line-by-line against the accepted spec and the full required local qualification matrix.

**Commit:** `docs(h100): plan P0 host relay implementation`.

## Task 2: CONNECT parser and TLS record gate, test first

**Files:**
- Create: `elixir/priv/h100/relay.py`.
- Create: `elixir/test/python/test_h100_relay.py`.
- Create: `elixir/test/python/run_tests.py` if a stable repository test entry point is needed.

**Interfaces:**
- Relay CLI accepts only explicit bind address, port, expected request ID, expected CONNECT authority, record limit, watchdog, and evidence destination.
- Relay emits one bounded JSON evidence object to a caller-owned file/pipe; it never logs bytes or headers other than the correlation ID and parsed authority.
- A pure parser/state-machine layer is independently unit-testable without sockets.

**Tests:**
- RED then GREEN for valid, missing, wrong, duplicate, malformed, and second CONNECT; wrong authority; pre-authorization upstream count remains zero.
- Test one accepted CONNECT and prove a second upstream connection cannot be created.
- Feed arbitrary TLS records through socket pairs and verify byte-for-byte forwarding; malformed and truncated headers/payloads and watchdog expiry close both sides.
- Permit one client application-data record and fail closed on a second; verify server application-data bytes are wholly withheld and both directions close.
- Exercise wrong TLS-version negotiation against the local fixture/client path and confirm it fails; relay only observes record framing, content type, and length.
- Verify evidence is bounded and excludes tunnel payload and HTTP content.

**Commit:** `feat(h100): add correlated single-use TLS relay`.

## Task 3: Independent policy verifier and controller state machine, test first

**Files:**
- Create: `elixir/priv/h100/policy_verify.py` (read-only effective-state verifier).
- Create: `elixir/priv/h100/host_qualification.py` (launcher, policy installer, lifecycle, and cleanup orchestration).
- Create: `elixir/lib/symphony_elixir/work_control/a4_host_relay_controller.ex` (unprivileged local BEAM PID proxy for A4).
- Create: `elixir/test/python/test_h100_policy.py`.
- Create: `elixir/test/symphony_elixir/a4_host_relay_controller_test.exs`.

**Interfaces:**
- The external launcher owns the temporary namespace and policy. It communicates over a mode-0600 Unix-domain socket located in a private runtime directory; protocol messages are bounded, typed, and contain no credentials or request payload.
- The read-only verifier independently reads namespace UID maps, actual `/proc` PID identity, nftables JSON state/counters, and exact relay listener exception. The verifier has no policy mutation functions.
- The BEAM controller implements the existing `A4Proof` callback protocol and stays unprivileged. It withholds the READY response until the launcher reports successful second verification for the actual proof PID and exact relay port.

**Tests:**
- RED/GREEN ordering tests for pre-spawn deny-all verification, proof spawn, relay readiness, exact-port rule installation, second verification, and READY exposure.
- Stage A failure proves no proof process, relay, Finch, or transport starts.
- Stage B failure proves READY is withheld, egress stays denied, relay stops, and the session fails closed.
- Test actual identity-to-scope binding, exact TCP loopback-port allow rule, IPv4/IPv6 default-deny behavior, and that another UID/process remains outside the scope.
- Verify no Finch startup occurs before A4 validates and consumes READY.

**Commit:** `feat(h100): gate proof readiness on verified host policy`.

## Task 4: Proof-only TLS trust, test first

**Files:**
- Modify: `elixir/lib/symphony_elixir/plane/client.ex` only to thread a per-proof Finch CA bundle from the A4 proof session; ordinary Finch keeps its existing trust source and settings.
- Modify: `elixir/test/support/a4/transport_fixture.exs` to use per-connection trust instead of mutating VM-global trust.
- Create: `elixir/test/symphony_elixir/a4_proof_tls_trust_test.exs`.

**Tests:**
- RED/GREEN for local generated CA with correct hostname success, untrusted CA failure, and wrong hostname failure under `verify_peer`.
- Confirm TLS 1.2 from client/origin evidence and fail when the relay sees more than one client application-data record.
- Confirm the proof-specific CA does not alter shared `:public_key` trust and ordinary Finch TLS options remain unchanged.
- Assert no `verify_none` option exists in the proof path.

**Commit:** `fix(h100): scope proof TLS trust to one connection`.

## Task 5: Real local TLS fixture and proof-process runner, test first

**Files:**
- Create: `elixir/priv/h100/local_tls_fixture.py` (loopback TLS 1.2 fixture and generated CA/server certificate lifecycle).
- Create: `elixir/test/support/a4/host_qualification_runner.exs` (fresh, unprivileged proof BEAM entry point using the real A4 proof, witness, Client, and Finch path).
- Modify: `elixir/test/support/a4/transport_fixture.exs` only for shared test utilities that retain no global trust mutation.

**Tests:**
- Generate CA/key/server material under a private temporary directory, restrict file access to the origin UID, trust only the generated CA in the one proof connection, and assert exact hostname verification.
- Send the exact bounded local PATCH once; fixture confirms one complete request without writing its body to logs/evidence.
- Confirm origin emits a server application-data record, relay suppresses the full record, Finch reports transport failure, and there is one dispatch, one CONNECT, one upstream, one client application-data record, zero retries, and zero replays.
- Failure/interrupt paths remove CA, certificate, key, temporary trust files, sockets, and all fixture children.

**Commit:** `test(h100): add isolated local TLS proof fixture`.

## Task 6: Real two-stage egress qualification and canaries

**Files:**
- Complete: `elixir/priv/h100/host_qualification.py` and `policy_verify.py`.
- Create: `elixir/test/support/a4/run_h100_local_qualification.py` as the reproducible entry point.
- Create: `elixir/test/python/test_h100_local_policy_integration.py` for disposable namespace policy integration tests.

**Tests/qualification:**
- Use rootless user and network namespaces with dedicated subordinate UID mappings; bring up namespace loopback; install deny-all for the preselected proof UID before process spawn; independently verify Stage A.
- Spawn the proof BEAM under the proof UID with no capabilities and a sanitized allowlist environment. Run relay and TLS origin as separate UIDs. Keep namespace/cgroup scope distinct from the invoking user's unrelated process.
- Give the separate relay UID only the exact TCP path to the local fixture; deny all other relay egress. The TLS origin UID accepts local fixture traffic only. Neither process receives policy-changing capability.
- After relay binds `127.0.0.1:<ephemeral-port>`, install only the exact proof-UID TCP loopback-port exception and independently verify Stage B against the actual proof PID and rules/counters. The BEAM proxy does not return READY before that check.
- Verify the proof process can reach the relay, cannot reach direct IPv4 or IPv6 canaries, and records rule counters. Verify a separate non-proof process completes its local control exchange.
- Run the real Finch request. If it spans more than one client application-data record, fail qualification and stop without changing the accepted record limit.
- Verify one exact local request arrives complete; the first encrypted server application-data record is observed and zero bytes from it reach Finch; both sockets close; no retry/replay occurs.
- Exercise process/relay/fixture failure paths and prove teardown removes namespace policy, sockets, children, generated trust, and all temporary files.

**Commit:** `test(h100): qualify proof egress in isolated namespace`.

## Task 7: Evidence and repository CI wiring

**Files:**
- Modify: `elixir/Makefile` to include deterministic Python unit tests in canonical `all`/CI verification while keeping privileged/local qualification a separate explicit target.
- Modify: `.github/workflows/make-all.yml` to run Python unit tests in CI and make the final aggregate depend on them; do not run the real local host qualification in CI.
- Modify: `elixir/README.md` with safe local-only qualification instructions and explicit prohibitions on production credentials and live Plane access.
- Create: `elixir/test/support/a4/evidence_schema.json` or equivalent versioned field contract for secret-free evidence.
- Output only at runtime: `elixir/_build/h100-p0-host-relay-evidence.json` (ignored build output, not a tracked self-referential artifact).

**Tests/verification:**
- Test evidence schema/required fields and recursively reject secret-bearing keys, payload fields, authorization material, and unbounded values.
- Confirm evidence records source/spec base, implementation SHA/tree, file/commit inventory, relay/manifest hashes, identity/policy/port checks, TLS/version/trust, connection/record counts, canaries, Finch classification, cleanup, and exact test commands/results.
- Run targeted Python and Elixir tests, existing A4 transport proof tests, format, lint/static checks, Dialyzer, full `make -C elixir all`, and `make -C elixir isolation-proof` using safe clean environment boundaries.

**Commit:** `docs(h100): record local host relay qualification evidence`.

## Task 8: Independent review and handoff

**Files:**
- Fix only findings that preserve the accepted design; any schema, trust-boundary, or one-record contract change is a STOP condition.
- Final evidence remains outside tracked source or contains the exact final source hashes without changing them.

**Verification:**
- Re-run fresh targeted and complete canonical verification after all fixes.
- Request independent review with the exact base/head/spec/plan and the required security checklist. Resolve every Critical and Important finding with regression coverage and request a fresh review round.
- Push only if existing GitHub authentication permits it; open a stacked review PR against `docs/h100-p0-host-relay-design`; do not change authentication, merge, or perform live Plane work.
- Confirm no credential values, provider payloads, TLS plaintext, private keys, or broad environment values appear in code, logs, tests, evidence, or PR text.

**Commit:** `fix(h100): address independent review findings` (only if findings require a fix).
