@IsTest
private class SalesERPIntegrationServiceTest {
    /** Scriptable ERP double; records every request so tests can assert on what was sent. */
    private class ErpMock implements HttpCalloutMock {
        Integer status;
        String body;
        Boolean timeout = false;
        List<HttpRequest> requests = new List<HttpRequest>();

        ErpMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            requests.add(request);
            if (timeout) {
                throw new CalloutException('Read timed out');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setHeader('Content-Type', 'application/json');
            response.setBody(body);
            return response;
        }
    }

    private static final String CREATED = '{"erpOrderNumber":"ATL-SO-778812","status":"ACCEPTED"}';

    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    private static SalesERPIntegrationService.Settings settings(Integer maxRetries) {
        SalesERPIntegrationService.Settings cfg = new SalesERPIntegrationService.Settings();
        cfg.maxRetries = maxRetries;
        return cfg;
    }

    private static Order order(Id orderId) {
        return [
            SELECT ERP_Sync_Status__c, ERP_Order_Number__c, ERP_Retry_Count__c, ERP_Next_Retry_At__c, ERP_Last_Error__c
            FROM Order
            WHERE Id = :orderId
        ];
    }

    private static Sales_Integration_Log__c onlyLog() {
        return [
            SELECT Outcome__c, Http_Status_Code__c, Endpoint__c, Correlation_Id__c, Related_Record_Id__c, Attempt__c
            FROM Sales_Integration_Log__c
        ];
    }

    @IsTest
    static void sync_created_marksTheOrderSyncedAndLogsTheCall() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(HttpCalloutMock.class, new ErpMock(201, CREATED));

        Test.startTest();
        List<SalesERPIntegrationService.SyncOutcome> outcomes = SalesERPIntegrationService.syncOrders(
            new List<Id>{ orderId }
        );
        Test.stopTest();

