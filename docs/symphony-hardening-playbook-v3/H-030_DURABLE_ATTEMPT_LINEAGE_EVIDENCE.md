# H-030 durable attempt lineage evidence

This document records H-030 durable attempt-lineage evidence only. It covers
the reconstruction onto accepted H-020 `main` and the focused V3 corruption
fix found during review. It is evidence for the H-030 candidate, not a plan
for another hardening phase.

## Authority and provenance

- Accepted H-020 base SHA: `8891ee624a39b99d384ec078eb73558ab4730a04`
- Accepted H-020 tree: `2badda0628c0ec2386e08cc8b8a6e0a4566f93da`
- Frozen old PR: `#6`
- Frozen old PR head: `275831d4b51d02fd7593ef991e981996ee18423b`
- Old stacked H-020 base: `4a5238e6ba066d2c2b03408ca8bbc2b506e7931e`
- Reconstructed branch: `hardening/h-030-durable-attempt-lineage-reconstructed`

The three previously published H-030 commits were transplanted in order:

| Old provisional commit | Reconstructed commit |
| --- | --- |
| `e0e61d9eba1967b4aa781bca4edfc9be74582509` | `1a1a828296f8e447c7ce2f9781fe41cd59fed4ce` |
| `f63118b0fbf01fa5c577b2c4864271318972edc4` | `bb3c563f269ccce98963cbfb9772667b858021b2` |
| `275831d4b51d02fd7593ef991e981996ee18423b` | `1534ed5c32b476175bc565f70f90d9120a8bcc78` |

The exact `git range-diff` result for those three commits is:

```text
1:  e0e61d9 = 1:  1a1a828 feat(runtime): persist routed attempt lineage
2:  f63118b = 2:  bb3c563 fix(runtime): isolate DETS ledgers by path
3:  275831d = 3:  1534ed5 fix(runtime): harden durable attempt close recovery
```

The old and reconstructed three-commit deltas also have the same 16-file
name-status set and the same statistics: 4,289 insertions and 95 deletions.
This is the original reconstruction equivalence result. The final candidate
is intentionally not byte-equivalent to old PR #6 because it is:

```text
old provisional H-030 delta
+
new V3 corruption fix
=
new reconstructed H-030 candidate
```

The H-030F focused corruption-validation fix is commit
`2c7e0a3fd396c71e6fb460bc05d6230007e9203a`.

The H-030G focused durable-resync recovery fix is commit
`eae1c7a33ba7f432497b47a57573c32773b97c12`.

## H-030 responsibility

H-030 persists only safety-relevant attempt-lineage state needed to preserve
autonomous authority across process or application restart. It does not make
the ledger a scheduler or a source of current tracker truth.

The durable state includes ordinary failure/retry counters, review-cycle
counters, exhaustion, lineage identity, route fingerprint, in-flight state,
and the close/close-pending state needed for safe terminal recovery. It does
not include prompts, source, runtime transcript/messages, credentials,
runtime PIDs, timer references, or Codex sessions.

## Stable identity

Routed configuration uses an explicit `symphony.project_id`. The configured
identifier is validated as a stable, non-path identifier and is stored as the
ledger `project_namespace`. Checkout, workflow, and worktree paths do not
define the project namespace.

The default DETS location is outside the checkout and workspace:

```text
$XDG_STATE_HOME/symphony/attempt-ledger/<project_id>.dets
```

or, when `XDG_STATE_HOME` is unset:

```text
~/.local/state/symphony/attempt-ledger/<project_id>.dets
```

An explicit ledger path remains available for controlled administration and
tests. With the same configured `project_id` and durable root, moving a
checkout from `/home/.../symphony` to `/srv/.../symphony` does not reset the
safety lineage.

The metadata records the tracker identity as the tracker kind plus a
provider-specific scope (`project_slug`, `repo`, `project_key`, or
`project_gid`, as applicable). A project/provider identity mismatch fails
closed. Different project IDs use different ledger paths and namespaces and
do not collide.

