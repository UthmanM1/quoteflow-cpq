/**
 * Test data for the Revenue Operations Lab.
 *
 * Personas are real users holding only the lab permission sets and the lab roles, so tests exercise the same sharing
 * (role hierarchy, Finance sharing rule) and FLS as the org. Approval tiers are injected in memory because Custom
 * Metadata cannot be inserted in tests; discount policies are real records (they are data, not metadata).
 */
@IsTest
public class SalesLabTestFactory {
    public static final String REP = 'rlrep';
    public static final String MANAGER = 'rlmgr';
    public static final String FINANCE = 'rlfin';
    public static final String DIRECTOR = 'rldir';
    public static final String INTEGRATION = 'rlint';
    public static final String ADMIN = 'rladm';
    public static final String OTHER_REP = 'rlrep2';

    public static final List<String> REP_SETS = new List<String>{ 'Sales_Lab_Base', 'Sales_Representative_Access' };
    public static final List<String> MANAGER_SETS = new List<String>{
        'Sales_Lab_Base',
        'Sales_Representative_Access',
        'Sales_Manager_Access'
    };
    public static final List<String> FINANCE_SETS = new List<String>{ 'Sales_Lab_Base', 'Finance_Manager_Access' };
    public static final List<String> DIRECTOR_SETS = new List<String>{
        'Sales_Lab_Base',
        'Sales_Representative_Access',
        'Sales_Manager_Access',
        'Sales_Director_Access'
    };
    public static final List<String> INTEGRATION_SETS = new List<String>{ 'Sales_Integration_Access' };
    public static final List<String> ADMIN_SETS = new List<String>{ 'Sales_Lab_Base', 'Sales_Administrator_Access' };

    public class Catalog {
        public Id pricebookId;
        public Product2 software;
        public Product2 services;
        public Product2 hardware;
        public Product2 unpriced;
    }

    // ------------------------------------------------------------------ policy and routing

    /** Tier 1 > 10% (manager), tier 2 > 20% or >= 250k (finance), tier 3 > 30% or >= 1m (director). */
    public static void installRouting() {
        DiscountPolicyService.routingOverride = new List<Approval_Routing__mdt>{
            new Approval_Routing__mdt(
                Tier__c = 1,
                Min_Discount_Percent__c = 10,
                Approver_Type__c = 'Manager',
                Active__c = true
            ),
            new Approval_Routing__mdt(
                Tier__c = 2,
                Min_Discount_Percent__c = 20,
                Min_Net_Amount__c = 250000,
                Approver_Type__c = 'Role',
                Approver_Role__c = 'Finance_Manager',
                Active__c = true
            ),
            new Approval_Routing__mdt(
                Tier__c = 3,
                Min_Discount_Percent__c = 30,
                Min_Net_Amount__c = 1000000,
                Approver_Type__c = 'Role',
                Approver_Role__c = 'Sales_Director',
                Active__c = true
            ),
            new Approval_Routing__mdt(
                Tier__c = 9,
                Min_Discount_Percent__c = 0,
                Approver_Type__c = 'Manager',
                Active__c = false
            )
        };
    }

    // ------------------------------------------------------------------ the full fixture used by most test classes

    /** Personas, catalogue, policies, and an account + opportunity owned by the rep. Call from @TestSetup. */
    public static void createFixture() {
        Map<String, User> users = createPersonas();
        createCatalog();
        createPolicies(users.get(ADMIN));
        System.runAs(users.get(REP)) {
            Account account = new Account(
                Name = 'Northwind Demo Traders (fictional)',
                ERP_Account_Number__c = 'ERP-1001'
            );
            insert account;
            insert new Opportunity(
                Name = 'Northwind platform rollout',
                AccountId = account.Id,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Pricebook2Id = Test.getStandardPricebookId()
            );
        }
    }

