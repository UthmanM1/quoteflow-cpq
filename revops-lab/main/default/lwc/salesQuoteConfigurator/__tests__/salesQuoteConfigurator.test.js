import { createElement } from 'lwc';
import SalesQuoteConfigurator from 'c/salesQuoteConfigurator';
import getContext from '@salesforce/apex/SalesQuoteConfiguratorController.getContext';
import getCatalog from '@salesforce/apex/SalesQuoteConfiguratorController.getCatalog';
import previewQuote from '@salesforce/apex/SalesQuoteConfiguratorController.previewQuote';
import saveQuote from '@salesforce/apex/SalesQuoteConfiguratorController.saveQuote';
import submitQuote from '@salesforce/apex/SalesQuoteConfiguratorController.submitQuote';

jest.mock(
    '@salesforce/apex/SalesQuoteConfiguratorController.getContext',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/SalesQuoteConfiguratorController.getCatalog',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/SalesQuoteConfiguratorController.previewQuote', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/SalesQuoteConfiguratorController.saveQuote', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/SalesQuoteConfiguratorController.submitQuote', () => ({ default: jest.fn() }), {
    virtual: true
});

const OPPORTUNITY_ID = '006000000000001AAA';
const CONTEXT = {
    opportunityId: OPPORTUNITY_ID,
    accountName: 'Northwind Demo Traders (fictional)',
    pricebookId: '01s000000000001AAA',
    pricebookName: 'Standard Price Book',
    currencyIsoCode: 'EUR',
    maxTermMonths: 36
};
const CATALOG = [
    {
        productId: '01t000000000001AAA',
        name: 'Platform Subscription',
        family: 'Software',
        billingFrequency: 'Annual',
        unitPrice: 1000,
        maxDiscountPercent: 40
    },
    {
        productId: '01t000000000002AAA',
        name: 'Edge Appliance',
        family: 'Hardware',
        billingFrequency: 'One-Time',
        unitPrice: 2500,
        maxDiscountPercent: 15
    }
];
const PREVIEW = {
    isValid: true,
    errors: [],
    lines: [{ productId: CATALOG[0].productId, netTotal: 7500, error: null }],
    listTotal: 10000,
    netTotal: 7500,
    discountAmount: 2500,
    maxDiscountPercent: 25,
    approval: { approvalRequired: true, tier: 2, reason: 'Discount above 20%' }
};

