import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getContext from '@salesforce/apex/QuoteConfiguratorController.getContext';
import getCatalog from '@salesforce/apex/QuoteConfiguratorController.getCatalog';
import getBundleOptions from '@salesforce/apex/QuoteConfiguratorController.getBundleOptions';
import previewPricing from '@salesforce/apex/QuoteConfiguratorController.previewPricing';
import saveQuote from '@salesforce/apex/QuoteConfiguratorController.saveQuote';
import submitForApproval from '@salesforce/apex/QuoteApprovalController.submitForApproval';
// Non-cacheable on purpose: called right after a save/submit, when a cached response would show the old status.
import getApprovalSummaryFresh from '@salesforce/apex/QuoteApprovalController.getApprovalSummaryFresh';
import { badgeClass, discountError, formatCurrency, formatPercent, messageFrom } from 'c/quoteFormat';

const PREVIEW_DEBOUNCE_MS = 400;
// Fallbacks only; the live values come from the server (ContextInfo) so client and server cannot drift.
const DEFAULT_MAX_DISCOUNT = 60;
const DEFAULT_MAX_TERM = 60;

export default class QuoteConfigurator extends NavigationMixin(LightningElement) {
    /** Opportunity record page context. Optional: the component also works on an app page. */
    @api recordId;

    context;
    catalog = [];
    pricebookId;
    termMonths = 12;
    draftLines = [];
    nextKey = 1;

    preview;
    savedQuoteId;
    approval;

    isLoadingContext = true;
    isPricing = false;
    isSaving = false;
    loadError;
    actionError;

    _previewTimer;
    _previewSequence = 0;

    // ------------------------------------------------------------------ data loading

