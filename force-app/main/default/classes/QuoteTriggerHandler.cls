/**
 * Quote__c trigger logic. The trigger file only delegates here.
 *
 * Responsibilities
 *   - normalise and validate new quotes (defaults, account/opportunity consistency, term range)
 *   - protect system-owned fields (totals, approval and ERP state) unless QuoteStateWriter is writing, and
 *     enforce the lifecycle graph (QuoteConstants.ALLOWED_TRANSITIONS)
 *   - lock commercial inputs once a quote leaves Draft/Rejected
 *   - re-price when a pricing input changes
 */
public with sharing class QuoteTriggerHandler {
    private static final Integer DEFAULT_TERM_MONTHS = 12;
    private static final Integer MAX_TERM_MONTHS = QuoteCalculationService.MAX_TERM_MONTHS;
    private static final Integer DEFAULT_VALIDITY_DAYS = 30;

    public static void run() {
        handle(Trigger.operationType, Trigger.new, (Map<Id, Quote__c>) Trigger.oldMap);
    }

    public static void handle(System.TriggerOperation operation, List<Quote__c> newRecords, Map<Id, Quote__c> oldMap) {
        switch on operation {
            when BEFORE_INSERT {
                beforeInsert(newRecords);
            }
            when BEFORE_UPDATE {
                beforeUpdate(newRecords, oldMap);
            }
            when AFTER_UPDATE {
                afterUpdate(newRecords, oldMap);
            }
            when else {
                // Other operations are not subscribed in QuoteTrigger.
            }
        }
    }

    // ------------------------------------------------------------------ before insert

    private static void beforeInsert(List<Quote__c> quotes) {
        Map<Id, Opportunity> opportunities = loadOpportunities(quotes);
        for (Quote__c quote : quotes) {
            // Quotes always start life as an unsubmitted draft with zeroed, system-owned amounts.
            quote.Status__c = QuoteConstants.STATUS_DRAFT;
            quote.Approval_Status__c = QuoteConstants.APPROVAL_NOT_SUBMITTED;
            quote.ERP_Sync_Status__c = QuoteConstants.ERP_NOT_REQUIRED;
            quote.Current_Approval_Level__c = 0;
            quote.Required_Approval_Level__c = 0;
            quote.List_Amount__c = 0;
            quote.Net_Amount__c = 0;
            quote.Total_Discount_Amount__c = 0;
            quote.Blended_Discount_Pct__c = 0;
            quote.Max_Line_Discount_Pct__c = 0;
            quote.ERP_Order_Id__c = null;
            quote.ERP_Sync_Attempts__c = 0;
            quote.ERP_Sync_Generation__c = 0;
            quote.ERP_Next_Attempt_At__c = null;
            quote.ERP_Last_Error__c = null;
            quote.ERP_Last_Sync__c = null;

            if (quote.Term_Months__c == null) {
                quote.Term_Months__c = DEFAULT_TERM_MONTHS;
            }
            if (quote.Valid_Until__c == null) {
                quote.Valid_Until__c = Date.today().addDays(DEFAULT_VALIDITY_DAYS);
            }
            validateTerm(quote);

            Opportunity opportunity = opportunities.get(quote.Opportunity__c);
            if (quote.Account__c == null && opportunity != null) {
                quote.Account__c = opportunity.AccountId;
            }
            if (quote.Account__c == null) {
                quote.Account__c.addError('An account is required.');
            } else if (opportunity != null && opportunity.AccountId != quote.Account__c) {
                quote.Opportunity__c.addError('The opportunity belongs to a different account.');
            }
        }
    }

    // ------------------------------------------------------------------ before update

    private static void beforeUpdate(List<Quote__c> quotes, Map<Id, Quote__c> oldMap) {
        Boolean canOverrideLock = FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION);
        for (Quote__c quote : quotes) {
            Quote__c previous = oldMap.get(quote.Id);
            validateTerm(quote);
            validateTransition(quote, previous);
            if (QuoteTriggerContext.isServiceUpdate) {
                continue;
            }
            rejectChangesToSystemFields(quote, previous);
            if (
                !QuoteConstants.EDITABLE_STATUSES.contains(previous.Status__c) &&
                !canOverrideLock &&
                commercialInputChanged(quote, previous)
            ) {
                quote.addError(
                    'Account, price book, opportunity and term cannot be changed while the quote is ' +
                        previous.Status__c +
                        '.'
                );
            }
        }
    }

    private static void validateTransition(Quote__c quote, Quote__c previous) {
        if (quote.Status__c == previous.Status__c) {
            return;
        }
        Map<String, Set<String>> allowed = QuoteTriggerContext.isServiceUpdate
            ? QuoteConstants.ALLOWED_TRANSITIONS
            : QuoteConstants.USER_TRANSITIONS;
        Set<String> targets = allowed.get(previous.Status__c);
        if (targets == null || !targets.contains(quote.Status__c)) {
            quote.Status__c.addError(
                'A quote cannot move from ' + previous.Status__c + ' to ' + quote.Status__c + ' this way.'
            );
        }
    }

    private static void rejectChangesToSystemFields(Quote__c quote, Quote__c previous) {
        if (
            quote.Approval_Status__c != previous.Approval_Status__c ||
            quote.Required_Approval_Level__c != previous.Required_Approval_Level__c ||
            quote.Current_Approval_Level__c != previous.Current_Approval_Level__c ||
            quote.List_Amount__c != previous.List_Amount__c ||
            quote.Net_Amount__c != previous.Net_Amount__c ||
            quote.Total_Discount_Amount__c != previous.Total_Discount_Amount__c ||
            quote.Blended_Discount_Pct__c != previous.Blended_Discount_Pct__c ||
            quote.Max_Line_Discount_Pct__c != previous.Max_Line_Discount_Pct__c
        ) {
            quote.addError('Approval and pricing fields are maintained by the system and cannot be edited.');
        }
        // ERP bookkeeping is owned by ERPIntegrationService; a forged order id or status would hide a failed sync.
        if (
            quote.ERP_Sync_Status__c != previous.ERP_Sync_Status__c ||
            quote.ERP_Order_Id__c != previous.ERP_Order_Id__c ||
            quote.ERP_Sync_Attempts__c != previous.ERP_Sync_Attempts__c ||
            quote.ERP_Next_Attempt_At__c != previous.ERP_Next_Attempt_At__c ||
            quote.ERP_Last_Sync__c != previous.ERP_Last_Sync__c ||
            quote.ERP_Last_Error__c != previous.ERP_Last_Error__c ||
            quote.ERP_Sync_Generation__c != previous.ERP_Sync_Generation__c
        ) {
            quote.addError('ERP synchronisation fields are maintained by the integration and cannot be edited.');
        }
    }

    private static Boolean commercialInputChanged(Quote__c quote, Quote__c previous) {
        return quote.Account__c != previous.Account__c ||
            quote.Pricebook__c != previous.Pricebook__c ||
            quote.Opportunity__c != previous.Opportunity__c ||
            quote.Term_Months__c != previous.Term_Months__c;
    }

    private static void validateTerm(Quote__c quote) {
        if (quote.Term_Months__c == null || quote.Term_Months__c < 1 || quote.Term_Months__c > MAX_TERM_MONTHS) {
            quote.Term_Months__c.addError('Term must be between 1 and ' + MAX_TERM_MONTHS + ' months.');
        }
    }

    // ------------------------------------------------------------------ after update

    private static void afterUpdate(List<Quote__c> quotes, Map<Id, Quote__c> oldMap) {
        if (QuoteTriggerContext.isRepricing) {
            return;
        }
        Set<Id> toReprice = new Set<Id>();
        for (Quote__c quote : quotes) {
            Quote__c previous = oldMap.get(quote.Id);
            Boolean pricingInputChanged =
                quote.Pricebook__c != previous.Pricebook__c ||
                quote.Term_Months__c != previous.Term_Months__c ||
                quote.Account__c != previous.Account__c;
            if (pricingInputChanged && QuoteConstants.EDITABLE_STATUSES.contains(quote.Status__c)) {
                toReprice.add(quote.Id);
            }
        }
        if (!toReprice.isEmpty()) {
            try {
                QuoteCalculationService.reprice(toReprice);
            } catch (QuoteFlowException e) {
                for (Quote__c quote : quotes) {
                    if (toReprice.contains(quote.Id)) {
                        quote.addError(e.getMessage());
                    }
                }
            }
        }
    }

    private static Map<Id, Opportunity> loadOpportunities(List<Quote__c> quotes) {
        Set<Id> opportunityIds = new Set<Id>();
        for (Quote__c quote : quotes) {
            if (quote.Opportunity__c != null) {
                opportunityIds.add(quote.Opportunity__c);
            }
        }
        return new Map<Id, Opportunity>(QuoteSelector.opportunitiesById(opportunityIds));
    }
}
