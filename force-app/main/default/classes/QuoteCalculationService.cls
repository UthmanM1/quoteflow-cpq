/**
 * Pricing engine for quote lines and quote totals.
 *
 * Price waterfall per line:
 *   1. base price      = contracted price (if one is valid today) otherwise pricebook list price
 *   2. schedule disc.  = volume tier from Discount_Rule__mdt; not stacked on contracted prices
 *   3. manual disc.    = rep-entered, capped at MAX_MANUAL_DISCOUNT_PCT
 *   4. net unit price  = base * (1 - schedule) * (1 - manual)
 *   5. totals          = unit price * quantity * term factor (annual subscriptions scale by term / 12)
 *
 * The line-level entry points work in memory so they can run in a before trigger (no DML, no extra
 * re-entry) and from the configurator preview, which prices lines that have never been saved.
 */
public with sharing class QuoteCalculationService {
    /** Exposed to the configurator so the client-side check cannot drift from the server rule. */
    public static final Decimal MAX_MANUAL_DISCOUNT_PCT = 60;
    public static final Integer MAX_TERM_MONTHS = 60;
    private static final Integer MONEY_SCALE = 2;

    public class PricingContext {
        public Id accountId;
        public Id pricebookId;
        public Integer termMonths = 12;
        public Date pricingDate = Date.today();
    }

    public class QuoteTotals {
        public Decimal listAmount = 0;
        public Decimal netAmount = 0;
        public Decimal totalDiscountAmount = 0;
        public Decimal blendedDiscountPct = 0;
        public Decimal maxLineDiscountPct = 0;
        public Integer lineCount = 0;
    }

    // ------------------------------------------------------------------ trigger entry points

    /**
     * Prices lines inside a before insert/update trigger. Failures are reported on the offending line
     * with addError so the rest of the batch is still evaluated and the user sees every problem at once.
     */
    public static void priceLinesInTrigger(List<Quote_Line__c> lines, Map<Id, Quote__c> quotesById) {
        Map<Id, List<Quote_Line__c>> linesByQuote = new Map<Id, List<Quote_Line__c>>();
        for (Quote_Line__c line : lines) {
            if (!linesByQuote.containsKey(line.Quote__c)) {
                linesByQuote.put(line.Quote__c, new List<Quote_Line__c>());
            }
            linesByQuote.get(line.Quote__c).add(line);
        }
        for (Id quoteId : linesByQuote.keySet()) {
            Quote__c quote = quotesById.get(quoteId);
            if (quote == null) {
                for (Quote_Line__c line : linesByQuote.get(quoteId)) {
                    line.addError('The parent quote does not exist or you do not have access to it.');
                }
                continue;
            }
            Map<Integer, String> errors = priceLines(linesByQuote.get(quoteId), contextFor(quote));
            for (Integer index : errors.keySet()) {
                linesByQuote.get(quoteId)[index].addError(errors.get(index));
            }
        }
    }

    /**
     * Aggregates line values onto the parent quotes. Runs in an after trigger, so it reads the committed
     * state of the transaction (including the lines that just fired the trigger) with one aggregate query.
     */
    public static void rollUp(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }
        Map<Id, QuoteTotals> totalsByQuote = new Map<Id, QuoteTotals>();
        for (AggregateResult row : QuoteSelector.lineTotalsByQuote(quoteIds)) {
            QuoteTotals totals = new QuoteTotals();
            totals.listAmount = money((Decimal) row.get('listTotal'));
            totals.netAmount = money((Decimal) row.get('netTotal'));
            totals.maxLineDiscountPct = nz((Decimal) row.get('maxDiscount'));
            totals.lineCount = (Integer) row.get('lineCount');
            finalise(totals);
            totalsByQuote.put((Id) row.get('quoteId'), totals);
        }

        List<Quote__c> updates = new List<Quote__c>();
        for (Quote__c quote : QuoteSelector.quotesById(quoteIds)) {
            QuoteTotals totals = totalsByQuote.containsKey(quote.Id) ? totalsByQuote.get(quote.Id) : new QuoteTotals();
            Integer requiredLevel = DiscountEvaluationService.evaluate(totals.maxLineDiscountPct).level;
            if (hasChanged(quote, totals, requiredLevel)) {
                updates.add(
                    new Quote__c(
                        Id = quote.Id,
                        List_Amount__c = totals.listAmount,
                        Net_Amount__c = totals.netAmount,
                        Total_Discount_Amount__c = totals.totalDiscountAmount,
                        Blended_Discount_Pct__c = totals.blendedDiscountPct,
                        Max_Line_Discount_Pct__c = totals.maxLineDiscountPct,
                        Required_Approval_Level__c = requiredLevel
                    )
                );
            }
        }
        writeAsService(updates, 'Unable to update quote totals');
    }

    /**
     * Re-prices every line on the supplied quotes after a pricing input (price book, term, account) changed.
     * Fails the whole operation if any line can no longer be priced, so a quote is never left half-repriced.
     */
    public static void reprice(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return;
        }
        Map<Id, Quote__c> quotes = new Map<Id, Quote__c>(QuoteSelector.quotesById(quoteIds));
        Map<Id, List<Quote_Line__c>> linesByQuote = new Map<Id, List<Quote_Line__c>>();
        for (Quote_Line__c line : QuoteSelector.linesForQuotes(quoteIds)) {
            if (!linesByQuote.containsKey(line.Quote__c)) {
                linesByQuote.put(line.Quote__c, new List<Quote_Line__c>());
            }
            linesByQuote.get(line.Quote__c).add(line);
        }

        List<Quote_Line__c> pricedLines = new List<Quote_Line__c>();
        List<String> failures = new List<String>();
        for (Id quoteId : linesByQuote.keySet()) {
            Quote__c quote = quotes.get(quoteId);
            List<Quote_Line__c> quoteLines = linesByQuote.get(quoteId);
            Map<Integer, String> errors = priceLines(quoteLines, contextFor(quote));
            for (Integer index : errors.keySet()) {
                failures.add(quote.Name + ': ' + errors.get(index));
            }
            pricedLines.addAll(quoteLines);
        }
        if (!failures.isEmpty()) {
            throw new QuoteFlowException('Quote could not be re-priced. ' + String.join(failures, ' '));
        }

        // The user who changed the price book/term/account already holds edit access on the quote (and therefore
        // its master-detail lines), so the line update stays an ordinary, sharing-enforced write.
        Boolean previous = QuoteTriggerContext.enterRepricing();
        try {
            update pricedLines;
        } catch (DmlException e) {
            throw new QuoteFlowException('Unable to save re-priced lines: ' + e.getDmlMessage(0));
        } finally {
            QuoteTriggerContext.restoreRepricing(previous);
        }
        rollUp(quoteIds);
    }

    // ------------------------------------------------------------------ in-memory pricing

    /**
     * Prices lines belonging to ONE quote context. Returns line index -> validation message for lines that
     * could not be priced; priced lines are mutated in place.
     * Does no DML and issues three SOQL statements regardless of line count.
     */
    public static Map<Integer, String> priceLines(List<Quote_Line__c> lines, PricingContext context) {
        Map<Integer, String> errors = new Map<Integer, String>();
        if (lines == null || lines.isEmpty()) {
            return errors;
        }
        if (
            context == null ||
            context.termMonths == null ||
            context.termMonths < 1 ||
            context.termMonths > MAX_TERM_MONTHS
        ) {
            String message = 'Term must be between 1 and ' + MAX_TERM_MONTHS + ' months.';
            for (Integer i = 0; i < lines.size(); i++) {
                errors.put(i, message);
            }
            return errors;
        }

        Set<Id> productIds = new Set<Id>();
        for (Quote_Line__c line : lines) {
            if (line.Product__c != null) {
                productIds.add(line.Product__c);
            }
        }
        Map<Id, Product2> products = QuoteSelector.productsById(productIds);
        Map<Id, PricebookEntry> entries = QuoteSelector.pricebookEntriesByProduct(context.pricebookId, productIds);
        Map<Id, Contracted_Price__c> contracted = QuoteSelector.contractedPricesByProduct(
            context.accountId,
            productIds,
            context.pricingDate
        );

        for (Integer i = 0; i < lines.size(); i++) {
            String error = priceLine(lines[i], context, products, entries, contracted);
            if (error != null) {
                errors.put(i, error);
            }
        }
        return errors;
    }

    /** Totals for lines that are not persisted (configurator preview). */
    public static QuoteTotals summarise(List<Quote_Line__c> pricedLines) {
        QuoteTotals totals = new QuoteTotals();
        for (Quote_Line__c line : pricedLines) {
            totals.listAmount += nz(line.List_Total__c);
            totals.netAmount += nz(line.Net_Total__c);
            totals.maxLineDiscountPct = Math.max(totals.maxLineDiscountPct, nz(line.Effective_Discount_Pct__c));
            totals.lineCount++;
        }
        finalise(totals);
        return totals;
    }

    public static PricingContext contextFor(Quote__c quote) {
        PricingContext context = new PricingContext();
        context.accountId = quote.Account__c;
        context.pricebookId = quote.Pricebook__c;
        context.termMonths = quote.Term_Months__c == null ? null : Integer.valueOf(quote.Term_Months__c);
        return context;
    }

    // ------------------------------------------------------------------ internals

    private static String priceLine(
        Quote_Line__c line,
        PricingContext context,
        Map<Id, Product2> products,
        Map<Id, PricebookEntry> entries,
        Map<Id, Contracted_Price__c> contracted
    ) {
        if (line.Product__c == null) {
            return 'Product is required.';
        }
        Product2 product = products.get(line.Product__c);
        if (product == null || !product.IsActive) {
            return 'The selected product is not available.';
        }
        if (line.Quantity__c == null || line.Quantity__c <= 0) {
            return 'Quantity must be greater than zero.';
        }
        Decimal manualPct = nz(line.Manual_Discount_Pct__c);
        if (manualPct < 0 || manualPct > MAX_MANUAL_DISCOUNT_PCT) {
            return 'Discount must be between 0% and ' + MAX_MANUAL_DISCOUNT_PCT + '%.';
        }
        PricebookEntry entry = entries.get(line.Product__c);
        if (entry == null) {
            return product.Name + ' has no active price in the selected price book.';
        }

        Boolean isSubscription = product.Billing_Model__c != QuoteConstants.BILLING_ONE_TIME;
        Decimal termFactor = isSubscription
            ? Decimal.valueOf(context.termMonths).divide(12, 6, RoundingMode.HALF_EVEN)
            : 1;

        line.Billing_Model__c = isSubscription ? QuoteConstants.BILLING_SUBSCRIPTION : QuoteConstants.BILLING_ONE_TIME;
        line.Pricebook_Entry_Id__c = entry.Id;
        line.List_Unit_Price__c = money(entry.UnitPrice);

        Contracted_Price__c contractedPrice = contracted.get(line.Product__c);
        line.Contracted_Unit_Price__c = contractedPrice == null ? null : money(contractedPrice.Unit_Price__c);
        line.Pricing_Source__c = contractedPrice == null
            ? QuoteConstants.PRICING_LIST
            : QuoteConstants.PRICING_CONTRACTED;
        line.Base_Unit_Price__c = contractedPrice == null ? line.List_Unit_Price__c : line.Contracted_Unit_Price__c;

        if (line.Is_Included__c == true) {
            // Covered by the bundle price: visible on the quote, contributes nothing to totals or approvals.
            line.Schedule_Discount_Pct__c = 0;
            line.Manual_Discount_Pct__c = 0;
            line.Effective_Discount_Pct__c = 0;
            line.Net_Unit_Price__c = 0;
            line.List_Total__c = 0;
            line.Net_Total__c = 0;
            return null;
        }

        Decimal schedulePct = contractedPrice == null
            ? DiscountEvaluationService.scheduleDiscountPct(product.Family, line.Quantity__c)
            : 0;
        Decimal keepFactor = (1 - schedulePct / 100) * (1 - manualPct / 100);

        line.Schedule_Discount_Pct__c = schedulePct;
        line.Manual_Discount_Pct__c = manualPct;
        line.Effective_Discount_Pct__c = ((1 - keepFactor) * 100).setScale(MONEY_SCALE, RoundingMode.HALF_EVEN);
        line.Net_Unit_Price__c = money(line.Base_Unit_Price__c * keepFactor);
        line.List_Total__c = money(line.List_Unit_Price__c * line.Quantity__c * termFactor);
        line.Net_Total__c = money(line.Net_Unit_Price__c * line.Quantity__c * termFactor);
        return null;
    }

    private static void finalise(QuoteTotals totals) {
        totals.totalDiscountAmount = money(totals.listAmount - totals.netAmount);
        totals.blendedDiscountPct = totals.listAmount > 0
            ? (totals.totalDiscountAmount / totals.listAmount * 100).setScale(MONEY_SCALE, RoundingMode.HALF_EVEN)
            : 0;
    }

    private static Boolean hasChanged(Quote__c quote, QuoteTotals totals, Integer requiredLevel) {
        return nz(quote.List_Amount__c) != totals.listAmount ||
            nz(quote.Net_Amount__c) != totals.netAmount ||
            nz(quote.Blended_Discount_Pct__c) != totals.blendedDiscountPct ||
            nz(quote.Max_Line_Discount_Pct__c) != totals.maxLineDiscountPct ||
            nz(quote.Required_Approval_Level__c) != requiredLevel;
    }

    /**
     * Totals and routing fields are system-owned: no persona has edit FLS on them, so they are written through
     * QuoteStateWriter. Every input above was read in user mode, and the triggering line change already required
     * edit access to the quote, so the elevation adds no access the user did not have.
     */
    private static void writeAsService(List<Quote__c> quotes, String failurePrefix) {
        try {
            QuoteStateWriter.updateQuotes(quotes);
        } catch (DmlException e) {
            throw new QuoteFlowException(failurePrefix + ': ' + e.getDmlMessage(0));
        }
    }

    private static Decimal money(Decimal value) {
        return nz(value).setScale(MONEY_SCALE, RoundingMode.HALF_EVEN);
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