    @wire(getContext, { opportunityId: '$recordId' })
    wiredContext({ data, error }) {
        if (data) {
            this.context = data;
            this.pricebookId = this.pricebookId || data.defaultPricebookId;
            this.isLoadingContext = false;
            this.loadError = undefined;
        } else if (error) {
            this.isLoadingContext = false;
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

    get isContextLoaded() {
        return !this.isLoadingContext;
    }

    get maxDiscount() {
        return this.context?.maxManualDiscountPct ?? DEFAULT_MAX_DISCOUNT;
    }

    get maxTermMonths() {
        return this.context?.maxTermMonths ?? DEFAULT_MAX_TERM;
    }

    get termOverflowMessage() {
        return `Term cannot exceed ${this.maxTermMonths} months.`;
    }

    get currencyCode() {
        return this.context?.currencyIsoCode;
    }

    get pricebookOptions() {
        return (this.context?.pricebooks || []).map((p) => ({ label: p.name, value: p.id }));
    }

    get productOptions() {
        return this.catalog.map((item) => ({
            label: `${item.name} (${formatCurrency(item.listPrice, this.currencyCode)}${item.billingModel === 'Subscription' ? ' / yr' : ''})`,
            value: item.productId
        }));
    }

    get hasLines() {
        return this.draftLines.length > 0;
    }

    get hasAccount() {
        return Boolean(this.context?.accountId);
    }

    get isLocked() {
        return Boolean(this.savedQuoteId);
    }

    get linesView() {
        return this.draftLines.map((line) => ({
            ...line,
            title: line.name,
            isBundle: line.productType === 'Bundle',
            optionsVisible: line.productType === 'Bundle' && line.options.length > 0,
            discountError: discountError(line.manualDiscountPct, this.maxDiscount)
        }));
    }

    get pricedLines() {
        return (this.preview?.lines || []).map((line, index) => ({
            ...line,
            key: `${line.productId}-${index}`,
            rowClass: line.isComponent ? 'slds-hint-parent qf-component' : 'slds-hint-parent',
            nameLabel: line.isComponent ? `↳ ${line.name}` : line.name,
            netUnitLabel: line.isIncluded ? 'Included' : formatCurrency(line.netUnitPrice, this.currencyCode),
            netTotalLabel: formatCurrency(line.netTotal, this.currencyCode),
            discountLabel: formatPercent(line.effectiveDiscountPct),
            hasDiscount: (line.effectiveDiscountPct || 0) > 0
        }));
    }

    get hasPreview() {
        return Boolean(this.preview) && this.preview.lines.length > 0;
    }

    get summary() {
        const p = this.preview;
        if (!p) {
            return null;
        }
        return {
            list: formatCurrency(p.listAmount, this.currencyCode),
            discount: formatCurrency(p.totalDiscountAmount, this.currencyCode),
            net: formatCurrency(p.netAmount, this.currencyCode),
            blended: formatPercent(p.blendedDiscountPct),
            maxLine: formatPercent(p.maxLineDiscountPct)
        };
    }

    get approvalMessage() {
        const p = this.preview;
        if (!p || !this.hasPreview) {
            return null;
        }
        return p.approvalRequired
            ? `Discount above ${p.approvalThresholdPct}% needs level ${p.approvalLevel} approval before this quote can be ordered.`
            : 'Within discount policy. The quote is approved automatically on submit.';
    }

    get approvalIcon() {
        return this.approvalRequired ? 'utility:warning' : 'utility:success';
    }

    get approvalRequired() {
        return Boolean(this.preview?.approvalRequired);
    }

    get validationErrors() {
        return this.preview?.errors || [];
    }

    get hasValidationErrors() {
        return this.validationErrors.length > 0;
    }

    get warnings() {
        return this.preview?.warnings || [];
    }

    get hasWarnings() {
        return this.warnings.length > 0;
    }

    get saveDisabled() {
        return (
            this.isSaving ||
            this.isPricing ||
            this.isLocked ||
            !this.hasPreview ||
            this.hasValidationErrors ||
            this.hasDraftErrors
        );
    }

    get hasDraftErrors() {
        return this.draftLines.some((l) => discountError(l.manualDiscountPct, this.maxDiscount) || !(l.quantity > 0));
    }

    get submitDisabled() {
        return !this.savedQuoteId || this.isSaving || !this.approval?.canSubmit;
    }

    get approvalStatusLabel() {
        return this.approval ? this.approval.status : null;
    }

    get approvalBadgeClass() {
        return badgeClass(this.approval?.status);
    }

    get showSpinner() {
        return this.isLoadingContext || this.isSaving;
    }

    // ------------------------------------------------------------------ editing

    handlePricebookChange(event) {
        this.pricebookId = event.detail.value;
        this.draftLines = [];
        this.preview = undefined;
    }

    handleTermChange(event) {
        const value = parseInt(event.detail.value, 10);
        this.termMonths = Number.isNaN(value) || value < 1 || value > this.maxTermMonths ? null : value;
        this.schedulePreview();
    }

    async handleAddProduct(event) {
        const productId = event.detail.value;
        const item = this.catalog.find((c) => c.productId === productId);
        if (!item) {
            return;
        }
        const line = {
            key: `l${this.nextKey++}`,
            productId,
            name: item.name,
            productType: item.productType,
            quantity: 1,
            manualDiscountPct: 0,
            options: []
        };
        this.draftLines = [...this.draftLines, line];
        if (item.productType === 'Bundle') {
            await this.loadBundleOptions(line.key, productId);
        }
        this.schedulePreview();
        // Reset the picker so the same product can be added again.
        const picker = this.template.querySelector('[data-id="product-picker"]');
        if (picker) {
            picker.value = null;
        }
    }

    async loadBundleOptions(lineKey, bundleId) {
        try {
            const options = await getBundleOptions({ bundleProductId: bundleId });
            this.updateLine(lineKey, {
                options: options.map((o) => ({
                    ...o,
                    selected: o.isRequired,
                    isDisabledQuantity: !o.isRequired,
                    quantity: o.defaultQuantity,
                    badge: o.isRequired ? 'Required' : o.isIncluded ? 'Included' : null
                }))
            });
        } catch (error) {
            this.actionError = messageFrom(error);
        }
    }

    handleLineField(event) {
        const { key, field } = event.target.dataset;
        const raw = event.detail.value;
        const value = raw === '' || raw === null ? null : Number(raw);
        this.updateLine(key, { [field]: value });
        this.schedulePreview();
    }

    handleOptionToggle(event) {
        const { key, option } = event.target.dataset;
        const line = this.draftLines.find((l) => l.key === key);
        const checked = event.detail.checked;
        const options = line.options.map((o) => {
            return o.productId === option ? { ...o, selected: checked, isDisabledQuantity: !checked } : o;
        });
        this.updateLine(key, { options });
        this.schedulePreview();
    }

    handleOptionQuantity(event) {
        const { key, option } = event.target.dataset;
        const line = this.draftLines.find((l) => l.key === key);
        const quantity = Number(event.detail.value);
        const options = line.options.map((o) => (o.productId === option ? { ...o, quantity } : o));
        this.updateLine(key, { options });
        this.schedulePreview();
    }

    handleRemoveLine(event) {
        const { key } = event.target.dataset;
        this.draftLines = this.draftLines.filter((l) => l.key !== key);
        this.schedulePreview();
    }

    updateLine(key, changes) {
        this.draftLines = this.draftLines.map((l) => (l.key === key ? { ...l, ...changes } : l));
    }

    // ------------------------------------------------------------------ pricing preview

    schedulePreview() {
        window.clearTimeout(this._previewTimer);
        if (!this.hasLines || this.hasDraftErrors || !this.termMonths) {
            this.preview = undefined;
            this.isPricing = false;
            return;
        }
        this.isPricing = true;
        this._previewTimer = window.setTimeout(() => this.runPreview(), PREVIEW_DEBOUNCE_MS);
    }

    async runPreview() {
        // Responses can arrive out of order; only the latest request is allowed to update the screen.
        const sequence = ++this._previewSequence;
        try {
            const result = await previewPricing({ draft: this.buildDraft() });
            if (sequence === this._previewSequence) {
                this.preview = result;
                this.actionError = undefined;
            }
        } catch (error) {
            if (sequence === this._previewSequence) {
                this.preview = undefined;
                this.actionError = messageFrom(error);
            }
        } finally {
            if (sequence === this._previewSequence) {
                this.isPricing = false;
            }
        }
    }

    buildDraft() {
        return {
            opportunityId: this.context?.opportunityId,
            accountId: this.context?.accountId,
            pricebookId: this.pricebookId,
            termMonths: this.termMonths,
            lines: this.draftLines.map((l) => ({
                productId: l.productId,
                quantity: l.quantity,
                manualDiscountPct: l.manualDiscountPct || 0,
                options:
                    l.productType === 'Bundle'
                        ? l.options
                              .filter((o) => o.selected)
                              .map((o) => ({ optionProductId: o.productId, quantity: o.quantity }))
                        : null
            }))
        };
    }

    // ------------------------------------------------------------------ save and submit

    async handleSave() {
        this.isSaving = true;
        this.actionError = undefined;
        try {
            this.savedQuoteId = await saveQuote({ draft: this.buildDraft() });
            await this.refreshApproval();
            this.toast('Quote saved', 'Review the summary, then submit it for approval.', 'success');
        } catch (error) {
            this.actionError = messageFrom(error);
        } finally {
            this.isSaving = false;
        }
    }

    async handleSubmit() {
        this.isSaving = true;
        this.actionError = undefined;
        try {
            const result = await submitForApproval({ quoteId: this.savedQuoteId });
            await this.refreshApproval();
            this.toast('Quote submitted', result.message, 'success');
        } catch (error) {
            this.actionError = messageFrom(error);
        } finally {
            this.isSaving = false;
        }
    }

    async refreshApproval() {
        this.approval = await getApprovalSummaryFresh({ quoteId: this.savedQuoteId });
    }

    handleOpenQuote() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.savedQuoteId, objectApiName: 'Quote__c', actionName: 'view' }
        });
    }

    handleStartOver() {
        this.savedQuoteId = undefined;
        this.approval = undefined;
        this.draftLines = [];
        this.preview = undefined;
        this.actionError = undefined;
    }

    // ------------------------------------------------------------------ helpers

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    disconnectedCallback() {
        window.clearTimeout(this._previewTimer);
    }
}
