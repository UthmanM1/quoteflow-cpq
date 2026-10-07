/**
 * Runs the ERP callouts outside the transaction that queued them (callouts are not allowed after DML in the same
 * transaction). Runs as the user who enqueued it: the integration user for scheduled runs, or an administrator holding
 * Sales_Run_ERP_Sync for on-demand runs.
 */
public with sharing class SalesERPSyncQueueable implements Queueable, Database.AllowsCallouts {
    private final List<Id> orderIds;

    public SalesERPSyncQueueable(List<Id> orderIds) {
        this.orderIds = orderIds;
    }

    public void execute(QueueableContext context) {
        try {
            SalesERPIntegrationService.syncOrders(orderIds);
        } catch (Exception e) {
            // Per-order failures are handled in the service; this is systemic (configuration, access). Orders stay
            // Pending and are retried by the next scheduled run.
            System.debug(
                LoggingLevel.ERROR,
                'SalesERPSyncQueueable aborted: ' + e.getTypeName() + ': ' + e.getMessage()
            );
            SalesIntegrationLogService.Entry entry = new SalesIntegrationLogService.Entry();
            entry.integrationName = SalesERPIntegrationService.INTEGRATION_NAME;
            entry.outcome = SalesIntegrationLogService.OUTCOME_PERMANENT;
            entry.errorMessage = 'Worker aborted: ' + e.getTypeName() + ': ' + e.getMessage();
            SalesIntegrationLogService.record(entry);
            SalesIntegrationLogService.flush();
        }
    }
}
