/**
 * Shared builders for Apex tests. Policy (discount tiers, approval thresholds, configuration rules) is
 * injected through the @TestVisible overrides so tests do not depend on whatever Custom Metadata happens
 * to be deployed in the org under test.
 */
@IsTest
public class TestDataFactory {
    public class Catalog {
        public Id pricebookId;
        public Product2 bundle;
        public Product2 seat;
        public Product2 analytics;
        public Product2 connector;
        public Product2 supportStandard;
        public Product2 supportPremium;
        public Product2 securityPack;
        public Product2 sso;
        public Product2 implementation;
    }

    public static final String FINANCE_ROLE = 'QF_Finance_Director';
    public static final String VP_ROLE = 'QF_VP_Sales';

    /** Permission sets per persona, mirroring the shipped permission set groups. */
    public static final List<String> REP_SETS = new List<String>{ 'QF_Base_Access', 'QF_Sales_Rep' };
    public static final List<String> MANAGER_SETS = new List<String>{
        'QF_Base_Access',
        'QF_Sales_Rep',
        'QF_Sales_Manager'
    };
    public static final List<String> FINANCE_SETS = new List<String>{ 'QF_Base_Access', 'QF_Finance_Approver' };
    public static final List<String> INTEGRATION_SETS = new List<String>{ 'QF_Integration_User' };

    // ------------------------------------------------------------------ policy

    public static void installPolicy() {
        DiscountEvaluationService.discountRulesOverride = new List<Discount_Rule__mdt>{
            new Discount_Rule__mdt(
                Product_Family__c = 'Subscriptions',
                Min_Quantity__c = 10,
                Max_Quantity__c = 24.99,
                Discount_Pct__c = 5,
                Is_Active__c = true
            ),
            new Discount_Rule__mdt(
                Product_Family__c = 'Subscriptions',
                Min_Quantity__c = 25,
                Max_Quantity__c = 99.99,
                Discount_Pct__c = 10,
                Is_Active__c = true
            ),
            new Discount_Rule__mdt(
                Product_Family__c = 'Subscriptions',
                Min_Quantity__c = 100,
                Discount_Pct__c = 15,
                Is_Active__c = true
            ),
            new Discount_Rule__mdt(
                Product_Family__c = 'Subscriptions',
                Min_Quantity__c = 1000,
                Discount_Pct__c = 40,
                Is_Active__c = false
            )
        };
        DiscountEvaluationService.thresholdsOverride = new List<Approval_Threshold__mdt>{
            new Approval_Threshold__mdt(
                Level__c = 1,
                Min_Discount_Pct__c = 10,
                Approver_Type__c = 'Manager',
                Is_Active__c = true
            ),
            new Approval_Threshold__mdt(
                Level__c = 2,
                Min_Discount_Pct__c = 20,
                Approver_Type__c = 'Role',
                Approver_Role_Developer_Name__c = FINANCE_ROLE,
                Is_Active__c = true
            ),
            new Approval_Threshold__mdt(
                Level__c = 3,
                Min_Discount_Pct__c = 30,
                Approver_Type__c = 'Role',
                Approver_Role_Developer_Name__c = VP_ROLE,
                Is_Active__c = true
            )
        };
        ProductConfigurationService.rulesOverride = new List<Configuration_Rule__mdt>{
            new Configuration_Rule__mdt(
                Rule_Type__c = 'Requires',
                Bundle_SKU__c = 'QF-PLATFORM-ENT',
                Source_SKU__c = 'QF-ANALYTICS-PRO',
                Target_SKU__c = 'QF-DATA-CONNECTOR',
                Message__c = 'Analytics Pro requires the Data Connector option.',
                Is_Active__c = true
            ),
            new Configuration_Rule__mdt(
                Rule_Type__c = 'Excludes',
                Bundle_SKU__c = 'QF-PLATFORM-ENT',
                Source_SKU__c = 'QF-SUPPORT-PREMIUM',
                Target_SKU__c = 'QF-SUPPORT-STD',
                Message__c = 'Premium and Standard support cannot be combined.',
                Is_Active__c = true
            )
        };
    }

    // ------------------------------------------------------------------ catalogue

