/**
 * Sales_Approval_Request__c rows are an audit trail. They are created and decided only by SalesQuoteApprovalService,
 * which raises SalesQuoteContext.isServiceWrite; any other insert, edit or delete (UI, API, Data Loader) is refused.
 */
public with sharing class SalesApprovalRequestTriggerHandler {
    public static void run() {
        handle(Trigger.operationType, Trigger.isDelete ? Trigger.old : Trigger.new);
    }

    public static void handle(System.TriggerOperation operation, List<Sales_Approval_Request__c> records) {
        if (SalesQuoteContext.isServiceWrite) {
            return;
        }
        if (
            operation == System.TriggerOperation.BEFORE_INSERT ||
            operation == System.TriggerOperation.BEFORE_UPDATE ||
            operation == System.TriggerOperation.BEFORE_DELETE
        ) {
            for (Sales_Approval_Request__c request : records) {
                request.addError(
                    'Approval requests are managed by the approval process and cannot be changed directly.'
                );
            }
        }
    }
}
