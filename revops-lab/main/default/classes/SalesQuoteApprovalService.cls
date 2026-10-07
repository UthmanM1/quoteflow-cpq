/**
 * Approval workflow for lab quotes: submit, decide, recall. (Named SalesQuoteApprovalService because the main QuoteFlow
 * layer already owns QuoteApprovalService and Apex has no namespaces inside one org.)
 *
 * Routing: DiscountPolicyService.evaluate picks the highest Approval_Routing__mdt tier that applies; one request is
 * created for that tier's approver (single-step, unlike the main layer's sequential multi-level approvals).
 *
 * Security
 *   - Reads are user-mode (SalesQuoteSelector); a user who cannot see the quote cannot act on it.
 *   - Authorisation is explicit: only the owner (or Sales_Override_Quote_Lock) submits and recalls; only the assigned
 *     approver decides. The LWC hides buttons, but these checks are the control.
 *   - Status and approval fields are read-only through FLS for every persona, so they are written with plain DML
 *     (system mode for CRUD/FLS) in this `with sharing` class: record sharing is still enforced. Approvers therefore need
 *     record edit access: managers and the director get it from the role hierarchy, Finance from the
 *     Finance_Edits_Submitted_Quotes sharing rule.
 */
public with sharing class SalesQuoteApprovalService {
    public class SubmissionResult {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public Boolean success = false;
        @AuraEnabled
        public Boolean approvalRequired = false;
        @AuraEnabled
        public Integer tier = 0;
        @AuraEnabled
        public Id approverId;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String message;
    }

    // ------------------------------------------------------------------ submit (bulk)

    public static SubmissionResult submit(Id quoteId) {
        return submit(new Set<Id>{ quoteId }).get(quoteId);
    }

    /** Bulk-safe: a constant number of queries for any number of quotes; one bad quote never blocks the others. */
    public static Map<Id, SubmissionResult> submit(Set<Id> quoteIds) {
        Map<Id, SubmissionResult> results = new Map<Id, SubmissionResult>();
        Map<Id, Quote_Configuration__c> quotes = SalesQuoteSelector.quotesForUpdate(quoteIds);
        Boolean canActForOwner = FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_OVERRIDE_LOCK);

        Map<Id, DiscountPolicyService.ApprovalDecision> decisions = new Map<Id, DiscountPolicyService.ApprovalDecision>();
        for (Id quoteId : quoteIds) {
            Quote_Configuration__c quote = quotes.get(quoteId);
            String problem = submissionProblem(quote, canActForOwner);
            if (problem != null) {
                results.put(quoteId, failure(quoteId, problem));
                continue;
            }
            decisions.put(
                quoteId,
                DiscountPolicyService.evaluate(quote.Max_Discount_Percent__c, quote.Total_Net_Amount__c)
            );
        }

        Map<Id, Id> approverByQuote = resolveApprovers(quotes, decisions);
        List<Quote_Configuration__c> quoteUpdates = new List<Quote_Configuration__c>();
        List<Sales_Approval_Request__c> requests = new List<Sales_Approval_Request__c>();
        Datetime now = Datetime.now();
        for (Id quoteId : decisions.keySet()) {
            Quote_Configuration__c quote = quotes.get(quoteId);
            DiscountPolicyService.ApprovalDecision decision = decisions.get(quoteId);
            SubmissionResult result = new SubmissionResult();
            result.quoteId = quoteId;
            result.approvalRequired = decision.approvalRequired;
            result.tier = decision.tier;
            Quote_Configuration__c quoteUpdate = new Quote_Configuration__c(
                Id = quoteId,
                Submitted_Date__c = now,
                Approval_Required__c = decision.approvalRequired,
                Required_Approval_Tier__c = decision.tier,
                Approval_Threshold_Percent__c = decision.thresholdPercent
            );
            if (!decision.approvalRequired) {
                quoteUpdate.Status__c = SalesLabConstants.QUOTE_APPROVED;
                quoteUpdate.Approved_Date__c = now;
                result.message = 'Within discount policy: approved automatically.';
            } else {
                Id approverId = approverByQuote.get(quoteId);
                if (approverId == null) {
                    results.put(
                        quoteId,
                        failure(
                            quoteId,
                            'No approver found for tier ' + decision.tier + '. Check the manager or role assignment.'
                        )
                    );
                    continue;
                }
                quoteUpdate.Status__c = SalesLabConstants.QUOTE_PENDING;
                result.approverId = approverId;
                result.message = 'Submitted for tier ' + decision.tier + ' approval (' + decision.reason + ').';
                requests.add(
                    new Sales_Approval_Request__c(
                        Quote_Configuration__c = quoteId,
                        Status__c = SalesLabConstants.REQUEST_PENDING,
                        Approver__c = approverId,
                        Requested_By__c = UserInfo.getUserId(),
                        Approval_Tier__c = decision.tier,
                        Requested_Discount_Percent__c = quote.Max_Discount_Percent__c,
                        Threshold_Percent__c = decision.thresholdPercent,
                        Quote_Amount__c = quote.Total_Net_Amount__c,
                        Submitted_Date__c = now
                    )
                );
            }
            result.status = quoteUpdate.Status__c;
            result.success = true;
            quoteUpdates.add(quoteUpdate);
            results.put(quoteId, result);
        }

        Savepoint savepoint = Database.setSavepoint();
        Boolean previous = SalesQuoteContext.enterServiceWrite();
        try {
            update quoteUpdates;
            insert requests;
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        } finally {
            SalesQuoteContext.restoreServiceWrite(previous);
        }
        return results;
    }

    // ------------------------------------------------------------------ decide

    public static void decide(Id requestId, Boolean approve, String comments) {
        if (requestId == null || approve == null) {
            throw new SalesLabException('An approval request and a decision are required.');
        }
        List<Sales_Approval_Request__c> found = SalesQuoteSelector.approvalRequestForUpdate(requestId);
        if (found.isEmpty()) {
            throw new SalesLabException('Approval request not found or you do not have access to it.');
        }
        Sales_Approval_Request__c request = found[0];
        if (request.Status__c != SalesLabConstants.REQUEST_PENDING) {
            throw new SalesLabException('This request has already been decided.');
        }
        if (request.Approver__c != UserInfo.getUserId()) {
            throw new SalesLabException('Only the assigned approver can decide on this request.');
        }
        String trimmed = comments == null ? null : comments.trim();
        if (!approve && (trimmed == null || trimmed.length() < SalesLabConstants.MIN_REJECTION_COMMENT_LENGTH)) {
            throw new SalesLabException(
                'Explain the rejection in at least ' + SalesLabConstants.MIN_REJECTION_COMMENT_LENGTH + ' characters.'
            );
        }
        Quote_Configuration__c quote = SalesQuoteSelector.quotesForUpdate(new Set<Id>{ request.Quote_Configuration__c })
            .get(request.Quote_Configuration__c);
        if (quote == null || quote.Status__c != SalesLabConstants.QUOTE_PENDING) {
            throw new SalesLabException('The quote is no longer waiting for approval. Refresh and try again.');
        }

        Datetime now = Datetime.now();
        Sales_Approval_Request__c decision = new Sales_Approval_Request__c(
            Id = request.Id,
            Status__c = approve ? SalesLabConstants.REQUEST_APPROVED : SalesLabConstants.REQUEST_REJECTED,
            Comments__c = trimmed,
            Decision_Date__c = now
        );
        Quote_Configuration__c quoteUpdate = new Quote_Configuration__c(
            Id = quote.Id,
            Status__c = approve ? SalesLabConstants.QUOTE_APPROVED : SalesLabConstants.QUOTE_REJECTED,
            Approved_Date__c = approve ? now : null
        );
        writeAtomically(
            new List<Sales_Approval_Request__c>{ decision },
            new List<Quote_Configuration__c>{ quoteUpdate }
        );
    }

    // ------------------------------------------------------------------ recall

    public static void recall(Id quoteId) {
        Quote_Configuration__c quote = SalesQuoteSelector.quotesForUpdate(new Set<Id>{ quoteId }).get(quoteId);
        if (quote == null) {
            throw new SalesLabException('Quote not found or you do not have access to it.');
        }
        if (!isOwnerOrOverride(quote, FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_OVERRIDE_LOCK))) {
            throw new SalesLabException('Only the quote owner can recall it.');
        }
        if (quote.Status__c != SalesLabConstants.QUOTE_PENDING) {
            throw new SalesLabException('Only quotes waiting for approval can be recalled.');
        }
        List<Sales_Approval_Request__c> pending = new List<Sales_Approval_Request__c>();
        for (Sales_Approval_Request__c request : SalesQuoteSelector.approvalRequestsForQuotes(new Set<Id>{ quoteId })) {
            if (request.Status__c == SalesLabConstants.REQUEST_PENDING) {
                pending.add(
                    new Sales_Approval_Request__c(Id = request.Id, Status__c = SalesLabConstants.REQUEST_RECALLED)
                );
            }
        }
        writeAtomically(
            pending,
            new List<Quote_Configuration__c>{
                new Quote_Configuration__c(Id = quoteId, Status__c = SalesLabConstants.QUOTE_DRAFT)
            }
        );
    }

    // ------------------------------------------------------------------ internals

    private static String submissionProblem(Quote_Configuration__c quote, Boolean canActForOwner) {
        if (quote == null) {
            return 'Quote not found or you do not have access to it.';
        }
        if (!isOwnerOrOverride(quote, canActForOwner)) {
            return 'Only the quote owner can submit it for approval.';
        }
        if (!SalesLabConstants.EDITABLE_QUOTE_STATUSES.contains(quote.Status__c)) {
            return 'Only Draft or Rejected quotes can be submitted (current status: ' + quote.Status__c + ').';
        }
        if (quote.Line_Count__c == null || quote.Line_Count__c == 0) {
            return 'Add at least one line before submitting.';
        }
        return null;
    }

    private static Boolean isOwnerOrOverride(Quote_Configuration__c quote, Boolean canActForOwner) {
        return quote.OwnerId == UserInfo.getUserId() || canActForOwner;
    }

    /** At most two user queries (managers, role holders), whatever the number of quotes. */
    @TestVisible
    private static Map<Id, Id> resolveApprovers(
        Map<Id, Quote_Configuration__c> quotes,
        Map<Id, DiscountPolicyService.ApprovalDecision> decisions
    ) {
        Set<Id> ownersNeedingManager = new Set<Id>();
        Set<String> roles = new Set<String>();
        for (Id quoteId : decisions.keySet()) {
            DiscountPolicyService.ApprovalDecision decision = decisions.get(quoteId);
            if (!decision.approvalRequired) {
                continue;
            }
            if (decision.approverType == SalesLabConstants.APPROVER_MANAGER) {
                ownersNeedingManager.add(quotes.get(quoteId).OwnerId);
            } else if (String.isNotBlank(decision.approverRole)) {
                roles.add(decision.approverRole);
            }
        }
        Map<Id, User> owners = SalesQuoteSelector.usersWithManager(ownersNeedingManager);
        Map<String, List<User>> holdersByRole = new Map<String, List<User>>();
        for (User holder : SalesQuoteSelector.activeUsersInRoles(roles)) {
            if (!holdersByRole.containsKey(holder.UserRole.DeveloperName)) {
                holdersByRole.put(holder.UserRole.DeveloperName, new List<User>());
            }
            holdersByRole.get(holder.UserRole.DeveloperName).add(holder);
        }

        Map<Id, Id> approverByQuote = new Map<Id, Id>();
        for (Id quoteId : decisions.keySet()) {
            DiscountPolicyService.ApprovalDecision decision = decisions.get(quoteId);
            Id ownerId = quotes.get(quoteId).OwnerId;
            if (!decision.approvalRequired) {
                continue;
            }
            if (decision.approverType == SalesLabConstants.APPROVER_MANAGER) {
                User owner = owners.get(ownerId);
                if (owner != null && owner.ManagerId != null && owner.Manager.IsActive) {
                    approverByQuote.put(quoteId, owner.ManagerId);
                }
                continue;
            }
            List<User> holders = holdersByRole.get(decision.approverRole);
            for (User holder : holders == null ? new List<User>() : holders) {
                // Never route a quote to its own owner (no self-approval).
                if (holder.Id != ownerId) {
                    approverByQuote.put(quoteId, holder.Id);
                    break;
                }
            }
        }
        return approverByQuote;
    }

    private static void writeAtomically(List<Sales_Approval_Request__c> requests, List<Quote_Configuration__c> quotes) {
        Savepoint savepoint = Database.setSavepoint();
        Boolean previous = SalesQuoteContext.enterServiceWrite();
        try {
            update requests;
            update quotes;
        } catch (DmlException e) {
            Database.rollback(savepoint);
            if (e.getDmlType(0) == StatusCode.INSUFFICIENT_ACCESS_OR_READONLY) {
                throw new SalesLabException(
                    'You do not have edit access to this quote. Approvers need access through the role hierarchy or the Finance sharing rule.'
                );
            }
            throw new SalesLabException(e.getDmlMessage(0));
        } finally {
            SalesQuoteContext.restoreServiceWrite(previous);
        }
    }

    private static SubmissionResult failure(Id quoteId, String message) {
        SubmissionResult result = new SubmissionResult();
        result.quoteId = quoteId;
        result.success = false;
        result.message = message;
        return result;
    }
}
