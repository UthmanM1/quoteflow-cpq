// RevOps Lab demo data. FICTIONAL companies and products. Run in a Developer Edition org, Trailhead Playground or
// scratch org ONLY, after deploying revops-lab and assigning yourself Sales_Administrator_PSG (the discount policy
// validation rule requires the Sales_Manage_Discount_Policy custom permission):
//
//   sf apex run --file scripts/apex/seed-revops-lab.apex --target-org <alias>
//
// Re-running creates duplicates; delete the RL-* products and the fictional account first.

Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1].Id;
update new Pricebook2(Id = standardPricebookId, IsActive = true);

List<Product2> products = new List<Product2>{
    new Product2(Name = 'Platform Subscription', ProductCode = 'RL-PLATFORM', Family = 'Software', Billing_Frequency__c = 'Annual', ERP_Item_Code__c = 'ATL-RL-PLATFORM', IsActive = true),
    new Product2(Name = 'Analytics Add-on', ProductCode = 'RL-ANALYTICS', Family = 'Software', Billing_Frequency__c = 'Annual', ERP_Item_Code__c = 'ATL-RL-ANALYTICS', IsActive = true),
    new Product2(Name = 'Implementation Package', ProductCode = 'RL-IMPL', Family = 'Services', Billing_Frequency__c = 'One-Time', ERP_Item_Code__c = 'ATL-RL-IMPL', IsActive = true),
    new Product2(Name = 'Edge Appliance', ProductCode = 'RL-EDGE', Family = 'Hardware', Billing_Frequency__c = 'One-Time', ERP_Item_Code__c = 'ATL-RL-EDGE', IsActive = true)
};
insert as user products;

Map<String, Decimal> prices = new Map<String, Decimal>{ 'RL-PLATFORM' => 1000, 'RL-ANALYTICS' => 400, 'RL-IMPL' => 5000, 'RL-EDGE' => 2500 };
List<PricebookEntry> entries = new List<PricebookEntry>();
for (Product2 product : products) {
    entries.add(new PricebookEntry(Pricebook2Id = standardPricebookId, Product2Id = product.Id, UnitPrice = prices.get(product.ProductCode), IsActive = true));
}
insert as user entries;

insert as user new List<Discount_Policy__c>{
    new Discount_Policy__c(Name = 'Software (current)', Product_Family__c = 'Software', Max_Discount_Percent__c = 40, Effective_From__c = Date.today().addYears(-1), Active__c = true),
    new Discount_Policy__c(Name = 'Services (current)', Product_Family__c = 'Services', Max_Discount_Percent__c = 20, Effective_From__c = Date.today().addYears(-1), Active__c = true),
    new Discount_Policy__c(Name = 'Hardware (current)', Product_Family__c = 'Hardware', Max_Discount_Percent__c = 15, Effective_From__c = Date.today().addYears(-1), Active__c = true)
};

Account account = new Account(Name = 'Northwind Demo Traders (fictional)', Customer_Segment__c = 'Enterprise', ERP_Account_Number__c = 'ERP-1001');
insert as user account;
insert as user new Contact(FirstName = 'Jordan', LastName = 'Example (fictional)', AccountId = account.Id, Buying_Role__c = 'Economic Buyer', Email = 'jordan.example@example.invalid');
insert as user new Opportunity(Name = 'Northwind platform rollout', AccountId = account.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(45), Pricebook2Id = standardPricebookId);

System.debug('RevOps Lab seeded. Open the Northwind opportunity and use the Sales Quote Configurator.');
