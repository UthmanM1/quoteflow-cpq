/**
 * Quote_Line__c trigger logic.
 *   before insert/update  enforce the quote lock, then price the lines in memory (user input for any
 *                         calculated field is overwritten, never trusted)
 *   before delete         enforce the quote lock, then cascade the delete to bundle components (Parent_Line__c is a
 *                         same-object lookup, which cannot cascade declaratively; SetNull would leave orphaned,
 *                         possibly zero-priced "included" components on the quote)
 *   after any change      roll the lines up onto the parent quote with one aggregate query
 */
public with sharing class QuoteLineTriggerHandler {
    public static void run() {
        handle(Trigger.operationType, Trigger.new, Trigger.old);
    }

    public static void handle(
        System.TriggerOperation operation,
        List<Quote_Line__c> newRecords,
        List<Quote_Line__c> oldRecords
    ) {
        switch on operation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                beforeSave(newRecords);
            }
            when BEFORE_DELETE {
                beforeDelete(oldRecords);
            }
            when AFTER_INSERT, AFTER_UPDATE, AFTER_UNDELETE {
                rollUp(newRecords);
            }
            when AFTER_DELETE {
                rollUp(oldRecords);
            }
            when else {
                // Not subscribed.
            }
        }
    }

    private static void beforeSave(List<Quote_Line__c> lines) {
        if (QuoteTriggerContext.isRepricing) {
            return;
        }
        Map<Id, Quote__c> quotes = loadQuotes(lines);
        List<Quote_Line__c> allowed = enforceLock(lines, quotes);
        validateIncludedFlags(allowed);
        QuoteCalculationService.priceLinesInTrigger(allowed, quotes);
    }

    private static void beforeDelete(List<Quote_Line__c> lines) {
        List<Quote_Line__c> allowed = enforceLock(lines, loadQuotes(lines));
        cascadeToComponents(allowed);
    }

    /** Deletes the components of every header being deleted, in one query and one DML statement. */
    private static void cascadeToComponents(List<Quote_Line__c> deletedLines) {
        Map<Id, Quote_Line__c> deletedById = new Map<Id, Quote_Line__c>(deletedLines);
        if (deletedById.isEmpty()) {
            return;
        }
        List<Quote_Line__c> orphans = new List<Quote_Line__c>();
        for (Quote_Line__c component : QuoteSelector.componentLinesForParents(deletedById.keySet())) {
            if (!deletedById.containsKey(component.Id)) {
                orphans.add(component);
            }
        }
        if (orphans.isEmpty()) {
            return;
        }
        try {
            delete orphans;
        } catch (DmlException e) {
            Set<Id> affectedHeaders = new Set<Id>();
            for (Quote_Line__c orphan : orphans) {
                affectedHeaders.add(orphan.Parent_Line__c);
            }
            for (Id headerId : affectedHeaders) {
                deletedById.get(headerId).addError('The bundle components could not be removed: ' + e.getDmlMessage(0));
            }
        }
    }

    /** Returns the lines that passed the lock check; the rest have already had an error added. */
    private static List<Quote_Line__c> enforceLock(List<Quote_Line__c> lines, Map<Id, Quote__c> quotes) {
        Boolean canOverride = FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION);
        List<Quote_Line__c> allowed = new List<Quote_Line__c>();
        for (Quote_Line__c line : lines) {
            Quote__c quote = quotes.get(line.Quote__c);
            if (quote == null) {
                line.addError('The parent quote does not exist or you do not have access to it.');
            } else if (
                !QuoteConstants.EDITABLE_STATUSES.contains(quote.Status__c) &&
                !canOverride &&
                !QuoteTriggerContext.isServiceUpdate
            ) {
                line.addError('Lines cannot be changed while the quote is ' + quote.Status__c + '.');
            } else {
                allowed.add(line);
            }
        }
        return allowed;
    }

    /**
     * Is_Included__c zeroes a line's price, so it is only honoured when the bundle definition says the
     * option is included. Anything else (API tampering, stale UI) is rejected.
     */
    private static void validateIncludedFlags(List<Quote_Line__c> lines) {
        Set<Id> parentIds = new Set<Id>();
        for (Quote_Line__c line : lines) {
            if (line.Is_Included__c == true && line.Parent_Line__c != null) {
                parentIds.add(line.Parent_Line__c);
            }
        }
        Map<Id, Quote_Line__c> parents = new Map<Id, Quote_Line__c>(QuoteSelector.linesByIds(parentIds));
        Set<Id> bundleProductIds = new Set<Id>();
        for (Quote_Line__c parent : parents.values()) {
            bundleProductIds.add(parent.Product__c);
        }
        Set<String> includedPairs = new Set<String>();
        for (Product_Option__c option : QuoteSelector.activeOptionsForBundles(bundleProductIds)) {
            if (option.Price_Treatment__c == QuoteConstants.PRICE_TREATMENT_INCLUDED) {
                includedPairs.add(option.Bundle_Product__c + ':' + option.Option_Product__c);
            }
        }
        for (Quote_Line__c line : lines) {
            if (line.Is_Included__c != true) {
                continue;
            }
            Quote_Line__c parent = parents.get(line.Parent_Line__c);
            if (parent == null || !includedPairs.contains(parent.Product__c + ':' + line.Product__c)) {
                line.Is_Included__c.addError('This product is not an included option of its bundle.');
            }
        }
    }

    private static void rollUp(List<Quote_Line__c> lines) {
        if (QuoteTriggerContext.isRepricing) {
            return; // reprice() performs its own roll-up once all lines are written.
        }
        Set<Id> quoteIds = new Set<Id>();
        for (Quote_Line__c line : lines) {
            quoteIds.add(line.Quote__c);
        }
        try {
            QuoteCalculationService.rollUp(quoteIds);
        } catch (QuoteFlowException e) {
            for (Quote_Line__c line : lines) {
                line.addError(e.getMessage());
            }
        }
    }

    private static Map<Id, Quote__c> loadQuotes(List<Quote_Line__c> lines) {
        Set<Id> quoteIds = new Set<Id>();
        for (Quote_Line__c line : lines) {
            quoteIds.add(line.Quote__c);
        }
        return new Map<Id, Quote__c>(QuoteSelector.quotesById(quoteIds));
    }
}
