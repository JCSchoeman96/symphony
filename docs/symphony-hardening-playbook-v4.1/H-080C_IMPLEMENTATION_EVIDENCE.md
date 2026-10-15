# H-080C integrated security reverification evidence

Evidence date: 2026-10-15

## 1. Candidate status

H080C_STATUS=LOCAL_VERIFICATION_COMPLETE / HOSTED_VERIFICATION_PENDING / NOT_ACCEPTED

LOCAL_CODEX_OWNERSHIP=USER_OWNED_ACCEPTED_FOR_LOCAL_BEHAVIORAL_PROOF

HOSTED_ROOT_OWNED_CODEX_PROOF=PENDING

MERGE_AUTHORITY=HUMAN_ONLY

PRODUCTION_SOURCE_CHANGED=NO

TEST_SOURCE_CHANGED=NO

The local proofs below ran against the accepted source tree. The evidence file is the only authorized candidate change. Hosted checks against the exact H-080C synthetic merge remain outstanding.

## 2. Accepted base and authority

Repository: JCSchoeman96/symphony

Decision reference: MG-2026-10-14-H080C-FRESH-PLANNING-RESET-01

Accepted base SHA: 5e3a7a0d2dd715e46ce8457dc3579eda39e85fa1

Accepted base tree: 2c8137428f267d84902def5cdcda98c781744723

The local worktree HEAD and merge-base with origin/main matched the accepted base. The worktree was clean before the evidence file was created.

GitHub reported main protected, at the accepted SHA and tree. The base commit verification was true. Branch protection required exactly make-all and validate-pr-description, both under app ID 15368. The base make-all check completed successfully under app 15368 for the accepted SHA.

Master Roadmap: docs/symphony-hardening-playbook-v4.1/V4_1_MASTER_ROADMAP.md, blob 4b0528bdc0647d889b42ebc478081d5b873898fe.

The Master Roadmap assigns H-080C to re-run integrated security proofs after authority, candidate-binding, and isolation work; produce one consolidated exact-head verdict for H-I12 through H-I24; make no source change without separate authorization from a finding; and stop on an unresolved critical or high authority bypass.

PR #41 and its governance materialization did not implement or accept H-080C.

## 3. Scope

This is a verification-only candidate. The test subject was the accepted source tree above. The only candidate path is:

    docs/symphony-hardening-playbook-v4.1/H-080C_IMPLEMENTATION_EVIDENCE.md

No production or test source changed. The Master Roadmap, governance projection, hardening status ledger, and unified roadmap were not changed.

The future evidence commit SHA is not stated here. The final signed candidate HEAD/tree and hosted synthetic-merge and check identities belong in the PR and execution handoff after commit.

## 4. Authority and lifecycle inventory

The current production modules were re-read at the accepted base before using the focused proofs. The inspection covered WorkflowLifecycle, AuthorityDisposition, LifecycleAssessment, CompletionProof, TransitionAttempt and its ledger/coordinator, AttemptLedger authority fence, RuntimeAttempt, Router, Profile, Authority, Plane.AgentTool, SourceControl and SourceControl.AgentTool, PromptBuilder, IsolationProfile, SuspensionContext, SuspensionRecovery, and Workspace.Ownership.

### WorkflowLifecycle

The canonical states are backlog, planning, ready, in_progress, in_review, changes_requested, ready_to_merge, merging, blocked, done, and canceled. Same-state and unlisted transitions fail.

The ordinary transitions and guards are:

| Transition | Owner | Responsibility | Required guards |
|---|---|---|---|
| Backlog to Planning | human | human | HumanDecision(:planning_started) |
| Planning to Ready | planner | planning | SemanticAttestation(:plan_attested), MechanicalGuard(:planning_requirements_verified) |
| Ready to In Progress | symphony | implementation | MechanicalGuard(:dispatch_guard) |
| In Progress to In Review | builder | implementation | SemanticAttestation(:implementation_attested), MechanicalGuard(:implementation_checks_verified), MechanicalGuard(:candidate_state_verified) |
| In Review to Changes Requested | independent_reviewer | review | SemanticAttestation(:review_changes_requested) |
| Changes Requested to In Review | fixer | correction | SemanticAttestation(:correction_attested), MechanicalGuard(:correction_checks_verified), MechanicalGuard(:candidate_state_verified) |
| In Review to Ready to Merge | independent_reviewer | review | MechanicalGuard(:review_acceptance_verified), SemanticAttestation(:review_accepted) |
| Ready to Merge to Merging | human | merge | HumanDecision(:merge_approved), MechanicalGuard(:merge_guard_verified) |
| Merging to Done | system | completion | MechanicalGuard(:completion_merge_verified) |

