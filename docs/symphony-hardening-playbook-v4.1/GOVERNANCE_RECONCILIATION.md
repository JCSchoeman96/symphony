# Governance reconciliation

**Record:** GOV-RECON-A candidate<br>
**Status:** IN REVIEW<br>
**Evidence checked:** 2026-09-23<br>
**Scope:** V4.1-000 through H-060A

This record reconciles the governance history visible in the repository and GitHub. It does not claim that the earlier ledger was accurate when it was written. It does not create missing GitHub review objects or convert external review into a GitHub approval.

GOV-RECON-A cannot record its own final candidate commit, merge commit, or post-merge acceptance in the same commit. GOV-RECON-B can append those facts after GOV-RECON-A has merged and passed post-merge acceptance.

## Reconciliation baseline

The supplied accepted starting baseline is protected `main` at commit `d346a91395608242317be4a7375b1052f3000f52`, tree `baac1c1d0bcaaf9104dad3496015210341bd5a42`. A fresh GitHub query confirmed `origin/main` still points to that commit. PR #18 is the merge that produced it.

The V4.1 roadmap remains unchanged at blob `4b0528bdc0647d889b42ebc478081d5b873898fe`. The accepted V3 evidence remains unchanged. At the starting commit, the V3 directory tree is `f6b51d53ca51818528f7ed6747ea1d7bc51bc8dd`; its H-010, H-020, and H-030 evidence blobs are `931bf13f96f3ee7899e803ed03c2b03e5f9a7e6f`, `f7750130b0a95cedce07ed2522cd5fdc7478475c`, and `92605628806ddd8fcb4404d466a43d8e68bdb868` respectively.

## Historical discrepancy

At the reconciliation baseline, `HARDENING_STATUS_LEDGER.md` still says V4.1-000 is "IN REVIEW once PR is opened", P-010 is "NOT STARTED / UNAUTHORIZED", and P-020+ is "NOT STARTED". The V4.1 README also says P-010 cannot begin until V4.1-000 is reviewed, merged, and post-merge verified. Those statements no longer match main: PRs #8 through #18 have merged in sequence, through H-060A.

This record preserves that discrepancy. The old statements describe what the ledger and README recorded; they are not evidence that those statements remained current after the merges.

## Evidence classes and acceptance rules

- **Repository-mechanical:** Git commit and tree objects, PR base and head, merge commit ancestry, check runs, and observed protected-branch configuration.
- **Repository-review:** submitted GitHub reviews, review comments, or issue comments on the PR.
- **External-governance:** an independent review or Master gate performed outside GitHub. The source must be identified. Do not label it a GitHub review.

A missing record is `unavailable` in the sources checked. It does not prove that an external event did not happen. Candidate SHA, merge SHA, and resulting tree are separate facts. `MERGED` alone does not mean `ACCEPTED`; acceptance also needs post-merge verification and the applicable governance decision.

The branch-protection query made for this reconciliation reports strict protection on `main`, with GitHub Actions app ID `15368` requiring `make-all` and `validate-pr-description`. Each PR head below has successful runs for both contexts. Each merge commit below has a successful `make-all` run. GitHub did not provide a historical branch-protection snapshot for each merge time, so this record does not claim that the current required-context configuration was identical throughout the whole sequence. The `validate-pr-description` check ran on PR heads; no corresponding post-merge run was present on the merge commits.

## Phase evidence through H-060A

The authorized base in each row is the PR's `main` base SHA and its tree. The candidate is the PR head SHA and tree. Check links point to successful GitHub Actions runs attached to the exact candidate or merge SHA. The selected candidate runs are successful runs for each required context.