## DETS schema and required safety fields

The schema version is `1`. Metadata contains exactly:

- `schema_version`
- `project_namespace`
- `tracker_identity`

Current active, exhausted, and closed lineage records use the base record
shape:

- `schema_version`
- `project_namespace`
- `issue_id`
- `lineage_id`
- `safety_counters`
- `status`
- `stop_reason`
- `route_fingerprint`
- `in_flight`
- `close_pending`
- `updated_at`

The safety counter map contains exactly `ordinary_failures`,
`ordinary_retries`, and `review_cycles`. Closed history records additionally
retain `closed_reason`, `rearm_reason`, `rearmed_by`, and `rearmed_at`.

Every active, exhausted, and closed lineage record must explicitly contain
both safety-critical keys:

```text
:in_flight
:close_pending
```

The V3 fix does not make every allowed record key mandatory. It adds a
focused `Map.fetch/2` check for these two safety fields, validates their
values as booleans, and maps either omission to `:invalid_record`. An
explicit `in_flight: false` and `close_pending: false` remains valid.

Before H-030F, `Map.get(record, key, false)` allowed an otherwise valid DETS
record missing either key to reopen as if the field were explicitly `false`.
After H-030F, reopening such a record returns the repository error shape:

```elixir
{:error, {:corrupt_attempt_record, {:current, issue_id}, :invalid_record}}
```

The same required-field validation is used for current and history lineage
record shapes.

## Durable ordering and failure behavior

Ledger writes use this order:

```text
AttemptPolicy decision
→ DETS write
→ :dets.sync/1 succeeds
→ in-memory state update and automatic follow-up authority
```

`persist_records/2` invokes the configured write function first and
`sync_fun` second. A write or sync failure is returned to the caller. The
Orchestrator applies the in-memory event only after `persist_safety/4` returns
success; it does not fall back to an in-memory autonomous retry when durable
accounting fails. The DETS file is opened as a set with autosave disabled for
implicit timing (`auto_save: :infinity`) and is chmod'ed to `0600`.

H-030G closes the recovery gap for a safety-relevant sync failure. A blocked
ledger whose reason is `{:attempt_ledger_unavailable, {:ledger_sync_failed,
reason}}` follows this exact lifecycle:

```text
Blocked
→ explicit AttemptLedger.sync/1
→ fresh durable-lineage reconciliation
→ Ready
→ only then reschedule or dispatch automatic work
```

If the explicit recovery sync fails, the ledger remains blocked and no retry
dispatch, worker spawn, counter reset, or follow-up authority is granted. The
existing poll cadence performs the next recovery attempt; no busy-loop or new
scheduler is introduced. A readable record in the still-open DETS table after
the original sync failure is not treated as durable authority. The successful
resync is required before the fresh lineage reread and tracker reconciliation.

## Restart and reconciliation

On routed startup, the Orchestrator opens and validates the DETS ledger before
allowing routed dispatch. It then loads active and exhausted lineages,
restores consumed counters, in-flight reservations, pending closes, and
exhaustion, fetches fresh tracker state, and recomputes current route,
dependency, and capacity decisions. It never restores a dead runtime session
or timer reference.

Corrupt records, a newer unsupported schema, provider/repository identity
mismatch, DETS open/read failure, or unavailable tracker state hold
autonomous dispatch closed. A malformed record therefore cannot be converted
into a safe-looking `false` value during startup recovery.

## Close-pending and exhaustion lifecycle

Terminal close is durable and ordered. The ledger first records a closed
lineage with `in_flight: false` and `close_pending: true`, syncs it, and only
then finalizes the record with `close_pending: false`. If confirmation or
finalization fails, the pending-close marker remains durable. On restart,
reconciliation confirms or retries the close before reopening autonomous work;
failure leaves the affected lineage fenced.

Ordinary retry/failure accounting and review-cycle accounting are persisted
before their follow-up decisions. Exhaustion survives restart and prevents a
new automatic attempt. Capacity waits, route changes, and continuations do
not consume the ordinary retry budget. Terminal and reset behavior remains on
the existing Orchestrator/AttemptLedger semantics.

