@IsTest
private class QuoteApprovalServiceTest {
    /**
     * Users deliberately have no roles: the manager is linked only through User.ManagerId and finance/VP only through
     * their role, so every approver sees the quote solely through the Approver_Access share (Read). This is the
     * persona set that exposes a `with sharing` service doing plain DML.
     */
    private static final List<String> REP_SETS = TestDataFactory.REP_SETS;
    private static final List<String> APPROVER_SETS = TestDataFactory.MANAGER_SETS;

    @TestSetup
    static void setup() {
        TestDataFactory.grantRunnerAdminAccess();
        TestDataFactory.createCatalog();
        Id financeRole = TestDataFactory.ensureRole(TestDataFactory.FINANCE_ROLE);
        Id vpRole = TestDataFactory.ensureRole(TestDataFactory.VP_ROLE);
        User manager = TestDataFactory.user('qfmgr', null, null, APPROVER_SETS);
        TestDataFactory.user('qfrep', null, manager.Id, REP_SETS);
        TestDataFactory.user('qffin', financeRole, null, TestDataFactory.FINANCE_SETS);
        TestDataFactory.user('qfvp', vpRole, null, APPROVER_SETS);
    }

    private static User userByAlias(String alias) {
        return [SELECT Id FROM User WHERE Alias = :alias LIMIT 1];
    }

    private static TestDataFactory.Catalog catalog() {
        TestDataFactory.installPolicy();
        TestDataFactory.Catalog c = new TestDataFactory.Catalog();
        c.pricebookId = Test.getStandardPricebookId();
        c.seat = [SELECT Id FROM Product2 WHERE ProductCode = 'QF-USER-SEAT'];
        return c;
    }

    /** Creates a quote owned by the rep with one seat line at the requested manual discount. */
    private static Quote__c repQuote(Decimal manualDiscountPct) {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c quote;
        System.runAs(userByAlias('qfrep')) {
            Account account = TestDataFactory.account('Contoso ' + manualDiscountPct, 'ERP-' + manualDiscountPct);
            quote = TestDataFactory.quoteWithSeats(catalog, account.Id, 5, manualDiscountPct);
        }
        return quote;
    }

    private static QuoteApprovalService.SubmissionResult submitAsRep(Id quoteId) {
        List<QuoteApprovalService.SubmissionResult> results;
        System.runAs(userByAlias('qfrep')) {
            results = QuoteApprovalService.submit(new Set<Id>{ quoteId });
        }
        return results[0];
    }

    private static Approval_Request__c pendingRequest(Id quoteId) {
        return [
            SELECT Id, Approver__c, Approval_Level__c, Status__c, Threshold_Pct__c
            FROM Approval_Request__c
            WHERE Quote__c = :quoteId AND Status__c = 'Pending'
        ];
    }

