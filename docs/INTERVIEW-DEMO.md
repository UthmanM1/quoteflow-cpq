# 15-Minute Interview Demonstration

A script for walking an interviewer through the RevOps Lab in a Salesforce org, then through the code behind it.

> Only demo in an org what you have deployed and checked yourself ([ORG-VALIDATION.md](ORG-VALIDATION.md)). If an item is
> still NOT VERIFIED, show it in the repository instead and say so - "this part I have built and unit-tested, not yet run in
> an org" is a strong, honest answer. Never describe the project as a client delivery or a production system.

## Before the interview (10 minutes of setup, not part of the 15)

* Deploy `revops-lab`, assign yourself `Sales_Lab_Base` + `Sales_Administrator_Access`, run `scripts/apex/seed-revops-lab.apex`.
* Create three users (or log in as each with *Login As*): a rep (role Sales_Representative, manager = a Sales Manager user),
  a manager (Sales_Manager) and a finance user (Finance_Manager), each with their permission set group.
* Place `salesQuoteConfigurator` on the Opportunity record page and `salesApprovalPanel` on the Quote Configuration record page.
* Prepare one quote already *Pending Approval* at tier 2 so you do not depend on live typing for the approval step.
* Open in browser tabs: the org (RevOps Lab app), the repository, the latest CI run if you have one.

---

## Minute 0-2: Salesforce org and architecture

**What to click:** App Launcher > *RevOps Lab*. Show the tabs, then the repository README.

**What to show:** the two layers - `force-app/` (custom CPQ engine) and `revops-lab/` (Sales Cloud platform build) - and the
status table: what is verified in an org, what is deployable source, what is design only.

**Technical point:** the lab is a separate package directory so it deploys on its own to a Developer Edition org; Apex has no
namespaces, so colliding class names were prefixed (`SalesQuoteApprovalService`).

**Likely question:** "Is this a real client project?"

**Strong answer:** "No. It's a portfolio project for a fictional company. I built it to show how I'd design a quote-to-order
process on the platform. The repository says exactly what has run in an org and what hasn't. ORG-VALIDATION.md is the
evidence log, and I only mark an item verified once I've run it myself."

## Minute 2-4: Account and Opportunity

**What to click:** the seeded *Northwind Demo Traders (fictional)* account > its opportunity.

**What to show:** Customer Segment and ERP Account Number on the account; the opportunity's price book; the Primary Quote
Configuration lookup (empty for now); the related list of quote configurations.

**Technical point:** extending standard objects instead of rebuilding them; `ERP_Account_Number__c` is an external id
(unique) because the ERP uses it as the customer key; the Closed Won validation rule ties the opportunity to an ordered quote.

**Likely question:** "Why a custom quote object instead of the standard Quote?"

**Strong answer:** "The standard Quote would be my first choice on a Sales Cloud project without CPQ. Here I wanted
master-detail roll-ups, a policy-driven discount cap and a custom approval audit trail on one object. That's easier to show
on a custom object, and I document the trade-off in CPQ-IMPLEMENTATION-MAPPING.md."

## Minute 4-7: Quote configuration LWC

**What to click:** on the opportunity, *Add product* twice (Platform Subscription x 10 at 25%, Implementation Package x 1).
Then set Edge Appliance to 20% discount to trigger the error, then fix it. *Save quote*.

**What to show:** the debounced server preview (totals and "Tier 2 approval required"); the instant client-side error at 20%
("between 0% and 15%"); the saved quote record with roll-up totals and the Valid Until date defaulted by the flow.

**Technical point:** the preview calls the same `ProductPricingService` / `DiscountPolicyService` code as the line trigger, so
preview and saved price cannot diverge. A sequence counter discards out-of-order responses. The client check is a
convenience; the trigger plus the `Discount_Within_Policy` validation rule are the control.

**Likely question:** "What stops someone posting a 90% discount through the API?"

**Strong answer:** "Three things, in order of execution. The before trigger stamps the policy cap from Discount_Policy__c.
The validation rule then rejects anything above it. Validation rules run after before triggers, which is why that works.
The list price is also overwritten from the price book entry, whatever the client sends. There's a test that inserts a line
directly to prove it."

## Minute 7-9: Discount and approval logic

**What to click:** *Submit for approval* on the saved quote. Open the Quote Configuration record and the `salesApprovalPanel`.
Switch to (or *Login As*) the finance user; approve the prepared tier-2 quote with a comment. Try rejecting another with "No".

