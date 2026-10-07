@IsTest
private class QuoteTriggerTest {
    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        TestDataFactory.account('Fabrikam', 'ERP-F-1');
        TestDataFactory.user('qftrep', null, null, new List<String>{ 'QF_Base_Access', 'QF_Sales_Rep' });
    }

    private static TestDataFactory.Catalog catalog() {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog c = new TestDataFactory.Catalog();
        c.pricebookId = Test.getStandardPricebookId();
        c.seat = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'];
        c.bundle = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-PLATFORM-ENT'];
        c.securityPack = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-SECURITY-PACK'];
        c.sso = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-SSO'];
        return c;
    }

    private static Account account() {
        return [SELECT Id FROM Account LIMIT 1];
    }

    @IsTest
    static void insert_forcesDraftStateAndAppliesDefaults() {
        Quote__c quote = new Quote__c(
            Account__c = account().Id,
            Pricebook__c = Test.getStandardPricebookId(),
            Status__c = 'Approved',
            Approval_Status__c = 'Approved',
            ERP_Order_Id__c = 'FAKE-1',
            Net_Amount__c = 999999
        );

        insert quote;

        Quote__c result = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Draft', result.Status__c, 'A quote cannot be created pre-approved');
        Assert.areEqual('Not Submitted', result.Approval_Status__c);
        Assert.areEqual(null, result.ERP_Order_Id__c);
        Assert.areEqual(0, result.Net_Amount__c);
        Assert.areEqual(12, result.Term_Months__c, 'Default term');
    }

    @IsTest
    static void insert_accountDefaultsFromOpportunity_andMismatchIsRejected() {
        Account other = TestDataFactory.account('Other Co', 'ERP-O-1');
        Opportunity opportunity = TestDataFactory.opportunity(account().Id);

        Quote__c defaulted = new Quote__c(
            Opportunity__c = opportunity.Id,
            Pricebook__c = Test.getStandardPricebookId()
        );
        insert defaulted;
        Database.SaveResult mismatch = Database.insert(
            new Quote__c(
                Account__c = other.Id,
                Opportunity__c = opportunity.Id,
                Pricebook__c = Test.getStandardPricebookId()
            ),
            false
        );

        Assert.areEqual(account().Id, [SELECT Account__c FROM Quote__c WHERE Id = :defaulted.Id].Account__c);
        Assert.isTrue(!mismatch.isSuccess());
        Assert.isTrue(mismatch.getErrors()[0].getMessage().contains('different account'));
    }

    @IsTest
    static void insert_invalidTermOrMissingAccount_isRejected() {
        Database.SaveResult tooLong = Database.insert(
            new Quote__c(Account__c = account().Id, Term_Months__c = 61),
            false
        );
        Database.SaveResult noAccount = Database.insert(new Quote__c(Term_Months__c = 12), false);

        Assert.isTrue(!tooLong.isSuccess());
        Assert.isTrue(tooLong.getErrors()[0].getMessage().contains('between 1 and 60'));
        Assert.isTrue(!noAccount.isSuccess());
        Assert.isTrue(noAccount.getErrors()[0].getMessage().contains('account is required'));
    }

    @IsTest
    static void insert_twoHundredQuotes_isBulkSafe() {
        List<Quote__c> quotes = new List<Quote__c>();
        for (Integer i = 0; i < 200; i++) {
            quotes.add(new Quote__c(Account__c = account().Id, Pricebook__c = Test.getStandardPricebookId()));
        }

        Test.startTest();
        insert quotes;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Quote__c WHERE Status__c = 'Draft']);
    }

    @IsTest
    static void update_userCannotSelfApprove_orEditSystemFields() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);

        Database.SaveResult selfApprove = Database.update(new Quote__c(Id = quote.Id, Status__c = 'Approved'), false);
        Database.SaveResult editTotals = Database.update(new Quote__c(Id = quote.Id, Net_Amount__c = 1), false);
        Database.SaveResult forgeApproval = Database.update(
            new Quote__c(Id = quote.Id, Approval_Status__c = 'Approved'),
            false
        );

        Assert.isTrue(!selfApprove.isSuccess());
        Assert.isTrue(selfApprove.getErrors()[0].getMessage().contains('cannot move from Draft to Approved'));
        Assert.isTrue(!editTotals.isSuccess());
        Assert.isTrue(!forgeApproval.isSuccess());
        Assert.areEqual('Draft', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void update_serviceTransition_followsLifecycleGraph() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);
        TestDataFactory.approve(quote, QuoteConstants.ERP_PENDING);

        // Even the system writer must follow the lifecycle graph.
        Database.SaveResult backwards = QuoteStateWriter.updateQuotesPartial(
            new List<Quote__c>{ new Quote__c(Id = quote.Id, Status__c = 'Rejected') }
        )[0];

        Assert.isFalse(backwards.isSuccess(), 'Approved -> Rejected is not an allowed transition');
        Assert.isFalse(QuoteTriggerContext.isServiceUpdate, 'The writer always restores the service flag');
    }

    @IsTest
    static void lines_cannotChangeAfterApproval_withoutOverridePermission() {
        TestDataFactory.Catalog catalog = catalog();
        User rep = [SELECT Id FROM User WHERE Alias = 'qftrep'];
        Quote__c quote;
        // Runs as the rep: the CI runner holds QF_Admin, whose break-glass permission would bypass the lock.
        System.runAs(rep) {
            quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);
        }
        TestDataFactory.approve(quote, QuoteConstants.ERP_PENDING);
        Quote_Line__c existing = [SELECT Id FROM Quote_Line__c WHERE Quote__c = :quote.Id];

        Database.SaveResult added;
        Database.SaveResult edited;
        Database.DeleteResult removed;
        Database.SaveResult termChange;
        System.runAs(rep) {
            Assert.isFalse(FeatureManagement.checkPermission('QF_Override_Quote_Lock'));
            added = Database.insert(TestDataFactory.line(quote.Id, catalog.seat, 1, null), false);
            edited = Database.update(new Quote_Line__c(Id = existing.Id, Manual_Discount_Pct__c = 50), false);
            removed = Database.delete(existing.Id, false);
            termChange = Database.update(new Quote__c(Id = quote.Id, Term_Months__c = 36), false);
        }

        Assert.isFalse(added.isSuccess());
        Assert.isTrue(added.getErrors()[0].getMessage().contains('cannot be changed while the quote is Approved'));
        Assert.isFalse(edited.isSuccess());
        Assert.isFalse(removed.isSuccess());
        Assert.isFalse(termChange.isSuccess());
    }

    @IsTest
    static void lines_overridePermissionHolder_canEditLockedQuote() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);
        TestDataFactory.approve(quote, QuoteConstants.ERP_PENDING);
        // The test runner holds QF_Admin (see @TestSetup), which carries QF_Override_Quote_Lock.
        Assert.isTrue(FeatureManagement.checkPermission('QF_Override_Quote_Lock'));

        Database.SaveResult added = Database.insert(TestDataFactory.line(quote.Id, catalog.seat, 1, null), false);

        Assert.isTrue(added.isSuccess(), 'Break-glass permission allows corrections');
    }

    @IsTest
    static void lines_includedFlagWithoutBundleDefinition_isRejected() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c header = TestDataFactory.line(quote.Id, catalog.bundle, 1, null);
        insert header;

        Database.SaveResult legitimate = Database.insert(
            new Quote_Line__c(
                Quote__c = quote.Id,
                Product__c = catalog.securityPack.Id,
                Quantity__c = 1,
                Parent_Line__c = header.Id,
                Is_Bundle_Component__c = true,
                Is_Included__c = true
            ),
            false
        );
        Database.SaveResult forged = Database.insert(
            new Quote_Line__c(
                Quote__c = quote.Id,
                Product__c = catalog.sso.Id,
                Quantity__c = 1,
                Parent_Line__c = header.Id,
                Is_Bundle_Component__c = true,
                Is_Included__c = true
            ),
            false
        );
        Database.SaveResult orphan = Database.insert(
            new Quote_Line__c(
                Quote__c = quote.Id,
                Product__c = catalog.seat.Id,
                Quantity__c = 1,
                Is_Included__c = true
            ),
            false
        );

        Assert.isTrue(legitimate.isSuccess(), 'Security pack is an Included option of the bundle');
        Assert.isTrue(!forged.isSuccess(), 'SSO is additive, so it cannot be zero-priced');
        Assert.isTrue(!orphan.isSuccess(), 'An included flag needs a parent bundle line');
    }

    @IsTest
    static void approvalRequest_cannotBeEditedOutsideTheApprovalService() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);
        Approval_Request__c request = new Approval_Request__c(
            Quote__c = quote.Id,
            Status__c = 'Pending',
            Approval_Level__c = 1
        );
        insert request;

        Database.SaveResult forged = Database.update(
            new Approval_Request__c(Id = request.Id, Status__c = 'Approved'),
            false
        );

        Assert.isTrue(!forged.isSuccess());
        Assert.isTrue(forged.getErrors()[0].getMessage().contains('managed by the approval process'));
    }

    @IsTest
    static void repUser_hasLeastPrivilegeObjectAndFieldAccess() {
        User rep = [SELECT Id FROM User WHERE Alias = 'qftrep'];

        System.runAs(rep) {
            Assert.isTrue(Schema.sObjectType.Quote__c.isCreateable());
            Assert.isTrue(!Schema.sObjectType.Quote__c.isDeletable(), 'Reps cannot delete quotes');
            Assert.isTrue(
                !Schema.sObjectType.Contracted_Price__c.isAccessible(),
                'Negotiated prices are hidden from reps'
            );
            Assert.isTrue(!Schema.sObjectType.Integration_Log__c.isAccessible());
            Assert.isTrue(!Schema.sObjectType.Quote__c.fields.Approval_Status__c.isUpdateable());
            Assert.isTrue(!Schema.sObjectType.Quote__c.fields.Net_Amount__c.isUpdateable());
            Assert.isTrue(!Schema.sObjectType.Quote_Line__c.fields.Net_Unit_Price__c.isUpdateable());
            Assert.isTrue(Schema.sObjectType.Quote_Line__c.fields.Manual_Discount_Pct__c.isUpdateable());
            Assert.isTrue(!FeatureManagement.checkPermission('QF_Override_Quote_Lock'));
        }
    }

    @IsTest
    static void repUser_cannotReadAnotherUsersPrivateQuote() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c adminQuote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        User rep = [SELECT Id FROM User WHERE Alias = 'qftrep'];

        System.runAs(rep) {
            Assert.areEqual(0, [SELECT COUNT() FROM Quote__c WHERE Id = :adminQuote.Id], 'OWD is Private');
            Assert.areEqual(0, QuoteSelector.quotesById(new Set<Id>{ adminQuote.Id }).size());
        }
    }

    // ------------------------------------------------------------------ added in the principal review

    @IsTest
    static void update_erpFieldsCannotBeForgedOutsideTheIntegration() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quoteWithSeats(catalog, account().Id, 5, null);
        TestDataFactory.approve(quote, QuoteConstants.ERP_PENDING);

        Database.SaveResult forgedOrder = Database.update(
            new Quote__c(Id = quote.Id, ERP_Order_Id__c = 'SO-FAKE'),
            false
        );
        Database.SaveResult forgedStatus = Database.update(
            new Quote__c(Id = quote.Id, ERP_Sync_Status__c = 'Synced'),
            false
        );

        Assert.isFalse(forgedOrder.isSuccess(), 'Admins have edit FLS, so only the trigger stops this');
        Assert.isTrue(forgedOrder.getErrors()[0].getMessage().contains('ERP synchronisation fields'));
        Assert.isFalse(forgedStatus.isSuccess());
        Assert.areEqual('Pending', TestDataFactory.requery(quote.Id).ERP_Sync_Status__c);
    }

    @IsTest
    static void stateWriter_refusesUserOwnedFields() {
        Quote__c quote = TestDataFactory.quote(account().Id, Test.getStandardPricebookId(), 12);

        try {
            QuoteStateWriter.updateQuotes(new List<Quote__c>{ new Quote__c(Id = quote.Id, Term_Months__c = 24) });
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('Term_Months__c'), e.getMessage());
        }
        Assert.areEqual(12, TestDataFactory.requery(quote.Id).Term_Months__c);
    }

    @IsTest
    static void lines_deletingBundleHeader_cascadesToItsComponents() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote = TestDataFactory.quote(account().Id, catalog.pricebookId, 12);
        Quote_Line__c header = TestDataFactory.line(quote.Id, catalog.bundle, 1, null);
        insert header;
        Quote_Line__c seat = TestDataFactory.line(quote.Id, catalog.seat, 5, null);
        seat.Parent_Line__c = header.Id;
        seat.Is_Bundle_Component__c = true;
        Quote_Line__c included = new Quote_Line__c(
            Quote__c = quote.Id,
            Product__c = catalog.securityPack.Id,
            Quantity__c = 1,
            Parent_Line__c = header.Id,
            Is_Bundle_Component__c = true,
            Is_Included__c = true
        );
        insert new List<Quote_Line__c>{ seat, included };
        Quote_Line__c standalone = TestDataFactory.line(quote.Id, catalog.seat, 2, null);
        insert standalone;

        Test.startTest();
        delete header;
        Test.stopTest();

        List<Quote_Line__c> remaining = [SELECT Id FROM Quote_Line__c WHERE Quote__c = :quote.Id];
        Assert.areEqual(1, remaining.size(), 'Components go with their header; unrelated lines stay');
        Assert.areEqual(standalone.Id, remaining[0].Id);
        Assert.areEqual(
            240,
            TestDataFactory.requery(quote.Id).Net_Amount__c,
            'Totals rolled up after the cascade: 2 x 120'
        );
    }
}
