# Tests

Salesforce requires Apex tests to be deployed with the classes they test, so they live in
`force-app/main/default/classes/` (`*Test.cls`, plus `TestDataFactory.cls`). This folder documents them; strategy is in
[docs/TESTING.md](../docs/TESTING.md).

| Test class | Covers |
|---|---|
| `DiscountEvaluationServiceTest` | tier boundaries, strict thresholds, inactive policy |
| `QuoteCalculationServiceTest` | waterfall, term scaling, contracted price, roll-up, re-pricing, 200-line bulk |
| `ProductConfigurationServiceTest` | options, bounds, requires/excludes rules, line expansion, constant-query bulk configuration |
| `QuoteApprovalServiceTest` | auto-approval, one/two/three-level approval by share-only approvers, rejection, wrong approver, non-owner submit/recall, share revocation, recall, 50-quote bulk |
| `QuoteTriggerTest` | lifecycle enforcement, locking (as the rep), tamper protection incl. ERP fields, writer allow-list, bundle delete cascade, least-privilege checks |
| `ERPIntegrationServiceTest` | HTTP mock scenarios, retry/back-off, leasing, batching, integration-user persona, Ordered quotes, requeue permission and generation, unpersisted outcome logging |
| `IntegrationLogServiceTest` | buffering, redaction, truncation, failure isolation (reported through Logger) |
| `QuoteControllersTest` | DTO shaping, preview, atomic save, many-bundle save, fresh approval summary, error translation and log reference |
| `QuoteOrderServiceTest` | order, items, subscriptions, opportunity link, state guards, non-owner refusal, rep persona, ERP eligibility after conversion |
| `LoggerTest` | persistence via platform event, survives rollback, read-only path, truncation |
| `AsyncJobsTest` | scheduler, queueable failure logging, purge batch for both log objects |

RevOps Lab Apex tests live in `revops-lab/main/default/classes/` (factory `SalesLabTestFactory`): `ProductPricingServiceTest`,
`DiscountPolicyServiceTest`, `SalesQuoteServiceTest`, `SalesQuoteApprovalServiceTest`, `OrderConversionServiceTest`,
`SalesERPIntegrationServiceTest`, `SalesIntegrationLogServiceTest`, `SalesControllersTest`. Descriptions in
[docs/TESTING.md](../docs/TESTING.md#revops-lab-tests).

None of the Apex tests in either layer has been executed in an org yet.

LWC unit tests (Jest) live next to each component in `force-app/main/default/lwc/*/__tests__/` and
`revops-lab/main/default/lwc/*/__tests__/`, and run with `npm run test:unit` (39 tests, passing locally).
