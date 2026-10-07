@IsTest
private class QuoteCalculationServiceTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        TestDataFactory.account('Northwind Traders', 'ERP-C-1001');
    }

    private static TestDataFactory.Catalog catalog() {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog c = new TestDataFactory.Catalog();
        c.pricebookId = Test.getStandardPricebookId();
        for (Product2 p : [SELECT Id, ProductCode FROM Product2]) {
            if (p.ProductCode == 'QF-USER-SEAT') {
                c.seat = p;
            }
            if (p.ProductCode == 'QF-IMPL-HOURLY') {
                c.implementation = p;
            }
            if (p.ProductCode == 'QF-PLATFORM-ENT') {
                c.bundle = p;
            }
            if (p.ProductCode == 'QF-SECURITY-PACK') {
                c.securityPack = p;
            }
        }
        return c;
    }

    private static Account account() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    private static Quote_Line__c priced(Id lineId) {
        return [
            SELECT
                Quantity__c,
                List_Unit_Price__c,
                Base_Unit_Price__c,
                Schedule_Discount_Pct__c,
                Manual_Discount_Pct__c,
                Effective_Discount_Pct__c,
                Net_Unit_Price__c,
                List_Total__c,
                Net_Total__c,
                Pricing_Source__c,
                Billing_Model__c
            FROM Quote_Line__c
            WHERE Id = :lineId
        ];
    }

    @IsTest
    static void line_belowFirstTier_pricesAtListWithNoDiscount() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 5, null);

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote_Line__c result = priced(line.Id);
        Assert.areEqual(120, result.List_Unit_Price__c);
        Assert.areEqual(0, result.Effective_Discount_Pct__c);
        Assert.areEqual(120, result.Net_Unit_Price__c);
        Assert.areEqual(600, result.Net_Total__c, '5 seats x 120 x 12/12');
        Assert.areEqual('List Price', result.Pricing_Source__c);
    }

    @IsTest
    static void line_volumeTierPlusManualDiscount_compoundsMultiplicatively() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 30, 10);

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote_Line__c result = priced(line.Id);
        Assert.areEqual(10, result.Schedule_Discount_Pct__c, '30 seats falls in the 25-99 tier');
        Assert.areEqual(19, result.Effective_Discount_Pct__c, '1 - 0.90 x 0.90 = 19%');
        Assert.areEqual(97.20, result.Net_Unit_Price__c, '120 x 0.81');
        Assert.areEqual(2916.00, result.Net_Total__c, '97.20 x 30');
        Assert.areEqual(3600.00, result.List_Total__c);
    }

    @IsTest
    static void line_subscriptionScalesWithTerm_oneTimeDoesNot() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 36);
        List<Quote_Line__c> lines = new List<Quote_Line__c>{
            TestDataFactory.line(quote.Id, catalog.seat, 5, null),
            TestDataFactory.line(quote.Id, catalog.implementation, 10, null)
        };

        Test.startTest();
        insert lines;
        Test.stopTest();

        Assert.areEqual(1800, priced(lines[0].Id).Net_Total__c, '5 x 120 x 36/12');
        Assert.areEqual(2000, priced(lines[1].Id).Net_Total__c, 'Implementation hours are not term-scaled');
        Assert.areEqual('One-Time', priced(lines[1].Id).Billing_Model__c);
    }

    @IsTest
    static void line_contractedPrice_overridesListAndSkipsScheduleDiscount() {
        TestDataFactory.Catalog catalog = catalog();
        Account account = account();
        insert new Contracted_Price__c(
            Account__c = account.Id,
            Product__c = catalog.seat.Id,
            Unit_Price__c = 100,
            Start_Date__c = Date.today().addDays(-30),
            End_Date__c = Date.today().addDays(300)
        );
        Quote__c quote = TestDataFactory.quote(account.Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 30, null);

        Test.startTest();
        insert line;
        Test.stopTest();

        Quote_Line__c result = priced(line.Id);
        Assert.areEqual('Contracted Price', result.Pricing_Source__c);
        Assert.areEqual(100, result.Base_Unit_Price__c);
        Assert.areEqual(0, result.Schedule_Discount_Pct__c, 'Volume tiers are not stacked on negotiated prices');
        Assert.areEqual(3000, result.Net_Total__c);
        Assert.areEqual(
            0,
            result.Effective_Discount_Pct__c,
            'Contracted price is pre-approved, so it is not a discount for approval purposes'
        );
    }

    @IsTest
    static void line_expiredContractedPrice_isIgnored() {
        TestDataFactory.Catalog catalog = catalog();
        Account account = account();
        insert new Contracted_Price__c(
            Account__c = account.Id,
            Product__c = catalog.seat.Id,
            Unit_Price__c = 100,
            Start_Date__c = Date.today().addDays(-400),
            End_Date__c = Date.today().addDays(-10)
        );
        Quote__c quote = TestDataFactory.quote(account.Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 5, null);

        insert line;

        Assert.areEqual('List Price', priced(line.Id).Pricing_Source__c);
    }

    @IsTest
    static void line_userSuppliedCalculatedFields_areOverwritten() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 5, null);
        line.Net_Unit_Price__c = 1;
        line.Net_Total__c = 5;
        line.Effective_Discount_Pct__c = 99;

        insert line;

        Quote_Line__c result = priced(line.Id);
        Assert.areEqual(120, result.Net_Unit_Price__c, 'Client-supplied price must never survive');
        Assert.areEqual(0, result.Effective_Discount_Pct__c);
    }

    @IsTest
    static void line_invalidInput_isRejectedWithClearMessage() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);

        Database.SaveResult zeroQuantity = Database.insert(
            TestDataFactory.line(quote.Id, catalog.seat, 0, null),
            false
        );
        Database.SaveResult excessiveDiscount = Database.insert(
            TestDataFactory.line(quote.Id, catalog.seat, 5, 75),
            false
        );

        Assert.isTrue(!zeroQuantity.isSuccess());
        Assert.isTrue(zeroQuantity.getErrors()[0].getMessage().contains('Quantity must be greater than zero'));
        Assert.isTrue(!excessiveDiscount.isSuccess());
        Assert.isTrue(excessiveDiscount.getErrors()[0].getMessage().contains('between 0% and 60%'));
    }

    @IsTest
    static void line_productMissingFromPricebook_isRejected() {
        TestDataFactory.Catalog catalog = catalog();
        Product2 unpriced = new Product2(
            Name = 'Unpriced',
            ProductCode = 'QF-NOPRICE',
            Family = 'Subscriptions',
            Product_Type__c = 'Standalone',
            Billing_Model__c = 'Subscription',
            IsActive = true
        );
        insert unpriced;
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);

        Database.SaveResult result = Database.insert(TestDataFactory.line(quote.Id, unpriced, 1, null), false);

        Assert.isTrue(!result.isSuccess());
        Assert.isTrue(
            result.getErrors()[0].getMessage().contains('no active price'),
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void rollUp_aggregatesTotalsAndRoutesApprovalLevel() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);

        Test.startTest();
        insert new List<Quote_Line__c>{
            TestDataFactory.line(quote.Id, catalog.seat, 5, null),
            TestDataFactory.line(quote.Id, catalog.implementation, 10, 25)
        };
        Test.stopTest();

        Quote__c result = TestDataFactory.requery(quote.Id);
        Assert.areEqual(2600, result.List_Amount__c, '5 x 120 + 10 x 200');
        Assert.areEqual(2100, result.Net_Amount__c, '600 + 2000 x 0.75');
        Assert.areEqual(500, result.Total_Discount_Amount__c);
        Assert.areEqual(19.23, result.Blended_Discount_Pct__c, '500 / 2600');
        Assert.areEqual(25, result.Max_Line_Discount_Pct__c);
        Assert.areEqual(2, result.Required_Approval_Level__c, '25% exceeds the 20% level-2 threshold');
    }

    @IsTest
    static void rollUp_afterLineDeleted_recalculatesTotals() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c discounted = TestDataFactory.line(quote.Id, catalog.implementation, 10, 25);
        insert new List<Quote_Line__c>{ TestDataFactory.line(quote.Id, catalog.seat, 5, null), discounted };

        delete discounted;

        Quote__c result = TestDataFactory.requery(quote.Id);
        Assert.areEqual(600, result.Net_Amount__c);
        Assert.areEqual(0, result.Max_Line_Discount_Pct__c);
        Assert.areEqual(
            0,
            result.Required_Approval_Level__c,
            'Approval requirement disappears with the discounted line'
        );
    }

    @IsTest
    static void rollUp_includedLine_contributesNothing() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c header = TestDataFactory.line(quote.Id, catalog.bundle, 1, null);
        insert header;
        insert new Quote_Line__c(
            Quote__c = quote.Id,
            Product__c = catalog.securityPack.Id,
            Quantity__c = 1,
            Parent_Line__c = header.Id,
            Is_Bundle_Component__c = true,
            Is_Included__c = true
        );

        Quote__c result = TestDataFactory.requery(quote.Id);

        Assert.areEqual(10000, result.Net_Amount__c, 'Only the bundle header is billable');
        Assert.areEqual(0, result.Max_Line_Discount_Pct__c);
    }

    @IsTest
    static void reprice_termChange_scalesSubscriptionLines() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c line = TestDataFactory.line(quote.Id, catalog.seat, 5, null);
        insert line;

        Test.startTest();
        update new Quote__c(Id = quote.Id, Term_Months__c = 24);
        Test.stopTest();

        Assert.areEqual(1200, priced(line.Id).Net_Total__c, 'Lines re-priced for the new term');
        Assert.areEqual(1200, TestDataFactory.requery(quote.Id).Net_Amount__c);
    }

    @IsTest
    static void bulk_twoHundredLinesAcrossQuotes_staysWithinQueryBudget() {
        TestDataFactory.Catalog catalog = catalog();
        Account account = account();
        List<Quote__c> quotes = new List<Quote__c>();
        for (Integer i = 0; i < 4; i++) {
            quotes.add(new Quote__c(Account__c = account.Id, Pricebook__c = catalog.pricebookId, Term_Months__c = 12));
        }
        insert quotes;
        List<Quote_Line__c> lines = new List<Quote_Line__c>();
        for (Integer i = 0; i < 200; i++) {
            lines.add(
                TestDataFactory.line(
                    quotes[Math.mod(i, quotes.size())].Id,
                    i < 100 ? catalog.seat : catalog.implementation,
                    10 + i,
                    0
                )
            );
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        insert lines;
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.isTrue(queriesUsed < 20, 'Pricing must not query per line; used ' + queriesUsed);
        Assert.areEqual(200, [SELECT COUNT() FROM Quote_Line__c WHERE Net_Total__c != NULL]);
        for (Quote__c quote : [SELECT Net_Amount__c FROM Quote__c WHERE Id IN :quotes]) {
            Assert.isTrue(quote.Net_Amount__c > 0, 'Every quote received rolled-up totals');
        }
    }
}
