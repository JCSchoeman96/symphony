# H-080A AuthorityFence lifecycle characterization

This is a partial H-080A characterization record for accepted base `7ba76fccaacc5789443c685ed6f1d2bee7f04f9c`. It does not complete H-080A. PR #26 changes this evidence file and the H-080A test file only; no production source changed.

## Classification: Outcome B — constructed-case overstatement corrected

The earlier test named `a mismatched DOWN process cannot release the live runtime fence` directly called `Orchestrator.handle_info/2` with a tuple built by the test. It used the running entry's monitor reference and the test process as the PID while the actual child stayed alive. The handler removed the entry and durably changed `BOUND, in_flight: true` to `RELEASED, in_flight: false`.

That observation demonstrated how the handler processes a constructed `:DOWN`-shaped tuple. It did not demonstrate that OTP generated a termination notification for a live child. The test now preserves and labels that observation, and a second test sends the constructed tuple to a live Orchestrator GenServer to characterize the production callback path.

OTP's monitor contract associates each monitor reference with the monitored process. When that process terminates, the monitoring process receives `{:DOWN, ref, :process, pid, reason}` for that process. The Orchestrator creates the monitor from the PID returned by `Task.Supervisor.start_child/2`, retains both values in the same running entry, and maps the reference back to that entry. Genuine monitor events captured from the live Orchestrator therefore establish that the exact monitored runtime child has terminated before teardown runs. See the [Erlang process monitor documentation](https://www.erlang.org/doc/system/ref_man_processes.html).

`handle_info/2` does not compare the event PID with the running entry PID or independently verify process liveness. It relies on the event being the VM-generated notification for the stored monitor. A test-sent tuple has the same structure but does not carry that OTP guarantee. The production source search found no application path that sends a `:DOWN` tuple; this characterization does not assess arbitrary BEAM message senders.

The clean-teardown invariant established for the production monitor lifecycle is:

```text
Task.Supervisor.start_child returns child PID
  -> AuthorityFence BOUND is already synced
  -> Orchestrator monitors that exact child PID and stores PID + ref + RuntimeAttempt
  -> OTP emits the matching DOWN only after that monitored child terminates
  -> Orchestrator matches ref to the current running entry
  -> AttemptLedger releases the entry's exact RuntimeAttempt identity and syncs RELEASED
  -> clear_in_flight syncs the RELEASED record, persists in_flight: false, and syncs again
```

The test captures the first three durable sync observations for a clean normal exit as:

```text
{RELEASED, true}  # RELEASED persisted and synced
{RELEASED, true}  # clear_in_flight's pre-clear sync
{RELEASED, false} # in_flight clear persisted and synced
```

The resulting fence is `RELEASED` and `in_flight` is false. Reopening the ledger returns the same record. Abnormal termination follows the same fence release and in-flight ordering before the existing retry path records the failure. An unresolved suspension skips ordinary release and retains `SUSPENSION_PENDING`, `in_flight: true`, and its open RecoveryLedger context.

## Production path and ordering

`spawn_prepared_issue_on_worker_host/7` first calls `bind_runtime_attempt_before_spawn/3`. `AttemptLedger.bind_runtime_attempt/3` validates the exact identity and persists and syncs the BOUND record before `do_spawn_prepared_issue_on_worker_host/7` calls `Task.Supervisor.start_child/2`. After start succeeds, `Process.monitor(pid)` creates a monitor and the running entry stores both `pid` and `ref`, alongside the `RuntimeAttempt` and its `Identity`.

The runtime `:DOWN` path is:

1. `Orchestrator.handle_info/2` routes a non-Plane monitor event to `handle_running_task_down/3`.
2. `find_issue_id_for_ref/2` selects the running entry by monitor reference. The handler ignores the event PID.
3. `pop_running_entry/2` removes the entry, then `record_session_completion_totals/2` updates volatile totals.
4. `release_runtime_fence_after_task_down/3` skips release if the entry has an unresolved lifecycle suspension. Otherwise it passes the entry's exact `RuntimeAttempt.Identity` to `AttemptLedger.release_authority_fence/3`.
5. The ledger checks work item, lineage generation, and full runtime identity against the BOUND fence. It persists and syncs RELEASED.
6. `clear_attempt_in_flight/2` requires the released fence, syncs before clearing, then persists and syncs `in_flight: false`.
7. `handle_agent_down/5` runs the normal continuation path for `:normal`; an abnormal reason records failure and queues the existing retry behavior.

