/**
 * The single elevated write path in QuoteFlow.
 *
 * Why it exists
 *   Totals, approval state and ERP bookkeeping are system-owned: no persona has edit FLS on them, and several
 *   personas that legitimately change them (an approver who only has Read through Apex sharing, the integration
 *   user who has View All but owns nothing) have no record-level edit access either. Plain DML inside a
 *   `with sharing` class skips CRUD/FLS but still enforces record sharing, so those writes must run without sharing.
 *
 * Rules (enforced here, reviewed in every PR)
 *   1. Callers authorise first. This class performs no business checks; it only writes.
 *   2. Only allow-listed system fields can be written on Quote__c; anything else throws before DML.
 *   3. Service mode (QuoteTriggerContext.isServiceUpdate) is raised here and nowhere else, and always restored.
 *   4. Reads stay in user mode in QuoteSelector. The only system-mode read is approver share rows below.
 */
public without sharing class QuoteStateWriter {
    @TestVisible
    private static final Set<String> QUOTE_SYSTEM_FIELDS = new Set<String>{
        'id',
        'status__c',
        'approval_status__c',
        'current_approval_level__c',
        'required_approval_level__c',
        'list_amount__c',
        'net_amount__c',
        'total_discount_amount__c',
        'blended_discount_pct__c',
        'max_line_discount_pct__c',
        'erp_sync_status__c',
        'erp_sync_attempts__c',
        'erp_next_attempt_at__c',
        'erp_last_error__c',
        'erp_last_sync__c',
        'erp_order_id__c',
        'erp_sync_generation__c'
    };

    // ------------------------------------------------------------------ Quote__c

    /** All-or-none update of system-owned quote fields. */
    public static void updateQuotes(List<Quote__c> quotes) {
        if (quotes == null || quotes.isEmpty()) {
            return;
        }
        assertSystemFieldsOnly(quotes);
        Boolean previous = QuoteTriggerContext.enterServiceMode();
        try {
            update quotes;
        } finally {
            QuoteTriggerContext.restoreServiceMode(previous);
        }
    }

    /** Partial-success update; results are index-aligned with the input so callers can report per record. */
    public static List<Database.SaveResult> updateQuotesPartial(List<Quote__c> quotes) {
        if (quotes == null || quotes.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        assertSystemFieldsOnly(quotes);
        Boolean previous = QuoteTriggerContext.enterServiceMode();
        try {
            return Database.update(quotes, false);
        } finally {
            QuoteTriggerContext.restoreServiceMode(previous);
        }
    }

    // ------------------------------------------------------------------ Approval_Request__c (written only by the approval service)

    public static void insertApprovalRequests(List<Approval_Request__c> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        Boolean previous = QuoteTriggerContext.enterServiceMode();
        try {
            insert requests;
        } finally {
            QuoteTriggerContext.restoreServiceMode(previous);
        }
    }

    public static List<Database.SaveResult> insertApprovalRequestsPartial(List<Approval_Request__c> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        Boolean previous = QuoteTriggerContext.enterServiceMode();
        try {
            return Database.insert(requests, false);
        } finally {
            QuoteTriggerContext.restoreServiceMode(previous);
        }
    }

    public static void updateApprovalRequests(List<Approval_Request__c> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        Boolean previous = QuoteTriggerContext.enterServiceMode();
        try {
            update requests;
        } finally {
            QuoteTriggerContext.restoreServiceMode(previous);
        }
    }

    // ------------------------------------------------------------------ Apex managed sharing (Approver_Access only)

    public static List<Database.SaveResult> insertApproverShares(List<Quote__Share> shares) {
        if (shares == null || shares.isEmpty()) {
            return new List<Database.SaveResult>();
        }
        for (Quote__Share share : shares) {
            if (share.RowCause != Schema.Quote__Share.RowCause.Approver_Access__c) {
                throw new IllegalArgumentException('QuoteStateWriter only manages Approver_Access shares.');
            }
        }
        return Database.insert(shares, false);
    }

    /** System-mode read: the caller (e.g. a rep recalling a quote) may not be able to see other users' share rows. */
    public static List<Quote__Share> approverShares(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote__Share>();
        }
        return [
            SELECT Id, ParentId, UserOrGroupId
            FROM Quote__Share
            WHERE ParentId IN :quoteIds AND RowCause = :Schema.Quote__Share.RowCause.Approver_Access__c
        ];
    }

    public static List<Database.DeleteResult> deleteApproverShares(List<Quote__Share> shares) {
        if (shares == null || shares.isEmpty()) {
            return new List<Database.DeleteResult>();
        }
        return Database.delete(shares, false);
    }

    // ------------------------------------------------------------------ guard rail

    @TestVisible
    private static void assertSystemFieldsOnly(List<Quote__c> quotes) {
        for (Quote__c quote : quotes) {
            if (quote.Id == null) {
                throw new IllegalArgumentException('QuoteStateWriter updates existing quotes only.');
            }
            for (String field : quote.getPopulatedFieldsAsMap().keySet()) {
                if (!QUOTE_SYSTEM_FIELDS.contains(field.toLowerCase())) {
                    throw new IllegalArgumentException(
                        'QuoteStateWriter cannot write ' +
                            field +
                            '; it is a user-owned field. Use user-mode DML instead.'
                    );
                }
            }
        }
    }
}
