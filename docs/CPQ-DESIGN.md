# CPQ Design: Standard CPQ Configuration vs Custom Development

QuoteFlow models Configure-Price-Quote concepts on **custom objects** so the repository deploys to any Developer Edition or scratch
org without a Salesforce CPQ licence (TD-01). This page maps each concept to what a team on **Salesforce CPQ (`SBQQ__` managed package)**
would configure, and to what is custom development in both worlds. That distinction is the point of the document.

Legend: **CONFIG** = standard CPQ configuration (admin, no code). **CUSTOM** = Apex/LWC/integration development.

| Capability | In a real Salesforce CPQ org | In this repository | Classification |
|---|---|---|---|
| Quote and quote line | `SBQQ__Quote__c`, `SBQQ__QuoteLine__c` (+ Quote Line Editor) | `Quote__c`, `Quote_Line__c`, `quoteConfigurator` LWC | Real CPQ: **CONFIG**. Here: **CUSTOM** |
| Product bundles | Bundle product (`SBQQ__ConfiguredSKU__c`), Product Features | `Product2.Product_Type__c = Bundle` | **CONFIG** in CPQ / custom model here |
| Product options | `SBQQ__ProductOption__c` (required, quantity, min/max, selected, bundled) | `Product_Option__c` (`Is_Required__c`, `Price_Treatment__c`, min/max/default) | **CONFIG** / custom model here |
| Configuration rules | Product Rules (Validation, Selection, Alert, Filter) | `Configuration_Rule__mdt` (Requires/Excludes) evaluated by `ProductConfigurationService.validate` | **CONFIG** / **CUSTOM** here |
| Pricing rules | Price Rules + Price Conditions + Price Actions | Pricing waterfall in `QuoteCalculationService` | **CONFIG** / **CUSTOM** here |
| Discount schedules | `SBQQ__DiscountSchedule__c` + Discount Tiers (Range/Slab) | `Discount_Rule__mdt` evaluated by `DiscountEvaluationService` | **CONFIG** / **CUSTOM** here |
| Contracted pricing | `SBQQ__ContractedPrice__c` | `Contracted_Price__c` + guarded read in `QuoteSelector` | **CONFIG** / **CUSTOM** here |
| Approval thresholds | Advanced Approvals (`sbaa__ApprovalRule__c`, chains, conditions, delegation) | `Approval_Threshold__mdt` + `QuoteApprovalService` + `Approval_Request__c` | **CONFIG** / **CUSTOM** here |
| Quote lifecycle | Quote status, `SBQQ__Ordered__c`, Contracted | `Status__c` graph enforced by `QuoteTriggerHandler` | **CONFIG** + light automation / **CUSTOM** here |
| Quote -> Order / Contract / Subscription | "Ordered" checkbox + order and contract generation, `SBQQ__Subscription__c` | `QuoteOrderService` creates Order, OrderItems, `Subscription__c` | **CONFIG** / **CUSTOM** here |
| Quote document | Quote Templates | Not implemented | **CONFIG** in CPQ |
| Calculation customisation | Quote Calculator Plugin (JavaScript QCP) | Apex services | **CUSTOM** in both |
| ERP synchronisation | Not provided | `ERPIntegrationService` | **CUSTOM** in both |
| Rich configurator UX | Standard Configurator / Quote Line Editor (customisable) | `quoteConfigurator`, `quoteApprovalPanel` | **CUSTOM** in both when the standard UI is not enough |
| Persona security | Package permission sets | `QF_*` permission sets and groups | **CONFIG** in both |

## What would remain custom development on a real CPQ implementation

1. ERP/order management integration (payload mapping, idempotency, retry, monitoring).
2. Quote Calculator Plugin logic for pricing the standard rules cannot express (aggregate tiering across lines, cross-product bundles).
3. Approval extensions: auto-escalation, delegated approval rules beyond Advanced Approvals, Slack/Teams notifications.
4. Custom LWC for experiences the Quote Line Editor cannot deliver; integration with `SBQQ.QuoteAPI` rather than writing quote lines directly.
5. Data migration, test automation and CI/CD around the package (CPQ metadata must be deployed as data, not metadata).
6. Guardrails: triggers on `SBQQ__` objects must respect the package's calculation sequence; heavy automation on quote lines is the commonest cause of CPQ performance problems.

## Lifecycle implemented here

```
Draft --submit--> Approved                (within policy, Approval_Status = Not Required, ERP = Pending)
Draft --submit--> Pending Approval --level N approved--> Approved   (ERP = Pending)
Pending Approval --reject--> Rejected --edit/resubmit--> Pending Approval | Approved
Pending Approval --recall--> Draft
Approved --convert--> Ordered             (Order, OrderItems, Subscriptions)
Draft | Rejected | Approved --> Cancelled
```
Lines and commercial header fields are locked outside Draft/Rejected (override: `QF_Override_Quote_Lock`).

## Pricing worked example

50 seats at list 120/yr, 10% manual discount, 24-month term, no contract: schedule tier 10% (25-99), effective discount
1 - 0.9 x 0.9 = 19%, net unit 97.20, net total 97.20 x 50 x 24/12 = 9,720.00. Maximum line discount 19% exceeds the 10% level-1
threshold, so the quote needs manager approval. Had the account held a 100.00 contracted price, base would be 100.00, schedule discount
would not stack, and a 10% manual discount would give effective 10% (not above the threshold).
