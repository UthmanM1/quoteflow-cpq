/**
 * Buffered, sanitised integration audit log.
 *
 * Logging is deliberately two-step (record, then flush). Apex forbids a callout after uncommitted DML, so
 * integration code collects entries while it calls out and flushes once at the end of the transaction.
 * A logging failure must never break the business transaction; it is reported through Logger instead.
 */
public with sharing class IntegrationLogService {
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_RETRYABLE = 'Retryable Failure';
    public static final String STATUS_PERMANENT = 'Permanent Failure';

    @TestVisible
    private static final Integer MAX_BODY_LENGTH = 100000;
    private static final Integer MAX_ERROR_LENGTH = 4000;
    private static final String TRUNCATION_MARKER = '...[truncated]';

    /** Redacts the value of any JSON property that looks like a credential. */
    private static final Pattern SENSITIVE_JSON_VALUE = Pattern.compile(
        '(?i)("(?:authorization|password|secret|client_secret|access_token|refresh_token|api[_-]?key|token)"\\s*:\\s*)"[^"]*"'
    );

    private static final List<Integration_Log__c> BUFFER = new List<Integration_Log__c>();

    public class Entry {
        public String correlationId;
        public String integrationName;
        public String direction = 'Outbound';
        public String status;
        public String httpMethod;
        public String endpoint;
        public Integer httpStatusCode;
        public Integer attempt;
        public Long durationMs;
        public Id relatedRecordId;
        public String requestBody;
        public String responseBody;
        public String errorMessage;
    }

    public static void record(Entry entry) {
        if (entry == null) {
            return;
        }
        BUFFER.add(
            new Integration_Log__c(
                Correlation_Id__c = entry.correlationId == null ? UUID.randomUUID().toString() : entry.correlationId,
                Integration_Name__c = entry.integrationName,
                Direction__c = entry.direction,
                Status__c = entry.status == null ? STATUS_SUCCESS : entry.status,
                Http_Method__c = entry.httpMethod,
                Endpoint__c = truncate(entry.endpoint, 255),
                Http_Status_Code__c = entry.httpStatusCode,
                Attempt__c = entry.attempt,
                Duration_Ms__c = entry.durationMs,
                Related_Record_Id__c = entry.relatedRecordId,
                Request_Body__c = sanitise(entry.requestBody),
                Response_Body__c = sanitise(entry.responseBody),
                Error_Message__c = truncate(entry.errorMessage, MAX_ERROR_LENGTH)
            )
        );
    }

    /** Persists buffered entries. Returns the number saved. Safe to call when the buffer is empty. */
    public static Integer flush() {
        if (BUFFER.isEmpty()) {
            return 0;
        }
        List<Integration_Log__c> pending = BUFFER.clone();
        BUFFER.clear();
        Integer saved = 0;
        try {
            List<Database.SaveResult> results = Database.insert(pending, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    saved++;
                } else {
                    Logger.warn(
                        'IntegrationLogService.flush',
                        'Integration log not saved (' +
                            pending[i].Correlation_Id__c +
                            '): ' +
                            results[i].getErrors()[0].getMessage(),
                        null
                    );
                }
            }
        } catch (Exception e) {
            // Includes missing CRUD/FLS in user mode. Never rethrow from a logger.
            Logger.error('IntegrationLogService.flush', 'Integration log flush failed', e, null);
        }
        return saved;
    }

    @TestVisible
    private static Integer bufferedCount() {
        return BUFFER.size();
    }

    @TestVisible
    private static String sanitise(String body) {
        if (String.isBlank(body)) {
            return body;
        }
        String redacted = SENSITIVE_JSON_VALUE.matcher(body).replaceAll('$1"***"');
        return truncate(redacted, MAX_BODY_LENGTH);
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.left(maxLength - TRUNCATION_MARKER.length()) + TRUNCATION_MARKER;
    }
}
