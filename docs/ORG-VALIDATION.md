# Real Org Validation

This is the evidence log for running the repository in a real Salesforce org. **Every item starts as NOT VERIFIED.**
Only the person who runs the step in Salesforce changes an item, and only with evidence (CLI output, test result,
screenshot file name, record Id). Until then, nothing in this repository should be described as working in an org.

How to fill it in: tick the box, replace `NOT VERIFIED` with `VERIFIED` or `FAILED`, add the date, org type
(Developer Edition / Trailhead Playground / scratch org), and the evidence. Commands are in [SALESFORCE-CLI.md](SALESFORCE-CLI.md).

Org used: _not yet recorded_ · CLI version: _not yet recorded_ · Commit: _not yet recorded_

## RevOps Lab (`revops-lab/`)

| # | Check | Status | How to verify | Evidence / notes |
|---|---|---|---|---|
| 1 | [ ] Org authorized | NOT VERIFIED | `sf org login web --alias revops-dev`; `sf org display` shows the org | |
| 2 | [ ] Metadata deployed | NOT VERIFIED | `sf project deploy start --source-dir revops-lab --wait 30` succeeds; job id recorded | |
| 3 | [ ] Objects verified | NOT VERIFIED | Object Manager shows Quote Configuration (+ Line), Sales Approval Request, Discount Policy, Sales Integration Log, Sales Subscription; Org-wide defaults match [revops-lab/SECURITY.md](revops-lab/SECURITY.md) | |
| 4 | [ ] Fields verified | NOT VERIFIED | Roll-up summaries on Quote Configuration recalculate when a line is added; custom fields on Account, Contact, Opportunity, Product2, Pricebook2, Order exist; page layouts show them | |
| 5 | [ ] Permission sets verified | NOT VERIFIED | 7 permission sets and 6 groups present; each group status *Updated*; a test user per persona sees what [FIELD-LEVEL-SECURITY.md](revops-lab/FIELD-LEVEL-SECURITY.md) says | |
| 6 | [ ] Flows activated | NOT VERIFIED | Setup > Flows: the four `Sales_*` flows are Active; creating a quote defaults Valid Until; approval creates the approver task | |
| 7 | [ ] Apex compiled | NOT VERIFIED | Deployment succeeds without compile errors; Setup > Apex Classes shows the lab classes | |
| 8 | [ ] Apex tests executed | NOT VERIFIED | `sf apex run test --test-level RunLocalTests --code-coverage`; record pass/fail counts and coverage per class | |
| 9 | [ ] LWC deployed | NOT VERIFIED | Both components appear in Lightning App Builder (Opportunity / Quote Configuration record pages) | |
| 10 | [ ] LWC tested inside Lightning | NOT VERIFIED | Configurator: add products, see preview, policy error at an over-limit discount, save, submit. Panel: approve/reject as the approver, convert as the owner | |
| 11 | [ ] Sample Account created | NOT VERIFIED | Seed script or manual; record Id | |
| 12 | [ ] Sample Opportunity created | NOT VERIFIED | With the standard price book; record Id | |
| 13 | [ ] Sample Quote created | NOT VERIFIED | Through `salesQuoteConfigurator`; QC number and totals | |
| 14 | [ ] Approval workflow tested | NOT VERIFIED | One quote per tier: auto-approve (<= 10%), manager (> 10%), finance (> 20%), director (> 30%); rejection with comment | |
| 15 | [ ] Order conversion tested | NOT VERIFIED | Order + OrderItems + Sales Subscription created; quote Ordered; opportunity can then be Closed Won | |
| 16 | [ ] Integration mock tested | NOT VERIFIED | `SalesERPIntegrationServiceTest` passes (HttpCalloutMock). Optional: a real mock endpoint behind the `Sales_ERP` Named Credential | |

## Known deployment risks to check first

These could not be proven without an org; expect to adjust them on the first deployment and record what changed.

| Risk | Where | What to do if it fails |
|---|---|---|
| Custom tab `motif` value (`Custom20: Airplane`) not accepted | `revops-lab/main/default/tabs` | Pick an icon in Setup > Tabs, retrieve the tab, commit |
| Page layout not assigned to your profile | `revops-lab/main/default/layouts` | Setup > Object Manager > Page Layouts > Page Layout Assignment |
| Orders not enabled | Order fields, conversion | Setup > Order Settings > Enable Orders, then redeploy |
| StageName *Negotiation/Review* missing | `Sales_Quote_Approved_Update_Opportunity` flow | Change the flow's stage value to one that exists |
| Criteria sharing rule not applied in Apex tests | `SalesQuoteApprovalServiceTest.tier2_*` | Check Setup > Sharing Settings recalculation; record the result |
| Permission set group not yet *Updated* when assigned | PSG assignment | Wait for recalculation, then assign |
| Standard profile name differs (*Standard User*) | `SalesLabTestFactory.user` | Adjust the profile query to an existing profile |

## Main QuoteFlow layer (`force-app/`) - optional second pass

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| M1 | [ ] Deployed to a scratch org | NOT VERIFIED | |
| M2 | [ ] Apex tests executed with coverage | NOT VERIFIED | |
| M3 | [ ] `quoteConfigurator` and `quoteApprovalPanel` tested inside Lightning | NOT VERIFIED | |
| M4 | [ ] PR pipeline (`validate-pr.yml`) run end to end | NOT VERIFIED | |
| M5 | [ ] Object permissions on `OrderItem` / `PricebookEntry` in `QF_*` permission sets accepted | NOT VERIFIED | These objects normally inherit access from Order / Pricebook2 and Product2; remove the entries if the deployment rejects them |

## Locally verified (no org involved)

For completeness, these checks have been run on the source and are **not** org evidence:
Apex parses (`prettier-plugin-apex`); metadata XML is well-formed and in schema order; persona FLS static check passes
for both layers; generated permission sets match their generator; LWC ESLint passes; 39 Jest tests pass across both layers.
