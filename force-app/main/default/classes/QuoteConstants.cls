/**
 * Shared vocabulary: picklist values, permission names and the quote lifecycle graph.
 */
public inherited sharing class QuoteConstants {
    public static final String STATUS_DRAFT = 'Draft';
    public static final String STATUS_PENDING_APPROVAL = 'Pending Approval';
    public static final String STATUS_APPROVED = 'Approved';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_ORDERED = 'Ordered';
    public static final String STATUS_CANCELLED = 'Cancelled';

    public static final String APPROVAL_NOT_SUBMITTED = 'Not Submitted';
    public static final String APPROVAL_NOT_REQUIRED = 'Not Required';
    public static final String APPROVAL_PENDING = 'Pending';
    public static final String APPROVAL_APPROVED = 'Approved';
    public static final String APPROVAL_REJECTED = 'Rejected';

    public static final String REQUEST_PENDING = 'Pending';
    public static final String REQUEST_APPROVED = 'Approved';
    public static final String REQUEST_REJECTED = 'Rejected';
    public static final String REQUEST_SUPERSEDED = 'Superseded';

    public static final String ERP_NOT_REQUIRED = 'Not Required';
    public static final String ERP_PENDING = 'Pending';
    public static final String ERP_IN_PROGRESS = 'In Progress';
    public static final String ERP_SYNCED = 'Synced';
    public static final String ERP_FAILED = 'Failed';

    public static final String BILLING_SUBSCRIPTION = 'Subscription';
    public static final String BILLING_ONE_TIME = 'One-Time';

    public static final String PRICING_LIST = 'List Price';
    public static final String PRICING_CONTRACTED = 'Contracted Price';

    public static final String PRODUCT_TYPE_BUNDLE = 'Bundle';

    public static final String OVERRIDE_LOCK_PERMISSION = 'QF_Override_Quote_Lock';
    public static final String REQUEUE_ERP_PERMISSION = 'QF_Requeue_ERP_Sync';

    public static final String PRICE_TREATMENT_INCLUDED = 'Included';

    /** Statuses in which commercial inputs (lines, term, price book) may still change. */
    public static final Set<String> EDITABLE_STATUSES = new Set<String>{ STATUS_DRAFT, STATUS_REJECTED };

    /**
     * Statuses in which a quote may still be (or become) synchronised with the ERP. Converting an approved quote
     * to an Order must not strand a sync that is pending or in flight, so Ordered stays eligible.
     */
    public static final Set<String> ERP_SYNCABLE_STATUSES = new Set<String>{ STATUS_APPROVED, STATUS_ORDERED };

    /** Lifecycle graph. Anything not listed here is rejected by QuoteTriggerHandler. */
    public static final Map<String, Set<String>> ALLOWED_TRANSITIONS = new Map<String, Set<String>>{
        STATUS_DRAFT => new Set<String>{ STATUS_PENDING_APPROVAL, STATUS_APPROVED, STATUS_CANCELLED },
        STATUS_PENDING_APPROVAL => new Set<String>{ STATUS_APPROVED, STATUS_REJECTED, STATUS_DRAFT },
        STATUS_REJECTED => new Set<String>{ STATUS_DRAFT, STATUS_PENDING_APPROVAL, STATUS_APPROVED, STATUS_CANCELLED },
        STATUS_APPROVED => new Set<String>{ STATUS_ORDERED, STATUS_CANCELLED },
        STATUS_ORDERED => new Set<String>(),
        STATUS_CANCELLED => new Set<String>()
    };

    /** Transitions a user may make by editing the record directly (everything else is service-driven). */
    public static final Map<String, Set<String>> USER_TRANSITIONS = new Map<String, Set<String>>{
        STATUS_DRAFT => new Set<String>{ STATUS_CANCELLED },
        STATUS_REJECTED => new Set<String>{ STATUS_DRAFT, STATUS_CANCELLED },
        STATUS_PENDING_APPROVAL => new Set<String>()
    };
}