    public static Map<String, User> createPersonas() {
        Id directorRole = roleId('Sales_Director');
        Id managerRole = roleId('Sales_Manager');
        Id repRole = roleId('Sales_Representative');
        Id financeRole = roleId('Finance_Manager');
        Map<String, User> users = new Map<String, User>();
        users.put(DIRECTOR, user(DIRECTOR, directorRole, null, DIRECTOR_SETS));
        users.put(MANAGER, user(MANAGER, managerRole, users.get(DIRECTOR).Id, MANAGER_SETS));
        users.put(REP, user(REP, repRole, users.get(MANAGER).Id, REP_SETS));
        users.put(OTHER_REP, user(OTHER_REP, repRole, users.get(MANAGER).Id, REP_SETS));
        users.put(FINANCE, user(FINANCE, financeRole, users.get(DIRECTOR).Id, FINANCE_SETS));
        users.put(INTEGRATION, user(INTEGRATION, null, null, INTEGRATION_SETS));
        users.put(ADMIN, user(ADMIN, null, null, ADMIN_SETS));
        return users;
    }

    public static Catalog createCatalog() {
        Catalog catalog = new Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        update new Pricebook2(Id = catalog.pricebookId, IsActive = true);
        catalog.software = product('Platform Subscription', 'RL-PLATFORM', 'Software', 'Annual');
        catalog.services = product('Implementation Package', 'RL-IMPL', 'Services', 'One-Time');
        catalog.hardware = product('Edge Appliance', 'RL-EDGE', 'Hardware', 'One-Time');
        catalog.unpriced = product('Unpriced Add-on', 'RL-UNPRICED', 'Software', 'Annual');
        insert new List<Product2>{ catalog.software, catalog.services, catalog.hardware, catalog.unpriced };
        insert new List<PricebookEntry>{
            entry(catalog.pricebookId, catalog.software, 1000),
            entry(catalog.pricebookId, catalog.services, 5000),
            entry(catalog.pricebookId, catalog.hardware, 2500)
        };
        return catalog;
    }

    /** Policies are business data guarded by a validation rule on $Permission, so they are created as the admin persona. */
    public static void createPolicies(User admin) {
        System.runAs(admin) {
            insert new List<Discount_Policy__c>{
                policy('Software 2020 (expired)', 'Software', 10, Date.today().addYears(-6), Date.today().addYears(-1)),
                policy('Software current', 'Software', 40, Date.today().addYears(-1), null),
                policy('Services current', 'Services', 20, Date.today().addYears(-1), null),
                policy('Hardware current', 'Hardware', 15, Date.today().addYears(-1), null)
            };
        }
    }

    public static Discount_Policy__c policy(String name, String family, Decimal maxPct, Date fromDate, Date toDate) {
        return new Discount_Policy__c(
            Name = name,
            Product_Family__c = family,
            Max_Discount_Percent__c = maxPct,
            Effective_From__c = fromDate,
            Effective_To__c = toDate,
            Active__c = true
        );
    }

    // ------------------------------------------------------------------ lookups used by tests

    public static User user(String alias) {
        return [SELECT Id, Name, ManagerId FROM User WHERE Alias = :alias LIMIT 1];
    }

    public static Opportunity opportunity() {
        return [SELECT Id, AccountId, Pricebook2Id FROM Opportunity WHERE Name = 'Northwind platform rollout' LIMIT 1];
    }

