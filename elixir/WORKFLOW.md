---
tracker:
  kind: linear
  provider:
    project_slug: "symphony-0c79b11b75ea"
  required_labels: []
  active_states:
    - Planning
    - Todo
    - Ready
    - In Progress
    - In Review
    - Changes Requested
    - Ready to Merge
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
  routing: routed
  profiles:
    planner: {}
    builder: {}
    reviewer: {}
    fixer: {}
    merge_gatekeeper: {}
  routes:
    Planning: planner
    In Review: reviewer
    Changes Requested: fixer
    Ready to Merge: merge_gatekeeper
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

# Symphony routed workflow

The orchestrator owns polling, claims, retries, workspace cleanup, and
dispatch. Each attempt receives exactly one role policy selected from
the tracker state and the configured profile. Role prompts are packaged under
elixir/prompts/ and may be updated at runtime; the active attempt keeps the
prompt captured when it starts.

The repository's optional live-proof tests are separate from this workflow. They require named
disposable provider resources, an explicitly configured Codex home, provider credentials, and the
exact `SYMPHONY_LIVE_PROOF_CONSENT` token before they can run. Missing consent or configuration
keeps those tests skipped; it is never treated as live evidence.

You are working on a Linear ticket `{{ issue.identifier }}`.

## Issue context

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. Resume from the current workspace
  and the existing issue evidence.
{% endif %}

## Lifecycle routing

- Planning uses the planner role to produce a bounded plan and then request
  Ready.
- Todo, Ready, and In Progress use the builder role to implement the
  approved plan.
- In Review uses the reviewer role to inspect the exact change and report
  PASS, FAIL, or BLOCKED evidence.
- Changes Requested uses the fixer role to address recorded findings only.
- Ready to Merge uses the merge gatekeeper profile, which is deferred,
  read-only, and non-executable.
- Terminal states stop the attempt and permit workspace cleanup.

## Operating rules

1. Work only in the assigned repository workspace and honor the effective
   profile sandbox.
2. Treat the tracker, repository history, authority documents, dependency
   graph, tests, and CI as evidence. Do not invent completion or review
   results.
3. Keep implementation and correction work bounded to the approved issue and
   recorded review findings.
4. A reviewer does not modify source, approve its own work, or merge. A fixer
   validates findings and does not self-approve.
5. Never bypass an unresolved, invalidated, cyclic, or incomplete dependency.
   Read-only planning and review may document an incomplete dependency, but
   implementation remains stopped until the graph is authoritative.
6. Use the existing authorized tracker-tool boundary for lifecycle transitions. With the Linear
   adapter, use `linear_graphql` only for reads and `linear_transition` with the verified
   `targetState`/`targetStateId` pair for state handoffs. Do not issue arbitrary merge or
   destructive tracker mutations; raw GraphQL mutations are rejected.
7. Stop after the role's bounded responsibility is complete. The orchestrator
   will reconcile the issue and schedule any permitted continuation or retry.
8. Ordinary runtime/spawn failures receive at most three automatic retries.
   Capacity waits do not consume that budget, and reviewer-to-correction loops
   stop after three review cycles. CI infrastructure is not retried
   automatically; request human/provider intervention instead.
9. Report exact validation commands and results. Report external blockers
   without fabricating provider, CI, or runtime evidence.

Attempt counters live in the orchestrator's OTP state. Workflow reloads retain
the counters for the current live issue lineage; a process restart performs the
existing tracker/filesystem recovery and does not synthesize retry history.

Use `linear_transition` for one authorized handoff per session, then stop. The tool checks current
issue state and dependencies before writing. If a handoff response is uncertain, report it and stop;
the next attempt must reread the tracker before proceeding. Do not repeat the write in this session.
Built-in prompt selections must match the configured responsibility.
