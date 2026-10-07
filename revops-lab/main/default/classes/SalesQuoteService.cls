/**
 * Quote configuration for the Revenue Operations Lab: preview pricing for an unsaved draft and save it as a
 * Quote Configuration with lines.
 *
 * The preview and the save use the same pricing and policy code as the line trigger, so what the user sees is
 * what gets saved; the trigger and the validation rules re-check everything on insert, so the UI is never the control.
 * User-entered data (quote header, lines, primary quote on the opportunity) is written in user mode.
 */
public with sharing class SalesQuoteService {
    @TestVisible
    private static final Integer MAX_LINES = 50;

    public class LineRequest {
        @AuraEnabled
        public Id productId { get; set; }
        @AuraEnabled
        public Decimal quantity { get; set; }
        @AuraEnabled
        public Decimal discountPercent { get; set; }
    }

    public class QuoteRequest {
        @AuraEnabled
        public Id opportunityId { get; set; }
        @AuraEnabled
        public Id pricebookId { get; set; }
        @AuraEnabled
        public Integer termMonths { get; set; }
        @AuraEnabled
        public List<LineRequest> lines { get; set; }
    }

    public class LinePreview {
        @AuraEnabled
        public Id productId;
        @AuraEnabled
        public String productName;
        @AuraEnabled
        public String productFamily;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal listUnitPrice;
        @AuraEnabled
        public Decimal discountPercent;
        @AuraEnabled
        public Decimal maxDiscountPercent;
        @AuraEnabled
        public Decimal listTotal;
        @AuraEnabled
        public Decimal netTotal;
        @AuraEnabled
        public String error;
    }

    public class QuotePreview {
        @AuraEnabled
        public Boolean isValid = true;
        @AuraEnabled
        public List<String> errors = new List<String>();
        @AuraEnabled
        public List<LinePreview> lines = new List<LinePreview>();
        @AuraEnabled
        public Decimal listTotal = 0;
        @AuraEnabled
        public Decimal netTotal = 0;
        @AuraEnabled
        public Decimal discountAmount = 0;
        @AuraEnabled
        public Decimal maxDiscountPercent = 0;
        @AuraEnabled
        public DiscountPolicyService.ApprovalDecision approval;
    }

    /** Draft priced in memory, plus the context needed to save it. */
    private class PricedDraft {
        Opportunity opportunity;
        Id pricebookId;
        List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>();
        QuotePreview preview = new QuotePreview();
    }

    // ------------------------------------------------------------------ public API

    public static QuotePreview preview(QuoteRequest request) {
        return price(request).preview;
    }

    /** Creates the quote and its lines atomically and makes it the opportunity's primary quote. Returns the quote Id. */
    public static Id save(QuoteRequest request) {
        PricedDraft draft = price(request);
        if (!draft.preview.isValid) {
            throw new SalesLabException(String.join(draft.preview.errors, ' '));
        }
        Savepoint savepoint = Database.setSavepoint();
        try {
            Quote_Configuration__c quote = new Quote_Configuration__c(
                Opportunity__c = draft.opportunity.Id,
                Account__c = draft.opportunity.AccountId,
                Price_Book__c = draft.pricebookId,
                Term_Months__c = request.termMonths == null ? 12 : request.termMonths
            );
            insert as user quote;

            List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>();
            for (Quote_Configuration_Line__c priced : draft.lines) {
                // Only user inputs are sent; the trigger re-prices and re-applies the policy cap on insert.
                lines.add(
                    new Quote_Configuration_Line__c(
                        Quote_Configuration__c = quote.Id,
                        Product__c = priced.Product__c,
                        Quantity__c = priced.Quantity__c,
                        Discount_Percent__c = priced.Discount_Percent__c
                    )
                );
            }
            insert as user lines;

            update as user new Opportunity(Id = draft.opportunity.Id, Primary_Quote_Configuration__c = quote.Id);
            return quote.Id;
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
    }

    // ------------------------------------------------------------------ internals

    private static PricedDraft price(QuoteRequest request) {
        PricedDraft draft = new PricedDraft();
        QuotePreview preview = draft.preview;
        if (request == null || request.opportunityId == null) {
            return fail(draft, 'An opportunity is required.');
        }
        draft.opportunity = SalesQuoteSelector.opportunitiesById(new Set<Id>{ request.opportunityId })
            .get(request.opportunityId);
        if (draft.opportunity == null) {
            return fail(draft, 'Opportunity not found or you do not have access to it.');
        }
        if (draft.opportunity.AccountId == null) {
            return fail(draft, 'The opportunity needs an account before it can be quoted.');
        }
        if (
            request.termMonths != null &&
            (request.termMonths < 1 ||
            request.termMonths > SalesLabConstants.MAX_TERM_MONTHS)
        ) {
            fail(draft, 'Term must be between 1 and ' + SalesLabConstants.MAX_TERM_MONTHS + ' months.');
        }
        draft.pricebookId = request.pricebookId != null
            ? request.pricebookId
            : (draft.opportunity.Pricebook2Id != null
                  ? draft.opportunity.Pricebook2Id
                  : SalesQuoteSelector.standardPricebookId());

        List<LineRequest> requested = request.lines == null ? new List<LineRequest>() : request.lines;
        if (requested.isEmpty()) {
            return fail(draft, 'Add at least one product.');
        }
        if (requested.size() > MAX_LINES) {
            return fail(draft, 'A quote can contain at most ' + MAX_LINES + ' lines.');
        }

        List<Id> pricebookByLine = new List<Id>();
        for (LineRequest line : requested) {
            draft.lines.add(
                new Quote_Configuration_Line__c(
                    Product__c = line == null ? null : line.productId,
                    Quantity__c = line == null ? null : line.quantity,
                    Discount_Percent__c = line == null || line.discountPercent == null ? 0 : line.discountPercent
                )
            );
            pricebookByLine.add(draft.pricebookId);
        }

        Map<Integer, PricebookEntry> entries = new Map<Integer, PricebookEntry>();
        Map<Integer, String> errors = ProductPricingService.priceLines(draft.lines, pricebookByLine, entries);
        DiscountPolicyService.applyCaps(draft.lines, Date.today());

        for (Integer i = 0; i < draft.lines.size(); i++) {
            Quote_Configuration_Line__c line = draft.lines[i];
            String error = errors.get(i);
            if (error == null && (line.Quantity__c == null || line.Quantity__c <= 0)) {
                error = 'Quantity must be greater than zero.';
            }
            if (error == null) {
                error = DiscountPolicyService.capViolation(line);
            }
            LinePreview dto = new LinePreview();
            dto.productId = line.Product__c;
            dto.productName = entries.containsKey(i) ? entries.get(i).Product2.Name : null;
            dto.productFamily = line.Product_Family__c;
            dto.billingFrequency = line.Billing_Frequency__c;
            dto.quantity = line.Quantity__c;
            dto.listUnitPrice = line.List_Unit_Price__c;
            dto.discountPercent = line.Discount_Percent__c;
            dto.maxDiscountPercent = line.Max_Allowed_Discount_Percent__c;
            dto.listTotal = ProductPricingService.listTotal(line);
            dto.netTotal = ProductPricingService.netTotal(line);
            dto.error = error;
            preview.lines.add(dto);
            if (error != null) {
                fail(draft, 'Line ' + (i + 1) + ': ' + error);
                continue;
            }
            preview.listTotal += dto.listTotal;
            preview.netTotal += dto.netTotal;
            preview.maxDiscountPercent = Math.max(preview.maxDiscountPercent, dto.discountPercent);
        }
        preview.discountAmount = preview.listTotal - preview.netTotal;
        preview.approval = DiscountPolicyService.evaluate(preview.maxDiscountPercent, preview.netTotal);
        return draft;
    }

    private static PricedDraft fail(PricedDraft draft, String message) {
        draft.preview.isValid = false;
        draft.preview.errors.add(message);
        return draft;
    }
}
