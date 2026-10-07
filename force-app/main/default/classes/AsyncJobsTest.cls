/**
 * Thin async entry points: the scheduler, the queueable failure path and the log retention batch.
 */
@IsTest
private class AsyncJobsTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
    }

    @IsTest
    static void scheduleEveryFiveMinutes_createsTwelveJobs() {
        Test.startTest();
        List<Id> jobIds = ERPSyncScheduler.scheduleEveryFiveMinutes();
        Test.stopTest();

        Assert.areEqual(12, jobIds.size());
        Assert.areEqual(12, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'QuoteFlow ERP Sync%']);
    }

    @IsTest
    static void scheduler_withNothingDue_enqueuesNothing() {
        ERPIntegrationService.configOverride = new ERPIntegrationService.Config();

        Test.startTest();
        new ERPSyncScheduler().execute(null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable']);
    }

    @IsTest
    static void queueable_systemicFailure_isLoggedNotThrown() {
        // A null work list is a programming error inside the worker: it must be logged, never escape the job.
        ERPIntegrationService.configOverride = new ERPIntegrationService.Config();

        Test.startTest();
        new ERPSyncQueueable(null).execute(null);
        Test.stopTest();

        Application_Log__c log = [SELECT Source__c, Level__c FROM Application_Log__c];
        Assert.areEqual('ERPSyncQueueable', log.Source__c);
        Assert.areEqual('ERROR', log.Level__c);
    }

    @IsTest
    static void purgeBatch_deletesOnlyLogsOlderThanRetention() {
        Integration_Log__c oldLog = new Integration_Log__c(Correlation_Id__c = 'old', Status__c = 'Success');
        Integration_Log__c newLog = new Integration_Log__c(Correlation_Id__c = 'new', Status__c = 'Success');
        insert new List<Integration_Log__c>{ oldLog, newLog };
        Test.setCreatedDate(oldLog.Id, Datetime.now().addDays(-(IntegrationLogPurgeBatch.retentionDays() + 1)));

        Test.startTest();
        Database.executeBatch(new IntegrationLogPurgeBatch(), 2000);
        Test.stopTest();

        List<Integration_Log__c> remaining = [SELECT Correlation_Id__c FROM Integration_Log__c];
        Assert.areEqual(1, remaining.size());
        Assert.areEqual('new', remaining[0].Correlation_Id__c);
    }

    @IsTest
    static void purgeBatch_rejectsObjectsOutsideTheAllowList() {
        try {
            new IntegrationLogPurgeBatch('Account');
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('Unsupported'));
        }
    }

    @IsTest
    static void purgeBatch_applicationLogs_areAlsoPurged() {
        Application_Log__c oldLog = new Application_Log__c(
            Level__c = 'ERROR',
            Source__c = 'test',
            Reference__c = 'old'
        );
        insert oldLog;
        Test.setCreatedDate(oldLog.Id, Datetime.now().addDays(-(IntegrationLogPurgeBatch.retentionDays() + 1)));

        Test.startTest();
        Database.executeBatch(new IntegrationLogPurgeBatch('Application_Log__c'), 2000);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Application_Log__c]);
    }
}
