# Testing Strategy

## Verification status (read this first)

The Apex and metadata have **not been deployed to or executed in a Salesforce org**. The LWC unit tests have been run locally.

| Check | Tool | Result |
|---|---|---|
| Apex syntax (main 36 classes + 4 triggers; lab 28 classes + 3 triggers) and formatting | `prettier-plugin-apex` (`npm run prettier:verify`) | Parses and is formatted |
| LWC lint | ESLint with `@salesforce/eslint-config-lwc` | Clean |
| LWC unit tests | `sfdx-lwc-jest` (`npm run test:unit:coverage`) | 39 tests pass (22 main, 17 lab); ~89% statements across the six bundles (gate: 80/70) |
| Persona FLS consistency | `scripts/ci/check_fls.py` | Both layers: every field in every `WITH USER_MODE` query is readable by each persona that reaches it |
| Metadata XML / workflow YAML well-formed; lockfile resolves | python `minidom`, PyYAML, `npm ci` | Valid |
| Metadata in schema element order; lab permission sets match their generator | `npm run check:metadata-order`, `npm run generate:lab-security` + `git diff` | Clean |
| Apex compiles against the real schema, Apex tests pass, coverage | **Not done - first run of the PR pipeline (scratch org)** | Pending |

Treat the Apex tests as written-to-spec and expect a first-run fix-up pass. Do not quote an Apex coverage percentage until a run produces one.

## Principles

* Test behaviour and failure modes, not lines. Every test asserts an outcome that a regression would change.
* **Test as the persona, not as the CI admin.** The CI runner has Modify All Data through its profile, which hides sharing and
  record-access bugs. Every journey that a non-admin performs (rep, role-less manager, finance approver with only
  `QF_Finance_Approver`, integration user with only `QF_Integration_User`) is run with `System.runAs` as a user holding only the
  shipped permission sets. The review defects W1-W3 were invisible precisely because this was missing.
* **Every defect gets a regression test** named after the behaviour it protects (see the table below).
* Deterministic policy: discount tiers, approval thresholds and configuration rules are injected via `@TestVisible` overrides, so tests do not depend on deployed Custom Metadata.
* System-owned state is arranged through `QuoteStateWriter` (`TestDataFactory.approve/setSystemState`), the same path production code must use; a direct `update` of an ERP or approval field is rejected by the trigger, in tests too.
* `Test.startTest()/stopTest()` isolate the unit under test, reset governor limits for budget assertions and deliver queueables, batches and platform events.
* Modern `Assert` class throughout (`Assert.areEqual`, `Assert.isTrue`, `Assert.fail`).

## Coverage of requirements

| Requirement | Tests |
|---|---|
| Unit | `DiscountEvaluationServiceTest` (pure logic), `ProductConfigurationServiceTest`, `IntegrationLogServiceTest`, `LoggerTest` |
| Bulk / governor budgets | 200 lines over 4 quotes (`QuoteCalculationServiceTest`); 50-quote submission (`QuoteApprovalServiceTest`); 200-quote insert (`QuoteTriggerTest`); 5-quote ERP batch = 5 callouts + 2 DML (`ERPIntegrationServiceTest`); **1 vs 20 bundles use the same number of queries** (`ProductConfigurationServiceTest`); 8-bundle save under a query budget (`QuoteControllersTest`) |
| Positive | Pricing waterfall, tier boundaries, auto-approval, one-, two- and three-level approval, order conversion, ERP 201/409 |
| Negative | Zero quantity, over-limit discount, unpriced product, invalid configurations, wrong approver, double decision, rejection without comment, self-approval via DML, forged included flag, forged ERP fields, locked quote edits, missing ERP customer id, 422, 5xx exhaustion, non-owner submit/recall/convert, requeue without permission |
| Personas / security | Rep least-privilege FLS, rep cannot read others' quotes, **role-less manager, finance-only and VP approvers decide through Apex shares only**, **integration user leases, syncs and logs quotes it does not own**, rep converts with rep permissions only, non-owner readers refused, superseded approver loses access, decider keeps access |
| Integration mocking | `HttpCalloutMock` (`ERPMock`) per test; headers and body asserted, including the generation-scoped `Idempotency-Key`; timeout via `CalloutException`; `Retry-After`; queueable executed at `Test.stopTest()` |
| Trigger | Defaults and forced draft state, lifecycle enforcement (also for the writer), lock/override, re-pricing on term change, approval request immutability, roll-up on delete, **bundle header delete cascades to components**, writer refuses user-owned fields |
| Error handling | Support reference shown to the user equals the persisted `Application_Log__c.Reference__c`; log survives rollback; cacheable path publishes nothing; failed ERP outcome write is logged; logger failure is reported, never thrown; queueable abort is logged |
| Async | Scheduler creates 12 jobs; nothing due = no jobs; purge batch keeps recent and deletes old rows for both log objects; allow-list on the purge object |

