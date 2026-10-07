@IsTest
private class QuoteOrderServiceTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        TestDataFactory.account('Tailspin', 'ERP-T-1');
        TestDataFactory.user('qforep', null, null, TestDataFactory.REP_SETS);
        TestDataFactory.user('qforep2', null, null, TestDataFactory.REP_SETS);
    }

    private static User userByAlias(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias LIMIT 1];
    }

    private static Quote__c approvedQuote(Integer term) {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog catalog = new TestDataFactory.Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        catalog.seat = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'];
        catalog.implementation = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-IMPL-HOURLY'];
        Quote__c quote = TestDataFactory.quote([SELECT Id FROM Account LIMIT 1].Id, catalog.pricebookId, term);
        insert new List<Quote_Line__c>{
            TestDataFactory.line(quote.Id, catalog.seat, 5, null),
            TestDataFactory.line(quote.Id, catalog.implementation, 10, null)
        };
        return TestDataFactory.approve(TestDataFactory.requery(quote.Id), QuoteConstants.ERP_PENDING);
    }

    @IsTest
    static void convert_approvedQuote_createsOrderItemsAndSubscriptions() {
        Quote__c quote = approvedQuote(24);

        Test.startTest();
        QuoteOrderService.ConversionResult result = QuoteOrderService.convert(quote.Id);
        Test.stopTest();

        Order order = [SELECT AccountId, Source_Quote__c, Pricebook2Id FROM Order WHERE Id = :result.orderId];
        Assert.areEqual(quote.Id, order.Source_Quote__c);
        Assert.areEqual(2, [SELECT COUNT() FROM OrderItem WHERE OrderId = :order.Id]);
        Assert.areEqual(
            1,
            result.subscriptionsCreated,
            'Only the subscription line becomes a Subscription__c; services do not'
        );
        Subscription__c subscription = [
            SELECT Annual_Recurring_Revenue__c, End_Date__c, Start_Date__c
            FROM Subscription__c
            WHERE Quote__c = :quote.Id
        ];
        Assert.areEqual(600, subscription.Annual_Recurring_Revenue__c, '5 x 120 per year, independent of term');
        Assert.areEqual(subscription.Start_Date__c.addMonths(24), subscription.End_Date__c);
        Assert.areEqual('Ordered', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void convert_draftQuote_isRefused() {
        Quote__c draft = TestDataFactory.quote([SELECT Id FROM Account LIMIT 1].Id, Test.getStandardPricebookId(), 12);

        try {
            QuoteOrderService.convert(draft.Id);
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('Only approved quotes'), e.getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Order]);
    }

    @IsTest
    static void convert_twice_isRefusedBecauseQuoteIsAlreadyOrdered() {
        Quote__c quote = approvedQuote(12);
        QuoteOrderService.convert(quote.Id);

        try {
            QuoteOrderService.convert(quote.Id);
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('current status: Ordered'), e.getMessage());
        }
        Assert.areEqual(1, [SELECT COUNT() FROM Order]);
    }

    // ------------------------------------------------------------------ added in the principal review

    @IsTest
    static void convert_quoteWithOpportunity_linksTheOrder() {
        // Regression: the selector used by convert() did not query Opportunity__c (SObjectException at runtime).
        Account account = [SELECT Id FROM Account LIMIT 1];
        Opportunity opportunity = TestDataFactory.opportunity(account.Id);
        TestDataFactory.installPolicy();
        Quote__c draft = new Quote__c(
            Account__c = account.Id,
            Opportunity__c = opportunity.Id,
            Pricebook__c = Test.getStandardPricebookId(),
            Term_Months__c = 12
        );
        insert draft;
        insert TestDataFactory.line(
            draft.Id,
            new Product2(Id = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'].Id),
            2,
            null
        );
        TestDataFactory.approve(draft, QuoteConstants.ERP_PENDING);

        Test.startTest();
        Id orderId = QuoteOrderService.convert(draft.Id).orderId;
        Test.stopTest();

        Assert.areEqual(opportunity.Id, [SELECT OpportunityId FROM Order WHERE Id = :orderId].OpportunityId);
    }

    @IsTest
    static void convert_keepsTheQuoteEligibleForErpSync() {
        Quote__c quote = approvedQuote(12);

        QuoteOrderService.convert(quote.Id);

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Ordered', after.Status__c);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Set<Id> due = new Map<Id, Quote__c>(QuoteSelector.quotesDueForErpSync(Datetime.now(), 10)).keySet();
        Assert.isTrue(due.contains(quote.Id), 'Converting must not strand a pending ERP sync');
    }

    @IsTest
    static void convert_byReaderWhoIsNotTheOwner_isRefused() {
        Quote__c quote = approvedQuote(12);
        User other = userByAlias('qforep2');
        QuoteSharingService.grantApproverAccess(
            new Map<Id, Id>{ quote.Id => other.Id },
            new Map<Id, Id>{ quote.Id => quote.OwnerId }
        );

        try {
            System.runAs(other) {
                QuoteOrderService.convert(quote.Id);
            }
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('Only the quote owner'), e.getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Order]);
    }

    @IsTest
    static void convert_asSalesRepPersona_usesOnlyRepPermissions() {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog catalog = new TestDataFactory.Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        catalog.seat = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'];
        User rep = userByAlias('qforep');
        Quote__c quote;
        System.runAs(rep) {
            quote = TestDataFactory.quoteWithSeats(catalog, [SELECT Id FROM Account LIMIT 1].Id, 3, null);
        }
        TestDataFactory.approve(quote, QuoteConstants.ERP_PENDING);

        QuoteOrderService.ConversionResult result;
        Test.startTest();
        System.runAs(rep) {
            result = QuoteOrderService.convert(quote.Id);
        }
        Test.stopTest();

        Assert.areNotEqual(null, result.orderId);
        Assert.areEqual(1, result.subscriptionsCreated);
        Assert.areEqual(
            'Ordered',
            TestDataFactory.requery(quote.Id).Status__c,
            'Status change is system-owned and still succeeds'
        );
    }
}
