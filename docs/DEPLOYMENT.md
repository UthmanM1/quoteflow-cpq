# Deployment and CI/CD

The workflows in `.github/workflows` are a **design for a GitHub Actions pipeline** and have not been run against real orgs.
Secrets and environments named below must be created by whoever adopts the repository.

## Branching model

```
main (production)        <- release PR, protected, deploys to production after approval
  ^
develop (integration)    <- default branch for work; every merge deploys to the integration sandbox
  ^
feature/QF-123-short-name   one change per branch, short-lived, rebased on develop
hotfix/QF-456-...           branched from main, merged to main and back-merged to develop
```

Developer loop: scratch org per feature (`sf org create scratch -f config/project-scratch-def.json`), `sf project deploy start`,
run the affected tests, then open a pull request. Scratch-org setup also runs `scripts/apex/seed-demo-data.apex` and assigns `QF_Administrator_PSG`.

## Two package directories

`sfdx-project.json` lists `force-app` (default) and `revops-lab`. The PR pipeline lints, tests and deploys **both** to
its scratch org, so a lab change is checked like any other. The integration/UAT/production pipeline (`deploy.yml`) ships
**`force-app` only**: the lab is a demonstration build meant for a Developer Edition or Trailhead org, deployed by hand with
the commands in [SALESFORCE-CLI.md](SALESFORCE-CLI.md) and recorded in [ORG-VALIDATION.md](ORG-VALIDATION.md).

## Pipeline

| Stage | Trigger | What happens | Gate |
|---|---|---|---|
| 1. Static checks | PR to `develop`/`main` | `npm ci` from the committed lockfile; ESLint (LWC); Prettier check (Apex, triggers, LWC); Jest with coverage gate; persona FLS check for both layers (`scripts/ci/check_fls.py`); metadata schema-order check; lab security generator drift check; Code Analyzer (PMD security + error-prone) | Must pass |
| 2. Apex tests | PR (after 1) | Create a **throw-away scratch org** from the Dev Hub, deploy `force-app` and `revops-lab`, `RunLocalTests`, per-class (85%) and overall (90%) coverage gate (`scripts/ci/check_coverage.py`), delete the org | Must pass |
| 3. Code review | PR | CODEOWNERS (including `QuoteStateWriter` and permission sets); checklist in the PR template | Required |
| 4. Integration deploy | push to `develop` | Deploy + `RunLocalTests` in the integration sandbox; serialised per environment | Automatic |
| 5. Release validation | push to `main` | `sf project deploy validate` against **production**, `RunLocalTests`, nothing saved; the deployment id is captured as a job output | Must pass |
| 6. UAT | after 5 | Deploy the same commit to UAT; business sign-off on the quote-to-order journey | Automatic deploy |
| 7. Production | after 5 and 6 | Required reviewers on the `production` environment approve, then `sf project deploy quick` of **exactly the id from step 5**; release tag pushed (the only job with `contents: write`) | Manual approval |

Guard rails in the workflows:

* Production is reachable only from `main`; `workflow_dispatch` re-runs the pipeline for the selected branch, it cannot redirect a feature branch to production.
* Quick deploy never uses a stored or hand-maintained id. If the validation has expired (10 days), the job fails and the release is re-run, rather than silently falling back to an unvalidated full deploy.
* Deploy jobs are serialised per environment (`concurrency`), the CLI major version is pinned (`SF_CLI_VERSION`), workflow permissions default to `contents: read`, and org login is a reusable composite action (`.github/actions/sf-setup`) that writes the auth URL to a `0600` temp file and deletes it.
* Secrets are environment-scoped (`ci`, `integration`, `production-validation`, `uat`, `production`), each holding its own `SFDX_AUTH_URL` (`DEVHUB_SFDX_AUTH_URL` for `ci`).

Why scratch orgs for PRs: a shared CI sandbox lets two open pull requests overwrite each other's metadata between deploy and test, so results
stop being attributable to a commit. The trade-off is scratch-org allocation and a few minutes of org creation per PR.

What is deliberately *not* done: delta deployments (e.g. `sfdx-git-delta`). The whole `force-app` is small enough that full, validated
deployments are simpler to reason about; a DevOps platform or delta tooling becomes worthwhile as the org grows.

Deployment order concerns: custom objects and fields before permission sets; roles and the `QF Finance` group before the sharing rule;
permission sets before permission set groups; Apex before the flow. `sf project deploy` resolves dependencies inside one deployment, but if a split deploy is needed use this order.

## Manual, per-environment configuration (not in source)

1. Auth Provider, External Credential principal and Named Credential (`docs/config-specs`); principal access to `QF_Integration_User`.
2. Integration user, with API-only profile and `QF_Integration_User`; log in as that user and run `ERPSyncScheduler.scheduleEveryFiveMinutes()`.
   As an administrator, schedule `IntegrationLogPurgeBatch` (see INTEGRATION.md).
3. Users, role assignment, `QF Finance` group membership, permission set group assignment, manager hierarchy.
4. Organisation settings: enable Orders; set OWDs as in SECURITY.md (also deployable via sharing settings).
5. Activate `QF_Quote_Rejection_Follow_Up` after review.
6. Lightning pages, page layouts and tabs (not included in this repository): place `quoteConfigurator` on the Opportunity page and `quoteApprovalPanel` on the Quote page.

## Where a DevOps platform fits (Gearset or similar)

Gearset **was not used** to build this project. Here is how a platform of that kind could be introduced:

* **Compare and promote**: org-to-org and branch-to-org comparisons catch configuration drift (profiles, layouts, sharing) that never reached Git, and let admins promote declarative changes through pull requests rather than editing production.
* **Pipelines**: model `feature -> develop -> UAT -> production` as a pipeline with automated validations on each PR and visible promotion status for non-developers.
* **Test and quality**: scheduled Apex test runs with trend reporting, static code analysis, and delta deployments that deploy only changed components, shortening the validation time that grows with org size.
* **Data**: deploy Custom Metadata records and seed reference data alongside metadata.
* **Rollback**: snapshots of the target org before deployment give a restore point for metadata that is hard to revert by hand.

The Salesforce CLI remains the foundation: CI jobs use `sf project deploy validate/start/quick`, scratch orgs for development, and Git as the source of truth. A platform adds orchestration, drift detection and a non-developer interface; it does not replace the pull-request discipline.

## Rollback strategy

* **Preferred: forward-fix.** Revert the merge commit on `main`, run the pipeline; the pipeline redeploys the previous known-good source.
* **Destructive changes** (removed fields/classes) are never combined with additive changes in one release; they ship one release later through `destructiveChanges.xml` after the code that used them is gone.
* **Data/metadata state**: Custom Metadata is in source and reverts with the code. Field data cannot be un-deployed, so schema changes follow expand-then-contract (add field, deploy code reading both, migrate, remove old).
* **Feature switches**: new behaviour that touches quote flow is gated by Custom Metadata (e.g. thresholds, ERP settings) so it can be disabled by deployment without a code revert.
* **ERP**: idempotency keys make replay after rollback safe; quotes in `Failed` can be requeued after the fix.
* Production deployments are tagged `release-YYYYMMDD-HHMM` to make the revert target obvious.
* A revert goes through the same validate → UAT → approve → quick-deploy path; there is no "emergency full deploy" shortcut in the workflow.

## Release checklist

Validated in CI; coverage report reviewed; permission changes diffed against SECURITY.md; destructive changes separated; manual configuration list above checked; rollback commit identified; stakeholders told the window.