Every transition has autonomous_merge=false. Any nonterminal state may move to Canceled only with HumanDecision(:cancellation_authorized). Cancellation revokes automation and invalidates dependency effects. Done and Canceled are terminal; only Done is a successful terminal state.

The Merging to Done pre-transition guard remains distinct from final validation of a provider Done observation. The former uses completion_merge_verified. Final assessment requires a completed CompletionProof that satisfies completion_proof_verified and closes the exact fresh observation and contract.

### AuthorityDisposition

The states are none, eligible, active, suspended, and escalated. None may become eligible after lifecycle eligibility. Eligible may become active when an attempt starts. Invalid, validation-required, or authority-reducing assessments suspend eligible or active authority. Resume from suspended requires fresh reconciliation and a canonical resume target; reactivation also requires an attempt-started fact. A human decision can escalate a suspension. Canceled work cannot resume, and escalated has no outgoing transition. Ordinary provider observations do not recreate authority.

### AttemptLedger authority fence

New reservations persist an armed fence. The normal transitions are armed to bound, armed to released for a safe unused reservation, bound to suspension_pending for the exact RuntimeAttempt and suspension intent, bound to released for the exact bound identity, and suspension_pending to released after exact terminal SuspensionContext correlation. Released is terminal for that fence instance.

An unresolved fence keeps in_flight protected. Clearing in_flight requires a released fence and durable sync. Closing a lineage with an unresolved fence fails. A new fence_attempt reservation with no preserved fence defaults to armed. An existing legacy in-flight record with a nil fence maps to legacy_ambiguous and remains unresolved; it does not become armed on recovery. The existing attempt-ledger test covers the not-found fence_attempt case.

### RuntimeAttempt

The transitions are queued to starting; starting to running, stopping, retry_queued, blocked, failed, or cancelled; running to stopping, completed, retry_queued, blocked, failed, or cancelled; stopping to containment_unconfirmed or containment_proven_dead; and containment_proven_dead to running, completed, retry_queued, blocked, failed, or cancelled.

RuntimeAttempt.terminal?/1 includes completed, retry_queued, blocked, failed, and cancelled. containment_unconfirmed has no outgoing transition but is not terminal. This accepted distinction is preserved.

The host-owned identity binds runtime_attempt_id, work_item_id, lineage_generation, responsibility, and runtime_profile. Mismatched or stale identity fails closed.

### TransitionAttempt

The states progress through requested, intent_authorized, fresh_context_loaded, prepared, mutation_submitted, and verifying, then terminate as verified, rejected, conflict, provider_failed, or indeterminate. Terminal attempts reject further operations.

The coordinator loads fresh context, prepares and persists the attempt, then durably arms the submission_fenced_at write-ahead fence before provider mutation. prepared is the last state from which the coordinator may emit a mutation. submit_once advances mutation_submitted in memory and calls the provider; that state is not separately persisted before invocation. The durable pre-submit fence is the no-blind-resubmit boundary. A possible but ambiguous mutation is reconciled as conflict, provider_failed, or indeterminate and is not blindly resubmitted after restart. Provider acknowledgement remains provisional until fresh observation verifies the result.

### Workspace ownership

Ownership progresses through reserved, provisioning, owned, release_pending, and released. Provisioning may move to release_pending. release_pending may return to owned only through the existing proven recovery and identity path, or it may move to released. Released is terminal. Directory existence alone does not prove ownership. Missing or changed ledger identity blocks adoption.

### SuspensionContext and SuspensionRecovery

SuspensionContext progresses from open to resolving, then to resolved or escalated. Resolved and escalated are terminal. Resolution requires fresh reconciliation, a canonical trusted resume target, and all required evidence. Provider projection alone cannot resolve a suspension.

SuspensionRecovery is a policy evaluation, not an authority issuer. Unknown reasons fail closed. Its resubmit? result is always false, so it never replays an old transition. Provider Blocked, security, and durability conditions keep authority suspended under the accepted rules.

