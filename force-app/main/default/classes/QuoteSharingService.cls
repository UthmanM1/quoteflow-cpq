/**
 * Apex managed sharing for approvers. Approvers outside the owner's role line (Finance Director, and any manager
 * linked only through User.ManagerId) cannot see a Private quote through the hierarchy, so the approval service
 * grants Read with the Approver_Access sharing reason.
 *
 * Lifecycle of a share
 *   granted  when a request is assigned to the approver
 *   kept     after the approver decides, so they can reopen what they approved/rejected (audit)
 *   revoked  when a pending request is superseded (recall, resubmission) and the user has not decided any
 *            other level of the same quote
 *
 * Writes go through QuoteStateWriter: the user who triggers the grant (for example a Finance Director approving
 * level 2 and thereby assigning level 3) usually has only Read access and could not create a share in user context.
 */
public with sharing class QuoteSharingService {
    /** @param approverByQuote quote Id to the user who has to decide on it */
    public static void grantApproverAccess(Map<Id, Id> approverByQuote, Map<Id, Id> ownerByQuote) {
        List<Quote__Share> shares = new List<Quote__Share>();
        for (Id quoteId : approverByQuote.keySet()) {
            Id approverId = approverByQuote.get(quoteId);
            // The owner already has full access; a share for them would be rejected by the platform.
            if (approverId == null || approverId == ownerByQuote.get(quoteId)) {
                continue;
            }
            shares.add(
                new Quote__Share(
                    ParentId = quoteId,
                    UserOrGroupId = approverId,
                    AccessLevel = 'Read',
                    RowCause = Schema.Quote__Share.RowCause.Approver_Access__c
                )
            );
        }
        // Partial success on purpose: a duplicate share (resubmission to the same approver) must not fail the submission.
        List<Database.SaveResult> results = QuoteStateWriter.insertApproverShares(shares);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess() && !isDuplicate(results[i].getErrors())) {
                Logger.error(
                    'QuoteSharingService.grantApproverAccess',
                    'Approver share failed for user ' +
                        shares[i].UserOrGroupId +
                        ': ' +
                        results[i].getErrors()[0].getMessage(),
                    null,
                    shares[i].ParentId
                );
            }
        }
    }

    /** @param usersByQuote quote Id to the users whose Approver_Access share should be removed */
    public static void revokeApproverAccess(Map<Id, Set<Id>> usersByQuote) {
        if (usersByQuote == null || usersByQuote.isEmpty()) {
            return;
        }
        List<Quote__Share> toDelete = new List<Quote__Share>();
        for (Quote__Share share : QuoteStateWriter.approverShares(usersByQuote.keySet())) {
            Set<Id> users = usersByQuote.get(share.ParentId);
            if (users != null && users.contains(share.UserOrGroupId)) {
                toDelete.add(share);
            }
        }
        List<Database.DeleteResult> results = QuoteStateWriter.deleteApproverShares(toDelete);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Logger.error(
                    'QuoteSharingService.revokeApproverAccess',
                    'Approver share not revoked: ' + results[i].getErrors()[0].getMessage(),
                    null,
                    toDelete[i].ParentId
                );
            }
        }
    }

    private static Boolean isDuplicate(List<Database.Error> errors) {
        for (Database.Error error : errors) {
            if (
                error.getStatusCode() == StatusCode.DUPLICATE_VALUE ||
                error.getStatusCode() == StatusCode.FIELD_INTEGRITY_EXCEPTION
            ) {
                return true;
            }
        }
        return false;
    }
}
