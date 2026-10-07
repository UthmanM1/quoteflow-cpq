trigger QuoteConfigurationTrigger on Quote_Configuration__c(before insert, before update) {
    QuoteConfigurationTriggerHandler.run();
}