### CompletionProof and candidate/review chain

CompletionProof has distinct stages: merge_authorized, merge_verified, and completed. merge_authorized may satisfy merge_guard_verified only with valid exact candidate, review, and source-control bindings. merge_verified may satisfy completion_merge_verified after actual merge verification. completed may satisfy completion_proof_verified only after closure against the exact fresh provider observation and project contract.

The evidence chain is identity-bound:

1. Exact CandidateRef and candidate/check evidence.
2. Independent Reviewer semantic acceptance and host-validated signed review provenance bound to the candidate, work item, project/workspace, policy, runtime attempt, and lineage.
3. Separate HumanDecision(:merge_approved).
4. Current merge guard and merge_authorized proof.
5. Actual merge verification and merge_verified proof.
6. Fresh provider observation and exact contract/identity closure into completed proof.

Candidate HEAD, tree, policy, or check movement invalidates downstream candidate evidence. Reviewer approval, human merge approval, merge verification, and provider Done do not substitute for one another.

## 5. H-I12 through H-I24 focused proof matrix

Each focused command ran on the accepted source tree. Suites are grouped as in the V3 plan to avoid repeated startup. A matrix row names the command group and its production seam.

### Focused command groups

Suite A, provider, lifecycle, and transition checks. Result: exit 0, 235 tests, 0 failures, seed 893187.

    cd elixir && mix test test/symphony_elixir/pre_080c_production_evidence_acquisition_test.exs test/symphony_elixir/plane_agent_tool_test.exs test/symphony_elixir/transition_coordinator_test.exs test/symphony_elixir/transition_coordinator_default_path_test.exs test/symphony_elixir/transition_freshness_test.exs test/symphony_elixir/work_control_workflow_lifecycle_test.exs test/symphony_elixir/work_control_assessment_test.exs test/symphony_elixir/runtime_transition_authority_binding_test.exs test/symphony_elixir/tracker_read_attestation_test.exs test/symphony_elixir/provider_project_contract_test.exs test/symphony_elixir/plane_webhook_test.exs test/symphony_elixir/orchestrator_plane_webhook_test.exs

Suite B, responsibility, prompt/tool, credential, and runtime isolation checks. Result: exit 0, 195 tests, 0 failures, seed 818054.

    cd elixir && mix test test/symphony_elixir/agent_router_test.exs test/symphony_elixir/profile_runtime_test.exs test/symphony_elixir/role_prompt_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/runtime_authority_test.exs test/symphony_elixir/runtime_attempt_identity_test.exs test/symphony_elixir/source_control_agent_tool_test.exs test/symphony_elixir/credential_boundary_test.exs test/symphony_elixir/credential_channel_enforcement_test.exs test/symphony_elixir/orchestrator_runtime_isolation_test.exs test/symphony_elixir/runtime_isolation_test.exs

Suite C, candidate, review, merge, and completion checks. Result: exit 0, 113 tests, 0 failures, seed 592569.

    cd elixir && mix test test/symphony_elixir/source_control_test.exs test/symphony_elixir/source_control_candidate_ref_test.exs test/symphony_elixir/source_control_coverage_test.exs test/symphony_elixir/source_control_merge_verification_test.exs test/symphony_elixir/source_control_agent_tool_test.exs test/symphony_elixir/guard_class_source_control_test.exs test/symphony_elixir/work_control_assessment_test.exs test/symphony_elixir/work_control_workflow_lifecycle_test.exs test/symphony_elixir/rem_h080c_candidate_evidence_recovery_test.exs test/symphony_elixir/rem_h080c_ready_to_merge_review_provenance_test.exs

Suite D, restart, recovery, and ownership checks. Result: exit 0, 232 tests, 0 failures, seed 940674.

    cd elixir && mix test test/symphony_elixir/h080a_authority_fence_characterization_test.exs test/symphony_elixir/attempt_ledger_test.exs test/symphony_elixir/transition_attempt_ledger_test.exs test/symphony_elixir/orchestrator_startup_reconciliation_test.exs test/symphony_elixir/workspace_ownership_ledger_test.exs test/symphony_elixir/suspension_recovery_test.exs test/symphony_elixir/rem_hi21_restart_gap_test.exs test/symphony_elixir/runtime_attempt_identity_test.exs test/symphony_elixir/runtime_attempt_teardown_test.exs test/symphony_elixir/rem_h080c_candidate_evidence_recovery_test.exs test/symphony_elixir/rem_h080c_ready_to_merge_review_provenance_test.exs

