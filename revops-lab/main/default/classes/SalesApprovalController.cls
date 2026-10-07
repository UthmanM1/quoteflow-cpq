/**
 * Server side of the salesApprovalPanel LWC. The can* flags are display hints computed with the same rules the
 * services enforce; the services remain the control.
 */
public with sharing class SalesApprovalController {
    public class HistoryItem {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Integer tier;
        @AuraEnabled
        public String approverName;
        @AuraEnabled
        public String requestedByName;
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
        public String quoteName;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public String opportunityName;
        @AuraEnabled
        public String ownerName;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Decimal listAmount;
        @AuraEnabled
        public Decimal netAmount;
        @AuraEnabled
        public Decimal discountAmount;
        @AuraEnabled
        public Decimal requestedDiscountPercent;
        @AuraEnabled
        public Decimal thresholdPercent;
        @AuraEnabled
        public Integer tier;
        @AuraEnabled
        public Boolean approvalRequired = false;
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public String approverName;
        @AuraEnabled
        public Id pendingRequestId;
        @AuraEnabled
        public String latestComments;
        @AuraEnabled
        public String customerPoNumber;
        @AuraEnabled
        public Id orderId;
        @AuraEnabled
        public Boolean canDecide = false;
        @AuraEnabled
        public Boolean canRecall = false;
        @AuraEnabled
        public Boolean canConvert = false;
        @AuraEnabled
        public Integer minCommentLength = SalesLabConstants.MIN_REJECTION_COMMENT_LENGTH;
        @AuraEnabled
        public String currencyIsoCode = UserInfo.getDefaultCurrency();
        @AuraEnabled
        public List<HistoryItem> history = new List<HistoryItem>();
    }

    /** Cached read for @wire; after a mutation the component calls refreshApex or getApprovalSummaryFresh. */
    @AuraEnabled(cacheable=true)
    public static ApprovalSummary getApprovalSummary(Id quoteId) {
        try {
            return build(quoteId);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static ApprovalSummary getApprovalSummaryFresh(Id quoteId) {
        try {
            return build(quoteId);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static void decide(Id requestId, Boolean approve, String comments) {
        try {
            SalesQuoteApprovalService.decide(requestId, approve, comments);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static void recallQuote(Id quoteId) {
        try {
            SalesQuoteApprovalService.recall(quoteId);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static Id convertToOrder(Id quoteId, String customerPoNumber) {
        try {
            return OrderConversionService.convert(quoteId, customerPoNumber).orderId;
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    private static ApprovalSummary build(Id quoteId) {
        Quote_Configuration__c quote = SalesQuoteSelector.quotesById(new Set<Id>{ quoteId }).get(quoteId);
        if (quote == null) {
            throw new SalesLabException('Quote not found or you do not have access to it.');
        }
        Id currentUser = UserInfo.getUserId();
        ApprovalSummary summary = new ApprovalSummary();
        summary.quoteId = quote.Id;
        summary.quoteName = quote.Name;
        summary.accountName = quote.Account__r?.Name;
        summary.opportunityName = quote.Opportunity__r?.Name;
        summary.ownerName = quote.Owner?.Name;
        summary.status = quote.Status__c;
        summary.listAmount = quote.Total_List_Amount__c;
        summary.netAmount = quote.Total_Net_Amount__c;
        summary.discountAmount = quote.Total_Discount_Amount__c;
        summary.requestedDiscountPercent = quote.Max_Discount_Percent__c;
        summary.thresholdPercent = quote.Approval_Threshold_Percent__c;
        summary.tier = quote.Required_Approval_Tier__c == null ? 0 : Integer.valueOf(quote.Required_Approval_Tier__c);
        summary.approvalRequired = quote.Approval_Required__c == true;
        summary.customerPoNumber = quote.Customer_PO_Number__c;
        summary.orderId = quote.Order__c;

        List<Sales_Approval_Request__c> requests = SalesQuoteSelector.approvalRequestsForQuotes(new Set<Id>{ quoteId });
        for (Sales_Approval_Request__c request : requests) {
            HistoryItem item = new HistoryItem();
            item.id = request.Id;
            item.status = request.Status__c;
            item.tier = request.Approval_Tier__c == null ? null : Integer.valueOf(request.Approval_Tier__c);
            item.approverName = request.Approver__r?.Name;
            item.requestedByName = request.Requested_By__r?.Name;
            item.comments = request.Comments__c;
            item.submittedDate = request.Submitted_Date__c;
            item.decisionDate = request.Decision_Date__c;
            summary.history.add(item);
            if (request.Status__c == SalesLabConstants.REQUEST_PENDING) {
                summary.pendingRequestId = request.Id;
                summary.canDecide = request.Approver__c == currentUser;
            }
        }
        // Requests are ordered newest first, so the first one describes the current approval.
        if (!requests.isEmpty()) {
            summary.approvalStatus = requests[0].Status__c;
            summary.approverName = requests[0].Approver__r?.Name;
            summary.latestComments = requests[0].Comments__c;
        } else {
            summary.approvalStatus = quote.Submitted_Date__c == null &&
                quote.Status__c == SalesLabConstants.QUOTE_DRAFT
                ? 'Not Submitted'
                : 'Not Required';
        }
        Boolean actsAsOwner =
            quote.OwnerId == currentUser ||
            FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_OVERRIDE_LOCK);
        summary.canRecall = actsAsOwner && quote.Status__c == SalesLabConstants.QUOTE_PENDING;
        summary.canConvert = actsAsOwner && quote.Status__c == SalesLabConstants.QUOTE_APPROVED;
        return summary;
    }
}
