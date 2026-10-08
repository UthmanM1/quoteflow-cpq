@IsTest
private class DiscountPolicyServiceTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    @IsTest
    static void activePolicy_currentPolicyWins_expiredIsIgnored() {
        Map<String, Discount_Policy__c> policies;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            policies = DiscountPolicyService.activePoliciesByFamily(
                new Set<String>{ 'Software', 'Services' },
                Date.today()
            );
        }

        Assert.areEqual(40, policies.get('software').Max_Discount_Percent__c);
        Assert.areEqual(20, policies.get('services').Max_Discount_Percent__c);
    }

    @IsTest
    static void applyCaps_familyWithoutPolicy_allowsNoDiscount() {
        List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>{
            new Quote_Configuration_Line__c(Product_Family__c = 'Hardware', Discount_Percent__c = 15),
            new Quote_Configuration_Line__c(Product_Family__c = 'Training', Discount_Percent__c = 1)
        };

        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            DiscountPolicyService.applyCaps(lines, Date.today());
        }

        Assert.areEqual(15, lines[0].Max_Allowed_Discount_Percent__c);
        Assert.isNull(DiscountPolicyService.capViolation(lines[0]), 'The cap itself is allowed');
        Assert.areEqual(0, lines[1].Max_Allowed_Discount_Percent__c);
        Assert.isTrue(DiscountPolicyService.capViolation(lines[1]).contains('exceeds'));
    }

    @IsTest
    static void evaluate_tiersByDiscountAndAmount() {
        SalesLabTestFactory.installRouting();

        Assert.isFalse(
            DiscountPolicyService.evaluate(10, 1000).approvalRequired,
            'Thresholds are strictly greater than'
        );
        Assert.areEqual(1, DiscountPolicyService.evaluate(10.01, 1000).tier);
        Assert.areEqual(2, DiscountPolicyService.evaluate(25, 1000).tier);
        Assert.areEqual(
            2,
            DiscountPolicyService.evaluate(5, 250000).tier,
            'Large deals need finance even at low discount'
        );
        DiscountPolicyService.ApprovalDecision top = DiscountPolicyService.evaluate(35, 1000);
        Assert.areEqual(3, top.tier);
        Assert.areEqual('Sales_Director', top.approverRole);
        Assert.areEqual(30, top.thresholdPercent);
        Assert.areEqual(0, DiscountPolicyService.evaluate(0, 0).tier, 'Inactive tiers are ignored');
    }

    @IsTest
    static void policyRecords_requireTheManagePolicyPermission() {
        Database.SaveResult withoutPermission;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.REP)) {
            withoutPermission = Database.insert(
                SalesLabTestFactory.policy('Rogue policy', 'Software', 90, Date.today(), null),
                false
            );
        }
        Database.SaveResult withPermission;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.FINANCE)) {
            withPermission = Database.insert(
                SalesLabTestFactory.policy('Training', 'Training', 10, Date.today(), null),
                false
            );
        }

        Assert.isFalse(withoutPermission.isSuccess());
        Assert.isTrue(
            withoutPermission.getErrors()[0].getMessage().contains('permission to maintain discount policies')
        );
        Assert.isTrue(withPermission.isSuccess(), 'Finance holds Sales_Manage_Discount_Policy');
    }

    @IsTest
    static void policyRecords_validateDatesAndRange() {
        Database.SaveResult badDates;
        Database.SaveResult badRange;
        System.runAs(SalesLabTestFactory.user(SalesLabTestFactory.ADMIN)) {
            badDates = Database.insert(
                SalesLabTestFactory.policy('Bad dates', 'Software', 10, Date.today(), Date.today().addDays(-1)),
                false
            );
            badRange = Database.insert(
                SalesLabTestFactory.policy('Bad range', 'Software', 120, Date.today(), null),
                false
            );
        }

        Assert.isFalse(badDates.isSuccess());
        Assert.isFalse(badRange.isSuccess());
    }
}
