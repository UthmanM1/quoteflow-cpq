import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getApprovalSummary from '@salesforce/apex/QuoteApprovalController.getApprovalSummary';
import decide from '@salesforce/apex/QuoteApprovalController.decide';
import submitForApproval from '@salesforce/apex/QuoteApprovalController.submitForApproval';
import recallQuote from '@salesforce/apex/QuoteApprovalController.recallQuote';
import convertToOrder from '@salesforce/apex/QuoteApprovalController.convertToOrder';
import { badgeClass, formatCurrency, formatPercent, messageFrom } from 'c/quoteFormat';

// Fallback only; the server sends the rule it enforces (ApprovalSummary.minRejectionCommentLength).
const DEFAULT_MIN_REJECTION_LENGTH = 10;

export default class QuoteApprovalPanel extends NavigationMixin(LightningElement) {
    /** Quote__c record Id, supplied by the record page. */
    @api recordId;

    summary;
    wiredResult;
    loadError;
    actionError;
    isLoading = true;
    isWorking = false;
    comments = '';
    commentsError;

    @wire(getApprovalSummary, { quoteId: '$recordId' })
    wiredSummary(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.summary = data;
            this.loadError = undefined;
            this.isLoading = false;
        } else if (error) {
            this.summary = undefined;
            this.loadError = messageFrom(error);
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------------ view model

    get hasSummary() {
        return Boolean(this.summary);
    }

    get statusBadgeClass() {
        return badgeClass(this.summary?.status);
    }

    get approvalBadgeClass() {
        return badgeClass(this.summary?.approvalStatus);
    }

    get amounts() {
        const s = this.summary;
        return {
            list: formatCurrency(s.listAmount, s.currencyIsoCode),
            net: formatCurrency(s.netAmount, s.currencyIsoCode),
            discount: formatCurrency(s.totalDiscountAmount, s.currencyIsoCode),
            blended: formatPercent(s.blendedDiscountPct),
            maxLine: formatPercent(s.maxLineDiscountPct)
        };
    }

    get levels() {
        return (this.summary?.levels || []).map((l) => ({
            ...l,
            key: `level-${l.level}`,
            label: `Level ${l.level}`,
            detail: `Above ${l.thresholdPct}% – ${l.approverType === 'Manager' ? "owner's manager" : l.approverRole}`,
            stateClass: this.levelClass(l),
            stateLabel: this.levelState(l)
        }));
    }

    levelClass(level) {
        if (!level.isRequired) {
            return 'slds-badge slds-theme_shade';
        }
        const request = (this.summary.history || []).filter((h) => h.level === level.level).pop();
        if (request?.status === 'Approved') {
            return 'slds-badge slds-theme_success';
        }
        if (request?.status === 'Rejected') {
            return 'slds-badge slds-theme_error';
        }
        return 'slds-badge slds-theme_warning';
    }

    levelState(level) {
        if (!level.isRequired) {
            return 'Not needed';
        }
        const request = (this.summary.history || []).filter((h) => h.level === level.level).pop();
        return request ? request.status : 'Waiting';
    }

    get noApprovalNeeded() {
        return this.summary?.requiredLevel === 0;
    }

    get history() {
        return (this.summary?.history || []).map((h) => ({
            ...h,
            statusClass: badgeClass(h.status),
            when: h.decisionDate || h.submittedDate,
            hasComments: Boolean(h.comments)
        }));
    }

    get hasHistory() {
        return this.history.length > 0;
    }

    get currentApprover() {
        const pending = (this.summary?.history || []).find((h) => h.status === 'Pending');
        return pending ? `${pending.approverName} (level ${pending.level})` : null;
    }

    get canDecide() {
        return Boolean(this.summary?.canDecide);
    }

    get showDecisionPanel() {
        return this.canDecide && this.summary.status === 'Pending Approval';
    }

    get showWaiting() {
        return !this.canDecide && this.summary?.status === 'Pending Approval';
    }

    get erpSummary() {
        const s = this.summary;
        if (!s || s.erpSyncStatus === 'Not Required') {
            return null;
        }
        return {
            status: s.erpSyncStatus,
            orderId: s.erpOrderId,
            error: s.erpLastError,
            statusClass: badgeClass(s.erpSyncStatus)
        };
    }

    get busy() {
        return this.isLoading || this.isWorking;
    }

    // ------------------------------------------------------------------ actions

    handleCommentsChange(event) {
        this.comments = event.detail.value;
        this.commentsError = undefined;
    }

    handleApprove() {
        return this.runDecision(true);
    }

    get minRejectionLength() {
        return this.summary?.minRejectionCommentLength ?? DEFAULT_MIN_REJECTION_LENGTH;
    }

    handleReject() {
        if ((this.comments || '').trim().length < this.minRejectionLength) {
            this.commentsError = `Explain the rejection (at least ${this.minRejectionLength} characters).`;
            return undefined;
        }
        return this.runDecision(false);
    }

    async runDecision(approve) {
        const succeeded = await this.perform(
            () => decide({ approvalRequestId: this.summary.pendingRequestId, approve, comments: this.comments }),
            approve ? 'Quote approved' : 'Quote rejected'
        );
        // Keep the approver's text if the decision failed, so it is not lost on a retry.
        if (succeeded) {
            this.comments = '';
        }
    }

    handleSubmit() {
        return this.perform(() => submitForApproval({ quoteId: this.recordId }), 'Quote submitted');
    }

    handleRecall() {
        return this.perform(() => recallQuote({ quoteId: this.recordId }), 'Quote recalled');
    }

    async handleConvert() {
        await this.perform(async () => {
            const orderId = await convertToOrder({ quoteId: this.recordId });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: orderId, objectApiName: 'Order', actionName: 'view' }
            });
        }, 'Order created');
    }

    /** Runs a server action, then refreshes the wire and the record page. Resolves to true on success. */
    async perform(action, successTitle) {
        this.isWorking = true;
        this.actionError = undefined;
        try {
            await action();
            await refreshApex(this.wiredResult);
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({ title: successTitle, variant: 'success' }));
            return true;
        } catch (error) {
            // Stale decisions (someone else actioned the request first) land here with a readable message.
            this.actionError = messageFrom(error);
            await refreshApex(this.wiredResult);
            return false;
        } finally {
            this.isWorking = false;
        }
    }
}
