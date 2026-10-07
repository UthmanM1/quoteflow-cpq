/**
 * Outbound REST/JSON integration that pushes converted lab orders to a FICTIONAL ERP ("Atlas ERP"). Named
 * SalesERPIntegrationService because the main QuoteFlow layer already owns ERPIntegrationService.
 *
 * What it demonstrates
 *   HTTP request         POST callout:Sales_ERP/api/v2/orders (Named Credential: no URL or secret in Apex or metadata)
 *   JSON                 typed request/response classes, JSON.serialize(obj, true) and JSON.deserialize with a guard
 *   Correlation id       a UUID per attempt, sent as X-Correlation-Id and in the body, stored on the log row
 *   Idempotency key      'sf-order-' + Order Id: every retry of the same order carries the same key
 *   Status handling      2xx/409 with an ERP order number = success; 408/429/5xx/timeouts = retryable;
 *                        other 4xx = permanent (needs a person, not another attempt)
 *   Retry                persisted on the Order (ERP_Retry_Count__c, ERP_Next_Retry_At__c) with exponential back-off;
 *                        Apex cannot sleep, so retries are scheduled, never looped
 *   Error logging        one Sales_Integration_Log__c row per attempt, flushed after all callouts
 *
 * Access: reads in user mode. The integration user has View All on Order but no record-level edit on orders it does
 * not own, so ERP bookkeeping is written by ErpStateWriter (without sharing) - after checking the user's FLS on exactly
 * the fields it writes. That is the only elevated write in the lab.
 */
