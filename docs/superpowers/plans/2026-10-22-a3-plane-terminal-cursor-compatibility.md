# A3 Plane terminal cursor compatibility implementation plan

> For agentic workers: use the executing-plans skill for a separately authorized implementation. This session is planning only. Do not implement, commit, push, or open a PR.

Goal: Accept a complete Plane snapshot when its terminal page retains a provider cursor.

Architecture: Change only the terminal branch of `page_next/1`. Keep the existing shared work-item/state decoder, pagination accumulator, and count reconciliation.

Tech stack: Elixir, ExUnit, existing Plane REST v1 client and injected request functions.

## Verified base and scope

On 2026-10-22, `git rev-parse HEAD HEAD^{tree}` returned:

```text
HEAD=ecbdc36fa816f8b24c1901e311c0f521a6c98a90
TREE=d8de3f2c9b9f99769449cb37ef5366f6ea988679
```

`git ls-remote origin refs/heads/main` returned:

```text
ecbdc36fa816f8b24c1901e311c0f521a6c98a90 refs/heads/main
```

The verification command exited 0. The initial working tree was clean. The untrusted `.worktrees/a3-plane-terminal-cursor-compatibility` draft was not inspected, copied, or used. Historical draft test numbers below are supplied context, not independently verified evidence.

A2 is the historical accepted candidate. A3 is a new remediation candidate and has no implementation or acceptance evidence yet.

Only these implementation files are proposed:

- `elixir/lib/symphony_elixir/plane/client.ex`, terminal pagination semantics.
- `elixir/test/symphony_elixir/plane_client_test.exs`, regression test and existing state fixture correction.

This planning session creates only `docs/superpowers/plans/2026-10-22-a3-plane-terminal-cursor-compatibility.md`.

## Root cause and semantics

ROOT_CAUSE=TERMINAL_NONEMPTY_CURSOR.

Supplied runtime evidence shows page 1 with 100 results, count=100, total_results=109, next_page_results=true, and a non-empty cursor. Page 2 has 9 results, accumulated=109, total_results=109, next_page_results=false, and a non-empty cursor. Frozen A2 returned `{:error, :snapshot_incomplete}`. Permission denial was NO. Plane runtime project scope was PASS.

The current `page_next/1` rejects a false continuation flag unless the cursor is nil or empty. The terminal `advance_pagination/6` branch already ignores the cursor and reconciles the total with the accumulated count.

Required semantics:

- `next_page_results=true` requires a valid non-empty binary cursor and continues through existing cursor safety checks.
- `next_page_results=false` means terminal. Ignore `next_cursor` for continuation and completeness, regardless of its retained value.
- A terminal flag does not prove completeness by itself. Stable totals and terminal accumulated count equality remain mandatory.

## Task 1: Establish RED before changing production code

- [ ] Recheck HEAD, tree, and live origin/main against the verified base. Stop if origin moved and record expected and observed SHAs. Keep clean A2 available in a separate authorized checkout for the differential gate.
- [ ] Add this regression to `elixir/test/symphony_elixir/plane_client_test.exs`, beside the existing pagination test. Keep the existing nil-cursor coverage.

```elixir
  test "accepts a complete work-item snapshot with a terminal provider cursor" do
    parent = self()
    page1_item = %{"id" => "one"}
    page2_item = %{"id" => "two"}

    request_fun = fn request ->
      send(parent, {:terminal_cursor_request, request.params["cursor"]})

      body =
        case request.params["cursor"] do
          nil ->
            %{
              "results" => [page1_item],
              "count" => 1,
              "total_results" => 2,
              "next_page_results" => true,
              "next_cursor" => "c1"
            }

          "c1" ->
            %{
              "results" => [page2_item],
              "count" => 1,
              "total_results" => 2,
              "next_page_results" => false,
              "next_cursor" => "provider-terminal-cursor"
            }
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [^page1_item, ^page2_item]} =
             Client.list_work_items(@config, request_fun: request_fun)

    assert_received {:terminal_cursor_request, nil}
    assert_received {:terminal_cursor_request, "c1"}
  end
```

- [ ] From `elixir`, run `mix test test/symphony_elixir/plane_client_test.exs --seed 0`. Record the new test's exact identity and assertion output. Expected RED is an assertion failure because the actual result is `{:error, :snapshot_incomplete}` instead of `{:ok, [page1_item, page2_item]}`. A compile error, transport error, or unrelated failure does not establish RED.