The running entry is removed before the ledger operation. For a genuine monitor event, the exact monitored process has already terminated when OTP delivers the message. If release or clear fails, the issue is blocked and the corresponding durable boundary remains available for restart reconciliation.

## Identity model

| Value | Classification | Clean-teardown role |
|---|---|---|
| `work_item_id` | Durable key and local correlation | Selects the ledger record and current running entry. |
| `runtime_attempt_id` | Durable RuntimeAttempt identity field | Distinguishes one execution from every retry. |
| `lineage_generation` | Durable lineage identity | Binds the attempt to the current retry lineage. |
| `responsibility` | Durable identity field | Captures the routed responsibility bound to this attempt. |
| `runtime_profile` | Durable identity field | Captures the routed profile bound to this attempt. |
| `RuntimeAttempt` struct and state | Volatile runtime identity | Lives in the running entry; its `Identity` is separately stored in the BOUND fence. |
| Child PID | Volatile runtime identity | Returned by Task.Supervisor and retained in the entry; not persisted. |
| Monitor reference | Volatile monitor identity and terminal-event correlation | Created for the child PID and retained in the same entry; not persisted. |
| Running entry | Volatile correlation record | Joins work item, child PID, monitor reference, route, and RuntimeAttempt. |
| Genuine `:DOWN` PID and reason | Terminal-event correlation and outcome | OTP supplies the monitored PID and exit reason; PID is not part of the durable RuntimeAttempt identity. |

The `RuntimeAttempt.Identity` contains `runtime_attempt_id`, `work_item_id`, `lineage_generation`, `responsibility`, and `runtime_profile`. That identity is stored in the AuthorityFence. The child PID, monitor reference, and running entry remain process-local and disappear on restart.

## D01–D12 lifecycle matrix

D02, D03, D08, and D10 run through a live `Orchestrator` GenServer and its Task.Supervisor child. Trace events show the exact `:DOWN` tuple received by that GenServer. D09 stops the original Orchestrator, then uses a test-owned monitor to observe the old child terminate; stale tuples sent to the fresh Orchestrator are constructed messages, and the old Orchestrator's monitor event is not delivered to it. Constructed cases are marked as test-sent messages; they are not classified as OTP monitor events.

| ID | Provenance and action | Result |
|---|---|---|
| D01 | Constructed event with unrelated ref and unrelated PID while current child is alive | Running entry, BOUND fence, and in-flight flag remain unchanged. |
| D02 | Genuine `:normal` monitor event for the exact current child | Entry is removed after child death; normal continuation follows. Fence becomes RELEASED and in-flight clears. |
| D03 | Genuine abnormal monitor event for the exact current child | Entry is removed after child death; RELEASED and in-flight clear precede the existing retry record. |
| D04 | Constructed event with current ref and a different PID while child is alive | Live GenServer accepts the tuple; entry is removed and fence releases. The test labels the message constructed, not VM-generated. |
| D05 | Constructed event with current child PID and unrelated ref | No teardown; the current entry and fence remain unchanged. |
| D06 | Constructed replay of a previous attempt's ref/PID after a newer RuntimeAttempt is current | New entry, identity, BOUND fence, in-flight flag, and live child remain unchanged. |
| D07 | Two constructed duplicate events after the previous exact attempt has already been torn down | Durable record and retry state remain unchanged; no second authority transition occurs. |
| D08 | Genuine child termination while the current entry has an unresolved suspension | Entry is removed, but `SUSPENSION_PENDING`, in-flight true, and the open RecoveryLedger context remain. Reopening both ledgers preserves them. |
| D09 | After restart, constructed stale tuples are sent to the fresh Orchestrator; a test-owned monitor observes the old child terminate | The old Orchestrator's genuine event is not delivered to the fresh process. The fresh running map stays empty and the reopened BOUND fence remains unchanged. |
| D10 | Genuine clean exit with exact current identity | Sync snapshots prove RELEASED is durable before `in_flight: false`; reopening preserves both values. |
| D11 | Unknown ref with a PID matching the current child | No teardown; PID equality cannot substitute for the monitor reference. |
| D12 | Constructed mismatched-PID event processed while exact child remains alive | Captures the durable transition to RELEASED/in-flight false and continued child liveness, with constructed provenance recorded. |

