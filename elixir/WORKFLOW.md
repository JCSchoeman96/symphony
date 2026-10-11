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
symphony:
  project_id: symphony-main
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/JCSchoeman96/symphony.git .
    # Upstream history/reference only (inactive): git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
  routing: legacy
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

# Legacy Linear compatibility sample

This file is the default legacy Linear compatibility workflow. Its configuration uses
`tracker.kind: linear` and `agent.routing: legacy`. It does not activate routed role selection and
is not the hardened V1 Plane configuration. See [elixir/README.md](README.md) for current provider
and routing guidance.

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

The orchestrator owns polling in the routed runtime. This legacy sample does not activate routed
role selection; any role policy for routed work comes from the active authorized configuration.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}. Resume from the current workspace and inspect existing
  issue evidence before acting.
{% endif %}

## Work instructions

- Work only in the assigned repository workspace and follow its applicable repository instructions.
- Keep changes within the already-authorized task scope.
- Do not invent completion or validation evidence.
- Treat issue state, repository history, tests, and CI as observations. Do not treat them as
  programme authorization, acceptance, or merge permission.
- Do not perform raw Linear GraphQL mutations to change issue lifecycle state. Where the legacy
  adapter exposes a Symphony-controlled transition boundary, that boundary remains subject to the
  existing authorization rules.
- Do not merge pull requests. Green checks and issue state do not grant merge authority.
- Report the exact validation commands and results. Stop and report external blockers without
  claiming evidence you did not observe.