public with sharing class SalesERPIntegrationService {
    public static final String INTEGRATION_NAME = 'Sales_ERP';
    private static final Integer TRANSACTION_BUDGET_MS = 100000;
    private static final Integer MAX_BACKOFF_MINUTES = 240;
    private static final Integer MAX_JOBS_PER_DISPATCH = 10;

    // ------------------------------------------------------------------ wire contract

    public class ErpOrderRequest {
        public String correlationId;
        public String salesforceOrderId;
        public String orderNumber;
        public String customerAccountNumber;
        public String purchaseOrderNumber;
        public String orderDate;
        public String currencyCode;
        public Decimal totalAmount;
        public List<ErpOrderLine> lines = new List<ErpOrderLine>();
    }

    public class ErpOrderLine {
        public Integer lineNumber;
        public String itemCode;
        public String description;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal lineTotal;
    }

    public class ErpOrderResponse {
        public String erpOrderNumber;
        public String status;
        public String errorCode;
        public String message;
    }

    public class SyncOutcome {
        public Id orderId;
        public Boolean success = false;
        public Boolean retryable = false;
        public Integer statusCode;
        public String erpOrderNumber;
        public String errorMessage;
        public String correlationId;
    }

    @TestVisible
    public class Settings {
        public String namedCredential = INTEGRATION_NAME;
        public String ordersPath = '/api/v2/orders';
        public Integer timeoutMs = 20000;
        public Integer maxRetries = 4;
        public Integer retryBaseMinutes = 5;
        public Integer batchSize = 5;
    }

    @TestVisible
    private static Settings settingsOverride;

    // ------------------------------------------------------------------ entry points

    /** On-demand sync for users holding Sales_Run_ERP_Sync (administrator, integration user). */
    public static Id requestSync(Set<Id> orderIds) {
        if (!FeatureManagement.checkPermission(SalesLabConstants.PERMISSION_RUN_ERP_SYNC)) {
            throw new SalesLabException('You do not have permission to run ERP synchronisation.');
        }
        List<Id> eligible = new List<Id>();
        for (Order order : SalesQuoteSelector.ordersForErp(orderIds).values()) {
            if (order.ERP_Sync_Status__c != SalesLabConstants.ERP_SYNCED) {
                eligible.add(order.Id);
            }
        }
        if (eligible.isEmpty()) {
            return null;
        }
        return System.enqueueJob(new SalesERPSyncQueueable(eligible));
    }

    /** Called by SalesERPSyncSchedulable (runs as the integration user). Returns the number of jobs enqueued. */
    public static Integer dispatchDueOrders() {
        Settings cfg = settings();
        List<Order> due = SalesQuoteSelector.ordersDueForErp(Datetime.now(), cfg.batchSize * MAX_JOBS_PER_DISPATCH);
        List<Id> ids = new List<Id>(new Map<Id, Order>(due).keySet());
        Integer jobs = 0;
        for (Integer start = 0; start < ids.size(); start += cfg.batchSize) {
            List<Id> chunk = new List<Id>();
            for (Integer i = start; i < Math.min(start + cfg.batchSize, ids.size()); i++) {
                chunk.add(ids[i]);
            }
            System.enqueueJob(new SalesERPSyncQueueable(chunk));
            jobs++;
        }
        return jobs;
    }

    /** All callouts first, then one write of order state and one flush of logs (no DML before a callout). */
    public static List<SyncOutcome> syncOrders(List<Id> orderIds) {
        Settings cfg = settings();
        Set<Id> idSet = new Set<Id>(orderIds);
        Map<Id, Order> orders = SalesQuoteSelector.ordersForErp(idSet);
        Map<Id, List<OrderItem>> itemsByOrder = new Map<Id, List<OrderItem>>();
        for (OrderItem item : SalesQuoteSelector.orderItemsForOrders(idSet)) {
            if (!itemsByOrder.containsKey(item.OrderId)) {
                itemsByOrder.put(item.OrderId, new List<OrderItem>());
            }
            itemsByOrder.get(item.OrderId).add(item);
        }

        Long started = System.currentTimeMillis();
        List<SyncOutcome> outcomes = new List<SyncOutcome>();
        for (Id orderId : orderIds) {
            Order order = orders.get(orderId);
            if (order == null || order.ERP_Sync_Status__c == SalesLabConstants.ERP_SYNCED) {
                continue;
            }
            Boolean outOfBudget =
                Limits.getCallouts() >= Limits.getLimitCallouts() ||
                (System.currentTimeMillis() - started) + cfg.timeoutMs > TRANSACTION_BUDGET_MS;
            if (outOfBudget) {
                break; // Remaining orders stay Pending and are picked up by the next run.
            }
            outcomes.add(syncOne(order, itemsByOrder.get(orderId), cfg));
        }
        ErpStateWriter.write(orders, outcomes, cfg);
        SalesIntegrationLogService.flush();
        return outcomes;
    }

    // ------------------------------------------------------------------ one order

    @TestVisible
    private static SyncOutcome syncOne(Order order, List<OrderItem> items, Settings cfg) {
        SyncOutcome outcome = new SyncOutcome();
        outcome.orderId = order.Id;
        outcome.correlationId = UUID.randomUUID().toString();
        SalesIntegrationLogService.Entry entry = new SalesIntegrationLogService.Entry();
        entry.correlationId = outcome.correlationId;
        entry.integrationName = INTEGRATION_NAME;
        entry.httpMethod = 'POST';
        entry.endpoint = 'callout:' + cfg.namedCredential + cfg.ordersPath;
        entry.attempt = (order.ERP_Retry_Count__c == null ? 0 : Integer.valueOf(order.ERP_Retry_Count__c)) + 1;
        entry.relatedRecordId = order.Id;

        Long started = System.currentTimeMillis();
        try {
            if (String.isBlank(order.Account.ERP_Account_Number__c)) {
                throw new SalesLabException('The account has no ERP account number.');
            }
            if (items == null || items.isEmpty()) {
                throw new SalesLabException('The order has no products.');
            }
            HttpRequest request = buildRequest(order, items, cfg, outcome.correlationId);
            entry.requestBody = request.getBody();
            HttpResponse response = new Http().send(request);
            entry.httpStatusCode = response.getStatusCode();
            entry.responseBody = response.getBody();
            classify(response, outcome);
        } catch (System.CalloutException e) {
            // Timeout or connection failure: the ERP may or may not have the order, which is why the key is idempotent.
            outcome.retryable = true;
            outcome.errorMessage = 'Callout failed: ' + e.getMessage();
        } catch (SalesLabException e) {
            outcome.errorMessage = e.getMessage();
        }
        entry.durationMs = System.currentTimeMillis() - started;
        entry.errorMessage = outcome.errorMessage;
        entry.outcome = outcome.success
            ? SalesIntegrationLogService.OUTCOME_SUCCESS
            : (outcome.retryable
                  ? SalesIntegrationLogService.OUTCOME_RETRYABLE
                  : SalesIntegrationLogService.OUTCOME_PERMANENT);
        outcome.statusCode = entry.httpStatusCode;
        SalesIntegrationLogService.record(entry);
        return outcome;
    }

    @TestVisible
    private static HttpRequest buildRequest(Order order, List<OrderItem> items, Settings cfg, String correlationId) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + cfg.namedCredential + cfg.ordersPath);
        request.setMethod('POST');
        request.setTimeout(cfg.timeoutMs);
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'application/json');
        request.setHeader('X-Correlation-Id', correlationId);
        request.setHeader('Idempotency-Key', 'sf-order-' + order.Id);
        request.setBody(JSON.serialize(toRequest(order, items, correlationId), true));
        return request;
    }

    @TestVisible
    private static ErpOrderRequest toRequest(Order order, List<OrderItem> items, String correlationId) {
        ErpOrderRequest payload = new ErpOrderRequest();
        payload.correlationId = correlationId;
        payload.salesforceOrderId = order.Id;
        payload.orderNumber = order.OrderNumber;
        payload.customerAccountNumber = order.Account.ERP_Account_Number__c;
        payload.purchaseOrderNumber = order.PoNumber;
        payload.orderDate = order.EffectiveDate == null ? null : String.valueOf(order.EffectiveDate);
        payload.currencyCode = UserInfo.getDefaultCurrency();
        payload.totalAmount = order.TotalAmount;
        Integer lineNumber = 1;
        for (OrderItem item : items) {
            ErpOrderLine line = new ErpOrderLine();
            line.lineNumber = lineNumber++;
            line.itemCode = String.isNotBlank(item.Product2.ERP_Item_Code__c)
                ? item.Product2.ERP_Item_Code__c
                : item.Product2.ProductCode;
            line.description = item.Product2.Name;
            line.quantity = item.Quantity;
            line.unitPrice = item.UnitPrice;
            line.lineTotal = item.TotalPrice;
            payload.lines.add(line);
        }
        return payload;
    }

    @TestVisible
    private static void classify(HttpResponse response, SyncOutcome outcome) {
        Integer code = response.getStatusCode();
        ErpOrderResponse parsed = parse(response.getBody());
        if ((code >= 200 && code < 300) || code == 409) {
            if (parsed != null && String.isNotBlank(parsed.erpOrderNumber)) {
                outcome.success = true; // 409 + order number = the ERP already has this order (idempotent replay).
                outcome.erpOrderNumber = parsed.erpOrderNumber;
            } else if (code == 409) {
                outcome.errorMessage = 'ERP reported a conflict without an order number.';
            } else {
                outcome.retryable = true; // Unknown outcome; safe to retry because the key is idempotent.
                outcome.errorMessage = 'ERP returned HTTP ' + code + ' without an order number.';
            }
            return;
        }
        String detail = parsed == null
            ? ''
            : ' ' +
              (parsed.errorCode == null ? '' : parsed.errorCode + ': ') +
              (parsed.message == null ? '' : parsed.message);
        outcome.errorMessage = ('ERP returned HTTP ' + code + '.' + detail).trim();
        outcome.retryable = code == 408 || code == 429 || code >= 500;
    }

    private static ErpOrderResponse parse(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            return (ErpOrderResponse) JSON.deserialize(body, ErpOrderResponse.class);
        } catch (JSONException e) {
            return null;
        }
    }

    @TestVisible
    private static Integer backoffMinutes(Integer retryCount, Settings cfg) {
        Integer exponent = Math.min(Math.max(retryCount - 1, 0), 8);
        return Math.min(cfg.retryBaseMinutes * (Integer) Math.pow(2, exponent), MAX_BACKOFF_MINUTES);
    }

    @TestVisible
    private static Settings settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        Sales_ERP_Setting__mdt setting = Sales_ERP_Setting__mdt.getInstance('Default');
        if (setting == null) {
            throw new SalesLabException('Sales_ERP_Setting__mdt "Default" is missing.');
        }
        Settings cfg = new Settings();
        cfg.namedCredential = setting.Named_Credential__c;
        cfg.ordersPath = setting.Orders_Path__c;
        cfg.timeoutMs = Integer.valueOf(setting.Timeout_Ms__c);
        cfg.maxRetries = Integer.valueOf(setting.Max_Retries__c);
        cfg.retryBaseMinutes = Integer.valueOf(setting.Retry_Base_Minutes__c);
        cfg.batchSize = Integer.valueOf(setting.Batch_Size__c);
        return cfg;
    }

    // ------------------------------------------------------------------ the only elevated write in the lab

    /**
     * Writes ERP bookkeeping on Order without sharing, because the integration user owns no orders. It refuses to run
     * unless the running user has edit FLS on every field it writes, so a user without the integration permission set
     * cannot use it to change orders.
     */
    @TestVisible
    private without sharing class ErpStateWriter {
        private void apply(Map<Id, Order> orders, List<SyncOutcome> outcomes, Settings cfg) {
            if (outcomes.isEmpty()) {
                return;
            }
            Map<String, Schema.SObjectField> fields = Schema.SObjectType.Order.fields.getMap();
            for (
                String name : new List<String>{
                    'ERP_Sync_Status__c',
                    'ERP_Order_Number__c',
                    'ERP_Retry_Count__c',
                    'ERP_Next_Retry_At__c',
                    'ERP_Last_Error__c'
                }
            ) {
                if (!fields.get(name).getDescribe().isUpdateable()) {
                    throw new SalesLabException(
                        'The running user cannot update Order.' + name + '; ERP state was not saved.'
                    );
                }
            }
            List<Order> updates = new List<Order>();
            Datetime now = Datetime.now();
            for (SyncOutcome outcome : outcomes) {
                Order order = orders.get(outcome.orderId);
                Integer retries =
                    (order.ERP_Retry_Count__c == null ? 0 : Integer.valueOf(order.ERP_Retry_Count__c)) + 1;
                Order update_ = new Order(Id = order.Id);
                if (outcome.success) {
                    update_.ERP_Sync_Status__c = SalesLabConstants.ERP_SYNCED;
                    update_.ERP_Order_Number__c = outcome.erpOrderNumber;
                    update_.ERP_Last_Error__c = null;
                    update_.ERP_Next_Retry_At__c = null;
                } else if (outcome.retryable && retries < cfg.maxRetries) {
                    update_.ERP_Sync_Status__c = SalesLabConstants.ERP_PENDING;
                    update_.ERP_Retry_Count__c = retries;
                    update_.ERP_Next_Retry_At__c = now.addMinutes(backoffMinutes(retries, cfg));
                    update_.ERP_Last_Error__c = outcome.errorMessage == null ? null : outcome.errorMessage.left(255);
                } else {
                    update_.ERP_Sync_Status__c = SalesLabConstants.ERP_FAILED;
                    update_.ERP_Retry_Count__c = retries;
                    update_.ERP_Next_Retry_At__c = null;
                    update_.ERP_Last_Error__c = outcome.errorMessage == null ? null : outcome.errorMessage.left(255);
                }
                updates.add(update_);
            }
            List<Database.SaveResult> results = Database.update(updates, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    // The ERP may already hold the order; the next run replays the same Idempotency-Key and heals this.
                    System.debug(
                        LoggingLevel.ERROR,
                        'ERP state not saved for ' + updates[i].Id + ': ' + results[i].getErrors()[0].getMessage()
                    );
                }
            }
        }

        private static void write(Map<Id, Order> orders, List<SyncOutcome> outcomes, Settings cfg) {
            new ErpStateWriter().apply(orders, outcomes, cfg);
        }
    }
}
