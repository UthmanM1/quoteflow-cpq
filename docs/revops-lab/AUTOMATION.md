# RevOps Lab - Automation Reference

Every automation in `revops-lab/`, what it does, and why it is declarative or code.
Status: deployable source, **not yet verified in an org** (see [ORG-VALIDATION.md](../ORG-VALIDATION.md)).

## Choosing the tool

| Need | Tool used | Why |
|---|---|---|
| Single-record field rule with a user-facing message | Validation rule | Admin-readable, changes without Apex, runs on every entry point (UI, API, Apex) |
| Defaults on create | Before-save record-triggered flow | No DML, runs before Apex triggers, admin-maintainable |
| Notifications and simple follow-on updates | After-save record-triggered flow | Declarative, no business rule to unit-test |
| Totals across child records | Roll-up summary fields | Native, transactional, no code; possible because the line is master-detail to the quote |
| Pricing from price book entries, policy lookups, bulk logic, routing, approvals, order creation, callouts | Apex (triggers delegate to services) | Needs bulk-safe multi-record queries, transactions, authorisation checks or HTTP |
| Delete protection | Apex trigger | Validation rules do not run on delete |
| Approval tiers, ERP settings | Custom metadata | Deployed configuration, read without SOQL |
| Discount caps | Custom object (`Discount_Policy__c`) | Business data that Finance maintains in the org, effective-dated |

## Order of execution on a Quote Configuration Line save

1. **Before-save flows** (none on lines) - on the quote header, `Sales_Quote_Configuration_Defaults` runs here.
2. **Before trigger** `QuoteConfigurationLineTrigger` -> `ProductPricingService` sets list price, price book entry id,
   family and billing frequency from the quote's price book; `DiscountPolicyService` sets `Max_Allowed_Discount_Percent__c`.
3. **Validation rules** `Quantity_Must_Be_Positive`, `Discount_Within_Policy` (uses the cap set in step 2),
   `Lines_Locked_After_Submit`.
4. Save; **formula fields** `List_Total__c`, `Net_Unit_Price__c`, `Net_Total__c` evaluate.
5. **Roll-up summary** recalculates `Total_List_Amount__c`, `Total_Net_Amount__c`, `Max_Discount_Percent__c`, `Line_Count__c`
   on the parent, which saves the quote (its trigger runs; nothing changes because no status field moved).

The point to explain in an interview: step 3 can rely on step 2 because custom validation rules run after before triggers.

## Validation rules (15)

| Object | Rule | What it prevents | Error shown |
|---|---|---|---|
| `Discount_Policy__c` | `Effective_Dates_In_Order` | End date cannot be before the start date. | Effective To cannot be before Effective From. |
| `Discount_Policy__c` | `Max_Discount_In_Range` | Maximum discount must be between 0% and 100%. | Maximum discount must be between 0% and 100%. |
| `Discount_Policy__c` | `Requires_Manage_Policy_Permission` | Only holders of the Sales_Manage_Discount_Policy custom permission may create or change policies, even if object permissions are granted by mistake. | You do not have permission to maintain discount policies. |
| `Opportunity` | `Closed_Won_Requires_Ordered_Quote` | Lab rule: an opportunity can only be Closed Won once its primary quote configuration has been ordered. Bypass with Sales_Override_Quote_Lock. | Convert the primary quote configuration to an order before closing the opportunity as won. |
| `Quote_Configuration_Line__c` | `Discount_Within_Policy` | Runs after the before trigger has set Max_Allowed_Discount_Percent__c from the discount policy (order of execution). | Discount exceeds the maximum allowed by the discount policy for this product family. |
| `Quote_Configuration_Line__c` | `Lines_Locked_After_Submit` | Lines cannot be added or edited once the quote is submitted (deletes are blocked by the trigger). | Lines cannot change after the quote is submitted. Recall the quote first. |
| `Quote_Configuration_Line__c` | `Quantity_Must_Be_Positive` | Quantity must be greater than zero. | Quantity must be greater than zero. |
| `Quote_Configuration__c` | `Account_Matches_Opportunity` | The quote account must be the opportunity account. | The account must match the opportunity account. |
| `Quote_Configuration__c` | `Commercial_Terms_Locked_After_Submit` | Commercial terms cannot change once the quote is submitted, unless the user holds Sales_Override_Quote_Lock. | Opportunity, price book, term and expiry cannot change after submission. Recall the quote first. |
| `Quote_Configuration__c` | `Order_Requires_Customer_PO` | An ordered quote must carry the customer purchase order number. | A customer PO number is required to convert the quote to an order. |
| `Quote_Configuration__c` | `Price_Book_Fixed_Once_Lines_Exist` | Lines are priced from the quote price book when they are saved. Changing the price book afterwards would leave them at the old prices, so it is blocked while lines exist. | Remove the lines before changing the price book. |
| `Quote_Configuration__c` | `Term_Months_In_Range` | Term must be between 1 and 60 months. | Term must be between 1 and 60 months. |
| `Quote_Configuration__c` | `Valid_Until_Not_In_Past` | A new or changed expiry date cannot be in the past. | Valid Until cannot be in the past. |
| `Sales_Approval_Request__c` | `Rejection_Requires_Comment` | A rejection must explain itself (at least 10 characters). Also enforced in Apex for a clear message. | Explain the rejection in at least 10 characters. |
| `Sales_Subscription__c` | `End_Date_After_Start_Date` | A subscription must end after it starts. | End Date must be after Start Date. |

