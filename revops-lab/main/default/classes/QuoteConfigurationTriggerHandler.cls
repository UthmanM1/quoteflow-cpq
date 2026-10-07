/**
 * Quote_Configuration__c trigger logic (the trigger only delegates here).
 *
 *   before insert   every quote starts as a Draft with empty system-owned fields, whatever the caller sent
 *   before update   status and approval/order fields change only through the lab services
 *                   (SalesQuoteContext.isServiceWrite); a user may only cancel a Draft or Rejected quote
 *
 * Commercial-term locking after submission is declarative (validation rule Commercial_Terms_Locked_After_Submit),
 * so administrators can read and adjust it without a deployment of code.
 */
public with sharing class QuoteConfigurationTriggerHandler {
    public static void run() {
        handle(Trigger.operationType, Trigger.new, (Map<Id, Quote_Configuration__c>) Trigger.oldMap);
    }

    public static void handle(
        System.TriggerOperation operation,
        List<Quote_Configuration__c> records,
        Map<Id, Quote_Configuration__c> oldMap
    ) {
        switch on operation {
            when BEFORE_INSERT {
                beforeInsert(records);
            }
            when BEFORE_UPDATE {
                beforeUpdate(records, oldMap);
            }
            when else {
                // Not subscribed.
            }
        }
    }

    private static void beforeInsert(List<Quote_Configuration__c> quotes) {
        for (Quote_Configuration__c quote : quotes) {
            quote.Status__c = SalesLabConstants.QUOTE_DRAFT;
            quote.Approval_Required__c = false;
            quote.Required_Approval_Tier__c = null;
            quote.Approval_Threshold_Percent__c = null;
            quote.Submitted_Date__c = null;
            quote.Approved_Date__c = null;
            quote.Order__c = null;
        }
    }

    private static void beforeUpdate(List<Quote_Configuration__c> quotes, Map<Id, Quote_Configuration__c> oldMap) {
        if (SalesQuoteContext.isServiceWrite) {
            return;
        }
        for (Quote_Configuration__c quote : quotes) {
            Quote_Configuration__c previous = oldMap.get(quote.Id);
            if (quote.Status__c != previous.Status__c && !isUserCancellation(previous.Status__c, quote.Status__c)) {
                quote.Status__c.addError(
                    'Status changes through Submit, Approve, Reject, Recall and Convert, not by editing.'
                );
            }
            if (
                quote.Approval_Required__c != previous.Approval_Required__c ||
                quote.Required_Approval_Tier__c != previous.Required_Approval_Tier__c ||
                quote.Approval_Threshold_Percent__c != previous.Approval_Threshold_Percent__c ||
                quote.Submitted_Date__c != previous.Submitted_Date__c ||
                quote.Approved_Date__c != previous.Approved_Date__c ||
                quote.Order__c != previous.Order__c
            ) {
                quote.addError('Approval and order fields are maintained by the system.');
            }
        }
    }

    private static Boolean isUserCancellation(String fromStatus, String toStatus) {
        return toStatus == SalesLabConstants.QUOTE_CANCELLED &&
            SalesLabConstants.EDITABLE_QUOTE_STATUSES.contains(fromStatus);
    }
}
