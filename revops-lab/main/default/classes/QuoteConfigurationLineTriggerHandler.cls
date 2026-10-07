/**
 * Quote_Configuration_Line__c trigger logic.
 *
 *   before insert/update  price every line from the quote's price book (ProductPricingService) and stamp the discount
 *                         cap from the active policy (DiscountPolicyService). The validation rules that run next in
 *                         the order of execution (Discount_Within_Policy, Quantity_Must_Be_Positive,
 *                         Lines_Locked_After_Submit) then judge the values this handler set.
 *   before delete         validation rules cannot see deletes, so the quote lock for deletes is enforced here.
 *
 * Totals are not calculated here: Total_List_Amount__c / Total_Net_Amount__c / Max_Discount_Percent__c are native
 * roll-up summary fields over formula fields on the line.
 */
public with sharing class QuoteConfigurationLineTriggerHandler {
    public static void run() {
        handle(Trigger.operationType, Trigger.new, Trigger.old);
    }

    public static void handle(
        System.TriggerOperation operation,
        List<Quote_Configuration_Line__c> newRecords,
        List<Quote_Configuration_Line__c> oldRecords
    ) {
        switch on operation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                priceAndCap(newRecords);
            }
            when BEFORE_DELETE {
                enforceDeleteLock(oldRecords);
            }
            when else {
                // Not subscribed.
            }
        }
    }

    private static void priceAndCap(List<Quote_Configuration_Line__c> lines) {
        Map<Id, Quote_Configuration__c> quotes = parentQuotes(lines);
        List<Id> pricebookByLine = new List<Id>();
        for (Quote_Configuration_Line__c line : lines) {
            Quote_Configuration__c quote = quotes.get(line.Quote_Configuration__c);
            pricebookByLine.add(quote == null ? null : quote.Price_Book__c);
        }
        Map<Integer, String> errors = ProductPricingService.priceLines(lines, pricebookByLine);
        List<Quote_Configuration_Line__c> priced = new List<Quote_Configuration_Line__c>();
        for (Integer i = 0; i < lines.size(); i++) {
            if (quotes.get(lines[i].Quote_Configuration__c) == null) {
                lines[i].addError('The quote does not exist or you do not have access to it.');
            } else if (errors.containsKey(i)) {
                lines[i].Product__c.addError(errors.get(i));
            } else {
                priced.add(lines[i]);
            }
        }
        DiscountPolicyService.applyCaps(priced, Date.today());
    }

    private static void enforceDeleteLock(List<Quote_Configuration_Line__c> lines) {
        Map<Id, Quote_Configuration__c> quotes = parentQuotes(lines);
        Boolean canOverride = FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_OVERRIDE_LOCK);
        for (Quote_Configuration_Line__c line : lines) {
            Quote_Configuration__c quote = quotes.get(line.Quote_Configuration__c);
            if (quote != null && !SalesLabConstants.EDITABLE_QUOTE_STATUSES.contains(quote.Status__c) && !canOverride) {
                line.addError('Lines cannot be removed after the quote is submitted. Recall the quote first.');
            }
        }
    }

    private static Map<Id, Quote_Configuration__c> parentQuotes(List<Quote_Configuration_Line__c> lines) {
        Set<Id> quoteIds = new Set<Id>();
        for (Quote_Configuration_Line__c line : lines) {
            quoteIds.add(line.Quote_Configuration__c);
        }
        return SalesQuoteSelector.quotesById(quoteIds);
    }
}
