import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getApprovalSummary from '@salesforce/apex/SalesApprovalController.getApprovalSummary';
import decide from '@salesforce/apex/SalesApprovalController.decide';
import recallQuote from '@salesforce/apex/SalesApprovalController.recallQuote';
import convertToOrder from '@salesforce/apex/SalesApprovalController.convertToOrder';
import { badgeClass, formatCurrency, formatPercent, messageFrom } from 'c/salesFormat';

/**
 * Quote Configuration record page component: amount, requested discount, threshold, approver, approval status and
 * comments; approve/reject for the assigned approver, recall and convert for the owner. The server decides who may
 * do what (the can* flags are hints computed with the same rules the services enforce).
 */
export default class SalesApprovalPanel extends NavigationMixin(LightningElement) {
    @api recordId;

    summary;
    wiredSummary;
    loadError;
    actionError;
    comments = '';
    commentsError;
    poNumber;
    isWorking = false;

    @wire(getApprovalSummary, { quoteId: '$recordId' })
    wired(result) {
        this.wiredSummary = result;
        if (result.data) {
            this.summary = result.data;
            this.loadError = undefined;
            if (this.poNumber === undefined) {
                this.poNumber = result.data.customerPoNumber;
            }
        } else if (result.error) {
            this.summary = undefined;
            this.loadError = messageFrom(result.error);
        }
    }

    // ------------------------------------------------------------------ view model

    get hasSummary() {
        return Boolean(this.summary);
    }

    get figures() {
        const s = this.summary;
        return {
            net: formatCurrency(s.netAmount, s.currencyIsoCode),
            list: formatCurrency(s.listAmount, s.currencyIsoCode),
            discountAmount: formatCurrency(s.discountAmount, s.currencyIsoCode),
            requested: formatPercent(s.requestedDiscountPercent),
            threshold: s.approvalRequired ? formatPercent(s.thresholdPercent) : 'No threshold reached',
            tier: s.approvalRequired ? `Tier ${s.tier}` : 'None'
        };
    }

    get statusClass() {
        return badgeClass(this.summary?.status);
    }

    get approvalStatusClass() {
        return badgeClass(this.summary?.approvalStatus);
    }

    get approverLabel() {
        return this.summary?.approverName || '—';
    }

    get hasLatestComments() {
        return Boolean(this.summary?.latestComments);
    }

    get history() {
        return (this.summary?.history || []).map((item) => ({
            ...item,
            badge: badgeClass(item.status),
            when: item.decisionDate || item.submittedDate
        }));
    }

    get hasHistory() {
        return this.history.length > 0;
    }

    get minCommentLength() {
        return this.summary?.minCommentLength ?? 10;
    }

    get canDecide() {
        return Boolean(this.summary?.canDecide);
    }

    get canRecall() {
        return Boolean(this.summary?.canRecall);
    }

    get canConvert() {
        return Boolean(this.summary?.canConvert);
    }

    // ------------------------------------------------------------------ actions

    handleCommentsChange(event) {
        this.comments = event.detail.value;
        this.commentsError = undefined;
    }

    handlePoChange(event) {
        this.poNumber = event.detail.value;
    }

    handleApprove() {
        return this.decideAndKeepComments(true);
    }

    handleReject() {
        if ((this.comments || '').trim().length < this.minCommentLength) {
            this.commentsError = `Explain the rejection in at least ${this.minCommentLength} characters.`;
            return undefined;
        }
        return this.decideAndKeepComments(false);
    }

    async decideAndKeepComments(approve) {
        const ok = await this.perform(
            () => decide({ requestId: this.summary.pendingRequestId, approve, comments: this.comments }),
            approve ? 'Quote approved' : 'Quote rejected'
        );
        if (ok) {
            this.comments = '';
        }
    }

    handleRecall() {
        return this.perform(() => recallQuote({ quoteId: this.recordId }), 'Quote recalled');
    }

    async handleConvert() {
        if (!this.poNumber || !this.poNumber.trim()) {
            this.actionError = 'Enter the customer PO number before converting the quote.';
            return;
        }
        await this.perform(async () => {
            const orderId = await convertToOrder({ quoteId: this.recordId, customerPoNumber: this.poNumber });
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: orderId, objectApiName: 'Order', actionName: 'view' }
            });
        }, 'Order created');
    }

    async perform(action, successTitle) {
        this.isWorking = true;
        this.actionError = undefined;
        try {
            await action();
            await refreshApex(this.wiredSummary);
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new ShowToastEvent({ title: successTitle, variant: 'success' }));
            return true;
        } catch (error) {
            this.actionError = messageFrom(error);
            await refreshApex(this.wiredSummary);
            return false;
        } finally {
            this.isWorking = false;
        }
    }
}
