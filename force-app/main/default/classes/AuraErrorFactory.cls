/**
 * Translates exceptions into AuraHandledExceptions the LWCs can display.
 * Business-rule and DML validation messages are user-actionable and pass through; anything else is logged through
 * Logger (persisted, survives rollback) and replaced with its reference so internals (query text, stack traces)
 * never reach the browser while support can still find the full error on Application_Log__c.
 */
public inherited sharing class AuraErrorFactory {
    public static AuraHandledException wrap(Exception e) {
        return wrap(e, true);
    }

    /** Use from @AuraEnabled(cacheable=true) methods, which may not publish events (no DML in cacheable reads). */
    public static AuraHandledException wrapReadOnly(Exception e) {
        return wrap(e, false);
    }

    private static AuraHandledException wrap(Exception e, Boolean canPersist) {
        String message;
        if (e instanceof QuoteFlowException) {
            message = e.getMessage();
        } else if (e instanceof DmlException) {
            message = ((DmlException) e).getDmlMessage(0);
        } else if (e instanceof QueryException || e instanceof System.NoAccessException) {
            String reference = canPersist
                ? Logger.warn(
                      'AuraErrorFactory',
                      'Access or query failure: ' + e.getTypeName() + ': ' + e.getMessage(),
                      null
                  )
                : Logger.errorReadOnly('AuraErrorFactory', 'Access or query failure', e);
            message = 'You do not have access to the data required for this action (reference ' + reference + ').';
        } else {
            String reference = canPersist
                ? Logger.error('AuraErrorFactory', 'Unexpected error in a Lightning controller', e, null)
                : Logger.errorReadOnly('AuraErrorFactory', 'Unexpected error in a cacheable Lightning read', e);
            message = 'Something went wrong. Please try again or contact support (reference ' + reference + ').';
        }
        AuraHandledException wrapped = new AuraHandledException(message);
        // Without this the client receives the generic "Script-thrown exception" text.
        wrapped.setMessage(message);
        return wrapped;
    }
}
