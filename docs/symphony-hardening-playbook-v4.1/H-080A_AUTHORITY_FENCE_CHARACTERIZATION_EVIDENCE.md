# H-080A AuthorityFence characterization evidence

This is a partial H-080A-FENCE-01 characterization record for accepted base `7ba76fccaacc5789443c685ed6f1d2bee7f04f9c`. It does not establish H-080A completion.

The test tranche adds `elixir/test/symphony_elixir/h080a_authority_fence_characterization_test.exs`. It does not change production code.

## Characterized fence cuts

The first six tests cover these paths:

- A persisted ARMED reservation with no bound runtime can be retired after restart.
- The runtime child observes a synced BOUND record before its first instruction. Killing the child and reopening the ledger leaves BOUND in flight and blocked.
- A BOUND write failure leaves ARMED, which restart can retire. A BOUND sync error leaves BOUND in flight, which restart keeps blocked.
- A task supervisor rejection occurs after BOUND. The child does not run, and the known start failure releases the exact runtime fence.
- Suspension pending write and sync errors, and RecoveryLedger context write and sync errors, preserve the RuntimeAttempt and suspension ID. Restart retains the fence and reconstructs or retains the open suspension context.
- A terminal recovery checkpoint is synced and reopened before release. RELEASED write and sync errors, and in-flight clear write and sync errors, leave the durable state at the corresponding boundary. Restart retries the authorized next step.

Each injected sync error first calls `:dets.sync/1`, then returns an error. This models an ambiguous acknowledgment where the row may be present after restart. Write errors return before inserting the row. Closing and reopening DETS checks persisted-record recovery. It does not simulate device loss or a hard power failure.

## Stop finding: mismatched DOWN releases a live runtime

The teardown probe in the new test file fails its required assertion. It starts and holds the child at its first instruction, then sends a `:DOWN` tuple with the child's actual monitor reference but the test process as the PID. The child is still alive when the event is handled. The ledger nevertheless changes from `BOUND` with `in_flight: true` to `RELEASED` with `in_flight: false`.

The probe first sends a tuple with an unrelated monitor reference. That event leaves the state unchanged. The reproducer therefore uses the exact current monitor reference and a mismatched process PID.

The production path is `Orchestrator.handle_info/2` → `handle_running_task_down/3` → `release_runtime_fence_after_task_down/3` → `AttemptLedger.release_authority_fence/3` → in-flight clearing. The `:DOWN` handler matches the monitor reference but ignores the message PID. The release path then trusts the RuntimeAttempt identity from the running entry without confirming that the monitored child exited.

The reproduction test is `test "a mismatched DOWN process cannot release the live runtime fence"` in `elixir/test/symphony_elixir/h080a_authority_fence_characterization_test.exs`. Its current failing assertion expects the fence to remain BOUND while the child is alive. The observed record is RELEASED and not in flight.

This is a STOP condition from the supplied task. Do not treat the passing fence-cut tests as phase evidence or patch production as part of this characterization tranche. The smallest reproduced violation is premature release of the exact current runtime fence while its child remains alive. Master direction is required before H-080A-FENCE-01 proceeds.

## Test record

Before adding the teardown reproducer, the characterization file ran 6 tests with 0 failures. The related attempt ledger, restart gap, runtime production path, and runtime teardown tests ran 74 tests with 0 failures. The combined run reported an existing unused-default-argument warning in `runtime_attempt_production_path_test.exs`.

After adding the teardown reproducer, `mix test test/symphony_elixir/h080a_authority_fence_characterization_test.exs` ran 7 tests and failed the mismatched-DOWN assertion described above. This failing result is the evidence for the stop finding.

## Scope limits

The remaining H-080A attack matrix is uncharacterized. This tranche does not cover provider and lifecycle authority, completion proof, dependency and project scope, H-040 mutation ambiguity, retry lineage, runtime roles, candidate and merge verification, webhook attacks, mixed legacy records, or workspace ownership. H-080B isolation, H-080C rerun, H-090 refactoring, H-100 live Plane webhook capture, H-110 soak, and production hardening remain outside this tranche.
