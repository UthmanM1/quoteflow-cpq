/**
 * Persists Log_Event__e to Application_Log__c. Platform event triggers run as the Automated Process user,
 * after the publishing transaction, so a rolled-back business transaction still leaves its log rows.
 */
public with sharing class LogEventTriggerHandler {
    public static void handle(List<Log_Event__e> events) {
        List<Application_Log__c> logs = new List<Application_Log__c>();
        for (Log_Event__e event : events) {
            logs.add(
                new Application_Log__c(
                    Level__c = event.Level__c,
                    Source__c = event.Source__c,
                    Message__c = event.Message__c,
                    Stack_Trace__c = event.Stack_Trace__c,
                    Reference__c = event.Reference__c,
                    Related_Record_Id__c = event.Related_Record_Id__c,
                    User_Id__c = event.User_Id__c
                )
            );
        }
        // Partial success: one malformed event must not drop the rest of the batch.
        List<Database.SaveResult> results = Database.insert(logs, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(
                    LoggingLevel.ERROR,
                    'Application log not saved: ' + results[i].getErrors()[0].getMessage()
                );
            }
        }
    }
}
