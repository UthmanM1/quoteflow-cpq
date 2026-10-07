/**
 * Polls for approved quotes awaiting ERP sync. Schedule it while logged in as the integration user so the
 * resulting queueable jobs, callouts and DML all run with that user's least-privilege permission set.
 *
 *     ERPSyncScheduler.scheduleEveryFiveMinutes();
 *
 * Polling (rather than enqueueing from the trigger) keeps the approving user out of the integration's
 * security context and gives retries and back-pressure for free.
 */
public with sharing class ERPSyncScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        try {
            ERPIntegrationService.dispatchDueQuotes();
        } catch (Exception e) {
            Logger.error('ERPSyncScheduler', 'ERP dispatch failed', e, null);
        }
    }

    /** Apex cron granularity is one hour, so a five-minute cadence needs twelve schedules. */
    public static List<Id> scheduleEveryFiveMinutes() {
        List<Id> jobIds = new List<Id>();
        for (Integer minute = 0; minute < 60; minute += 5) {
            String name = 'QuoteFlow ERP Sync :' + (minute < 10 ? '0' : '') + minute;
            jobIds.add(System.schedule(name, '0 ' + minute + ' * * * ?', new ERPSyncScheduler()));
        }
        return jobIds;
    }
}
