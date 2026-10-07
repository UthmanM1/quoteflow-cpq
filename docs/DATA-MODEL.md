# Data Model

`*` = system-owned: read-only to users through FLS, protected again by the Quote trigger, written only through `QuoteStateWriter`.

## Standard objects (extended)

| Object | Custom field | Type | Purpose |
|---|---|---|---|
| Account | `ERP_Customer_Id__c` | Text(64), external id, unique | Key sent to the ERP as `customerId`. |
| Contact | `Is_Quote_Signatory__c` | Checkbox | Marks contacts who may accept quotes. |
| Opportunity | `Primary_Quote__c` | Lookup(Quote__c) | Quote chosen as the opportunity's commercial proposal. |
| Product2 | `Product_Type__c` | Picklist: Standalone, Bundle, Option, Service | Drives configurator behaviour. |
| Product2 | `Billing_Model__c` | Picklist: Subscription, One-Time | Subscription prices are annual rates scaled by term/12. |
| Product2 | `ERP_SKU__c` | Text(64), external id | SKU used in the ERP payload (falls back to `ProductCode`). |
| Pricebook2 | `Customer_Segment__c` | Picklist | Segment-specific price books. |
| Order | `Source_Quote__c` | Lookup(Quote__c) | Traceability from order to quote. |

## Quote__c (Quote) - OWD Private

| Field | Type | Notes |
|---|---|---|
| `Name` | Auto Number `Q-{000000}` | |
| `Account__c` | Lookup(Account), delete: Restrict | Defaulted from the opportunity if blank. |
| `Opportunity__c` | Lookup(Opportunity) | Must belong to `Account__c`. |
| `Primary_Contact__c` | Lookup(Contact) | |
| `Pricebook__c` | Lookup(Pricebook2), delete: Restrict | Changing it re-prices lines. |
| `Status__c` | Picklist: Draft, Pending Approval, Approved, Rejected, Ordered, Cancelled | Lifecycle graph enforced in `QuoteTriggerHandler`. History tracked. |
| `Approval_Status__c`* | Picklist: Not Submitted, Not Required, Pending, Approved, Rejected | |
| `Term_Months__c` | Number(3,0), required | 1-60. |
| `Valid_Until__c` | Date | Defaults to today + 30 days. |
| `List_Amount__c`*, `Net_Amount__c`*, `Total_Discount_Amount__c`* | Currency | Rolled up from lines. |
| `Blended_Discount_Pct__c`*, `Max_Line_Discount_Pct__c`* | Percent(5,2) | Max line discount drives approval routing. |
| `Required_Approval_Level__c`*, `Current_Approval_Level__c`* | Number(1,0) | |
| `ERP_Sync_Status__c`* | Picklist: Not Required, Pending, In Progress, Synced, Failed | Written by the ERP sync (as the integration user, through the writer). |
| `ERP_Order_Id__c`* | Text(64), external id, unique | |
| `ERP_Last_Sync__c`*, `ERP_Sync_Attempts__c`*, `ERP_Next_Attempt_At__c`*, `ERP_Last_Error__c`* | DateTime / Number / DateTime / Text(255) | Retry bookkeeping; `ERP_Next_Attempt_At__c` doubles as the lease expiry. |
| `ERP_Sync_Generation__c`* | Number(4,0) | 1 on approval, +1 per operator requeue; part of the ERP `Idempotency-Key`. |

Sharing reason: `Approver_Access` (Apex managed sharing for approvers).

## Quote_Line__c (Quote Line) - ControlledByParent

| Field | Type | Notes |
|---|---|---|
| `Quote__c` | Master-detail(Quote__c) | |
| `Product__c` | Lookup(Product2), required | |
| `Parent_Line__c` | Lookup(Quote_Line__c) | Component -> bundle header. |
| `Quantity__c` | Number(10,2), required | |
| `Manual_Discount_Pct__c` | Percent | Rep-entered, capped at 60%. |
| `Is_Bundle_Component__c` | Checkbox | |
| `Is_Included__c` | Checkbox | Zero-priced; trigger accepts it only if `Product_Option__c.Price_Treatment__c = Included`. |
| `Billing_Model__c`*, `Pricing_Source__c`*, `Pricebook_Entry_Id__c`* | Picklist / Picklist / Text(18) | |
| `List_Unit_Price__c`*, `Contracted_Unit_Price__c`*, `Base_Unit_Price__c`* | Currency | |
| `Schedule_Discount_Pct__c`*, `Effective_Discount_Pct__c`* | Percent | Effective = 1 - (1 - schedule)(1 - manual). |
| `Net_Unit_Price__c`*, `List_Total__c`*, `Net_Total__c`* | Currency | Totals include term scaling for subscriptions. |
| `Line_Discount_Amount__c` | Formula(Currency) | `List_Total__c - Net_Total__c` |

