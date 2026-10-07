# Security Model

> Design specification plus the metadata in `force-app`. Roles, groups, sharing rules, permission sets and permission set groups
> are in source control. **Profiles, the Named/External Credential, user records and role assignments are org configuration**
> described here but not deployed by this repository.

## Principles

1. **Least privilege, additive.** Profiles are minimal; capability comes from permission sets composed into persona groups.
2. **Users never write system-owned data.** Totals, approval state and ERP state are read-only through FLS, and the triggers re-check it so API/DML paths that skip FLS (Apex, integrations) cannot forge them either.
3. **Enforce in code, not only in metadata.** Reads use `WITH USER_MODE`; user-initiated DML uses `insert/update as user` or `AccessLevel.USER_MODE`. System-owned fields are written only through `QuoteStateWriter`, after the calling service has authorised the action (below).
4. **Authorise in the service, not in the UI.** `@AuraEnabled` methods are a public API. Owner-only actions (submit, recall, convert) and approver-only decisions are checked in `QuoteApprovalService`/`QuoteOrderService`; the LWC flags are display hints computed with the same rule.
5. **Separate identities.** The ERP integration runs as its own API-only user, never as a person.

### Why `with sharing` alone was not enough

`with sharing` makes plain DML skip CRUD/FLS but **still enforce record-level sharing**. The people who legitimately change
approval state often hold only *Read* on the quote: an approver who sees it through the `Approver_Access` share or the Finance
sharing rule, or the integration user, whose View All grants read but not edit. A `with sharing` service doing plain DML fails
for exactly those users (and the failure is hidden whenever partial-success DML is used). The design therefore keeps every service
`with sharing`, reads in user mode, authorises explicitly, and routes the resulting state change through one small
`without sharing` class whose writable fields are allow-listed.

## Organisation-wide defaults

| Object | OWD | Rationale |
|---|---|---|
| Account, Opportunity, Contact | Private (standard Sales Cloud baseline) | Reps see their own customers; managers via hierarchy. |
| `Quote__c` | Private | Pricing and discounts are commercially sensitive. |
| `Quote_Line__c`, `Approval_Request__c` | Controlled by Parent | Master-detail; inherit the quote's access. |
| `Contracted_Price__c` | Private | Negotiated prices must not leak between customers or to reps. |
| `Subscription__c`, `Integration_Log__c` | Private | |
| `Product_Option__c` | Public Read/Write | Catalogue data; write access restricted by CRUD, not by sharing. |
| Product2, Pricebook2 | Public Read Only (standard) | |

## Role hierarchy (`roles/`)

```
QF VP Sales
 |- QF Finance Director
 |- QF Sales Manager
     |- QF Sales Rep
```
Managers inherit their reps' records. Finance does not sit in the sales line; it receives access through a sharing rule.

## Sharing

| Mechanism | What | Why |
|---|---|---|
| Role hierarchy | Manager sees reps' quotes | Standard. |
| Criteria sharing rule `Finance_Reads_Submitted_Quotes` | Group `QF Finance` gets **Read** on quotes where `Status__c != Draft` | Finance reviews anything that has left draft, never working drafts. |
| Apex managed sharing, reason `Approver_Access` | Approver gets **Read** on the quote when a request is assigned | Level-3 approvers (VP) and role-based approvers are not always above the owner. `QuoteSharingService` is the only writer. |

Share lifecycle: granted when a request is assigned; **kept** after the approver decides (they can reopen what they approved or
rejected); **revoked** when a pending request is superseded by a recall or resubmission, unless the same user decided another level
of that quote. Share writes and reads of share rows go through `QuoteStateWriter`, because the user who triggers them (for example a
Finance Director routing to the VP) usually has only Read access. Revocation on cancellation or ownership change remains a hardening item.

## Permission sets and groups (`permissionsets/`, `permissionsetgroups/`)

| Permission set | Grants | Notable denials |
|---|---|---|
| `QF_Base_Access` | Read Product2, Pricebook2, PricebookEntry, Product_Option__c; access to the two LWC controllers | Nothing else. |
| `QF_Sales_Rep` | Create/read/edit Quote; CRUD Quote Line; read Approval Request; create Order/OrderItem/Subscription for conversion; edit rep-owned inputs only (term, price book, manual discount, quantity) | No delete on quotes; no access to `Contracted_Price__c`, `Integration_Log__c`; every calculated field read-only. |
| `QF_Sales_Manager` | Rep capabilities + delete quotes, read integration logs | Cannot edit calculated fields; approval decisions go through Apex only. |
| `QF_Finance_Approver` | Read quotes/lines/requests/subscriptions/logs; full CRUD on `Contracted_Price__c`; custom permission `QF_Manage_Contracted_Pricing` | Cannot edit quotes. |
| `QF_Admin` | Full CRUD + View All on QuoteFlow objects, Modify All on both log objects (`Integration_Log__c`, `Application_Log__c`), custom permissions `QF_Override_Quote_Lock` and `QF_Requeue_ERP_Sync` | Does not replace the System Administrator profile. ERP and approval fields are still trigger-protected. |
| `QF_Integration_User` | **Read-only** on Quote (View All, to find work), lines, Account ERP id, Product2; create integration logs; create/edit Subscription | No edit on Quote at all: lease and outcome bookkeeping (ERP fields only) is written by `QuoteStateWriter`. No Delete anywhere; no Modify All; no UI access. |

Persona groups: `QF_Sales_Rep_PSG` (Base + Rep), `QF_Sales_Manager_PSG` (Base + Rep + Manager), `QF_Finance_PSG` (Base + Finance),
`QF_Administrator_PSG` (Base + Admin). Assign groups, not individual sets, so a persona change is one assignment.

