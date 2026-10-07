/**
 * Hourly dispatcher for pending lab orders. Schedule it while logged in as the integration user so the queued jobs,
 * callouts and log rows run under that user's least-privilege permission set group:
 *
 *     System.schedule('RevOps Lab ERP Sync', '0 15 * * * ?', new SalesERPSyncSchedulable());
 */
public with sharing class SalesERPSyncSchedulable implements Schedulable {
    public void execute(SchedulableContext context) {
        try {
            SalesERPIntegrationService.dispatchDueOrders();
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                'RevOps Lab ERP dispatch failed: ' + e.getTypeName() + ': ' + e.getMessage()
            );
        }
    }
}
