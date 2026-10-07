/**
 * Approval requests are an audit record. They are created and decided only by QuoteApprovalService,
 * which raises QuoteTriggerContext.isServiceUpdate; any other update (UI, API, Data Loader) is refused.
 */
public with sharing class ApprovalRequestTriggerHandler {
    public static void run() {
        handle(Trigger.operationType, Trigger.new);
    }

    public static void handle(System.TriggerOperation operation, List<Approval_Request__c> newRecords) {
        if (operation != System.TriggerOperation.BEFORE_UPDATE || QuoteTriggerContext.isServiceUpdate) {
            return;
        }
        for (Approval_Request__c request : newRecords) {
            request.addError('Approval requests are managed by the approval process and cannot be edited directly.');
        }
    }
}
