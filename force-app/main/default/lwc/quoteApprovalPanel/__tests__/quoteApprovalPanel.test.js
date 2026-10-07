import { createElement } from 'lwc';
import QuoteApprovalPanel from 'c/quoteApprovalPanel';
import getApprovalSummary from '@salesforce/apex/QuoteApprovalController.getApprovalSummary';
import decide from '@salesforce/apex/QuoteApprovalController.decide';
import convertToOrder from '@salesforce/apex/QuoteApprovalController.convertToOrder';
import { refreshApex } from '@salesforce/apex';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { mockNavigate } from 'lightning/navigation';

const TOAST_EVENT = 'lightning__showtoast';

jest.mock(
    '@salesforce/apex/QuoteApprovalController.getApprovalSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/QuoteApprovalController.decide', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/QuoteApprovalController.submitForApproval', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex/QuoteApprovalController.recallQuote', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/QuoteApprovalController.convertToOrder', () => ({ default: jest.fn() }), {
    virtual: true
});
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn(() => Promise.resolve()) }), { virtual: true });
jest.mock('lightning/navigation', () => {
    const Navigate = Symbol('Navigate');
    const navigate = jest.fn();
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](pageReference) {
                navigate(pageReference);
            }
        };
    NavigationMixin.Navigate = Navigate;
    return { NavigationMixin, mockNavigate: navigate };
});
jest.mock('lightning/uiRecordApi', () => ({ notifyRecordUpdateAvailable: jest.fn(() => Promise.resolve()) }), {
    virtual: true
});

const QUOTE_ID = 'a00000000000001AAA';
const REQUEST_ID = 'a01000000000001AAA';

const PENDING_FOR_ME = {
    quoteId: QUOTE_ID,
    quoteNumber: 'Q-000042',
    accountName: 'Northwind (fictional)',
    status: 'Pending Approval',
    approvalStatus: 'Pending',
    listAmount: 1000,
    netAmount: 750,
    totalDiscountAmount: 250,
    blendedDiscountPct: 25,
    maxLineDiscountPct: 25,
    requiredLevel: 2,
    currentLevel: 1,
    erpSyncStatus: 'Not Required',
    pendingRequestId: REQUEST_ID,
    canDecide: true,
    canSubmit: false,
    canRecall: false,
    canConvert: false,
    minRejectionCommentLength: 15,
    currencyIsoCode: 'GBP',
    levels: [
        { level: 1, thresholdPct: 10, approverType: 'Manager', isRequired: true },
        { level: 2, thresholdPct: 20, approverType: 'Role', approverRole: 'QF_Finance_Director', isRequired: true }
    ],
    history: [{ id: REQUEST_ID, level: 1, status: 'Pending', approverName: 'Morgan Manager' }]
};

// Real timers in this suite: a macrotask lets every chained await (action, refreshApex, notify) settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

async function render(summary) {
    const element = createElement('c-quote-approval-panel', { is: QuoteApprovalPanel });
    element.recordId = QUOTE_ID;
    document.body.appendChild(element);
    getApprovalSummary.emit(summary);
    await flushPromises();
    return element;
}

const button = (element, label) =>
    [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);

async function typeComment(element, text) {
    const textarea = element.shadowRoot.querySelector('lightning-textarea');
    textarea.dispatchEvent(new CustomEvent('change', { detail: { value: text } }));
    await flushPromises();
}

describe('c-quote-approval-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows amounts in the currency supplied by the server and the waiting approver', async () => {
        const element = await render(PENDING_FOR_ME);

        expect(element.shadowRoot.textContent).toContain('£750.00');
        expect(element.shadowRoot.textContent).toContain('Morgan Manager (level 1)');
    });

    it('enforces the server-supplied minimum rejection comment before calling Apex', async () => {
        const element = await render(PENDING_FOR_ME);
        await typeComment(element, 'Too deep');

        button(element, 'Reject').click();
        await flushPromises();

        expect(decide).not.toHaveBeenCalled();
        expect(element.shadowRoot.textContent).toContain('at least 15 characters');
    });

    it('approves, then refreshes the wire and the record page and confirms with a toast', async () => {
        decide.mockResolvedValue();
        const element = await render(PENDING_FOR_ME);
        const toastHandler = jest.fn();
        element.addEventListener(TOAST_EVENT, toastHandler);

        button(element, 'Approve').click();
        await flushPromises();

        expect(decide).toHaveBeenCalledWith({ approvalRequestId: REQUEST_ID, approve: true, comments: '' });
        expect(refreshApex).toHaveBeenCalled();
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: QUOTE_ID }]);
        expect(toastHandler.mock.calls[0][0].detail.title).toBe('Quote approved');
    });

    it('keeps the comment and shows the reason when a decision is refused', async () => {
        decide.mockRejectedValue({ body: { message: 'This request has already been actioned.' } });
        const element = await render(PENDING_FOR_ME);
        await typeComment(element, 'Margin is below the floor for this segment.');

        button(element, 'Reject').click();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('already been actioned');
        expect(element.shadowRoot.querySelector('lightning-textarea').value).toBe(
            'Margin is below the floor for this segment.'
        );
        expect(refreshApex).toHaveBeenCalled();
    });

    it('hides decision controls from users who are not the assigned approver', async () => {
        const element = await render({ ...PENDING_FOR_ME, canDecide: false });

        expect(button(element, 'Approve')).toBeUndefined();
        expect(element.shadowRoot.textContent).toContain('Only the assigned approver');
    });

    it('converts an approved quote and navigates to the new order', async () => {
        convertToOrder.mockResolvedValue('801000000000001AAA');
        const element = await render({
            ...PENDING_FOR_ME,
            status: 'Approved',
            approvalStatus: 'Approved',
            canDecide: false,
            canConvert: true,
            pendingRequestId: null,
            history: [],
            erpSyncStatus: 'Failed',
            erpLastError: 'ERP returned HTTP 422. UNKNOWN_SKU: SKU not found'
        });

        button(element, 'Convert to order').click();
        await flushPromises();

        expect(convertToOrder).toHaveBeenCalledWith({ quoteId: QUOTE_ID });
        expect(mockNavigate).toHaveBeenCalledTimes(1);
        expect(mockNavigate.mock.calls[0][0].attributes.recordId).toBe('801000000000001AAA');
        expect(element.shadowRoot.textContent).toContain('UNKNOWN_SKU');
    });

    it('renders a load error instead of the summary', async () => {
        const element = createElement('c-quote-approval-panel', { is: QuoteApprovalPanel });
        element.recordId = QUOTE_ID;
        document.body.appendChild(element);
        getApprovalSummary.error({ message: 'Quote not found or you do not have access to it.' });
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('do not have access');
        expect(button(element, 'Approve')).toBeUndefined();
    });
});