    public static Catalog catalog() {
        Catalog catalog = new Catalog();
        catalog.pricebookId = Test.getStandardPricebookId();
        for (Product2 product : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode LIKE 'RL-%']) {
            switch on product.ProductCode {
                when 'RL-PLATFORM' {
                    catalog.software = product;
                }
                when 'RL-IMPL' {
                    catalog.services = product;
                }
                when 'RL-EDGE' {
                    catalog.hardware = product;
                }
                when 'RL-UNPRICED' {
                    catalog.unpriced = product;
                }
            }
        }
        return catalog;
    }

    /** Quote with one line, created as the running user (call inside System.runAs(rep)). */
    public static Quote_Configuration__c quoteWithLine(Product2 product, Decimal quantity, Decimal discountPercent) {
        Quote_Configuration__c quote = new Quote_Configuration__c(
            Opportunity__c = opportunity().Id,
            Term_Months__c = 12
        );
        insert quote;
        insert line(quote.Id, product, quantity, discountPercent);
        return requery(quote.Id);
    }

    public static Quote_Configuration_Line__c line(
        Id quoteId,
        Product2 product,
        Decimal quantity,
        Decimal discountPercent
    ) {
        return new Quote_Configuration_Line__c(
            Quote_Configuration__c = quoteId,
            Product__c = product.Id,
            Quantity__c = quantity,
            Discount_Percent__c = discountPercent
        );
    }

    /** True when the user has record access to the record (read, or edit when needEdit). Read-only; for preconditions. */
    public static Boolean hasAccess(Id userId, Id recordId, Boolean needEdit) {
        List<UserRecordAccess> rows = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :recordId
        ];
        return !rows.isEmpty() && (needEdit ? rows[0].HasEditAccess : rows[0].HasReadAccess);
    }

    /** Failure-message aid: why can (or cannot) this user see this quote? Role, status, access flags and share rows. */
    public static String accessReport(Id userId, Id quoteId) {
        User person = [SELECT Alias, UserRole.DeveloperName FROM User WHERE Id = :userId];
        List<String> parts = new List<String>{
            'user=' +
            person.Alias +
            ', role=' +
            person.UserRole?.DeveloperName,
            'quoteStatus=' + [SELECT Status__c FROM Quote_Configuration__c WHERE Id = :quoteId].Status__c
        };
        for (UserRecordAccess access : [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :quoteId
        ]) {
            parts.add('read=' + access.HasReadAccess + ', edit=' + access.HasEditAccess);
        }
        for (Quote_Configuration__Share share : [
            SELECT RowCause, AccessLevel, UserOrGroupId
            FROM Quote_Configuration__Share
            WHERE ParentId = :quoteId
        ]) {
            parts.add('share ' + share.RowCause + '/' + share.AccessLevel + ' -> ' + share.UserOrGroupId);
        }
        return String.join(parts, '; ');
    }

    public static Quote_Configuration__c requery(Id quoteId) {
        return [
            SELECT
                Id,
                Name,
                OwnerId,
                Status__c,
                Account__c,
                Price_Book__c,
                Valid_Until__c,
                Customer_PO_Number__c,
                Total_List_Amount__c,
                Total_Net_Amount__c,
                Total_Discount_Amount__c,
                Max_Discount_Percent__c,
                Line_Count__c,
                Approval_Required__c,
                Required_Approval_Tier__c,
                Approval_Threshold_Percent__c,
                Submitted_Date__c,
                Approved_Date__c,
                Order__c
            FROM Quote_Configuration__c
            WHERE Id = :quoteId
        ];
    }

    /** Approved quote converted to an order by the rep; returns the order Id (ERP status Pending). */
    public static Id orderedQuote(Decimal softwareQuantity) {
        installRouting();
        Catalog catalog = catalog();
        Id orderId;
        System.runAs(user(REP)) {
            Quote_Configuration__c quote = quoteWithLine(catalog.software, softwareQuantity, 5);
            insert line(quote.Id, catalog.services, 1, 0);
            SalesQuoteApprovalService.submit(quote.Id);
            orderId = OrderConversionService.convert(quote.Id, 'PO-4471').orderId;
        }
        return orderId;
    }

    // ------------------------------------------------------------------ internals

    public static Id roleId(String developerName) {
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

    public static User user(String alias, Id roleId, Id managerId, List<String> permissionSets) {
        Id profileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
        User newUser = new User(
            Alias = alias,
            LastName = 'RevOps ' + alias,
            Email = alias + '@revops-lab-test.invalid',
            Username = alias + '.' + System.currentTimeMillis() + '@revops-lab-test.invalid',
            ProfileId = profileId,
            UserRoleId = roleId,
            ManagerId = managerId,
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert newUser;
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSets]) {
                assignments.add(
                    new PermissionSetAssignment(AssigneeId = newUser.Id, PermissionSetId = permissionSet.Id)
                );
            }
            insert assignments;
        }
        return newUser;
    }

    private static Product2 product(String name, String code, String family, String billing) {
        return new Product2(
            Name = name,
            ProductCode = code,
            Family = family,
            Billing_Frequency__c = billing,
            ERP_Item_Code__c = 'ATL-' + code,
            IsActive = true
        );
    }

    private static PricebookEntry entry(Id pricebookId, Product2 product, Decimal price) {
        return new PricebookEntry(
            Pricebook2Id = pricebookId,
            Product2Id = product.Id,
            UnitPrice = price,
            IsActive = true
        );
    }
}
