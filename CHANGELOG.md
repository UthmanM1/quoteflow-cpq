# Changelog

## 1.2.0 - QuoteFlow Revenue Operations Lab

A second, independent package directory (`revops-lab/`) that builds a Sales Cloud quote-to-subscription process. The main
`force-app/` layer is unchanged in architecture. Nothing in this release has been deployed to an org yet; see
[docs/ORG-VALIDATION.md](docs/ORG-VALIDATION.md).

### Added
- Lab data model: `Quote_Configuration__c` (+ `Quote_Configuration_Line__c`), `Sales_Approval_Request__c`, `Discount_Policy__c`,
  `Sales_Integration_Log__c`, `Sales_Subscription__c`; fields on Account, Contact, Opportunity, Product2, Pricebook2 and Order.
- 15 validation rules, 4 record-triggered flows, 4 roll-up summaries, `Approval_Routing__mdt`, `Sales_ERP_Setting__mdt`,
  Lightning app, tabs and layouts.
- Security: 4 roles, 7 permission sets, 6 permission set groups, 3 custom permissions, a criteria sharing rule, all permission
  sets generated from one matrix (`scripts/revops-lab/generate_security.py`) together with the FLS document.
- Apex: selector, 7 services, 3 trigger handlers, 2 controllers, queueable/schedulable ERP dispatch, 8 test classes + factory.
- LWC: `salesQuoteConfigurator`, `salesApprovalPanel`, `salesFormat`, with 17 Jest tests.
- ERP integration contract and sample payloads (`docs/revops-lab/samples/`), Named Credential specification.
- Docs: `SALESFORCE-CLI.md`, `ORG-VALIDATION.md` (every item NOT VERIFIED), `CPQ-IMPLEMENTATION-MAPPING.md`,
  `INTERVIEW-DEMO.md`, `PORTFOLIO-EVIDENCE.md`, rewritten `CASE-STUDY.md`, lab docs under `docs/revops-lab/`; TD-21.
- CI: metadata schema-order check (`scripts/ci/normalize_metadata.py`), generator drift check, FLS check for both layers;
  the PR scratch org deploys both package directories.

### Changed
- Metadata XML in both layers normalised to schema element order.
- `check_fls.py` covers both layers.

### Corrected
- Docs previously stated that a standard object cannot be the master of a custom detail object. That is wrong; the main
  layer's lookups to standard objects are a design choice (ARCHITECTURE.md, TD-10, CASE-STUDY.md).
- README setup used a non-existent `sf org assign permsetgroup` command.

## 1.1.0 - principal architect review

Driven by [docs/PRINCIPAL-REVIEW.md](docs/PRINCIPAL-REVIEW.md) (15 strengths, 15 weaknesses, each mapped to files and tests).

### Fixed (runtime defects reasoned from platform behaviour; not yet observed in an org)
- Approvers with Read-only access (Apex share or sharing rule) could not record decisions: `with sharing` services used plain DML. System-owned writes now go through `QuoteStateWriter`.
- The integration user could not write lease/outcome state (View All is read-only), so ERP sync never happened; failures were swallowed. Writes now go through the writer and only persisted leases are dispatched.
- `QuoteOrderService.convert` read `Opportunity__c` without querying it. Converted (Ordered) quotes no longer drop out of ERP sync.
- Submit, recall and convert enforced ownership only in the UI; the services now enforce it.
- Deleting a bundle header orphaned its components; the delete now cascades.
- A trigger test asserted the quote lock while running as a user holding the break-glass permission.
- CI could not start (no lockfile, ESLint peer conflict, unformatted Apex for the Prettier check).

### Added
- `QuoteStateWriter` (single allow-listed elevated writer), `Logger` + `Log_Event__e` + `Application_Log__c`, `ERP_Sync_Generation__c`, `QF_Requeue_ERP_Sync`.
- Bulk `ProductConfigurationService.configureAll` (two queries for any number of bundles).
- Approver share revocation on recall/resubmission.
- `quoteFormat` LWC service module, server-supplied policy limits and currency, non-cacheable post-mutation refresh, `lwc:if` templates.
- Jest suites (22 tests), persona and regression Apex tests (`LoggerTest`, `AsyncJobsTest` and additions to every test class), `Assert` class throughout.
- PR pipeline with scratch org per PR and coverage gates; release pipeline validate → UAT → approval → quick deploy of the same validation.
- `scripts/ci/check_fls.py`, `scripts/ci/check_coverage.py`.

### Changed
- `QF_Integration_User` is read-only on `Quote__c`; `QF_Admin` gains application-log access and the requeue permission.
- `IntegrationLogPurgeBatch` purges both log objects and is scheduled by an administrator.
- Documentation updated throughout; Technical decisions TD-17 to TD-20 added.
