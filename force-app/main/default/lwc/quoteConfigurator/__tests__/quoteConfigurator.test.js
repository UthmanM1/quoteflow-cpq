import { createElement } from 'lwc';
import QuoteConfigurator from 'c/quoteConfigurator';
import getContext from '@salesforce/apex/QuoteConfiguratorController.getContext';
import getCatalog from '@salesforce/apex/QuoteConfiguratorController.getCatalog';
import getBundleOptions from '@salesforce/apex/QuoteConfiguratorController.getBundleOptions';
import previewPricing from '@salesforce/apex/QuoteConfiguratorController.previewPricing';
import saveQuote from '@salesforce/apex/QuoteConfiguratorController.saveQuote';
import submitForApproval from '@salesforce/apex/QuoteApprovalController.submitForApproval';
import getApprovalSummaryFresh from '@salesforce/apex/QuoteApprovalController.getApprovalSummaryFresh';

jest.mock(
    '@salesforce/apex/QuoteConfiguratorController.getContext',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/QuoteConfiguratorController.getCatalog',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/QuoteConfiguratorController.getBundleOptions', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/QuoteConfiguratorController.previewPricing', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/QuoteConfiguratorController.saveQuote', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/QuoteApprovalController.submitForApproval', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/QuoteApprovalController.getApprovalSummaryFresh', () => ({ default: jest.fn() }), {
    virtual: true
});

const CONTEXT = {
    opportunityId: '006000000000001AAA',
    opportunityName: 'Platform rollout',
    accountId: '001000000000001AAA',
    accountName: 'Northwind (fictional)',
    defaultPricebookId: '01s000000000001AAA',
    pricebooks: [{ id: '01s000000000001AAA', name: 'Standard' }],
    maxManualDiscountPct: 40,
    maxTermMonths: 36,
    currencyIsoCode: 'EUR'
};
const CATALOG = [
    {
        productId: '01t000000000001AAA',
        productCode: 'QF-USER-SEAT',
        name: 'Platform User Seat',
        productType: 'Standalone',
        billingModel: 'Subscription',
        listPrice: 120
    }
];
const BUNDLE = {
    productId: '01t000000000009AAA',
    productCode: 'QF-PLATFORM-ENT',
    name: 'QuoteFlow Platform Enterprise',
    productType: 'Bundle',
    billingModel: 'Subscription',
    listPrice: 10000
};
const BUNDLE_OPTIONS = [
    {
        productId: '01t00000000000AAAA',
        name: 'Platform User Seat',
        isRequired: true,
        isIncluded: false,
        defaultQuantity: 5
    },
    {
        productId: '01t00000000000BAAA',
        name: 'Single Sign-On',
        isRequired: false,
        isIncluded: false,
        defaultQuantity: 1
    }
];
const PREVIEW = {
    isValid: true,
    errors: [],
    warnings: [],
    lines: [
        {
            productId: '01t000000000001AAA',
            name: 'Platform User Seat',
            quantity: 1,
            netUnitPrice: 120,
            netTotal: 120,
            effectiveDiscountPct: 0,
            isComponent: false,
            isIncluded: false
        }
    ],
    listAmount: 120,
    netAmount: 120,
    totalDiscountAmount: 0,
    blendedDiscountPct: 0,
    maxLineDiscountPct: 0,
    approvalRequired: false,
    approvalLevel: 0
};

const flushPromises = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

function render() {
    const element = createElement('c-quote-configurator', { is: QuoteConfigurator });
    element.recordId = CONTEXT.opportunityId;
    document.body.appendChild(element);
    return element;
}

async function renderWithContext(context = CONTEXT) {
    const element = render();
    getContext.emit(context);
    getCatalog.emit([...CATALOG, BUNDLE]);
    await flushPromises();
    return element;
}

async function addSeat(element) {
    const picker = element.shadowRoot.querySelector('[data-id="product-picker"]');
    picker.dispatchEvent(new CustomEvent('change', { detail: { value: CATALOG[0].productId } }));
    await flushPromises();
}

