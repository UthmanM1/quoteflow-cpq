# CPQ Implementation Mapping

How Salesforce CPQ concepts map to what this repository actually contains.

> **The Salesforce CPQ managed package (`SBQQ__`) is not installed, configured or used anywhere in this repository.**
> Every `SBQQ__` name below describes how a real CPQ implementation would model the capability. The QuoteFlow objects are
> custom implementations of similar ideas, built so the project deploys to an org without a CPQ licence. They are not
> the managed package, are not compatible with it, and would not be migrated "in place" to it.

## Labels

| Label | Meaning |
|---|---|
| **NATIVE CPQ** | Delivered by the Salesforce CPQ managed package through configuration (records, settings, rules) - discussed here, not implemented |
| **PLATFORM CONFIGURATION** | Standard Salesforce Platform features configured as metadata in this repository (objects, fields, roll-ups, validation rules, flows, custom metadata, security) |
| **CUSTOM APEX** | Apex written in this repository |
| **CUSTOM LWC** | Lightning Web Components written in this repository |
| **INTEGRATION** | Outbound integration code and contracts written in this repository (fictional ERP) |

## The five layers involved

| Layer | What it is | In this repository |
|---|---|---|
| Salesforce Sales Cloud | Standard CRM: Account, Contact, Opportunity, Product2, Pricebook2, PricebookEntry, Order, OrderItem (and a standard Quote object, not used here) | Used and extended by the RevOps Lab (`revops-lab/`) and partly by the main layer |
| Salesforce CPQ managed package | Separately licensed package adding `SBQQ__` objects, the Quote Line Editor, product/price rules, discount schedules, contracted prices, a pricing engine and (with Advanced Approvals) `sbaa__` approvals | **Not used** |
| Custom Apex CPQ implementation | Main QuoteFlow layer (`force-app/`): `Quote__c`, `Quote_Line__c`, bundles and options, configuration rules, pricing waterfall, contracted prices, multi-level approvals | Implemented as source; not yet executed in an org |
| Custom LWC | `quoteConfigurator`, `quoteApprovalPanel` (main); `salesQuoteConfigurator`, `salesApprovalPanel` (lab) | Implemented; Jest-tested locally |
| External ERP integration | Order push to a fictional ERP over a Named Credential | Implemented in both layers against an assumed contract; mocked in tests |

Why the lab uses a custom `Quote_Configuration__c` rather than the standard Sales Cloud `Quote`: the standard object brings
opportunity line-item syncing and its own PDF features, which would add setup without showing more platform skill; the
custom object lets the lab demonstrate master-detail roll-ups, policy validation and a custom approval audit trail. On a
real Sales Cloud project without CPQ, the standard `Quote`/`QuoteLineItem` would be the first option to evaluate.

## Object mapping

### `SBQQ__Quote__c` - quote header

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | `SBQQ__Quote__c` with primary-quote sync to the opportunity, status, quote templates, calculation by the CPQ pricing engine | NATIVE CPQ |
| Main layer | `Quote__c`: lifecycle graph in `QuoteTriggerHandler`, totals rolled up by `QuoteCalculationService`, system fields written only through `QuoteStateWriter` | CUSTOM APEX |
| RevOps Lab | `Quote_Configuration__c`: Private OWD, roll-up summary totals, 6 validation rules, before-save defaulting flow, status changes only through services | PLATFORM CONFIGURATION + CUSTOM APEX |
| UI | `quoteConfigurator` / `salesQuoteConfigurator` create the quote from the opportunity | CUSTOM LWC |

### `SBQQ__QuoteLine__c` - quote line

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | `SBQQ__QuoteLine__c` edited in the Quote Line Editor; list, special, regular, customer and net price fields computed by the package | NATIVE CPQ |
| Main layer | `Quote_Line__c` priced in memory in the before trigger (`QuoteCalculationService.priceLines`): contracted or list base, volume tier, compounding manual discount, term scaling | CUSTOM APEX |
| RevOps Lab | `Quote_Configuration_Line__c`: list price stamped from the price book entry (`ProductPricingService`), totals as formula fields, native roll-up to the header, discount cap enforced by a validation rule | PLATFORM CONFIGURATION + CUSTOM APEX |

### `SBQQ__ProductOption__c` - bundle options

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | `SBQQ__ProductOption__c` linking a bundle (configured SKU) to an optional SKU, with required/selected/bundled flags and quantity bounds; options grouped by product features | NATIVE CPQ |
| Main layer | `Product_Option__c` (`Is_Required__c`, `Price_Treatment__c` Included/Additive, min/max/default quantity), validated and expanded in bulk by `ProductConfigurationService.configureAll` | CUSTOM APEX (data model: PLATFORM CONFIGURATION) |
| RevOps Lab | Not modelled - the lab sells standalone products only | - |
| UI | Option selection in `quoteConfigurator` | CUSTOM LWC |

