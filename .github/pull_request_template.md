## Summary

## Checklist
- [ ] Bulk-safe: no SOQL/DML in loops; query/DML budget asserted in a bulk test where the path is hot
- [ ] Reads go through `QuoteSelector` with `WITH USER_MODE`; user-initiated DML is `as user` / `AccessLevel.USER_MODE`
- [ ] System-owned fields are written **only** through `QuoteStateWriter`, after an explicit authorisation check in the calling service
- [ ] Authorisation is enforced in the service, not only hidden in the LWC
- [ ] Unexpected errors go through `Logger` / `AuraErrorFactory`, never only `System.debug`
- [ ] No business logic in triggers
- [ ] Tests assert outcomes (positive, negative, bulk) and run as the persona that will use the feature, not only as the CI admin
- [ ] LWC changes have Jest tests
- [ ] Permission set / FLS impact reviewed; `npm run check:fls` passes
- [ ] Destructive changes are in a separate release
- [ ] Docs updated (ARCHITECTURE / TECHNICAL-DECISIONS if a decision changed)
