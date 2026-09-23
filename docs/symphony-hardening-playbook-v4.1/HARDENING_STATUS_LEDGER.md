# Hardening status ledger

This file is the concise index of current programme state. Detailed historical provenance and review limits are recorded in [GOVERNANCE_RECONCILIATION.md](GOVERNANCE_RECONCILIATION.md).

## Historical reconciliation notice

The original V4.1 ledger became stale after V4.1-000. The discrepancy is preserved and reconciled in GOVERNANCE_RECONCILIATION.md. Current rows below represent reconciled programme state; they do not imply these values were present in earlier revisions.

## Current accepted baseline

| Branch | Commit | Tree |
|---|---|---|
| protected `main` | `e113dda4a58c51df8f56159a9daad3f1854d9d3b` | `be9d1c348a6d2be7a8e9475a4a0a9e077f52a9d2` |

## Phase index

| Phase | Status | PR | Accepted merge commit | Tree | Evidence | Next authorization |
|---|---|---:|---|---|---|---|
| H-010 | ACCEPTED | [#4](https://github.com/JCSchoeman96/symphony/pull/4) | `a1c60f1e8cb39233d89c341936947547d272891d` | `60443f2b48304531db84228d3fce90cfa2eb33db` | [V3 evidence](../symphony-hardening-playbook-v3/H-010_CRITICAL_TEST_AUTHORITY_EVIDENCE.md) | H-020 history |
| H-020 | ACCEPTED | [#5](https://github.com/JCSchoeman96/symphony/pull/5) | `8891ee624a39b99d384ec078eb73558ab4730a04` | `2badda0628c0ec2386e08cc8b8a6e0a4566f93da` | [V3 evidence](../symphony-hardening-playbook-v3/H-020_PROVIDER_CAPABILITY_CONTRACT_EVIDENCE.md) | H-030 history |
| H-030 | ACCEPTED | [#7](https://github.com/JCSchoeman96/symphony/pull/7) | `46cb22e33dc87729f56f1c07158992c63a84ac27` | `683a27711e56830146328406db331754e6ad08d6` | [V3 evidence](../symphony-hardening-playbook-v3/H-030_DURABLE_ATTEMPT_LINEAGE_EVIDENCE.md) | V4.1-000 |
| P-000 | ACCEPTED architecture evidence | N/A | No separate merge | H-030 tree above | [P-000 evidence](P-000_PLANE_PROVIDER_FEASIBILITY_EVIDENCE.md) and [roadmap](V4_1_MASTER_ROADMAP.md) | V4.1-000 |
| V4.1-000 | ACCEPTED | [#8](https://github.com/JCSchoeman96/symphony/pull/8) | `cb5eab22df613c5e449e5d886d5c96e9c4b6a436` | `2e1e6536dab86f1258bdee0cc80a2e9cbd544f2a` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | P-010 |
| P-010 | ACCEPTED | [#9](https://github.com/JCSchoeman96/symphony/pull/9) | `9eda9a9c529cedc76c01dcdbf5da31c9d271a1b9` | `c32c0b0b5768c129666060637e5da13698e0695d` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | P-020 |
| P-020 | ACCEPTED | [#10](https://github.com/JCSchoeman96/symphony/pull/10) | `7d0987b0e401a3e4166aad562d218fbd0b9a655f` | `5d52dbccc2adece991a6b1eded9feb820a17e960` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | P-030 |
| P-030 | ACCEPTED | [#11](https://github.com/JCSchoeman96/symphony/pull/11) | `f3b52b24045940187237aed1e0b45590049dc42f` | `fb64441239d264b95de13d519d7f5a44920b1b8b` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | P-040 |
| P-040 | ACCEPTED | [#12](https://github.com/JCSchoeman96/symphony/pull/12) | `f1d17b9cb564d74b972e4b317237451147d9eff1` | `8db749bf362e0b45e4892577741c3f8afec3e8aa` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-040 |
| H-040 | ACCEPTED | [#13](https://github.com/JCSchoeman96/symphony/pull/13) | `daeee2c10ea352e02842226fa6e21e20d3105690` | `38464ad90530123671709ab1ef3fad68dd582ced` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-050A |
| H-050A | ACCEPTED | [#14](https://github.com/JCSchoeman96/symphony/pull/14) | `7ad57bc059dbcd7e49b813021e84a797bc71437a` | `3734f8ebeb65f900bbd0022bbfbc1f1805059c9b` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-050B |
| H-050B | ACCEPTED | [#15](https://github.com/JCSchoeman96/symphony/pull/15) | `5fb71b0c87f298454eb2b0fa52eb90a281c5c537` | `a7dd2f13cdfa202c82c0c16786b4fa7546da28e8` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-050C |
| H-050C | ACCEPTED | [#16](https://github.com/JCSchoeman96/symphony/pull/16) | `8c9794a621805d248c39a74c5019e3b65d297840` | `85d30175cc7190f96b2a1bb4063ff27ff9094cdb` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-050D |
| H-050D | ACCEPTED | [#17](https://github.com/JCSchoeman96/symphony/pull/17) | `d9167352a5a06d6627e1b7a149b21604711d48f7` | `99a7533c7128dd8e9f8b37b02b961ff53de4d66f` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | H-060A |
| H-060A | ACCEPTED per supplied starting authority | [#18](https://github.com/JCSchoeman96/symphony/pull/18) | `d346a91395608242317be4a7375b1052f3000f52` | `baac1c1d0bcaaf9104dad3496015210341bd5a42` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | GOV-RECON-A; H-060B remains unauthorized |
| GOV-RECON-A | ACCEPTED | #19 | `e113dda4a58c51df8f56159a9daad3f1854d9d3b` | `be9d1c348a6d2be7a8e9475a4a0a9e077f52a9d2` | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | GOV-RECON-B closure only; H-060B remains unauthorized |
| GOV-RECON-B | IN REVIEW (candidate) | Not assigned | Not accepted | Not accepted | [Reconciliation](GOVERNANCE_RECONCILIATION.md) | None from this candidate |
| H-060B | NOT AUTHORIZED | N/A | N/A | N/A | [Roadmap](V4_1_MASTER_ROADMAP.md) | Planning only after GOV-RECON-B is merged, post-merge verified, and explicitly Master-accepted |

GOV-RECON-A is accepted. GOV-RECON-B is an in-review candidate and is not accepted. H-060B is not authorized for planning or implementation by this candidate.
