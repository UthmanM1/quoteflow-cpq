# Salesforce CLI Runbook

Exact `sf` (Salesforce CLI v2) commands for working with this repository.

> **Execution status:** these commands are documented, **not** recorded as run. No org was available while writing
> them, so there is no execution evidence in this repository. When you run them, paste the output (or a screenshot
> reference) into [ORG-VALIDATION.md](ORG-VALIDATION.md). Flags can change between CLI releases; check `sf <command> --help`.

Aliases used below: `revops-dev` (Developer Edition org or Trailhead Playground), `devhub` (Dev Hub), `revops-scratch` (scratch org).

## 0. Install and check the tooling

```bash
npm install --global @salesforce/cli
sf --version
sf plugins --core
npm ci                       # project dev dependencies (ESLint, Prettier, sfdx-lwc-jest) from package-lock.json
```

## 1. Authorize an org

```bash
# Developer Edition org or Trailhead Playground (opens a browser)
sf org login web --alias revops-dev --instance-url https://login.salesforce.com

# Org with My Domain login only (Trailhead Playgrounds often need this)
sf org login web --alias revops-dev --instance-url https://<your-domain>.my.salesforce.com

# Dev Hub for scratch orgs
sf org login web --alias devhub --set-default-dev-hub

# Headless / CI (as used in .github/actions/sf-setup): SFDX auth URL stored as a secret, never committed
sf org login sfdx-url --sfdx-url-file auth.txt --alias revops-dev

# Confirm
sf org list
sf org display --target-org revops-dev
```

## 2. Set the default org

```bash
sf config set target-org=revops-dev
sf config set target-dev-hub=devhub
sf config list
```

## 3. (Optional) Create a scratch org instead

```bash
sf org create scratch --definition-file config/project-scratch-def.json --alias revops-scratch \
  --duration-days 7 --set-default --target-dev-hub devhub
```

## 4. Deploy source

```bash
# Preview what would be deployed
sf project deploy preview --source-dir revops-lab --target-org revops-dev

# Validate only (nothing saved), running the lab tests
sf project deploy validate --source-dir revops-lab --target-org revops-dev --test-level RunSpecifiedTests \
  --tests ProductPricingServiceTest --tests DiscountPolicyServiceTest --tests SalesQuoteServiceTest \
  --tests SalesQuoteApprovalServiceTest --tests OrderConversionServiceTest --tests SalesERPIntegrationServiceTest \
  --tests SalesIntegrationLogServiceTest --tests SalesControllersTest --wait 30

# Deploy the RevOps Lab only
sf project deploy start --source-dir revops-lab --target-org revops-dev --wait 30

# Deploy both layers (main QuoteFlow + lab) - names do not collide
sf project deploy start --source-dir force-app --source-dir revops-lab --target-org revops-dev --wait 30
```

After deploying, give yourself access and seed demo data:

```bash
sf org assign permset --name Sales_Lab_Base --name Sales_Administrator_Access --target-org revops-dev
sf apex run --file scripts/apex/seed-revops-lab.apex --target-org revops-dev
sf org open --target-org revops-dev --path lightning/app/c__RevOps_Lab
```

Permission set **groups** are assigned in Setup (Users > Permission Set Group Assignments) or as data once the group
status is *Updated*:

```bash
sf data query --query "SELECT Id, DeveloperName, Status FROM PermissionSetGroup WHERE DeveloperName LIKE 'Sales_%'" --target-org revops-dev
sf data create record --sobject PermissionSetAssignment \
  --values "AssigneeId=<UserId> PermissionSetGroupId=<PermissionSetGroupId>" --target-org revops-dev
```

## 5. Run Apex tests

```bash
# All local tests, with coverage, results written to files
sf apex run test --test-level RunLocalTests --code-coverage --result-format human \
  --output-dir test-results --wait 30 --target-org revops-dev

# Only the lab classes
sf apex run test --class-names SalesQuoteServiceTest --class-names SalesQuoteApprovalServiceTest \
  --class-names OrderConversionServiceTest --class-names SalesERPIntegrationServiceTest \
  --code-coverage --result-format human --wait 20 --target-org revops-dev

# One method
sf apex run test --tests SalesQuoteApprovalServiceTest.tier2_routesToFinance_whoDecidesThroughTheSharingRule \
  --result-format human --wait 10 --target-org revops-dev

# Results of an earlier asynchronous run
sf apex get test --test-run-id <707...> --code-coverage --result-format human --target-org revops-dev

# Coverage gate used in CI
python3 scripts/ci/check_coverage.py test-results --min-class 85 --min-overall 90
```

## 6. Run LWC Jest tests (local, no org needed)

```bash
npm run test:unit                       # all Jest suites, both layers
npm run test:unit:coverage              # with the coverage gate from jest.config.js
npx sfdx-lwc-jest -- revops-lab         # lab components only
npx sfdx-lwc-jest --watch               # re-run on change
npm run lint                            # ESLint for both layers
```

## 7. Retrieve metadata

```bash
# Specific components changed in the org (e.g. after editing a flow or layout in Setup)
sf project retrieve start --metadata Flow:Sales_Quote_Approved_Update_Opportunity --target-org revops-dev
sf project retrieve start --metadata "Layout:Quote_Configuration__c-Quote Configuration Layout" --target-org revops-dev
sf project retrieve start --metadata CustomObject:Quote_Configuration__c --target-org revops-dev

# Everything listed in a manifest
sf project retrieve start --manifest manifest/revops-lab.xml --target-org revops-dev

# Review what changed before committing
git diff --stat
python3 scripts/ci/normalize_metadata.py --check force-app revops-lab
```

## 8. Generate package.xml

```bash
# From local source (no org needed)
sf project generate manifest --source-dir revops-lab --name revops-lab --output-dir manifest

# From what is in the org
sf project generate manifest --from-org revops-dev --name org-snapshot --output-dir manifest
```

The repository does not commit a generated manifest: source is the single source of truth, and a stale package.xml
is a common cause of partial deployments.

## 9. Check deployment status

```bash
# Start asynchronously and get a job id
sf project deploy start --source-dir revops-lab --target-org revops-dev --async

# Status / errors of that job
sf project deploy report --job-id <0Af...> --target-org revops-dev

# Re-attach and wait
sf project deploy resume --job-id <0Af...> --wait 30

# Cancel
sf project deploy cancel --job-id <0Af...> --target-org revops-dev
```

In the org: Setup > Deployment Status shows the same job with component and test failures.

## 10. Debugging

```bash
sf apex tail log --target-org revops-dev --color      # stream debug logs while you click through the UI
sf apex list log --target-org revops-dev
sf apex get log --log-id <07L...> --target-org revops-dev
```

## 11. Clean up

```bash
sf org delete scratch --target-org revops-scratch --no-prompt
sf org logout --target-org revops-dev --no-prompt
```
