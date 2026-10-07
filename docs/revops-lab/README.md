# QuoteFlow Revenue Operations Lab

A second implementation layer, in its own package directory (`revops-lab/`), that shows hands-on Salesforce Platform
configuration and development around a standard Sales Cloud quote-to-order process:

```
Account -> Opportunity -> Products (Price Book Entries) -> Quote Configuration -> Approval -> Order -> Subscription -> ERP
```

It sits **next to** the main QuoteFlow CPQ implementation in `force-app/`, which is unchanged in scope. The two layers do
different jobs:

| | Main layer (`force-app/`) | RevOps Lab (`revops-lab/`) |
|---|---|---|
| Purpose | Custom CPQ engine: bundles, options, configuration rules, contracted prices, multi-level approvals, idempotent ERP sync | Sales Cloud platform skills: standard objects, roll-up summaries, validation rules, record-triggered flows, custom metadata, persona security, a compact Apex service layer, two LWCs |
| Style | Mostly code (Apex services own the rules) | Declarative first, Apex where code is the right tool |
| Deploys to | Scratch org (pipeline) | Developer Edition org, Trailhead Playground or scratch org, on its own |

## Status - read this first

| Category | What it means | What is in it |
|---|---|---|
| **Implemented in a development org** | Deployed and checked in a real org, with evidence recorded in [ORG-VALIDATION.md](../ORG-VALIDATION.md) | **Nothing yet.** Every checklist item starts as NOT VERIFIED. Move items here only after you run them. |
| **Deployable source, not yet org-verified** | Complete Salesforce DX source written to deploy; checked locally only (Apex parse, XML well-formed and in schema order, static FLS check, LWC Jest) | Everything under `revops-lab/` |
| **Designed / documented only** | Not deployable source; needs manual setup in an org | Named/External Credential for the ERP (`docs/revops-lab/config-specs`), user records, role and permission-set-group assignments, Lightning page placement, scheduling the sync job |

The CPQ managed package (`SBQQ__`) is **not installed or used** anywhere in this repository. How the lab and the main
layer map to it is explained in [CPQ-IMPLEMENTATION-MAPPING.md](../CPQ-IMPLEMENTATION-MAPPING.md).

## What is in `revops-lab/`

| Area | Components |
|---|---|
| Standard objects (extended) | Account (`Customer_Segment__c`, `ERP_Account_Number__c`), Contact (`Buying_Role__c`), Opportunity (`Primary_Quote_Configuration__c`), Product2 (`Billing_Frequency__c`, `ERP_Item_Code__c`), Pricebook2 (`Sales_Region__c`), Order (`Quote_Configuration__c`, `ERP_*`) |
| Custom objects | `Quote_Configuration__c` (+ child `Quote_Configuration_Line__c`), `Sales_Approval_Request__c`, `Discount_Policy__c`, `Sales_Integration_Log__c`, `Sales_Subscription__c` |
| Declarative logic | 4 roll-up summary fields + formula fields, 15 validation rules, 4 record-triggered flows, 2 custom metadata types with records |
| Security | 4 roles, 7 permission sets, 6 permission set groups, 3 custom permissions, 1 criteria-based sharing rule |
| UI | `RevOps Lab` Lightning app, 5 tabs, 6 page layouts, LWCs `salesQuoteConfigurator` and `salesApprovalPanel` (+ `salesFormat` helper) |
| Apex | `SalesQuoteSelector`, `SalesQuoteService`, `ProductPricingService`, `DiscountPolicyService`, `SalesQuoteApprovalService`, `OrderConversionService`, `SalesERPIntegrationService`, `SalesIntegrationLogService`, queueable + schedulable, 3 triggers with handlers, 2 controllers, 8 test classes + `SalesLabTestFactory` |
| Tests | Apex: 8 test classes (not yet executed in an org). LWC: 17 Jest tests (pass locally). |

### Naming: why three names differ from the brief