    @IsTest
    static void submit_withinPolicy_approvesAutomaticallyAndQueuesErpSync() {
        Quote__c quote = repQuote(5);

        Test.startTest();
        QuoteApprovalService.SubmissionResult result = submitAsRep(quote.Id);
        Test.stopTest();

        Assert.isTrue(result.success, result.message);
        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Approved', after.Status__c);
        Assert.areEqual('Not Required', after.Approval_Status__c);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c, 'Approved quotes are queued for the ERP');
        Assert.areEqual(0, [SELECT COUNT() FROM Approval_Request__c WHERE Quote__c = :quote.Id]);
    }

    @IsTest
    static void submit_aboveLevelOne_routesToOwnersManager() {
        Quote__c quote = repQuote(15);

        Test.startTest();
        QuoteApprovalService.SubmissionResult result = submitAsRep(quote.Id);
        Test.stopTest();

        Assert.areEqual('PendingApproval', result.outcome);
        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Pending Approval', after.Status__c);
        Assert.areEqual('Pending', after.Approval_Status__c);
        Assert.areEqual(1, after.Current_Approval_Level__c);
        Approval_Request__c request = pendingRequest(quote.Id);
        Assert.areEqual(userByAlias('qfmgr').Id, request.Approver__c);
        Assert.areEqual(10, request.Threshold_Pct__c);
        Assert.areEqual(
            1,
            [
                SELECT COUNT()
                FROM Quote__Share
                WHERE ParentId = :quote.Id AND UserOrGroupId = :request.Approver__c AND RowCause = 'Approver_Access__c'
            ],
            'Approver is granted read access through Apex sharing'
        );
    }

    @IsTest
    static void decide_managerApprovesSingleLevel_quoteBecomesApproved() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        Approval_Request__c request = pendingRequest(quote.Id);

        Test.startTest();
        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(request.Id, true, 'Strategic account, margin acceptable.');
        }
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Approved', after.Status__c);
        Assert.areEqual('Approved', after.Approval_Status__c);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Approval_Request__c decided = [
            SELECT Status__c, Decision_Comments__c, Decision_Date__c
            FROM Approval_Request__c
            WHERE Id = :request.Id
        ];
        Assert.areEqual('Approved', decided.Status__c);
        Assert.areNotEqual(null, decided.Decision_Date__c);
    }

    @IsTest
    static void decide_twoLevelDiscount_escalatesToFinanceThenApproves() {
        Quote__c quote = repQuote(25);
        submitAsRep(quote.Id);

        Test.startTest();
        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(pendingRequest(quote.Id).Id, true, 'Level one fine.');
        }
        Quote__c midway = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Pending Approval', midway.Status__c, 'Still waiting on level 2');
        Assert.areEqual(2, midway.Current_Approval_Level__c);
        Approval_Request__c levelTwo = pendingRequest(quote.Id);
        Assert.areEqual(
            userByAlias('qffin').Id,
            levelTwo.Approver__c,
            'Level 2 resolves to the Finance Director role holder'
        );
        System.runAs(userByAlias('qffin')) {
            QuoteApprovalService.decide(levelTwo.Id, true, 'Finance signed off.');
        }
        Test.stopTest();

        Assert.areEqual('Approved', TestDataFactory.requery(quote.Id).Status__c);
        Assert.areEqual(
            2,
            [SELECT COUNT() FROM Approval_Request__c WHERE Quote__c = :quote.Id AND Status__c = 'Approved']
        );
    }

    @IsTest
    static void decide_rejectionWithoutExplanation_isRefused() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        Id requestId = pendingRequest(quote.Id).Id;

        Test.startTest();
        try {
            System.runAs(userByAlias('qfmgr')) {
                QuoteApprovalService.decide(requestId, false, 'no');
            }
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('explain the rejection'), e.getMessage());
        }
        Test.stopTest();

        Assert.areEqual('Pending Approval', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void decide_rejectionWithComment_rejectsQuoteAndAllowsResubmission() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);

        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(pendingRequest(quote.Id).Id, false, 'Discount too deep for this segment.');
        }

        Quote__c rejected = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Rejected', rejected.Status__c);
        Assert.areEqual('Rejected', rejected.Approval_Status__c);

        System.runAs(userByAlias('qfrep')) {
            update new Quote_Line__c(
                Id = [SELECT Id FROM Quote_Line__c WHERE Quote__c = :quote.Id]
                .Id,
                Manual_Discount_Pct__c = 5
            );
        }
        Assert.isTrue(submitAsRep(quote.Id).success, 'A rejected quote can be revised and resubmitted');
        Assert.areEqual('Approved', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void decide_userWhoIsNotTheApprover_isRefused() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        Id requestId = pendingRequest(quote.Id).Id;

        try {
            System.runAs(userByAlias('qfvp')) {
                QuoteApprovalService.decide(requestId, true, 'I will approve it anyway.');
            }
            Assert.fail('Expected an access failure');
        } catch (QuoteFlowException e) {
            Assert.isTrue(
                e.getMessage().contains('assigned approver') || e.getMessage().contains('not found'),
                e.getMessage()
            );
        }
        Assert.areEqual('Pending Approval', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void decide_alreadyActionedRequest_isRefused() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        Id requestId = pendingRequest(quote.Id).Id;
        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(requestId, true, 'Approved first time.');
            try {
                QuoteApprovalService.decide(requestId, false, 'Changing my mind later.');
                Assert.fail('Expected QuoteFlowException');
            } catch (QuoteFlowException e) {
                Assert.isTrue(e.getMessage().contains('already been actioned'), e.getMessage());
            }
        }
    }

    @IsTest
    static void submit_invalidQuotes_reportPerQuoteErrors() {
        TestDataFactory.Catalog catalog = catalog();
        Quote__c empty;
        Quote__c approved = repQuote(5);
        submitAsRep(approved.Id);
        System.runAs(userByAlias('qfrep')) {
            Account account = TestDataFactory.account('Empty Inc', 'ERP-E');
            empty = TestDataFactory.quote(account.Id, catalog.pricebookId, 12);
        }

        List<QuoteApprovalService.SubmissionResult> results;
        System.runAs(userByAlias('qfrep')) {
            results = QuoteApprovalService.submit(new Set<Id>{ empty.Id, approved.Id });
        }

        Map<Id, QuoteApprovalService.SubmissionResult> byQuote = new Map<Id, QuoteApprovalService.SubmissionResult>();
        for (QuoteApprovalService.SubmissionResult result : results) {
            byQuote.put(result.quoteId, result);
        }
        Assert.isTrue(byQuote.get(empty.Id).message.contains('at least one line'));
        Assert.isTrue(byQuote.get(approved.Id).message.contains('Only Draft or Rejected'));
    }

    @IsTest
    static void submit_noEligibleApprover_failsWithoutChangingTheQuote() {
        Quote__c quote = repQuote(15);
        update new User(Id = userByAlias('qfrep').Id, ManagerId = null);

        QuoteApprovalService.SubmissionResult result = submitAsRep(quote.Id);

        Assert.isTrue(!result.success);
        Assert.isTrue(result.message.contains('No eligible approver'), result.message);
        Assert.areEqual('Draft', TestDataFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void recall_ownerReturnsQuoteToDraftAndSupersedesRequest() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);

        System.runAs(userByAlias('qfrep')) {
            QuoteApprovalService.recall(quote.Id);
        }

        Assert.areEqual('Draft', TestDataFactory.requery(quote.Id).Status__c);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Approval_Request__c WHERE Quote__c = :quote.Id AND Status__c = 'Superseded']
        );
    }

    @IsTest
    static void submit_fiftyQuotes_isBulkSafe() {
        TestDataFactory.Catalog catalog = catalog();
        List<Quote__c> quotes = new List<Quote__c>();
        System.runAs(userByAlias('qfrep')) {
            Account account = TestDataFactory.account('Bulk Co', 'ERP-B');
            for (Integer i = 0; i < 50; i++) {
                quotes.add(
                    new Quote__c(Account__c = account.Id, Pricebook__c = catalog.pricebookId, Term_Months__c = 12)
                );
            }
            insert quotes;
            List<Quote_Line__c> lines = new List<Quote_Line__c>();
            for (Quote__c quote : quotes) {
                lines.add(TestDataFactory.line(quote.Id, catalog.seat, 5, 15));
            }
            insert lines;
        }
        Set<Id> ids = new Map<Id, Quote__c>(quotes).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<QuoteApprovalService.SubmissionResult> results;
        System.runAs(userByAlias('qfrep')) {
            results = QuoteApprovalService.submit(ids);
        }
        Integer used = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(50, results.size());
        Assert.areEqual(50, [SELECT COUNT() FROM Approval_Request__c WHERE Quote__c IN :ids AND Status__c = 'Pending']);
        Assert.isTrue(used < 25, 'Submission must not query per quote; used ' + used);
    }

    // ------------------------------------------------------------------ added in the principal review

    private static Integer approverShares(Id quoteId, Id userId) {
        return [
            SELECT COUNT()
            FROM Quote__Share
            WHERE ParentId = :quoteId AND UserOrGroupId = :userId AND RowCause = 'Approver_Access__c'
        ];
    }

    @IsTest
    static void decide_threeLevels_shareOnlyApproversCanEachDecide() {
        Quote__c quote = repQuote(35);
        Assert.isTrue(submitAsRep(quote.Id).success);

        Test.startTest();
        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(pendingRequest(quote.Id).Id, true, 'Level one approved.');
        }
        System.runAs(userByAlias('qffin')) {
            QuoteApprovalService.decide(pendingRequest(quote.Id).Id, true, 'Finance approved.');
        }
        Approval_Request__c levelThree = pendingRequest(quote.Id);
        Assert.areEqual(userByAlias('qfvp').Id, levelThree.Approver__c);
        Assert.areEqual(
            1,
            approverShares(quote.Id, levelThree.Approver__c),
            'A Read-only finance approver can still route to the VP'
        );
        System.runAs(userByAlias('qfvp')) {
            QuoteApprovalService.decide(levelThree.Id, true, 'VP approved.');
        }
        Test.stopTest();

        Quote__c after = TestDataFactory.requery(quote.Id);
        Assert.areEqual('Approved', after.Status__c);
        Assert.areEqual('Pending', after.ERP_Sync_Status__c);
        Assert.areEqual(1, after.ERP_Sync_Generation__c, 'Approval opens ERP sync generation 1');
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM Approval_Request__c WHERE Quote__c = :quote.Id AND Status__c = 'Approved']
        );
        Assert.areEqual(1, approverShares(quote.Id, userByAlias('qffin').Id), 'Deciders keep read access for audit');
    }

    @IsTest
    static void submit_byUserWhoCanReadButDoesNotOwnTheQuote_isRefused() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        System.runAs(userByAlias('qfmgr')) {
            QuoteApprovalService.decide(pendingRequest(quote.Id).Id, false, 'Discount too deep for this segment.');
        }

        List<QuoteApprovalService.SubmissionResult> results;
        Test.startTest();
        System.runAs(userByAlias('qfmgr')) {
            results = QuoteApprovalService.submit(new Set<Id>{ quote.Id });
        }
        Test.stopTest();

        Assert.isFalse(results[0].success);
        Assert.isTrue(results[0].message.contains('Only the quote owner'), results[0].message);
        Assert.areEqual('Rejected', TestDataFactory.requery(quote.Id).Status__c);
        Assert.areEqual(
            1,
            approverShares(quote.Id, userByAlias('qfmgr').Id),
            'The manager decided, so keeps read access'
        );
    }

    @IsTest
    static void recall_revokesTheUndecidedApproversAccess() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);
        Id managerId = userByAlias('qfmgr').Id;
        Assert.areEqual(1, approverShares(quote.Id, managerId));

        Test.startTest();
        System.runAs(userByAlias('qfrep')) {
            QuoteApprovalService.recall(quote.Id);
        }
        Test.stopTest();

        Assert.areEqual(0, approverShares(quote.Id, managerId), 'A superseded approver no longer sees the quote');
        System.runAs(userByAlias('qfmgr')) {
            Assert.areEqual(0, [SELECT COUNT() FROM Quote__c WHERE Id = :quote.Id WITH USER_MODE]);
        }
    }

    @IsTest
    static void recall_byNonOwner_isRefused() {
        Quote__c quote = repQuote(15);
        submitAsRep(quote.Id);

        try {
            System.runAs(userByAlias('qfmgr')) {
                QuoteApprovalService.recall(quote.Id);
            }
            Assert.fail('Expected QuoteFlowException');
        } catch (QuoteFlowException e) {
            Assert.isTrue(e.getMessage().contains('Only the quote owner'), e.getMessage());
        }
        Assert.areEqual('Pending Approval', TestDataFactory.requery(quote.Id).Status__c);
    }
}
