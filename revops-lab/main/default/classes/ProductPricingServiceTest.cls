@IsTest
private class ProductPricingServiceTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    @IsTest
    static void priceLines_setsListPriceFamilyAndBillingFromThePriceBook() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>{
            new Quote_Configuration_Line__c(Product__c = catalog.software.Id, Quantity__c = 2),
            new Quote_Configuration_Line__c(Product__c = catalog.services.Id, Quantity__c = 1)
        };

        Map<Integer, String> errors;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            errors = ProductPricingService.priceLines(lines, new List<Id>{ catalog.pricebookId, catalog.pricebookId });
        }

        Assert.isTrue(errors.isEmpty(), String.valueOf(errors));
        Assert.areEqual(1000, lines[0].List_Unit_Price__c);
        Assert.areEqual('Software', lines[0].Product_Family__c);
        Assert.areEqual('Annual', lines[0].Billing_Frequency__c);
        Assert.areEqual('One-Time', lines[1].Billing_Frequency__c);
        Assert.isNotNull(lines[0].Price_Book_Entry_Id__c);
    }

    @IsTest
    static void priceLines_productWithoutPriceOrPriceBook_isReportedPerLine() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>{
            new Quote_Configuration_Line__c(Product__c = catalog.unpriced.Id, Quantity__c = 1),
            new Quote_Configuration_Line__c(Product__c = catalog.software.Id, Quantity__c = 1),
            new Quote_Configuration_Line__c(Quantity__c = 1)
        };

        Map<Integer, String> errors;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            errors = ProductPricingService.priceLines(
                lines,
                new List<Id>{ catalog.pricebookId, null, catalog.pricebookId }
            );
        }

        Assert.isTrue(errors.get(0).contains('no active price'));
        Assert.isTrue(errors.get(1).contains('no price book'));
        Assert.isTrue(errors.get(2).contains('Select a product'));
    }

    @IsTest
    static void trigger_overwritesUserSuppliedListPrice() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Quote_Configuration_Line__c line;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Quote_Configuration__c quote = new Quote_Configuration__c(
                Opportunity__c = SalesLabTestFactory.opportunity().Id
            );
            insert quote;
            line = SalesLabTestFactory.line(quote.Id, catalog.software, 3, 0);
            line.List_Unit_Price__c = 1;
            insert line;
        }

        Quote_Configuration_Line__c saved = [
            SELECT List_Unit_Price__c, Net_Total__c
            FROM Quote_Configuration_Line__c
            WHERE Id = :line.Id
        ];
        Assert.areEqual(1000, saved.List_Unit_Price__c, 'The price book, not the caller, decides the list price');
        Assert.areEqual(3000, saved.Net_Total__c);
    }

    @IsTest
    static void trigger_twoHundredLinesAcrossQuotes_usesConstantQueries() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            List<Quote_Configuration__c> quotes = new List<Quote_Configuration__c>();
            for (Integer i = 0; i < 4; i++) {
                quotes.add(new Quote_Configuration__c(Opportunity__c = SalesLabTestFactory.opportunity().Id));
            }
            insert quotes;
            List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>();
            for (Integer i = 0; i < 200; i++) {
                Product2 product = Math.mod(i, 2) == 0 ? catalog.software : catalog.hardware;
                lines.add(SalesLabTestFactory.line(quotes[Math.mod(i, 4)].Id, product, 1, 5));
            }

            Test.startTest();
            insert lines;
            Integer queries = Limits.getQueries();
            Test.stopTest();

            Assert.isTrue(queries <= 10, 'Pricing and policy lookups must not run per line; used ' + queries);
        }
        Assert.areEqual(200, [SELECT COUNT() FROM Quote_Configuration_Line__c]);
    }
}
