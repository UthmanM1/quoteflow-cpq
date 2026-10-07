/**
 * Converts exceptions into messages the lab LWCs can show. Business-rule and validation messages pass through;
 * anything unexpected is replaced by a generic message with a reference so internals never reach the browser.
 * (The main QuoteFlow layer persists such errors through Logger; the lab is kept self-contained and debug-logs them.)
 */
public inherited sharing class SalesAuraErrors {
    public static AuraHandledException wrap(Exception e) {
        String message;
        if (e instanceof SalesLabException) {
            message = e.getMessage();
        } else if (e instanceof DmlException) {
            message = ((DmlException) e).getDmlMessage(0);
        } else if (e instanceof QueryException || e instanceof System.NoAccessException) {
            message = 'You do not have access to the data required for this action.';
        } else {
            String reference = UUID.randomUUID().toString().left(8);
            System.debug(
                LoggingLevel.ERROR,
                '[' + reference + '] ' + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
            message =
                'Something went wrong. Please try again or contact your administrator (reference ' +
                reference +
                ').';
        }
        AuraHandledException wrapped = new AuraHandledException(message);
        wrapped.setMessage(message);
        return wrapped;
    }
}