Suite E, REM-H080C-03 dependency-scope checks. Result: exit 0, 129 tests, 0 failures, seed 662827.

    cd elixir && mix test test/symphony_elixir/rem_h080c_03_backlog_planning_dependency_route_coupling_test.exs test/symphony_elixir/dependency_graph_test.exs test/symphony_elixir/dependency_policy_test.exs test/symphony_elixir/dependency_completeness_test.exs test/symphony_elixir/agent_router_dependency_proof_test.exs test/symphony_elixir/transition_policy_test.exs test/symphony_elixir/orchestrator_plane_epoch_test.exs

The hostile-instruction static trace also ran from the repository root and exited 0:

    rg -n 'PromptBuilder|build_prompt|with_role_prompt|role_prompt' elixir/lib/symphony_elixir
    rg -n 'authorize_lifecycle_command|authorize_source_control_operation|agent_tool_context|runtime_attempt_identity' elixir/lib/symphony_elixir

| Invariant | Result | Evidence and fail-closed behavior |
|---|---|---|
| H-I12 | PASS, Suite A | Provider identity and project contract remain stable across display-name changes. Forged or stale read attestations do not restore authority. |
| H-I13 | PASS, Suite A | Mutation acknowledgements are provisional. TransitionCoordinator uses a fresh provider observation and assessment to decide truth; stale context fails closed. |
| H-I14 | PASS, Suites A and E | Human planning intent does not create a Planner RuntimeAttempt. Backlog to Planning uses transition-scoped dependency evidence; Ready to In Progress retains dispatch/runtime gating. |
| H-I15 | PASS, Suite A | Webhooks cause authoritative rereads. Event payloads alone do not grant forward authority. |
| H-I16 | PASS, Suites B and C | Work-control and source-control permissions remain separate. SourceControl.AgentTool is Reviewer-only and read-only. |
| H-I17 | PASS, Suites B and D, plus Task 7 isolation proof | Work item, project, workspace, repository, and credential scopes stay bound. The actual Codex isolation proof passed locally. |
| H-I18 | PASS, Suites A and B | The child runtime cannot supply provider transport details or host tool context. Plane semantic tooling and credential boundaries are host-controlled. |
| H-I19 | PASS, Suites A and D | Provider observations cannot manufacture forward authority or bypass the durable authority fence. |
| H-I20 | PASS, Suite C | Provider Done and dependency completion require exact completed CompletionProof and source-control closure. |
| H-I21 | PASS, Suite D | Suspension belongs to Symphony. Provider Blocked or stale projection does not release the fence or resume work. |
| H-I22 | PASS, Suite D | Ambiguous possible mutation becomes indeterminate or otherwise blocked for reconciliation. Startup does not blindly resubmit an old transition. |
| H-I23 | PASS, Suites C and D | Candidate movement invalidates candidate-bound checks and review provenance. Recovery preserves exact candidate and Reviewer identity. |
| H-I24 | PASS, Suites A and C | HumanDecision, SemanticAttestation, MechanicalGuard, review provenance, and CompletionProof remain distinct guard classes. |

## 6. Accepted remediation composition

REM-H080C-01, candidate-bound source-control evidence recovery, passed in Suites C and D. Recovery revalidates evidence against the exact CandidateRef and its bound project, workspace, contract, and policy. Candidate movement makes old evidence unusable.

PRE-H080C-CODEX-QUAL-01, exact codex-cli 0.162.1 qualification, passed locally for version identity and actual behavioral/isolation proof. The accepted prior qualification established root-owned path proof in its authorized GitHub Actions environment. This prior proof is not substituted for the required H-080C synthetic-merge proof.

REM-H080C-02, bounded signed Reviewer provenance recovery, passed in Suites C and D. Review provenance stays signed and bound to the Reviewer RuntimeAttempt, lineage, policy, project/workspace, and exact candidate. It remains distinct from mechanical review evidence and the human merge decision.