| Phase / PR | Authorized base: commit / tree | Candidate: commit / tree | Merge: method, commit / tree / parent(s) | CI: candidate and post-merge | GitHub review / external governance | Next authorization |
|---|---|---|---|---|---|---|
| V4.1-000 / [#8](https://github.com/JCSchoeman96/symphony/pull/8) | `46cb22e33dc87729f56f1c07158992c63a84ac27` / `683a27711e56830146328406db331754e6ad08d6` | `8f6ebf733e72126728f2c97844d8e32500dc8f0c` / `2e1e6536dab86f1258bdee0cc80a2e9cbd544f2a` | Squash-style, one parent: `cb5eab22df613c5e449e5d886d5c96e9c4b6a436` / `2e1e6536dab86f1258bdee0cc80a2e9cbd544f2a` / parent `46cb22e33dc87729f56f1c07158992c63a84ac27` | Candidate: `make-all` [104684984392](https://github.com/JCSchoeman96/symphony/actions/runs/35062299314/job/104684984392), `validate-pr-description` [104685099467](https://github.com/JCSchoeman96/symphony/actions/runs/35062333904/job/104685099467), both success. Merge: `make-all` [104688354610](https://github.com/JCSchoeman96/symphony/actions/runs/35063397174/job/104688354610), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | P-010 |
| P-010 / [#9](https://github.com/JCSchoeman96/symphony/pull/9) | `cb5eab22df613c5e449e5d886d5c96e9c4b6a436` / `2e1e6536dab86f1258bdee0cc80a2e9cbd544f2a` | `4837d0ab8b552fa031433b758d01f546fbaccddb` / `c32c0b0b5768c129666060637e5da13698e0695d` | Squash-style, one parent: `9eda9a9c529cedc76c01dcdbf5da31c9d271a1b9` / `c32c0b0b5768c129666060637e5da13698e0695d` / parent `cb5eab22df613c5e449e5d886d5c96e9c4b6a436` | Candidate: `make-all` [104922695691](https://github.com/JCSchoeman96/symphony/actions/runs/35134304224/job/104922695691), `validate-pr-description` [104922696737](https://github.com/JCSchoeman96/symphony/actions/runs/35134304366/job/104922696737), both success. Merge: `make-all` [104949538179](https://github.com/JCSchoeman96/symphony/actions/runs/35142297075/job/104949538179), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | P-020 |
| P-020 / [#10](https://github.com/JCSchoeman96/symphony/pull/10) | `9eda9a9c529cedc76c01dcdbf5da31c9d271a1b9` / `c32c0b0b5768c129666060637e5da13698e0695d` | `c22a6b97c5d8841ba833681f017fb3af0e659061` / `5d52dbccc2adece991a6b1eded9feb820a17e960` | Squash-style, one parent: `7d0987b0e401a3e4166aad562d218fbd0b9a655f` / `5d52dbccc2adece991a6b1eded9feb820a17e960` / parent `9eda9a9c529cedc76c01dcdbf5da31c9d271a1b9` | Candidate: `make-all` [105200649465](https://github.com/JCSchoeman96/symphony/actions/runs/35220943626/job/105200649465), `validate-pr-description` [105200649488](https://github.com/JCSchoeman96/symphony/actions/runs/35220943619/job/105200649488), both success. Merge: `make-all` [105274968096](https://github.com/JCSchoeman96/symphony/actions/runs/35242717359/job/105274968096), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | P-030 |
| P-030 / [#11](https://github.com/JCSchoeman96/symphony/pull/11) | `7d0987b0e401a3e4166aad562d218fbd0b9a655f` / `5d52dbccc2adece991a6b1eded9feb820a17e960` | `c4a06c2ac63539eb3c2e93fcf78b13c09a6616ab` / `fb64441239d264b95de13d519d7f5a44920b1b8b` | Squash-style, one parent: `f3b52b24045940187237aed1e0b45590049dc42f` / `fb64441239d264b95de13d519d7f5a44920b1b8b` / parent `7d0987b0e401a3e4166aad562d218fbd0b9a655f` | Candidate: `make-all` [105370210828](https://github.com/JCSchoeman96/symphony/actions/runs/35271042079/job/105370210828), `validate-pr-description` [105370210713](https://github.com/JCSchoeman96/symphony/actions/runs/35271042094/job/105370210713), both success. Merge: `make-all` [105488254321](https://github.com/JCSchoeman96/symphony/actions/runs/35309452869/job/105488254321), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | P-040 |
| P-040 / [#12](https://github.com/JCSchoeman96/symphony/pull/12) | `f3b52b24045940187237aed1e0b45590049dc42f` / `fb64441239d264b95de13d519d7f5a44920b1b8b` | `8a89f2117ee1dc96b2369c0b47da70ae4cce9b5f` / `8db749bf362e0b45e4892577741c3f8afec3e8aa` | Squash-style, one parent: `f1d17b9cb564d74b972e4b317237451147d9eff1` / `8db749bf362e0b45e4892577741c3f8afec3e8aa` / parent `f3b52b24045940187237aed1e0b45590049dc42f` | Candidate: `make-all` [105603083397](https://github.com/JCSchoeman96/symphony/actions/runs/35346149401/job/105603083397), `validate-pr-description` [105603083309](https://github.com/JCSchoeman96/symphony/actions/runs/35346149370/job/105603083309), both success. Merge: `make-all` [105617263960](https://github.com/JCSchoeman96/symphony/actions/runs/35350511616/job/105617263960), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-040 |
| H-040 / [#13](https://github.com/JCSchoeman96/symphony/pull/13) | `f1d17b9cb564d74b972e4b317237451147d9eff1` / `8db749bf362e0b45e4892577741c3f8afec3e8aa` | `d47bb1f8aa98851e9a2f9efc1b30fdb15aa8ef78` / `38464ad90530123671709ab1ef3fad68dd582ced` | Squash-style, one parent: `daeee2c10ea352e02842226fa6e21e20d3105690` / `38464ad90530123671709ab1ef3fad68dd582ced` / parent `f1d17b9cb564d74b972e4b317237451147d9eff1` | Candidate: `make-all` [105850324567](https://github.com/JCSchoeman96/symphony/actions/runs/35425393183/job/105850324567), `validate-pr-description` [105850324676](https://github.com/JCSchoeman96/symphony/actions/runs/35425393213/job/105850324676), both success. Merge: `make-all` [105855487853](https://github.com/JCSchoeman96/symphony/actions/runs/35427354238/job/105855487853), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-050A |
| H-050A / [#14](https://github.com/JCSchoeman96/symphony/pull/14) | `daeee2c10ea352e02842226fa6e21e20d3105690` / `38464ad90530123671709ab1ef3fad68dd582ced` | `2c6958d771ea279c30e2ece338e0d31d00159e99` / `3734f8ebeb65f900bbd0022bbfbc1f1805059c9b` | Squash-style, one parent: `7ad57bc059dbcd7e49b813021e84a797bc71437a` / `3734f8ebeb65f900bbd0022bbfbc1f1805059c9b` / parent `daeee2c10ea352e02842226fa6e21e20d3105690` | Candidate: `make-all` [105932988698](https://github.com/JCSchoeman96/symphony/actions/runs/35456638835/job/105932988698), `validate-pr-description` [105932988549](https://github.com/JCSchoeman96/symphony/actions/runs/35456638815/job/105932988549), both success. Merge: `make-all` [105950271728](https://github.com/JCSchoeman96/symphony/actions/runs/35463064419/job/105950271728), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-050B |
| H-050B / [#15](https://github.com/JCSchoeman96/symphony/pull/15) | `7ad57bc059dbcd7e49b813021e84a797bc71437a` / `3734f8ebeb65f900bbd0022bbfbc1f1805059c9b` | `4291343422c199ee5f47a99206a82b2c2205b6dc` / `a7dd2f13cdfa202c82c0c16786b4fa7546da28e8` | Two-parent merge commit: `5fb71b0c87f298454eb2b0fa52eb90a281c5c537` / `a7dd2f13cdfa202c82c0c16786b4fa7546da28e8` / parents `7ad57bc059dbcd7e49b813021e84a797bc71437a`, `4291343422c199ee5f47a99206a82b2c2205b6dc` | Candidate: `make-all` [106111645023](https://github.com/JCSchoeman96/symphony/actions/runs/35523539355/job/106111645023), `validate-pr-description` [106111729769](https://github.com/JCSchoeman96/symphony/actions/runs/35523568996/job/106111729769), both success. Merge: `make-all` [106144119477](https://github.com/JCSchoeman96/symphony/actions/runs/35535663798/job/106144119477), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-050C |
| H-050C / [#16](https://github.com/JCSchoeman96/symphony/pull/16) | `5fb71b0c87f298454eb2b0fa52eb90a281c5c537` / `a7dd2f13cdfa202c82c0c16786b4fa7546da28e8` | `5bed264786e5303e6763f8a0d6c9e8fdf6d80da0` / `85d30175cc7190f96b2a1bb4063ff27ff9094cdb` | Squash-style, one parent: `8c9794a621805d248c39a74c5019e3b65d297840` / `85d30175cc7190f96b2a1bb4063ff27ff9094cdb` / parent `5fb71b0c87f298454eb2b0fa52eb90a281c5c537` | Candidate: `make-all` [106479155802](https://github.com/JCSchoeman96/symphony/actions/runs/35643774956/job/106479155802), `validate-pr-description` [106479156139](https://github.com/JCSchoeman96/symphony/actions/runs/35643774910/job/106479156139), both success. Merge: `make-all` [106498619631](https://github.com/JCSchoeman96/symphony/actions/runs/35649657338/job/106498619631), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-050D |
| H-050D / [#17](https://github.com/JCSchoeman96/symphony/pull/17) | `8c9794a621805d248c39a74c5019e3b65d297840` / `85d30175cc7190f96b2a1bb4063ff27ff9094cdb` | `ec20fb838492e0a4671640dfa08156c99754e8eb` / `99a7533c7128dd8e9f8b37b02b961ff53de4d66f` | Two-parent merge commit: `d9167352a5a06d6627e1b7a149b21604711d48f7` / `99a7533c7128dd8e9f8b37b02b961ff53de4d66f` / parents `8c9794a621805d248c39a74c5019e3b65d297840`, `ec20fb838492e0a4671640dfa08156c99754e8eb` | Candidate: `make-all` [106667330588](https://github.com/JCSchoeman96/symphony/actions/runs/35703662750/job/106667330588), `validate-pr-description` [106667330201](https://github.com/JCSchoeman96/symphony/actions/runs/35703662667/job/106667330201), both success. Merge: `make-all` [106672849115](https://github.com/JCSchoeman96/symphony/actions/runs/35705361942/job/106672849115), success. | GitHub: no submitted review, issue comment, or review comment. External governance: unavailable. | H-060A |
| H-060A / [#18](https://github.com/JCSchoeman96/symphony/pull/18) | `d9167352a5a06d6627e1b7a149b21604711d48f7` / `99a7533c7128dd8e9f8b37b02b961ff53de4d66f` | `a4d892215e2390340dbeb0cc263c3a8466016e45` / `baac1c1d0bcaaf9104dad3496015210341bd5a42` | Two-parent merge commit: `d346a91395608242317be4a7375b1052f3000f52` / `baac1c1d0bcaaf9104dad3496015210341bd5a42` / parents `d9167352a5a06d6627e1b7a149b21604711d48f7`, `a4d892215e2390340dbeb0cc263c3a8466016e45` | Candidate: `make-all` [106886175337](https://github.com/JCSchoeman96/symphony/actions/runs/35769158562/job/106886175337), `validate-pr-description` [106886176029](https://github.com/JCSchoeman96/symphony/actions/runs/35769158582/job/106886176029), both success. Merge: `make-all` [106912508887](https://github.com/JCSchoeman96/symphony/actions/runs/35776962438/job/106912508887), success. | GitHub: no submitted review, issue comment, or review comment. External governance: the supplied GOV-RECON planning brief reports an independent review; its source transcript and reviewer identity are unavailable here. | The current user request authorizes GOV-RECON-A implementation. It does not authorize H-060B, which remains blocked on GOV-RECON-B acceptance. |

GitHub's REST pull-request object did not report a merge-method field. The labels above are inferred from the resulting commit's parent count, tree, PR commit count, and message. PRs #8-#14 and #16 each contain multiple PR commits, but their resulting commit has one parent equal to the PR base and a tree equal to the PR head tree. Its message matches the PR title. Those facts identify squash-style integration. PRs #15, #17, and #18 have two-parent merge commits whose first parent is the PR base and second parent is the candidate head.

## Review and acceptance limits

GitHub contains zero submitted reviews, zero review comments, and zero issue comments for every PR from #8 through #18. For H-060A, the supplied planning brief says an external independent review occurred. The review artifact, reviewer identity, and transcript were not present in the repository or the GitHub PR. For V4.1-000 through H-050D, external-governance review evidence was unavailable in the sources checked. No row describes a GitHub approval.

The supplied starting authority identifies H-060A as accepted. This reconciliation confirms the exact PR head, merge ancestry, tree, candidate CI, and post-merge `make-all` result. GitHub's records alone do not establish any external Master approval. Review provenance remains an explicit evidence gap for the earlier phases.

## Runtime lineage clarification

`RuntimeAttempt.Identity.lineage_generation` carries the durable lineage token from `AttemptLedger`'s `record.lineage_id`. `Orchestrator.allocate_runtime_attempt/4` passes that value to `RuntimeAttempt.Identity.allocate/3`. `AttemptLedger` creates an opaque token such as `lineage-<random hex>`; it is not a second counter. Keep the field name unchanged in GOV-RECON.

## Carried-forward requirements

These items remain future work. This reconciliation does not authorize their implementation:

- H-060B startup recovery and suspension reconciliation.
- H-060C workspace ownership and shutdown recovery.
- H-070 relation-snapshot proof and scale evidence, including large dependency graphs.
- H-080 Codex runtime isolation and explicit security-contract coverage authority.
- H-080C integrated dependency-security gate.

Do not reopen H-050C synthetic-merge behavior or change runtime naming here. Record dependency-security requirements for a later authorized phase; do not upgrade packages in GOV-RECON.

## GOV-RECON-A state

At this local candidate stage:

```text
GOV-RECON-A = IN REVIEW
H-060B = NOT AUTHORIZED
```

PR #19 records this candidate. GitHub is the source of truth for its exact-head CI and submitted review status. `IN REVIEW` names the candidate state and does not claim that an independent review has already passed. After the PR merges and receives post-merge acceptance, GOV-RECON-B can append its exact candidate, merge, CI, review provenance, and accepted baseline. GOV-RECON-B may then authorize H-060B for planning. It does not authorize H-060B implementation.

## Performance and scope

This is documentation-only. Hot data, warm data, Redis, Postgres, PubSub, Oban, and runtime provider calls are not applicable. Evidence collection read the bounded PR sequence #8-#18 and the associated commit and check records. No production latency or concurrency behavior changes.
