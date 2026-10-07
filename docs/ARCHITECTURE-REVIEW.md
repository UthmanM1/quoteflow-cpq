# Architecture Review (risk register)

The original self-review, kept as a living risk register. Severity: **H** high, **M** medium, **L** low.
The later [principal architect review](PRINCIPAL-REVIEW.md) found runtime defects this register had missed (sharing on approvals,
integration-user write access, an unqueried field in order conversion) and drove the current revision.

## Status after the principal review

| Item | Status |
|---|---|
| S1 approver shares never revoked | **Partly resolved**: revoked when a pending request is superseded (recall/resubmission); still open for cancellation and ownership change |
| S2 system-mode writes rely on discipline | **Resolved**: single `QuoteStateWriter` with a field allow-list, CODEOWNERS entry and PR checklist item; a Code Analyzer rule is still a "revisit" (TD-17) |
| G1 bundle validation SOQL per bundle | **Resolved**: `ProductConfigurationService.configureAll`, two queries for any number of bundles |
| Testing gaps: Jest, non-rep personas | **Resolved**: 22 Jest tests; finance, role-less manager, VP and integration personas tested |
| Technical debt: errors visible only in debug logs | **Resolved**: `Logger` → `Log_Event__e` → `Application_Log__c` |
| D1 pipeline unproven | **Open**: the pipeline is now consistent (lockfile, scratch org per PR, validated quick deploy) but has still never run |
| Everything else below | Open as described |

## Overall verdict

The design is coherent: thin entry points, policy as metadata, bulk-safe pricing, explicit security boundaries and a resilient integration.
The largest risk is not architectural but **unverified code**: nothing has been compiled against a real org or run. Fix that first.

## Findings and proposed improvements

### Security
| # | Sev | Finding | Improvement |
|---|---|---|---|
| S1 | M | Approver share rows are never revoked (cancel, owner change, reassignment). | Remove `Approver_Access` shares on terminal states; scheduled reconciliation. |
| S2 | M | Several system-mode writes rely on code review discipline. | Centralise in one `QuoteSystemWriter` class, add PMD rule banning `update`/`insert` outside it, and test each caller for authorisation. |
| S3 | M | `Integration_Log__c` stores request/response bodies; redaction is regex-based and may miss field names. | Shield Platform Encryption on body fields; allow-list payload fields instead of deny-list redaction. |
| S4 | M | Approver identity is a single user; no delegation or out-of-office. | Delegated approver field with date range, audited. |
| S5 | L | `Product_Option__c` is Public Read/Write; edit prevented only by CRUD. | Private-with-sharing or Public Read Only plus an editor permission set. |
| S6 | L | No automated permission regression check. | CI job diffing permission-set XML against an approved baseline. |

### Governor limits
| # | Sev | Finding | Improvement |
|---|---|---|---|
| G1 | M | `previewPricing`/`saveQuote` validate bundles in a loop (about 5 SOQL per bundle, capped at 5 bundles). | Bulkify `ProductConfigurationService` to accept many bundles per call. |
| G2 | M | `reprice` updates all lines in one transaction; very large quotes could approach the 10,000 DML-row or CPU limits. | Queueable/batch reprice above a line-count threshold. |
| G3 | L | Catalogue query capped at 200 entries. | Server-side search with pagination. |
| G4 | L | Row locks (`FOR UPDATE`) on a quote during decisions can collide with ERP updates. | Keep lock scope narrow (already single quote); add retry on `UNABLE_TO_LOCK_ROW`. |

### Scalability
| # | Sev | Finding | Improvement |
|---|---|---|---|
| C1 | M | Dispatch ceiling about 600 quotes/hour and up to 5 minutes latency. | Platform Event or CDC-driven dispatch; tune batch size with ERP rate limits. |
| C2 | M | `Integration_Log__c` growth. | Retention batch exists; add Big Object/external archive for audit needs. |
| C3 | L | Per-line volume tiers only. | Quote-level aggregate tiering via a calculation pass. |

### Maintainability
| # | Sev | Finding | Improvement |
|---|---|---|---|
| M1 | M | Custom `Quote__c` model diverges from the CPQ managed package; migration would be a project. | Isolate pricing and approval behind interfaces so a CPQ adapter can replace the data layer. |
| M2 | L | Picklist values duplicated as constants. | Generate from describe or enforce through tests. |
| M3 | L | Static feature flags (`QuoteTriggerContext`) are implicit coupling. | Move to an explicit execution-context object passed to services. |
| M4 | L | DTOs are nested in services and controllers, so LWC-facing types leak into domain classes. | Move to a `QuoteDto` namespace class. |

### Integration
| # | Sev | Finding | Improvement |
|---|---|---|---|
| I1 | H | The ERP contract is assumed; real field names, status semantics and limits will differ. | Contract tests against the ERP sandbox; OpenAPI-driven DTO generation. |
| I2 | M | No circuit breaker: an ERP outage consumes attempts for every quote. | Metadata kill-switch and automatic open/half-open state. |
| I3 | M | One-way only; ERP changes (cancelled orders, status) do not return. | Signed inbound REST resource or event subscription. |
| I4 | L | Single currency and no jitter. | Multi-currency support; jitter if several dispatchers exist. |

### Technical debt
No Lightning pages, layouts, tabs or list views in source; quote document generation not implemented; the rejection flow ships inactive; the
named credential is specification only; `Integration_Log__c` has no UI. Permission set metadata was generated by script from the field list; a
reviewer should confirm FLS against the SECURITY.md matrix in an org.

### Deployment
| # | Sev | Finding | Improvement |
|---|---|---|---|
| D1 | H | Pipeline unproven; secrets, environments and sandboxes do not exist. | Stand up a free scratch-org pipeline first and capture a real run. |
| D2 | M | Roles/groups/sharing rule and permission set groups have deployment ordering and calculation delays. | Post-deploy script waiting for PSG status `Updated`. |
| D3 | M | Manual steps (named credential, user assignment, schedules) can be forgotten. | Post-deploy checklist enforced by a smoke test run as the integration user. |

### Testing gaps
No Apex test has been executed; no UI/e2e tests; no concurrency simulation; no load test of 10k+ lines; no mutation testing. Add them in that order after the first green run.

## Recommended sequence

1. Deploy to a scratch org, fix compile errors, run all tests, record real coverage (D1, test gap).
2. Contract-test the ERP (I1) and add the circuit breaker (I2).
3. Finish share revocation for cancellation and ownership change (S1).
4. Add Lightning pages and the permission-diff CI check (S6).
