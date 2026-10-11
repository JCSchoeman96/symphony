---
name: release
description: Prepare a release candidate and, under explicit release authority, tag an independently verified merged commit.
---

# Release

<!-- SYMPHONY_AUTHORITY_CLASS: PROCEDURAL_NON_AUTHORITY -->

This skill describes release procedure only. It does not create release, merge, or tag authority.

## Candidate preparation

1. Start from an authorized feature branch and clean worktree.
2. Use the requested version. If none is supplied, derive the next patch after the latest `vX.Y.Z` tag.
3. Update `elixir/mix.exs` and other actual version sources required by the release.
4. Run the repository quality gate, commit the candidate, push the authorized branch, and open or
   update its PR using the repository template.
5. Do not call the `land` skill to merge. Human or separately authorized external merge authority
   owns that decision.

## Merge fact

After an external merge, resolve the exact merged commit and verify its tree, PR identity, and
required post-merge checks independently. A PR merge fact does not establish programme acceptance.

## Release and tag action

Create or publish a tag only when explicit release authority exists and the exact merged commit has
been independently verified. Verify the release workflow and assets against that commit. Do not
move a published tag without explicit authority.
