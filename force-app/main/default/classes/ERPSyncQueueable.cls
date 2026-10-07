/**
 * Thin async wrapper so callouts run outside the scheduler transaction (which performs DML first).
 * Runs as the user who enqueued it, i.e. the integration user that owns ERPSyncScheduler.
 */
public with sharing class ERPSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> quoteIds;

    public ERPSyncQueueable(List<Id> quoteIds) {
        this.quoteIds = quoteIds;
    }

    public void execute(QueueableContext context) {
        try {
            ERPIntegrationService.syncQuotes(quoteIds);
        } catch (Exception e) {
            // Per-quote failures are handled inside the service. Reaching here means something systemic
            // (missing configuration, no access). Leased quotes are released when their lease expires.
            Integer leased = quoteIds == null ? 0 : quoteIds.size();
            Logger.error(
                'ERPSyncQueueable',
                'Worker aborted; ' + leased + ' leased quote(s) will be retried after the lease expires',
                e,
                null
            );
        }
    }
}