    public static Catalog createCatalog() {
        Catalog c = new Catalog();
        c.pricebookId = Test.getStandardPricebookId();
        c.bundle = product(
            'QuoteFlow Platform Enterprise',
            'QF-PLATFORM-ENT',
            'Subscriptions',
            'Bundle',
            'Subscription'
        );
        c.seat = product('Platform User Seat', 'QF-USER-SEAT', 'Subscriptions', 'Standalone', 'Subscription');
        c.analytics = product('Analytics Pro', 'QF-ANALYTICS-PRO', 'Subscriptions', 'Option', 'Subscription');
        c.connector = product('Data Connector', 'QF-DATA-CONNECTOR', 'Subscriptions', 'Option', 'Subscription');
        c.supportStandard = product('Standard Support', 'QF-SUPPORT-STD', 'Subscriptions', 'Option', 'Subscription');
        c.supportPremium = product('Premium Support', 'QF-SUPPORT-PREMIUM', 'Subscriptions', 'Option', 'Subscription');
        c.securityPack = product('Security Pack', 'QF-SECURITY-PACK', 'Subscriptions', 'Option', 'Subscription');
        c.sso = product('Single Sign-On', 'QF-SSO', 'Subscriptions', 'Option', 'Subscription');
        c.implementation = product('Implementation Hours', 'QF-IMPL-HOURLY', 'Services', 'Service', 'One-Time');
        List<Product2> products = new List<Product2>{
            c.bundle,
            c.seat,
            c.analytics,
            c.connector,
            c.supportStandard,
            c.supportPremium,
            c.securityPack,
            c.sso,
            c.implementation
        };
        insert products;

        Map<Id, Decimal> prices = new Map<Id, Decimal>{
            c.bundle.Id => 10000,
            c.seat.Id => 120,
            c.analytics.Id => 2400,
            c.connector.Id => 600,
            c.supportStandard.Id => 1500,
            c.supportPremium.Id => 4000,
            c.securityPack.Id => 1000,
            c.sso.Id => 800,
            c.implementation.Id => 200
        };
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 p : products) {
            entries.add(
                new PricebookEntry(
                    Pricebook2Id = c.pricebookId,
                    Product2Id = p.Id,
                    UnitPrice = prices.get(p.Id),
                    IsActive = true
                )
            );
        }
        insert entries;

