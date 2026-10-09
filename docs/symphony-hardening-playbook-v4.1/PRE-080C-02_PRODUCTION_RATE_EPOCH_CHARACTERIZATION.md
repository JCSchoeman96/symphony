# PRE-080C-02 — Production-Rate Epoch Characterization

**Outcome: `LIMIT FOUND`**

This document records the production-rate behavior measured by the PRE-080C-02 candidate. It does not change the V4.1 status ledger or authorize H-080C.

## Candidate identity

| Field | Value |
|---|---|
| Accepted base commit SHA | `c1ecb653fbbb05e8872d67802c2a3d730c2e653e` |
| Accepted base Git tree | `41365f1580b8e728b5fe86581b404623082be8e8` |
| Implementation commit SHA | `35a402f7fcd9cf5de6e0c82db72814082e155e39` |
| Implementation commit Git tree | `b17dec16d4ebcf24eef89cdc0f4f0dbf321bffdd` |
| Source/test-only Git tree | `025d453c1e27af0d3058e48e2b58bf1e40496a68`; calculated without this evidence document |
| Pull request | `#37`; open candidate, not accepted |

The implementation commit identifies the scheduler-seam remediation. The source/test-only tree is a separately calculated tree identity and is not a commit or the PR head tree. The final PR head and synthetic merge identities belong in the PR description after the candidate is frozen; they are intentionally not embedded here.

Programme status: `PRE-080C-02 = AUTHORIZED / ACTIVE / NOT ACCEPTED`; `PRE-080C-03 = NOT STARTED`; `PRE-H080C = NOT REACHED`; `H-080C = NOT AUTHORIZED`.

## Measurement setup

The characterization runs the Orchestrator, Plane Adapter, DependencyReader, Client, and ReadScheduler. The fixture virtualizes provider transport and scheduler time only. It uses production settings: 60 request starts per 60,000 ms, four concurrent attempts, and a 64-request queue. Default production time delegates remain `System.monotonic_time/1`, `System.system_time/1`, and `Process.send_after/3`.

The provider replies immediately. Wall and CPU durations below describe the local test run; modeled duration is the pacing lower bound. Neither is an estimate of Plane network latency.

For a stable fixture with `N` relation reads, `Wopen` and `Wclose` work-item page reads, two project reads, and `Sopen` and `Sclose` state-page reads:

```text
L = N + Wopen + Wclose + 2 + Sopen + Sclose
A = L + retry_attempts
earliest_final_start_ms = floor((A - 1) / 60) * 60_000
```

The fixture uses 100 work items per page and one state page per snapshot, so `L = N + 2 * ceil(N / 100) + 4`. Pacing checks use actual scheduler attempt starts. Each stable run had zero retries, so attempts equal logical reads.

## Stable full-epoch results

| Items | Edges | Work-item pages | Relation reads | Project reads | State pages | Logical reads / attempts | Retries | Final start lower bound | Test wall / CPU | Dispatch unavailable |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 5,000 | 20 | 1,000 | 2 | 2 | 1,024 | 0 | 1,020,000 ms (17 min) | 682 / 3,807 ms | 1,020,000 ms |
| 5,000 | 25,000 | 100 | 5,000 | 2 | 2 | 5,104 | 0 | 5,100,000 ms (85 min) | 12,881 / 56,108 ms | 5,100,000 ms |
| 10,000 | 50,000 | 200 | 10,000 | 2 | 2 | 10,204 | 0 | 10,200,000 ms (170 min) | 51,172 / 195,644 ms | 10,200,000 ms |

Each run published one complete current graph after one SCC pass. Starts were grouped at 60,000 ms intervals, with four requests at the final boundary; no rolling 60,000 ms period exceeded 60 starts. Peak concurrency was four and queue high-water was four. Orchestrator mailbox high-water was zero; scheduler mailbox high-water was 8, 7, and 8. Process count after completion matched its baseline in all three runs. The 10k graph had 10,000 nodes and 50,000 edges, with no retries, queued work, in-flight reads, or task-supervisor children after publication.

Observed memory samples (not thresholds):

| Items | Acquisition task high-water | Orchestrator baseline / published / after GC | Scheduler baseline / published / after GC | Graph external size | BEAM total after GC |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 6,687,368 B | 34,624 / 9,577,640 / 4,119,712 B | 2,760 / 67,888 / 3,904 B | 1,400,459 B | 103,793,384 B |
| 5,000 | 20,702,336 B | 16,848 / 19,129,504 / 19,900,200 B | 2,760 / 145,280 / 3,904 B | 7,048,459 B | 164,918,200 B |
| 10,000 | 47,929,360 B | 16,848 / 41,052,296 / 34,386,840 B | 2,760 / 75,792 / 3,904 B | 14,108,459 B | 249,200,904 B |

