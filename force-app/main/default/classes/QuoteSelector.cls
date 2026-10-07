/**
 * Central SOQL for the quoting domain. Every query runs in USER_MODE so CRUD, FLS and sharing of the
 * running user are enforced by the platform. Deliberate exceptions: contracted pricing (ContractedPriceReader
 * below) and approver share rows (QuoteStateWriter.approverShares). Selectors return every field their callers
 * read; a missing field is a runtime SObjectException, so each path is exercised by a test.
 */
public with sharing class QuoteSelector {
    public static List<Quote__c> quotesById(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote__c>();
        }
        return [
            SELECT
                Id,
                Name,
                OwnerId,
                Account__c,
                Account__r.Name,
                Opportunity__c,
                Pricebook__c,
                Status__c,
                Approval_Status__c,
                Term_Months__c,
                Valid_Until__c,
                List_Amount__c,
                Net_Amount__c,
                Total_Discount_Amount__c,
                Blended_Discount_Pct__c,
                Max_Line_Discount_Pct__c,
                Required_Approval_Level__c,
                Current_Approval_Level__c,
                ERP_Sync_Status__c,
                ERP_Order_Id__c,
                ERP_Last_Error__c
            FROM Quote__c
            WHERE Id IN :quoteIds
            WITH USER_MODE
        ];
    }

    /** Row-locks the quotes so concurrent submit/decide calls serialise instead of racing. */
    public static List<Quote__c> quotesForUpdate(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote__c>();
        }
        return [
            SELECT
                Id,
                Name,
                OwnerId,
                Account__c,
                Opportunity__c,
                Pricebook__c,
                Status__c,
                Approval_Status__c,
                Term_Months__c,
                Blended_Discount_Pct__c,
                Max_Line_Discount_Pct__c,
                Required_Approval_Level__c,
                Current_Approval_Level__c,
                ERP_Sync_Status__c,
                ERP_Sync_Generation__c
            FROM Quote__c
            WHERE Id IN :quoteIds
            WITH USER_MODE
            FOR UPDATE
        ];
    }

    public static List<Quote__c> quotesForErp(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote__c>();
        }
        return [
            SELECT
                Id,
                Name,
                Account__c,
                Account__r.ERP_Customer_Id__c,
                Status__c,
                Term_Months__c,
                Valid_Until__c,
                Net_Amount__c,
                ERP_Sync_Status__c,
                ERP_Sync_Attempts__c,
                ERP_Sync_Generation__c,
                ERP_Order_Id__c
            FROM Quote__c
            WHERE Id IN :quoteIds
            WITH USER_MODE
        ];
    }

    /**
     * Quotes the scheduler may pick up: queued, or abandoned mid-flight with an expired lease.
     * Ordered quotes stay eligible so converting a quote to an Order never strands its ERP sync.
     */
    public static List<Quote__c> quotesDueForErpSync(Datetime asOf, Integer maxRecords) {
        return [
            SELECT Id, ERP_Sync_Status__c, ERP_Sync_Attempts__c
            FROM Quote__c
            WHERE
                Status__c IN :QuoteConstants.ERP_SYNCABLE_STATUSES
                AND ERP_Sync_Status__c IN (:QuoteConstants.ERP_PENDING, :QuoteConstants.ERP_IN_PROGRESS)
                AND (ERP_Next_Attempt_At__c = NULL
                OR ERP_Next_Attempt_At__c <= :asOf)
            WITH USER_MODE
            ORDER BY ERP_Next_Attempt_At__c ASC NULLS FIRST, CreatedDate ASC
            LIMIT :maxRecords
            FOR UPDATE
        ];
    }

    public static List<Quote_Line__c> linesForQuotes(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Quote_Line__c>();
        }
        return [
            SELECT
                Id,
                Quote__c,
                Product__c,
                Product__r.Name,
                Product__r.ProductCode,
                Product__r.ERP_SKU__c,
                Parent_Line__c,
                Quantity__c,
                Billing_Model__c,
                Pricing_Source__c,
                Pricebook_Entry_Id__c,
                List_Unit_Price__c,
                Base_Unit_Price__c,
                Schedule_Discount_Pct__c,
                Manual_Discount_Pct__c,
                Effective_Discount_Pct__c,
                Net_Unit_Price__c,
                List_Total__c,
                Net_Total__c,
                Is_Bundle_Component__c,
                Is_Included__c
            FROM Quote_Line__c
            WHERE Quote__c IN :quoteIds
            WITH USER_MODE
            ORDER BY Quote__c, CreatedDate, Id
        ];
    }

    public static List<Quote_Line__c> linesByIds(Set<Id> lineIds) {
        if (lineIds == null || lineIds.isEmpty()) {
            return new List<Quote_Line__c>();
        }
        return [SELECT Id, Quote__c, Product__c FROM Quote_Line__c WHERE Id IN :lineIds WITH USER_MODE];
    }

    /** Component lines of the given bundle headers (used to cascade a header delete). */
    public static List<Quote_Line__c> componentLinesForParents(Set<Id> parentLineIds) {
        if (parentLineIds == null || parentLineIds.isEmpty()) {
            return new List<Quote_Line__c>();
        }
        return [
            SELECT Id, Quote__c, Parent_Line__c
            FROM Quote_Line__c
            WHERE Parent_Line__c IN :parentLineIds
            WITH USER_MODE
        ];
    }

    public static List<AggregateResult> lineTotalsByQuote(Set<Id> quoteIds) {
        return [
            SELECT
                Quote__c quoteId,
                SUM(List_Total__c) listTotal,
                SUM(Net_Total__c) netTotal,
                MAX(Effective_Discount_Pct__c) maxDiscount,
                COUNT(Id) lineCount
            FROM Quote_Line__c
            WHERE Quote__c IN :quoteIds
            WITH USER_MODE
            GROUP BY Quote__c
        ];
    }

    public static Map<Id, Product2> productsById(Set<Id> productIds) {
        if (productIds == null || productIds.isEmpty()) {
            return new Map<Id, Product2>();
        }
        return new Map<Id, Product2>(
            [
                SELECT Id, Name, ProductCode, Family, IsActive, Product_Type__c, Billing_Model__c, ERP_SKU__c
                FROM Product2
                WHERE Id IN :productIds
                WITH USER_MODE
            ]
        );
    }

    public static Map<Id, PricebookEntry> pricebookEntriesByProduct(Id pricebookId, Set<Id> productIds) {
        Map<Id, PricebookEntry> result = new Map<Id, PricebookEntry>();
        if (pricebookId == null || productIds == null || productIds.isEmpty()) {
            return result;
        }
        for (PricebookEntry entry : [
            SELECT Id, Product2Id, UnitPrice
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId AND Product2Id IN :productIds AND IsActive = TRUE
            WITH USER_MODE
        ]) {
            result.put(entry.Product2Id, entry);
        }
        return result;
    }

    public static List<Product_Option__c> activeOptionsForBundles(Set<Id> bundleProductIds) {
        if (bundleProductIds == null || bundleProductIds.isEmpty()) {
            return new List<Product_Option__c>();
        }
        return [
            SELECT
                Id,
                Bundle_Product__c,
                Option_Product__c,
                Option_Product__r.Name,
                Option_Product__r.ProductCode,
                Option_Product__r.IsActive,
                Is_Required__c,
                Price_Treatment__c,
                Default_Quantity__c,
                Min_Quantity__c,
                Max_Quantity__c,
                Sort_Order__c
            FROM Product_Option__c
            WHERE Bundle_Product__c IN :bundleProductIds AND Is_Active__c = TRUE
            WITH USER_MODE
            ORDER BY Sort_Order__c NULLS LAST, Option_Product__r.Name
        ];
    }

    public static List<Approval_Request__c> requestsForQuotes(Set<Id> quoteIds) {
        if (quoteIds == null || quoteIds.isEmpty()) {
            return new List<Approval_Request__c>();
        }
        return [
            SELECT
                Id,
                Name,
                Quote__c,
                Status__c,
                Approval_Level__c,
                Requested_Discount_Pct__c,
                Threshold_Pct__c,
                Approver__c,
                Approver__r.Name,
                Submitted_By__c,
                Submitted_By__r.Name,
                Submitted_Date__c,
                Decision_Date__c,
                Decision_Comments__c
            FROM Approval_Request__c
            WHERE Quote__c IN :quoteIds
            WITH USER_MODE
            ORDER BY Approval_Level__c, CreatedDate
        ];
    }

    public static List<Approval_Request__c> requestForUpdate(Id requestId) {
        return [
            SELECT Id, Quote__c, Status__c, Approval_Level__c, Approver__c, Requested_Discount_Pct__c
            FROM Approval_Request__c
            WHERE Id = :requestId
            WITH USER_MODE
            FOR UPDATE
        ];
    }

    public static List<Opportunity> opportunitiesById(Set<Id> opportunityIds) {
        if (opportunityIds == null || opportunityIds.isEmpty()) {
            return new List<Opportunity>();
        }
        return [
            SELECT Id, Name, AccountId, Account.Name, Pricebook2Id
            FROM Opportunity
            WHERE Id IN :opportunityIds
            WITH USER_MODE
        ];
    }

    public static List<Pricebook2> activePricebooks() {
        return [
            SELECT Id, Name, IsStandard
            FROM Pricebook2
            WHERE IsActive = TRUE
            WITH USER_MODE
            ORDER BY IsStandard DESC, Name
            LIMIT 50
        ];
    }

    /** Sellable catalogue for one price book. Options are excluded; they are only reachable through a bundle. */
    public static List<PricebookEntry> catalogueEntries(Id pricebookId) {
        return [
            SELECT
                Product2Id,
                Product2.Name,
                Product2.ProductCode,
                Product2.Family,
                Product2.Product_Type__c,
                Product2.Billing_Model__c,
                UnitPrice
            FROM PricebookEntry
            WHERE
                Pricebook2Id = :pricebookId
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.Product_Type__c IN ('Standalone', 'Bundle', 'Service')
            WITH USER_MODE
            ORDER BY Product2.Product_Type__c, Product2.Name
            LIMIT 200
        ];
    }

    public static Map<Id, User> usersWithManager(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) {
            return new Map<Id, User>();
        }
        return new Map<Id, User>(
            [
                SELECT Id, Name, ManagerId, Manager.IsActive
                FROM User
                WHERE Id IN :userIds
                WITH USER_MODE
            ]
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

    /**
     * Contracted prices are commercially sensitive, so reps are not granted read access to the object.
     * Pricing still has to honour them, therefore the read runs in system mode but only after confirming
     * the caller can see the account the prices belong to.
     */
    public static Map<Id, Contracted_Price__c> contractedPricesByProduct(Id accountId, Set<Id> productIds, Date asOf) {
        Map<Id, Contracted_Price__c> result = new Map<Id, Contracted_Price__c>();
        if (accountId == null || productIds == null || productIds.isEmpty() || !canReadAccount(accountId)) {
            return result;
        }
        for (Contracted_Price__c price : ContractedPriceReader.read(accountId, productIds, asOf)) {
            Contracted_Price__c current = result.get(price.Product__c);
            if (current == null || price.Start_Date__c > current.Start_Date__c) {
                result.put(price.Product__c, price);
            }
        }
        return result;
    }

    @TestVisible
    private static Boolean canReadAccount(Id accountId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :accountId
            LIMIT 1
        ];
        return !access.isEmpty() && access[0].HasReadAccess;
    }

    private without sharing class ContractedPriceReader {
        private static List<Contracted_Price__c> read(Id accountId, Set<Id> productIds, Date asOf) {
            return [
                SELECT Id, Product__c, Unit_Price__c, Start_Date__c, End_Date__c
                FROM Contracted_Price__c
                WHERE
                    Account__c = :accountId
                    AND Product__c IN :productIds
                    AND Start_Date__c <= :asOf
                    AND (End_Date__c = NULL
                    OR End_Date__c >= :asOf)
            ];
        }
    }
}
