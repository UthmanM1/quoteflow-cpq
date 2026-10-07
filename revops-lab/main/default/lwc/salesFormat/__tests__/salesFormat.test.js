import { badgeClass, formatCurrency, formatPercent, messageFrom } from 'c/salesFormat';

describe('c/salesFormat', () => {
    it('formats currency in the server-supplied ISO code and percentages to two decimals', () => {
        expect(formatCurrency(1234.5, 'GBP')).toContain('1,234.50');
        expect(formatCurrency(undefined)).toContain('0.00');
        expect(formatPercent(12.345)).toBe('12.35%');
    });

    it('maps statuses to SLDS badges and tolerates unknown values', () => {
        expect(badgeClass('Approved')).toBe('slds-badge slds-theme_success');
        expect(badgeClass('Rejected')).toBe('slds-badge slds-theme_error');
        expect(badgeClass('Something new')).toBe('slds-badge');
    });

    it('extracts readable messages from Apex, LDS and plain errors', () => {
        expect(messageFrom({ body: { message: 'Only the quote owner can recall it.' } })).toBe(
            'Only the quote owner can recall it.'
        );
        expect(messageFrom({ body: [{ message: 'a' }, { message: 'b' }] })).toBe('a, b');
        expect(messageFrom(new Error('plain'))).toBe('plain');
        expect(messageFrom(null)).toBe('An unexpected error occurred.');
    });
});