        insert new List<Product_Option__c>{
            option(c.bundle, c.seat, true, 'Additive', 5, 5, 500, 1),
            option(c.bundle, c.connector, false, 'Additive', 1, 1, 5, 2),
            option(c.bundle, c.analytics, false, 'Additive', 1, 1, 1, 3),
            option(c.bundle, c.supportStandard, false, 'Additive', 1, 1, 1, 4),
            option(c.bundle, c.supportPremium, false, 'Additive', 1, 1, 1, 5),
            option(c.bundle, c.securityPack, false, 'Included', 1, 1, 1, 6),
            option(c.bundle, c.sso, false, 'Additive', 1, 1, 1, 7)
        };
        return c;
    }

    private static Product2 product(String name, String code, String family, String type, String billing) {
        return new Product2(
            Name = name,
            ProductCode = code,
            Family = family,
            Product_Type__c = type,
            Billing_Model__c = billing,
            ERP_SKU__c = 'ERP-' + code,
            IsActive = true
        );
    }

    private static Product_Option__c option(
        Product2 bundle,
        Product2 optionProduct,
        Boolean required,
        String treatment,
        Decimal defaultQty,
        Decimal min,
        Decimal max,
        Integer sort
    ) {
        return new Product_Option__c(
            Name = optionProduct.Name,
            Bundle_Product__c = bundle.Id,
            Option_Product__c = optionProduct.Id,
            Is_Required__c = required,
            Price_Treatment__c = treatment,
            Default_Quantity__c = defaultQty,
            Min_Quantity__c = min,
            Max_Quantity__c = max,
            Sort_Order__c = sort,
            Is_Active__c = true
        );
    }

    // ------------------------------------------------------------------ customers and quotes

    public static Account account(String name, String erpId) {
        Account account = new Account(Name = name, ERP_Customer_Id__c = erpId);
        insert account;
        return account;
    }

    public static Opportunity opportunity(Id accountId) {
        Opportunity opportunity = new Opportunity(
            Name = 'Platform renewal',
            AccountId = accountId,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        return opportunity;
    }

    public static Quote__c quote(Id accountId, Id pricebookId, Integer termMonths) {
        Quote__c quote = new Quote__c(Account__c = accountId, Pricebook__c = pricebookId, Term_Months__c = termMonths);
        insert quote;
        return quote;
    }

    public static Quote_Line__c line(Id quoteId, Product2 product, Decimal quantity, Decimal manualDiscountPct) {
        return new Quote_Line__c(
            Quote__c = quoteId,
            Product__c = product.Id,
            Quantity__c = quantity,
            Manual_Discount_Pct__c = manualDiscountPct
        );
    }

    /** Quote with one seat line, priced by the trigger. */
    public static Quote__c quoteWithSeats(Catalog catalog, Id accountId, Decimal seats, Decimal manualDiscountPct) {
        Quote__c quote = quote(accountId, catalog.pricebookId, 12);
        insert line(quote.Id, catalog.seat, seats, manualDiscountPct);
        return requery(quote.Id);
    }

    public static Quote__c requery(Id quoteId) {
        return [
            SELECT
                Id,
                Name,
                OwnerId,
                Status__c,
                Approval_Status__c,
                Term_Months__c,
                List_Amount__c,
                Net_Amount__c,
                Total_Discount_Amount__c,
                Blended_Discount_Pct__c,
                Max_Line_Discount_Pct__c,
                Required_Approval_Level__c,
                Current_Approval_Level__c,
                ERP_Sync_Status__c,
                ERP_Sync_Attempts__c,
                ERP_Next_Attempt_At__c,
                ERP_Order_Id__c,
                ERP_Last_Error__c,
                ERP_Sync_Generation__c
            FROM Quote__c
            WHERE Id = :quoteId
        ];
    }

    /** Moves a priced quote to Approved/ERP queued exactly as QuoteApprovalService would (through the system writer). */
    public static Quote__c approve(Quote__c quote, String erpStatus) {
        QuoteStateWriter.updateQuotes(
            new List<Quote__c>{
                new Quote__c(
                    Id = quote.Id,
                    Status__c = QuoteConstants.STATUS_APPROVED,
                    Approval_Status__c = QuoteConstants.APPROVAL_NOT_REQUIRED,
                    ERP_Sync_Status__c = erpStatus,
                    ERP_Sync_Attempts__c = erpStatus == QuoteConstants.ERP_IN_PROGRESS ? 1 : 0,
                    ERP_Sync_Generation__c = 1
                )
            }
        );
        return requery(quote.Id);
    }

    /** Arranges system-owned state for a test, the same way production code is required to: through the writer. */
    public static void setSystemState(Quote__c changes) {
        QuoteStateWriter.updateQuotes(new List<Quote__c>{ changes });
    }

    // ------------------------------------------------------------------ users

    public static Id ensureRole(String developerName) {
        List<UserRole> existing = [SELECT Id FROM UserRole WHERE DeveloperName = :developerName LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        UserRole role = new UserRole(DeveloperName = developerName, Name = developerName.replace('_', ' '));
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert role;
        }
        return role.Id;
    }

    public static User user(String alias, Id roleId, Id managerId, List<String> permissionSetNames) {
        Id profileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        User user = new User(
            Alias = alias,
            LastName = 'QF ' + alias,
            Email = alias + '@quoteflow-test.invalid',
            Username = alias + '.' + System.currentTimeMillis() + '@quoteflow-test.invalid',
            ProfileId = profileId,
            UserRoleId = roleId,
            ManagerId = managerId,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
            assign(user.Id, permissionSetNames);
        }
        return user;
    }

    public static void assign(Id userId, List<String> permissionSetNames) {
        Set<Id> alreadyAssigned = new Set<Id>();
        for (PermissionSetAssignment existing : [
            SELECT PermissionSetId
            FROM PermissionSetAssignment
            WHERE AssigneeId = :userId
        ]) {
            alreadyAssigned.add(existing.PermissionSetId);
        }
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            if (alreadyAssigned.contains(permissionSet.Id)) {
                continue;
            }
            assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSet.Id));
        }
        insert assignments;
    }

    /** The test runner is a CI user; give it the QuoteFlow access an administrator would have. */
    public static void grantRunnerAdminAccess() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            assign(UserInfo.getUserId(), new List<String>{ 'QF_Base_Access', 'QF_Admin' });
        }
    }
}
