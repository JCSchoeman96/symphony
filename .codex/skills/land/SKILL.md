---
name: land
description: Verify a PR candidate and prepare the human or external merge handoff. This skill does not merge.
---

# Land handoff

<!-- SYMPHONY_AUTHORITY_CLASS: PROCEDURAL_NON_AUTHORITY -->

This compatibility skill verifies an exact candidate and prepares a human or external merge
handoff. It does not merge, enable auto-merge, or grant merge or acceptance authority. A green check
is evidence about a candidate; it is not permission to merge or accept it.

## Preconditions

- Work in an already-authorized source-control role and writable workspace.
- Confirm the PR belongs to the current branch and the worktree is clean.
- Read the applicable repository authority and required-check policy.

## Review steps

1. Resolve the PR URL, base SHA, head SHA, and exact candidate identity.
2. Independently read protected-branch configuration. For this repository, verify `make-all` and
   `validate-pr-description` are required and produced by GitHub Actions app `15368`.
3. Inspect mergeability and whether the base has moved. If the accepted governance baseline moved,
   stop and obtain a new governance decision. Do not silently rebase around it.
4. Resolve review findings and verify the exact candidate again after any change.
5. Observe required check results on that exact candidate. Do not treat optional, skipped, neutral,
   or differently produced checks as required-check proof.
6. Resolve the exact synthetic merge candidate and verify its base and head parents.
7. Prepare a handoff containing the candidate identity, branch protection, required-check evidence,
   review status, synthetic merge identity, and any unresolved risks.

## Stop boundary

Stop after the exact candidate is verified, required checks are observed, review findings are
resolved, and the handoff is ready. A human or separately authorized external process owns the
merge decision. Master Governance owns programme acceptance after the applicable post-merge evidence.

## Advisory watcher

`land_watch.py` is a convenience monitor. Its output is advisory and does not prove required-check
identity, branch protection, exact merge readiness, or permission to merge.
