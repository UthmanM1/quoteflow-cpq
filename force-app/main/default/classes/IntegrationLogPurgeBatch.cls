/**
 * Retention job for Integration_Log__c and Application_Log__c. Payload columns are large, so unbounded growth is
 * a storage problem long before it is a query problem. Retention comes from ERP_Integration_Setting__mdt.
 *
 * Runs in user mode: schedule it as an administrator holding QF_Administrator_PSG (View All + Modify All on both
 * log objects). The integration user deliberately has no delete rights. Purging Integration_Log__c chains a
 * second run for Application_Log__c.
 *
 *     System.schedule('QuoteFlow Log Purge', '0 0 2 * * ?', new IntegrationLogPurgeBatch());
 */
public with sharing class IntegrationLogPurgeBatch implements Database.Batchable<SObject>, Schedulable {
    private static final Integer DEFAULT_RETENTION_DAYS = 90;
    @TestVisible
    private static final List<String> PURGE_ORDER = new List<String>{ 'Integration_Log__c', 'Application_Log__c' };

    private final String objectApiName;

    public IntegrationLogPurgeBatch() {
        this(PURGE_ORDER[0]);
    }

    public IntegrationLogPurgeBatch(String objectApiName) {
        if (!PURGE_ORDER.contains(objectApiName)) {
            throw new IllegalArgumentException('Unsupported log object: ' + objectApiName);
        }
        this.objectApiName = objectApiName;
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime cutoff = Datetime.now().addDays(-retentionDays());
        // Object name comes from the allow-list above, never from input, and the cutoff is a bind variable.
        return Database.getQueryLocatorWithBinds(
            'SELECT Id FROM ' + objectApiName + ' WHERE CreatedDate < :cutoff',
            new Map<String, Object>{ 'cutoff' => cutoff },
            AccessLevel.USER_MODE
        );
    }

    public void execute(Database.BatchableContext context, List<SObject> scope) {
        List<Database.DeleteResult> results = Database.delete(scope, false, AccessLevel.USER_MODE);
        Integer failures = 0;
        String firstError;
        for (Database.DeleteResult result : results) {
            if (!result.isSuccess()) {
                failures++;
                firstError = firstError == null ? result.getErrors()[0].getMessage() : firstError;
            }
        }
        if (failures > 0) {
            Logger.warn(
                'IntegrationLogPurgeBatch',
                failures + ' ' + objectApiName + ' row(s) not purged: ' + firstError,
                null
            );
        }
    }

    public void finish(Database.BatchableContext context) {
        Integer next = PURGE_ORDER.indexOf(objectApiName) + 1;
        // Tests may start only one batch per test method, so the chained run is exercised by its own test.
        if (next < PURGE_ORDER.size() && !Test.isRunningTest()) {
            Database.executeBatch(new IntegrationLogPurgeBatch(PURGE_ORDER[next]), 2000);
        }
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(new IntegrationLogPurgeBatch(), 2000);
    }

    @TestVisible
    private static Integer retentionDays() {
        ERP_Integration_Setting__mdt setting = ERP_Integration_Setting__mdt.getInstance('Default');
        return setting == null ||
            setting.Log_Retention_Days__c == null
            ? DEFAULT_RETENTION_DAYS
            : Integer.valueOf(setting.Log_Retention_Days__c);
    }
}
