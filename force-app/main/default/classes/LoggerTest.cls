@IsTest
private class LoggerTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
    }

    @IsTest
    static void error_isPersistedToApplicationLogWithItsReference() {
        Test.startTest();
        String reference = Logger.error(
            'LoggerTest',
            'Something broke',
            new DmlException('boom'),
            UserInfo.getUserId()
        );
        Test.stopTest(); // delivers the platform event to LogEventTrigger

        Application_Log__c log = [
            SELECT Level__c, Source__c, Message__c, Reference__c, Related_Record_Id__c, User_Id__c, Stack_Trace__c
            FROM Application_Log__c
        ];
        Assert.areEqual(reference, log.Reference__c);
        Assert.areEqual('ERROR', log.Level__c);
        Assert.areEqual('LoggerTest', log.Source__c);
        Assert.isTrue(log.Message__c.contains('System.DmlException: boom'), log.Message__c);
        Assert.areEqual(String.valueOf(UserInfo.getUserId()), log.Related_Record_Id__c);
        Assert.areEqual(String.valueOf(UserInfo.getUserId()), log.User_Id__c);
    }

    @IsTest
    static void log_survivesRollbackOfTheBusinessTransaction() {
        Test.startTest();
        Savepoint savepoint = Database.setSavepoint();
        insert new Account(Name = 'Rolled back');
        Logger.warn('LoggerTest', 'Logged before the rollback', null);
        Database.rollback(savepoint);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Rolled back']);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Application_Log__c WHERE Level__c = 'WARN'],
            'Publish Immediately keeps the log'
        );
    }

    @IsTest
    static void errorReadOnly_publishesNothing() {
        Test.startTest();
        String reference = Logger.errorReadOnly('LoggerTest', 'In a cacheable read', new NullPointerException());
        Test.stopTest();

        Assert.isNotNull(reference);
        Assert.areEqual(0, Logger.PUBLISHED.size());
        Assert.areEqual(0, [SELECT COUNT() FROM Application_Log__c]);
    }

    @IsTest
    static void longMessages_areTruncatedNotRejected() {
        String huge = 'x'.repeat(Logger.MAX_TEXT + 500);

        Test.startTest();
        Logger.error('LoggerTest', huge);
        Test.stopTest();

        Assert.areEqual(Logger.MAX_TEXT, [SELECT Message__c FROM Application_Log__c].Message__c.length());
    }
}
