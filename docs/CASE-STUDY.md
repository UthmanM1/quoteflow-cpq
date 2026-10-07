# Case Study: QuoteFlow CPQ and the Revenue Operations Lab

> A **portfolio project** that demonstrates Salesforce platform and CPQ-style engineering skills. The company, ERP,
> people and data are fictional. It is not a client engagement, it has not been deployed to production, the Salesforce
> CPQ managed package was not used, and it makes no claim about certifications or years of experience.

## How to read the status of anything in this case study

| Status | Meaning | Today |
|---|---|---|
| **Implemented in development org** | Deployed to a Developer Edition / Trailhead / scratch org and checked, with evidence in [ORG-VALIDATION.md](ORG-VALIDATION.md) | **Nothing yet.** Items move here only after the checklist is run. |
| **Designed / documented but not org-verified** | Written as deployable source (or as a specification) and checked only locally | Everything described below |

Locally verified (and therefore stated as such): Apex parses and is formatted; metadata XML is well-formed and in schema
order; a static check confirms every user-mode query is readable by the personas that run it; 39 LWC Jest tests pass.
Not yet verified: Apex compilation against an org, Apex test results, LWC behaviour inside Lightning, CI pipeline runs.

## 1. Business problem

A fictional vendor sells a software platform, add-ons, implementation services and hardware. Reps quote in spreadsheets:
prices drift from the price book, discounts are granted without consistent approval, approved deals are re-keyed into the
ERP, and nobody can see why a quote is stuck. The brief: configure, price, discount, approve, order and synchronise, with
an audit trail and no way to bypass policy.

## 2. Architecture

Two layers in one repository, deployable independently:

* **Main QuoteFlow layer (`force-app/`)** - a custom CPQ engine: bundles and options, configuration rules, a pricing waterfall
  with volume tiers and contracted prices, sequential multi-level approvals, idempotent ERP sync with leases.
* **Revenue Operations Lab (`revops-lab/`)** - a Sales Cloud build: standard Account/Opportunity/Product/Price Book/Order
  extended with custom objects, roll-ups, validation rules, flows and a compact Apex service layer.

Both follow the same shape: triggers delegate to handlers, one selector per layer owns all SOQL in user mode, services hold
the rules and the authorisation checks, controllers only shape DTOs, policy lives in data or metadata depending on who changes
it. [ARCHITECTURE.md](ARCHITECTURE.md), [revops-lab/README.md](revops-lab/README.md).
*Status: designed / documented, not org-verified.*

## 3. Salesforce configuration

Lab: 5 custom objects plus a line object; fields on six standard objects; 4 roll-up summary fields over formula fields;
15 validation rules (including `$Permission` checks and a cross-object Closed Won rule); 4 record-triggered flows (before-save
defaults, approver task, opportunity stage update, rejection follow-up); 2 custom metadata types; a Lightning app, tabs and
page layouts. Every item and its purpose: [revops-lab/AUTOMATION.md](revops-lab/AUTOMATION.md).
Main layer: custom metadata for discount tiers, approval thresholds, configuration rules and ERP settings; a platform event
for persistent logging.
*Status: deployable source, not org-verified.*

## 4. Apex

Lab services: `SalesQuoteService` (preview and save), `ProductPricingService` (price book pricing, one query for any number of
lines), `DiscountPolicyService` (policy caps from data, approval tiers from metadata), `SalesQuoteApprovalService` (bulk submit,
decide, recall), `OrderConversionService`, `SalesERPIntegrationService`, `SalesIntegrationLogService`.
Main layer services: pricing engine, bundle configuration (bulk, two queries for any number of bundles), multi-level approvals,
order conversion, ERP sync, logging - with one allow-listed elevated writer for system-owned fields.
Techniques that matter: user-mode reads; user-mode DML for user-entered data; system-owned fields read-only through FLS and
written by services after explicit owner/approver checks; savepoints; row locks; constant query counts asserted in tests.
*Status: written and parsed; Apex tests not yet executed in an org.*

## 5. LWC

