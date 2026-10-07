@IsTest
private class SalesQuoteServiceTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    private static SalesQuoteService.QuoteRequest request(List<SalesQuoteService.LineRequest> lines) {
        SalesQuoteService.QuoteRequest request = new SalesQuoteService.QuoteRequest();
        request.opportunityId = SalesLabTestFactory.opportunity().Id;
        request.termMonths = 24;
        request.lines = lines;
        return request;
    }

    private static SalesQuoteService.LineRequest line(Product2 product, Decimal quantity, Decimal discount) {
        SalesQuoteService.LineRequest line = new SalesQuoteService.LineRequest();
        line.productId = product.Id;
        line.quantity = quantity;
        line.discountPercent = discount;
        return line;
    }

    @IsTest
    static void preview_validDraft_returnsTotalsAndApprovalRequirement() {
        SalesLabTestFactory.installRouting();
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();

        SalesQuoteService.QuotePreview preview;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            preview = SalesQuoteService.preview(
                request(
                    new List<SalesQuoteService.LineRequest>{
                        line(catalog.software, 10, 25),
                        line(catalog.services, 1, 0)
                    }
                )
            );
        }

        Assert.isTrue(preview.isValid, String.join(preview.errors, '; '));
        Assert.areEqual(15000, preview.listTotal, '10 x 1,000 + 5,000');
        Assert.areEqual(12500, preview.netTotal, '10 x 750 + 5,000');
        Assert.areEqual(2500, preview.discountAmount);
        Assert.areEqual(25, preview.maxDiscountPercent);
        Assert.areEqual(2, preview.approval.tier, '25% is above the 20% finance tier');
        Assert.areEqual('Platform Subscription', preview.lines[0].productName);
        Assert.areEqual(40, preview.lines[0].maxDiscountPercent);
    }

    @IsTest
    static void preview_discountAbovePolicyOrBadQuantity_isInvalidWithLineErrors() {
        SalesLabTestFactory.installRouting();
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();

        SalesQuoteService.QuotePreview preview;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            preview = SalesQuoteService.preview(
                request(
                    new List<SalesQuoteService.LineRequest>{
                        line(catalog.hardware, 1, 16),
                        line(catalog.software, 0, 0)
                    }
                )
            );
        }

        Assert.isFalse(preview.isValid);
        Assert.isTrue(preview.lines[0].error.contains('15'), preview.lines[0].error);
        Assert.isTrue(preview.lines[1].error.contains('Quantity'));
        Assert.areEqual(2, preview.errors.size());
    }

    @IsTest
    static void save_createsQuoteWithLines_rollsUpAndSetsPrimaryQuote() {
        SalesLabTestFactory.installRouting();
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();

        Id quoteId;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Test.startTest();
            quoteId = SalesQuoteService.save(
                request(
                    new List<SalesQuoteService.LineRequest>{
                        line(catalog.software, 10, 25),
                        line(catalog.services, 1, 0)
                    }
                )
            );
            Test.stopTest();
        }

        Quote_Configuration__c quote = SalesLabTestFactory.requery(quoteId);
        Assert.areEqual('Draft', quote.Status__c);
        Assert.areEqual(15000, quote.Total_List_Amount__c, 'Native roll-up summary over the line formula');
        Assert.areEqual(12500, quote.Total_Net_Amount__c);
        Assert.areEqual(25, quote.Max_Discount_Percent__c);
        Assert.areEqual(2, quote.Line_Count__c);
        Assert.areEqual(SalesLabTestFactory.opportunity().AccountId, quote.Account__c);
        Assert.areEqual(Date.today().addDays(30), quote.Valid_Until__c, 'Defaulted by the before-save flow');
        Assert.areEqual(
            quoteId,
            [SELECT Primary_Quote_Configuration__c FROM Opportunity WHERE Id = :SalesLabTestFactory.opportunity().Id]
            .Primary_Quote_Configuration__c
        );
    }

    @IsTest
    static void save_invalidDraft_savesNothing() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();

        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            try {
                SalesQuoteService.save(
                    request(new List<SalesQuoteService.LineRequest>{ line(catalog.unpriced, 1, 0) })
                );
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('no active price'), e.getMessage());
            }
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Quote_Configuration__c]);
    }

    @IsTest
    static void validationRule_discountAbovePolicy_isRejectedOnDirectInsert() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Database.SaveResult result;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Quote_Configuration__c quote = new Quote_Configuration__c(
                Opportunity__c = SalesLabTestFactory.opportunity().Id
            );
            insert quote;
            // Bypasses the service: the trigger stamps the cap, then the validation rule judges it.
            result = Database.insert(SalesLabTestFactory.line(quote.Id, catalog.hardware, 1, 20), false);
        }

        Assert.isFalse(result.isSuccess());
        Assert.isTrue(result.getErrors()[0].getMessage().contains('maximum allowed by the discount policy'));
    }

    @IsTest
    static void lines_lockedAfterSubmission_forInsertEditAndDelete() {
        SalesLabTestFactory.installRouting();
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Database.SaveResult added;
        Database.SaveResult edited;
        Database.DeleteResult removed;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Quote_Configuration__c quote = SalesLabTestFactory.quoteWithLine(catalog.software, 5, 15);
            Assert.isTrue(SalesQuoteApprovalService.submit(quote.Id).success);
            Quote_Configuration_Line__c existing = [
                SELECT Id
                FROM Quote_Configuration_Line__c
                WHERE Quote_Configuration__c = :quote.Id
            ];

            added = Database.insert(SalesLabTestFactory.line(quote.Id, catalog.services, 1, 0), false);
            edited = Database.update(new Quote_Configuration_Line__c(Id = existing.Id, Discount_Percent__c = 5), false);
            removed = Database.delete(existing.Id, false);
        }

        Assert.isFalse(added.isSuccess(), 'Validation rule Lines_Locked_After_Submit');
        Assert.isFalse(edited.isSuccess());
        Assert.isFalse(removed.isSuccess(), 'Deletes are locked by the trigger');
        Assert.isTrue(removed.getErrors()[0].getMessage().contains('Recall the quote first'));
    }

    @IsTest
    static void quote_statusAndSystemFields_cannotBeEditedDirectly() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Database.SaveResult forgedStatus;
        Database.SaveResult cancelled;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            Quote_Configuration__c quote = SalesLabTestFactory.quoteWithLine(catalog.software, 1, 0);
            forgedStatus = Database.update(new Quote_Configuration__c(Id = quote.Id, Status__c = 'Approved'), false);
            cancelled = Database.update(new Quote_Configuration__c(Id = quote.Id, Status__c = 'Cancelled'), false);
        }

        Assert.isFalse(forgedStatus.isSuccess(), 'A quote cannot approve itself through an edit');
        Assert.isTrue(cancelled.isSuccess(), 'Cancelling a draft is the one status change a user may make');
    }

    @IsTest
    static void quote_priceBookCannotChangeOnceLinesExist() {
        SalesLabTestFactory.Catalog catalog = SalesLabTestFactory.catalog();
        Pricebook2 other = new Pricebook2(Name = 'RevOps Lab EMEA', IsActive = true, Sales_Region__c = 'EMEA');
        insert other;
        Quote_Configuration__c quote;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            quote = SalesLabTestFactory.quoteWithLine(catalog.software, 1, 0);
        }

        Database.SaveResult result = Database.update(
            new Quote_Configuration__c(Id = quote.Id, Price_Book__c = other.Id),
            false
        );

        Assert.isFalse(result.isSuccess());
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Remove the lines'));
    }
}
