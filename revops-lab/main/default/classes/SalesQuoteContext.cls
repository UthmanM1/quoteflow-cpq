/**
 * Transaction-scoped flag that tells the lab triggers a service (approval, conversion) is writing status fields.
 * Private state, changed only through enter/restore pairs so a nested call cannot clear an outer caller's flag.
 */
public inherited sharing class SalesQuoteContext {
    private static Boolean serviceWrite = false;

    public static Boolean isServiceWrite {
        get {
            return serviceWrite;
        }
    }

    public static Boolean enterServiceWrite() {
        Boolean previous = serviceWrite;
        serviceWrite = true;
        return previous;
    }

    public static void restoreServiceWrite(Boolean previous) {
        serviceWrite = previous == true;
    }
}