        Assert.isTrue(outcomes[0].success);
        Order after = order(orderId);
        Assert.areEqual('Synced', after.ERP_Sync_Status__c);
        Assert.areEqual('ATL-SO-778812', after.ERP_Order_Number__c);
        Sales_Integration_Log__c log = onlyLog();
        Assert.areEqual('Success', log.Outcome__c);
        Assert.areEqual(201, log.Http_Status_Code__c);
        Assert.areEqual('callout:Sales_ERP/api/v2/orders', log.Endpoint__c, 'Named Credential reference, never a URL');
        Assert.areEqual(outcomes[0].correlationId, log.Correlation_Id__c);
        Assert.areEqual(String.valueOf(orderId), log.Related_Record_Id__c);
    }

    @IsTest
    static void request_isJsonWithCorrelationAndIdempotencyHeaders_andNoCredentials() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        ErpMock mock = new ErpMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        HttpRequest sent = mock.requests[0];
        Assert.areEqual('POST', sent.getMethod());
        Assert.areEqual('application/json', sent.getHeader('Content-Type'));
        Assert.areEqual('sf-order-' + orderId, sent.getHeader('Idempotency-Key'));
        Assert.isNull(sent.getHeader('Authorization'), 'Authentication is injected by the Named Credential');
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(sent.getBody());
        Assert.areEqual(sent.getHeader('X-Correlation-Id'), body.get('correlationId'));
        Assert.areEqual('ERP-1001', body.get('customerAccountNumber'));
        Assert.areEqual('PO-4471', body.get('purchaseOrderNumber'));
        List<Object> lines = (List<Object>) body.get('lines');
        Assert.areEqual(2, lines.size());
        Set<Object> itemCodes = new Set<Object>();
        for (Object line : lines) {
            itemCodes.add(((Map<String, Object>) line).get('itemCode'));
        }
        Assert.isTrue(itemCodes.contains('ATL-RL-PLATFORM'));
    }

    @IsTest
    static void sync_conflictWithOrderNumber_isAnIdempotentSuccess() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(
            HttpCalloutMock.class,
            new ErpMock(409, '{"erpOrderNumber":"ATL-SO-778812","errorCode":"DUPLICATE"}')
        );

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        Assert.areEqual('Synced', order(orderId).ERP_Sync_Status__c);
    }

    @IsTest
    static void sync_validationError_isPermanent() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(
            HttpCalloutMock.class,
            new ErpMock(422, '{"errorCode":"UNKNOWN_ITEM","message":"Item ATL-RL-IMPL is not sellable"}')
        );

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        Order after = order(orderId);
        Assert.areEqual('Failed', after.ERP_Sync_Status__c);
        Assert.isTrue(after.ERP_Last_Error__c.contains('UNKNOWN_ITEM'), after.ERP_Last_Error__c);
        Assert.areEqual('Permanent Failure', onlyLog().Outcome__c);
    }

    @IsTest
    static void sync_serverError_isRetriedWithBackoff() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(HttpCalloutMock.class, new ErpMock(503, '{"errorCode":"MAINTENANCE"}'));

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        Order after = order(orderId);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Assert.areEqual(1, after.ERP_Retry_Count__c);
        Assert.isTrue(after.ERP_Next_Retry_At__c > Datetime.now().addMinutes(4), 'First retry waits the 5 minute base');
        Assert.areEqual('Retryable Failure', onlyLog().Outcome__c);
    }

    @IsTest
    static void sync_timeout_isRetryable_untilRetriesAreExhausted() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(1);
        ErpMock mock = new ErpMock(200, '');
        mock.timeout = true;
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        Order after = order(orderId);
        Assert.areEqual('Failed', after.ERP_Sync_Status__c, 'maxRetries = 1, so the first retryable failure is final');
        Assert.isTrue(after.ERP_Last_Error__c.contains('timed out'));
    }

    @IsTest
    static void sync_accountWithoutErpNumber_failsWithoutCallingTheErp() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        Account account = [SELECT Id FROM Account LIMIT 1];
        account.ERP_Account_Number__c = null;
        update account;
        SalesERPIntegrationService.settingsOverride = settings(4);
        ErpMock mock = new ErpMock(201, CREATED);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        SalesERPIntegrationService.syncOrders(new List<Id>{ orderId });
        Test.stopTest();

        Assert.areEqual(0, mock.requests.size());
        Assert.areEqual('Failed', order(orderId).ERP_Sync_Status__c);
    }

    @IsTest
    static void integrationUserPersona_dispatchesAndSyncsOrdersItDoesNotOwn() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(HttpCalloutMock.class, new ErpMock(201, CREATED));
        User integration = SalesLabTestFactory.user(SalesLabTestFactory.INTEGRATION);

        Integer jobs;
        Test.startTest();
        System.runAs(integration) {
            jobs = SalesERPIntegrationService.dispatchDueOrders();
        }
        Test.stopTest();

        Assert.areEqual(1, jobs);
        Assert.areEqual(
            'Synced',
            order(orderId).ERP_Sync_Status__c,
            'Queueable ran at stopTest as the integration user'
        );
        Assert.areEqual(1, [SELECT COUNT() FROM Sales_Integration_Log__c WHERE Outcome__c = 'Success']);
    }

    @IsTest
    static void requestSync_requiresTheRunErpSyncPermission() {
        Id orderId = SalesLabTestFactory.orderedQuote(3);
        SalesERPIntegrationService.settingsOverride = settings(4);
        Test.setMock(HttpCalloutMock.class, new ErpMock(201, CREATED));

        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            try {
                SalesERPIntegrationService.requestSync(new Set<Id>{ orderId });
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('permission'), e.getMessage());
            }
        }
        Id jobId;
        Test.startTest();
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.ADMIN)) {
            jobId = SalesERPIntegrationService.requestSync(new Set<Id>{ orderId });
        }
        Test.stopTest();

        Assert.isNotNull(jobId);
        Assert.areEqual('Synced', order(orderId).ERP_Sync_Status__c);
    }

    @IsTest
    static void backoff_growsExponentiallyAndIsCapped() {
        SalesERPIntegrationService.Settings cfg = settings(10);
        Assert.areEqual(5, SalesERPIntegrationService.backoffMinutes(1, cfg));
        Assert.areEqual(10, SalesERPIntegrationService.backoffMinutes(2, cfg));
        Assert.areEqual(40, SalesERPIntegrationService.backoffMinutes(4, cfg));
        Assert.areEqual(240, SalesERPIntegrationService.backoffMinutes(9, cfg));
    }
}
