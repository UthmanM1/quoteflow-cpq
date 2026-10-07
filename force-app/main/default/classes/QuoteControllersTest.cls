@IsTest
private class QuoteControllersTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        TestDataFactory.account('Adventure Works', 'ERP-A-1');
    }

    private static Map<String, Product2> products() {
        Map<String, Product2> byCode = new Map<String, Product2>();
        for (Product2 p : [SELECT Id, ProductCode FROM Product2]) {
            byCode.put(p.ProductCode, p);
        }
        return byCode;
    }

    private static QuoteConfiguratorController.DraftRequest draft(
        Id accountId,
        List<QuoteConfiguratorController.DraftLine> lines
    ) {
        QuoteConfiguratorController.DraftRequest request = new QuoteConfiguratorController.DraftRequest();
        request.accountId = accountId;
        request.pricebookId = Test.getStandardPricebookId();
        request.termMonths = 12;
        request.lines = lines;
        return request;
    }

    private static QuoteConfiguratorController.DraftLine draftLine(
        Product2 product,
        Decimal quantity,
        Decimal discount
    ) {
        QuoteConfiguratorController.DraftLine line = new QuoteConfiguratorController.DraftLine();
        line.productId = product.Id;
        line.quantity = quantity;
        line.manualDiscountPct = discount;
        return line;
    }

    private static ProductConfigurationService.OptionSelection pick(Product2 product, Decimal quantity) {
        ProductConfigurationService.OptionSelection selection = new ProductConfigurationService.OptionSelection();
        selection.optionProductId = product.Id;
        selection.quantity = quantity;
        return selection;
    }

    @IsTest
    static void getContext_returnsOpportunityAccountAndPricebooks() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        Opportunity opportunity = TestDataFactory.opportunity(account.Id);

        QuoteConfiguratorController.ContextInfo info = QuoteConfiguratorController.getContext(opportunity.Id);

        Assert.areEqual(account.Id, info.accountId);
        Assert.areEqual(Test.getStandardPricebookId(), info.defaultPricebookId);
        Assert.isTrue(!info.pricebooks.isEmpty());
    }

    @IsTest
    static void getCatalog_excludesOptionProducts() {
        List<QuoteConfiguratorController.CatalogItem> items = QuoteConfiguratorController.getCatalog(
            Test.getStandardPricebookId()
        );

        Set<String> codes = new Set<String>();
        for (QuoteConfiguratorController.CatalogItem item : items) {
            codes.add(item.productCode);
        }
        Assert.isTrue(codes.contains('QF-PLATFORM-ENT'));
        Assert.isTrue(codes.contains('QF-USER-SEAT'));
        Assert.isTrue(!codes.contains('QF-SSO'), 'Options are only reachable through their bundle');
    }

    @IsTest
    static void preview_standaloneAndBundle_returnsPricedLinesAndApprovalHint() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        QuoteConfiguratorController.DraftLine bundle = draftLine(p.get('QF-PLATFORM-ENT'), 1, 0);
        bundle.options = new List<ProductConfigurationService.OptionSelection>{
            pick(p.get('QF-USER-SEAT'), 10),
            pick(p.get('QF-SECURITY-PACK'), 1)
        };
        QuoteConfiguratorController.DraftRequest request = draft(
            [SELECT Id FROM Account LIMIT 1].Id,
            new List<QuoteConfiguratorController.DraftLine>{ bundle, draftLine(p.get('QF-IMPL-HOURLY'), 10, 25) }
        );

        Test.startTest();
        QuoteConfiguratorController.PreviewResponse response = QuoteConfiguratorController.previewPricing(request);
        Test.stopTest();

        Assert.isTrue(response.isValid, String.join(response.errors, '; '));
        Assert.areEqual(4, response.lines.size(), 'Bundle header, two components, one service line');
        Assert.areEqual(25, response.maxLineDiscountPct);
        Assert.isTrue(response.approvalRequired);
        Assert.areEqual(2, response.approvalLevel);
        // 10,000 bundle + 10 seats x 120 x 0.95 (5% tier) + security pack included + 2,000 x 0.75 services
        Assert.areEqual(12640, response.netAmount);
    }

    @IsTest
    static void preview_invalidConfiguration_reportsErrorsWithoutThrowing() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        QuoteConfiguratorController.DraftLine bundle = draftLine(p.get('QF-PLATFORM-ENT'), 1, 0);
        bundle.options = new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-ANALYTICS-PRO'), 1) };

        QuoteConfiguratorController.PreviewResponse response = QuoteConfiguratorController.previewPricing(
            draft([SELECT Id FROM Account LIMIT 1].Id, new List<QuoteConfiguratorController.DraftLine>{ bundle })
        );

        Assert.isTrue(!response.isValid);
        Assert.isTrue(String.join(response.errors, ' ').contains('requires the Data Connector'));
    }

    @IsTest
    static void saveQuote_createsQuoteWithBundleHierarchyAndLinksOpportunity() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        Account account = [SELECT Id FROM Account LIMIT 1];
        Opportunity opportunity = TestDataFactory.opportunity(account.Id);
        QuoteConfiguratorController.DraftLine bundle = draftLine(p.get('QF-PLATFORM-ENT'), 1, 0);
        bundle.options = new List<ProductConfigurationService.OptionSelection>{
            pick(p.get('QF-USER-SEAT'), 5),
            pick(p.get('QF-SECURITY-PACK'), 1)
        };
        QuoteConfiguratorController.DraftRequest request = draft(
            account.Id,
            new List<QuoteConfiguratorController.DraftLine>{ bundle }
        );
        request.opportunityId = opportunity.Id;

        Test.startTest();
        Id quoteId = QuoteConfiguratorController.saveQuote(request);
        Test.stopTest();

        List<Quote_Line__c> lines = [
            SELECT Parent_Line__c, Is_Bundle_Component__c, Net_Total__c
            FROM Quote_Line__c
            WHERE Quote__c = :quoteId
        ];
        Assert.areEqual(3, lines.size());
        Integer children = 0;
        for (Quote_Line__c line : lines) {
            if (line.Is_Bundle_Component__c) {
                Assert.areNotEqual(null, line.Parent_Line__c);
                children++;
            }
        }
        Assert.areEqual(2, children);
        Assert.areEqual(10600, TestDataFactory.requery(quoteId).Net_Amount__c, '10,000 bundle + 5 x 120');
        Assert.areEqual(
            quoteId,
            [SELECT Primary_Quote__c FROM Opportunity WHERE Id = :opportunity.Id].Primary_Quote__c
        );
    }

    @IsTest
    static void saveQuote_invalidDraft_rollsBackAndReturnsReadableError() {
        Map<String, Product2> p = products();
        Integer quotesBefore = [SELECT COUNT() FROM Quote__c];
        QuoteConfiguratorController.DraftRequest request = draft(
            [SELECT Id FROM Account LIMIT 1].Id,
            new List<QuoteConfiguratorController.DraftLine>{ draftLine(p.get('QF-USER-SEAT'), 0, 0) }
        );

        try {
            QuoteConfiguratorController.saveQuote(request);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Quantity must be greater than zero'), e.getMessage());
        }

        Assert.areEqual(quotesBefore, [SELECT COUNT() FROM Quote__c], 'Nothing partially saved');
    }

    @IsTest
    static void approvalSummary_reflectsLifecycleAndPermissions() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        Account account = [SELECT Id FROM Account LIMIT 1];
        TestDataFactory.Catalog catalog = new TestDataFactory.Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        catalog.seat = p.get('QF-USER-SEAT');
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account.Id, 5, 0);

        QuoteApprovalController.ApprovalSummary summary = QuoteApprovalController.getApprovalSummary(quote.Id);

        Assert.areEqual('Draft', summary.status);
        Assert.isTrue(summary.canSubmit);
        Assert.isTrue(!summary.canDecide);
        Assert.areEqual(3, summary.levels.size());
        Assert.areEqual(10, summary.levels[0].thresholdPct);
    }

    @IsTest
    static void controllerErrors_doNotLeakInternalDetail() {
        try {
            QuoteApprovalController.getApprovalSummary(UserInfo.getUserId());
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(!e.getMessage().contains('SELECT'), 'No query text in client messages');
            Assert.areNotEqual(null, e.getMessage());
        }
    }

    // ------------------------------------------------------------------ added in the principal review

    @IsTest
    static void getContext_exposesServerPolicyToTheClient() {
        QuoteConfiguratorController.ContextInfo info = QuoteConfiguratorController.getContext(null);

        Assert.areEqual(QuoteCalculationService.MAX_MANUAL_DISCOUNT_PCT, info.maxManualDiscountPct);
        Assert.areEqual(QuoteCalculationService.MAX_TERM_MONTHS, info.maxTermMonths);
        Assert.areEqual(UserInfo.getDefaultCurrency(), info.currencyIsoCode);
    }

    @IsTest
    static void saveQuote_manyBundles_noLongerLimitedByGovernorWorkaround() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        List<QuoteConfiguratorController.DraftLine> lines = new List<QuoteConfiguratorController.DraftLine>();
        for (Integer i = 0; i < 8; i++) {
            QuoteConfiguratorController.DraftLine bundle = draftLine(p.get('QF-PLATFORM-ENT'), 1, 0);
            bundle.options = new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-USER-SEAT'), 5) };
            lines.add(bundle);
        }

        Test.startTest();
        Id quoteId = QuoteConfiguratorController.saveQuote(draft([SELECT Id FROM Account LIMIT 1].Id, lines));
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(
            16,
            [SELECT COUNT() FROM Quote_Line__c WHERE Quote__c = :quoteId],
            '8 headers + 8 seat components'
        );
        Assert.isTrue(queries < 40, 'Bundle validation is bulk; used ' + queries + ' queries for 8 bundles');
    }

    @IsTest
    static void approvalSummaryFresh_reflectsStateImmediatelyAfterSubmit() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        TestDataFactory.Catalog catalog = new TestDataFactory.Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        catalog.seat = p.get('QF-USER-SEAT');
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, [SELECT Id FROM Account LIMIT 1].Id, 5, 0);

        QuoteApprovalController.submitForApproval(quote.Id);
        QuoteApprovalController.ApprovalSummary summary = QuoteApprovalController.getApprovalSummaryFresh(quote.Id);

        Assert.areEqual('Approved', summary.status, 'Within policy, so approved on submit');
        Assert.isTrue(summary.canConvert);
        Assert.areEqual(QuoteApprovalService.MIN_REJECTION_COMMENT_LENGTH, summary.minRejectionCommentLength);
    }

    @IsTest
    static void unexpectedError_isLoggedWithTheReferenceShownToTheUser() {
        AuraHandledException wrapped = AuraErrorFactory.wrap(new NullPointerException());

        Assert.areEqual(1, Logger.PUBLISHED.size());
        String reference = Logger.PUBLISHED[0].Reference__c;
        Assert.isTrue(
            wrapped.getMessage().contains(reference),
            'The support reference must be findable on Application_Log__c'
        );
    }
}