Custom permissions: `QF_Override_Quote_Lock` (break-glass edit of locked quotes; also lets an administrator act for an owner),
`QF_Requeue_ERP_Sync` (operator requeue of failed ERP syncs), `QF_Manage_Contracted_Pricing`, `QF_View_Integration_Logs`.
They are checked with `FeatureManagement.checkPermission` so code never inspects profile or permission-set names.

## Profiles (configuration)

* Sales, finance and manager users: clone of **Minimum Access - Salesforce**; all capability from permission set groups.
* Integration user: **Salesforce API Only System Integrations** profile + `QF_Integration_User`; no login to the UI, IP-restricted, password never used (JWT/OAuth for the CLI only if needed).
* Administrators: System Administrator + `QF_Administrator_PSG`.

## Persona access matrix

| Persona | Sees | Can do | Cannot do |
|---|---|---|---|
| Sales rep | Own accounts, opportunities, quotes | Configure, price, save, submit, recall, convert approved quotes | Edit totals/approval/ERP fields, delete quotes, see contracted prices or logs, approve own quote |
| Sales manager | Team's quotes (hierarchy) | Everything a rep can + approve level 1 when assigned, delete quotes | Override lock, edit calculated fields |
| Finance | Non-draft quotes (sharing rule) | Maintain contracted prices, approve level 2 when assigned, inspect ERP outcomes | Edit quotes |
| Administrator | Everything in QuoteFlow | Override quote lock, requeue ERP failures, maintain metadata | - |
| Integration user | Approved/ordered quotes and lines | Read quote data, write logs; ERP state is written on its behalf by `QuoteStateWriter` | Edit any user-owned field, anything else |

## CRUD/FLS in Apex

| Pattern | Where |
|---|---|
| `WITH USER_MODE` on every SOQL statement | `QuoteSelector`, `IntegrationLogPurgeBatch` |
| `insert/update as user`, `Database.*(..., AccessLevel.USER_MODE)` | `QuoteConfiguratorController`, `QuoteOrderService` (Order, OrderItem, Subscription), `IntegrationLogService`, `IntegrationLogPurgeBatch` |
| `with sharing` on all services and controllers; `inherited sharing` on pure utilities | all except the two named `without sharing` classes below |
| `without sharing`, deliberately | `QuoteStateWriter` (system-owned fields, approval rows, approver shares) and the private `QuoteSelector.ContractedPriceReader` |
| Static check that every `WITH USER_MODE` field is readable by the personas that call it | `scripts/ci/check_fls.py`, run in CI |
| Controllers expose only DTOs, never raw SObjects with unbounded fields | `QuoteConfiguratorController`, `QuoteApprovalController` |

### Deliberate system-mode operations

All of them go through `QuoteStateWriter`, which refuses any Quote__c field that is not on its system-field allow-list.

| Operation | Why it cannot be user mode | Compensating control |
|---|---|---|
| Roll-up of totals and `Required_Approval_Level__c` | No persona has edit FLS on totals | Calculated from rows read in user mode; the triggering line change already required edit access to the quote |
| Approval request creation/decision, quote status changes | Approvers usually hold only Read (Apex share or sharing rule); no persona may edit approval fields | Service checks owner (submit/recall), assigned approver and pending state (decide), row-locks quote and request, rolls back on any failure |
| Quote status `Ordered` after conversion | Status is system-owned | Owner-only, Approved-only, inside the conversion savepoint; Order/OrderItem/Subscription themselves are created in user mode |
| ERP lease and outcome bookkeeping | The integration user owns no quotes and has read-only access | Writes ERP fields only; failed writes are logged and the lease is not dispatched; idempotency key makes a lost update self-healing |
| Operator requeue | Same as above | Requires `QF_Requeue_ERP_Sync`; starts a new sync generation |
| Reading `Contracted_Price__c` for pricing | Reps have no object access by design | `canReadAccount` (`UserRecordAccess`) must pass first; query is account- and product-scoped; only the price is used |
| Apex managed sharing insert/delete and share-row reads | Share rows are system data; the acting user may have Read only | Only `Approver_Access` row cause; grant/revoke rules in `QuoteSharingService` |

The service flag that disarms trigger tamper-protection (`QuoteTriggerContext.isServiceUpdate`) has a private setter and is raised
only inside `QuoteStateWriter`, always restored in `finally`. It protects against UI, API, Flow and Data Loader callers; it cannot
protect against other Apex in the org, which is why the PR checklist and CODEOWNERS cover `QuoteStateWriter`.

## Input and output hardening

* All SOQL is static or bound; no dynamic SOQL, so no injection surface.
* Server-side re-validation of everything the LWC previews; client-supplied prices are overwritten by the trigger.
* `Is_Included__c` (zero price) is accepted only when the bundle definition says so.
* `AuraErrorFactory` hides internals and returns a support reference that is persisted on `Application_Log__c` (via a Publish Immediately platform event, so it survives rollback). Cacheable reads cannot publish events and keep the reference in the debug log only.
* Integration payloads are redacted for credential-looking JSON properties and truncated before storage.
* Named Credential holds the endpoint and auth; no secret, token or URL is in Apex, metadata or tests. The URL in `docs/config-specs` is a non-routable placeholder.

## Integration user

Dedicated API-only user. Scheduler is created while logged in as that user, so the queueable inherits its identity and the
External Credential principal is granted **only** to `QF_Integration_User`. Rotating the ERP client secret is an
org-setup operation and never touches the repository.

## Known gaps

See [ARCHITECTURE-REVIEW.md](ARCHITECTURE-REVIEW.md): share revocation on cancellation/ownership change, Shield Platform Encryption for logs, login IP ranges, event monitoring, and an automated permission-diff check in CI.
