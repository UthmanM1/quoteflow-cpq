trigger QuoteLineTrigger on Quote_Line__c(
    before insert,
    before update,
    before delete,
    after insert,
    after update,
    after delete,
    after undelete
) {
    QuoteLineTriggerHandler.run();
}