## Record-triggered flows

| Flow | Object / when | Entry criteria | What it does |
|---|---|---|---|
| `Sales_Quote_Configuration_Defaults` | Quote Configuration, **before save, create** | none | Gets the opportunity; sets Account (if blank) to the opportunity account, Price Book (if blank) to the opportunity price book, Valid Until (if blank) to today + 30 |
| `Sales_Approval_Request_Task` | Sales Approval Request, **after save, create** | Approver is set | Creates a high-priority task for the approver, due in 2 days, related to the quote |
| `Sales_Quote_Approved_Update_Opportunity` | Quote Configuration, **after save, update** | Status changed to Approved | Sets the opportunity StageName to *Negotiation/Review* and its Primary Quote Configuration to this quote |
| `Sales_Quote_Rejected_Follow_Up` | Quote Configuration, **after save, update** | Status changed to Rejected | Creates a high-priority "revise and resubmit" task for the quote owner |

All four ship **Active**. They contain no business rules: removing them would lose convenience, not correctness.
Assumption: the org's Opportunity StageName picklist contains *Negotiation/Review* (true for new Developer Edition orgs).

## Apex triggers (one per object, logic in handlers)

| Trigger | Events | Handler behaviour |
|---|---|---|
| `QuoteConfigurationTrigger` | before insert, before update | Insert: force Draft and blank system fields. Update: status, approval and order fields change only inside a service (`SalesQuoteContext.isServiceWrite`); a user may only cancel a Draft/Rejected quote |
| `QuoteConfigurationLineTrigger` | before insert, before update, before delete | Price and cap (see order of execution); block deletes on submitted quotes unless `Sales_Override_Quote_Lock` |
| `SalesApprovalRequestTrigger` | before insert, before update, before delete | Refuse any change outside `SalesQuoteApprovalService` (the rows are an audit trail) |

## Apex services

| Class | Responsibility | Notes |
|---|---|---|
| `SalesQuoteSelector` | All SOQL, `WITH USER_MODE` | One price book entry query for any number of lines and price books |
| `ProductPricingService` | List price from price book entry, product attributes | In memory: shared by trigger and preview |
| `DiscountPolicyService` | Policy caps (data) and approval tiers (custom metadata) | `evaluate`: highest tier by discount **or** deal size |
| `SalesQuoteService` | Preview and save a draft | User-mode inserts; savepoint; sets the opportunity's primary quote |
| `SalesQuoteApprovalService` | Submit (bulk), decide, recall | Owner / assigned-approver checks; row locks; atomic writes |
| `OrderConversionService` | Quote -> Order, OrderItems, Sales Subscriptions | Order and items in user mode; requires PO number |
| `SalesERPIntegrationService` | REST/JSON order push, classification, retry | See [INTEGRATION.md](INTEGRATION.md) |
| `SalesIntegrationLogService` | Buffered, sanitised log rows | Never breaks the business transaction |
| `SalesERPSyncSchedulable` / `SalesERPSyncQueueable` | Hourly dispatch / callouts | Schedule as the integration user |

## Custom metadata

| Type | Records | Used by |
|---|---|---|
| `Approval_Routing__mdt` | Tier 1 Sales Manager (> 10%), Tier 2 Finance Manager (> 20% or >= 250,000), Tier 3 Sales Director (> 30% or >= 1,000,000) | `DiscountPolicyService.evaluate` |
| `Sales_ERP_Setting__mdt` | Default: `Sales_ERP`, `/api/v2/orders`, 20 s timeout, 4 retries, 5 min base back-off, batch 5 | `SalesERPIntegrationService` |
