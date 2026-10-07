/**
 * Bundle configuration: which options exist, what a valid selection looks like, and how a validated
 * selection expands into quote lines.
 *
 * Structural data (options, quantities, included vs additive) lives on Product_Option__c.
 * Cross-option constraints ("Analytics requires Data Connector") live in Configuration_Rule__mdt.
 * Validation is always re-run on save; the configurator UI is a convenience, never the control.
 *
 * Bulk contract: configureAll() validates and expands any number of bundles with exactly two queries (bundle
 * products and their options), independent of how many bundles or options are in the request. The single-bundle
 * methods delegate to it, so there is one code path.
 */
public with sharing class ProductConfigurationService {
    private static final String RULE_REQUIRES = 'Requires';
    private static final String RULE_EXCLUDES = 'Excludes';

    public class OptionSelection {
        @AuraEnabled
        public Id optionProductId;
        @AuraEnabled
        public Decimal quantity;
    }

    public class BundleOption {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public String productCode;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Boolean isRequired;
        @AuraEnabled
        public Boolean isIncluded;
        @AuraEnabled
        public Decimal defaultQuantity;
        @AuraEnabled
        public Decimal minQuantity;
        @AuraEnabled
        public Decimal maxQuantity;
    }

    public class ConfigurationResult {
        @AuraEnabled
        public Boolean isValid = true;
        @AuraEnabled
        public List<String> errors = new List<String>();
        @AuraEnabled
        public List<String> warnings = new List<String>();
        /** Selections after defaults for required options have been applied. */
        @AuraEnabled
        public List<OptionSelection> selections = new List<OptionSelection>();
    }

    /** Header plus component lines for one configured bundle. Components reference the header after it is inserted. */
    public class BundleLines {
        public Quote_Line__c header;
        public List<Quote_Line__c> components = new List<Quote_Line__c>();
    }

    /** One bundle to configure. */
    public class BundleRequest {
        public Id bundleProductId;
        public Decimal quantity;
        public Decimal manualDiscountPct;
        public List<OptionSelection> selections;

        public BundleRequest(
            Id bundleProductId,
            Decimal quantity,
            Decimal manualDiscountPct,
            List<OptionSelection> selections
        ) {
            this.bundleProductId = bundleProductId;
            this.quantity = quantity;
            this.manualDiscountPct = manualDiscountPct;
            this.selections = selections;
        }
    }

    /** Validation result plus, when valid, the unsaved lines. Index-aligned with the requests. */
    public class BundleConfiguration {
        public ConfigurationResult result;
        public BundleLines lines;
    }

    @TestVisible
    private static List<Configuration_Rule__mdt> rulesOverride;

    /** Bundle definitions loaded once per call. */
    private class Definitions {
        Map<Id, Product2> products = new Map<Id, Product2>();
        Map<Id, Map<Id, Product_Option__c>> optionsByBundle = new Map<Id, Map<Id, Product_Option__c>>();
    }

    // ------------------------------------------------------------------ reads

    public static List<BundleOption> getBundleOptions(Id bundleProductId) {
        List<BundleOption> result = new List<BundleOption>();
        if (bundleProductId == null) {
            return result;
        }
        for (Product_Option__c option : QuoteSelector.activeOptionsForBundles(new Set<Id>{ bundleProductId })) {
            if (option.Option_Product__r.IsActive != true) {
                continue;
            }
            BundleOption dto = new BundleOption();
            dto.productId = option.Option_Product__c;
            dto.productCode = option.Option_Product__r.ProductCode;
            dto.name = option.Option_Product__r.Name;
            dto.isRequired = option.Is_Required__c == true;
            dto.isIncluded = option.Price_Treatment__c == QuoteConstants.PRICE_TREATMENT_INCLUDED;
            dto.defaultQuantity = nz(option.Default_Quantity__c, 1);
            dto.minQuantity = option.Is_Required__c == true
                ? Math.max(nz(option.Min_Quantity__c, 1), 1)
                : nz(option.Min_Quantity__c, 0);
            dto.maxQuantity = option.Max_Quantity__c;
            result.add(dto);
        }
        return result;
    }

    // ------------------------------------------------------------------ bulk entry point

    /**
     * Validates every request and expands the valid ones into unsaved lines. Never throws for user mistakes;
     * each problem is returned on its own result so the caller can show all of them in one pass.
     */
    public static List<BundleConfiguration> configureAll(Id quoteId, List<BundleRequest> requests) {
        List<BundleConfiguration> configurations = new List<BundleConfiguration>();
        if (requests == null || requests.isEmpty()) {
            return configurations;
        }
        Definitions definitions = loadDefinitions(requests);
        List<Configuration_Rule__mdt> activeRules = activeRules();
        for (BundleRequest request : requests) {
            BundleConfiguration configuration = new BundleConfiguration();
            configuration.result = validateOne(request, definitions, activeRules);
            if (configuration.result.isValid) {
                configuration.lines = expand(quoteId, request, configuration.result, definitions);
            }
            configurations.add(configuration);
        }
        return configurations;
    }

    // ------------------------------------------------------------------ single-bundle convenience API

    public static ConfigurationResult validate(Id bundleProductId, List<OptionSelection> selections) {
        return configureAll(null, new List<BundleRequest>{ new BundleRequest(bundleProductId, 1, 0, selections) })[0]
            .result;
    }

    /**
     * Expands a VALID selection into unsaved lines. Re-validates and throws so that a skipped validation
     * cannot produce an invalid quote.
     */
    public static BundleLines buildLines(
        Id quoteId,
        Id bundleProductId,
        Decimal bundleQuantity,
        Decimal manualDiscountPct,
        List<OptionSelection> selections
    ) {
        BundleConfiguration configuration = configureAll(
            quoteId,
            new List<BundleRequest>{ new BundleRequest(bundleProductId, bundleQuantity, manualDiscountPct, selections) }
        )[0];
        if (!configuration.result.isValid) {
            throw new QuoteFlowException('Configuration is invalid: ' + String.join(configuration.result.errors, ' '));
        }
        return configuration.lines;
    }

    // ------------------------------------------------------------------ internals

    /** Two queries in total, whatever the number of bundles. */
    private static Definitions loadDefinitions(List<BundleRequest> requests) {
        Set<Id> bundleIds = new Set<Id>();
        for (BundleRequest request : requests) {
            if (request != null && request.bundleProductId != null) {
                bundleIds.add(request.bundleProductId);
            }
        }
        Definitions definitions = new Definitions();
        definitions.products = QuoteSelector.productsById(bundleIds);
        for (Product_Option__c option : QuoteSelector.activeOptionsForBundles(bundleIds)) {
            if (!definitions.optionsByBundle.containsKey(option.Bundle_Product__c)) {
                definitions.optionsByBundle.put(option.Bundle_Product__c, new Map<Id, Product_Option__c>());
            }
            definitions.optionsByBundle.get(option.Bundle_Product__c).put(option.Option_Product__c, option);
        }
        return definitions;
    }

    private static ConfigurationResult validateOne(
        BundleRequest request,
        Definitions definitions,
        List<Configuration_Rule__mdt> activeRules
    ) {
        ConfigurationResult result = new ConfigurationResult();
        Product2 bundle = request == null ? null : definitions.products.get(request.bundleProductId);
        if (bundle == null || bundle.Product_Type__c != QuoteConstants.PRODUCT_TYPE_BUNDLE) {
            return fail(result, 'The selected product is not a configurable bundle.');
        }
        Map<Id, Product_Option__c> optionsByProduct = definitions.optionsByBundle.containsKey(bundle.Id)
            ? definitions.optionsByBundle.get(bundle.Id)
            : new Map<Id, Product_Option__c>();

        Map<Id, Decimal> quantityByOption = new Map<Id, Decimal>();
        List<OptionSelection> selections = request.selections == null
            ? new List<OptionSelection>()
            : request.selections;
        for (OptionSelection selection : selections) {
            if (selection == null || selection.optionProductId == null || nz(selection.quantity, 0) <= 0) {
                continue;
            }
            Product_Option__c option = optionsByProduct.get(selection.optionProductId);
            if (option == null) {
                fail(result, 'An option was selected that is not part of ' + bundle.Name + '.');
                continue;
            }
            Decimal qty = selection.quantity;
            String label = option.Option_Product__r.Name;
            if (option.Min_Quantity__c != null && qty < option.Min_Quantity__c) {
                fail(result, label + ' requires a minimum quantity of ' + option.Min_Quantity__c + '.');
            }
            if (option.Max_Quantity__c != null && qty > option.Max_Quantity__c) {
                fail(result, label + ' allows a maximum quantity of ' + option.Max_Quantity__c + '.');
            }
            quantityByOption.put(selection.optionProductId, qty);
        }

        for (Product_Option__c option : optionsByProduct.values()) {
            if (option.Is_Required__c == true && !quantityByOption.containsKey(option.Option_Product__c)) {
                quantityByOption.put(option.Option_Product__c, nz(option.Default_Quantity__c, 1));
                result.warnings.add(option.Option_Product__r.Name + ' is required and was added automatically.');
            }
        }

        applyRules(bundle, optionsByProduct, quantityByOption, activeRules, result);

        for (Id optionId : quantityByOption.keySet()) {
            OptionSelection normalised = new OptionSelection();
            normalised.optionProductId = optionId;
            normalised.quantity = quantityByOption.get(optionId);
            result.selections.add(normalised);
        }
        return result;
    }

    private static BundleLines expand(
        Id quoteId,
        BundleRequest request,
        ConfigurationResult result,
        Definitions definitions
    ) {
        Map<Id, Product_Option__c> optionsByProduct = definitions.optionsByBundle.get(request.bundleProductId);
        BundleLines lines = new BundleLines();
        lines.header = new Quote_Line__c(
            Quote__c = quoteId,
            Product__c = request.bundleProductId,
            Quantity__c = request.quantity,
            Manual_Discount_Pct__c = request.manualDiscountPct,
            Is_Bundle_Component__c = false
        );
        for (OptionSelection selection : result.selections) {
            Product_Option__c option = optionsByProduct.get(selection.optionProductId);
            Boolean included = option.Price_Treatment__c == QuoteConstants.PRICE_TREATMENT_INCLUDED;
            lines.components.add(
                new Quote_Line__c(
                    Quote__c = quoteId,
                    Product__c = selection.optionProductId,
                    // A null bundle quantity is left for the pricing engine to reject with a clear message.
                    Quantity__c = request.quantity == null ? null : selection.quantity * request.quantity,
                    Manual_Discount_Pct__c = included ? 0 : request.manualDiscountPct,
                    Is_Bundle_Component__c = true,
                    Is_Included__c = included
                )
            );
        }
        return lines;
    }

    private static void applyRules(
        Product2 bundle,
        Map<Id, Product_Option__c> optionsByProduct,
        Map<Id, Decimal> quantityByOption,
        List<Configuration_Rule__mdt> activeRules,
        ConfigurationResult result
    ) {
        Map<String, Id> productIdBySku = new Map<String, Id>();
        for (Product_Option__c option : optionsByProduct.values()) {
            productIdBySku.put(option.Option_Product__r.ProductCode, option.Option_Product__c);
        }
        for (Configuration_Rule__mdt rule : activeRules) {
            if (rule.Bundle_SKU__c != bundle.ProductCode) {
                continue;
            }
            Id sourceId = productIdBySku.get(rule.Source_SKU__c);
            Id targetId = productIdBySku.get(rule.Target_SKU__c);
            Boolean sourceSelected = sourceId != null && quantityByOption.containsKey(sourceId);
            Boolean targetSelected = targetId != null && quantityByOption.containsKey(targetId);
            if (rule.Rule_Type__c == RULE_REQUIRES && sourceSelected && !targetSelected) {
                fail(result, rule.Message__c);
            } else if (rule.Rule_Type__c == RULE_EXCLUDES && sourceSelected && targetSelected) {
                fail(result, rule.Message__c);
            }
        }
    }

    private static List<Configuration_Rule__mdt> activeRules() {
        List<Configuration_Rule__mdt> active = new List<Configuration_Rule__mdt>();
        for (
            Configuration_Rule__mdt rule : rulesOverride != null
                ? rulesOverride
                : Configuration_Rule__mdt.getAll().values()
        ) {
            if (rule.Is_Active__c == true) {
                active.add(rule);
            }
        }
        return active;
    }

    private static ConfigurationResult fail(ConfigurationResult result, String message) {
        result.isValid = false;
        result.errors.add(message);
        return result;
    }

    private static Decimal nz(Decimal value, Decimal fallback) {
        return value == null ? fallback : value;
    }
}
