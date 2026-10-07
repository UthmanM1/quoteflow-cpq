/**
 * Formatting and error helpers shared by the RevOps Lab components (service component, no template).
 * Kept separate from the main layer's quoteFormat so the lab deploys on its own.
 */
const formatters = new Map();

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

const THEMES = {
    Draft: 'slds-theme_shade',
    'Pending Approval': 'slds-theme_warning',
    Pending: 'slds-theme_warning',
    Approved: 'slds-theme_success',
    Ordered: 'slds-theme_success',
    'Not Required': 'slds-theme_success',
    Rejected: 'slds-theme_error',
    Recalled: 'slds-theme_shade',
    Cancelled: 'slds-theme_shade',
    'Not Submitted': 'slds-theme_shade'
};

export function badgeClass(status) {
    return THEMES[status] ? `slds-badge ${THEMES[status]}` : 'slds-badge';
}

/** Readable message from an Apex/LDS error; never exposes stack traces. */
export function messageFrom(error) {
    if (!error) {
        return 'An unexpected error occurred.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return error.body?.message || error.message || 'An unexpected error occurred.';
}