**What to show:** requested discount 25%, threshold 20%, approver = finance user, the task the flow created, the approval
history; the rejection error "at least 10 characters"; after approval, the opportunity stage moved to Negotiation/Review.

**Technical point:** tiers are custom metadata (deployed configuration, read without SOQL); caps are a custom object (business
data Finance maintains). The highest tier wins, by discount **or** deal size. Finance is outside the sales role line, so a
criteria sharing rule gives it edit access while FLS keeps every field read-only.

**Likely question:** "Why not the standard Approval Process?"

**Strong answer:** "For one or two fixed steps I'd use the standard Approval Process. Here routing depends on metadata tiers
and a deal-size rule, I want a queryable audit object, and I want the decision logic unit-tested with personas. The cost
is that I've re-implemented things the platform gives you for free, like email approval and delegation. That's written
down as a trade-off in the docs."

## Minute 9-11: Apex architecture

**What to click:** repository: `SalesQuoteSelector`, `SalesQuoteApprovalService`, `QuoteConfigurationLineTriggerHandler`, one test class.

**What to show:** triggers that only delegate; all SOQL in one selector `WITH USER_MODE`; bulk `submit(Set<Id>)` with two user
queries for any number of quotes; owner and approver checks in the service; savepoints; `SalesQuoteApprovalServiceTest`
running as real personas with roles.

**Technical point:** user-mode reads, user-mode DML for user-entered data, plain DML (still `with sharing`) for system-owned
fields after explicit authorisation. One elevated writer (`ErpStateWriter`) that checks FLS before writing.

**Likely question:** "How do you know it's bulk-safe?"

**Strong answer:** "The tests assert it. 200 lines across four quotes stay under a fixed query budget, and 50 submissions
use fewer than 15 queries. I wrote those assertions before the code was finished. To be precise: the Apex tests are
written and parse, but I'll only claim they pass once the org run in ORG-VALIDATION.md is green."

## Minute 11-13: Security and permissions

**What to click:** Setup > Permission Set Groups (*Sales Representative*, *Finance Manager*); then `docs/revops-lab/SECURITY.md`
and the generated `FIELD-LEVEL-SECURITY.md`.

**What to show:** the persona table "create / edit / submit / approve / convert / run ERP sync - why or why not"; the custom
permissions used in validation rules (`$Permission.Sales_Override_Quote_Lock`); permission sets generated from one matrix.

**Technical point:** additive permission sets composed into groups; FLS makes system-owned fields read-only for everyone;
segregation of duties (the admin can override locks but cannot approve).

**Likely question:** "What's the difference between View All and Modify All, and why does it matter here?"

**Strong answer:** "View All gives read access to every record, not edit. Modify All needs Delete as well, which an
integration user shouldn't have. So the integration user reads orders in user mode with View All. It writes only five
ERP fields, through a small without-sharing writer that first checks the user has edit FLS on them. That's one documented
exception to with sharing, and it's easy to review."

## Minute 13-15: Integration and CI/CD

**What to click:** `SalesERPIntegrationService.cls`, `docs/revops-lab/samples/`, `SalesERPIntegrationServiceTest`, then
`.github/workflows/validate-pr.yml` and `deploy.yml`.

**What to show:** Named Credential endpoint (no secrets in code), typed JSON, correlation id and idempotency key, the status
table (409 with an order number = success), back-off persisted on the Order, one log row per attempt; the PR pipeline
(lint, Prettier, Jest, FLS check, metadata order, scratch-org deploy and tests with a coverage gate) and the release pipeline
(validate against production, UAT, approval, quick deploy of that exact validation).

**Technical point:** callouts before DML; retries scheduled, not looped (Apex can't sleep); the idempotency key makes
at-least-once delivery safe.

**Likely question:** "What happens if the ERP creates the order but the response is lost?"

**Strong answer:** "The call times out and is classified as retryable, so the order stays Pending. The next attempt sends
the same Idempotency-Key. A well-behaved ERP replies 409 with the original order number, and I treat that as success. The
main layer goes one step further: the key carries a sync generation, so a deliberate re-send after fixing a 422 isn't
answered with the cached failure."

---

## If something fails live

Say what you expected, show the test that covers it, and move on. Do not improvise claims about production behaviour.
