/**
 * List pricing for Quote Configuration Lines.
 *
 * The price book entry is the single source of list price: whatever the user or an API client sends in
 * List_Unit_Price__c is overwritten. Product family and billing frequency are copied from the product so the
 * discount policy, reporting and order conversion do not need extra queries later.
 *
 * Bulk contract: one SOQL statement per call, however many lines, quotes or price books are involved.
 * Works in memory (no DML), so the same code serves the before trigger and the configurator preview.
 */
public with sharing class ProductPricingService {
    /**
     * Prices lines in place. `pricebookByLine` holds the price book for each line (index-aligned).
     * Returns line index -> user-facing error for lines that could not be priced.
     */
    public static Map<Integer, String> priceLines(List<Quote_Configuration_Line__c> lines, List<Id> pricebookByLine) {
        return priceLines(lines, pricebookByLine, new Map<Integer, PricebookEntry>());
    }

    /** As above; also fills `matchedEntries` (line index -> price book entry) for callers that display product data. */
    public static Map<Integer, String> priceLines(
        List<Quote_Configuration_Line__c> lines,
        List<Id> pricebookByLine,
        Map<Integer, PricebookEntry> matchedEntries
    ) {
        Map<Integer, String> errors = new Map<Integer, String>();
        if (lines == null || lines.isEmpty()) {
            return errors;
        }
        Set<Id> pricebookIds = new Set<Id>();
        Set<Id> productIds = new Set<Id>();
        for (Integer i = 0; i < lines.size(); i++) {
            if (pricebookByLine[i] != null) {
                pricebookIds.add(pricebookByLine[i]);
            }
            if (lines[i].Product__c != null) {
                productIds.add(lines[i].Product__c);
            }
        }
        Map<String, PricebookEntry> entries = SalesQuoteSelector.pricebookEntries(pricebookIds, productIds);

        for (Integer i = 0; i < lines.size(); i++) {
            Quote_Configuration_Line__c line = lines[i];
            if (line.Product__c == null) {
                errors.put(i, 'Select a product.');
                continue;
            }
            if (pricebookByLine[i] == null) {
                errors.put(i, 'The quote has no price book. Set one on the opportunity or the quote.');
                continue;
            }
            PricebookEntry entry = entries.get(SalesQuoteSelector.entryKey(pricebookByLine[i], line.Product__c));
            if (entry == null || !entry.IsActive || !entry.Product2.IsActive) {
                errors.put(i, 'The selected product has no active price in the quote price book.');
                continue;
            }
            matchedEntries.put(i, entry);
            line.Price_Book_Entry_Id__c = entry.Id;
            line.List_Unit_Price__c = entry.UnitPrice;
            line.Product_Family__c = entry.Product2.Family;
            line.Billing_Frequency__c = entry.Product2.Billing_Frequency__c == SalesLabConstants.BILLING_ANNUAL
                ? SalesLabConstants.BILLING_ANNUAL
                : SalesLabConstants.BILLING_ONE_TIME;
        }
        return errors;
    }

    /** Same rounding as the Net_Total__c formula, for lines that are not saved yet (preview). */
    public static Decimal netTotal(Quote_Configuration_Line__c line) {
        return (listTotal(line) * (1 - nz(line.Discount_Percent__c) / 100)).setScale(2, RoundingMode.HALF_UP);
    }

    public static Decimal listTotal(Quote_Configuration_Line__c line) {
        return nz(line.Quantity__c) * nz(line.List_Unit_Price__c);
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
