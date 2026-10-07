@IsTest
private class IntegrationLogServiceTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
    }

    private static IntegrationLogService.Entry entry(String request) {
        IntegrationLogService.Entry e = new IntegrationLogService.Entry();
        e.integrationName = 'ERP_Gateway';
        e.status = IntegrationLogService.STATUS_SUCCESS;
        e.httpMethod = 'POST';
        e.endpoint = 'callout:ERP_Gateway/v1/sales-orders';
        e.requestBody = request;
        return e;
    }

    @IsTest
    static void flush_persistsBufferedEntriesAndEmptiesBuffer() {
        IntegrationLogService.record(entry('{"a":1}'));
        IntegrationLogService.record(entry('{"a":2}'));
        Assert.areEqual(2, IntegrationLogService.bufferedCount());

        Test.startTest();
        Integer saved = IntegrationLogService.flush();
        Test.stopTest();

        Assert.areEqual(2, saved);
        Assert.areEqual(0, IntegrationLogService.bufferedCount());
        Assert.areEqual(2, [SELECT COUNT() FROM Integration_Log__c]);
        Assert.areEqual(0, IntegrationLogService.flush(), 'Second flush is a no-op');
    }

    @IsTest
    static void record_generatesCorrelationIdWhenMissing() {
        IntegrationLogService.record(entry('{}'));
        IntegrationLogService.flush();

        Assert.areNotEqual(null, [SELECT Correlation_Id__c FROM Integration_Log__c].Correlation_Id__c);
    }

    @IsTest
    static void sanitise_redactsCredentialLookingValues() {
        String raw = '{"orderId":"1","Authorization":"Bearer abc.def","client_secret" : "s3cr3t","nested":{"apiKey":"k-123","password":"p"}}';

        String clean = IntegrationLogService.sanitise(raw);

        Assert.isTrue(!clean.contains('abc.def'));
        Assert.isTrue(!clean.contains('s3cr3t'));
        Assert.isTrue(!clean.contains('k-123'));
        Assert.isTrue(clean.contains('"orderId":"1"'), 'Business data is preserved');
    }

    @IsTest
    static void sanitise_truncatesOversizedPayloads() {
        String huge = '{"data":"' + 'x'.repeat(IntegrationLogService.MAX_BODY_LENGTH + 500) + '"}';

        String clean = IntegrationLogService.sanitise(huge);

        Assert.areEqual(IntegrationLogService.MAX_BODY_LENGTH, clean.length());
        Assert.isTrue(clean.endsWith('...[truncated]'));
    }

    @IsTest
    static void flush_neverThrowsWhenInsertIsNotPossible() {
        // A user without access to the log object: the logger must swallow the failure, not break the caller.
        User noAccess = TestDataFactory.user('qflognop', null, null, new List<String>());
        IntegrationLogService.record(entry('{}'));

        Integer saved;
        System.runAs(noAccess) {
            saved = IntegrationLogService.flush();
        }

        Assert.areEqual(0, saved);
        Assert.areEqual(0, [SELECT COUNT() FROM Integration_Log__c]);
        Assert.areEqual(
            1,
            Logger.PUBLISHED.size(),
            'The failure is reported through the application log, not just debug'
        );
    }
}
