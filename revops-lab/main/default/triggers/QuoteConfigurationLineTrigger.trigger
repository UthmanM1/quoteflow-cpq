trigger QuoteConfigurationLineTrigger on Quote_Configuration_Line__c(before insert, before update, before delete) {
    QuoteConfigurationLineTriggerHandler.run();
}
