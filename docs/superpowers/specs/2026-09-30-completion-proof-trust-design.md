# CompletionProof trust boundary

## Goal

Prevent caller-built guard maps from validating `Merging → Done` or satisfying downstream dependencies. Preserve a real completion path for code work by binding SourceControl's candidate and merge verification to a fresh provider `Done` observation.

## Design

`CompletionProof` is a typed mechanical evidence value with explicit stages. SourceControl creates the merge-authorization stage from fresh review, candidate, and required-check evidence before `Ready to Merge → Merging`. SourceControl then verifies the exact human merge and required checks before `Merging → Done`. The transition coordinator may submit `Done` only after that merge-verification stage passes.

The public proof constructors create structural values only. SourceControl signs a stage after its provider checks succeed; moving to merge verification requires a valid SourceControl signature on the authorization stage, and the updated proof is signed only after exact merge verification succeeds. Caller-built proof structs and fabricated `MergeVerification` values therefore cannot establish either trusted stage.

After submission, the coordinator rereads the provider. The `Tracker` boundary attaches a signed read receipt to each normalized Plane issue only after the adapter returns it. `ProviderObservation.from_issue/2` preserves that receipt only while the observation still matches the issue's ID, project, state identity, name, and update time. `LifecycleAssessment` closes the proof only when this Tracker-issued observation maps to the configured `Done` state for the same work item and project contract, was read strictly after merge verification, and is no more than five minutes old. Revalidation also requires a current Tracker read strictly after merge verification, so a still-fresh pre-merge receipt cannot replay a completed proof. Later routed refreshes obtain a new receipt from their own Tracker read before revalidating completion. A caller-built or stale observation cannot establish closure, and changing a signed observation or its issue fields invalidates the binding. Dependency satisfaction continues to depend on `completion_validated?/1` and a current read receipt.

Bare maps, `outcome: :verified` maps, incomplete proof stages, mismatched CandidateRefs, failed or unavailable GitHub verification, wrong work-item identity, and provider observations outside the configured `Done` mapping fail closed. Legacy checkpoint records remain readable, but their class/name-only completion evidence does not validate completion.

The change does not add autonomous merge authority or complete the remaining H-080A characterization matrix.

## Verification

Tests cover the original forged-map reproducer, forged verified maps, required proof stages, CandidateRef and policy binding, real SourceControl verification through the existing injected GitHub request seam, fresh provider closure, dependency consequences, and legacy checkpoint behavior. Run focused completion, source-control, lifecycle, transition, and recovery tests, then `git diff --check` and `make -C elixir all`.
