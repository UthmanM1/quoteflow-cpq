/**
 * Outbound REST/JSON integration with the (fictional) ERP "Atlas ERP" sales-order API.
 *
 * Flow
 *   QuoteApprovalService marks an approved quote ERP_Sync_Status__c = Pending
 *   -> ERPSyncScheduler (runs as the integration user) calls dispatchDueQuotes()
 *   -> claimDueQuotes() leases the quotes (In Progress) in its own transaction
 *   -> ERPSyncQueueable calls syncQuotes(), the only place that performs callouts
 *
 * Authentication is never handled in Apex. The request targets callout:ERP_Gateway, a Named Credential
 * backed by an External Credential (OAuth 2.0 client credentials). The platform injects and refreshes
 * the bearer token; this class never sees a secret.
 *
 * Retries are persisted rather than looped: a transient failure schedules the next attempt on the quote
 * (ERP_Next_Attempt_At__c) with exponential backoff, because Apex cannot sleep and a retry loop would burn
 * the 120 second callout budget. Every request carries an Idempotency-Key derived from the quote and its sync
 * generation, so a retry after a lost response cannot create a second ERP order, while an operator requeue (new
 * generation) is not answered with the ERP's cached failure.
 *
 * Security: reads run in user mode as the integration user (View All on Quote__c is how it finds work). It owns no
 * quotes and has no record-level edit access, so lease and outcome bookkeeping - ERP fields only - is written
 * through QuoteStateWriter. Failed writes are never silently ignored: a lease that did not persist is not
 * dispatched, and an outcome that did not persist is logged (the next attempt replays the same key and heals it).
 */
