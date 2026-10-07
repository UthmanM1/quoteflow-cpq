trigger SalesApprovalRequestTrigger on Sales_Approval_Request__c(before insert, before update, before delete) {
    SalesApprovalRequestTriggerHandler.run();
}
