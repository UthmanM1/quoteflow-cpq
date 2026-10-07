/**
 * Buffered, sanitised log of ERP calls (Sales_Integration_Log__c). Named SalesIntegrationLogService because the main
 * QuoteFlow layer already owns IntegrationLogService.
 *
 * Two steps on purpose: Apex forbids a callout after uncommitted DML, so callers record entries while they call out
 * and flush once afterwards. A logging failure never breaks the business transaction.
 */
public with sharing class SalesIntegrationLogService {
    public static final String OUTCOME_SUCCESS = 'Success';
    public static final String OUTCOME_RETRYABLE = 'Retryable Failure';
    public static final String OUTCOME_PERMANENT = 'Permanent Failure';

    @TestVisible
    private static final Integer MAX_BODY_LENGTH = 100000;
    private static final Integer MAX_ERROR_LENGTH = 4000;

    /** Redacts the value of any JSON property whose name looks like a credential. */
    private static final Pattern SENSITIVE = Pattern.compile(
        '(?i)("(?:authorization|password|secret|client_secret|access_token|refresh_token|api[_-]?key|token)"\\s*:\\s*)"[^"]*"'
    );

    private static final List<Sales_Integration_Log__c> BUFFER = new List<Sales_Integration_Log__c>();

    public class Entry {
        public String correlationId;
        public String integrationName;
        public String httpMethod;
        public String endpoint;
        public Integer httpStatusCode;
        public String outcome;
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
            new Sales_Integration_Log__c(
                Correlation_Id__c = entry.correlationId,
                Integration_Name__c = entry.integrationName,
                Direction__c = 'Outbound',
                Http_Method__c = entry.httpMethod,
                Endpoint__c = truncate(entry.endpoint, 255),
                Http_Status_Code__c = entry.httpStatusCode,
                Outcome__c = entry.outcome == null ? OUTCOME_SUCCESS : entry.outcome,
                Attempt__c = entry.attempt,
                Duration_Ms__c = entry.durationMs,
                Related_Record_Id__c = entry.relatedRecordId,
                Request_Body__c = sanitise(entry.requestBody),
                Response_Body__c = sanitise(entry.responseBody),
                Error_Message__c = truncate(entry.errorMessage, MAX_ERROR_LENGTH)
            )
        );
    }

    /** Inserts buffered entries in user mode. Returns the number saved; never throws. */
    public static Integer flush() {
        if (BUFFER.isEmpty()) {
            return 0;
        }
        List<Sales_Integration_Log__c> pending = BUFFER.clone();
        BUFFER.clear();
        Integer saved = 0;
        try {
            for (Database.SaveResult result : Database.insert(pending, false, AccessLevel.USER_MODE)) {
                if (result.isSuccess()) {
                    saved++;
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        'Integration log not saved: ' + result.getErrors()[0].getMessage()
                    );
                }
            }
        } catch (Exception e) {
            // Includes a running user without create access to the log object.
            System.debug(LoggingLevel.ERROR, 'Integration log flush failed: ' + e.getMessage());
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
        return truncate(SENSITIVE.matcher(body).replaceAll('$1"***"'), MAX_BODY_LENGTH);
    }

    private static String truncate(String value, Integer maxLength) {
        return value == null || value.length() <= maxLength ? value : value.left(maxLength);
    }
}
