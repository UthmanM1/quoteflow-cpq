/**
 * Pure discount policy: volume schedules and approval thresholds.
 * Policy lives in Custom Metadata (Discount_Rule__mdt, Approval_Threshold__mdt) so that commercial
 * operations can change it through a normal deployment without touching code. The class has no DML and
 * no SOQL, which keeps it cheap to call from triggers and trivial to unit test.
 */
public with sharing class DiscountEvaluationService {
    public class ApprovalRequirement {
        public Integer level = 0;
        public Decimal thresholdPct;
        public Boolean approvalRequired {
            get {
                return level > 0;
            }
        }
    }

    /** CMDT cannot be inserted in tests; tests inject in-memory records here instead. */
    @TestVisible
    private static List<Discount_Rule__mdt> discountRulesOverride;
    @TestVisible
    private static List<Approval_Threshold__mdt> thresholdsOverride;

    /**
     * Volume discount for one line. The most generous active tier whose range contains the quantity wins;
     * tiers are matched per line, not aggregated across the quote (see TECHNICAL-DECISIONS, TD-09).
     */
    public static Decimal scheduleDiscountPct(String productFamily, Decimal quantity) {
        if (String.isBlank(productFamily) || quantity == null || quantity <= 0) {
            return 0;
        }
        Discount_Rule__mdt best;
        for (Discount_Rule__mdt rule : discountRules()) {
            if (rule.Is_Active__c != true || !productFamily.equalsIgnoreCase(rule.Product_Family__c)) {
                continue;
            }
            Boolean aboveMin = quantity >= nz(rule.Min_Quantity__c);
            Boolean belowMax = rule.Max_Quantity__c == null || quantity <= rule.Max_Quantity__c;
            if (aboveMin && belowMax && (best == null || nz(rule.Discount_Pct__c) > nz(best.Discount_Pct__c))) {
                best = rule;
            }
        }
        return best == null ? 0 : nz(best.Discount_Pct__c);
    }

    /** Highest approval level whose threshold is strictly exceeded by the discount. Level 0 = no approval. */
    public static ApprovalRequirement evaluate(Decimal discountPct) {
        ApprovalRequirement result = new ApprovalRequirement();
        Decimal pct = nz(discountPct);
        for (Approval_Threshold__mdt threshold : thresholds()) {
            if (threshold.Is_Active__c != true || threshold.Level__c == null) {
                continue;
            }
            Integer level = Integer.valueOf(threshold.Level__c);
            if (pct > nz(threshold.Min_Discount_Pct__c) && level > result.level) {
                result.level = level;
                result.thresholdPct = threshold.Min_Discount_Pct__c;
            }
        }
        return result;
    }

    public static Map<Id, ApprovalRequirement> evaluate(List<Quote__c> quotes) {
        Map<Id, ApprovalRequirement> result = new Map<Id, ApprovalRequirement>();
        for (Quote__c quote : quotes) {
            result.put(quote.Id, evaluate(quote.Max_Line_Discount_Pct__c));
        }
        return result;
    }

    /** Threshold configuration for a given level; null when the level is not configured or inactive. */
    public static Approval_Threshold__mdt thresholdForLevel(Integer level) {
        for (Approval_Threshold__mdt threshold : thresholds()) {
            if (
                threshold.Is_Active__c == true &&
                threshold.Level__c != null &&
                Integer.valueOf(threshold.Level__c) == level
            ) {
                return threshold;
            }
        }
        return null;
    }

    /** Active thresholds ordered by level, for display. */
    public static List<Approval_Threshold__mdt> activeThresholds() {
        List<Approval_Threshold__mdt> active = new List<Approval_Threshold__mdt>();
        for (Integer level = 1; level <= 9; level++) {
            Approval_Threshold__mdt threshold = thresholdForLevel(level);
            if (threshold != null) {
                active.add(threshold);
            }
        }
        return active;
    }

    private static List<Discount_Rule__mdt> discountRules() {
        return discountRulesOverride != null ? discountRulesOverride : Discount_Rule__mdt.getAll().values();
    }

    private static List<Approval_Threshold__mdt> thresholds() {
        return thresholdsOverride != null ? thresholdsOverride : Approval_Threshold__mdt.getAll().values();
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }
}
