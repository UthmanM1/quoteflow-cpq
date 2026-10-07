# RevOps Lab - Security Model

Status: roles, permission sets, permission set groups, custom permissions and the sharing rule are **deployable
source**; user records, role and group assignments are org setup. Nothing here is verified in an org yet - see
[ORG-VALIDATION.md](../ORG-VALIDATION.md). The object and field matrix is generated: [FIELD-LEVEL-SECURITY.md](FIELD-LEVEL-SECURITY.md).

## Principles

1. **Additive least privilege.** Users get a minimal profile (*Standard User* in tests; *Minimum Access - Salesforce* recommended
   in a real org) plus one permission set group per persona.
2. **People never type system-owned values.** Status, approval, pricing outputs and ERP bookkeeping are read-only through FLS
   for every persona; services write them after an explicit authorisation check.
3. **The service is the control, the UI is a hint.** `@AuraEnabled` methods are a public API, so owner and approver checks live
   in `SalesQuoteApprovalService` and `OrderConversionService`, not in the LWC.
4. **`with sharing` everywhere, user-mode reads everywhere.** One named exception: `SalesERPIntegrationService.ErpStateWriter`.
5. **Separate identities.** The ERP integration runs as an API-only integration user, never as a person.

## Personas and roles

```
Sales Director                      (role Sales_Director)
 |- Sales Manager                   (role Sales_Manager)
 |   |- Sales Representative        (role Sales_Representative)
 |- Finance Manager                 (role Finance_Manager)  - outside the sales line
Integration User                    (no role; API only)
Salesforce Administrator            (System Administrator profile + Sales_Administrator_PSG)
```

| Persona | Permission set group | Sets inside |
|---|---|---|
| Sales Representative | `Sales_Representative_PSG` | `Sales_Lab_Base`, `Sales_Representative_Access` |
| Sales Manager | `Sales_Manager_PSG` | Base, Representative, `Sales_Manager_Access` |
| Finance Manager | `Finance_Manager_PSG` | Base, `Finance_Manager_Access` |
| Sales Director | `Sales_Director_PSG` | Base, Representative, Manager, `Sales_Director_Access` |
| Integration User | `Sales_Integration_PSG` | `Sales_Integration_Access` |
| Salesforce Administrator | `Sales_Administrator_PSG` | Base, `Sales_Administrator_Access` |

## Record access (sharing)

| Object | OWD | Who else sees a record | Mechanism |
|---|---|---|---|
| `Quote_Configuration__c` | Private | Owner's managers and the director: read/edit | Role hierarchy |
| | | Finance managers: **edit** once the quote leaves Draft (and is not Cancelled) | Criteria sharing rule `Finance_Edits_Submitted_Quotes` |
| `Quote_Configuration_Line__c`, `Sales_Approval_Request__c` | Controlled by parent | Same as the quote | Master-detail |
| `Sales_Subscription__c` | Controlled by parent | Same as the account | Master-detail to Account |
| `Discount_Policy__c` | Public Read Only | Everyone reads; changes need object permission **and** `Sales_Manage_Discount_Policy` (validation rule) | OWD + custom permission |
| `Sales_Integration_Log__c` | Private | Administrators (View All) | Object permission |

Why Finance gets **Edit** and not Read: Finance approves tier 2. The approval service is `with sharing` and records the
decision with plain DML (system mode for CRUD/FLS, but sharing is enforced), so the approver needs record-level edit.
FLS keeps every quote field read-only for Finance, so the extra access cannot be used to change the quote in the UI.
The main QuoteFlow layer solves the same problem differently - an allow-listed elevated writer (TD-17) - and the two are
compared in [TECHNICAL-DECISIONS.md](../TECHNICAL-DECISIONS.md).

## Custom permissions

| Custom permission | Checked in | Held by |
|---|---|---|
| `Sales_Override_Quote_Lock` | Validation rules `Commercial_Terms_Locked_After_Submit`, `Lines_Locked_After_Submit`, `Closed_Won_Requires_Ordered_Quote`; Apex delete lock; owner checks in submit, recall, convert | Administrator |
| `Sales_Manage_Discount_Policy` | Validation rule `Requires_Manage_Policy_Permission` | Finance Manager, Administrator |
| `Sales_Run_ERP_Sync` | `SalesERPIntegrationService.requestSync` | Integration User, Administrator |

## What each persona can do - and why

| Action | Sales Rep | Sales Manager | Finance Manager | Sales Director | Integration User | Administrator |
|---|---|---|---|---|---|---|
| **Create quote** | Yes - creates on own opportunities | Yes | **No** - no create permission; Finance reviews, it does not sell | Yes | **No** - no object access | Yes |
| **Edit quote** | Own quotes while Draft/Rejected (validation rules lock commercial terms after submit) | Team quotes via hierarchy, same lock | **No** - record edit exists only for approvals; every field is read-only (FLS) | All quotes via hierarchy, same lock | No | Yes; may edit locked terms with `Sales_Override_Quote_Lock` |
| **Submit quote** | Own quotes (service checks owner) | Own quotes only; a team member's quote is refused | No | Own quotes only | No | Yes, on behalf of owners (override permission) |
| **Approve quote** | No (never routed to the owner) | Tier 1 when assigned: owner's manager | Tier 2 when assigned (Finance_Manager role) | Tier 3 when assigned (Sales_Director role) | No | **No** - segregation of duties: the override permission does not include deciding approvals |
| **Convert quote** | Own approved quotes; needs Order create (granted) and a customer PO | Own quotes | No - read-only on orders | Own quotes | No | Yes (override permission) |
| **Run ERP sync** | No | No | No | No | Yes - scheduled job runs as this user | On demand with `Sales_Run_ERP_Sync` |

How the "why" is enforced:

* **Create/Edit:** object permissions in the permission sets + FLS + validation rules (lock) + the quote trigger (status).
* **Submit/Recall/Convert:** `quote.OwnerId == UserInfo.getUserId()` or `Sales_Override_Quote_Lock`, in the services.
* **Approve:** `request.Approver__c == UserInfo.getUserId()` in `SalesQuoteApprovalService.decide`; the approver needs
  record edit access, which the hierarchy (manager, director) or the sharing rule (finance) provides.
* **Run ERP sync:** custom permission check, plus edit FLS on the five `Order.ERP_*` fields, which `ErpStateWriter`
  verifies before writing.

## CRUD/FLS in Apex

| Pattern | Where |
|---|---|
| `WITH USER_MODE` on every query | `SalesQuoteSelector` (all lab SOQL) |
| `insert/update as user` for user-entered data | `SalesQuoteService` (quote, lines, opportunity primary quote), `OrderConversionService` (Order, OrderItems) |
| Plain DML for system-owned fields, `with sharing` | Quote status/approval fields, approval requests, subscriptions, order ERP status - after explicit authorisation |
| `AccessLevel.USER_MODE` on logging | `SalesIntegrationLogService.flush` |
| `without sharing`, FLS-checked, ERP fields only | `SalesERPIntegrationService.ErpStateWriter` (the integration user owns no orders) |
| Static check that every `USER_MODE` field is readable by the personas that reach it | `scripts/ci/check_fls.py` (main and lab) |

## Things to verify in an org (not provable from source)

* The criteria sharing rule grants Finance edit when a quote moves to Pending Approval (and recalculation timing).
* PSG status reaches *Updated* after deployment before assignment.
* Tab and app visibility for each persona.
