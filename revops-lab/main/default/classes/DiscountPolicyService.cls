/**
 * Discount guardrails and approval routing for the Revenue Operations Lab.
 *
 * Two deliberately different kinds of policy:
 *   Discount_Policy__c       business DATA maintained by Finance in the org (effective-dated cap per product family).
 *                            Changing it needs no deployment, only the Sales_Manage_Discount_Policy permission.
 *   Approval_Routing__mdt    deployed CONFIGURATION (approval tiers). It changes through the release process and is
 *                            read without SOQL (getAll), so it costs nothing in a trigger.
 */
public with sharing class DiscountPolicyService {
    public class ApprovalDecision {
        @AuraEnabled
        public Boolean approvalRequired = false;
        @AuraEnabled
        public Integer tier = 0;
        @AuraEnabled
        public Decimal thresholdPercent;
        @AuraEnabled
        public Decimal netAmountThreshold;
        @AuraEnabled
        public String approverType;
        @AuraEnabled
        public String approverRole;
        @AuraEnabled
        public String reason;
    }

    @TestVisible
    private static List<Approval_Routing__mdt> routingOverride;

    // ------------------------------------------------------------------ discount caps

    /** Most recent active policy per product family on the given date (one query). */
    public static Map<String, Discount_Policy__c> activePoliciesByFamily(Set<String> families, Date asOf) {
        Map<String, Discount_Policy__c> byFamily = new Map<String, Discount_Policy__c>();
        // Ordered by Effective_From__c DESC, so the first policy seen for a family is the one in force.
        for (Discount_Policy__c policy : SalesQuoteSelector.activePolicies(families, asOf)) {
            String key = policy.Product_Family__c.toLowerCase();
            if (!byFamily.containsKey(key)) {
                byFamily.put(key, policy);
            }
        }
        return byFamily;
    }

    /**
     * Sets Max_Allowed_Discount_Percent__c on each line from its family's policy. A family without a policy gets a
     * cap of 0 (no discount without an explicit policy). Lines must already be priced (Product_Family__c set).
     */
    public static void applyCaps(List<Quote_Configuration_Line__c> lines, Date asOf) {
        Set<String> families = new Set<String>();
        for (Quote_Configuration_Line__c line : lines) {
            if (String.isNotBlank(line.Product_Family__c)) {
                families.add(line.Product_Family__c);
            }
        }
        Map<String, Discount_Policy__c> policies = activePoliciesByFamily(families, asOf);
        for (Quote_Configuration_Line__c line : lines) {
            Discount_Policy__c policy = String.isBlank(line.Product_Family__c)
                ? null
                : policies.get(line.Product_Family__c.toLowerCase());
            line.Max_Allowed_Discount_Percent__c = policy == null ? 0 : policy.Max_Discount_Percent__c;
        }
    }

    /** User-facing message when a line breaks its cap, or null. Mirrors the Discount_Within_Policy validation rule. */
    public static String capViolation(Quote_Configuration_Line__c line) {
        Decimal discount = line.Discount_Percent__c == null ? 0 : line.Discount_Percent__c;
        Decimal cap = line.Max_Allowed_Discount_Percent__c == null ? 0 : line.Max_Allowed_Discount_Percent__c;
        if (discount < 0) {
            return 'Discount cannot be negative.';
        }
        if (discount > cap) {
            return 'Discount of ' +
                discount +
                '% exceeds the ' +
                cap +
                '% maximum for ' +
                (String.isBlank(line.Product_Family__c) ? 'this product' : line.Product_Family__c) +
                '.';
        }
        return null;
    }

    // ------------------------------------------------------------------ approval routing

    /**
     * Highest active tier that applies. A tier applies when the max line discount is strictly above its discount
     * threshold, or when the net amount reaches its optional amount threshold.
     */
    public static ApprovalDecision evaluate(Decimal maxDiscountPercent, Decimal netAmount) {
        ApprovalDecision decision = new ApprovalDecision();
        Decimal discount = maxDiscountPercent == null ? 0 : maxDiscountPercent;
        Decimal amount = netAmount == null ? 0 : netAmount;
        for (Approval_Routing__mdt tier : routing()) {
            if (tier.Active__c != true || tier.Tier__c == null) {
                continue;
            }
            Boolean byDiscount = tier.Min_Discount_Percent__c != null && discount > tier.Min_Discount_Percent__c;
            Boolean byAmount = tier.Min_Net_Amount__c != null && amount >= tier.Min_Net_Amount__c;
            Integer level = Integer.valueOf(tier.Tier__c);
            if ((byDiscount || byAmount) && level > decision.tier) {
                decision.approvalRequired = true;
                decision.tier = level;
                decision.thresholdPercent = tier.Min_Discount_Percent__c;
                decision.netAmountThreshold = tier.Min_Net_Amount__c;
                decision.approverType = tier.Approver_Type__c;
                decision.approverRole = tier.Approver_Role__c;
                decision.reason = byDiscount
                    ? 'Discount above ' + tier.Min_Discount_Percent__c + '%'
                    : 'Net amount of at least ' + tier.Min_Net_Amount__c;
            }
        }
        if (!decision.approvalRequired) {
            decision.reason = 'Within discount policy';
        }
        return decision;
    }

    private static List<Approval_Routing__mdt> routing() {
        return routingOverride != null ? routingOverride : Approval_Routing__mdt.getAll().values();
    }
}
