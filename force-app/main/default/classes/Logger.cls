/**
 * Minimal, persistent application logger.
 *
 * Entries are published as Log_Event__e (Publish Immediately), so they are kept even when the transaction that
 * raised them rolls back - exactly the case where a log is most needed. LogEventTrigger persists them to
 * Application_Log__c. Every call also writes to the debug log for developers.
 *
 * Callers use the returned reference as the support id shown to the user (see AuraErrorFactory), which makes
 * "contact support (reference ab12cd34)" actionable: the reference is searchable on Application_Log__c.
 *
 * A logger must never break the business transaction, so publishing failures are swallowed.
 */
public inherited sharing class Logger {
    public static final String LEVEL_ERROR = 'ERROR';
    public static final String LEVEL_WARN = 'WARN';

    @TestVisible
    private static final Integer MAX_TEXT = 32000;

    /** Events published in this transaction; lets tests assert without depending on asynchronous delivery. */
    @TestVisible
    private static final List<Log_Event__e> PUBLISHED = new List<Log_Event__e>();

    public static String error(String source, String message, Exception e, Id relatedRecordId) {
        return publish(LEVEL_ERROR, source, message, e, relatedRecordId, true);
    }

    public static String error(String source, String message) {
        return publish(LEVEL_ERROR, source, message, null, null, true);
    }

    public static String warn(String source, String message, Id relatedRecordId) {
        return publish(LEVEL_WARN, source, message, null, relatedRecordId, true);
    }

    /** For read-only contexts (cacheable Aura methods): reference and debug log only, nothing is published. */
    public static String errorReadOnly(String source, String message, Exception e) {
        return publish(LEVEL_ERROR, source, message, e, null, false);
    }

    private static String publish(
        String level,
        String source,
        String message,
        Exception e,
        Id relatedRecordId,
        Boolean persist
    ) {
        String reference = UUID.randomUUID().toString().left(8);
        String fullMessage = message;
        if (e != null) {
            fullMessage = (String.isBlank(message) ? '' : message + ' | ') + e.getTypeName() + ': ' + e.getMessage();
        }
        System.debug(
            level == LEVEL_ERROR ? LoggingLevel.ERROR : LoggingLevel.WARN,
            '[' + reference + '] ' + source + ': ' + fullMessage
        );
        Log_Event__e event = new Log_Event__e(
            Level__c = level,
            Source__c = truncate(source, 255),
            Message__c = truncate(fullMessage, MAX_TEXT),
            Stack_Trace__c = e == null ? null : truncate(e.getStackTraceString(), MAX_TEXT),
            Reference__c = reference,
            Related_Record_Id__c = relatedRecordId == null ? null : String.valueOf(relatedRecordId),
            User_Id__c = UserInfo.getUserId()
        );
        // Publishing counts as a DML statement and a LimitException cannot be caught, so never publish when the
        // budget is spent or when the caller is a read-only context (@AuraEnabled(cacheable=true) forbids DML).
        if (!persist || Limits.getDmlStatements() >= Limits.getLimitDmlStatements()) {
            return reference;
        }
        PUBLISHED.add(event);
        try {
            Database.SaveResult result = EventBus.publish(event);
            if (!result.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'Log event not published: ' + result.getErrors()[0].getMessage());
            }
        } catch (Exception publishFailure) {
            // Includes the hourly publish allocation being exhausted. Never rethrow from a logger.
            System.debug(LoggingLevel.ERROR, 'Log event publish failed: ' + publishFailure.getMessage());
        }
        return reference;
    }

    private static String truncate(String value, Integer maxLength) {
        return value == null || value.length() <= maxLength ? value : value.left(maxLength);
    }
}
