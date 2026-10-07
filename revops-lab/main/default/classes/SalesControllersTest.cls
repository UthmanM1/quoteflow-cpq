@IsTest
private class SalesControllersTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    private static User rep() {
        return SalesLabTestFactory.user(SalesLabTestFactory.REP);
    }

    private static SalesQuoteService.QuoteRequest request(Product2 product, Decimal quantity, Decimal discount) {
        SalesQuoteService.LineRequest line = new SalesQuoteService.LineRequest();
        line.productId = product.Id;
        line.quantity = quantity;
        line.discountPercent = discount;
        SalesQuoteService.QuoteRequest request = new SalesQuoteService.QuoteRequest();
        request.opportunityId = SalesLabTestFactory.opportunity().Id;
        request.termMonths = 12;
        request.lines = new List<SalesQuoteService.LineRequest>{ line };
        return request;
    }

    @IsTest
    static void getContext_andCatalog_exposePriceBookAndPolicyCaps() {
        SalesQuoteConfiguratorController.ContextInfo info;
        List<SalesQuoteConfiguratorController.CatalogItem> catalog;
        System.runAs(rep()) {
            info = SalesQuoteConfiguratorController.getContext(SalesLabTestFactory.opportunity().Id);
            catalog = SalesQuoteConfiguratorController.getCatalog(info.pricebookId);
        }

        Assert.areEqual(Test.getStandardPricebookId(), info.pricebookId);
        Assert.areEqual('Northwind Demo Traders (fictional)', info.accountName);
        Assert.areEqual(3, catalog.size(), 'The unpriced product is not offered');
        for (SalesQuoteConfiguratorController.CatalogItem item : catalog) {
            if (item.productCode == 'RL-EDGE') {
                Assert.areEqual(15, item.maxDiscountPercent);
            }
        }
    }

    @IsTest
    static void previewSaveAndSubmit_throughTheControllers() {
        SalesLabTestFactory.installRouting();
        Product2 software = SalesLabTestFactory.catalog().software;
        SalesQuoteService.QuotePreview preview;
        SalesQuoteApprovalService.SubmissionResult result;
        Id quoteId;
        System.runAs(rep()) {
            preview = SalesQuoteConfiguratorController.previewQuote(request(software, 2, 12));
            quoteId = SalesQuoteConfiguratorController.saveQuote(request(software, 2, 12));
            result = SalesQuoteConfiguratorController.submitQuote(quoteId);
        }

        Assert.isTrue(preview.approval.approvalRequired);
        Assert.areEqual(1, result.tier);
        Assert.areEqual('Pending Approval', result.status);
    }

    @IsTest
    static void approvalSummary_showsAmountsThresholdApproverAndActions() {
        SalesLabTestFactory.installRouting();
        Id quoteId;
        System.runAs(rep()) {
            quoteId = SalesQuoteConfiguratorController.saveQuote(
                request(SalesLabTestFactory.catalog().software, 2, 25)
            );
            SalesQuoteConfiguratorController.submitQuote(quoteId);
        }

        SalesApprovalController.ApprovalSummary asRep;
        System.runAs(rep()) {
            asRep = SalesApprovalController.getApprovalSummaryFresh(quoteId);
        }
        SalesApprovalController.ApprovalSummary asFinance;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.FINANCE)) {
            asFinance = SalesApprovalController.getApprovalSummary(quoteId);
        }

        Assert.areEqual(1500, asRep.netAmount);
        Assert.areEqual(25, asRep.requestedDiscountPercent);
        Assert.areEqual(20, asRep.thresholdPercent);
        Assert.areEqual('Pending', asRep.approvalStatus);
        Assert.isTrue(asRep.approverName.contains('rlfin'));
        Assert.isTrue(asRep.canRecall);
        Assert.isFalse(asRep.canDecide);
        Assert.isTrue(asFinance.canDecide, 'Finance sees the quote through the sharing rule and is the approver');
        Assert.isFalse(asFinance.canRecall);
    }

    @IsTest
    static void decideAndConvert_throughTheApprovalController() {
        SalesLabTestFactory.installRouting();
        Id quoteId;
        System.runAs(rep()) {
            quoteId = SalesQuoteConfiguratorController.saveQuote(
                request(SalesLabTestFactory.catalog().software, 2, 15)
            );
            SalesQuoteConfiguratorController.submitQuote(quoteId);
        }
        Id requestId = [SELECT Id FROM Sales_Approval_Request__c WHERE Quote_Configuration__c = :quoteId].Id;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.MANAGER)) {
            SalesApprovalController.decide(requestId, true, 'Approved.');
        }

        Id orderId;
        System.runAs(rep()) {
            orderId = SalesApprovalController.convertToOrder(quoteId, 'PO-77');
        }

        Assert.isNotNull(orderId);
        Assert.areEqual('Ordered', SalesLabTestFactory.requery(quoteId).Status__c);
    }

    @IsTest
    static void errors_areTranslatedWithoutLeakingInternals() {
        System.runAs(rep()) {
            try {
                SalesApprovalController.convertToOrder(SalesLabTestFactory.opportunity().Id, 'PO-1');
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not found'), e.getMessage());
            }
        }
        AuraHandledException unexpected = SalesAuraErrors.wrap(new NullPointerException());
        Assert.isTrue(unexpected.getMessage().contains('reference'), unexpected.getMessage());
        Assert.isFalse(unexpected.getMessage().contains('NullPointer'));
    }
}