describe('c-quote-configurator', () => {
    beforeEach(() => {
        jest.useFakeTimers();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('asks to be opened from an opportunity when there is no account', async () => {
        const element = render();
        getContext.emit({ ...CONTEXT, accountId: null, accountName: null });
        await flushPromises();

        expect(element.shadowRoot.textContent).toContain('Open this component from an opportunity');
        expect(element.shadowRoot.querySelector('[data-id="product-picker"]')).toBeNull();
    });

    it('shows a readable load error from the server', async () => {
        const element = render();
        getContext.error({
            message: 'You do not have access to the data required for this action (reference ab12cd34).'
        });
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('reference ab12cd34');
    });

    it('takes discount and term limits from the server, not from hard-coded values', async () => {
        const element = await renderWithContext();
        await addSeat(element);

        const discount = element.shadowRoot.querySelector('lightning-input[data-field="manualDiscountPct"]');
        const term = element.shadowRoot.querySelector('[data-id="term"]');
        expect(discount.max).toBe(40);
        expect(term.max).toBe(36);
    });

    it('debounces pricing and sends the draft once the user pauses', async () => {
        previewPricing.mockResolvedValue(PREVIEW);
        const element = await renderWithContext();
        await addSeat(element);

        expect(previewPricing).not.toHaveBeenCalled();
        jest.advanceTimersByTime(400);
        await flushPromises();

        expect(previewPricing).toHaveBeenCalledTimes(1);
        const { draft } = previewPricing.mock.calls[0][0];
        expect(draft.accountId).toBe(CONTEXT.accountId);
        expect(draft.lines).toEqual([
            { productId: CATALOG[0].productId, quantity: 1, manualDiscountPct: 0, options: null }
        ]);
        expect(element.shadowRoot.textContent).toContain('Within discount policy');
    });

    it('ignores a slow, stale preview response that arrives after a newer one', async () => {
        let resolveFirst;
        previewPricing
            .mockImplementationOnce(() => new Promise((resolve) => (resolveFirst = resolve)))
            .mockResolvedValueOnce({
                ...PREVIEW,
                netAmount: 999,
                approvalRequired: true,
                approvalLevel: 2,
                approvalThresholdPct: 20
            });
        const element = await renderWithContext();
        await addSeat(element);
        jest.advanceTimersByTime(400);
        await flushPromises();

        const quantity = element.shadowRoot.querySelector('lightning-input[data-field="quantity"]');
        quantity.dispatchEvent(new CustomEvent('change', { detail: { value: '2' } }));
        jest.advanceTimersByTime(400);
        await flushPromises();
        resolveFirst(PREVIEW);
        await flushPromises();

        expect(element.shadowRoot.textContent).toContain('needs level 2 approval');
        expect(element.shadowRoot.textContent).not.toContain('Within discount policy');
    });

    it('blocks the preview and saving while a discount is above the server limit', async () => {
        const element = await renderWithContext();
        await addSeat(element);

        const discount = element.shadowRoot.querySelector('lightning-input[data-field="manualDiscountPct"]');
        discount.dispatchEvent(new CustomEvent('change', { detail: { value: '45' } }));
        jest.advanceTimersByTime(400);
        await flushPromises();

        expect(previewPricing).not.toHaveBeenCalled();
        expect(element.shadowRoot.textContent).toContain('Enter a value between 0 and 40.');
        const save = [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === 'Save quote');
        expect(save.disabled).toBe(true);
    });

    it('refreshes approval status with a non-cacheable call after save and after submit', async () => {
        previewPricing.mockResolvedValue(PREVIEW);
        saveQuote.mockResolvedValue('a00000000000001AAA');
        submitForApproval.mockResolvedValue({
            success: true,
            message: 'Within discount policy; approved automatically.'
        });
        getApprovalSummaryFresh
            .mockResolvedValueOnce({
                quoteNumber: 'Q-000001',
                status: 'Draft',
                approvalStatus: 'Not Submitted',
                canSubmit: true
            })
            .mockResolvedValueOnce({
                quoteNumber: 'Q-000001',
                status: 'Approved',
                approvalStatus: 'Not Required',
                canSubmit: false
            });
        const element = await renderWithContext();
        await addSeat(element);
        jest.advanceTimersByTime(400);
        await flushPromises();

        const buttons = () => [...element.shadowRoot.querySelectorAll('lightning-button')];
        buttons()
            .find((b) => b.label === 'Save quote')
            .click();
        await flushPromises();
        buttons()
            .find((b) => b.label === 'Submit for approval')
            .click();
        await flushPromises();

        expect(saveQuote).toHaveBeenCalledTimes(1);
        expect(submitForApproval).toHaveBeenCalledWith({ quoteId: 'a00000000000001AAA' });
        expect(getApprovalSummaryFresh).toHaveBeenCalledTimes(2);
        const badge = element.shadowRoot.querySelector('span.slds-badge');
        expect(badge.textContent).toBe('Approved');
        expect(badge.className).toContain('slds-theme_success');
    });

    it('shows the server message when saving fails', async () => {
        previewPricing.mockResolvedValue(PREVIEW);
        saveQuote.mockRejectedValue({
            body: { message: 'Platform User Seat has no active price in the selected price book.' }
        });
        const element = await renderWithContext();
        await addSeat(element);
        jest.advanceTimersByTime(400);
        await flushPromises();

        [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === 'Save quote').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('no active price');
        expect(getApprovalSummaryFresh).not.toHaveBeenCalled();
    });

    it('configures a bundle: required options preselected, optional ones toggled into the draft', async () => {
        getBundleOptions.mockResolvedValue(BUNDLE_OPTIONS);
        previewPricing.mockResolvedValue(PREVIEW);
        const element = await renderWithContext();
        const picker = element.shadowRoot.querySelector('[data-id="product-picker"]');
        picker.dispatchEvent(new CustomEvent('change', { detail: { value: BUNDLE.productId } }));
        await flushPromises();

        const checkboxes = element.shadowRoot.querySelectorAll('[data-role="option-toggle"]');
        expect(checkboxes).toHaveLength(2);
        expect(checkboxes[0].checked).toBe(true);
        expect(checkboxes[0].disabled).toBe(true);
        checkboxes[1].dispatchEvent(new CustomEvent('change', { detail: { checked: true } }));
        jest.advanceTimersByTime(400);
        await flushPromises();

        const { draft } = previewPricing.mock.calls[previewPricing.mock.calls.length - 1][0];
        expect(draft.lines[0].options).toEqual([
            { optionProductId: BUNDLE_OPTIONS[0].productId, quantity: 5 },
            { optionProductId: BUNDLE_OPTIONS[1].productId, quantity: 1 }
        ]);
    });

    it('clears the preview when the last line is removed', async () => {
        previewPricing.mockResolvedValue(PREVIEW);
        const element = await renderWithContext();
        await addSeat(element);
        jest.advanceTimersByTime(400);
        await flushPromises();
        expect(element.shadowRoot.querySelector('table')).not.toBeNull();

        element.shadowRoot.querySelector('lightning-button-icon').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('table')).toBeNull();
    });
});
