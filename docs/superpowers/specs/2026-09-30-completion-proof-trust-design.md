# CompletionProof trust boundary

## Goal

Prevent caller-built guard maps from validating `Merging → Done` or satisfying downstream dependencies. Preserve a real completion path for code work by binding SourceControl's candidate and merge verification to a fresh provider `Done` observation.

## Design

`CompletionProof` is a typed mechanical evidence value with explicit stages. SourceControl creates the merge-authorization stage from fresh review, candidate, and required-check evidence before `Ready to Merge → Merging`. SourceControl then verifies the exact human merge and required checks before `Merging → Done`. The transition coordinator may submit `Done` only after that merge-verification stage passes.

The public proof constructors create structural values only. SourceControl signs a stage after its provider checks succeed; moving to merge verification requires a valid SourceControl signature on the authorization stage, and the updated proof is signed only after exact merge verification succeeds. Caller-built proof structs and fabricated `MergeVerification` values therefore cannot establish either trusted stage.

After submission, the coordinator rereads the provider. `LifecycleAssessment` closes the proof only when the fresh observation maps to the configured `Done` state for the same work item and project contract. A completed proof records the provider state identity and contract fingerprint so a later fresh reread can confirm that closure. Dependency satisfaction continues to depend on `completion_validated?/1`.

Bare maps, `outcome: :verified` maps, incomplete proof stages, mismatched CandidateRefs, failed or unavailable GitHub verification, wrong work-item identity, and provider observations outside the configured `Done` mapping fail closed. Legacy checkpoint records remain readable, but their class/name-only completion evidence does not validate completion.

The change does not add autonomous merge authority or expand H-080A characterization.

## Verification

Tests cover the original forged-map reproducer, forged verified maps, required proof stages, CandidateRef and policy binding, real SourceControl verification through the existing injected GitHub request seam, fresh provider closure, dependency consequences, and legacy checkpoint behavior. Run focused completion, source-control, lifecycle, transition, and recovery tests, then `git diff --check` and `make -C elixir all`.