REM-H080C-03, Backlog to Planning dependency-scope composition, passed in Suites A and E. Backlog remains non-routable. HumanDecision(:planning_started) authorizes the human transition. A transition-scoped dependency context can support planning without a runtime route. The accepted policy can permit planning with an unresolved active hard dependency. Canceled or malformed blockers, cycles, unavailable or incomplete graphs, cross-project evidence, missing human decision, wrong identity, stale token or dependency epoch, and changed provider observation fail closed. Ready to In Progress continues to use normal implementation, dispatch, and dependency authority.

## 7. Responsibility separation

Backlog to Planning is human-owned and does not create Planner runtime authority. Planner is distinct from Builder. Builder and Fixer cannot self-review, approve, or merge. Reviewer uses a fresh, distinct RuntimeAttempt identity and has no write, push, or merge operation. The merge gatekeeper is deferred and non-executable.

Reviewer acceptance is not HumanDecision(:merge_approved). Human merge approval is not CompletionProof. Provider Done is not CompletionProof. The completion stages remain merge_authorized, merge_verified, and completed, each mapped to its own MechanicalGuard.

## 8. Instruction and prompt authority trace

Prompt text is procedure, not authority. PromptBuilder renders workflow task and role instruction text from the host Route and Profile. The inspected code path does not parse prompt or role text into Route, Profile, RuntimeAttempt, or Authority. The host derives and validates Route, Profile, Authority, RuntimeAttempt identity, and tool context before the model-facing turn.

Plane.AgentTool.execute/3 accepts only the requested target as child input. It obtains the current Route, WorkItem, RuntimeAttempt identity, and required semantic/mechanical evidence from trusted host context and production issuers. Runtime-supplied or forged semantic and mechanical lookalikes do not become trusted current evidence. The child cannot provide provider transport details to acquire mutation authority.

SourceControl.AgentTool.execute/3 exposes a no-argument Reviewer-only read of current candidate status. Builder and Fixer do not receive that tool. Runtime profiles and credential channels determine filesystem, network, git, and credential access; prompt text cannot change those settings.

The accepted role, tool, authority, credential, and isolation tests plus static data-flow trace establish this boundary. No additional hostile-instruction test was needed or added.

## 9. Restart and recovery proof

Suite D re-exercised the authority fence, RuntimeAttempt identity and lineage binding, write-ahead submission fence, TransitionAttempt persistence and restart reconciliation, workspace ownership and release, SuspensionContext and RecoveryLedger, provider Blocked behavior, correlated suspension, candidate-bound evidence recovery, signed review provenance recovery, and containment teardown.

Stale or incomplete durable evidence resolves to suspended, blocked, validation-required, conflict, or indeterminate outcomes. It does not silently regain forward authority. A possible prior mutation is reconciled rather than blindly resubmitted. Unresolved fence state prevents lineage closure or clearing in_flight. Directory existence does not reclaim a workspace. Provider projection does not resolve a Symphony suspension.

## 10. Exact Codex and full-gate result

Local runtime identity:

    codex --version
    codex-cli 0.162.1

    command -v codex
    /home/jcschoeman96/.local/bin/codex

    readlink -f /home/jcschoeman96/.local/bin/codex
    /home/jcschoeman96/.codex/packages/standalone/releases/0.162.1-x86_64-unknown-linux-musl/bin/codex

The resolved executable is a regular file owned by jcschoeman96:jcschoeman96, UID 1000, GID 1000, mode 755. User ownership is accepted for local behavioral/isolation proof. It is not trusted-path ownership proof.

The production pin and Makefile target were checked with:

    rg -n 'codex-cli 0\.162\.1|supported_codex_version|verify-codex|isolation-proof|^all:' elixir/Makefile elixir/lib/symphony_elixir/codex/isolation_profile.ex

The production pin is codex-cli 0.162.1. The canonical local gate was:

    make -C elixir all

Result: exit 0. It completed setup, build, format checks, Credo, eight ordinary coverage partitions, transition-fixture coverage, H-070A scale characterization, aggregate coverage, Dialyzer, exact Codex version verification, and actual-Codex/AppServer isolation proof.

The eight ordinary partitions reported 158, 261, 207, 237, 189, 150, 284, and 346 tests, all with zero failures. The output reported one excluded test in the first partition, one skipped test in each of partitions three through six, and two skipped in partition seven. Transition-fixture coverage reported 66 tests and zero failures. H-070A scale reported 10,000 items, 50,000 edges, 10,200 calls and attempts, peak concurrency 3, and 147176 ms. Aggregate coverage was 90.48%. Dialyzer reported zero errors, zero skipped, and zero unnecessary skips. The actual-Codex/AppServer suite reported 72 tests and zero failures.

