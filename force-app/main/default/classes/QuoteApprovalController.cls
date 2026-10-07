/**
 * Server side of quoteApprovalPanel (and the approval-status badge in quoteConfigurator).
 * Authorisation lives in QuoteApprovalService and QuoteOrderService; this class only shapes data and translates
 * errors. The can* flags are a display hint computed with the same rule the services enforce.
 */
public with sharing class QuoteApprovalController {
    public class LevelInfo {
        @AuraEnabled
        public Integer level;
        @AuraEnabled
        public Decimal thresholdPct;
        @AuraEnabled
        public String approverType;
        @AuraEnabled
        public String approverRole;
        @AuraEnabled
        public Boolean isRequired;
    }

    public class RequestInfo {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public Integer level;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Id approverId;
        @AuraEnabled
        public String approverName;
        @AuraEnabled
        public String submittedByName;
        @AuraEnabled
        public Decimal thresholdPct;
        @AuraEnabled
        public Decimal requestedDiscountPct;
        @AuraEnabled
        public String comments;
        @AuraEnabled
        public Datetime submittedDate;
        @AuraEnabled
        public Datetime decisionDate;
    }

    public class ApprovalSummary {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteNumber;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public Decimal listAmount;
        @AuraEnabled
        public Decimal netAmount;
        @AuraEnabled
        public Decimal totalDiscountAmount;
        @AuraEnabled
        public Decimal blendedDiscountPct;
        @AuraEnabled
        public Decimal maxLineDiscountPct;
        @AuraEnabled
        public Integer requiredLevel;
        @AuraEnabled
        public Integer currentLevel;
        @AuraEnabled
        public String erpSyncStatus;
        @AuraEnabled
        public String erpOrderId;
        @AuraEnabled
        public String erpLastError;
        @AuraEnabled
        public Id pendingRequestId;
        @AuraEnabled
        public Boolean canDecide = false;
        @AuraEnabled
        public Boolean canSubmit = false;
        @AuraEnabled
        public Boolean canRecall = false;
        @AuraEnabled
        public Boolean canConvert = false;
        @AuraEnabled
        public Integer minRejectionCommentLength = QuoteApprovalService.MIN_REJECTION_COMMENT_LENGTH;
        @AuraEnabled
        public String currencyIsoCode = UserInfo.getDefaultCurrency();
        @AuraEnabled
        public List<LevelInfo> levels = new List<LevelInfo>();
        @AuraEnabled
        public List<RequestInfo> history = new List<RequestInfo>();
    }

    /** Cached read for @wire. Use getApprovalSummaryFresh after a mutation, or refreshApex on the wire. */
    @AuraEnabled(cacheable=true)
    public static ApprovalSummary getApprovalSummary(Id quoteId) {
        try {
            return buildSummary(quoteId);
        } catch (Exception e) {
            throw AuraErrorFactory.wrapReadOnly(e);
        }
    }

    /**
     * Non-cacheable variant for imperative calls made right after a save or submit. An imperative call to a
     * cacheable method may be answered from the client cache and show the pre-mutation status.
     */
    @AuraEnabled
    public static ApprovalSummary getApprovalSummaryFresh(Id quoteId) {
        try {
            return buildSummary(quoteId);
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }

    private static ApprovalSummary buildSummary(Id quoteId) {
        List<Quote__c> found = QuoteSelector.quotesById(new Set<Id>{ quoteId });
        if (found.isEmpty()) {
            throw new QuoteFlowException('Quote not found or you do not have access to it.');
        }
        Quote__c quote = found[0];
        Id currentUser = UserInfo.getUserId();

        ApprovalSummary summary = new ApprovalSummary();
        summary.quoteId = quote.Id;
        summary.quoteNumber = quote.Name;
        summary.accountName = quote.Account__r.Name;
        summary.status = quote.Status__c;
        summary.approvalStatus = quote.Approval_Status__c;
        summary.listAmount = quote.List_Amount__c;
        summary.netAmount = quote.Net_Amount__c;
        summary.totalDiscountAmount = quote.Total_Discount_Amount__c;
        summary.blendedDiscountPct = quote.Blended_Discount_Pct__c;
        summary.maxLineDiscountPct = quote.Max_Line_Discount_Pct__c;
        summary.requiredLevel = quote.Required_Approval_Level__c == null
            ? 0
            : Integer.valueOf(quote.Required_Approval_Level__c);
        summary.currentLevel = quote.Current_Approval_Level__c == null
            ? 0
            : Integer.valueOf(quote.Current_Approval_Level__c);
        summary.erpSyncStatus = quote.ERP_Sync_Status__c;
        summary.erpOrderId = quote.ERP_Order_Id__c;
        summary.erpLastError = quote.ERP_Last_Error__c;

        for (Approval_Threshold__mdt threshold : DiscountEvaluationService.activeThresholds()) {
            LevelInfo level = new LevelInfo();
            level.level = Integer.valueOf(threshold.Level__c);
            level.thresholdPct = threshold.Min_Discount_Pct__c;
            level.approverType = threshold.Approver_Type__c;
            level.approverRole = threshold.Approver_Role_Developer_Name__c;
            level.isRequired = level.level <= summary.requiredLevel;
            summary.levels.add(level);
        }

        for (Approval_Request__c request : QuoteSelector.requestsForQuotes(new Set<Id>{ quoteId })) {
            RequestInfo info = new RequestInfo();
            info.id = request.Id;
            info.level = Integer.valueOf(request.Approval_Level__c);
            info.status = request.Status__c;
            info.approverId = request.Approver__c;
            info.approverName = request.Approver__r.Name;
            info.submittedByName = request.Submitted_By__r.Name;
            info.thresholdPct = request.Threshold_Pct__c;
            info.requestedDiscountPct = request.Requested_Discount_Pct__c;
            info.comments = request.Decision_Comments__c;
            info.submittedDate = request.Submitted_Date__c;
            info.decisionDate = request.Decision_Date__c;
            summary.history.add(info);
            if (request.Status__c == QuoteConstants.REQUEST_PENDING) {
                summary.pendingRequestId = request.Id;
                summary.canDecide = request.Approver__c == currentUser;
            }
        }

        // Mirrors the authorisation enforced in QuoteApprovalService / QuoteOrderService; display only.
        Boolean canActAsOwner =
            quote.OwnerId == currentUser || FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION);
        summary.canSubmit = canActAsOwner && QuoteConstants.EDITABLE_STATUSES.contains(quote.Status__c);
        summary.canRecall = canActAsOwner && quote.Status__c == QuoteConstants.STATUS_PENDING_APPROVAL;
        summary.canConvert = canActAsOwner && quote.Status__c == QuoteConstants.STATUS_APPROVED;
        return summary;
    }

    @AuraEnabled
    public static void decide(Id approvalRequestId, Boolean approve, String comments) {
        try {
            QuoteApprovalService.decide(approvalRequestId, approve, comments);
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }

    @AuraEnabled
    public static QuoteApprovalService.SubmissionResult submitForApproval(Id quoteId) {
        try {
            List<QuoteApprovalService.SubmissionResult> results = QuoteApprovalService.submit(new Set<Id>{ quoteId });
            QuoteApprovalService.SubmissionResult result = results.isEmpty() ? null : results[0];
            if (result == null || !result.success) {
                throw new QuoteFlowException(result == null ? 'Submission failed.' : result.message);
            }
            return result;
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }

    @AuraEnabled
    public static void recallQuote(Id quoteId) {
        try {
            QuoteApprovalService.recall(quoteId);
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }

    @AuraEnabled
    public static Id convertToOrder(Id quoteId) {
        try {
            return QuoteOrderService.convert(quoteId).orderId;
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }
}