These samples cover a fresh runtime baseline, acquisition task high-water, graph publication, and post-publication garbage collection. Intermediate normalization and graph-build phases are not sampled individually.

## Other scenarios

- **Refresh fence:** A routable, previously validated work item remained available during refresh, while no runner started and the prior graph conferred no dispatch authority. Once the fresh complete graph published, the lifecycle assessment remained valid and the runner started. The fixture also confirmed a dispatch candidate could not start on a restarted runtime with an unavailable epoch; it started after the fresh acquisition published.
- **Shared scheduler:** With 60 starts consumed and one bulk relation read queued, a control project read started first at 60,000 ms, then the bulk read. Both completed at that logical timestamp because provider service time is zero. Control priority does not bypass global pacing. The wait was below the existing 240-second relation timeout.
- **Webhook identity:** One repeated delivery and one duplicate event identity produced one targeted read. The 1,000-same-item burst coalesced 1,000 indications. A 1,000-distinct-item burst reached the existing 64-entry pending queue, with two targeted tasks and one full epoch in flight. Overflow dirtied the active epoch and a covering acquisition published a current graph. The run recorded 3,138 provider attempts, including 66 targeted starts, and three full epochs total. Scheduler, targeted work, queues, and task-supervisor children drained to zero.
- **Signalled edits:** Four full epochs ran serially: two published and two were superseded. Three edit indications arrived during acquisition; only one full acquisition ran at a time. The follow-up graph contained the changed `item-5 → item-999` edge and 5,001 edges total. The run recorded 4,096 provider starts and 4,080,000 ms modeled time from initial acquisition, including 3,060,000 ms from the first edit to current publication.
- **Provider mutation:** Changing the item set between opening and closing enumeration returned `{:error, :node_set_changed}` after three attempts and published no graph.
- **Restart:** Stopping after the first 60 starts discarded partial work. The restarted runtime began with empty scheduler history and an unavailable graph; a seeded candidate remained undispatchable. It completed a fresh 1,024-attempt epoch, published a current graph, and started the candidate's runner. The provider log contained 1,084 starts, including the abandoned 60.

## H-070 scale comparison

The accepted H-070A characterization tests DependencyReader directly and sets a 1 ms start window to keep CI bounded. It excludes the Orchestrator's two project reads and two state-list pages. This candidate's fixture adds those four reads to the stable totals.

The final H-070A run passed with one test and no failures. It recorded 1,020 calls at 1k in 1,561 ms, 5,100 calls at 5k in 39,804 ms, and 10,200 calls at 10k in 165,302 ms, with peak concurrency of 2, 3, and 3. These are accelerated scale measurements, not the production pacing durations above.

## Outcome and supported envelope

**`LIMIT FOUND`** — a complete graph is structurally obtainable at the current 10,000-item ceiling, but the configured global rate limit alone leaves dispatch unavailable for at least 170 minutes at that size. The corresponding lower bounds are 17 minutes at 1k and 85 minutes at 5k. Real provider latency, retries, throttling, shared scheduler use, and CPU work can extend them.

The characterized structural envelope remains the existing 10,000-item ceiling, four concurrent attempts, 64 queued reads, and 60 starts per 60 seconds. A dirty event requires a quiet complete acquisition before a current graph is available again. This evidence does not authorize changing those limits or implementing a throughput optimization.

## Verification

- Production-rate characterization: 13 tests, 0 failures.
- Scheduler and scheduler-aware Plane client regression: 47 tests, 0 failures.
- H-070A scale test: 1 test, 0 failures.
- Relevant dependency, epoch, webhook, and project-contract tests: 142 tests, 3 failures. All three were AgentRunner runtime-start tests that timed out waiting for the runner-start message; preflight reproduced these failures against baseline.
- `mix specs.check`, `mix format --check-formatted`, `mix credo --strict`, and `mix dialyzer`: passed.
- `make -C elixir all`: stopped in coverage partition 3 after 346 tests, with 5 failures and 2 skips. The failures were four pinned-Codex identity/runtime tests and one AppServer routed-launch test; all reported unsupported `codex-cli 0.162.0` where the isolation fixtures require `0.159.3`. Remaining coverage partitions, the full H-070A make target, coverage report, Dialyzer make target, and isolation-proof target did not run in that invocation. H-070A, specs, formatting, Credo, and Dialyzer passed independently as listed above.
- This evidence describes PR #37 as an open, unaccepted candidate. The required GitHub checks for its final remediation candidate must complete before review; no merge or programme acceptance is claimed. H-080C remains unauthorized.
