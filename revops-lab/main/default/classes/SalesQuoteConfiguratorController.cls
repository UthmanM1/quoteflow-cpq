/**
 * Server side of the salesQuoteConfigurator LWC. Shapes data and translates errors only; pricing, policy and approval
 * rules live in the services, and the line trigger re-checks everything on save.
 */
public with sharing class SalesQuoteConfiguratorController {
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
        public Id pricebookId;
        @AuraEnabled
        public String pricebookName;
        @AuraEnabled
        public String currencyIsoCode = UserInfo.getDefaultCurrency();
        @AuraEnabled
        public Integer maxTermMonths = SalesLabConstants.MAX_TERM_MONTHS;
    }

    public class CatalogItem {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String productCode;
        @AuraEnabled
        public String family;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public Decimal unitPrice;
        @AuraEnabled
        public Decimal maxDiscountPercent;
    }

    @AuraEnabled(cacheable=true)
    public static ContextInfo getContext(Id opportunityId) {
        try {
            Opportunity opportunity = SalesQuoteSelector.opportunitiesById(new Set<Id>{ opportunityId })
                .get(opportunityId);
            if (opportunity == null) {
                throw new SalesLabException('Opportunity not found or you do not have access to it.');
            }
            ContextInfo info = new ContextInfo();
            info.opportunityId = opportunity.Id;
            info.opportunityName = opportunity.Name;
            info.accountId = opportunity.AccountId;
            info.accountName = opportunity.Account?.Name;
            info.pricebookId = opportunity.Pricebook2Id != null
                ? opportunity.Pricebook2Id
                : SalesQuoteSelector.standardPricebookId();
            info.pricebookName = opportunity.Pricebook2Id != null ? opportunity.Pricebook2.Name : 'Standard Price Book';
            return info;
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CatalogItem> getCatalog(Id pricebookId) {
        try {
            List<PricebookEntry> entries = SalesQuoteSelector.catalogue(pricebookId);
            Set<String> families = new Set<String>();
            for (PricebookEntry entry : entries) {
                if (String.isNotBlank(entry.Product2.Family)) {
                    families.add(entry.Product2.Family);
                }
            }
            Map<String, Discount_Policy__c> policies = DiscountPolicyService.activePoliciesByFamily(
                families,
                Date.today()
            );
            List<CatalogItem> items = new List<CatalogItem>();
            for (PricebookEntry entry : entries) {
                CatalogItem item = new CatalogItem();
                item.productId = entry.Product2Id;
                item.name = entry.Product2.Name;
                item.productCode = entry.Product2.ProductCode;
                item.family = entry.Product2.Family;
                item.billingFrequency = entry.Product2.Billing_Frequency__c;
                item.unitPrice = entry.UnitPrice;
                Discount_Policy__c policy = String.isBlank(item.family)
                    ? null
                    : policies.get(item.family.toLowerCase());
                item.maxDiscountPercent = policy == null ? 0 : policy.Max_Discount_Percent__c;
                items.add(item);
            }
            return items;
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static SalesQuoteService.QuotePreview previewQuote(SalesQuoteService.QuoteRequest request) {
        try {
            return SalesQuoteService.preview(request);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static Id saveQuote(SalesQuoteService.QuoteRequest request) {
        try {
            return SalesQuoteService.save(request);
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }

    @AuraEnabled
    public static SalesQuoteApprovalService.SubmissionResult submitQuote(Id quoteId) {
        try {
            SalesQuoteApprovalService.SubmissionResult result = SalesQuoteApprovalService.submit(quoteId);
            if (result == null || !result.success) {
                throw new SalesLabException(result == null ? 'Submission failed.' : result.message);
            }
            return result;
        } catch (Exception e) {
            throw SalesAuraErrors.wrap(e);
        }
    }
}