public with sharing class ERPIntegrationService {
    public static final String INTEGRATION_NAME = 'ERP_Gateway';
    @TestVisible
    private static final Integer LEASE_MINUTES = 15;
    @TestVisible
    private static final Integer MAX_BACKOFF_MINUTES = 60;
    private static final Integer TRANSACTION_BUDGET_MS = 110000;
    private static final Integer MAX_JOBS_PER_DISPATCH = 10;
    private static final String CURRENCY_CODE = 'USD';

    // ------------------------------------------------------------------ wire contracts

    public class OrderRequest {
        public String correlationId;
        public String quoteId;
        public String quoteNumber;
        public String customerId;
        public String currencyCode;
        public Integer termMonths;
        public Decimal totalNetAmount;
        public String validUntil;
        public List<OrderLine> lines = new List<OrderLine>();
    }

    public class OrderLine {
        public Integer lineNumber;
        public String sku;
        public String description;
        public Decimal quantity;
        public Decimal unitPrice;
        public Decimal discountPct;
        public Decimal lineTotal;
        public String billingModel;
        public Boolean includedInBundle;
    }

    public class OrderResponse {
        public String orderId;
        public String status;
        public String message;
        public String errorCode;
    }

    public class SyncOutcome {
        public Id quoteId;
        public Boolean success = false;
        public Boolean retryable = false;
        public Boolean deferred = false;
        public Integer statusCode;
        public String erpOrderId;
        public String errorMessage;
        public String correlationId;
        public Integer retryAfterSeconds;
    }

    @TestVisible
    public class Config {
        public String namedCredential = INTEGRATION_NAME;
        public String ordersPath = '/v1/sales-orders';
        public Integer timeoutMs = 20000;
        public Integer maxAttempts = 5;
        public Integer retryBaseDelayMinutes = 2;
        public Integer batchSize = 5;
    }

    @TestVisible
    private static Config configOverride;

    // ------------------------------------------------------------------ dispatch (no callouts)

    /** Called by the scheduler. Leases due quotes and hands them to queueable jobs in batch-size chunks. */
    public static Integer dispatchDueQuotes() {
        Config cfg = config();
        List<Id> claimed = claimDueQuotes(cfg);
        Integer jobs = 0;
        for (Integer start = 0; start < claimed.size() && jobs < MAX_JOBS_PER_DISPATCH; start += cfg.batchSize) {
            Integer finish = Math.min(start + cfg.batchSize, claimed.size());
            System.enqueueJob(new ERPSyncQueueable(slice(claimed, start, finish)));
            jobs++;
        }
        return jobs;
    }

    /** Leases due quotes. Only quotes whose lease was actually written are returned for dispatch. */
    @TestVisible
    private static List<Id> claimDueQuotes(Config cfg) {
        Datetime now = Datetime.now();
        List<Quote__c> due = QuoteSelector.quotesDueForErpSync(now, cfg.batchSize * MAX_JOBS_PER_DISPATCH);
        List<Quote__c> updates = new List<Quote__c>();
        for (Quote__c quote : due) {
            Integer attempt =
                (quote.ERP_Sync_Attempts__c == null ? 0 : Integer.valueOf(quote.ERP_Sync_Attempts__c)) + 1;
            if (attempt > cfg.maxAttempts) {
                // A lease that expired repeatedly means the worker keeps dying; stop rather than loop forever.
                updates.add(
                    new Quote__c(
                        Id = quote.Id,
                        ERP_Sync_Status__c = QuoteConstants.ERP_FAILED,
                        ERP_Next_Attempt_At__c = null,
                        ERP_Last_Error__c = 'Abandoned after ' +
                            cfg.maxAttempts +
                            ' attempts (worker did not complete).'
                    )
                );
                continue;
            }
            updates.add(
                new Quote__c(
                    Id = quote.Id,
                    ERP_Sync_Status__c = QuoteConstants.ERP_IN_PROGRESS,
                    ERP_Sync_Attempts__c = attempt,
                    ERP_Next_Attempt_At__c = now.addMinutes(LEASE_MINUTES)
                )
            );
        }
        List<Id> claimed = new List<Id>();
        List<Database.SaveResult> results = QuoteStateWriter.updateQuotesPartial(updates);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Logger.error(
                    'ERPIntegrationService.claimDueQuotes',
                    'Lease not written; quote not dispatched: ' + results[i].getErrors()[0].getMessage(),
                    null,
                    updates[i].Id
                );
            } else if (updates[i].ERP_Sync_Status__c == QuoteConstants.ERP_IN_PROGRESS) {
                claimed.add(updates[i].Id);
            }
        }
        return claimed;
    }

    /**
     * Operations tool: puts permanently failed quotes back in the queue after the cause has been fixed.
     * Starts a new sync generation, i.e. a new Idempotency-Key, because the ERP would otherwise replay its stored
     * failure for the old key. Requires the QF_Requeue_ERP_Sync custom permission.
     */
    public static Integer requeueFailed(Set<Id> quoteIds) {
        if (!FeatureManagement.checkPermission(QuoteConstants.REQUEUE_ERP_PERMISSION)) {
            throw new QuoteFlowException('You do not have permission to requeue ERP synchronisation.');
        }
        List<Quote__c> updates = new List<Quote__c>();
        for (Quote__c quote : QuoteSelector.quotesForErp(quoteIds)) {
            if (
                quote.ERP_Sync_Status__c == QuoteConstants.ERP_FAILED &&
                QuoteConstants.ERP_SYNCABLE_STATUSES.contains(quote.Status__c)
            ) {
                updates.add(
                    new Quote__c(
                        Id = quote.Id,
                        ERP_Sync_Status__c = QuoteConstants.ERP_PENDING,
                        ERP_Sync_Attempts__c = 0,
                        ERP_Sync_Generation__c = generation(quote) + 1,
                        ERP_Next_Attempt_At__c = null,
                        ERP_Last_Error__c = null
                    )
                );
            }
        }
        Integer requeued = 0;
        List<Database.SaveResult> results = QuoteStateWriter.updateQuotesPartial(updates);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                requeued++;
            } else {
                Logger.error(
                    'ERPIntegrationService.requeueFailed',
                    results[i].getErrors()[0].getMessage(),
                    null,
                    updates[i].Id
                );
            }
        }
        return requeued;
    }

    // ------------------------------------------------------------------ sync (callouts, then DML)

    /**
     * Sends each leased quote to the ERP. All callouts happen first; quote state and log rows are written
     * afterwards, because DML before a callout would raise "uncommitted work pending".
     */
    public static List<SyncOutcome> syncQuotes(List<Id> quoteIds) {
        Config cfg = config();
        Set<Id> idSet = new Set<Id>(quoteIds);
        Map<Id, Quote__c> quotes = new Map<Id, Quote__c>(QuoteSelector.quotesForErp(idSet));
        Map<Id, List<Quote_Line__c>> linesByQuote = new Map<Id, List<Quote_Line__c>>();
        for (Quote_Line__c line : QuoteSelector.linesForQuotes(idSet)) {
            if (!linesByQuote.containsKey(line.Quote__c)) {
                linesByQuote.put(line.Quote__c, new List<Quote_Line__c>());
            }
            linesByQuote.get(line.Quote__c).add(line);
        }

        Long started = System.currentTimeMillis();
        List<SyncOutcome> outcomes = new List<SyncOutcome>();
        for (Id quoteId : quoteIds) {
            Quote__c quote = quotes.get(quoteId);
            if (
                quote == null ||
                quote.ERP_Sync_Status__c != QuoteConstants.ERP_IN_PROGRESS ||
                !QuoteConstants.ERP_SYNCABLE_STATUSES.contains(quote.Status__c)
            ) {
                continue; // Already handled by another run, or no longer eligible.
            }
            Boolean outOfBudget =
                Limits.getCallouts() >= Limits.getLimitCallouts() ||
                (System.currentTimeMillis() - started) + cfg.timeoutMs > TRANSACTION_BUDGET_MS;
            outcomes.add(outOfBudget ? deferred(quote) : syncOne(quote, linesByQuote.get(quoteId), cfg));
        }
        applyOutcomes(quotes, outcomes, cfg);
        IntegrationLogService.flush();
        return outcomes;
    }

    @TestVisible
    private static SyncOutcome syncOne(Quote__c quote, List<Quote_Line__c> lines, Config cfg) {
        SyncOutcome outcome = new SyncOutcome();
        outcome.quoteId = quote.Id;
        outcome.correlationId = UUID.randomUUID().toString();
        Integer attempt = quote.ERP_Sync_Attempts__c == null ? 1 : Integer.valueOf(quote.ERP_Sync_Attempts__c);

        IntegrationLogService.Entry entry = new IntegrationLogService.Entry();
        entry.correlationId = outcome.correlationId;
        entry.integrationName = INTEGRATION_NAME;
        entry.httpMethod = 'POST';
        entry.endpoint = 'callout:' + cfg.namedCredential + cfg.ordersPath;
        entry.attempt = attempt;
        entry.relatedRecordId = quote.Id;

        Long started = System.currentTimeMillis();
        try {
            if (String.isBlank(quote.Account__r.ERP_Customer_Id__c)) {
                throw new QuoteFlowException(
                    'Account has no ERP customer id. Set it on the account and requeue the quote.'
                );
            }
            if (lines == null || lines.isEmpty()) {
                throw new QuoteFlowException('Quote has no lines to send.');
            }
            HttpRequest request = buildRequest(quote, lines, cfg, outcome.correlationId);
            entry.requestBody = request.getBody();

            HttpResponse response = new Http().send(request);
            entry.durationMs = System.currentTimeMillis() - started;
            entry.httpStatusCode = response.getStatusCode();
            entry.responseBody = response.getBody();
            classify(response, outcome);
        } catch (System.CalloutException e) {
            // Covers timeouts and connection failures; the ERP may or may not have received the request,
            // which is exactly why the Idempotency-Key exists.
            outcome.retryable = true;
            outcome.errorMessage = 'Callout failed: ' + e.getMessage();
        } catch (QuoteFlowException e) {
            outcome.errorMessage = e.getMessage();
        } catch (Exception e) {
            outcome.errorMessage =
                'Unexpected error building or sending request: ' +
                e.getTypeName() +
                ': ' +
                e.getMessage();
        }

        entry.durationMs = entry.durationMs == null ? System.currentTimeMillis() - started : entry.durationMs;
        entry.errorMessage = outcome.errorMessage;
        entry.status = outcome.success
            ? IntegrationLogService.STATUS_SUCCESS
            : (outcome.retryable ? IntegrationLogService.STATUS_RETRYABLE : IntegrationLogService.STATUS_PERMANENT);
        outcome.statusCode = entry.httpStatusCode;
        IntegrationLogService.record(entry);
        return outcome;
    }

    @TestVisible
    private static HttpRequest buildRequest(
        Quote__c quote,
        List<Quote_Line__c> lines,
        Config cfg,
        String correlationId
    ) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + cfg.namedCredential + cfg.ordersPath);
        request.setMethod('POST');
        request.setTimeout(cfg.timeoutMs);
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'application/json');
        request.setHeader('X-Correlation-Id', correlationId);
        request.setHeader('Idempotency-Key', idempotencyKey(quote));
        request.setHeader('X-Source-System', 'QuoteFlow');
        request.setBody(JSON.serialize(toOrderRequest(quote, lines, correlationId), true));
        return request;
    }

    /** Stable across retries of one generation; changes only when an operator requeues the quote. */
    @TestVisible
    private static String idempotencyKey(Quote__c quote) {
        return 'qf-quote-' + quote.Id + '-g' + generation(quote);
    }

    private static Integer generation(Quote__c quote) {
        return quote.ERP_Sync_Generation__c == null ||
            quote.ERP_Sync_Generation__c < 1
            ? 1
            : Integer.valueOf(quote.ERP_Sync_Generation__c);
    }

    @TestVisible
    private static OrderRequest toOrderRequest(Quote__c quote, List<Quote_Line__c> lines, String correlationId) {
        OrderRequest payload = new OrderRequest();
        payload.correlationId = correlationId;
        payload.quoteId = quote.Id;
        payload.quoteNumber = quote.Name;
        payload.customerId = quote.Account__r.ERP_Customer_Id__c;
        payload.currencyCode = CURRENCY_CODE;
        payload.termMonths = quote.Term_Months__c == null ? null : Integer.valueOf(quote.Term_Months__c);
        payload.totalNetAmount = quote.Net_Amount__c;
        payload.validUntil = quote.Valid_Until__c == null ? null : String.valueOf(quote.Valid_Until__c);
        Integer lineNumber = 1;
        for (Quote_Line__c line : lines) {
            OrderLine item = new OrderLine();
            item.lineNumber = lineNumber++;
            item.sku = String.isNotBlank(line.Product__r.ERP_SKU__c)
                ? line.Product__r.ERP_SKU__c
                : line.Product__r.ProductCode;
            item.description = line.Product__r.Name;
            item.quantity = line.Quantity__c;
            item.unitPrice = line.Net_Unit_Price__c;
            item.discountPct = line.Effective_Discount_Pct__c;
            item.lineTotal = line.Net_Total__c;
            item.billingModel = line.Billing_Model__c;
            item.includedInBundle = line.Is_Included__c == true;
            payload.lines.add(item);
        }
        return payload;
    }

    /**
     * HTTP status policy
     *   200/201/202 with orderId  success
     *   409 with orderId          success (idempotent replay of an order we already created)
     *   408, 429, 5xx             retryable; 429 honours Retry-After
     *   other 4xx (400, 401, 403, 404, 422 ...) permanent; needs a human, not another attempt
     *   2xx without a usable body retryable (safe because of the idempotency key)
     */
    @TestVisible
    private static void classify(HttpResponse response, SyncOutcome outcome) {
        Integer code = response.getStatusCode();
        if (code == 200 || code == 201 || code == 202 || code == 409) {
            OrderResponse parsed = parse(response.getBody());
            if (parsed != null && String.isNotBlank(parsed.orderId)) {
                outcome.success = true;
                outcome.erpOrderId = parsed.orderId;
            } else if (code == 409) {
                outcome.errorMessage = 'ERP reported a conflict without an order id.';
            } else {
                outcome.retryable = true;
                outcome.errorMessage = 'ERP returned ' + code + ' without a usable order id.';
            }
            return;
        }
        OrderResponse failure = parse(response.getBody());
        String detail = failure == null
            ? ''
            : ' ' +
              (failure.errorCode == null ? '' : failure.errorCode + ': ') +
              (failure.message == null ? '' : failure.message);
        outcome.errorMessage = ('ERP returned HTTP ' + code + '.' + detail).trim();
        if (code == 408 || code == 429 || code >= 500) {
            outcome.retryable = true;
            String retryAfter = response.getHeader('Retry-After');
            if (code == 429 && retryAfter != null && retryAfter.isNumeric()) {
                outcome.retryAfterSeconds = Integer.valueOf(retryAfter);
            }
        }
    }

    private static OrderResponse parse(String body) {
        if (String.isBlank(body)) {
            return null;
        }
        try {
            return (OrderResponse) JSON.deserialize(body, OrderResponse.class);
        } catch (JSONException e) {
            return null;
        }
    }

    private static SyncOutcome deferred(Quote__c quote) {
        SyncOutcome outcome = new SyncOutcome();
        outcome.quoteId = quote.Id;
        outcome.retryable = true;
        outcome.deferred = true;
        outcome.errorMessage = 'Deferred: transaction callout budget exhausted.';
        return outcome;
    }

    // ------------------------------------------------------------------ persisting results

    @TestVisible
    private static void applyOutcomes(Map<Id, Quote__c> quotes, List<SyncOutcome> outcomes, Config cfg) {
        Datetime now = Datetime.now();
        List<Quote__c> updates = new List<Quote__c>();
        for (SyncOutcome outcome : outcomes) {
            Quote__c quote = quotes.get(outcome.quoteId);
            Integer attempt = quote.ERP_Sync_Attempts__c == null ? 1 : Integer.valueOf(quote.ERP_Sync_Attempts__c);
            Quote__c update_ = new Quote__c(Id = quote.Id);
            if (outcome.success) {
                update_.ERP_Sync_Status__c = QuoteConstants.ERP_SYNCED;
                update_.ERP_Order_Id__c = outcome.erpOrderId;
                update_.ERP_Last_Sync__c = now;
                update_.ERP_Last_Error__c = null;
                update_.ERP_Next_Attempt_At__c = null;
            } else if (outcome.deferred) {
                update_.ERP_Sync_Status__c = QuoteConstants.ERP_PENDING;
                update_.ERP_Sync_Attempts__c = Math.max(attempt - 1, 0);
                update_.ERP_Next_Attempt_At__c = now;
            } else if (outcome.retryable && attempt < cfg.maxAttempts) {
                update_.ERP_Sync_Status__c = QuoteConstants.ERP_PENDING;
                update_.ERP_Next_Attempt_At__c = now.addMinutes(
                    retryDelayMinutes(attempt, cfg, outcome.retryAfterSeconds)
                );
                update_.ERP_Last_Error__c = shorten(outcome.errorMessage);
            } else {
                update_.ERP_Sync_Status__c = QuoteConstants.ERP_FAILED;
                update_.ERP_Next_Attempt_At__c = null;
                update_.ERP_Last_Error__c = shorten(outcome.errorMessage);
            }
            updates.add(update_);
        }
        if (updates.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = QuoteStateWriter.updateQuotesPartial(updates);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                // The ERP may already hold the order. The lease expires, the next attempt replays the same
                // Idempotency-Key and the ERP answers 409 with the original order id, which heals this.
                Logger.error(
                    'ERPIntegrationService.applyOutcomes',
                    'ERP outcome not persisted (' +
                        (outcomes[i].success ? 'success ' + outcomes[i].erpOrderId : 'failure') +
                        '): ' +
                        results[i].getErrors()[0].getMessage(),
                    null,
                    updates[i].Id
                );
            }
        }
    }

    /** base * 2^(attempt - 1), capped; a 429 Retry-After longer than the backoff wins. */
    @TestVisible
    private static Integer retryDelayMinutes(Integer attempt, Config cfg, Integer retryAfterSeconds) {
        Integer exponent = Math.min(Math.max(attempt - 1, 0), 10);
        Integer backoff = Math.min(cfg.retryBaseDelayMinutes * (Integer) Math.pow(2, exponent), MAX_BACKOFF_MINUTES);
        Integer retryAfterMinutes = retryAfterSeconds == null ? 0 : (Integer) Math.ceil(retryAfterSeconds / 60.0);
        return Math.max(backoff, retryAfterMinutes);
    }

    // ------------------------------------------------------------------ helpers

    @TestVisible
    private static Config config() {
        if (configOverride != null) {
            return configOverride;
        }
        ERP_Integration_Setting__mdt setting = ERP_Integration_Setting__mdt.getInstance('Default');
        if (setting == null) {
            throw new QuoteFlowException('ERP_Integration_Setting__mdt "Default" is missing.');
        }
        Config cfg = new Config();
        cfg.namedCredential = setting.Named_Credential__c;
        cfg.ordersPath = setting.Orders_Path__c;
        cfg.timeoutMs = Integer.valueOf(setting.Timeout_Ms__c);
        cfg.maxAttempts = Integer.valueOf(setting.Max_Attempts__c);
        cfg.retryBaseDelayMinutes = Integer.valueOf(setting.Retry_Base_Delay_Minutes__c);
        cfg.batchSize = Integer.valueOf(setting.Batch_Size__c);
        return cfg;
    }

    private static List<Id> slice(List<Id> source, Integer start, Integer finish) {
        List<Id> part = new List<Id>();
        for (Integer i = start; i < finish; i++) {
            part.add(source[i]);
        }
        return part;
    }

    private static String shorten(String message) {
        return message == null || message.length() <= 255 ? message : message.left(252) + '...';
    }
}
