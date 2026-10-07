/**
 * Quote approval workflow: submission, sequential multi-level routing, decisions and recall.
 *
 * Routing is driven by Approval_Threshold__mdt. A quote whose highest line discount exceeds the level-N
 * threshold needs approval at every configured level from the lowest up to N, in order.
 *
 * Security model
 *   - Reads run in user mode (QuoteSelector): a user who cannot see the quote cannot act on it.
 *   - Authorisation is explicit and lives here, not in the UI: only the owner (or a holder of the
 *     QF_Override_Quote_Lock break-glass permission) may submit or recall; only the assigned approver may decide.
 *   - State changes (quote status, approval rows, approver shares) are written through QuoteStateWriter, because
 *     approvers typically hold only Read access to the quote (Apex share or Finance sharing rule) and no persona has
 *     edit FLS on approval fields. A `with sharing` service doing plain DML would fail for exactly those approvers.
 *   - Each public operation is atomic: a savepoint is rolled back if any step fails.
 */
public with sharing class QuoteApprovalService {
    public static final Integer MIN_REJECTION_COMMENT_LENGTH = 10;

    public class SubmissionResult {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public Boolean success = false;
        @AuraEnabled
        public String outcome;
        @AuraEnabled
        public Integer level = 0;
        @AuraEnabled
        public String message;
    }

    // ------------------------------------------------------------------ submit

    public static List<SubmissionResult> submit(Set<Id> quoteIds) {
        Map<Id, SubmissionResult> results = new Map<Id, SubmissionResult>();
        List<Quote__c> quotes = QuoteSelector.quotesForUpdate(quoteIds);
        Set<Id> found = new Map<Id, Quote__c>(quotes).keySet();
        for (Id quoteId : quoteIds) {
            if (!found.contains(quoteId)) {
                results.put(quoteId, error(quoteId, 'Quote not found or you do not have access to it.'));
            }
        }

        Set<Id> quotesWithLines = new Set<Id>();
        for (AggregateResult row : QuoteSelector.lineTotalsByQuote(found)) {
            if ((Integer) row.get('lineCount') > 0) {
                quotesWithLines.add((Id) row.get('quoteId'));
            }
        }

        Boolean canActForOthers = FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION);
        List<Quote__c> needsApproval = new List<Quote__c>();
        List<Quote__c> autoApproved = new List<Quote__c>();
        for (Quote__c quote : quotes) {
            String problem = submissionProblem(quote, quotesWithLines, canActForOthers);
            if (problem != null) {
                results.put(quote.Id, error(quote.Id, problem));
            } else if (DiscountEvaluationService.evaluate(quote.Max_Line_Discount_Pct__c).approvalRequired) {
                needsApproval.add(quote);
            } else {
                autoApproved.add(quote);
            }
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            saveAutoApproved(autoApproved, results);
            saveForApproval(needsApproval, results);
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
        return results.values();
    }

    // ------------------------------------------------------------------ decide

    public static void decide(Id approvalRequestId, Boolean approve, String comments) {
        if (approvalRequestId == null || approve == null) {
            throw new QuoteFlowException('An approval request and a decision are required.');
        }
        List<Approval_Request__c> requests = QuoteSelector.requestForUpdate(approvalRequestId);
        if (requests.isEmpty()) {
            throw new QuoteFlowException('Approval request not found or you do not have access to it.');
        }
        Approval_Request__c request = requests[0];
        if (request.Status__c != QuoteConstants.REQUEST_PENDING) {
            throw new QuoteFlowException('This request has already been actioned.');
        }
        if (request.Approver__c != UserInfo.getUserId()) {
            throw new QuoteFlowException('Only the assigned approver can decide on this request.');
        }
        if (!approve && (String.isBlank(comments) || comments.trim().length() < MIN_REJECTION_COMMENT_LENGTH)) {
            throw new QuoteFlowException(
                'Please explain the rejection (at least ' + MIN_REJECTION_COMMENT_LENGTH + ' characters).'
            );
        }

        List<Quote__c> locked = QuoteSelector.quotesForUpdate(new Set<Id>{ request.Quote__c });
        if (locked.isEmpty()) {
            throw new QuoteFlowException('The quote is no longer available.');
        }
        Quote__c quote = locked[0];
        Integer requestLevel = Integer.valueOf(request.Approval_Level__c);
        if (
            quote.Status__c != QuoteConstants.STATUS_PENDING_APPROVAL ||
            nz(quote.Current_Approval_Level__c) != requestLevel
        ) {
            throw new QuoteFlowException('The quote has changed since this request was raised. Refresh and try again.');
        }

        Approval_Request__c decision = new Approval_Request__c(
            Id = request.Id,
            Status__c = approve ? QuoteConstants.REQUEST_APPROVED : QuoteConstants.REQUEST_REJECTED,
            Decision_Date__c = Datetime.now(),
            Decision_Comments__c = comments == null ? null : comments.trim()
        );

        Quote__c quoteUpdate = new Quote__c(Id = quote.Id);
        List<Approval_Request__c> nextRequests = new List<Approval_Request__c>();
        Map<Id, Id> shareApprover = new Map<Id, Id>();

        if (!approve) {
            quoteUpdate.Status__c = QuoteConstants.STATUS_REJECTED;
            quoteUpdate.Approval_Status__c = QuoteConstants.APPROVAL_REJECTED;
        } else {
            Integer nextLevel = nextLevel(requestLevel, Integer.valueOf(nz(quote.Required_Approval_Level__c)));
            if (nextLevel == 0) {
                markApproved(quoteUpdate);
            } else {
                Map<Id, Id> approvers = resolveApprovers(new List<Quote__c>{ quote }, nextLevel);
                if (approvers.get(quote.Id) == null) {
                    throw new QuoteFlowException(
                        'No eligible approver is configured for level ' + nextLevel + '. Contact your administrator.'
                    );
                }
                nextRequests.add(
                    buildRequest(quote, nextLevel, approvers.get(quote.Id), request.Requested_Discount_Pct__c)
                );
                quoteUpdate.Current_Approval_Level__c = nextLevel;
                shareApprover.put(quote.Id, approvers.get(quote.Id));
            }
        }

        Savepoint savepoint = Database.setSavepoint();
        try {
            QuoteStateWriter.updateApprovalRequests(new List<Approval_Request__c>{ decision });
            QuoteStateWriter.updateQuotes(new List<Quote__c>{ quoteUpdate });
            if (!nextRequests.isEmpty()) {
                QuoteStateWriter.insertApprovalRequests(nextRequests);
                QuoteSharingService.grantApproverAccess(shareApprover, new Map<Id, Id>{ quote.Id => quote.OwnerId });
            }
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
    }

    // ------------------------------------------------------------------ recall

    public static void recall(Id quoteId) {
        List<Quote__c> locked = QuoteSelector.quotesForUpdate(new Set<Id>{ quoteId });
        if (locked.isEmpty()) {
            throw new QuoteFlowException('Quote not found or you do not have access to it.');
        }
        Quote__c quote = locked[0];
        if (!isOwnerOrOverride(quote, FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION))) {
            throw new QuoteFlowException('Only the quote owner can recall it.');
        }
        if (quote.Status__c != QuoteConstants.STATUS_PENDING_APPROVAL) {
            throw new QuoteFlowException('Only quotes pending approval can be recalled.');
        }
        Savepoint savepoint = Database.setSavepoint();
        try {
            supersedePendingRequests(new Set<Id>{ quoteId });
            QuoteStateWriter.updateQuotes(
                new List<Quote__c>{
                    new Quote__c(
                        Id = quoteId,
                        Status__c = QuoteConstants.STATUS_DRAFT,
                        Approval_Status__c = QuoteConstants.APPROVAL_NOT_SUBMITTED,
                        Current_Approval_Level__c = 0
                    )
                }
            );
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
    }

    // ------------------------------------------------------------------ approver resolution

    /** One user query for managers and one for role holders, regardless of how many quotes are passed in. */
    @TestVisible
    private static Map<Id, Id> resolveApprovers(List<Quote__c> quotes, Integer level) {
        Map<Id, Id> approverByQuote = new Map<Id, Id>();
        Approval_Threshold__mdt threshold = DiscountEvaluationService.thresholdForLevel(level);
        if (threshold == null) {
            return approverByQuote;
        }
        if (threshold.Approver_Type__c == 'Manager') {
            Set<Id> ownerIds = new Set<Id>();
            for (Quote__c quote : quotes) {
                ownerIds.add(quote.OwnerId);
            }
            Map<Id, User> owners = QuoteSelector.usersWithManager(ownerIds);
            for (Quote__c quote : quotes) {
                User owner = owners.get(quote.OwnerId);
                if (owner != null && owner.ManagerId != null && owner.Manager.IsActive) {
                    approverByQuote.put(quote.Id, owner.ManagerId);
                }
            }
        } else if (String.isNotBlank(threshold.Approver_Role_Developer_Name__c)) {
            List<User> holders = QuoteSelector.activeUsersInRoles(
                new Set<String>{ threshold.Approver_Role_Developer_Name__c }
            );
            for (Quote__c quote : quotes) {
                for (User holder : holders) {
                    // Never route a quote to its own owner (no self-approval).
                    if (holder.Id != quote.OwnerId) {
                        approverByQuote.put(quote.Id, holder.Id);
                        break;
                    }
                }
            }
        }
        return approverByQuote;
    }

    // ------------------------------------------------------------------ internals

    private static String submissionProblem(Quote__c quote, Set<Id> quotesWithLines, Boolean canActForOthers) {
        if (!isOwnerOrOverride(quote, canActForOthers)) {
            return 'Only the quote owner can submit it for approval.';
        }
        if (!QuoteConstants.EDITABLE_STATUSES.contains(quote.Status__c)) {
            return 'Only Draft or Rejected quotes can be submitted (current status: ' + quote.Status__c + ').';
        }
        if (!quotesWithLines.contains(quote.Id)) {
            return 'Add at least one line before submitting the quote.';
        }
        if (nz(quote.Max_Line_Discount_Pct__c) < 0) {
            return 'Quote totals are inconsistent. Re-save the quote lines and try again.';
        }
        return null;
    }

    private static Boolean isOwnerOrOverride(Quote__c quote, Boolean canActForOthers) {
        return quote.OwnerId == UserInfo.getUserId() || canActForOthers;
    }

    private static void saveAutoApproved(List<Quote__c> quotes, Map<Id, SubmissionResult> results) {
        if (quotes.isEmpty()) {
            return;
        }
        List<Quote__c> updates = new List<Quote__c>();
        for (Quote__c quote : quotes) {
            Quote__c update_ = new Quote__c(Id = quote.Id);
            markApproved(update_);
            update_.Approval_Status__c = QuoteConstants.APPROVAL_NOT_REQUIRED;
            updates.add(update_);
        }
        List<Database.SaveResult> saved = QuoteStateWriter.updateQuotesPartial(updates);
        for (Integer i = 0; i < saved.size(); i++) {
            SubmissionResult result = new SubmissionResult();
            result.quoteId = updates[i].Id;
            result.success = saved[i].isSuccess();
            result.outcome = saved[i].isSuccess() ? 'Approved' : 'Error';
            result.message = saved[i].isSuccess()
                ? 'Within discount policy; approved automatically.'
                : saved[i].getErrors()[0].getMessage();
            results.put(result.quoteId, result);
        }
    }

    private static void saveForApproval(List<Quote__c> quotes, Map<Id, SubmissionResult> results) {
        if (quotes.isEmpty()) {
            return;
        }
        Map<Id, Quote__c> quoteById = new Map<Id, Quote__c>(quotes);
        Map<Id, Integer> firstLevelByQuote = new Map<Id, Integer>();
        Map<Id, Id> approverByQuote = new Map<Id, Id>();

        // Group by first level so approver lookup stays one query per level, not per quote.
        Map<Integer, List<Quote__c>> byLevel = new Map<Integer, List<Quote__c>>();
        for (Quote__c quote : quotes) {
            Integer required = DiscountEvaluationService.evaluate(quote.Max_Line_Discount_Pct__c).level;
            Integer first = nextLevel(0, required);
            if (first == 0) {
                results.put(
                    quote.Id,
                    error(quote.Id, 'No approval level is configured for this discount. Contact your administrator.')
                );
                continue;
            }
            firstLevelByQuote.put(quote.Id, first);
            if (!byLevel.containsKey(first)) {
                byLevel.put(first, new List<Quote__c>());
            }
            byLevel.get(first).add(quote);
        }
        for (Integer level : byLevel.keySet()) {
            approverByQuote.putAll(resolveApprovers(byLevel.get(level), level));
        }

        List<Approval_Request__c> newRequests = new List<Approval_Request__c>();
        for (Id quoteId : firstLevelByQuote.keySet()) {
            Quote__c quote = quoteById.get(quoteId);
            if (approverByQuote.get(quoteId) == null) {
                results.put(
                    quoteId,
                    error(quoteId, 'No eligible approver was found. Check the manager hierarchy or role assignment.')
                );
                continue;
            }
            newRequests.add(
                buildRequest(
                    quote,
                    firstLevelByQuote.get(quoteId),
                    approverByQuote.get(quoteId),
                    quote.Max_Line_Discount_Pct__c
                )
            );
        }
        if (newRequests.isEmpty()) {
            return;
        }

        Set<Id> routedQuoteIds = new Set<Id>();
        for (Approval_Request__c request : newRequests) {
            routedQuoteIds.add(request.Quote__c);
        }
        supersedePendingRequests(routedQuoteIds);

        List<Database.SaveResult> inserted = QuoteStateWriter.insertApprovalRequestsPartial(newRequests);
        List<Quote__c> quoteUpdates = new List<Quote__c>();
        Map<Id, Id> sharedApprovers = new Map<Id, Id>();
        Map<Id, Id> owners = new Map<Id, Id>();
        for (Integer i = 0; i < inserted.size(); i++) {
            Id quoteId = newRequests[i].Quote__c;
            if (!inserted[i].isSuccess()) {
                results.put(quoteId, error(quoteId, inserted[i].getErrors()[0].getMessage()));
                continue;
            }
            Integer level = Integer.valueOf(newRequests[i].Approval_Level__c);
            quoteUpdates.add(
                new Quote__c(
                    Id = quoteId,
                    Status__c = QuoteConstants.STATUS_PENDING_APPROVAL,
                    Approval_Status__c = QuoteConstants.APPROVAL_PENDING,
                    Current_Approval_Level__c = level
                )
            );
            sharedApprovers.put(quoteId, newRequests[i].Approver__c);
            owners.put(quoteId, quoteById.get(quoteId).OwnerId);
            SubmissionResult result = new SubmissionResult();
            result.quoteId = quoteId;
            result.success = true;
            result.outcome = 'PendingApproval';
            result.level = level;
            result.message = 'Submitted for level ' + level + ' approval.';
            results.put(quoteId, result);
        }
        QuoteStateWriter.updateQuotes(quoteUpdates);
        QuoteSharingService.grantApproverAccess(sharedApprovers, owners);
    }

    /**
     * Marks pending requests as superseded and revokes the read access their approvers were given, unless the same
     * user decided another level of that quote (they keep access to what they decided).
     */
    private static void supersedePendingRequests(Set<Id> quoteIds) {
        List<Approval_Request__c> stale = new List<Approval_Request__c>();
        Map<Id, Set<Id>> pendingApprovers = new Map<Id, Set<Id>>();
        Map<Id, Set<Id>> decidingApprovers = new Map<Id, Set<Id>>();
        for (Approval_Request__c request : QuoteSelector.requestsForQuotes(quoteIds)) {
            if (request.Status__c == QuoteConstants.REQUEST_PENDING) {
                stale.add(new Approval_Request__c(Id = request.Id, Status__c = QuoteConstants.REQUEST_SUPERSEDED));
                addTo(pendingApprovers, request.Quote__c, request.Approver__c);
            } else if (
                request.Status__c == QuoteConstants.REQUEST_APPROVED ||
                request.Status__c == QuoteConstants.REQUEST_REJECTED
            ) {
                addTo(decidingApprovers, request.Quote__c, request.Approver__c);
            }
        }
        QuoteStateWriter.updateApprovalRequests(stale);

        Map<Id, Set<Id>> toRevoke = new Map<Id, Set<Id>>();
        for (Id quoteId : pendingApprovers.keySet()) {
            Set<Id> users = new Set<Id>(pendingApprovers.get(quoteId));
            if (decidingApprovers.containsKey(quoteId)) {
                users.removeAll(decidingApprovers.get(quoteId));
            }
            if (!users.isEmpty()) {
                toRevoke.put(quoteId, users);
            }
        }
        QuoteSharingService.revokeApproverAccess(toRevoke);
    }

    private static void addTo(Map<Id, Set<Id>> target, Id key, Id value) {
        if (value == null) {
            return;
        }
        if (!target.containsKey(key)) {
            target.put(key, new Set<Id>());
        }
        target.get(key).add(value);
    }

    private static Approval_Request__c buildRequest(Quote__c quote, Integer level, Id approverId, Decimal discountPct) {
        Approval_Threshold__mdt threshold = DiscountEvaluationService.thresholdForLevel(level);
        return new Approval_Request__c(
            Quote__c = quote.Id,
            Status__c = QuoteConstants.REQUEST_PENDING,
            Approval_Level__c = level,
            Requested_Discount_Pct__c = discountPct,
            Threshold_Pct__c = threshold == null ? null : threshold.Min_Discount_Pct__c,
            Approver__c = approverId,
            Submitted_By__c = UserInfo.getUserId(),
            Submitted_Date__c = Datetime.now()
        );
    }

    /** Approval queues the quote for the ERP as generation 1; an operator requeue starts generation 2, and so on. */
    private static void markApproved(Quote__c quoteUpdate) {
        quoteUpdate.Status__c = QuoteConstants.STATUS_APPROVED;
        quoteUpdate.Approval_Status__c = QuoteConstants.APPROVAL_APPROVED;
        quoteUpdate.Current_Approval_Level__c = 0;
        quoteUpdate.ERP_Sync_Status__c = QuoteConstants.ERP_PENDING;
        quoteUpdate.ERP_Sync_Attempts__c = 0;
        quoteUpdate.ERP_Sync_Generation__c = 1;
        quoteUpdate.ERP_Next_Attempt_At__c = null;
    }

    /** First configured level strictly above `after` and not above `required`; 0 when there is none. */
    private static Integer nextLevel(Integer after, Integer required) {
        for (Integer level = after + 1; level <= required; level++) {
            if (DiscountEvaluationService.thresholdForLevel(level) != null) {
                return level;
            }
        }
        return 0;
    }

    private static SubmissionResult error(Id quoteId, String message) {
        SubmissionResult result = new SubmissionResult();
        result.quoteId = quoteId;
        result.outcome = 'Error';
        result.message = message;
        return result;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
