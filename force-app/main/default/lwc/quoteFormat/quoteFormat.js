/**
 * Shared presentation helpers for the QuoteFlow components (service component, no template).
 * Keeping these in one module stops the two components drifting apart on formatting and error handling.
 */

/** SLDS theme class per quote / approval / request status. */
export const STATUS_THEME = Object.freeze({
    Draft: 'slds-theme_shade',
    'Pending Approval': 'slds-theme_warning',
    Approved: 'slds-theme_success',
    Rejected: 'slds-theme_error',
    Ordered: 'slds-theme_success',
    Cancelled: 'slds-theme_shade',
    Pending: 'slds-theme_warning',
    'Not Required': 'slds-theme_success',
    'Not Submitted': 'slds-theme_shade',
    Superseded: 'slds-theme_shade',
    'In Progress': 'slds-theme_warning',
    Synced: 'slds-theme_success',
    Failed: 'slds-theme_error'
});

export function badgeClass(status) {
    const theme = STATUS_THEME[status];
    return theme ? `slds-badge ${theme}` : 'slds-badge';
}

const formatters = new Map();

/** Currency formatter for the org/user currency supplied by the server (falls back to USD). */
export function formatCurrency(value, currencyIsoCode) {
    const code = currencyIsoCode || 'USD';
    if (!formatters.has(code)) {
        formatters.set(code, new Intl.NumberFormat(undefined, { style: 'currency', currency: code }));
    }
    return formatters.get(code).format(Number(value) || 0);
}

export function formatPercent(value) {
    return `${(Number(value) || 0).toFixed(2)}%`;
}

/** Client-side mirror of the server rule; the server stays authoritative. */
export function discountError(value, maxDiscountPct) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    return value < 0 || value > maxDiscountPct ? `Enter a value between 0 and ${maxDiscountPct}.` : null;
}

/** Extracts a readable message from an Apex/LDS error without exposing internals. */
export function messageFrom(error) {
    if (!error) {
        return 'An unexpected error occurred.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error.body?.message || error.message || 'An unexpected error occurred.';
}