The host-only `mix symphony.attempt_rearm` task requires project, issue,
reason, operator, and a non-negative timestamp. Rearm preserves the exhausted
lineage as closed history, creates a new lineage generation with fresh
counters, and opens only that new lineage. Rearm is not exposed through agent
dynamic tools, and manual DETS deletion is unsupported.

## Corruption and recovery evidence

The focused real-DETS regressions are in:

- `elixir/test/symphony_elixir/attempt_ledger_test.exs`
  - explicit `false` fields survive a raw DETS close/reopen;
  - a raw current record missing `in_flight` is rejected;
  - a raw current record missing `close_pending` is rejected;
  - existing schema, identity, reopen, close-pending, exhaustion, rearm, and
    write/sync failure coverage remains active.
- `elixir/test/symphony_elixir/orchestrator_attempt_lineage_test.exs`
  - each omitted safety field is removed from a disk-backed record after the
    ledger is closed;
  - the real Orchestrator startup path reopens the file and blocks with the
    corrupt-record error;
  - no worker dispatch occurs and `running`, `retry_attempts`, and
    `attempt_counters` remain empty.
  - a repeated recovery sync failure leaves the ledger blocked and does not
    dispatch a worker or create retry authority;
  - a successful recovery sync is observed after the original failed safety
    sync and before reconciliation restores `:ready`;
  - the safety record is closed and reopened through the real DETS ledger
    after recovery, with its counters and explicit safety fields intact;
  - an ordinarily exhausted lineage remains exhausted after the same
    close/reopen cycle and rejects a new attempt.

The H-030G Orchestrator delta is limited to the dedicated sync-failure
recovery gate in `elixir/lib/symphony_elixir/orchestrator.ex`; the focused
regressions and their helpers are in
`elixir/test/symphony_elixir/orchestrator_attempt_lineage_test.exs`. No
AttemptLedger schema or validation code changed for H-030G.

The focused command was:

```text
mix test test/symphony_elixir/attempt_ledger_test.exs \
  test/symphony_elixir/orchestrator_attempt_lineage_test.exs \
  test/symphony_elixir/attempt_policy_test.exs \
  test/mix/tasks/attempt_rearm_task_test.exs
```

Result: 67 tests, 0 failures.

The full coverage command completed with 538 tests, 0 failures, 6 skipped,
and 90.31% total coverage. The H-010 truthful 90% coverage threshold was
unchanged and remained green. `mix format --check-formatted`, `mix specs.check`,
strict Credo, Dialyzer, `make -C elixir all`, and `git diff --check` all passed;
Dialyzer reported 0 errors.

## Final changed-file inventory

The final candidate's accepted-H-020-base-to-head inventory is:

- `docs/symphony-hardening-playbook-v3/H-030_DURABLE_ATTEMPT_LINEAGE_EVIDENCE.md`
- `README.md`
- `elixir/README.md`
- `elixir/WORKFLOW.md`
- `elixir/lib/mix/tasks/symphony.attempt_rearm.ex`
- `elixir/lib/symphony_elixir/agent_runtime/attempt_ledger.ex`
- `elixir/lib/symphony_elixir/config.ex`
- `elixir/lib/symphony_elixir/config/schema.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex`
- `elixir/lib/symphony_elixir/tracker.ex`
- `elixir/test/mix/tasks/attempt_rearm_task_test.exs`
- `elixir/test/support/test_support.exs`
- `elixir/test/symphony_elixir/attempt_ledger_test.exs`
- `elixir/test/symphony_elixir/config_identity_test.exs`
- `elixir/test/symphony_elixir/core_test.exs`
- `elixir/test/symphony_elixir/orchestrator_attempt_lineage_test.exs`
- `elixir/test/symphony_elixir/tracker_capabilities_test.exs`

The mixed H-020/H-030 plan is not present. No H-020 capability semantics were
changed by H-030F, and H-040 was not started.