const flush = async () => {
    for (let i = 0; i < 5; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
};

async function render() {
    const element = createElement('c-sales-quote-configurator', { is: SalesQuoteConfigurator });
    element.recordId = OPPORTUNITY_ID;
    document.body.appendChild(element);
    getContext.emit(CONTEXT);
    getCatalog.emit(CATALOG);
    await flush();
    return element;
}

function change(element, selector, value) {
    element.shadowRoot.querySelector(selector).dispatchEvent(new CustomEvent('change', { detail: { value } }));
}

async function addLine(element, productId, quantity, discount) {
    [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === 'Add product').click();
    await flush();
    change(element, 'lightning-combobox[data-field="productId"]', productId);
    change(element, 'lightning-input[data-field="quantity"]', String(quantity));
    change(element, 'lightning-input[data-field="discountPercent"]', String(discount));
    await flush();
}

const button = (element, label) =>
    [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);

describe('c-sales-quote-configurator', () => {
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

    it('shows the opportunity context and the term limit supplied by the server', async () => {
        const element = await render();

        expect(element.shadowRoot.textContent).toContain('Northwind Demo Traders (fictional)');
        expect(element.shadowRoot.querySelector('[data-id="term"]').max).toBe(36);
    });

    it('prices the draft on the server after the user pauses and shows the approval requirement', async () => {
        previewQuote.mockResolvedValue(PREVIEW);
        const element = await render();
        await addLine(element, CATALOG[0].productId, 10, 25);

        expect(previewQuote).not.toHaveBeenCalled();
        jest.advanceTimersByTime(400);
        await flush();

        expect(previewQuote).toHaveBeenCalledTimes(1);
        expect(previewQuote.mock.calls[0][0].request).toEqual({
            opportunityId: OPPORTUNITY_ID,
            pricebookId: CONTEXT.pricebookId,
            termMonths: 12,
            lines: [{ productId: CATALOG[0].productId, quantity: 10, discountPercent: 25 }]
        });
        expect(element.shadowRoot.querySelector('[data-id="approval-message"]').textContent).toContain(
            'Tier 2 approval required'
        );
        expect(element.shadowRoot.querySelector('[data-id="summary"]').textContent).toContain('7,500.00');
    });

    it('validates the discount against the product policy before calling the server', async () => {
        const element = await render();
        await addLine(element, CATALOG[1].productId, 1, 20);
        jest.advanceTimersByTime(400);
        await flush();

        expect(previewQuote).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('[data-role="line-error"]').textContent).toBe(
            'Discount must be between 0% and 15%.'
        );
        expect(button(element, 'Save quote').disabled).toBe(true);
    });

    it('shows server validation errors and keeps saving disabled', async () => {
        previewQuote.mockResolvedValue({
            ...PREVIEW,
            isValid: false,
            errors: ['Line 1: The selected product has no active price in the quote price book.'],
            lines: [
                {
                    productId: CATALOG[0].productId,
                    error: 'The selected product has no active price in the quote price book.'
                }
            ]
        });
        const element = await render();
        await addLine(element, CATALOG[0].productId, 1, 0);
        jest.advanceTimersByTime(400);
        await flush();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('no active price');
        expect(button(element, 'Save quote').disabled).toBe(true);
    });

    it('ignores a stale preview response that arrives after a newer one', async () => {
        let resolveFirst;
        previewQuote
            .mockImplementationOnce(() => new Promise((resolve) => (resolveFirst = resolve)))
            .mockResolvedValueOnce({ ...PREVIEW, approval: { approvalRequired: false, tier: 0 } });
        const element = await render();
        await addLine(element, CATALOG[0].productId, 10, 25);
        jest.advanceTimersByTime(400);
        await flush();
        change(element, 'lightning-input[data-field="discountPercent"]', '5');
        jest.advanceTimersByTime(400);
        await flush();
        resolveFirst(PREVIEW);
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="approval-message"]').textContent).toContain(
            'Within discount policy'
        );
    });

    it('saves, then submits, and reports the server outcome', async () => {
        previewQuote.mockResolvedValue(PREVIEW);
        saveQuote.mockResolvedValue('a00000000000001AAA');
        submitQuote.mockResolvedValue({
            success: true,
            status: 'Pending Approval',
            message: 'Submitted for tier 2 approval.'
        });
        const element = await render();
        const toast = jest.fn();
        element.addEventListener('lightning__showtoast', toast);
        await addLine(element, CATALOG[0].productId, 10, 25);
        jest.advanceTimersByTime(400);
        await flush();

        button(element, 'Save quote').click();
        await flush();
        button(element, 'Submit for approval').click();
        await flush();

        expect(saveQuote).toHaveBeenCalledTimes(1);
        expect(submitQuote).toHaveBeenCalledWith({ quoteId: 'a00000000000001AAA' });
        expect(toast.mock.calls.map((c) => c[0].detail.title)).toEqual(['Quote saved', 'Quote submitted']);
        expect(button(element, 'Submit for approval').disabled).toBe(true);
    });

    it('shows the server message when saving fails', async () => {
        previewQuote.mockResolvedValue(PREVIEW);
        saveQuote.mockRejectedValue({
            body: { message: 'Discount exceeds the maximum allowed by the discount policy.' }
        });
        const element = await render();
        await addLine(element, CATALOG[0].productId, 10, 25);
        jest.advanceTimersByTime(400);
        await flush();

        button(element, 'Save quote').click();
        await flush();

        expect(element.shadowRoot.querySelector('[data-id="action-error"]').textContent).toContain('discount policy');
        expect(submitQuote).not.toHaveBeenCalled();
    });
});