For D02, D03, D08, and D10, the precondition includes the current work item, full `RuntimeAttempt.Identity`, child PID, monitor reference, BOUND fence, and `in_flight: true`. The monitor trace includes the same reference and PID after the child has exited. Postconditions assert the running entry, durable fence, in-flight state, child liveness, and—where relevant—reopened ledger state. D09 separately asserts the fresh Orchestrator has no old running entry and that the old child's termination leaves the reopened fence unchanged. D04 and D12 assert the same identity and durable states but record the test-sent event and live child explicitly.

## Harness cleanup and Plane startup failure

The initial PR CI run had a second failure in `OrchestratorPlaneEpochTest`, “startup cleans up a thousand terminal Plane nodes without blocking on item GETs.” It passed when run alone on PR HEAD and on the accepted base, but failed after the original H-080A module in the ordered one-worker run.

The H-080A fixtures had two cleanup gaps: supervisor shutdown was asynchronous (`Process.exit/2` without waiting), and DETS handles reopened during restart cuts were not all tracked. The ledger fixture registry tracks its temporary roots, Task.Supervisors, runtime children, and opened AttemptLedger and RecoveryLedger tables. Cleanup waits for supervisor termination, checks child liveness, closes remaining tracked tables, verifies those tables are closed, and removes the temporary roots. The live-lifecycle fixture separately tracks Orchestrator PIDs, Task.Supervisor PIDs, and runtime child PIDs; its cleanup removes receive tracing, stops those processes, checks registered names and child liveness, and restores the application capture configuration. Test-owned monitor references are demonitor'ed or consumed by their matching `:DOWN` assertion.

After that cleanup change, the ordered command containing the H-080A file followed by the 1,000-item Plane test passed in four observed runs: the initial post-cleanup run and three repetitions, each with 15 tests and 0 failures. The full PR candidate suite also passed with this cleanup in place. The Plane test passed alone on the accepted base and PR HEAD. This evidence supports classifying the earlier readiness failure as H-080A test-harness contamination; timing sensitivity cannot be excluded from these finite runs. The cleanup is within this test file. The Plane test and production source remain unchanged.

## Verification record

Initial authorized pins were verified before edits: accepted main `7ba76fccaacc5789443c685ed6f1d2bee7f04f9c`, tree `ccce54196e30a8c0928feee5639a7e8662f4fa7d`; PR #26 base and head `c2cc3c29f12237ceb962c415ed4bc8d22ab010e4`; head tree `7c7806433c29fd435f1533676c6a9d0e9ba78db2`; and exactly the test and evidence files listed above. The roadmap and H-010/H-020/H-030 blob IDs matched the authorization.

At the accepted base, the comparable full suite completed with 1,476 tests, 0 failures, and 6 skips (`--seed 202938 --max-cases 8`). The isolated 1,000-item Plane test passed on accepted base (424 ms) and PR HEAD (503 ms). Before cleanup, the ordered H-080A plus Plane run failed both the old mismatched assertion and Plane readiness. After cleanup and lifecycle characterization, the same ordered run completed with 15 tests, 0 failures.

The local full-suite verification completed on commit `6aa1bd5eb83bfdc9abe9172d676e57b71ce84bc1` (tree `338233eb674f97c009014206734fb8f36a99db3d`), before the evidence-only precision edits in this follow-up:

- `mix format --check-formatted` passed.
- The H-080A file passed: 14 tests, 0 failures.
- AttemptLedger, RuntimeAttempt teardown/identity/production path, startup reconciliation, REM-HI21 restart, RecoveryLedger, and Orchestrator attempt-lineage suites passed: 167 tests, 0 failures.
- The isolated 1,000-item Plane startup test passed: 1 test, 0 failures. The ordered H-080A-plus-Plane run passed: 15 tests, 0 failures.
- `make -C elixir all` passed: 1,490 tests, 0 failures, 6 skips, and 90.01% total coverage. Build, format, Credo, and Dialyzer passed; Dialyzer reported 0 errors and 0 skips.
- The H-080A-plus-Plane ordered run passed three additional consecutive repetitions: each 15 tests, 0 failures.

The focused runtime command emits the existing unused optional argument warning in `runtime_attempt_production_path_test.exs`; it did not fail the command. The updated PR description is validated separately with `mix pr_body.check`. Final commit SHA/tree and GitHub check results are included in the completion report.

## Scope limits

This tranche covers only runtime termination identity, AuthorityFence ordering, suspension interaction, restart behavior, and the associated test harness. It does not complete H-080A and does not start CompletionProof provenance or any other H-080A topic. No production source changed. PR #26 remains unmerged.
