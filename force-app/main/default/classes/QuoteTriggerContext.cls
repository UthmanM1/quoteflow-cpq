/**
 * Transaction-scoped switches shared by services and trigger handlers.
 *
 * Both switches have private state and are changed only through enter/restore pairs, so a caller can never
 * clear a flag that an outer caller raised. Service mode is entered exclusively by QuoteStateWriter, the single
 * elevated write path; tests that need it go through the writer as well.
 *
 * Honest limit: static state protects against UI, API, Flow and Data Loader callers, which cannot reach it.
 * It does not protect against other Apex running in the same org, which is system-mode code by definition;
 * that boundary is held by code review (see the PR checklist) rather than by the runtime.
 */
public inherited sharing class QuoteTriggerContext {
    private static Boolean serviceMode = false;
    private static Boolean repricingMode = false;

    /** True while QuoteStateWriter is writing system-owned fields (status, totals, approval and ERP state). */
    public static Boolean isServiceUpdate {
        get {
            return serviceMode;
        }
    }

    /** True while QuoteCalculationService re-prices existing lines; stops Quote_Line__c trigger re-entry. */
    public static Boolean isRepricing {
        get {
            return repricingMode;
        }
    }

    /** Raises service mode and returns the previous value, which must be passed to restoreServiceMode in a finally block. */
    public static Boolean enterServiceMode() {
        Boolean previous = serviceMode;
        serviceMode = true;
        return previous;
    }

    public static void restoreServiceMode(Boolean previous) {
        serviceMode = previous == true;
    }

    public static Boolean enterRepricing() {
        Boolean previous = repricingMode;
        repricingMode = true;
        return previous;
    }

    public static void restoreRepricing(Boolean previous) {
        repricingMode = previous == true;
    }
}
