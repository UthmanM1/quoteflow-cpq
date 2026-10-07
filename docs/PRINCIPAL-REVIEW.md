# Principal Architect Review

A review of QuoteFlow CPQ conducted the way a Salesforce Principal Architect would in a technical interview: read every Apex
class, trigger, LWC, permission set and pipeline file; trace the main journeys (configure → save → submit → approve → convert → ERP sync)
through the *actual* sharing and permission model rather than through the comments; then rank what is strong and what would fail.

The review was done against the repository as uploaded (baseline). Each weakness lists the change made in this revision under
**Resolution**; the [Resolution log](#resolution-log) at the end maps findings to files.

> Scope note: this is a fictional portfolio project. Nothing here has been deployed to a real org. Findings marked
> *runtime defect* are reasoned from platform behaviour (sharing, FLS, SOQL field access), not observed in an org.

---

## 15 strongest technical areas

| # | Area | Evidence | Why it matters in an interview |
|---|---|---|---|
| S1 | **Trigger architecture** | One trigger per object, `switch on Trigger.operationType`, static `handle(operation, lists)` overloads (`QuoteTriggerHandler`, `QuoteLineTriggerHandler`) | Logic is testable without DML; no logic in trigger bodies. |
| S2 | **Single selector** | `QuoteSelector` owns every query, `WITH USER_MODE` by default | One place to review CRUD/FLS/sharing for reads and to tune fields. |
| S3 | **Before-trigger pricing, shared with preview** | `QuoteCalculationService.priceLines` mutates `Trigger.new` in memory and also prices unsaved preview lines | No recursion, no extra DML, preview and saved price cannot diverge. |
| S4 | **Constant query cost** | Pricing issues three queries per quote context; roll-up is one aggregate query | Bulk behaviour is predictable and asserted by bulk tests. |
| S5 | **Policy as Custom Metadata** | Discount tiers, thresholds, configuration rules, ERP settings; `@TestVisible` injection | Commercial change without code; deterministic tests. |
| S6 | **Lifecycle as data** | `QuoteConstants.ALLOWED_TRANSITIONS` vs narrower `USER_TRANSITIONS` | Status graph is reviewable and enforced on every path, including the API. |
| S7 | **Tamper-proofing** | Before-insert resets system fields; `rejectChangesToSystemFields`; `Is_Included__c` validated against the bundle definition | FLS alone leaves Apex/integration paths open; the trigger closes them. |
| S8 | **Lost-update protection** | `FOR UPDATE` on quote and request, state re-checked after locking in `decide` | Two approvers racing cannot both win. |
| S9 | **Approval keyed on max line discount** | `Max_Line_Discount_Pct__c` drives routing, not blended discount | A deep discount cannot hide inside a large quote. |
| S10 | **Guarded system-mode read for contracted prices** | `UserRecordAccess` check, then a narrowly scoped `without sharing` inner reader | Shows the "elevate narrowly, authorise first" pattern. |
| S11 | **Credential hygiene** | `callout:ERP_Gateway` Named Credential + External Credential; test asserts no `Authorization` header from Apex | No secrets in code, metadata or tests. |
| S12 | **Resilient integration design** | Status-classified outcomes, persisted exponential back-off, `Retry-After`, lease expiry, callout-budget guard, callouts before DML | Correct use of async Apex limits instead of in-transaction retry loops. |
| S13 | **Buffered, sanitised integration log** | `IntegrationLogService.record/flush`, credential redaction, truncation, retention batch | Logging respects the DML-before-callout rule and never breaks the business transaction. |
| S14 | **Error contract** | `QuoteFlowException` = safe to show; `AuraErrorFactory` hides internals; per-record results (`addError`, `SubmissionResult`, `SyncOutcome`) | One bad record never hides the others; no stack traces in the browser. |
| S15 | **LWC as a thin, server-authoritative client** | Debounced preview with out-of-order response guard; DTO-only controllers; `refreshApex` + `notifyRecordUpdateAvailable` in the approval panel | Classic LWC race condition handled; UI never trusted for price. |

Honourable mention: the documentation is unusually honest (verification status, "Gearset was not used", self-review). Keep that.

---

## 15 weakest areas

Severity: **Critical** = a core journey fails at runtime; **High** = security/reliability gap a reviewer would block on; **Medium** = quality/maintainability.

### W1 — `with sharing` DML blocks approvers from deciding *(Critical, runtime defect)*
* **Why it is a problem.** `QuoteApprovalService`, `QuoteSharingService` and `QuoteCalculationService.writeAsService` are `with sharing` and use plain `update`/`insert`. Plain DML skips CRUD/FLS but **not record-level sharing** in a `with sharing` class. An approver who sees the quote only through the `Approver_Access` Apex share (Read), or the Finance sharing rule (Read), gets `INSUFFICIENT_ACCESS_OR_READONLY` when `decide` updates the quote and the master-detail `Approval_Request__c`. The class comments say "written in system mode" — they are not. The Finance Director (sibling branch of the role tree) can therefore never approve level 2, and a manager linked only through `User.ManagerId` (no role) cannot approve level 1. Next-level share inserts made by a Read-only approver fail and are swallowed by `Database.insert(…, false)`.
* **Senior approach.** Keep `with sharing` on services, authorise explicitly (assigned approver, row lock, state), then perform the state change through **one** small `without sharing` writer that only touches system-owned fields. Name it, test it, and make it the only place the service flag is raised.
* **Affects:** security, correctness (maintainability).
* **Files:** `classes/QuoteApprovalService.cls`, `classes/QuoteSharingService.cls`, `classes/QuoteCalculationService.cls`.
* **Resolution.** New `QuoteStateWriter` (`without sharing`, field-allow-listed, flag-scoped). All system-owned writes go through it. `decide` now succeeds for share-only approvers; regression test runs the full three-level journey with role-less users.

### W2 — Integration user cannot write quote ERP state; failures are silent *(Critical, runtime defect)*
* **Why it is a problem.** `claimDueQuotes`, `applyOutcomes` and `requeueFailed` update quotes with `AccessLevel.USER_MODE`. `QF_Integration_User` grants Edit + **View All** on `Quote__c` — View All gives read, not edit, on records the integration user does not own. Every lease and outcome update fails, `Database.update(…, false)` swallows it, `claimed` still contains the ids, the worker skips them because the status never became `In Progress`, and **no quote is ever synchronised**. Tests pass only because they run as an admin runner.
* **Senior approach.** Read in user mode (the integration user really does need View All to find work), write ERP bookkeeping through the scoped system-mode writer, and treat a failed lease as "not claimed". Test as the integration persona, not as the CI admin.
* **Affects:** integration reliability, security, testing.
* **Files:** `classes/ERPIntegrationService.cls`, `permissionsets/QF_Integration_User.permissionset-meta.xml`, `classes/ERPIntegrationServiceTest.cls`.
* **Resolution.** ERP writes go through `QuoteStateWriter.writeErpState`; only successfully leased ids are dispatched; a new test runs dispatch and sync as a user holding only `QF_Integration_User`.

### W3 — Order conversion throws, and conversion strands ERP sync *(Critical, runtime defect)*
* **Why it is a problem.** `QuoteOrderService.convert` reads `quote.Opportunity__c` from `QuoteSelector.quotesForUpdate`, which does not select that field → `SObjectException: SObject row was retrieved via SOQL without querying the requested field`. Separately, the ERP pipeline only considers `Status__c = Approved`; once a quote is converted it becomes `Ordered`, so a pending/leased ERP sync is skipped forever and the quote stays `In Progress`.
* **Senior approach.** Selectors return the fields their callers use (and a test calls every selector path). Model "ERP-eligible" as a set of statuses, not one value.
* **Affects:** correctness, integration reliability, testing.
* **Files:** `classes/QuoteSelector.cls`, `classes/QuoteOrderService.cls`, `classes/ERPIntegrationService.cls`, `classes/QuoteConstants.cls`.
* **Resolution.** Field added to the selector; `QuoteConstants.ERP_SYNCABLE_STATUSES = {Approved, Ordered}` used by selector and worker; regression tests for both.

### W4 — Authorisation enforced only in the UI *(High)*
* **Why it is a problem.** `canSubmit`/`canConvert` are computed for the LWC, but `QuoteApprovalService.submit` and `QuoteOrderService.convert` accept any user who can read the quote. Finance (Read on non-draft quotes via sharing rule) could resubmit a rejected quote; a manager could submit on a rep's behalf. `@AuraEnabled` methods are a public API — the button being hidden is not a control.
* **Senior approach.** Enforce the same rule in the service the UI uses for display; return a per-record error rather than throwing in bulk paths.
* **Affects:** security.
* **Files:** `classes/QuoteApprovalService.cls`, `classes/QuoteOrderService.cls`.
* **Resolution.** Owner (or `QF_Override_Quote_Lock` holder) check in `submit` and `convert`; tests prove a non-owner reader is refused.

### W5 — Elevated writes scattered; protection depends on a public mutable flag; ERP fields unprotected *(High)*
* **Why it is a problem.** Six classes and the test factory toggle `QuoteTriggerContext.isServiceUpdate` by hand. Any missed `finally` leaves the trigger disarmed for the rest of the transaction. `rejectChangesToSystemFields` protects totals and approval state but not `ERP_*` fields, so an admin-level user or a Flow could forge `ERP_Order_Id__c`/`ERP_Sync_Status__c`.
* **Senior approach.** One writer owns the flag; the flag has a private setter; every system-owned field is in the tamper list. (Be candid in interview: a static flag guards UI/API callers, not other Apex — that is what code review and the PR checklist are for.)
* **Affects:** security, maintainability.
* **Files:** `classes/QuoteTriggerContext.cls`, `classes/QuoteTriggerHandler.cls`, `classes/TestDataFactory.cls`.
* **Resolution.** `isServiceUpdate` is now a read-only property over private state, changed only through `enterServiceMode()/restoreServiceMode()`, which only `QuoteStateWriter` calls (tests arrange state through the writer too); ERP fields added to the tamper check.

### W6 — Bundle validation issues SOQL per bundle; a hard cap hides it *(High, governor limits)*
* **Why it is a problem.** For each bundle, `expand` calls `validate` (2 queries), then `buildLines` calls `validate` again (2 more) and queries options again (1) ≈ 5 SOQL per bundle, inside a loop. `MAX_BUNDLES_PER_DRAFT = 5` exists to keep the transaction under 100 queries — a limit workaround rather than a design.
* **Senior approach.** Load products and options for **all** bundles in one pass, validate in memory, expand from the same maps. Then the cap becomes a business rule, not a governor-limit crutch.
* **Affects:** scalability, performance.
* **Files:** `classes/ProductConfigurationService.cls`, `classes/QuoteConfiguratorController.cls`.
* **Resolution.** New bulk API `ProductConfigurationService.validateAll/buildAll` (2 queries total, any number of bundles); single-bundle methods delegate to it; a test asserts the query count does not grow with bundle count.

### W7 — Deleting a bundle header orphans its components *(High, data integrity)*
* **Why it is a problem.** `Parent_Line__c` is a lookup with `SetNull`. Deleting a header leaves its components on the quote as standalone lines; `Included` components stay zero-priced with `Is_Included__c = true` and no parent, which is exactly the state the trigger rejects on save.
* **Senior approach.** Cascade the delete in the before-delete handler (lookups cannot cascade declaratively to the same object), bulk-safe and lock-checked.
* **Affects:** maintainability (data integrity), correctness.
* **Files:** `classes/QuoteLineTriggerHandler.cls`.
* **Resolution.** Before-delete cascades component deletion for deleted headers; test added.

### W8 — Approver shares are never revoked; share failures disappear *(Medium, security)*
* **Why it is a problem.** A superseded approver (recall, resubmission to a different approver) keeps read access to a commercially sensitive quote indefinitely. Share insert failures only reach `System.debug`.
* **Senior approach.** Revoke `Approver_Access` rows for pending requests that are superseded; keep shares for approvers who actually decided (audit). Persist failures.
* **Affects:** security.
* **Files:** `classes/QuoteSharingService.cls`, `classes/QuoteApprovalService.cls`.
* **Resolution.** `QuoteSharingService.revokeApproverAccess` called on recall/supersede (skips users who decided an earlier level); failures go to the application log.

### W9 — Unexpected errors only reach `System.debug` *(High, error handling / operability)*
* **Why it is a problem.** `AuraErrorFactory` tells the user "contact support (reference ab12cd34)" but the reference only exists in a debug log nobody captured. Scheduler/queueable aborts, share failures and failed ERP outcome writes are equally invisible in production.
* **Senior approach.** A small logger that publishes an immediate-publish Platform Event (survives rollback) and persists it to a log object; reference ids become searchable.
* **Affects:** maintainability (operability), integration reliability.
* **Files:** `classes/AuraErrorFactory.cls`, `classes/ERPSyncScheduler.cls`, `classes/ERPSyncQueueable.cls`, `classes/ERPIntegrationService.cls`, `classes/QuoteSharingService.cls`.
* **Resolution.** New `Log_Event__e` (Publish Immediately) → `LogEventTrigger` → `Application_Log__c`, written by `Logger`. All former debug-only error paths use it.

### W10 — Idempotency key cannot distinguish a deliberate resend *(Medium, integration reliability)*
* **Why it is a problem.** `Idempotency-Key = qf-quote-<id>` is constant for the life of the quote. After a permanent failure (e.g. 422 unknown SKU) is fixed and the quote requeued, a standards-following ERP replays the **stored 422** for that key. The requeue tool can never succeed.
* **Senior approach.** Key = quote + *sync generation*. Retries of one generation reuse the key (safe replay); an operator requeue starts a new generation.
* **Affects:** integration reliability.
* **Files:** `classes/ERPIntegrationService.cls`, `objects/Quote__c/fields/`.
* **Resolution.** New `Quote__c.ERP_Sync_Generation__c`; key `qf-quote-<id>-g<n>`; `requeueFailed` increments it; tests updated.

### W11 — LWC: stale data from an imperative cacheable call, deprecated directives, duplicated policy *(Medium, LWC quality)*
* **Why it is a problem.** `quoteConfigurator.refreshApproval` calls `getApprovalSummary` (`cacheable=true`) imperatively after save **and after submit**; the second call can be served from the Lightning Data Service cache, so the badge still says *Draft*. Templates use deprecated `if:true/if:false`. The 60% discount cap and USD are hard-coded in two places each, so client and server can drift.
* **Senior approach.** Non-cacheable read for post-mutation refresh (or `refreshApex` on a wire); `lwc:if/lwc:else`; get policy limits from the server context; currency from the org.
* **Affects:** maintainability, correctness.
* **Files:** `lwc/quoteConfigurator/*`, `lwc/quoteApprovalPanel/*`, `classes/QuoteApprovalController.cls`, `classes/QuoteConfiguratorController.cls`.
* **Resolution.** `QuoteApprovalController.getApprovalSummaryFresh` (non-cacheable) for imperative refresh; `lwc:if` everywhere; `ContextInfo.maxManualDiscountPct` and `currencyIsoCode` drive the client; shared `quoteFormat` service module.

### W12 — No LWC unit tests *(Medium, testing)*
* **Why it is a problem.** The most interactive logic (debounce, out-of-order guard, rejection-comment rule, action visibility) is untested; controller tests cannot see it.
* **Senior approach.** `sfdx-lwc-jest` with wire adapters mocked; test behaviour (what renders, what Apex is called with), not implementation.
* **Affects:** testing.
* **Files:** `lwc/*/__tests__/`.
* **Resolution.** Jest suites for both components and the shared module; run in CI.

### W13 — Apex tests miss the personas that break *(High, testing)*
* **Why it is a problem.** Most tests run as the CI admin (profile has Modify All Data), which is precisely why W1–W3 are invisible. No test exercises the integration user, a share-only approver, the scheduler or the purge batch. Assertions use legacy `System.assert*`. The code has never been executed, so "tests pass" is unknown.
* **Senior approach.** Persona tests for each permission set group that matters, regression tests for each defect, modern `Assert` class, and say plainly that the suite has not been run.
* **Affects:** testing.
* **Files:** `classes/*Test.cls`, `classes/TestDataFactory.cls`.
* **Resolution.** New persona and regression tests (integration user, role-less manager and finance approvers, non-owner submit/convert, cascade delete, bulk bundles, logger, scheduler/purge); all test classes migrated to `Assert`.

### W14 — CI fails before it validates anything *(High, CI/CD)*
* **Why it is a problem.** `validate-pr.yml` runs `npm ci` with `cache: npm`, but there is no `package-lock.json` → the job fails at step one. `package.json` pins `@lwc/eslint-plugin-lwc ^1.8` against `@salesforce/eslint-config-lwc ^3.6` (which resolves to 3.7.x, peer `^2`) → `ERESOLVE`. Even with dependencies installed, `prettier:verify` would fail: the Apex was never Prettier-formatted and `.prettierrc` did not load the Apex plugin. PR validation targets one shared CI sandbox, so concurrent PRs overwrite each other.
* **Senior approach.** Committed lockfile, consistent peer versions, Jest in the static stage, an ephemeral scratch org per PR from a Dev Hub, and a separate release validation against a sandbox.
* **Affects:** deployment, testing.
* **Files:** `package.json`, `package-lock.json`, `.github/workflows/validate-pr.yml`.
* **Resolution.** Lockfile generated; dependency set fixed; Apex plugin configured and all sources formatted; PR pipeline = static checks + Jest → scratch-org deploy + `RunLocalTests` with per-class coverage gate → scratch org deleted.

### W15 — Release pipeline does not match the documented process *(High, CI/CD)*
* **Why it is a problem.** README/DEPLOYMENT describe a UAT stage that `deploy.yml` does not have. `workflow_dispatch` with `target=production` deploys **whatever branch it was run from**. Quick deploy uses a manually maintained repository variable that can point at a validation of a different commit. No concurrency guard; `@salesforce/cli` unpinned; `contents: write` granted to every job.
* **Senior approach.** Validate the exact commit in the same run, gate with environment reviewers, quick-deploy *that* job id; restrict production to `main`; pin tooling; least-privilege job permissions; serialise deployments per environment.
* **Affects:** deployment, security.
* **Files:** `.github/workflows/deploy.yml`, `docs/DEPLOYMENT.md`.
* **Resolution.** Rewritten: `develop` → integration; `main` → validate (job id captured) → UAT deploy → production quick-deploy of the same validation after approval; branch guards, concurrency, pinned CLI, scoped permissions.

---

## Ranking by the requested priorities

| Priority | Findings |
|---|---|
| 1 Apex architecture | W1, W5 |
| 2 Governor-limit safety | W6 |
| 3 Bulkification | W6, W7 |
| 4 CRUD/FLS security | W2, W5 |
| 5 Sharing/security | W1, W4, W8 |
| 6 Error handling | W9 |
| 7 Integration reliability | W2, W3, W10 |
| 8 LWC quality | W11 |
| 9 Test quality | W12, W13 |
| 10 CI/CD architecture | W14, W15 |

## What was deliberately *not* changed

* Custom objects instead of the CPQ managed package (TD-01) — a portfolio trade-off, documented, not a defect.
* Custom approval engine instead of the native Approval Process (TD-02).
* Poll-and-lease dispatch (TD-07). Platform Events / CDC remain the documented next step.
* A trigger framework (TD-04) — three triggers do not justify one.

## Resolution log

| Finding | New / changed files |
|---|---|
| W1, W5 | `QuoteStateWriter.cls` (new), `QuoteTriggerContext.cls`, `QuoteApprovalService.cls`, `QuoteCalculationService.cls`, `QuoteSharingService.cls`, `QuoteOrderService.cls`, `QuoteTriggerHandler.cls`, `TestDataFactory.cls` |
| W2 | `ERPIntegrationService.cls`, `ERPIntegrationServiceTest.cls`, `QF_Integration_User` permission set |
| W3 | `QuoteSelector.cls`, `QuoteOrderService.cls`, `QuoteConstants.cls`, `ERPIntegrationService.cls`, `QuoteOrderServiceTest.cls` |
| W4 | `QuoteApprovalService.cls`, `QuoteOrderService.cls`, `QuoteApprovalServiceTest.cls`, `QuoteOrderServiceTest.cls` |
| W6 | `ProductConfigurationService.cls`, `QuoteConfiguratorController.cls`, `ProductConfigurationServiceTest.cls` |
| W7 | `QuoteLineTriggerHandler.cls`, `QuoteTriggerTest.cls` |
| W8 | `QuoteSharingService.cls`, `QuoteApprovalService.cls`, `QuoteApprovalServiceTest.cls` |
| W9 | `Logger.cls`, `LogEventTriggerHandler.cls`, `LogEventTrigger.trigger`, `Log_Event__e`, `Application_Log__c` (all new), `AuraErrorFactory.cls`, `ERPSyncScheduler.cls`, `ERPSyncQueueable.cls`, `LoggerTest.cls` |
| W10 | `Quote__c.ERP_Sync_Generation__c` (new), `ERPIntegrationService.cls`, `QuoteApprovalService.cls` |
| W11 | `quoteConfigurator`, `quoteApprovalPanel`, `quoteFormat` (new), `QuoteApprovalController.cls`, `QuoteConfiguratorController.cls` |
| W12 | `lwc/*/__tests__/*.test.js`, `jest.config.js` |
| W13 | all `*Test.cls`, `AsyncJobsTest.cls` (new) |
| W14 | `package.json`, `package-lock.json`, `.github/workflows/validate-pr.yml` |
| W15 | `.github/workflows/deploy.yml`, `docs/DEPLOYMENT.md` |

---

## Talking points for a technical interview

Short, defensible answers grounded in this repository. None of them claim the code has run in an org.

* **"Why is there a `without sharing` class in a security-focused design?"** Because `with sharing` + plain DML still enforces record
  sharing, and the users who legitimately change approval state often only have Read. The answer is not to grant Edit (that opens the API
  to forgery) but to authorise in the service and make the elevation one small, allow-listed, reviewed class (`QuoteStateWriter`, TD-17).
* **"How would you have caught W1-W3 earlier?"** By testing as the persona. The CI runner's profile has Modify All Data, so every
  sharing and record-access defect passes. The fixed suite runs each journey as a user holding only the shipped permission sets, and
  `scripts/ci/check_fls.py` statically checks that every `WITH USER_MODE` field is readable by the personas that reach it.
* **"What does View All actually give the integration user?"** Read on every record, not edit. Least privilege here means
  read-only on quotes plus a scoped writer for the ERP fields, rather than Modify All.
* **"Why a sync generation in the idempotency key?"** Idempotent APIs typically cache the response per key; without a generation an
  operator requeue after a fixed 422 would be answered with the same 422 forever (TD-19).
* **"Why Platform Events for logging?"** Publish Immediately survives rollback, which is exactly when you need the log; cacheable
  reads cannot publish, so they fall back to the debug log. On a real project use an established logger (TD-18).
* **"What is still not proven?"** The Apex has never been compiled against an org or executed. The first PR pipeline run is the next
  step, and a fix-up pass is expected. LWC Jest tests, lint, formatting and the static FLS check have been run locally.
