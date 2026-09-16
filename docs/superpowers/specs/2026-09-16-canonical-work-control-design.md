# Canonical work control design

## Goal

P-010 adds a provider-neutral work-control domain that separates provider
observation, canonical lifecycle validation, and Symphony-owned authority. It
keeps the existing Linear/Memory tracker boundary and legacy workflow path
while making routed decisions fail closed when trusted lifecycle evidence is
missing.

## Architecture

`Tracker.Issue` remains the compatibility/provider DTO. A fresh issue read is
wrapped as an immutable `ProviderObservation`; it is not treated as a
canonical state grant. `LifecycleAssessment` maps the observation through the
exact canonical `WorkflowLifecycle` vocabulary and compares it with a trusted
validated prior state plus typed guard evidence. `AuthorityDisposition` and
the pure `SuspensionContext` policy then decide whether autonomous work is
eligible, active, suspended, or escalated.

`WorkItem` is an ephemeral aggregate of the provider-neutral identity and
metadata needed by routed consumers. It carries the raw observation, latest
assessment, validated lifecycle state, disposition, optional suspension
context, and dependency metadata. It is never persisted. Orchestrator state
may retain WorkItems only as derived in-memory projections and must not
restore positive routed authority without trusted evidence.

`WorkflowLifecycle` is the sole owner of canonical state classification,
responsibility, dispatchability, transition legality, guard classes, and
transition side-effect metadata. Router and TransitionPolicy consume it.
Route overrides can select a profile only when that profile has the lifecycle
responsibility owned by the canonical state. Provider aliases remain in raw
legacy/provider compatibility paths and are not added to the canonical table.

## Canonical policy

The canonical states are Backlog, Planning, Ready, In Progress, In Review,
Changes Requested, Ready to Merge, Merging, Blocked, Done, and Canceled.
Done is successful terminal completion only after the typed mechanical
`completion_proof_verified` guard. Canceled is terminal invalidation and never
satisfies a dependency. Blocked is a human-facing provider projection; local
suspension does not require a provider mutation.

Assessment results are `Unassessed`, `MappingResolved`, `Validated`,
`AuthorityReducing`, `ValidationRequired`, and `Invalid`. A new observation
starts a new assessment. Unknown mappings and impossible transitions are
invalid. Forward observations without their required guard evidence are
validation-required and cannot grant authority. Cancellation and recognized
Blocked observations reduce authority immediately. Guard class identity is
preserved, so a semantic attestation cannot satisfy a mechanical guard and a
mechanical guard cannot satisfy a human decision.

The canonical transition graph is Backlog→Planning, Planning→Ready,
Ready→In Progress, In Progress→In Review, In Review→Changes Requested,
Changes Requested→In Review, In Review→Ready to Merge, Ready to Merge→Merging,
Merging→Done, and any nonterminal state→Canceled. All other direct transitions
are invalid. The merge transition remains human-controlled in V1.

## Integration boundaries

Routed dispatch, retry, running-worker reconciliation, dependency changes, and
AgentRunner continuation use a WorkItem assessment/disposition. Only a
validated, dispatchable canonical state can select a routed profile. An unsafe
observation stops or suspends local work and opens a SuspensionContext without
requiring `Tracker.transition_state`. Legacy dispatch continues to use its
configured provider active/terminal lists and aliases.

Dependency policy consumes validated lifecycle completion. A raw provider
`Done` observation is unresolved, validated `Done` with the required
completion-proof guard satisfies, and Canceled invalidates. The existing H-030
AttemptLedger, lineage generation, durable ordering, retry exhaustion, and
explicit rearm semantics remain unchanged.

No Plane HTTP, Plane project contract, CandidateRef, RuntimeAttempt identity,
durable suspension store, new persistence layer, autonomous merge, or later
hardening phase is included.

## Testing

Pure module tests cover all canonical states, classifications, ownership,
dispatchability, legal and exhaustive invalid transitions, assessment status
and guard-class separation, disposition recovery, suspension lifecycle, and
WorkItem composition. Existing router, transition, dependency, memory,
Linear tool, Orchestrator, AgentRunner, H-020 capability, and H-030 lineage
suites are updated only where the routed authority contract intentionally
changes. Tests use deterministic provider doubles and prove raw forward
observations and raw Done cannot grant authority or dependency completion.