## Approval_Request__c - ControlledByParent, immutable outside `QuoteApprovalService`

`Quote__c` (master-detail), `Status__c` (Pending/Approved/Rejected/Superseded), `Approval_Level__c`, `Requested_Discount_Pct__c`,
`Threshold_Pct__c`, `Approver__c` (User), `Submitted_By__c` (User), `Submitted_Date__c`, `Decision_Date__c`, `Decision_Comments__c`.
One row per level; multi-level approvals create the next row only after the previous one is approved.

## Product_Option__c - OWD Public Read/Write (catalogue data; edit rights via permission sets)

`Bundle_Product__c`, `Option_Product__c` (lookups to Product2), `Is_Required__c`, `Price_Treatment__c` (Additive/Included),
`Default_Quantity__c`, `Min_Quantity__c`, `Max_Quantity__c`, `Sort_Order__c`, `Is_Active__c`.

## Contracted_Price__c - OWD Private

`Account__c`, `Product__c` (lookups), `Unit_Price__c`, `Start_Date__c`, `End_Date__c`. Reps have no access to the object; pricing
reads it through a guarded system-mode query (TD-10).

## Integration_Log__c - OWD Private

`Correlation_Id__c` (external id), `Integration_Name__c`, `Direction__c`, `Status__c` (Success / Retryable Failure / Permanent Failure),
`Http_Method__c`, `Endpoint__c`, `Http_Status_Code__c`, `Attempt__c`, `Duration_Ms__c`, `Related_Record_Id__c`,
`Request_Body__c`, `Response_Body__c` (long text, sanitised and truncated), `Error_Message__c`.

## Application_Log__c - OWD Private

Persisted errors and warnings: `Level__c` (ERROR/WARN/INFO), `Source__c`, `Message__c`, `Stack_Trace__c` (long text),
`Reference__c` (external id; the support reference shown to users), `Related_Record_Id__c`, `User_Id__c`. Written by `LogEventTrigger`
from the `Log_Event__e` platform event (Publish Immediately, same fields), so entries survive a rolled-back transaction. Purged by
`IntegrationLogPurgeBatch` with the same retention as integration logs.

## Subscription__c - OWD Private

`Account__c`, `Quote__c`, `Product__c`, `Status__c`, `Quantity__c`, `Start_Date__c`, `End_Date__c`, `Annual_Recurring_Revenue__c`, `ERP_Subscription_Id__c`.

## Custom Metadata Types

| Type | Purpose | Shipped records |
|---|---|---|
| `Discount_Rule__mdt` | Volume tiers by product family and quantity range | 5 (Subscriptions x3, Services x2) |
| `Approval_Threshold__mdt` | Level, discount threshold, approver type (Manager/Role) | 3 (10%, 20%, 30%) |
| `Configuration_Rule__mdt` | Requires/Excludes constraints between bundle options | 3 |
| `ERP_Integration_Setting__mdt` | Named credential, path, timeout, attempts, back-off, batch size, retention | 1 (`Default`) |

## Relationships in words

* A **Quote** belongs to one Account and usually one Opportunity; the Opportunity points back at its Primary Quote.
* A **Quote Line** is a child (master-detail) of its Quote and inherits its sharing. Bundle components point at their bundle header through `Parent_Line__c`;
  deleting a header deletes its components (cascaded by the before-delete trigger, because a same-object lookup cannot cascade declaratively).
* **Product Options** define what may be configured inside a bundle; **Configuration Rules** define constraints between options.
* **Approval Requests** are the audit trail of every approval step for a quote.
* Converting a quote creates an **Order** (+ OrderItems) and **Subscriptions**; the ERP sync stores its order id back on the quote.
* **Integration Logs** reference their quote by id, not by relationship, so logs survive quote deletion and can be purged independently.