## Task 2: Make the smallest production change and establish GREEN

- [ ] In `page_next/1`, retain the boolean and true-flag branches. Replace the final nil/empty-cursor condition and error fallback with the terminal success fallback. The complete proposed function is:

```elixir
  defp page_next(body) do
    next? = raw_value(body, :next_page_results)
    next_cursor = raw_value(body, :next_cursor)

    cond do
      not is_boolean(next?) ->
        {:error, :snapshot_incomplete}

      next? and valid_cursor?(next_cursor) ->
        {:ok, true}

      next? ->
        {:error, :snapshot_incomplete}

      true ->
        {:ok, false}
    end
  end
```

- [ ] Run the same client command. The new regression must return both items in order and confirm the second request uses cursor `"c1"`. The existing state fixture still expects rejection without count metadata, so it remains rejected at this stage.

## Task 3: Correct the existing list_states fixture in place

The current `next_page_results=false`, `next_cursor="stale"` fixture lacks both `count` and `total_results`. Its existing failure does not isolate cursor handling. Even after terminal cursor acceptance, missing completeness metadata independently causes `:snapshot_incomplete`. The obsolete assumption is that a terminal cursor alone makes an otherwise complete page invalid.

- [ ] Replace only that assertion and fixture with:

```elixir
    assert {:ok, []} =
             Client.list_states(@config,
               request_fun: fn _request ->
                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "results" => [],
                      "count" => 0,
                      "total_results" => 0,
                      "next_page_results" => false,
                      "next_cursor" => "stale"
                    }
                  }}
               end
             )
```

- [ ] Preserve the surrounding state pagination, malformed-page, and 65-state rejection assertions. Retain the dedicated missing-completeness-metadata tests.
- [ ] Run the client suite again and record GREEN evidence.

## Preserved guards

Review the final diff and retained tests for all of these invariants:

- Boolean validation of `next_page_results`.
- Valid non-empty binary cursor required for every non-terminal page.
- Repeated continuation cursor rejection. An ignored terminal cursor is not a continuation.
- Required `count` and `total_results`, their non-negative integer validation, `count == length(results)`, and `total_results >= count`.
- Stable totals across pages, running accumulated count <= total, and terminal accumulated count == total.
- Page bound of 100, work-item bound of 10,000, and state bound of 64.
- Existing malformed-result validation, HTTP/transport mapping, scoped paths, and 4,000,000-byte response-size bound.

Do not alter `page_counts/2`, reconciliation helpers, accumulator rules, request scheduling, limits, or adapter code.

## Task 4: Bounded differential gate

Historical context is not an acceptance gate. A previous draft reportedly had 30 passing client tests. Its full suite reportedly had 1,934 tests, 2 failures, and 6 skips. One adjacent PlaneAdapterTest expected `:missing_plane_api_key` but received `:missing_plane_workspace_id`, also reproduced on clean A2. The other failure was a builder-response timeout in Pre080cProductionEvidenceAcquisitionTest, reported passing in isolation on A2 and draft A3. No equivalent clean-A2 full-suite comparator exists.

- [ ] Run clean A2 and A3 sequentially in the same environment. Verify A2 SHA/tree and record A3 base plus complete diff identity. Use the same dependency lock, runtime, seed, concurrency settings, test configuration, and machine resources. Do not run competing suites concurrently.
- [ ] Record `elixir --version`, `mix --version`, `uname -a`, runtime executable paths, OTP/Elixir versions, relevant non-secret MIX_ENV/ERL_FLAGS and scheduler settings, dependency/cache setup, and checkout identity. Repository guidance specifies Elixir 1.19.x and OTP 28. Do not expose credentials in evidence.
- [ ] From each checkout's `elixir` directory run these commands with the same environment:

```bash
mix test test/symphony_elixir/plane_client_test.exs --seed 0
mix test test/symphony_elixir/plane_*test.exs test/symphony_elixir/orchestrator_plane_*test.exs --seed 0
mix format --check-formatted
mix specs.check
mix test --seed 0
```

