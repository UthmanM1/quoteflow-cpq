/**
 * Server side of the quoteConfigurator LWC. Thin by design: it shapes DTOs and delegates all pricing,
 * configuration and approval rules to the services. The preview is advisory; saveQuote re-validates and
 * re-prices on the server, and the Quote_Line__c trigger prices again on insert.
 */
public with sharing class QuoteConfiguratorController {
    /** Business limit on configured lines per quote (a bundle counts once, however many options it expands to). */
    @TestVisible
    private static final Integer MAX_DRAFT_LINES = 25;

    // ------------------------------------------------------------------ DTOs

    public class ContextInfo {
        @AuraEnabled
        public Id opportunityId;
        @AuraEnabled
        public String opportunityName;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public Id defaultPricebookId;
        @AuraEnabled
        public List<PricebookInfo> pricebooks = new List<PricebookInfo>();
        /** Server-owned policy the client mirrors for instant feedback, so the two cannot drift. */
        @AuraEnabled
        public Decimal maxManualDiscountPct = QuoteCalculationService.MAX_MANUAL_DISCOUNT_PCT;
        @AuraEnabled
        public Integer maxTermMonths = QuoteCalculationService.MAX_TERM_MONTHS;
        @AuraEnabled
        public String currencyIsoCode = UserInfo.getDefaultCurrency();
    }

    public class PricebookInfo {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
    }

    public class CatalogItem {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public String productCode;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String family;
        @AuraEnabled
        public String productType;
        @AuraEnabled
        public String billingModel;
        @AuraEnabled
        public Decimal listPrice;
    }

    public class DraftLine {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal manualDiscountPct;
        @AuraEnabled
        public List<ProductConfigurationService.OptionSelection> options;
    }

    public class DraftRequest {
        @AuraEnabled
        public Id opportunityId;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public Id pricebookId;
        @AuraEnabled
        public Integer termMonths;
        @AuraEnabled
        public List<DraftLine> lines;
    }

    public class PricedLine {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal listUnitPrice;
        @AuraEnabled
        public Decimal baseUnitPrice;
        @AuraEnabled
        public Decimal scheduleDiscountPct;
        @AuraEnabled
        public Decimal manualDiscountPct;
        @AuraEnabled
        public Decimal effectiveDiscountPct;
        @AuraEnabled
        public Decimal netUnitPrice;
        @AuraEnabled
        public Decimal listTotal;
        @AuraEnabled
        public Decimal netTotal;
        @AuraEnabled
        public String pricingSource;
        @AuraEnabled
        public Boolean isComponent;
        @AuraEnabled
        public Boolean isIncluded;
        @AuraEnabled
        public String error;
    }

    public class PreviewResponse {
        @AuraEnabled
        public Boolean isValid = true;
        @AuraEnabled
        public List<String> errors = new List<String>();
        @AuraEnabled
        public List<String> warnings = new List<String>();
        @AuraEnabled
        public List<PricedLine> lines = new List<PricedLine>();
        @AuraEnabled
        public Decimal listAmount = 0;
        @AuraEnabled
        public Decimal netAmount = 0;
        @AuraEnabled
        public Decimal totalDiscountAmount = 0;
        @AuraEnabled
        public Decimal blendedDiscountPct = 0;
        @AuraEnabled
        public Decimal maxLineDiscountPct = 0;
        @AuraEnabled
        public Boolean approvalRequired = false;
        @AuraEnabled
        public Integer approvalLevel = 0;
        @AuraEnabled
        public Decimal approvalThresholdPct;
    }

    /** Unsaved lines plus the index of the header each component belongs to (-1 for headers/standalone). */
    private class Expansion {
        List<Quote_Line__c> lines = new List<Quote_Line__c>();
        List<Integer> parentIndex = new List<Integer>();
        List<String> errors = new List<String>();
        List<String> warnings = new List<String>();
    }

    // ------------------------------------------------------------------ reads

    @AuraEnabled(cacheable=true)
    public static ContextInfo getContext(Id opportunityId) {
        try {
            ContextInfo info = new ContextInfo();
            Id standardPricebookId;
            for (Pricebook2 book : QuoteSelector.activePricebooks()) {
                PricebookInfo option = new PricebookInfo();
                option.id = book.Id;
                option.name = book.Name;
                info.pricebooks.add(option);
                if (book.IsStandard) {
                    standardPricebookId = book.Id;
                }
            }
            info.defaultPricebookId = standardPricebookId;
            if (opportunityId != null) {
                List<Opportunity> found = QuoteSelector.opportunitiesById(new Set<Id>{ opportunityId });
                if (!found.isEmpty()) {
                    info.opportunityId = found[0].Id;
                    info.opportunityName = found[0].Name;
                    info.accountId = found[0].AccountId;
                    info.accountName = found[0].Account.Name;
                    info.defaultPricebookId = found[0].Pricebook2Id != null
                        ? found[0].Pricebook2Id
                        : standardPricebookId;
                }
            }
            return info;
        } catch (Exception e) {
            throw AuraErrorFactory.wrapReadOnly(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CatalogItem> getCatalog(Id pricebookId) {
        try {
            List<CatalogItem> items = new List<CatalogItem>();
            if (pricebookId == null) {
                return items;
            }
            for (PricebookEntry entry : QuoteSelector.catalogueEntries(pricebookId)) {
                CatalogItem item = new CatalogItem();
                item.productId = entry.Product2Id;
                item.productCode = entry.Product2.ProductCode;
                item.name = entry.Product2.Name;
                item.family = entry.Product2.Family;
                item.productType = entry.Product2.Product_Type__c;
                item.billingModel = entry.Product2.Billing_Model__c;
                item.listPrice = entry.UnitPrice;
                items.add(item);
            }
            return items;
        } catch (Exception e) {
            throw AuraErrorFactory.wrapReadOnly(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<ProductConfigurationService.BundleOption> getBundleOptions(Id bundleProductId) {
        try {
            return ProductConfigurationService.getBundleOptions(bundleProductId);
        } catch (Exception e) {
            throw AuraErrorFactory.wrapReadOnly(e);
        }
    }

    // ------------------------------------------------------------------ preview

    @AuraEnabled
    public static PreviewResponse previewPricing(DraftRequest draft) {
        try {
            PreviewResponse response = new PreviewResponse();
            Expansion expansion = expand(draft, null);
            response.errors.addAll(expansion.errors);
            response.warnings.addAll(expansion.warnings);
            if (expansion.lines.isEmpty()) {
                response.isValid = response.errors.isEmpty();
                return response;
            }

            QuoteCalculationService.PricingContext context = pricingContext(draft);
            Map<Integer, String> lineErrors = QuoteCalculationService.priceLines(expansion.lines, context);
            Map<Id, Product2> products = QuoteSelector.productsById(productIds(expansion.lines));

            for (Integer i = 0; i < expansion.lines.size(); i++) {
                Quote_Line__c line = expansion.lines[i];
                PricedLine dto = toDto(line, products.get(line.Product__c), lineErrors.get(i));
                response.lines.add(dto);
                if (dto.error != null) {
                    response.errors.add(dto.name + ': ' + dto.error);
                }
            }

            QuoteCalculationService.QuoteTotals totals = QuoteCalculationService.summarise(expansion.lines);
            response.listAmount = totals.listAmount;
            response.netAmount = totals.netAmount;
            response.totalDiscountAmount = totals.totalDiscountAmount;
            response.blendedDiscountPct = totals.blendedDiscountPct;
            response.maxLineDiscountPct = totals.maxLineDiscountPct;
            DiscountEvaluationService.ApprovalRequirement requirement = DiscountEvaluationService.evaluate(
                totals.maxLineDiscountPct
            );
            response.approvalRequired = requirement.approvalRequired;
            response.approvalLevel = requirement.level;
            response.approvalThresholdPct = requirement.thresholdPct;
            response.isValid = response.errors.isEmpty();
            return response;
        } catch (Exception e) {
            throw AuraErrorFactory.wrap(e);
        }
    }

    // ------------------------------------------------------------------ save

    /** Creates the quote and its lines atomically. Returns the new quote Id. */
    @AuraEnabled
    public static Id saveQuote(DraftRequest draft) {
        Savepoint savepoint = Database.setSavepoint();
        try {
            Expansion expansion = expand(draft, null);
            if (!expansion.errors.isEmpty()) {
                throw new QuoteFlowException(String.join(expansion.errors, ' '));
            }
            if (expansion.lines.isEmpty()) {
                throw new QuoteFlowException('Add at least one product before saving.');
            }

            Quote__c quote = new Quote__c(
                Account__c = draft.accountId,
                Opportunity__c = draft.opportunityId,
                Pricebook__c = draft.pricebookId,
                Term_Months__c = draft.termMonths
            );
            insert as user quote;

            List<Quote_Line__c> roots = new List<Quote_Line__c>();
            for (Integer i = 0; i < expansion.lines.size(); i++) {
                expansion.lines[i].Quote__c = quote.Id;
                if (expansion.parentIndex[i] < 0) {
                    roots.add(expansion.lines[i]);
                }
            }
            insert as user roots;

            List<Quote_Line__c> components = new List<Quote_Line__c>();
            for (Integer i = 0; i < expansion.lines.size(); i++) {
                Integer parent = expansion.parentIndex[i];
                if (parent >= 0) {
                    expansion.lines[i].Parent_Line__c = expansion.lines[parent].Id;
                    components.add(expansion.lines[i]);
                }
            }
            insert as user components;

            if (draft.opportunityId != null) {
                Opportunity opportunity = new Opportunity(Id = draft.opportunityId, Primary_Quote__c = quote.Id);
                update as user opportunity;
            }
            return quote.Id;
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw AuraErrorFactory.wrap(e);
        }
    }

    // ------------------------------------------------------------------ internals

    /**
     * Turns the draft into unsaved lines in the order the user entered them. All bundles are validated and expanded
     * in one ProductConfigurationService call, so the SOQL cost is constant regardless of how many bundles the
     * draft contains (one product query here, two for all bundle definitions).
     */
    private static Expansion expand(DraftRequest draft, Id quoteId) {
        Expansion expansion = new Expansion();
        if (draft == null || draft.lines == null || draft.lines.isEmpty()) {
            return expansion;
        }
        if (draft.lines.size() > MAX_DRAFT_LINES) {
            expansion.errors.add('A quote can contain at most ' + MAX_DRAFT_LINES + ' configured lines.');
            return expansion;
        }
        Set<Id> draftProductIds = new Set<Id>();
        for (DraftLine line : draft.lines) {
            if (line != null && line.productId != null) {
                draftProductIds.add(line.productId);
            }
        }
        Map<Id, Product2> products = QuoteSelector.productsById(draftProductIds);

        // Pass 1: classify lines and collect every bundle into one bulk request.
        List<ProductConfigurationService.BundleRequest> bundleRequests = new List<ProductConfigurationService.BundleRequest>();
        Map<Integer, Integer> bundleRequestIndexByDraftIndex = new Map<Integer, Integer>();
        for (Integer i = 0; i < draft.lines.size(); i++) {
            DraftLine draftLine = draft.lines[i];
            if (draftLine == null || draftLine.productId == null) {
                continue;
            }
            Product2 product = products.get(draftLine.productId);
            if (product != null && product.Product_Type__c == QuoteConstants.PRODUCT_TYPE_BUNDLE) {
                bundleRequestIndexByDraftIndex.put(i, bundleRequests.size());
                bundleRequests.add(
                    new ProductConfigurationService.BundleRequest(
                        product.Id,
                        draftLine.quantity,
                        discountOf(draftLine),
                        draftLine.options
                    )
                );
            }
        }
        List<ProductConfigurationService.BundleConfiguration> configurations = ProductConfigurationService.configureAll(
            quoteId,
            bundleRequests
        );

        // Pass 2: assemble lines in draft order.
        for (Integer i = 0; i < draft.lines.size(); i++) {
            DraftLine draftLine = draft.lines[i];
            if (draftLine == null || draftLine.productId == null) {
                continue;
            }
            Product2 product = products.get(draftLine.productId);
            if (product == null) {
                expansion.errors.add('A selected product is not available.');
                continue;
            }
            if (!bundleRequestIndexByDraftIndex.containsKey(i)) {
                expansion.lines.add(
                    new Quote_Line__c(
                        Quote__c = quoteId,
                        Product__c = product.Id,
                        Quantity__c = draftLine.quantity,
                        Manual_Discount_Pct__c = discountOf(draftLine)
                    )
                );
                expansion.parentIndex.add(-1);
                continue;
            }
            ProductConfigurationService.BundleConfiguration configuration = configurations[
                bundleRequestIndexByDraftIndex.get(i)
            ];
            expansion.warnings.addAll(configuration.result.warnings);
            if (!configuration.result.isValid) {
                for (String message : configuration.result.errors) {
                    expansion.errors.add(product.Name + ': ' + message);
                }
                continue;
            }
            Integer headerIndex = expansion.lines.size();
            expansion.lines.add(configuration.lines.header);
            expansion.parentIndex.add(-1);
            for (Quote_Line__c component : configuration.lines.components) {
                expansion.lines.add(component);
                expansion.parentIndex.add(headerIndex);
            }
        }
        return expansion;
    }

    private static Decimal discountOf(DraftLine draftLine) {
        return draftLine.manualDiscountPct == null ? 0 : draftLine.manualDiscountPct;
    }

    private static QuoteCalculationService.PricingContext pricingContext(DraftRequest draft) {
        QuoteCalculationService.PricingContext context = new QuoteCalculationService.PricingContext();
        context.accountId = draft.accountId;
        context.pricebookId = draft.pricebookId;
        context.termMonths = draft.termMonths == null ? 12 : draft.termMonths;
        return context;
    }

    private static Set<Id> productIds(List<Quote_Line__c> lines) {
        Set<Id> ids = new Set<Id>();
        for (Quote_Line__c line : lines) {
            ids.add(line.Product__c);
        }
        return ids;
    }

    private static PricedLine toDto(Quote_Line__c line, Product2 product, String error) {
        PricedLine dto = new PricedLine();
        dto.productId = line.Product__c;
        dto.name = product == null ? 'Unknown product' : product.Name;
        dto.quantity = line.Quantity__c;
        dto.listUnitPrice = line.List_Unit_Price__c;
        dto.baseUnitPrice = line.Base_Unit_Price__c;
        dto.scheduleDiscountPct = line.Schedule_Discount_Pct__c;
        dto.manualDiscountPct = line.Manual_Discount_Pct__c;
        dto.effectiveDiscountPct = line.Effective_Discount_Pct__c;
        dto.netUnitPrice = line.Net_Unit_Price__c;
        dto.listTotal = line.List_Total__c;
        dto.netTotal = line.Net_Total__c;
        dto.pricingSource = line.Pricing_Source__c;
        dto.isComponent = line.Is_Bundle_Component__c == true;
        dto.isIncluded = line.Is_Included__c == true;
        dto.error = error;
        return dto;
    }
}
