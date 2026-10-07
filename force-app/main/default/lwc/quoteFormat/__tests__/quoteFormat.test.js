import { badgeClass, discountError, formatCurrency, formatPercent, messageFrom } from 'c/quoteFormat';

describe('c/quoteFormat', () => {
    it('maps statuses to SLDS badge themes and tolerates unknown values', () => {
        expect(badgeClass('Approved')).toBe('slds-badge slds-theme_success');
        expect(badgeClass('Failed')).toBe('slds-badge slds-theme_error');
        expect(badgeClass('Something new')).toBe('slds-badge');
        expect(badgeClass(undefined)).toBe('slds-badge');
    });

    it('formats currency in the supplied ISO code, defaulting to USD', () => {
        expect(formatCurrency(1234.5, 'EUR')).toContain('1,234.50');
        expect(formatCurrency(null)).toContain('0.00');
        expect(formatCurrency(10)).toContain('$');
    });

    it('formats percentages to two decimals', () => {
        expect(formatPercent(12.345)).toBe('12.35%');
        expect(formatPercent(undefined)).toBe('0.00%');
    });

    it('validates discounts against the server limit', () => {
        expect(discountError(null, 60)).toBeNull();
        expect(discountError(60, 60)).toBeNull();
        expect(discountError(60.5, 60)).toBe('Enter a value between 0 and 60.');
        expect(discountError(-1, 40)).toBe('Enter a value between 0 and 40.');
    });

    it('extracts readable messages from Apex, LDS and plain errors', () => {
        expect(messageFrom({ body: { message: 'Business rule' } })).toBe('Business rule');
        expect(messageFrom({ body: [{ message: 'a' }, { message: 'b' }] })).toBe('a, b');
        expect(messageFrom(new Error('plain'))).toBe('plain');
        expect(messageFrom(undefined)).toBe('An unexpected error occurred.');
    });
});