Apex has no namespaces inside one org, and the main layer already owns `QuoteApprovalService`, `ERPIntegrationService`,
`IntegrationLogService` and the objects `Approval_Request__c`, `Integration_Log__c`, `Subscription__c`. So that both
layers can be deployed to the same org, the lab uses:

| Requested | Lab name |
|---|---|
| QuoteApprovalService | `SalesQuoteApprovalService` |
| ERPIntegrationService | `SalesERPIntegrationService` |
| IntegrationLogService | `SalesIntegrationLogService` |
| Approval Request / Integration Log / Subscription objects | `Sales_Approval_Request__c` / `Sales_Integration_Log__c` / `Sales_Subscription__c` |
| SalesQuoteService, DiscountPolicyService, ProductPricingService, OrderConversionService, Quote Configuration, Discount Policy | unchanged |

## The process, end to end

1. **Account and Opportunity** (standard). The opportunity carries the price book.
2. **Quote Configuration** created from the opportunity with `salesQuoteConfigurator`. A before-save flow defaults account,
   price book and expiry. Each line is priced by the trigger from the price book entry and capped by the active
   `Discount_Policy__c` for its product family; validation rules then reject anything outside the cap.
3. **Totals** are native roll-up summary fields over line formula fields: no Apex roll-up code.
4. **Submit** (`SalesQuoteApprovalService`): the highest `Approval_Routing__mdt` tier that applies (by discount or deal size)
   picks the approver - the owner's manager, the Finance Manager role or the Sales Director role - or approves
   automatically. A flow gives the approver a task.
5. **Decide** in `salesApprovalPanel`: only the assigned approver; rejection needs a comment (Apex and a validation rule).
   Approval moves the opportunity to *Negotiation/Review* (flow); rejection creates a follow-up task (flow).
6. **Convert** (`OrderConversionService`): approved quote + customer PO -> Order and OrderItems (user mode),
   Sales Subscriptions for annual products, order queued for the ERP.
7. **ERP sync** (`SalesERPIntegrationService`): scheduled as the integration user; JSON over a Named Credential with
   correlation id, idempotency key, status classification, back-off and a log row per call.
8. **Close** the opportunity: a validation rule only allows *Closed Won* once the primary quote is ordered.

Details: [AUTOMATION.md](AUTOMATION.md) (every rule, flow and trigger), [SECURITY.md](SECURITY.md) (personas and why),
[FIELD-LEVEL-SECURITY.md](FIELD-LEVEL-SECURITY.md) (generated matrix), [INTEGRATION.md](INTEGRATION.md) (REST/JSON).

## Deploying it

Exact commands are in [SALESFORCE-CLI.md](../SALESFORCE-CLI.md). In short:

```bash
sf org login web --alias revops-dev
sf project deploy start --source-dir revops-lab --target-org revops-dev --wait 30
sf org assign permset --name Sales_Lab_Base --name Sales_Administrator_Access --target-org revops-dev
sf apex run --file scripts/apex/seed-revops-lab.apex --target-org revops-dev
sf apex run test --class-names SalesQuoteServiceTest --class-names SalesQuoteApprovalServiceTest --result-format human --code-coverage --target-org revops-dev --wait 20
```

Then add `salesQuoteConfigurator` to the Opportunity record page and `salesApprovalPanel` to the Quote Configuration
record page in Lightning App Builder, and work through [ORG-VALIDATION.md](../ORG-VALIDATION.md).

Prerequisites in the target org: Orders enabled (Setup > Order Settings), the standard StageName value
*Negotiation/Review* (present in new Developer Edition orgs), and the *Standard User* profile for the test users.

## Known limitations (deliberate, for scope)

* Single-step approval (one tier's approver), unlike the main layer's sequential multi-level approvals.
* Changing the quote price book is blocked once lines exist rather than re-pricing them.
* Annual lines are priced per year; the term only sets the subscription end date.
* Unexpected controller errors are logged to the debug log only; the main layer shows the persistent-logging pattern.
* The ERP idempotency key is per order; the main layer shows the generation-scoped key needed for operator re-sends.
