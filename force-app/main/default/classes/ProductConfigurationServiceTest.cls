@IsTest
private class ProductConfigurationServiceTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
    }

    private static Map<String, Product2> products() {
        Map<String, Product2> byCode = new Map<String, Product2>();
        for (Product2 p : [SELECT Id, Name, ProductCode FROM Product2]) {
            byCode.put(p.ProductCode, p);
        }
        return byCode;
    }

    private static ProductConfigurationService.OptionSelection pick(Product2 product, Decimal quantity) {
        ProductConfigurationService.OptionSelection selection = new ProductConfigurationService.OptionSelection();
        selection.optionProductId = product.Id;
        selection.quantity = quantity;
        return selection;
    }

    @IsTest
    static void getBundleOptions_returnsOrderedActiveOptionsWithRules() {
        Map<String, Product2> p = products();

        List<ProductConfigurationService.BundleOption> options = ProductConfigurationService.getBundleOptions(
            p.get('QF-PLATFORM-ENT').Id
        );

        Assert.areEqual(7, options.size());
        Assert.areEqual('QF-USER-SEAT', options[0].productCode, 'Ordered by Sort_Order__c');
        Assert.isTrue(options[0].isRequired);
        Assert.areEqual(5, options[0].minQuantity, 'Required option has a floor of its configured minimum');
        Assert.isTrue(options[5].isIncluded, 'Security pack is included in the bundle price');
    }

    @IsTest
    static void validate_validSelection_returnsNormalisedSelections() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>{
                pick(p.get('QF-USER-SEAT'), 25),
                pick(p.get('QF-DATA-CONNECTOR'), 1),
                pick(p.get('QF-ANALYTICS-PRO'), 1)
            }
        );

        Assert.isTrue(result.isValid, String.join(result.errors, '; '));
        Assert.areEqual(3, result.selections.size());
        Assert.isTrue(result.warnings.isEmpty());
    }

    @IsTest
    static void validate_missingRequiredOption_isAddedWithWarning() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>()
        );

        Assert.isTrue(result.isValid);
        Assert.areEqual(1, result.selections.size());
        Assert.areEqual(p.get('QF-USER-SEAT').Id, result.selections[0].optionProductId);
        Assert.areEqual(5, result.selections[0].quantity, 'Default quantity applied');
        Assert.areEqual(1, result.warnings.size());
    }

    @IsTest
    static void validate_quantityOutsideBounds_reportsEveryProblem() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>{
                pick(p.get('QF-USER-SEAT'), 2),
                pick(p.get('QF-SSO'), 3)
            }
        );

        Assert.isTrue(!result.isValid);
        Assert.areEqual(2, result.errors.size(), String.join(result.errors, '; '));
        Assert.isTrue(result.errors[0].contains('minimum quantity of 5'));
        Assert.isTrue(result.errors[1].contains('maximum quantity of 1'));
    }

    @IsTest
    static void validate_optionOfAnotherBundle_isRejected() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-IMPL-HOURLY'), 10) }
        );

        Assert.isTrue(!result.isValid);
        Assert.isTrue(result.errors[0].contains('not part of'));
    }

    @IsTest
    static void validate_requiresRule_failsWhenTargetMissing() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-ANALYTICS-PRO'), 1) }
        );

        Assert.isTrue(!result.isValid);
        Assert.isTrue(result.errors.contains('Analytics Pro requires the Data Connector option.'));
    }

    @IsTest
    static void validate_excludesRule_failsWhenBothSelected() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            p.get('QF-PLATFORM-ENT').Id,
            new List<ProductConfigurationService.OptionSelection>{
                pick(p.get('QF-SUPPORT-STD'), 1),
                pick(p.get('QF-SUPPORT-PREMIUM'), 1)
            }
        );

        Assert.isTrue(!result.isValid);
        Assert.isTrue(result.errors.contains('Premium and Standard support cannot be combined.'));
    }

    @IsTest
    static void validate_nonBundleProduct_isRejected() {
        TestDataFactory.installPolicy();

        ProductConfigurationService.ConfigurationResult result = ProductConfigurationService.validate(
            products().get('QF-USER-SEAT').Id,
            new List<ProductConfigurationService.OptionSelection>()
        );

        Assert.isTrue(!result.isValid);
        Assert.areEqual('The selected product is not a configurable bundle.', result.errors[0]);
    }

    @IsTest
    static void buildLines_expandsBundleIntoHeaderAndComponents() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        Test.startTest();
        ProductConfigurationService.BundleLines lines = ProductConfigurationService.buildLines(
            null,
            p.get('QF-PLATFORM-ENT').Id,
            2,
            5,
            new List<ProductConfigurationService.OptionSelection>{
                pick(p.get('QF-USER-SEAT'), 10),
                pick(p.get('QF-SECURITY-PACK'), 1)
            }
        );
        Test.stopTest();

        Assert.areEqual(2, lines.header.Quantity__c);
        Assert.areEqual(5, lines.header.Manual_Discount_Pct__c);
        Assert.areEqual(2, lines.components.size());
        for (Quote_Line__c component : lines.components) {
            Assert.isTrue(component.Is_Bundle_Component__c);
            if (component.Product__c == p.get('QF-SECURITY-PACK').Id) {
                Assert.isTrue(component.Is_Included__c, 'Included option');
                Assert.areEqual(0, component.Manual_Discount_Pct__c, 'Included components never carry a discount');
                Assert.areEqual(2, component.Quantity__c, 'Component quantity scales with bundle quantity');
            } else {
                Assert.areEqual(20, component.Quantity__c, '10 seats per bundle x 2 bundles');
                Assert.areEqual(5, component.Manual_Discount_Pct__c);
            }
        }
    }

    @IsTest
    static void buildLines_invalidConfiguration_throws() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();

        try {
            ProductConfigurationService.buildLines(
                null,
                p.get('QF-PLATFORM-ENT').Id,
                1,
                0,
                new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-ANALYTICS-PRO'), 1) }
            );
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('Configuration is invalid'), e.getMessage());
        }
    }

    // ------------------------------------------------------------------ added in the principal review

    @IsTest
    static void configureAll_manyBundles_usesConstantQueries() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        List<ProductConfigurationService.BundleRequest> one = new List<ProductConfigurationService.BundleRequest>();
        List<ProductConfigurationService.BundleRequest> twenty = new List<ProductConfigurationService.BundleRequest>();
        for (Integer i = 0; i < 20; i++) {
            ProductConfigurationService.BundleRequest request = new ProductConfigurationService.BundleRequest(
                p.get('QF-PLATFORM-ENT').Id,
                1,
                0,
                new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-USER-SEAT'), 10) }
            );
            if (i == 0) {
                one.add(request);
            }
            twenty.add(request);
        }

        Test.startTest();
        Integer before = Limits.getQueries();
        ProductConfigurationService.configureAll(null, one);
        Integer forOne = Limits.getQueries() - before;
        before = Limits.getQueries();
        List<ProductConfigurationService.BundleConfiguration> results = ProductConfigurationService.configureAll(
            null,
            twenty
        );
        Integer forTwenty = Limits.getQueries() - before;
        Test.stopTest();

        Assert.areEqual(forOne, forTwenty, 'Query cost must not grow with the number of bundles');
        Assert.isTrue(forTwenty <= 2, 'Products + options; used ' + forTwenty);
        Assert.areEqual(20, results.size());
        for (ProductConfigurationService.BundleConfiguration configuration : results) {
            Assert.isTrue(configuration.result.isValid, String.join(configuration.result.errors, '; '));
            Assert.areEqual(1, configuration.lines.components.size());
        }
    }

    @IsTest
    static void configureAll_reportsEachBundleIndependently() {
        TestDataFactory.installPolicy();
        Map<String, Product2> p = products();
        ProductConfigurationService.BundleRequest valid = new ProductConfigurationService.BundleRequest(
            p.get('QF-PLATFORM-ENT').Id,
            1,
            0,
            new List<ProductConfigurationService.OptionSelection>()
        );
        ProductConfigurationService.BundleRequest invalid = new ProductConfigurationService.BundleRequest(
            p.get('QF-PLATFORM-ENT').Id,
            1,
            0,
            new List<ProductConfigurationService.OptionSelection>{ pick(p.get('QF-ANALYTICS-PRO'), 1) }
        );
        ProductConfigurationService.BundleRequest notABundle = new ProductConfigurationService.BundleRequest(
            p.get('QF-USER-SEAT').Id,
            1,
            0,
            null
        );

        List<ProductConfigurationService.BundleConfiguration> results = ProductConfigurationService.configureAll(
            null,
            new List<ProductConfigurationService.BundleRequest>{ valid, invalid, notABundle }
        );

        Assert.isTrue(results[0].result.isValid);
        Assert.areNotEqual(null, results[0].lines);
        Assert.isFalse(results[1].result.isValid);
        Assert.areEqual(null, results[1].lines, 'Invalid bundles are never expanded');
        Assert.isFalse(results[2].result.isValid);
    }
}