### `SBQQ__DiscountSchedule__c` - volume discounts

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | Discount schedule with tiers (range or slab) attached to products or price book entries | NATIVE CPQ |
| Main layer | `Discount_Rule__mdt` tiers per product family, applied per line by `DiscountEvaluationService.scheduleDiscountPct` (range, not slab) | PLATFORM CONFIGURATION (custom metadata) + CUSTOM APEX |
| RevOps Lab | No automatic volume tiers. Instead `Discount_Policy__c` sets an effective-dated **maximum** manual discount per family (a guardrail, not a schedule) | PLATFORM CONFIGURATION (data + validation rule) + CUSTOM APEX |

### `SBQQ__ContractedPrice__c` - account-specific prices

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | Contracted prices per account and product, typically created from contracts, applied by the pricing engine | NATIVE CPQ |
| Main layer | `Contracted_Price__c`, read through a narrowly scoped system-mode reader after a `UserRecordAccess` check; overrides list price and suppresses volume tiers | CUSTOM APEX |
| RevOps Lab | Not modelled | - |

### `SBQQ__ProductRule__c` - configuration rules

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | Product rules (validation, selection, alert, filter) with error conditions and actions, scoped to bundles through configuration rules | NATIVE CPQ |
| Main layer | `Configuration_Rule__mdt` (Requires / Excludes between options) evaluated by `ProductConfigurationService` on preview **and** on save | PLATFORM CONFIGURATION (custom metadata) + CUSTOM APEX |
| RevOps Lab | Validation rules play the "validation rule" role at record level (quantity, discount cap, locks, PO before ordering) | PLATFORM CONFIGURATION |

### `SBQQ__PriceRule__c` - price rules

| Where | Implementation | Label |
|---|---|---|
| Salesforce CPQ | Price rules with price conditions and price actions, evaluated at defined points of the calculation sequence | NATIVE CPQ |
| Main layer | The pricing waterfall is code: `QuoteCalculationService` (base price -> schedule -> manual -> term) | CUSTOM APEX |
| RevOps Lab | List price from the price book plus capped manual discount; formulas compute net values | PLATFORM CONFIGURATION + CUSTOM APEX |

## Related capabilities

| Capability | Salesforce CPQ | Main layer | RevOps Lab |
|---|---|---|---|
| Approvals | Advanced Approvals (`sbaa__` package) - NATIVE CPQ (separate package) | `Approval_Threshold__mdt` + `QuoteApprovalService`, sequential multi-level, Apex managed sharing - CUSTOM APEX | `Approval_Routing__mdt` + `SalesQuoteApprovalService`, single tier by discount or deal size, role hierarchy + criteria sharing rule - PLATFORM CONFIGURATION + CUSTOM APEX |
| Quote to order | Ordered flag creates Order/OrderItems; contracts and `SBQQ__Subscription__c` - NATIVE CPQ | `QuoteOrderService` - CUSTOM APEX | `OrderConversionService` - CUSTOM APEX |
| Subscriptions | `SBQQ__Subscription__c` - NATIVE CPQ | `Subscription__c` - CUSTOM APEX | `Sales_Subscription__c` (master-detail to Account) - PLATFORM CONFIGURATION + CUSTOM APEX |
| Configurator UI | Configurator and Quote Line Editor - NATIVE CPQ | `quoteConfigurator` - CUSTOM LWC | `salesQuoteConfigurator` - CUSTOM LWC |
| Calculation extension | Quote Calculator Plugin (JavaScript) - custom code inside CPQ | Apex services - CUSTOM APEX | Apex services - CUSTOM APEX |
| ERP order push | Not provided by CPQ | `ERPIntegrationService` - INTEGRATION | `SalesERPIntegrationService` - INTEGRATION |

## What would change on a real CPQ project

* Quote, line, option, schedule, contracted price, product and price rules become package configuration, deployed as
  **data** (records), not metadata - which changes the CI/CD approach (data-migration tooling alongside source deploys).
* Custom code moves to the package's extension points: the Quote Calculator Plugin for pricing, `SBQQ.ServiceRouter`
  /Quote API for programmatic quote changes, and careful triggers on `SBQQ__` objects that respect the calculation sequence.
* The ERP integration, persona security design, CI/CD and testing approach in this repository would carry over largely unchanged.
