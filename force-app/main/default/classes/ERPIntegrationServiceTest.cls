@IsTest
private class ERPIntegrationServiceTest {
    /** Scriptable ERP double. Records every request so tests can assert on what was sent. */
    private class ERPMock implements HttpCalloutMock {
        Integer status;
        String body;
        Map<String, String> headers = new Map<String, String>();
        Boolean throwCalloutException = false;
        List<HttpRequest> requests = new List<HttpRequest>();

        ERPMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            requests.add(request);
            if (throwCalloutException) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            for (String name : headers.keySet()) {
                response.setHeader(name, headers.get(name));
            }
            return response;
        }
    }

    private static final String CREATED = '{"orderId":"SO-90001","status":"CREATED"}';

    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        TestDataFactory.account('Contoso Ltd', 'ERP-C-77');
        TestDataFactory.account('No ERP Id Ltd', null);
        TestDataFactory.user('qfint', null, null, TestDataFactory.INTEGRATION_SETS);
        TestDataFactory.user('qferep', null, null, TestDataFactory.REP_SETS);
    }

    private static Quote__c leasedQuote(String accountName, Integer attempts) {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog catalog = new TestDataFactory.Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        catalog.seat = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'];
        Quote__c quote = TestDataFactory.quoteWithSeats(
            catalog,
            [SELECT Id FROM Account WHERE Name = :accountName].Id,
            5,
            null
        );
        TestDataFactory.approve(quote, QuoteConstants.ERP_IN_PROGRESS);
        TestDataFactory.setSystemState(new Quote__c(Id = quote.Id, ERP_Sync_Attempts__c = attempts));
        return TestDataFactory.requery(quote.Id);
    }

    private static ERPIntegrationService.Config config(Integer maxAttempts) {
        ERPIntegrationService.Config cfg = new ERPIntegrationService.Config();
        cfg.maxAttempts = maxAttempts;
        return cfg;
    }

    @IsTest
    static void sync_created_marksQuoteSyncedAndLogsSuccess() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        ERPMock mock = new ERPMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        List<ERPIntegrationService.SyncOutcome> outcomes = ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.isTrue(outcomes[0].success);
        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Synced', after.ERP_Sync_Status__c);
        Assert.areEqual('SO-90001', after.ERP_Order_Id__c);
        Assert.areEqual(null, after.ERP_Last_Error__c);
        Integration_Log__c log = [
            SELECT Status__c, Http_Status_Code__c, Correlation_Id__c, Related_Record_Id__c, Attempt__c, Endpoint__c
            FROM Integration_Log__c
        ];
        Assert.areEqual('Success', log.Status__c);
        Assert.areEqual(201, log.Http_Status_Code__c);
        Assert.areEqual(String.valueOf(quote.Id), log.Related_Record_Id__c);
        Assert.areEqual('callout:ERP_Gateway/v1/sales-orders', log.Endpoint__c);
        Assert.areEqual(outcomes[0].correlationId, log.Correlation_Id__c);
    }

    @IsTest
    static void request_carriesCorrelationIdempotencyAndContractFields() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        ERPMock mock = new ERPMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        HttpRequest sent = mock.requests[0];
        Assert.areEqual('POST', sent.getMethod());
        Assert.areEqual('callout:ERP_Gateway/v1/sales-orders', sent.getEndpoint(), 'Named Credential, never a raw URL');
        Assert.areEqual(
            'qf-quote-' + quote.Id + '-g1',
            sent.getHeader('Idempotency-Key'),
            'Quote id plus sync generation'
        );
        Assert.areNotEqual(null, sent.getHeader('X-Correlation-Id'));
        Assert.areEqual(null, sent.getHeader('Authorization'), 'Auth is injected by the Named Credential, not by Apex');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(sent.getBody());
        Assert.areEqual('ERP-C-77', body.get('customerId'));
        Assert.areEqual(sent.getHeader('X-Correlation-Id'), body.get('correlationId'));
        Assert.areEqual(12, body.get('termMonths'));
        List<Object> lines = (List<Object>) body.get('lines');
        Assert.areEqual(1, lines.size());
        Assert.areEqual('ERP-QF-USER-SEAT', ((Map<String, Object>) lines[0]).get('sku'));
    }

    @IsTest
    static void sync_conflictWithExistingOrderId_isTreatedAsIdempotentSuccess() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 2);
        Test.setMock(HttpCalloutMock.class, new ERPMock(409, '{"orderId":"SO-90001","errorCode":"DUPLICATE"}'));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.areEqual('Synced', TestDataFactory.requery(quote.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void sync_serverError_schedulesBackoffRetry() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 2);
        Test.setMock(HttpCalloutMock.class, new ERPMock(503, '{"errorCode":"UNAVAILABLE","message":"Maintenance"}'));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c, 'Retryable failures go back to the queue');
        Assert.isTrue(after.ERP_Next_Attempt_At__c > Datetime.now().addMinutes(3), 'Attempt 2 waits 2 x 2 = 4 minutes');
        Assert.isTrue(after.ERP_Last_Error__c.contains('503'));
        Assert.areEqual('Retryable Failure', [SELECT Status__c FROM Integration_Log__c].Status__c);
    }

    @IsTest
    static void sync_retryableFailureOnLastAttempt_failsPermanently() {
        ERPIntegrationService.configOverride = config(3);
        Quote__c quote = leasedQuote('Contoso Ltd', 3);
        Test.setMock(HttpCalloutMock.class, new ERPMock(500, '{}'));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Failed', after.ERP_Sync_Status__c);
        Assert.areEqual(null, after.ERP_Next_Attempt_At__c);
    }

    @IsTest
    static void sync_rateLimited_honoursRetryAfterHeader() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        ERPMock mock = new ERPMock(429, '{"errorCode":"RATE_LIMIT"}');
        mock.headers.put('Retry-After', '1200');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Assert.isTrue(
            after.ERP_Next_Attempt_At__c > Datetime.now().addMinutes(19),
            'Retry-After of 20 minutes beats the 2 minute backoff'
        );
    }

    @IsTest
    static void sync_validationRejection_isPermanentAndNotRetried() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        Test.setMock(HttpCalloutMock.class, new ERPMock(422, '{"errorCode":"UNKNOWN_SKU","message":"SKU not found"}'));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Failed', after.ERP_Sync_Status__c);
        Assert.isTrue(after.ERP_Last_Error__c.contains('UNKNOWN_SKU'), after.ERP_Last_Error__c);
        Assert.areEqual('Permanent Failure', [SELECT Status__c FROM Integration_Log__c].Status__c);
    }

    @IsTest
    static void sync_timeout_isRetryable() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        ERPMock mock = new ERPMock(200, '');
        mock.throwCalloutException = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Assert.isTrue(after.ERP_Last_Error__c.contains('timed out'));
    }

    @IsTest
    static void sync_successWithUnusableBody_isRetryableBecauseRequestsAreIdempotent() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        Test.setMock(HttpCalloutMock.class, new ERPMock(200, '<html>gateway</html>'));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.areEqual('Pending', TestDataFactory.requery(quote.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void sync_accountWithoutErpCustomerId_failsWithoutCallingTheErp() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('No ERP Id Ltd', 1);
        ERPMock mock = new ERPMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.areEqual(0, mock.requests.size());
        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Failed', after.ERP_Sync_Status__c);
        Assert.isTrue(after.ERP_Last_Error__c.contains('no ERP customer id'));
    }

    @IsTest
    static void sync_quotesNoLongerLeased_areSkipped() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        TestDataFactory.setSystemState(new Quote__c(Id = quote.Id, ERP_Sync_Status__c = 'Synced'));
        ERPMock mock = new ERPMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.areEqual(0, mock.requests.size(), 'Duplicate dispatch must not produce a second callout');
    }

    @IsTest
    static void sync_batchOfQuotes_makesOneCalloutEachAndFlushesLogsOnce() {
        ERPIntegrationService.configOverride = config(5);
        List<Id> ids = new List<Id>();
        for (Integer i = 0; i < 5; i++) {
            ids.add(leasedQuote('Contoso Ltd', 1).Id);
        }
        ERPMock mock = new ERPMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        ERPIntegrationService.syncQuotes(ids);
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.areEqual(5, mock.requests.size());
        Assert.areEqual(5, [SELECT COUNT() FROM Integration_Log__c WHERE Status__c = 'Success']);
        Assert.areEqual(2, dmlUsed, 'One DML for quote state, one for logs');
    }

    @IsTest
    static void dispatch_leasesDueQuotesAndEnqueuesWorker() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c due = leasedQuote('Contoso Ltd', 0);
        TestDataFactory.setSystemState(
            new Quote__c(
                Id = due.Id,
                ERP_Sync_Status__c = 'Pending',
                ERP_Next_Attempt_At__c = Datetime.now().addMinutes(-1)
            )
        );
        Quote__c notYet = leasedQuote('Contoso Ltd', 0);
        TestDataFactory.setSystemState(
            new Quote__c(
                Id = notYet.Id,
                ERP_Sync_Status__c = 'Pending',
                ERP_Next_Attempt_At__c = Datetime.now().addMinutes(30)
            )
        );
        Test.setMock(HttpCalloutMock.class, new ERPMock(201, CREATED));

        Test.startTest();
        Integer jobs = ERPIntegrationService.dispatchDueQuotes();
        Test.stopTest();

        Assert.areEqual(1, jobs);
        Assert.areEqual('Synced', TestDataFactory.requery(due.Id).ERP_Sync_Status__c, 'Queueable ran at stopTest');
        Assert.areEqual(
            'Pending',
            TestDataFactory.requery(notYet.Id).ERP_Sync_Status__c,
            'Backed-off quotes are left alone'
        );
    }

    @IsTest
    static void claim_abandonedLeaseBeyondMaxAttempts_isFailedNotLoopedForever() {
        ERPIntegrationService.Config cfg = config(3);
        Quote__c stuck = leasedQuote('Contoso Ltd', 3);
        TestDataFactory.setSystemState(
            new Quote__c(Id = stuck.Id, ERP_Next_Attempt_At__c = Datetime.now().addMinutes(-20))
        );

        Test.startTest();
        List<Id> claimed = ERPIntegrationService.claimDueQuotes(cfg);
        Test.stopTest();

        Assert.isTrue(claimed.isEmpty());
        Assert.areEqual('Failed', TestDataFactory.requery(stuck.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void retryDelay_growsExponentiallyAndIsCapped() {
        ERPIntegrationService.Config cfg = config(10);
        Assert.areEqual(2, ERPIntegrationService.retryDelayMinutes(1, cfg, null));
        Assert.areEqual(4, ERPIntegrationService.retryDelayMinutes(2, cfg, null));
        Assert.areEqual(16, ERPIntegrationService.retryDelayMinutes(4, cfg, null));
        Assert.areEqual(60, ERPIntegrationService.retryDelayMinutes(9, cfg, null), 'Capped at one hour');
        Assert.areEqual(10, ERPIntegrationService.retryDelayMinutes(1, cfg, 600));
    }

    @IsTest
    static void requeueFailed_resetsOnlyFailedApprovedQuotes() {
        Quote__c failed = leasedQuote('Contoso Ltd', 5);
        TestDataFactory.setSystemState(new Quote__c(Id = failed.Id, ERP_Sync_Status__c = 'Failed'));
        Quote__c synced = leasedQuote('Contoso Ltd', 1);
        TestDataFactory.setSystemState(new Quote__c(Id = synced.Id, ERP_Sync_Status__c = 'Synced'));

        // The runner holds QF_Admin, which carries QF_Requeue_ERP_Sync.
        Integer count = ERPIntegrationService.requeueFailed(new Set<Id>{ failed.Id, synced.Id });

        Assert.areEqual(1, count);
        Quote__c after = TestDataFactory.requery(failed.Id);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Assert.areEqual(0, after.ERP_Sync_Attempts__c);
        Assert.areEqual(2, after.ERP_Sync_Generation__c, 'A deliberate resend starts a new idempotency generation');
        Assert.areEqual('qf-quote-' + failed.Id + '-g2', ERPIntegrationService.idempotencyKey(after));
    }

    // ------------------------------------------------------------------ added in the principal review

    @IsTest
    static void integrationUserPersona_leasesSyncsAndLogsQuotesItDoesNotOwn() {
        // Regression: View All gives the integration user read but not edit access. With user-mode writes every lease
        // failed silently and nothing was ever synchronised; the admin test runner could not see that.
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 0);
        TestDataFactory.setSystemState(
            new Quote__c(Id = quote.Id, ERP_Sync_Status__c = 'Pending', ERP_Next_Attempt_At__c = null)
        );
        User integration = [SELECT Id FROM User WHERE Alias = 'qfint'];
        Test.setMock(HttpCalloutMock.class, new ERPMock(201, CREATED));

        Integer jobs;
        Test.startTest();
        System.runAs(integration) {
            jobs = ERPIntegrationService.dispatchDueQuotes();
        }
        Test.stopTest();

        Assert.areEqual(1, jobs);
        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areNotEqual(integration.Id, after.OwnerId);
        Assert.areEqual('Synced', after.ERP_Sync_Status__c);
        Assert.areEqual('SO-90001', after.ERP_Order_Id__c);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Integration_Log__c WHERE Related_Record_Id__c = :quote.Id AND Status__c = 'Success']
        );
    }

    @IsTest
    static void orderedQuote_isStillSynchronised() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        TestDataFactory.setSystemState(new Quote__c(Id = quote.Id, Status__c = 'Ordered'));
        Test.setMock(HttpCalloutMock.class, new ERPMock(201, CREATED));

        Test.startTest();
        ERPIntegrationService.syncQuotes(new List<Id>{ quote.Id });
        Test.stopTest();

        Assert.areEqual('Synced', TestDataFactory.requery(quote.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void requeueFailed_withoutPermission_isRefused() {
        Quote__c failed = leasedQuote('Contoso Ltd', 5);
        TestDataFactory.setSystemState(new Quote__c(Id = failed.Id, ERP_Sync_Status__c = 'Failed'));

        try {
            System.runAs([SELECT Id FROM User WHERE Alias = 'qferep'][0]) {
                ERPIntegrationService.requeueFailed(new Set<Id>{ failed.Id });
            }
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('permission'), e.getMessage());
        }
        Assert.areEqual('Failed', TestDataFactory.requery(failed.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void outcomeThatCannotBePersisted_isLoggedNotSwallowed() {
        ERPIntegrationService.configOverride = config(5);
        Quote__c quote = leasedQuote('Contoso Ltd', 1);
        ERPIntegrationService.SyncOutcome outcome = new ERPIntegrationService.SyncOutcome();
        outcome.quoteId = quote.Id;
        outcome.success = true;
        // A second quote with the same ERP order id violates the unique external id, so the write fails.
        Quote__c other = leasedQuote('Contoso Ltd', 1);
        TestDataFactory.setSystemState(new Quote__c(Id = other.Id, ERP_Order_Id__c = 'SO-DUP'));
        outcome.erpOrderId = 'SO-DUP';

        ERPIntegrationService.applyOutcomes(
            new Map<Id, Quote__c>{ quote.Id => quote },
            new List<ERPIntegrationService.SyncOutcome>{ outcome },
            config(5)
        );

        Assert.areEqual(
            'In Progress',
            TestDataFactory.requery(quote.Id).ERP_Sync_Status__c,
            'Lease expiry retries it later'
        );
        Assert.areEqual(1, Logger.PUBLISHED.size());
        Assert.areEqual('ERPIntegrationService.applyOutcomes', Logger.PUBLISHED[0].Source__c);
    }
}