## Regression tests for the review findings

| Finding ([PRINCIPAL-REVIEW.md](PRINCIPAL-REVIEW.md)) | Test |
|---|---|
| W1 sharing blocks approvers | `QuoteApprovalServiceTest.decide_threeLevels_shareOnlyApproversCanEachDecide` (and the existing journeys, now with a finance-only approver) |
| W2 integration user cannot write | `ERPIntegrationServiceTest.integrationUserPersona_leasesSyncsAndLogsQuotesItDoesNotOwn` |
| W3 conversion field / stranded sync | `QuoteOrderServiceTest.convert_quoteWithOpportunity_linksTheOrder`, `convert_keepsTheQuoteEligibleForErpSync`, `ERPIntegrationServiceTest.orderedQuote_isStillSynchronised` |
| W4 UI-only authorisation | `QuoteApprovalServiceTest.submit_byUserWhoCanReadButDoesNotOwnTheQuote_isRefused`, `recall_byNonOwner_isRefused`, `QuoteOrderServiceTest.convert_byReaderWhoIsNotTheOwner_isRefused` |
| W5 scattered elevation / ERP tampering | `QuoteTriggerTest.update_erpFieldsCannotBeForgedOutsideTheIntegration`, `stateWriter_refusesUserOwnedFields`, `update_serviceTransition_followsLifecycleGraph` |
| W6 SOQL per bundle | `ProductConfigurationServiceTest.configureAll_manyBundles_usesConstantQueries`, `QuoteControllersTest.saveQuote_manyBundles_noLongerLimitedByGovernorWorkaround` |
| W7 orphaned components | `QuoteTriggerTest.lines_deletingBundleHeader_cascadesToItsComponents` |
| W8 shares never revoked | `QuoteApprovalServiceTest.recall_revokesTheUndecidedApproversAccess` |
| W9 debug-only errors | `LoggerTest.*`, `QuoteControllersTest.unexpectedError_isLoggedWithTheReferenceShownToTheUser`, `AsyncJobsTest.queueable_systemicFailure_isLoggedNotThrown`, `ERPIntegrationServiceTest.outcomeThatCannotBePersisted_isLoggedNotSwallowed` |
| W10 idempotency generation | `ERPIntegrationServiceTest.request_carriesCorrelationIdempotencyAndContractFields`, `requeueFailed_resetsOnlyFailedApprovedQuotes` |
| W11 stale cached status | `quoteConfigurator.test.js` "refreshes approval status with a non-cacheable call after save and after submit" |
| A latent test bug | `QuoteTriggerTest.lines_cannotChangeAfterApproval_withoutOverridePermission` previously ran as the admin runner, whose break-glass permission bypasses the lock it was asserting; it now runs as the rep |

## LWC unit tests (Jest)

| Suite | What it proves |
|---|---|
| `quoteConfigurator.test.js` | No-account guidance; load errors rendered; discount/term limits come from the server; preview is debounced and sends the expected draft; a slow stale response cannot overwrite a newer one; over-limit discount blocks preview and save; bundle options (required preselected/locked, optional toggled into the draft); removing the last line clears the preview; save and submit refresh through the non-cacheable Apex method; server errors are shown |
| `quoteApprovalPanel.test.js` | Currency from the server; server-supplied minimum rejection length enforced before Apex is called; approve refreshes the wire and the record page and toasts; failed decision keeps the comment and shows the reason; non-approvers see no decision controls; convert navigates to the order and ERP errors are shown; load errors |
| `quoteFormat.test.js` | Badge mapping, currency/percent formatting, discount validation, error message extraction |

Wire adapters are mocked with `createApexTestWireAdapter`; imperative Apex, `lightning/navigation` and `lightning/uiRecordApi` with `jest.mock`.

