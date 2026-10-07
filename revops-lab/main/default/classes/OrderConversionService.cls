/**
 * Converts an approved lab quote into a standard Order with OrderItems, one Sales_Subscription__c per annual line,
 * and queues the order for ERP synchronisation. All-or-nothing.
 *
 * Access model
 *   Order and OrderItem   created in USER MODE: creating orders is a normal sales action, so the caller's object and
 *                         field permissions apply (reps hold Order create in Sales_Representative_Access).
 *   Sales_Subscription__c created with plain DML (system mode for CRUD/FLS, sharing still enforced): subscriptions are
 *                         derived data, and reps are deliberately read-only on them.
 *   Quote status, Order__c and the order's ERP status are system-owned fields, also written with plain DML.
 */
public with sharing class OrderConversionService {
    public class ConversionResult {
        @AuraEnabled
        public Id orderId;
        @AuraEnabled
        public Integer orderItemsCreated = 0;
        @AuraEnabled
        public Integer subscriptionsCreated = 0;
    }

    public static ConversionResult convert(Id quoteId, String customerPoNumber) {
        Quote_Configuration__c quote = SalesQuoteSelector.quotesForUpdate(new Set<Id>{ quoteId }).get(quoteId);
        if (quote == null) {
            throw new SalesLabException('Quote not found or you do not have access to it.');
        }
        if (
            quote.OwnerId != UserInfo.getUserId() &&
            !FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_OVERRIDE_LOCK)
        ) {
            throw new SalesLabException('Only the quote owner can convert it to an order.');
        }
        if (quote.Status__c != SalesLabConstants.QUOTE_APPROVED) {
            throw new SalesLabException(
                'Only approved quotes can be converted (current status: ' + quote.Status__c + ').'
            );
        }
        String poNumber = String.isNotBlank(customerPoNumber) ? customerPoNumber.trim() : quote.Customer_PO_Number__c;
        if (String.isBlank(poNumber)) {
            throw new SalesLabException('Enter the customer PO number before converting the quote.');
        }
        List<Quote_Configuration_Line__c> lines = SalesQuoteSelector.linesForQuotes(new Set<Id>{ quoteId });
        if (lines.isEmpty()) {
            throw new SalesLabException('The quote has no lines.');
        }
        Integer termMonths = quote.Term_Months__c == null ? 12 : Integer.valueOf(quote.Term_Months__c);
        Date startDate = Date.today();

        Savepoint savepoint = Database.setSavepoint();
        Boolean previous = SalesQuoteContext.enterServiceWrite();
        try {
            Order order = new Order(
                AccountId = quote.Account__c,
                OpportunityId = quote.Opportunity__c,
                Pricebook2Id = quote.Price_Book__c,
                EffectiveDate = startDate,
                Status = 'Draft',
                PoNumber = poNumber,
                Quote_Configuration__c = quote.Id
            );
            insert as user order;

            List<OrderItem> items = new List<OrderItem>();
            List<Sales_Subscription__c> subscriptions = new List<Sales_Subscription__c>();
            for (Quote_Configuration_Line__c line : lines) {
                items.add(
                    new OrderItem(
                        OrderId = order.Id,
                        PricebookEntryId = line.Price_Book_Entry_Id__c,
                        Quantity = line.Quantity__c,
                        UnitPrice = line.Net_Unit_Price__c
                    )
                );
                if (line.Billing_Frequency__c == SalesLabConstants.BILLING_ANNUAL) {
                    subscriptions.add(
                        new Sales_Subscription__c(
                            Account__c = quote.Account__c,
                            Product__c = line.Product__c,
                            Order__c = order.Id,
                            Quote_Configuration__c = quote.Id,
                            Quantity__c = line.Quantity__c,
                            Annual_Value__c = line.Net_Total__c,
                            Start_Date__c = startDate,
                            End_Date__c = startDate.addMonths(termMonths),
                            Status__c = 'Pending Activation'
                        )
                    );
                }
            }
            insert as user items;
            insert subscriptions;

            update new Quote_Configuration__c(
                Id = quote.Id,
                Status__c = SalesLabConstants.QUOTE_ORDERED,
                Order__c = order.Id,
                Customer_PO_Number__c = poNumber
            );
            update new Order(Id = order.Id, ERP_Sync_Status__c = SalesLabConstants.ERP_PENDING, ERP_Retry_Count__c = 0);

            ConversionResult result = new ConversionResult();
            result.orderId = order.Id;
            result.orderItemsCreated = items.size();
            result.subscriptionsCreated = subscriptions.size();
            return result;
        } catch (DmlException e) {
            Database.rollback(savepoint);
            throw new SalesLabException('Order creation failed: ' + e.getDmlMessage(0));
        } catch (Exception e) {
            Database.rollback(savepoint);
            throw e;
        } finally {
            SalesQuoteContext.restoreServiceWrite(previous);
        }
    }
}
