@IsTest
private class DiscountEvaluationServiceTest {
    @TestSetup
    static void setup() {
        TestDataFactory.installPolicy();
    }

    @IsTest
    static void scheduleDiscount_tierBoundaries_selectsMatchingTier() {
        TestDataFactory.installPolicy();

        Test.startTest();
        Decimal belowFirstTier = DiscountEvaluationService.scheduleDiscountPct('Subscriptions', 9.99);
        Decimal firstTierLowerBound = DiscountEvaluationService.scheduleDiscountPct('Subscriptions', 10);
        Decimal secondTierLowerBound = DiscountEvaluationService.scheduleDiscountPct('Subscriptions', 25);
        Decimal openEndedTier = DiscountEvaluationService.scheduleDiscountPct('Subscriptions', 5000);
        Test.stopTest();

        Assert.areEqual(0, belowFirstTier, 'No tier below the first minimum');
        Assert.areEqual(5, firstTierLowerBound, 'Lower bound is inclusive');
        Assert.areEqual(10, secondTierLowerBound, 'Second tier starts at 25');
        Assert.areEqual(15, openEndedTier, 'Inactive 1000+ tier must be ignored; the open-ended 100+ tier applies');
    }

    @IsTest
    static void scheduleDiscount_unknownFamilyOrBadQuantity_returnsZero() {
        TestDataFactory.installPolicy();

        Assert.areEqual(0, DiscountEvaluationService.scheduleDiscountPct('Hardware', 50), 'Family with no rules');
        Assert.areEqual(0, DiscountEvaluationService.scheduleDiscountPct(null, 50), 'Blank family');
        Assert.areEqual(0, DiscountEvaluationService.scheduleDiscountPct('Subscriptions', null), 'Null quantity');
        Assert.areEqual(0, DiscountEvaluationService.scheduleDiscountPct('Subscriptions', 0), 'Zero quantity');
        Assert.areEqual(
            5,
            DiscountEvaluationService.scheduleDiscountPct('subscriptions', 10),
            'Family match is case-insensitive'
        );
    }

    @IsTest
    static void evaluate_thresholdsAreStrictlyExceeded() {
        TestDataFactory.installPolicy();

        Assert.areEqual(0, DiscountEvaluationService.evaluate(10).level, 'Exactly at the threshold needs no approval');
        Assert.areEqual(1, DiscountEvaluationService.evaluate(10.01).level);
        Assert.areEqual(1, DiscountEvaluationService.evaluate(20).level);
        Assert.areEqual(2, DiscountEvaluationService.evaluate(20.01).level);
        Assert.areEqual(3, DiscountEvaluationService.evaluate(45).level, 'Highest exceeded level wins');
        Assert.areEqual(0, DiscountEvaluationService.evaluate(null).level, 'Null is treated as no discount');
        Assert.areEqual(
            10,
            DiscountEvaluationService.evaluate(12).thresholdPct,
            'Reports the threshold that was exceeded'
        );
    }

    @IsTest
    static void evaluate_inactiveThreshold_isIgnored() {
        DiscountEvaluationService.thresholdsOverride = new List<Approval_Threshold__mdt>{
            new Approval_Threshold__mdt(
                Level__c = 1,
                Min_Discount_Pct__c = 10,
                Approver_Type__c = 'Manager',
                Is_Active__c = false
            ),
            new Approval_Threshold__mdt(
                Level__c = 2,
                Min_Discount_Pct__c = 20,
                Approver_Type__c = 'Manager',
                Is_Active__c = true
            )
        };

        Assert.areEqual(0, DiscountEvaluationService.evaluate(15).level, 'Level 1 is switched off');
        Assert.areEqual(2, DiscountEvaluationService.evaluate(25).level);
        Assert.areEqual(1, DiscountEvaluationService.activeThresholds().size(), 'Only active thresholds are listed');
    }

    @IsTest
    static void evaluate_quotes_usesMaxLineDiscount() {
        TestDataFactory.installPolicy();
        Quote__c low = new Quote__c(Max_Line_Discount_Pct__c = 5);
        Quote__c high = new Quote__c(Max_Line_Discount_Pct__c = 35);
        // Ids are only used as map keys, so fabricate stable ones without DML.
        low.Id = Quote__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        high.Id = Quote__c.SObjectType.getDescribe().getKeyPrefix() + '000000000002';

        Map<Id, DiscountEvaluationService.ApprovalRequirement> result = DiscountEvaluationService.evaluate(
            new List<Quote__c>{ low, high }
        );

        Assert.areEqual(false, result.get(low.Id).approvalRequired);
        Assert.areEqual(3, result.get(high.Id).level);
    }
}
