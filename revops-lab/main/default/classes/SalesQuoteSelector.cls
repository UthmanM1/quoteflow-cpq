/**
 * Every SOQL statement of the Revenue Operations Lab. All queries run WITH USER_MODE, so object permissions, field-level
 * security and sharing of the running user are enforced by the platform; callers never see data the user could not.
 * Each method returns exactly the fields its callers read.
 */
public with sharing class SalesQuoteSelector {
    private static final Integer MAX_CATALOGUE_ROWS = 200;

    // ------------------------------------------------------------------ Sales Cloud standard objects

    public static Map<Id, Opportunity> opportunitiesById(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new Map<Id, Opportunity>();
        }
        return new Map<Id, Opportunity>(
            [
                SELECT Id, Name, AccountId, Account.Name, Pricebook2Id, Pricebook2.Name, OwnerId, StageName
                FROM Opportunity
                WHERE Id IN :opportunityIds
                WITH USER_MODE
            ]
        );
    }

    /** Standard price book; tests cannot query it, so they receive Test.getStandardPricebookId(). */
    public static Id standardPricebookId() {
        if (Test.isRunningTest()) {
            return Test.getStandardPricebookId();
        }
        List<Pricebook2> books = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE WITH USER_MODE LIMIT 1];
        return books.isEmpty() ? null : books[0].Id;
    }

    /** One query for any number of price books and products: key is pricebookId + ':' + productId. */
    public static Map<String, PricebookEntry> pricebookEntries(Set<Id> pricebookIds, Set<Id> productIds) {
        Map<String, PricebookEntry> result = new Map<String, PricebookEntry>();
        if (pricebookIds == null || pricebookIds.isEmpty() || productIds == null || productIds.isEmpty()) {
            return result;
        }
        for (PricebookEntry entry : [
            SELECT
                Id,
                Pricebook2Id,
                Product2Id,
                UnitPrice,
                IsActive,
                Product2.Name,
                Product2.ProductCode,
                Product2.Family,
                Product2.IsActive,
                Product2.Billing_Frequency__c
            FROM PricebookEntry
            WHERE Pricebook2Id IN :pricebookIds AND Product2Id IN :productIds
            WITH USER_MODE
        ]) {
            result.put(entryKey(entry.Pricebook2Id, entry.Product2Id), entry);
        }
        return result;
    }

    public static String entryKey(Id pricebookId, Id productId) {
        return String.valueOf(pricebookId) + ':' + String.valueOf(productId);
    }

    public static List<PricebookEntry> catalogue(Id pricebookId) {
        if (pricebookId == null) {
            return new List<PricebookEntry>();
        }
        return [
            SELECT
                Id,
                Product2Id,
                UnitPrice,
                Product2.Name,
                Product2.ProductCode,
                Product2.Family,
                Product2.Billing_Frequency__c
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND IsActive = TRUE AND Product2.IsActive = TRUE
            WITH USER_MODE
            ORDER BY Product2.Family, Product2.Name
            LIMIT :MAX_CATALOGUE_ROWS
        ];
    }

    // ------------------------------------------------------------------ quotes and lines

    public static Map<Id, Quote_Configuration__c> quotesById(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new Map<Id, Quote_Configuration__c>();
        }
        return new Map<Id, Quote_Configuration__c>(
            [
                SELECT
                    Id,
                    Name,
                    OwnerId,
                    Owner.Name,
                    Opportunity__c,
                    Opportunity__r.Name,
                    Account__c,
                    Account__r.Name,
                    Price_Book__c,
                    Status__c,
                    Term_Months__c,
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
                    Order__c
                FROM Quote_Configuration__c
                WHERE Id IN :quoteIds
                WITH USER_MODE
            ]
        );
    }

    /** Row-locks the quotes so concurrent submit/decide/convert calls serialise instead of racing. */
    public static Map<Id, Quote_Configuration__c> quotesForUpdate(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new Map<Id, Quote_Configuration__c>();
        }
        return new Map<Id, Quote_Configuration__c>(
            [
                SELECT
                    Id,
                    Name,
                    OwnerId,
                    Opportunity__c,
                    Account__c,
                    Price_Book__c,
                    Status__c,
                    Term_Months__c,
                    Customer_PO_Number__c,
                    Total_Net_Amount__c,
                    Max_Discount_Percent__c,
                    Line_Count__c,
                    Order__c
                FROM Quote_Configuration__c
                WHERE Id IN :quoteIds
                WITH USER_MODE
                FOR UPDATE
            ]
        );
    }

    public static List<Quote_Configuration_Line__c> linesForQuotes(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote_Configuration_Line__c>();
        }
        return [
            SELECT
                Id,
                Quote_Configuration__c,
                Product__c,
                Product__r.Name,
                Product__r.ProductCode,
                Product__r.ERP_Item_Code__c,
                Quantity__c,
                Discount_Percent__c,
                List_Unit_Price__c,
                Net_Unit_Price__c,
                Net_Total__c,
                Billing_Frequency__c,
                Price_Book_Entry_Id__c
            FROM Quote_Configuration_Line__c
            WHERE Quote_Configuration__c IN :quoteIds
            WITH USER_MODE
            ORDER BY Quote_Configuration__c, Name
        ];
    }

    // ------------------------------------------------------------------ policy

    public static List<Discount_Policy__c> activePolicies(Set<String> families, Date asOf) {
        if (families == null || families.isEmpty()) {
            return new List<Discount_Policy__c>();
        }
        return [
            SELECT Id, Name, Product_Family__c, Max_Discount_Percent__c, Effective_From__c, Effective_To__c
            FROM Discount_Policy__c
            WHERE
                Active__c = TRUE
                AND Product_Family__c IN :families
                AND Effective_From__c <= :asOf
                AND (Effective_To__c = NULL
                OR Effective_To__c >= :asOf)
            WITH USER_MODE
            ORDER BY Effective_From__c DESC
        ];
    }

    // ------------------------------------------------------------------ approvals and users

    public static List<Sales_Approval_Request__c> approvalRequestsForQuotes(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Sales_Approval_Request__c>();
        }
        return [
            SELECT
                Id,
                Name,
                Quote_Configuration__c,
                Status__c,
                Approval_Tier__c,
                Approver__c,
                Approver__r.Name,
                Requested_By__c,
                Requested_By__r.Name,
                Requested_Discount_Percent__c,
                Threshold_Percent__c,
                Quote_Amount__c,
                Comments__c,
                Submitted_Date__c,
                Decision_Date__c
            FROM Sales_Approval_Request__c
            WHERE Quote_Configuration__c IN :quoteIds
            WITH USER_MODE
            ORDER BY Submitted_Date__c DESC, Name DESC
        ];
    }

    public static List<Sales_Approval_Request__c> approvalRequestForUpdate(Id requestId) {
        return [
            SELECT Id, Quote_Configuration__c, Status__c, Approver__c
            FROM Sales_Approval_Request__c
            WHERE Id = :requestId
            WITH USER_MODE
            FOR UPDATE
        ];
    }

    public static Map<Id, User> usersWithManager(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) {
            return new Map<Id, User>();
        }
        return new Map<Id, User>(
            [SELECT Id, Name, ManagerId, Manager.Name, Manager.IsActive FROM User WHERE Id IN :userIds WITH USER_MODE]
        );
    }

    public static List<User> activeUsersInRoles(Set<String> roleDeveloperNames) {
        if (roleDeveloperNames == null || roleDeveloperNames.isEmpty()) {
            return new List<User>();
        }
        return [
            SELECT Id, Name, UserRole.DeveloperName
            FROM User
            WHERE IsActive = TRUE AND UserRole.DeveloperName IN :roleDeveloperNames
            WITH USER_MODE
            ORDER BY Name, Id
        ];
    }

    // ------------------------------------------------------------------ orders (ERP)

    public static Map<Id, Order> ordersForErp(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return new Map<Id, Order>();
        }
        return new Map<Id, Order>(
            [
                SELECT
                    Id,
                    OrderNumber,
                    EffectiveDate,
                    PoNumber,
                    TotalAmount,
                    AccountId,
                    Account.ERP_Account_Number__c,
                    Quote_Configuration__c,
                    ERP_Sync_Status__c,
                    ERP_Retry_Count__c,
                    ERP_Order_Number__c
                FROM Order
                WHERE Id IN :orderIds
                WITH USER_MODE
            ]
        );
    }

    public static List<OrderItem> orderItemsForOrders(Set<Id> orderIds) {
        if (orderIds == null || orderIds.isEmpty()) {
            return new List<OrderItem>();
        }
        return [
            SELECT
                Id,
                OrderId,
                Quantity,
                UnitPrice,
                TotalPrice,
                Product2.Name,
                Product2.ProductCode,
                Product2.ERP_Item_Code__c
            FROM OrderItem
            WHERE OrderId IN :orderIds
            WITH USER_MODE
            ORDER BY OrderId, Id
        ];
    }

    /** Orders waiting for the ERP whose retry time has come. */
    public static List<Order> ordersDueForErp(Datetime asOf, Integer maxRecords) {
        return [
            SELECT Id
            FROM Order
            WHERE
                ERP_Sync_Status__c = :SalesLabConstants.ERP_PENDING
                AND (ERP_Next_Retry_At__c = NULL
                OR ERP_Next_Retry_At__c <= :asOf)
            WITH USER_MODE
            ORDER BY ERP_Next_Retry_At__c ASC NULLS FIRST, CreatedDate ASC
            LIMIT :maxRecords
        ];
    }
}