## RevOps Lab tests

Same principles, applied to `revops-lab/`. Apex tests run as persona users created in `SalesLabTestFactory` (role +
only the shipped lab permission sets) inside `System.runAs`, so sharing (role hierarchy, the Finance criteria sharing rule)
and FLS are exercised rather than bypassed by an administrator runner.

| Test class | Covers |
|---|---|
| `ProductPricingServiceTest` | list price, family and billing frequency stamped from the price book; a product without a price or price book reported per line; the trigger overwrites a client-supplied list price; 200 lines across quotes with constant queries |
| `DiscountPolicyServiceTest` | current policy wins and expired policies are ignored; a family without a policy allows no discount; tiers by discount and by deal size; policy records need the manage permission and valid dates/range |
| `SalesQuoteServiceTest` | preview totals and approval requirement; over-policy discount or bad quantity rejected per line; save creates quote + lines, rolls up and sets the primary quote; invalid draft saves nothing; validation rule rejects an over-policy direct insert; lines locked after submission; status/system fields not directly editable; price book fixed once lines exist |
| `SalesQuoteApprovalServiceTest` | auto-approval updates the opportunity (flow); tier 1 manager via role hierarchy, tier 2 Finance via the sharing rule, tier 3 director; rejection needs a comment and creates a follow-up task (flow); only the assigned approver decides; recall by owner only; a manager who can see but does not own cannot submit; approval rows not editable outside the service; 50 quotes submitted with constant queries |
| `OrderConversionServiceTest` | Order, OrderItems and subscriptions created and ERP sync queued; PO number required; unapproved quote refused; non-owner refused; Closed Won requires an ordered primary quote |
| `SalesERPIntegrationServiceTest` | 201 marks the order synced and logs; JSON with correlation and idempotency headers and no credentials; 409 with order number is success; 422 permanent; 5xx retried with back-off; timeout retryable until retries are exhausted; missing ERP account number fails without a callout; integration-user persona; manual sync needs the custom permission; back-off grows and is capped |
| `SalesIntegrationLogServiceTest` | redaction of credential-like properties; truncation; one row per entry; flush never throws when the user cannot create logs |
| `SalesControllersTest` | context and catalogue with policy caps; preview, save and submit through the controller; approval summary; decide and convert; errors translated without leaking internals |

Jest (17 tests): `salesQuoteConfigurator` (catalogue load, debounced preview, stale-response guard, client-side policy
error, save and submit), `salesApprovalPanel` (approver controls, comment rule, recall, convert with PO number, errors),
`salesFormat` (formatting and validation helpers).

## Test classes

Apex: `DiscountEvaluationServiceTest`, `QuoteCalculationServiceTest`, `ProductConfigurationServiceTest`, `QuoteApprovalServiceTest`, `QuoteTriggerTest`,
`ERPIntegrationServiceTest`, `IntegrationLogServiceTest`, `QuoteControllersTest`, `QuoteOrderServiceTest`, `LoggerTest`, `AsyncJobsTest`; shared `TestDataFactory`.

## Known gaps

* Apex has not been executed in either layer (see the top of this page and [ORG-VALIDATION.md](ORG-VALIDATION.md)).
* No UI/end-to-end test (e.g. UTAM/Playwright against a scratch org).
* Concurrency (two approvers racing) relies on `FOR UPDATE` and is not simulated.
* Tests use the Standard User profile plus permission sets; org-specific profile customisation could change results.
* The runner needs `QF_Admin` (assigned in `@TestSetup` via `grantRunnerAdminAccess`) because new-field FLS is not granted by deployment.
* The chained purge of `Application_Log__c` is tested directly rather than through the chain (one batch per test method).

## Running

```bash
npm ci
npm run lint && npm run prettier:verify && npm run test:unit:coverage && npm run check:fls

sf project deploy start --source-dir force-app --target-org <alias>      # or --source-dir revops-lab
sf apex run test --test-level RunLocalTests --code-coverage --output-dir test-results --wait 30 --target-org <alias>
python3 scripts/ci/check_coverage.py test-results --min-class 85 --min-overall 90
```

Coverage gates: Jest 80% statements/lines/functions and 70% branches (`jest.config.js`); Apex 85% per class and 90% overall
(`scripts/ci/check_coverage.py`), above the platform's 75% org-wide minimum.