`salesQuoteConfigurator` (lab): product selection, quantity, discount with the policy cap shown, debounced server preview that
ignores stale responses, approval requirement, summary, client and server validation, save and submit.
`salesApprovalPanel` (lab): amount, requested discount, threshold, approver, status, comments, history; approve/reject with a
server-supplied comment rule, recall, convert with a PO number.
Main layer: `quoteConfigurator` (bundles and options) and `quoteApprovalPanel` (multi-level progress, ERP status).
*Status: 39 Jest tests pass locally; not yet tested inside Lightning.*

## 6. Security

Lab personas - Sales Representative, Sales Manager, Finance Manager, Sales Director, Integration User, Administrator - each with
a permission set group, generated from one matrix together with the FLS document. Role hierarchy for the sales line, a
criteria sharing rule for Finance, custom permissions checked in validation rules and Apex, and a table of who can create, edit,
submit, approve, convert and run the ERP sync, with the reason for each ([revops-lab/SECURITY.md](revops-lab/SECURITY.md)).
Main layer: Apex managed sharing for approvers with revocation, and an elevated writer instead of a sharing rule
([SECURITY.md](SECURITY.md)).
*Status: deployable source, not org-verified.*

## 7. CPQ mapping

Each `SBQQ__` concept (quote, quote line, product option, discount schedule, contracted price, product rule, price rule) is
mapped to the main layer and the lab and labelled NATIVE CPQ, PLATFORM CONFIGURATION, CUSTOM APEX, CUSTOM LWC or INTEGRATION
([CPQ-IMPLEMENTATION-MAPPING.md](CPQ-IMPLEMENTATION-MAPPING.md)). The managed package itself is discussed, not implemented.

## 8. Integration

Order push to a fictional ERP over a Named Credential: typed JSON, correlation id, idempotency key, status classification
(409 with an order number = idempotent success), back-off persisted on the record, one sanitised log row per attempt, callouts
before DML. The main layer adds leases and generation-scoped keys ([revops-lab/INTEGRATION.md](revops-lab/INTEGRATION.md),
[INTEGRATION.md](INTEGRATION.md)).
*Status: tested only with `HttpCalloutMock` in Apex tests not yet executed; no real endpoint exists.*

## 9. Testing

Apex: 19 test classes and two factories. Tests run as real personas (with roles and only the shipped permission sets), assert
query budgets for bulk paths, cover every HTTP outcome with mocks, and include a regression test for each defect found in the
[principal architect review](PRINCIPAL-REVIEW.md). LWC: 6 Jest suites, 39 tests. Coverage gates for both.
*Status: Jest passes locally; Apex not yet executed.*

## 10. CI/CD

Pull requests: lint, Prettier, Jest, persona FLS check, metadata order check, generator drift check, PMD, then a throw-away
scratch org with both layers deployed and all local Apex tests run behind a coverage gate. Releases: validate against
production, deploy the same commit to UAT, approve, quick-deploy that exact validation. CLI commands for working against a
single developer org: [SALESFORCE-CLI.md](SALESFORCE-CLI.md).
*Status: pipelines designed; never run.*

## 11. Lessons learned (from building this project)

* **Test as the persona.** The worst defects found in review - approvers blocked by sharing, an integration user that could
  read but not write, a selector missing a field - were invisible to tests running as an administrator.
* **Know which platform layer enforces what.** Plain DML skips CRUD/FLS but not sharing in a `with sharing` class; View All is
  read-only; custom validation rules run after before triggers, so a trigger can stamp a value a rule then judges.
* **Policy has an owner.** Values Finance changes weekly are data (`Discount_Policy__c`); values that change with a release are
  custom metadata (`Approval_Routing__mdt`).
* **Make the unsafe path impossible.** FLS stops people; triggers and validation rules stop API clients; services check who
  is acting.
* **Design for the retry first.** Idempotency keys and persisted back-off simplified everything after them.
* **Verification is a deliverable.** A parse and a Jest run catch some mistakes, not behaviour in an org; the repository
  separates what is verified from what is not, and ORG-VALIDATION.md is where that changes.
* **A correction:** an earlier version of these docs claimed a standard object cannot be the master of a custom detail. That is
  wrong: Account, Opportunity and other standard objects can be masters, and the lab uses Account as the master of
  `Sales_Subscription__c`. The main layer's lookups to standard objects are a choice (independent Private sharing), not a constraint.
