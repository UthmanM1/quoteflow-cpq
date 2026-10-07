import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/SalesQuoteConfiguratorController.getContext';
import getCatalog from '@salesforce/apex/SalesQuoteConfiguratorController.getCatalog';
import previewQuote from '@salesforce/apex/SalesQuoteConfiguratorController.previewQuote';
import saveQuote from '@salesforce/apex/SalesQuoteConfiguratorController.saveQuote';
import submitQuote from '@salesforce/apex/SalesQuoteConfiguratorController.submitQuote';
import { formatCurrency, formatPercent, messageFrom } from 'c/salesFormat';

const PREVIEW_DELAY_MS = 400;

/**
 * Opportunity record page component: choose products, quantities and discounts, see server-side pricing and the
 * approval requirement, then save and submit. The preview is advisory: the server prices and validates again on save,
 * and the line trigger and validation rules re-check every value.
 */
export default class SalesQuoteConfigurator extends NavigationMixin(LightningElement) {
    @api recordId;

    context;
    catalog = [];
    lines = [];
    termMonths = 12;
    preview;
    savedQuoteId;
    submission;

    loadError;
    actionError;
    isPricing = false;
    isWorking = false;

    _nextKey = 1;
    _timer;
    _sequence = 0;

    @wire(getContext, { opportunityId: '$recordId' })
    wiredContext({ data, error }) {
        if (data) {
            this.context = data;
            this.loadError = undefined;
        } else if (error) {
            this.loadError = messageFrom(error);
        }
    }

    @wire(getCatalog, { pricebookId: '$pricebookId' })
    wiredCatalog({ data, error }) {
        if (data) {
            this.catalog = data;
        } else if (error) {
            this.loadError = messageFrom(error);
        }
    }

    // ------------------------------------------------------------------ view model

    get pricebookId() {
        return this.context?.pricebookId;
    }

    get isLoaded() {
        return Boolean(this.context);
    }

    get maxTermMonths() {
        return this.context?.maxTermMonths ?? 60;
    }

    get productOptions() {
        return this.catalog.map((item) => ({
            label: `${item.name} · ${formatCurrency(item.unitPrice, this.context?.currencyIsoCode)}${
                item.billingFrequency === 'Annual' ? ' / year' : ''
            }`,
            value: item.productId
        }));
    }

    get hasLines() {
        return this.lines.length > 0;
    }

    get lineRows() {
        return this.lines.map((line, index) => {
            const item = this.catalog.find((c) => c.productId === line.productId);
            const max = item ? item.maxDiscountPercent : 0;
            const priced = this.preview?.lines?.[index];
            return {
                ...line,
                maxDiscount: max,
                discountHelp: item ? `Policy maximum ${formatPercent(max)}` : '',
                clientError: this.clientError(line, max),
                serverError: priced?.error,
                netTotalLabel:
                    priced && !priced.error ? formatCurrency(priced.netTotal, this.context?.currencyIsoCode) : '—'
            };
        });
    }

    get hasClientErrors() {
        return this.lineRows.some((row) => row.clientError);
    }

    get summary() {
        const p = this.preview;
        if (!p) {
            return null;
        }
        const currency = this.context?.currencyIsoCode;
        return {
            list: formatCurrency(p.listTotal, currency),
            discount: formatCurrency(p.discountAmount, currency),
            net: formatCurrency(p.netTotal, currency),
            maxDiscount: formatPercent(p.maxDiscountPercent)
        };
    }

    get approvalRequired() {
        return Boolean(this.preview?.approval?.approvalRequired);
    }

    get approvalMessage() {
        const approval = this.preview?.approval;
        if (!approval) {
            return '';
        }
        return approval.approvalRequired
            ? `Tier ${approval.tier} approval required (${approval.reason}).`
            : 'Within discount policy: the quote is approved automatically on submit.';
    }

    get approvalIcon() {
        return this.approvalRequired ? 'utility:warning' : 'utility:success';
    }

    get serverErrors() {
        return this.preview && !this.preview.isValid ? this.preview.errors : [];
    }

    get hasServerErrors() {
        return this.serverErrors.length > 0;
    }

