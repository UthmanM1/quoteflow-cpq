import { createElement } from 'lwc';
import SalesApprovalPanel from 'c/salesApprovalPanel';
import getApprovalSummary from '@salesforce/apex/SalesApprovalController.getApprovalSummary';
import decide from '@salesforce/apex/SalesApprovalController.decide';
import recallQuote from '@salesforce/apex/SalesApprovalController.recallQuote';
import convertToOrder from '@salesforce/apex/SalesApprovalController.convertToOrder';
import { refreshApex } from '@salesforce/apex';
import { mockNavigate } from 'lightning/navigation';

jest.mock(
    '@salesforce/apex/SalesApprovalController.getApprovalSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/SalesApprovalController.decide', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SalesApprovalController.recallQuote', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SalesApprovalController.convertToOrder', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex', () => ({ refreshApex: jest.fn(() => Promise.resolve()) }), { virtual: true });
jest.mock('lightning/uiRecordApi', () => ({ notifyRecordUpdateAvailable: jest.fn(() => Promise.resolve()) }), {
    virtual: true
});
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

const QUOTE_ID = 'a00000000000001AAA';
const PENDING = {
    quoteId: QUOTE_ID,
    quoteName: 'QC-000042',
    status: 'Pending Approval',
    listAmount: 10000,
    netAmount: 7500,
    discountAmount: 2500,
    requestedDiscountPercent: 25,
    thresholdPercent: 20,
    tier: 2,
    approvalRequired: true,
    approvalStatus: 'Pending',
    approverName: 'Fran Finance',
    pendingRequestId: 'a01000000000001AAA',
    latestComments: null,
    canDecide: true,
    canRecall: false,
    canConvert: false,
    minCommentLength: 12,
    currencyIsoCode: 'GBP',
    history: [{ id: 'a01000000000001AAA', status: 'Pending', tier: 2, approverName: 'Fran Finance' }]
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function render(summary) {
    const element = createElement('c-sales-approval-panel', { is: SalesApprovalPanel });
    element.recordId = QUOTE_ID;
    document.body.appendChild(element);
    getApprovalSummary.emit(summary);
    await flush();
    return element;
}

const button = (element, label) =>
    [...element.shadowRoot.querySelectorAll('lightning-button')].find((b) => b.label === label);
const text = (element, id) => element.shadowRoot.querySelector(`[data-id="${id}"]`).textContent;

describe('c-sales-approval-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows amount, requested discount, threshold, approver and status', async () => {
        const element = await render(PENDING);

        expect(text(element, 'net')).toBe('£7,500.00');
        expect(text(element, 'requested')).toBe('25.00%');
        expect(text(element, 'threshold')).toBe('20.00% (Tier 2)');
        expect(text(element, 'approver')).toBe('Fran Finance');
        expect(text(element, 'approval-status')).toBe('Pending');
    });

    it('requires the server-supplied minimum comment before rejecting', async () => {
        const element = await render(PENDING);
        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Too low' } }));
        await flush();

        button(element, 'Reject').click();
        await flush();

        expect(decide).not.toHaveBeenCalled();
        expect(element.shadowRoot.textContent).toContain('at least 12 characters');
    });

    it('approves and refreshes the wired summary', async () => {
        decide.mockResolvedValue();
        const element = await render(PENDING);

        button(element, 'Approve').click();
        await flush();

        expect(decide).toHaveBeenCalledWith({ requestId: PENDING.pendingRequestId, approve: true, comments: '' });
        expect(refreshApex).toHaveBeenCalled();
    });

    it('keeps the comment and shows the reason when a rejection is refused', async () => {
        decide.mockRejectedValue({ body: { message: 'This request has already been decided.' } });
        const element = await render(PENDING);
        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Margin below the segment floor.' } }));
        await flush();

        button(element, 'Reject').click();
        await flush();

        expect(text(element, 'action-error')).toContain('already been decided');
        expect(element.shadowRoot.querySelector('lightning-textarea').value).toBe('Margin below the segment floor.');
    });

    it('hides decision controls from everyone but the approver and lets the owner recall', async () => {
        recallQuote.mockResolvedValue();
        const element = await render({ ...PENDING, canDecide: false, canRecall: true });

        expect(button(element, 'Approve')).toBeUndefined();
        button(element, 'Recall').click();
        await flush();

        expect(recallQuote).toHaveBeenCalledWith({ quoteId: QUOTE_ID });
    });

    it('requires a PO number, then converts and navigates to the order', async () => {
        convertToOrder.mockResolvedValue('801000000000001AAA');
        const element = await render({
            ...PENDING,
            status: 'Approved',
            approvalStatus: 'Approved',
            latestComments: 'Margin acceptable.',
            canDecide: false,
            canConvert: true,
            customerPoNumber: null
        });
        expect(text(element, 'comments')).toBe('Margin acceptable.');

        button(element, 'Convert to order').click();
        await flush();
        expect(convertToOrder).not.toHaveBeenCalled();
        expect(text(element, 'action-error')).toContain('PO number');

        element.shadowRoot
            .querySelector('[data-id="po"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'PO-4471' } }));
        await flush();
        button(element, 'Convert to order').click();
        await flush();

        expect(convertToOrder).toHaveBeenCalledWith({ quoteId: QUOTE_ID, customerPoNumber: 'PO-4471' });
        expect(mockNavigate.mock.calls[0][0].attributes.recordId).toBe('801000000000001AAA');
    });

    it('renders a load error instead of the summary', async () => {
        const element = createElement('c-sales-approval-panel', { is: SalesApprovalPanel });
        element.recordId = QUOTE_ID;
        document.body.appendChild(element);
        getApprovalSummary.error({ message: 'Quote not found or you do not have access to it.' });
        await flush();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('do not have access');
    });
});
