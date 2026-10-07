/**
 * Shared vocabulary for the Revenue Operations Lab: picklist values and custom permission names.
 */
public inherited sharing class SalesLabConstants {
    public static final String QUOTE_DRAFT = 'Draft';
    public static final String QUOTE_PENDING = 'Pending Approval';
    public static final String QUOTE_APPROVED = 'Approved';
    public static final String QUOTE_REJECTED = 'Rejected';
    public static final String QUOTE_ORDERED = 'Ordered';
    public static final String QUOTE_CANCELLED = 'Cancelled';

    /** Statuses in which lines and commercial terms may still change. */
    public static final Set<String> EDITABLE_QUOTE_STATUSES = new Set<String>{ QUOTE_DRAFT, QUOTE_REJECTED };

    public static final String REQUEST_PENDING = 'Pending';
    public static final String REQUEST_APPROVED = 'Approved';
    public static final String REQUEST_REJECTED = 'Rejected';
    public static final String REQUEST_RECALLED = 'Recalled';

    public static final String BILLING_ANNUAL = 'Annual';
    public static final String BILLING_ONE_TIME = 'One-Time';

    public static final String ERP_NOT_SENT = 'Not Sent';
    public static final String ERP_PENDING = 'Pending';
    public static final String ERP_SYNCED = 'Synced';
    public static final String ERP_FAILED = 'Failed';

    public static final String APPROVER_MANAGER = 'Manager';
    public static final String APPROVER_ROLE = 'Role';

    public static final String PERMISSION_OVERRIDE_LOCK = 'Sales_Override_Quote_Lock';
    public static final String PERMISSION_RUN_ERP_SYNC = 'Sales_Run_ERP_Sync';

    public static final Integer MIN_REJECTION_COMMENT_LENGTH = 10;
    public static final Integer MAX_TERM_MONTHS = 60;
}
