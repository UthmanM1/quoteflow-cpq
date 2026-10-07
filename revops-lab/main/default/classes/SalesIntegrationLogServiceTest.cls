@IsTest
private class SalesIntegrationLogServiceTest {
    private static SalesIntegrationLogService.Entry entry(String body) {
        SalesIntegrationLogService.Entry entry = new SalesIntegrationLogService.Entry();
        entry.correlationId = 'corr-1';
        entry.integrationName = 'Sales_ERP';
        entry.httpMethod = 'POST';
        entry.requestBody = body;
        entry.outcome = SalesIntegrationLogService.OUTCOME_SUCCESS;
        return entry;
    }

    @IsTest
    static void sanitise_redactsCredentialLikeProperties() {
        String clean = SalesIntegrationLogService.sanitise(
            '{"access_token":"abc123","apiKey":"k-9","orderNumber":"00000100"}'
        );

        Assert.isFalse(clean.contains('abc123'));
        Assert.isFalse(clean.contains('k-9'));
        Assert.isTrue(clean.contains('"orderNumber":"00000100"'), 'Business data is kept');
    }

    @IsTest
    static void sanitise_truncatesLargePayloads() {
        String huge = '{"data":"' + 'x'.repeat(SalesIntegrationLogService.MAX_BODY_LENGTH + 10) + '"}';

        Assert.areEqual(SalesIntegrationLogService.MAX_BODY_LENGTH, SalesIntegrationLogService.sanitise(huge).length());
    }

    @IsTest
    static void recordAndFlush_writesOneRowPerEntry() {
        SalesIntegrationLogService.record(entry('{}'));
        SalesIntegrationLogService.record(entry('{}'));
        Assert.areEqual(2, SalesIntegrationLogService.bufferedCount());

        Integer saved = SalesIntegrationLogService.flush();

        Assert.areEqual(2, saved);
        Assert.areEqual(0, SalesIntegrationLogService.bufferedCount());
        Assert.areEqual(2, [SELECT COUNT() FROM Sales_Integration_Log__c]);
    }

    @IsTest
    static void flush_neverThrows_whenTheUserCannotCreateLogs() {
        User rep = SalesLabTestFactory.user('rlnolog', null, null, SalesLabTestFactory.REP_SETS);
        SalesIntegrationLogService.record(entry('{}'));

        Integer saved;
        System.runAs(rep) {
            saved = SalesIntegrationLogService.flush();
        }

        Assert.areEqual(0, saved);
        Assert.areEqual(0, [SELECT COUNT() FROM Sales_Integration_Log__c]);
    }
}
