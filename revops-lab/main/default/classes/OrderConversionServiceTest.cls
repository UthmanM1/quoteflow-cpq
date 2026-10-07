@IsTest
private class OrderConversionServiceTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    private static Quote_Configuration__c approvedQuote() {
        SalesLabTestFactory.installRouting();
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Quote_Configuration__c quote;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            quote = SalesLabTestFactory.quoteWithLine(catalog.software, 4, 5);
            insert SalesLabTestFactory.line(quote.Id, catalog.services, 1, 0);
            Assert.areEqual('Approved', SalesQuoteApprovalService.submit(quote.Id).status);
        }
        return SalesLabTestFactory.requery(quote.Id);
    }

    @IsTest
    static void convert_createsOrderItemsSubscriptionsAndQueuesTheErp() {
        Quote_Configuration__c quote = approvedQuote();

        OrderConversionService.ConversionResult result;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Test.startTest();
            result = OrderConversionService.convert(quote.Id, 'PO-4471');
            Test.stopTest();
        }

        Order order = [
            SELECT PoNumber, Quote_Configuration__c, ERP_Sync_Status__c, OpportunityId, Status
            FROM Order
            WHERE Id = :result.orderId
        ];
        Assert.areEqual('PO-4471', order.PoNumber);
        Assert.areEqual(quote.Id, order.Quote_Configuration__c);
        Assert.areEqual('Pending', order.ERP_Sync_Status__c, 'Queued for the ERP');
        Assert.areEqual(2, result.orderItemsCreated);
        Assert.areEqual(
            950,
            [SELECT UnitPrice FROM OrderItem WHERE OrderId = :order.Id AND Product2.ProductCode = 'RL-PLATFORM']
            .UnitPrice
        );
        Assert.areEqual(1, result.subscriptionsCreated, 'Only the annual product becomes a subscription');
        Sales_Subscription__c subscription = [
            SELECT Annual_Value__c, Start_Date__c, End_Date__c, Status__c
            FROM Sales_Subscription__c
        ];
        Assert.areEqual(3800, subscription.Annual_Value__c);
        Assert.areEqual(subscription.Start_Date__c.addMonths(12), subscription.End_Date__c);
        Quote_Configuration__c after = SalesLabTestFactory.requery(quote.Id);
        Assert.areEqual('Ordered', after.Status__c);
        Assert.areEqual(order.Id, after.Order__c);
    }

    @IsTest
    static void convert_withoutPurchaseOrderNumber_isRefused() {
        Quote_Configuration__c quote = approvedQuote();

        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            try {
                OrderConversionService.convert(quote.Id, '  ');
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('PO number'), e.getMessage());
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Order]);
    }

    @IsTest
    static void convert_unapprovedQuote_isRefused() {
        SalesLabTestFactory.installRouting();
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Quote_Configuration__c draft = SalesLabTestFactory.quoteWithLine(
                SalesLabTestFactory.catalog().software,
                1,
                0
            );
            try {
                OrderConversionService.convert(draft.Id, 'PO-1');
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('Only approved quotes'), e.getMessage());
            }
        }
    }

    @IsTest
    static void convert_byManagerWhoDoesNotOwnTheQuote_isRefused() {
        Quote_Configuration__c quote = approvedQuote();

        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.MANAGER)) {
            try {
                OrderConversionService.convert(quote.Id, 'PO-1');
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('Only the quote owner'), e.getMessage());
            }
        }
    }

    @IsTest
    static void opportunity_closedWon_requiresAnOrderedPrimaryQuote() {
        Quote_Configuration__c quote = approvedQuote();
        Id opportunityId = SalesLabTestFactory.opportunity().Id;

        Database.SaveResult tooEarly;
        Database.SaveResult afterOrder;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            tooEarly = Database.update(new Opportunity(Id = opportunityId, StageName = 'Closed Won'), false);
            OrderConversionService.convert(quote.Id, 'PO-9');
            afterOrder = Database.update(new Opportunity(Id = opportunityId, StageName = 'Closed Won'), false);
        }

        Assert.isFalse(tooEarly.isSuccess(), 'Validation rule Closed_Won_Requires_Ordered_Quote');
        Assert.isTrue(afterOrder.isSuccess(), String.valueOf(afterOrder.getErrors()));
    }
}
