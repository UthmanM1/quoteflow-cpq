/**
 * Converts an approved quote into a standard Order, its OrderItems and one Subscription__c per
 * subscription line. All-or-nothing: any failure rolls the whole conversion back.
 *
 * Order, OrderItem and Subscription__c are created in user mode, so the caller needs create access to them;
 * conversion is an ordinary user action and gets no elevation. Only the status change on the quote (a system-owned
 * field) goes through QuoteStateWriter. The ERP sync of the quote is independent of conversion: Ordered quotes stay
 * eligible (QuoteConstants.ERP_SYNCABLE_STATUSES), so converting never strands a pending sync.
 */
public with sharing class QuoteOrderService {
    public class ConversionResult {
        @AuraEnabled
        public Id orderId;
        @AuraEnabled
        public Integer subscriptionsCreated = 0;
    }

    public static ConversionResult convert(Id quoteId) {
        List<Quote__c> locked = QuoteSelector.quotesForUpdate(new Set<Id>{ quoteId });
        if (locked.isEmpty()) {
            throw new QuoteFlowException('Quote not found or you do not have access to it.');
        }
        Quote__c quote = locked[0];
        if (
            quote.OwnerId != UserInfo.getUserId() &&
            !FeatureManagement.checkPermission(QuoteConstants.OVERRIDE_LOCK_PERMISSION)
        ) {
            throw new QuoteFlowException('Only the quote owner can convert it to an order.');
        }
        if (quote.Status__c != QuoteConstants.STATUS_APPROVED) {
            throw new QuoteFlowException(
                'Only approved quotes can be converted to an order (current status: ' + quote.Status__c + ').'
            );
        }
        if (quote.Account__c == null || quote.Pricebook__c == null) {
            throw new QuoteFlowException('The quote needs an account and a price book before it can be ordered.');
        }
        List<Quote_Line__c> lines = QuoteSelector.linesForQuotes(new Set<Id>{ quoteId });
        if (lines.isEmpty()) {
            throw new QuoteFlowException('The quote has no lines.');
        }
        Integer term = quote.Term_Months__c == null ? 12 : Integer.valueOf(quote.Term_Months__c);

        Savepoint savepoint = Database.setSavepoint();
        try {
            Order order = new Order(
                AccountId = quote.Account__c,
                OpportunityId = quote.Opportunity__c,
                Pricebook2Id = quote.Pricebook__c,
                Source_Quote__c = quote.Id,
                EffectiveDate = Date.today(),
                Status = 'Draft'
            );
            insert as user order;

            List<OrderItem> items = new List<OrderItem>();
            List<Subscription__c> subscriptions = new List<Subscription__c>();
            for (Quote_Line__c line : lines) {
                items.add(
                    new OrderItem(
                        OrderId = order.Id,
                        PricebookEntryId = line.Pricebook_Entry_Id__c,
                        Quantity = line.Quantity__c,
                        // Net_Total already includes term scaling, so the order carries the contract value per unit.
                        UnitPrice = (line.Net_Total__c / line.Quantity__c).setScale(2, RoundingMode.HALF_EVEN)
                    )
                );
                if (line.Billing_Model__c == QuoteConstants.BILLING_SUBSCRIPTION) {
                    subscriptions.add(
                        new Subscription__c(
                            Account__c = quote.Account__c,
                            Quote__c = quote.Id,
                            Product__c = line.Product__c,
                            Status__c = 'Pending Activation',
                            Quantity__c = line.Quantity__c,
                            Start_Date__c = Date.today(),
                            End_Date__c = Date.today().addMonths(term),
                            Annual_Recurring_Revenue__c = (line.Net_Unit_Price__c * line.Quantity__c)
                                .setScale(2, RoundingMode.HALF_EVEN)
                        )
                    );
                }
            }
            insert as user items;
            insert as user subscriptions;

            QuoteStateWriter.updateQuotes(
                new List<Quote__c>{ new Quote__c(Id = quote.Id, Status__c = QuoteConstants.STATUS_ORDERED) }
            );

            ConversionResult result = new ConversionResult();
            result.orderId = order.Id;
            result.subscriptionsCreated = subscriptions.size();
            return result;
        } catch (DmlException e) {
            Database.rollback(savepoint);
            // User-mode DML reports missing CRUD/FLS as a DmlException, so one handler covers both cases.
            throw new QuoteFlowException('Order creation failed: ' + e.getDmlMessage(0));
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        }
    }
}