The adjacent command covers Plane adapter, configuration, project contract, dependency reader, scheduler, request policy, state projection, work control, agent tool, webhook, and epoch suites. Preserve repository-required `make all` checks before any later integration handoff; record their outcomes and investigate discrepancies within authorized scope.

- [ ] From each checkout's root run:

```bash
git diff --check
git diff --exit-code ecbdc36fa816f8b24c1901e311c0f521a6c98a90 -- elixir/mix.lock
git status --short
```

Require unchanged `mix.lock`, passing format and whitespace checks, and no unexplained source/test files outside the two-file scope. No dependency change is required.

- [ ] For every run, record candidate, exact command, working directory, environment/runtime, exit code, test count, failure count and full failure identities, skip count, and captured output location. Use not applicable for non-test command counts. Compare failure assertions as well as names. Account for the one new client test when comparing counts; do not treat historical totals as required fresh totals.
- [ ] Classify the adapter mismatch as `PRE_EXISTING_BASELINE_FAILURE` only after the same-environment A2 comparator confirms the same failure. Do not repair adapter validation precedence under A3 authority.
- [ ] A3 proceeds only if the differential shows no new deterministic failures attributable to A3. An incomplete comparator or unexplained failure leaves the gate unresolved. A deterministic broader-suite failure caused by A3 blocks the candidate.

## Builder timeout classification and retry bound

The relevant existing test is `real Planner to Ready result feeds real Builder dispatch and fresh Coordinator authority` in `elixir/test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs`, beginning at line 548 on this base. Its builder-response assertion is at line 897. Verify the failure identity against actual logs before applying this policy.

If the timeout appears on A3 but not the first equivalent A2 full-suite comparator:

1. Run the named test once isolated on clean A2 and once isolated on A3, using the same environment and `mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs:548 --seed 0` from `elixir`.
2. Permit at most one additional A3 full-suite run with `mix test --seed 0`, using the original environment and settings.
3. If the timeout recurs on A3 while absent from equivalent A2 evidence, set `STOP=A3_POSSIBLE_FULL_SUITE_REGRESSION`. An A3-only isolated recurrence is also adverse evidence and must not be dismissed by a later passing suite.
4. If it does not recur, both isolated runs pass, and no new deterministic failure remains, record a transient suite-level failure with all original failure evidence retained.

Maximum under this branch is one initial full suite per candidate, one isolated named test per candidate, and one extra A3 full suite. No unlimited retries, timeout increases, seed changes, or implementation changes to hide the failure. If both candidates exhibit the timeout, retain comparative evidence without claiming that this proves A3 acceptance. If classification remains uncertain, stop for review.

## Performance and scaling review

There are no new provider requests. A terminal false flag still stops immediately, and a true flag still requests the next page through the existing code. There are no page-size or limit changes, no new DB calls, no added GenServer blocking, no new polling, no task/mailbox growth, and no bounded snapshot memory increase. The request-count assertion belongs only to the injected test transport. Production work remains bounded by the existing page, item, state, and response-size limits. The change replaces a terminal predicate and does not alter accumulation complexity or cursor history storage.

## STOP conditions and authority

Stop and report the exact reason if any of the following occurs:

- Live origin/main moves from the required base. Record expected and observed SHA and require a new base decision.
- The fix requires API v2, credential/role expansion, or provider mutation.
- It requires removing count reconciliation or weakening non-terminal cursor safety.
- Work expands beyond the supported scope, including adapter fixes, timeout fixes, dependencies, or unrelated refactors.
- The differential identifies a deterministic broader-suite failure caused by A3.
- The bounded timeout policy produces `A3_POSSIBLE_FULL_SUITE_REGRESSION`.

Recheck live origin/main at the later candidate handoff. Failed or unavailable verification blocks a claim that the gate passed.

Merge authority is HUMAN_ONLY. Planning, implementation checks, and green tests do not grant merge or programme acceptance. This session must stop after writing and verifying the plan, with no source/test changes, implementation runs, commit, push, or PR.

After human-controlled merge and A3 acceptance, requalify candidate-bound evidence against A3. Do not resume halfway through the old A2 P0-B chain. The later authority process must determine which P0 evidence H-I23 must replay. H100 remains unauthorized. No production execution or provider mutation is authorized by this plan.

## Planning verdict

PLAN_VERDICT=READY FOR IMPLEMENTATION

NEXT_FIRST_FAILURE=NONE
