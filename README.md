# QuoteFlow CPQ

**B2B Sales and Configure-Price-Quote platform on Salesforce - portfolio demonstration**

> **Read this first.** QuoteFlow CPQ is a *demonstration project* for a fictional software vendor. It is not a client system and has not been
> implemented for any real company. Configuration that needs a live org (Named/External Credential, users, roles, schedules) is provided as a
> design specification. The Apex has been **parsed and statically checked, not deployed or executed**; the LWC Jest suite has been run locally.
> See [Verification status](#verification-status) and the [principal architect review](docs/PRINCIPAL-REVIEW.md) that drove the current revision.
> The Salesforce CPQ managed package (`SBQQ__`) is **not** installed or used; CPQ concepts are implemented as custom code and mapped in
> [CPQ-IMPLEMENTATION-MAPPING.md](docs/CPQ-IMPLEMENTATION-MAPPING.md). No certification or professional track record is claimed by this repository.

## Two layers

| Layer | Folder | What it shows | Status |
|---|---|---|---|
| **QuoteFlow CPQ (main)** | `force-app/` | A custom CPQ engine in Apex/LWC: bundles and options, configuration rules, pricing waterfall, contracted prices, multi-level approvals with Apex managed sharing, idempotent ERP sync with leases | Source parsed and statically checked; not yet deployed |
| **Revenue Operations Lab** | `revops-lab/` | A Sales Cloud build on standard Account/Opportunity/Product/Price Book/Order: custom objects, roll-ups, 15 validation rules, 4 record-triggered flows, custom metadata, personas with permission set groups, role hierarchy and a sharing rule, a compact Apex service layer and two LWCs | Source parsed and statically checked; designed to deploy to a Developer Edition org; **not yet deployed** - see [ORG-VALIDATION.md](docs/ORG-VALIDATION.md) |

The layers share no code and deploy independently (`sfdx-project.json` lists both package directories). Lab details:
[docs/revops-lab/README.md](docs/revops-lab/README.md). The rest of this README describes the main layer unless it says otherwise.

## Project overview

QuoteFlow lets sales reps turn an opportunity into an approved, ERP-synchronised order: select products and bundles, configure options, price with
volume schedules and contracted prices, apply discounts, route over-threshold discounts for approval, convert approved quotes into orders and subscriptions,
and track status end to end.

## Business problem

Quoting in spreadsheets causes price drift, inconsistent discount approvals, re-keyed ERP orders and no audit trail. QuoteFlow centralises pricing policy
(as deployable metadata), enforces the approval policy in code, and automates the hand-off to the ERP.

## Architecture

```
Opportunity -> quoteConfigurator (LWC) -> QuoteConfiguratorController -> ProductConfigurationService
                                                                      -> QuoteCalculationService -> DiscountEvaluationService
Quote_Line__c trigger -> QuoteLineTriggerHandler -> QuoteCalculationService (price in memory, roll up totals)
Quote__c / quoteApprovalPanel (LWC) -> QuoteApprovalController -> QuoteApprovalService -> Approval_Request__c
Approved quote -> ERPSyncScheduler -> ERPSyncQueueable -> ERPIntegrationService -> callout:ERP_Gateway -> IntegrationLogService

System-owned fields (totals, approval state, ERP bookkeeping) -> QuoteStateWriter   (the single elevated write path)
Unexpected errors -> Logger -> Log_Event__e (publish immediately) -> LogEventTrigger -> Application_Log__c
```
Full documentation: [Architecture](docs/ARCHITECTURE.md), [Data model](docs/DATA-MODEL.md).

## Technology stack

Salesforce Sales Cloud (API 62.0), Apex (triggers, services, Queueable, Schedulable, Batchable), Lightning Web Components, Custom Metadata Types, Platform Events, Record-triggered Flow,
Named/External Credentials (OAuth 2.0), REST/JSON, Permission Sets and Permission Set Groups, Apex managed sharing, Salesforce CLI, GitHub Actions, Jest (`sfdx-lwc-jest`), ESLint, Prettier, PMD.

## Features

* Opportunity-embedded configurator: catalogue search, bundles with required/optional/included options, quantities, per-line discount, live server-priced preview, validation, approval hint
* Pricing: list vs contracted price, volume discount schedules, compounding manual discount, term scaling for subscriptions, included components
* Rule-driven bundle validation (required options, min/max, requires/excludes)
* Multi-level, sequential approvals by discount threshold with manager or role-based approvers, row-locked decisions, recall, resubmission, full history
* Approval panel with threshold progress, approver, comments and ERP status
* Quote -> Order, OrderItems and Subscriptions
* Idempotent ERP sync with retry, back-off, correlation ids and a sanitised audit log
* Lifecycle locking so approved quotes cannot be altered without a break-glass permission
* Persistent application log (survives rollback) behind every support reference shown to users

## Salesforce components

| Area | Components |
|---|---|
| Apex services | `QuoteCalculationService`, `DiscountEvaluationService`, `QuoteApprovalService`, `ProductConfigurationService`, `ERPIntegrationService`, `IntegrationLogService`, `QuoteOrderService`, `QuoteSharingService` |
| Data access / writes | `QuoteSelector` (all reads, user mode), `QuoteStateWriter` (the only elevated write path, field allow-listed) |
| Support | `QuoteConstants`, `QuoteTriggerContext`, `QuoteFlowException`, `AuraErrorFactory`, `Logger` |
| Triggers + handlers | `QuoteTrigger`, `QuoteLineTrigger`, `ApprovalRequestTrigger`, `LogEventTrigger` and their handlers |
| Controllers | `QuoteConfiguratorController`, `QuoteApprovalController` |
| Async | `ERPSyncScheduler`, `ERPSyncQueueable`, `IntegrationLogPurgeBatch` |
| LWC | `quoteConfigurator`, `quoteApprovalPanel`, `quoteFormat` (shared service module), each with Jest tests |
| Objects | `Quote__c`, `Quote_Line__c`, `Approval_Request__c`, `Product_Option__c`, `Contracted_Price__c`, `Integration_Log__c`, `Application_Log__c`, `Subscription__c`; platform event `Log_Event__e`; extended Account, Contact, Opportunity, Product2, Pricebook2, Order |
| Custom Metadata | `Discount_Rule__mdt`, `Approval_Threshold__mdt`, `Configuration_Rule__mdt`, `ERP_Integration_Setting__mdt` (+ records) |
| Security | 6 permission sets, 4 permission set groups, 4 custom permissions, roles, `QF Finance` group, sharing rule |
| Flow | `QF_Quote_Rejection_Follow_Up` (ships as Draft) |

Repository layout:

```
force-app/main/default/
  classes/ triggers/ lwc/ objects/ flows/ permissionsets/ permissionsetgroups/
  customMetadata/ customPermissions/ roles/ groups/ sharingRules/
docs/            architecture, security, integration, testing, deployment, decisions, review, case study, samples, config-specs
tests/           pointer to the Apex test classes (Salesforce requires tests to live with the classes)
revops-lab/main/default/
  classes/ triggers/ lwc/ objects/ flows/ permissionsets/ permissionsetgroups/ customMetadata/
  customPermissions/ roles/ sharingRules/ applications/ tabs/ layouts/
docs/revops-lab/ lab overview, automation, security, generated FLS matrix, integration contract, samples
scripts/apex/    demo seed data (main layer and lab)
scripts/ci/      persona FLS check (both layers), metadata order check, Apex coverage gate
scripts/revops-lab/  generator for lab permission sets, groups and the FLS document
.github/         workflows, reusable CLI setup action, CODEOWNERS, PR template
```

## Security

Private OWD, hierarchy + Finance sharing rule + Apex sharing for approvers (revoked when a request is superseded), persona permission set groups, read-only calculated
fields enforced by FLS **and** triggers, `WITH USER_MODE` reads, authorisation checked in the services (not only in the UI), one named elevated writer (`QuoteStateWriter`)
for system-owned fields, a read-only least-privilege integration user, no secrets in source. See [SECURITY.md](docs/SECURITY.md).

## Testing

Main layer - Apex: eleven test classes plus `TestDataFactory`, covering pricing boundaries, bulk query/DML budgets, approval journeys run as role-less, share-only approvers, the integration
user persona, regression tests for every defect in the review, scripted HTTP mocks and async jobs. LWC: 22 Jest tests across the three bundles (debounce, stale-response guard,
server-supplied policy, non-cacheable refresh, decision flow).
RevOps Lab - Apex: eight test classes plus `SalesLabTestFactory`, run as six personas with roles and only the shipped permission sets; LWC: 17 Jest tests.
See [TESTING.md](docs/TESTING.md).

## CI/CD

PR: lint, Prettier, Jest with a coverage gate, persona FLS check, metadata order and generator drift checks, PMD, then deploy both layers to a throw-away scratch org with `RunLocalTests` and a per-class coverage gate.
`develop` deploys to integration (main layer only). `main` validates against production, deploys the same commit to UAT, waits for approval and quick-deploys exactly that validation.
Shows where Salesforce CLI and a DevOps platform such as Gearset could fit (Gearset was **not** used). See [DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Integration

Asynchronous REST/JSON order push to a fictional ERP via Named Credential; generation-scoped idempotency key, correlation id, status-based retry policy, persisted exponential back-off,
lease-based dispatch that only dispatches leases it actually wrote; converted (Ordered) quotes stay in sync scope.
Samples in [`docs/samples`](docs/samples). See [INTEGRATION.md](docs/INTEGRATION.md).

## Key architectural decisions

Custom quote objects instead of the CPQ package (TD-01), custom approvals (TD-02), policy in Custom Metadata (TD-03), price-in-before-trigger (TD-05), user-mode by default with
named system-mode exceptions behind a single writer (TD-06, TD-17), poll-and-lease dispatch (TD-07), idempotent persisted retry with sync generations (TD-08, TD-19), persistent logging via
Platform Events (TD-18). See [TECHNICAL-DECISIONS.md](docs/TECHNICAL-DECISIONS.md) and
[CPQ-DESIGN.md](docs/CPQ-DESIGN.md) for the standard-CPQ-configuration vs custom-development split.

## Verification status

| Check | Status |
|---|---|
| Apex parses (`prettier-plugin-apex`; main 36 classes + 4 triggers, lab 28 classes + 3 triggers) and is Prettier-formatted | Done (locally) |
| LWC ESLint clean; Jest (39 tests: 22 main, 17 lab) passes locally with coverage above the configured gate | Done (locally) |
| Static persona FLS check (`scripts/ci/check_fls.py`), both layers: every user-mode query is readable by its callers | Done (locally) |
| Metadata XML well-formed and in schema order; lab permission sets match their generator; `npm ci` resolves from the lockfile | Done (locally) |
| Deploy to a scratch org / sandbox | **Not done** |
| Apex tests executed, coverage measured | **Not done** |
| CI pipeline run end to end | **Not done** |
| Generated permission-set FLS reviewed in an org | **Not done** |
| RevOps Lab org checklist (16 items) | **All NOT VERIFIED** - [ORG-VALIDATION.md](docs/ORG-VALIDATION.md) |

Expect a first-run fix-up pass (schema/permission details cannot be proven without an org).

## Getting started (scratch org)

```bash
sf org create scratch -f config/project-scratch-def.json -a quoteflow -d
sf project deploy start --source-dir force-app -o quoteflow
sf org assign permset -n QF_Base_Access -n QF_Admin -o quoteflow     # the same sets QF_Administrator_PSG groups
sf apex run -f scripts/apex/seed-demo-data.apex -o quoteflow
sf apex run test --test-level RunLocalTests --code-coverage -o quoteflow -w 20

npm ci && npm run lint && npm run test:unit && npm run check:fls   # local static checks and LWC tests
```
Then add `quoteConfigurator` to the Opportunity Lightning page and `quoteApprovalPanel` to a Quote page. The ERP credential is specification only, so syncing needs the manual setup in DEPLOYMENT.md.

RevOps Lab in a Developer Edition or Trailhead org (full command reference, including retrieve, package.xml and deployment
status: [SALESFORCE-CLI.md](docs/SALESFORCE-CLI.md)):

```bash
sf org login web --alias revops-dev --set-default
sf project deploy start --source-dir revops-lab --wait 30
sf org assign permset -n Sales_Lab_Base -n Sales_Administrator_Access
sf apex run --file scripts/apex/seed-revops-lab.apex
sf apex run test --test-level RunLocalTests --code-coverage --result-format human --wait 30
```
Record each result in [ORG-VALIDATION.md](docs/ORG-VALIDATION.md); these commands are documented, not yet run.

## Limitations

Custom objects instead of `SBQQ__`; per-line volume tiers; single currency on the ERP payload; no quote document generation; one-way ERP sync against an assumed contract; no Lightning pages
or layouts in source; Apex never executed in an org; see
[ARCHITECTURE-REVIEW.md](docs/ARCHITECTURE-REVIEW.md).

## Future improvements

Execute and harden in a scratch org (first CI run); UI/end-to-end tests; aggregate tiering; alerting on `Application_Log__c` and a circuit breaker for the ERP; inbound ERP webhook;
delegated approvals; quote PDF generation; Shield encryption for logs; permission-diff CI check.

## Documentation index

[Architecture](docs/ARCHITECTURE.md) · [Data model](docs/DATA-MODEL.md) · [Security](docs/SECURITY.md) · [Integration](docs/INTEGRATION.md) · [Testing](docs/TESTING.md) · [Deployment](docs/DEPLOYMENT.md) ·
[Technical decisions](docs/TECHNICAL-DECISIONS.md) · [CPQ design](docs/CPQ-DESIGN.md) · [Principal architect review](docs/PRINCIPAL-REVIEW.md) ·
[Architecture review (register)](docs/ARCHITECTURE-REVIEW.md) · [Case study](docs/CASE-STUDY.md)

RevOps Lab and evidence: [Lab overview](docs/revops-lab/README.md) · [Automation](docs/revops-lab/AUTOMATION.md) ·
[Lab security](docs/revops-lab/SECURITY.md) · [Lab FLS matrix](docs/revops-lab/FIELD-LEVEL-SECURITY.md) ·
[Lab integration](docs/revops-lab/INTEGRATION.md) · [Salesforce CLI](docs/SALESFORCE-CLI.md) ·
[Org validation](docs/ORG-VALIDATION.md) · [CPQ implementation mapping](docs/CPQ-IMPLEMENTATION-MAPPING.md) ·
[Interview demo](docs/INTERVIEW-DEMO.md) · [Portfolio evidence](docs/PORTFOLIO-EVIDENCE.md)