The local gate printed the fixture's expected namespace-spawn failure message while testing cleanup after a namespace launch failure. The relevant AppServer test and actual-Codex suite completed with zero failures.

HOSTED_ROOT_OWNED_CODEX_PROOF=PENDING. Before readiness, the exact PR synthetic-merge linux-isolation-proof must establish all of the following from its log: install root /usr/local/lib/symphony-codex-0.162.1; Codex executable UID 0; root ownership of the executable and path components as reported by stat/namei; exact version codex-cli 0.162.1; SYMPHONY_ENFORCE_TEST_RUNTIME_PATH_TRUST=1; actual-Codex/AppServer isolation proof passing, including 72 tests and zero failures. The required make-all and validate-pr-description checks must also pass on that exact synthetic merge under app 15368.

## 11. Failure, retry, and warning disclosure

The following attempts and outputs are recorded so this evidence does not hide the earlier runs:

| Attempt | Result | Disposition |
|---|---|---|
| First Suite A invocation | The exact Suite A command listed in section 5 exited 1 before ExUnit because dependencies were absent; Mix reported unchecked dependencies and instructed running mix deps.get. | Repository-standard cd elixir && mix setup exited 0, reported locked dependencies unchanged, and the exact Suite A rerun passed with 235 tests and zero failures. |
| Static prompt scan launched with cwd elixir | The command cd elixir && rg -n PromptBuilder\|build_prompt\|with_role_prompt\|role_prompt elixir/lib/symphony_elixir exited 2 because elixir/lib/symphony_elixir was then resolved relative to elixir/. | Both required static scans were rerun from repository root and exited 0. |
| Initial unslop skill path | cat of /home/jcschoeman96/.codex-profiles/work/skills/unslop/SKILL.md exited 1 because the path did not exist. | Loaded the available skill at /home/jcschoeman96/.agents/skills/unslop/SKILL.md and applied it. |
| Exploratory codex.ex lookup and awk extraction | Prior working notes report an incorrect file lookup and noisy extraction. Their exact original command lines and exit codes were not retained. | No gate relied on either result, and neither changed repository state. This limitation is disclosed rather than assigning an exit code. |
| Evidence cleanup attempt using rm -f | Tool rejected the command before shell execution. | Removed the temporary draft with apply_patch. |
| V2 local root-ownership stop | V2 wording caused a blocked result because local Codex was user-owned. | The binding V3 ruling superseded that planner over-constraint. Local exact-version behavioral/isolation proof is accepted; root-owned proof remains mandatory on the exact hosted synthetic merge. |
| Initial subagent fence concern | The first report suggested a missing fence on a new not-found reservation. | Follow-up checked persist_safety/4 and the existing attempt-ledger test. New reservations persist armed; only legacy in-flight nil-fence records resolve to legacy_ambiguous. No defect remains. |
| Task 1 scan wrapper | A malformed shell grouping exited 2 with a syntax error near '|'. | Bash rejected that script before execution. The corrected static source scan exited 0 and reported 131 matches. |
| Repository search for PRE-H080C-CODEX-QUAL-01 | The command rg -n -C 3 'PRE-H080C-CODEX-QUAL-01' docs elixir .github returned exit 1 because the identifier has no local match in those paths. | The V3 binding ruling supplies the accepted precedent. No local file path or hash is claimed for that external decision. |

The full gate also emitted 27 parser shift/reduce warnings, an unused private optional argument warning, and Dialyzer's notice that no :ignore_warnings option was configured. Dialyzer completed with zero errors. No focused or full test run was canceled or reported flaky. Several full-gate partitions report the skips/exclusions listed in section 10.

No production, test, CI, or governance failure remains unresolved locally. Hosted verification is pending.

## 12. Acceptance boundary

This document records local verification only. Independent review, human merge, post-merge verification, and Master Governance acceptance remain outstanding. H-080C is not accepted. No merge is authorized by this evidence.

The final signed candidate HEAD/tree, PR identity, synthetic-merge SHA/tree/parents, GitHub signature verification, required check identities, and hosted root-owned Codex proof must be recorded in the PR and execution handoff after they exist.
