trigger ApprovalRequestTrigger on Approval_Request__c(before update) {
    ApprovalRequestTriggerHandler.run();
}