    get saveDisabled() {
        return (
            this.isWorking ||
            this.isPricing ||
            Boolean(this.savedQuoteId) ||
            !this.hasLines ||
            this.hasClientErrors ||
            !this.preview ||
            !this.preview.isValid
        );
    }

    get isSaved() {
        return Boolean(this.savedQuoteId);
    }

    get submitDisabled() {
        return this.isWorking || !this.savedQuoteId || Boolean(this.submission);
    }

    get busy() {
        return this.isWorking;
    }

    // ------------------------------------------------------------------ editing

    handleAddLine() {
        this.lines = [
            ...this.lines,
            { key: `line-${this._nextKey++}`, productId: null, quantity: 1, discountPercent: 0 }
        ];
    }

    handleRemoveLine(event) {
        const { key } = event.target.dataset;
        this.lines = this.lines.filter((line) => line.key !== key);
        this.schedulePreview();
    }

    handleLineChange(event) {
        const { key, field } = event.target.dataset;
        const raw = event.detail.value;
        const value = field === 'productId' ? raw : raw === '' || raw === null ? null : Number(raw);
        this.lines = this.lines.map((line) => (line.key === key ? { ...line, [field]: value } : line));
        this.schedulePreview();
    }

    handleTermChange(event) {
        const value = parseInt(event.detail.value, 10);
        this.termMonths = Number.isNaN(value) ? null : value;
        this.schedulePreview();
    }

    clientError(line, maxDiscount) {
        if (!line.productId) {
            return 'Select a product.';
        }
        if (!(line.quantity > 0)) {
            return 'Quantity must be greater than zero.';
        }
        const discount = line.discountPercent ?? 0;
        if (discount < 0 || discount > maxDiscount) {
            return `Discount must be between 0% and ${maxDiscount}%.`;
        }
        return null;
    }

    // ------------------------------------------------------------------ pricing preview

    schedulePreview() {
        window.clearTimeout(this._timer);
        const termValid = this.termMonths >= 1 && this.termMonths <= this.maxTermMonths;
        if (!this.hasLines || this.hasClientErrors || !termValid) {
            this.preview = undefined;
            this.isPricing = false;
            return;
        }
        this.isPricing = true;
        this._timer = window.setTimeout(() => this.runPreview(), PREVIEW_DELAY_MS);
    }

    async runPreview() {
        // Only the latest request may update the screen; earlier responses can arrive later.
        const sequence = ++this._sequence;
        try {
            const result = await previewQuote({ request: this.buildRequest() });
            if (sequence === this._sequence) {
                this.preview = result;
                this.actionError = undefined;
            }
        } catch (error) {
            if (sequence === this._sequence) {
                this.preview = undefined;
                this.actionError = messageFrom(error);
            }
        } finally {
            if (sequence === this._sequence) {
                this.isPricing = false;
            }
        }
    }

    buildRequest() {
        return {
            opportunityId: this.recordId,
            pricebookId: this.pricebookId,
            termMonths: this.termMonths,
            lines: this.lines.map((line) => ({
                productId: line.productId,
                quantity: line.quantity,
                discountPercent: line.discountPercent ?? 0
            }))
        };
    }

    // ------------------------------------------------------------------ save and submit

    async handleSave() {
        this.isWorking = true;
        this.actionError = undefined;
        try {
            this.savedQuoteId = await saveQuote({ request: this.buildRequest() });
            this.toast('Quote saved', 'Review the summary, then submit it for approval.', 'success');
        } catch (error) {
            this.actionError = messageFrom(error);
        } finally {
            this.isWorking = false;
        }
    }

    async handleSubmit() {
        this.isWorking = true;
        this.actionError = undefined;
        try {
            this.submission = await submitQuote({ quoteId: this.savedQuoteId });
            this.toast('Quote submitted', this.submission.message, 'success');
        } catch (error) {
            this.actionError = messageFrom(error);
        } finally {
            this.isWorking = false;
        }
    }

    handleOpenQuote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.savedQuoteId, objectApiName: 'Quote_Configuration__c', actionName: 'view' }
        });
    }

    handleStartOver() {
        this.lines = [];
        this.preview = undefined;
        this.savedQuoteId = undefined;
        this.submission = undefined;
        this.actionError = undefined;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    disconnectedCallback() {
        window.clearTimeout(this._timer);
    }
}
