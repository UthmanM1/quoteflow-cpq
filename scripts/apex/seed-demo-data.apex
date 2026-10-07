// Seeds a small, fictional catalogue for local demos. Run in a scratch org or sandbox ONLY:
//   sf apex run --file scripts/apex/seed-demo-data.apex --target-org <alias>
// The running user needs the QF_Admin permission set. All names are fictional.

Id standardPricebookId = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1].Id;

List<Product2> products = new List<Product2>{
    new Product2(Name = 'QuoteFlow Platform Enterprise', ProductCode = 'QF-PLATFORM-ENT', Family = 'Subscriptions', Product_Type__c = 'Bundle', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-PLATFORM-ENT', IsActive = true),
    new Product2(Name = 'Platform User Seat', ProductCode = 'QF-USER-SEAT', Family = 'Subscriptions', Product_Type__c = 'Standalone', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-USER-SEAT', IsActive = true),
    new Product2(Name = 'Analytics Pro', ProductCode = 'QF-ANALYTICS-PRO', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-ANALYTICS-PRO', IsActive = true),
    new Product2(Name = 'Data Connector', ProductCode = 'QF-DATA-CONNECTOR', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-DATA-CONNECTOR', IsActive = true),
    new Product2(Name = 'Standard Support', ProductCode = 'QF-SUPPORT-STD', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-SUPPORT-STD', IsActive = true),
    new Product2(Name = 'Premium Support', ProductCode = 'QF-SUPPORT-PREMIUM', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-SUPPORT-PREMIUM', IsActive = true),
    new Product2(Name = 'Security Pack', ProductCode = 'QF-SECURITY-PACK', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-SECURITY-PACK', IsActive = true),
    new Product2(Name = 'Single Sign-On', ProductCode = 'QF-SSO', Family = 'Subscriptions', Product_Type__c = 'Option', Billing_Model__c = 'Subscription', ERP_SKU__c = 'ERP-QF-SSO', IsActive = true),
    new Product2(Name = 'Implementation Hours', ProductCode = 'QF-IMPL-HOURLY', Family = 'Services', Product_Type__c = 'Service', Billing_Model__c = 'One-Time', ERP_SKU__c = 'ERP-QF-IMPL-HOURLY', IsActive = true)
};
insert as user products;

Map<String, Product2> byCode = new Map<String, Product2>();
Map<String, Decimal> prices = new Map<String, Decimal>{
    'QF-PLATFORM-ENT' => 10000, 'QF-USER-SEAT' => 120, 'QF-ANALYTICS-PRO' => 2400, 'QF-DATA-CONNECTOR' => 600,
    'QF-SUPPORT-STD' => 1500, 'QF-SUPPORT-PREMIUM' => 4000, 'QF-SECURITY-PACK' => 1000, 'QF-SSO' => 800, 'QF-IMPL-HOURLY' => 200
};
List<PricebookEntry> entries = new List<PricebookEntry>();
for (Product2 p : products) {
    byCode.put(p.ProductCode, p);
    entries.add(new PricebookEntry(Pricebook2Id = standardPricebookId, Product2Id = p.Id, UnitPrice = prices.get(p.ProductCode), IsActive = true));
}
insert as user entries;

Product2 bundle = byCode.get('QF-PLATFORM-ENT');
insert as user new List<Product_Option__c>{
    new Product_Option__c(Name = 'User Seats', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-USER-SEAT').Id, Is_Required__c = true, Price_Treatment__c = 'Additive', Default_Quantity__c = 5, Min_Quantity__c = 5, Max_Quantity__c = 500, Sort_Order__c = 1),
    new Product_Option__c(Name = 'Data Connector', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-DATA-CONNECTOR').Id, Price_Treatment__c = 'Additive', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 5, Sort_Order__c = 2),
    new Product_Option__c(Name = 'Analytics Pro', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-ANALYTICS-PRO').Id, Price_Treatment__c = 'Additive', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 1, Sort_Order__c = 3),
    new Product_Option__c(Name = 'Standard Support', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-SUPPORT-STD').Id, Price_Treatment__c = 'Additive', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 1, Sort_Order__c = 4),
    new Product_Option__c(Name = 'Premium Support', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-SUPPORT-PREMIUM').Id, Price_Treatment__c = 'Additive', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 1, Sort_Order__c = 5),
    new Product_Option__c(Name = 'Security Pack', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-SECURITY-PACK').Id, Price_Treatment__c = 'Included', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 1, Sort_Order__c = 6),
    new Product_Option__c(Name = 'Single Sign-On', Bundle_Product__c = bundle.Id, Option_Product__c = byCode.get('QF-SSO').Id, Price_Treatment__c = 'Additive', Default_Quantity__c = 1, Min_Quantity__c = 1, Max_Quantity__c = 1, Sort_Order__c = 7)
};

Account account = new Account(Name = 'Northwind Demo Traders (fictional)', ERP_Customer_Id__c = 'ERP-C-1001');
insert as user account;
insert as user new Opportunity(Name = 'Northwind platform rollout', AccountId = account.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(45));
System.debug('Seeded ' + products.size() + ' products. Open the Opportunity and use the Quote Configurator.');
