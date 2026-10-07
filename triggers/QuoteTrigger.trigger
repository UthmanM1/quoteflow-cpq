trigger QuoteTrigger on Quote__c(before insert, before update, after update) {
    QuoteTriggerHandler.run();
}
