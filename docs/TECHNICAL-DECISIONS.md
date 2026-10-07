# Technical Decisions

Lightweight ADRs. Status of all decisions: *accepted for this demonstration*; "Revisit" notes when production would differ.

## TD-01 Custom quote objects instead of Salesforce CPQ (`SBQQ__`)
**Context** The portfolio must be reviewable and deployable by anyone. **Decision** Model quote, line, options, contracted price on custom
objects and document the CPQ mapping ([CPQ-DESIGN.md](CPQ-DESIGN.md)). **Consequences** Deployable to a Developer Edition; demonstrates
pricing/approval engineering, but is not CPQ expertise on the package itself. **Revisit** On a real programme, use CPQ and extend it (QCP, `SBQQ.QuoteAPI`).

## TD-02 Custom approval requests instead of the native Approval Process
**Decision** `Approval_Request__c` rows + `QuoteApprovalService`. **Why** Multi-level routing from metadata, one decision UI (`quoteApprovalPanel`),
transparent audit rows, bulk-testable. **Cost** Re-implements delegation, email templates and mobile approval. **Revisit** Use Advanced Approvals when CPQ is present.

## TD-03 Policy as Custom Metadata
Discount tiers, thresholds, configuration rules and ERP settings are `__mdt`. They deploy with code, are diffable in review and need no DML at runtime
(`getAll()` is free of SOQL limits). Cost: a commercial change is a deployment. Tests inject policy through `@TestVisible` fields because CMDT cannot be inserted.

## TD-04 Trigger handler classes, no framework
One trigger per object delegating to a handler with a `switch on` over `TriggerOperation`. Handlers expose `handle(operation, lists)` so logic is testable without firing a trigger. A full framework (bypass maps, ordering) is unnecessary at three triggers; adopt one if the count grows.

## TD-05 Price in the before trigger, aggregate in the after trigger
Pricing mutates `Trigger.new` in memory (no DML, no recursion) and totals are one aggregate query per transaction. Alternative (price lines in an after trigger and update them) doubles DML and requires recursion guards. The same in-memory entry point serves the configurator preview, so preview and saved price cannot diverge.

## TD-06 System-mode writes for system-owned fields, user-mode everywhere else
Users cannot edit totals, approval or ERP state, so the services that own them write in system mode behind explicit checks ([SECURITY.md](SECURITY.md)). Reads and user-initiated DML run in user mode. The alternative, giving users edit FLS and trusting triggers, makes the API a forgery path.
*Revised after review:* "system mode" here must mean **without sharing**, not just "plain DML in a `with sharing` class" — the latter still enforces record sharing and failed for share-only approvers and the integration user. See TD-17.

## TD-07 Poll-and-lease dispatcher, not trigger-enqueued callouts
Scheduler (as the integration user) claims quotes and enqueues a queueable. Gains: single identity, no credential principal for every approver, natural retry timing, bounded concurrency. Cost: up to five minutes latency and twelve schedule entries. **Revisit** Platform Events/Change Data Capture for near-real-time dispatch.

## TD-08 Persisted back-off plus idempotency key
Apex cannot sleep and an in-transaction retry loop consumes the callout budget, so the next attempt time is stored on the quote and the ERP deduplicates with `Idempotency-Key = qf-quote-<id>-g<generation>` (TD-19). This makes at-least-once delivery safe, including after partial failure where the ERP created an order but our update failed.

## TD-09 Volume tiers evaluated per line
Simple, predictable, bulk-friendly. Aggregate tiering (sum quantity of a product across lines/bundles) needs a quote-level pass and re-pricing sibling lines on every change. Documented limitation; listed in the review.

## TD-10 Contracted prices hidden from reps, applied by guarded system-mode read
Negotiated prices are sensitive. Reps get no object access; `QuoteSelector.contractedPricesByProduct` confirms the caller can read the account via `UserRecordAccess`, then reads only that account/product price. Alternative: make `Contracted_Price__c` a master-detail child of Account so it inherits account sharing. That is allowed (standard objects can be masters) and would be the simpler choice if reps should see every price on accounts they can read; it was not taken because prices are deliberately hidden from reps and only applied by the pricing service.

## TD-11 Sequential approval driven by the highest line discount
Approval keys on `Max_Line_Discount_Pct__c`, not blended discount, so a deeply discounted line cannot hide inside a large quote. Levels are sequential 1..N where configured. Contracted price is treated as pre-approved and is excluded from "discount". **Revisit** margin-based rules, deal-size conditions, parallel approvals.

## TD-12 Buffered, sanitised integration logging
Entries are buffered and flushed after callouts (DML-before-callout rule). Credential-like JSON properties are redacted and bodies truncated. Logging failures never fail the business transaction.

