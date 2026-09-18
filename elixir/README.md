# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear adapter serves read-only `linear_graphql` plus the workflow-controlled `linear_transition`,
GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. The blocked
entry itself is runtime state, but routed safety counters and exhaustion are durable in a
project-scoped DETS ledger; restarting does not restore a Codex session or retry timer.

Automatic retry accounting is bounded per issue lineage: ordinary runtime or spawn failures receive
at most three retries, capacity waits do not consume that failure budget, and reviewer-to-correction
loops stop after three cycles. Normal continuations and route changes are tracked separately. CI
infrastructure is not retried automatically; a human or provider path must handle it. Routed mode
requires an explicit stable `symphony.project_id`; safety-relevant writes are synced before any
automatic follow-up, and ledger/provider reconciliation failures hold autonomous dispatch closed.

Retry dispatch rechecks eligibility, capacity, and the selected role against the immutable graph
epoch from reconciliation. It does not fetch provider relations per candidate. A later
reconciliation publishes a new epoch when dependencies change; incomplete or unavailable graph
data fails routed dispatch closed until reconciliation succeeds. Review-to-correction transitions
count even if observed during retry wait or denied by dependencies. Previously counted route
changes are not charged again when the retry starts.

Legacy adapters retain accepted per-issue blocker checks and do not claim a complete graph epoch.
Routed implementation/correction remain disabled for providers missing their required capabilities.
Built-in role prompt names must match the profile responsibility, including `.md` names. Custom
prompt text and files are trusted operator configuration and require manual role-policy review.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill can use Symphony's `linear_graphql` app-server tool for read-only Linear
     GraphQL queries. Workflow state changes must use `linear_transition`; raw GraphQL mutations
     are rejected at the Linear boundary.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, configure the lifecycle states used by your team.
     The shipped routed example uses Planning, Todo, Ready, In Progress, In Review,
     Changes Requested, and Ready to Merge; merge remains a deferred, read-only gate.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `agent.routing: routed` opts into explicit responsibility-aware profiles and
  state routes and requires `symphony.project_id`. The shipped `WORKFLOW.md` is a
  legacy Linear compatibility sample; use the deterministic `memory` adapter in
  tests until a provider passes the complete routed capability contract. Workflows
  without `agent.profiles` retain the legacy compatibility path.
- Routed safety lineage is stored in a deterministic DETS file outside the
  repository, workspace, and default `/tmp` directory. The namespace is keyed by
  `symphony.project_id`, while tracker/repository identity is checked on open.
  Corrupt, newer-schema, unavailable, or mismatched ledgers hold autonomous work
  closed rather than resetting counters. Use `mix symphony.attempt_rearm` with an
  explicit project, issue, reason, operator, and epoch-millisecond timestamp to rearm an
  exhausted lineage;
  deleting the DETS file manually is unsafe and unsupported.
- Routed role policies are shipped in `prompts/`. Symphony reads those files
  at runtime and uses the packaged copy when a file is unavailable. An active
  attempt captures its role prompt when it starts, so a later file edit applies
  to future attempts only.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tools: the Linear adapter advertises read-only `linear_graphql`, accepting either a raw query
  string or an object with nonblank `query` and optional object `variables`, and
  `linear_transition`, which accepts `targetState` plus a verified `targetStateId` for the
  bound current issue. The transition tool authorizes only the handoff owned by the bound
  responsibility; implementation/correction require a complete, allowed dependency decision,
  and `In Review` → `Ready to Merge` additionally requires `merge_permitted?`. Raw GraphQL
  mutations are rejected. Both tools execute host-side with the session-bound endpoint/token and
  strip declared token environment variables from the Codex child. `project_slug` scopes scheduler
  reads, while the configured Linear credential remains the provider permission boundary.
- Responsibility and errors: `linear_transition` is the only lifecycle write path exposed by the
  Linear adapter. It verifies the requested state name/ID against the current issue's team before
  issuing the fixed `issueUpdate` mutation. Each handoff refreshes the project dependency graph
  with bound provider settings and authorizes against current state, completeness, and cycles.
  Each bound session may attempt one mutation, including uncertain transport outcomes. A new
  session is required for another handoff. Concurrent tracker edits can still race between the
  final read and mutation; this is not provider-side atomic authorization. Read/config failures use
  `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### Plane adapter profile

- Config: use `tracker.kind: plane` with `tracker.provider.workspace_slug` for the Plane REST
  path, an explicit stable `tracker.provider.workspace_id`, and `tracker.provider.project_id`.
  `tracker.provider.api_key` must be `$PLANE_API_KEY` (or be supplied host-side); literal tokens
  are rejected. The endpoint is the host-controlled `https://api.plane.so` default.
- P-040 is read-only and supports fresh issue refresh plus bounded, complete dependency graph
  epochs. Plane enumerates the configured project, reads each item's fixed relations endpoint with
  bounded concurrency, rejects incomplete or cross-project data, and publishes a new immutable
  epoch only after the closing node set remains stable. Routed configuration remains fail-closed
  because later transition and agent-tool capabilities are still unsupported. Plane reads never
  grant lifecycle authority or completion proof.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_RUN_LIVE_E2E=1
export LINEAR_API_KEY='[secret omitted]'
export SYMPHONY_LIVE_LINEAR_TEAM_KEY='[named disposable team key]'
export SYMPHONY_LIVE_CODEX_HOME=/absolute/path/to/disposable-codex-home
mise exec -- make e2e
```

The consent/configuration gate is mandatory. It requires the exact consent token above, the
provider credential, a named disposable provider scope, and an explicitly configured Codex home
containing `auth.json`; it never falls back to the operator's default `CODEX_HOME`. Missing consent
or configuration leaves the test skipped, not passed. The gate reports only safe variable names and
is covered by `live_proof_gate_test.exs`.

Linear live-proof variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` names the disposable parent team; there is no default.
- `SYMPHONY_LIVE_PROOF_CONSENT` must equal `I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES`.
- `SYMPHONY_RUN_LIVE_E2E=1` enables the two Linear scenarios.
- `LINEAR_API_KEY` supplies the Linear credential without printing it.
- `SYMPHONY_LIVE_CODEX_HOME` names the Codex home copied into the temporary worker environment.
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
copies the explicitly configured Codex home auth into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The Linear live test creates a temporary project and issue in the named team, writes a temporary
`WORKFLOW.md`, runs a real agent turn, verifies the workspace side effect, and requires Codex to
read issue context through `linear_graphql` and use `linear_transition` to move the issue to `In
Review`. The harness then cleans up the issue and project directly through the provider API.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN='[secret omitted]'
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_LIVE_CODEX_HOME=/absolute/path/to/disposable-codex-home
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/github_live_e2e_test.exs --seed 0
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_LIVE_CODEX_HOME=/absolute/path/to/disposable-codex-home
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/jira_live_e2e_test.exs --seed 0
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_LIVE_CODEX_HOME=/absolute/path/to/disposable-codex-home
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/asana_live_e2e_test.exs --seed 0
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
export SYMPHONY_LIVE_PROOF_CONSENT=I_UNDERSTAND_THIS_MUTATES_NAMED_DISPOSABLE_RESOURCES
export SYMPHONY_LIVE_CODEX_HOME=/absolute/path/to/disposable-codex-home
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mise exec -- mix test test/symphony_elixir/gitlab_live_e2e_test.exs --seed 0
```

The complete deterministic proof and the external-proof boundary are recorded in
[`../docs/symphony-agent-router-dependency-proof.md`](../docs/symphony-agent-router-dependency-proof.md).

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