## TD-13 Named Credential + External Credential with one named principal
No secrets in code or metadata; token acquisition and refresh are platform concerns; principal access is granted through a dedicated permission set. Per-user principals would be needed only if the ERP must attribute actions to individual reps.

## TD-14 Flow only for notification
Declarative automation is used where it is genuinely simpler and carries no business rule (`QF_Quote_Rejection_Follow_Up`). Anything that needs bulk testing or transactional control stays in Apex.

## TD-15 Server revalidation, DTO-based controllers
LWC previews are advisory; `saveQuote` rebuilds and re-validates from IDs and quantities only. Controllers return DTOs with exactly what the UI needs rather than SObjects, keeping the FLS surface explicit.

## TD-16 Lifecycle as data (`QuoteConstants.ALLOWED_TRANSITIONS`)
The status graph is a map, easy to review and unit test, with a narrower map for user-initiated changes. Picklist values are still repeated as string constants; generating them from the picklist describe is a candidate improvement.

## TD-17 One elevated writer for system-owned state
**Context** The review found system-owned writes in six places, each toggling the trigger's service flag by hand and each running
`with sharing`, which blocked share-only approvers and the integration user. **Decision** `QuoteStateWriter` (`without sharing`) is the
only class that writes totals, approval state, ERP bookkeeping, approval rows and approver shares; it rejects any other Quote__c field and
is the only place the service flag is raised. Services stay `with sharing`, read in user mode and authorise before calling it.
**Consequences** Elevation is reviewable in one file (CODEOWNERS, PR checklist). **Revisit** A PMD/Code Analyzer custom rule that fails the
build if `QuoteTriggerContext.enterServiceMode` is referenced anywhere else.

## TD-18 Persistent application logging through a Publish Immediately platform event
**Decision** `Logger` publishes `Log_Event__e`; `LogEventTrigger` persists it to `Application_Log__c`. **Why** A debug log is not an
operations tool, and a log row inserted in the failing transaction is rolled back with it. Publish Immediately survives the rollback.
**Cost** Event publishing allocation; cacheable Aura reads cannot publish (no DML), so they log a reference to the debug log only.
**Alternatives** Nebula Logger or a similar open-source framework is the sensible choice on a real project; a hand-rolled minimal logger is
used here to keep the demo dependency-free.

## TD-19 Idempotency key scoped to a sync generation
**Decision** `Idempotency-Key = qf-quote-<quoteId>-g<ERP_Sync_Generation__c>`. Retries within a generation replay the same key (safe at-least-once);
an operator requeue (`QF_Requeue_ERP_Sync`) increments the generation. **Why** Idempotent APIs commonly cache the *response* for a key, so after a
fixed permanent failure the old key would replay the old 422 forever. **Trade-off** A requeue after a *successful but unrecorded* create would create a
second order; the runbook therefore only requeues `Failed` quotes and requires the operator to check the ERP first.

## TD-20 Ephemeral scratch org per pull request; release validated once and quick-deployed
**Decision** PRs deploy to a throw-away scratch org from the Dev Hub and run `RunLocalTests` with a per-class coverage gate; `main` validates
against production, deploys the same commit to UAT and, after approval, quick-deploys that exact validation. **Why** A shared CI sandbox lets
concurrent PRs overwrite each other; a manually maintained "last validation id" can point at a different commit. **Cost** Scratch org allocation and
a few minutes per PR.


## TD-21 RevOps Lab: sharing rule and `with sharing` service writes instead of a central elevated writer
**Context** The lab (`revops-lab/`) needs the same guarantees as the main layer - approvers must record decisions, the integration user must
write ERP bookkeeping - but on standard Sales Cloud objects and with as little elevated code as possible. **Decision** Approver access comes
from the platform: the role hierarchy gives managers and the director edit access to their reps' quotes, and the criteria sharing rule
`Finance_Edits_Submitted_Quotes` gives Finance edit access once a quote leaves Draft. Services are `with sharing`, read in user mode, authorise
the actor explicitly, and write system-owned fields (read-only through FLS for everyone) with plain DML, which skips FLS but still enforces
sharing. The only `without sharing` code is the private `ErpStateWriter` inside `SalesERPIntegrationService`, which writes five ERP fields on
Order and first checks that the running user has edit FLS on each. **Why both approaches exist** The main layer's Apex managed sharing gives
per-quote, per-approver access, revoked on recall, at the price of one central elevated writer (TD-17). The lab shows the declarative
alternative: less code, but access is per role/criteria rather than per record. **Trade-off** Finance can edit every non-draft quote it
can see, not only the ones it was asked to approve; the service, not sharing, enforces that only the routed approver decides.
**Revisit** If approvers outside the role line are needed, add Apex managed sharing as in the main layer.
