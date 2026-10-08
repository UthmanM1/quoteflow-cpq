/**
 * Approval journeys run as the real personas: rep (Sales_Representative role, manager = Sales_Manager user),
 * manager and director (role hierarchy), finance (outside the sales line; access through the sharing rule).
 */
@IsTest
private class SalesQuoteApprovalServiceTest {
    @TestSetup
    static void setup() {
        SalesLabTestFactory.createFixture();
    }

    private static User persona(String alias) {
        return SalesLabTestFactory.user(alias);
    }

    private static Quote_Configuration__c submittedQuote(Product2 product, Decimal quantity, Decimal discount) {
        SalesLabTestFactory.installRouting();
        Quote_Configuration__c quote;
        System.runAs(persona(SalesLabTestFactory.REP)) {
            quote = SalesLabTestFactory.quoteWithLine(product, quantity, discount);
            SalesQuoteApprovalService.SubmissionResult result = SalesQuoteApprovalService.submit(quote.Id);
            Assert.isTrue(result.success, result.message);
        }
        return SalesLabTestFactory.requery(quote.Id);
    }

    private static Sales_Approval_Request__c pendingRequest(Id quoteId) {
        return [
            SELECT
                Id,
                Approver__c,
                Approval_Tier__c,
                Threshold_Percent__c,
                Quote_Amount__c,
                Requested_Discount_Percent__c
            FROM Sales_Approval_Request__c
            WHERE Quote_Configuration__c = :quoteId AND Status__c = 'Pending'
        ];
    }

    @IsTest
    static void submit_withinPolicy_isApprovedAutomatically_andFlowUpdatesTheOpportunity() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 5);

        Assert.areEqual('Approved', quote.Status__c);
        Assert.isFalse(quote.Approval_Required__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Sales_Approval_Request__c]);
        Opportunity opportunity = [
            SELECT StageName, Primary_Quote_Configuration__c
            FROM Opportunity
            WHERE Id = :SalesLabTestFactory.opportunity().Id
        ];
        Assert.areEqual('Negotiation/Review', opportunity.StageName, 'Record-triggered flow on approval');
        Assert.areEqual(quote.Id, opportunity.Primary_Quote_Configuration__c);
    }

    @IsTest
    static void tier1_routesToTheOwnersManager_whoApprovesThroughTheRoleHierarchy() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 15);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);
        Assert.areEqual(persona(SalesLabTestFactory.MANAGER).Id, request.Approver__c);
        Assert.areEqual(10, request.Threshold_Percent__c);
        Assert.areEqual(15, request.Requested_Discount_Percent__c);
        Assert.areEqual(4250, request.Quote_Amount__c);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Task WHERE WhatId = :quote.Id AND OwnerId = :request.Approver__c],
            'Approver task flow'
        );

        Test.startTest();
        System.runAs(persona(SalesLabTestFactory.MANAGER)) {
            SalesQuoteApprovalService.decide(request.Id, true, 'Fine for this account.');
        }
        Test.stopTest();

        Quote_Configuration__c after = SalesLabTestFactory.requery(quote.Id);
        Assert.areEqual('Approved', after.Status__c);
        Assert.isNotNull(after.Approved_Date__c);
        Assert.areEqual('Approved', [SELECT Status__c FROM Sales_Approval_Request__c WHERE Id = :request.Id].Status__c);
    }

    @IsTest
    static void tier2_routesToFinance_whoDecidesThroughTheSharingRule() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 25);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);
        Assert.areEqual(persona(SalesLabTestFactory.FINANCE).Id, request.Approver__c);
        Assert.areEqual(2, request.Approval_Tier__c);

        User finance = persona(SalesLabTestFactory.FINANCE);
        Assert.isTrue(
            SalesLabTestFactory.hasAccess(finance.Id, quote.Id, true),
            'Finance should have edit access to a submitted quote through the sharing rule. ' +
            SalesLabTestFactory.accessReport(finance.Id, quote.Id)
        );

        Test.startTest();
        System.runAs(finance) {
            SalesQuoteApprovalService.decide(request.Id, true, 'Margin acceptable.');
        }
        Test.stopTest();

        Assert.areEqual('Approved', SalesLabTestFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void tier3_routesToTheSalesDirector() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 35);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);
        Assert.areEqual(persona(SalesLabTestFactory.DIRECTOR).Id, request.Approver__c);

        System.runAs(persona(SalesLabTestFactory.DIRECTOR)) {
            SalesQuoteApprovalService.decide(request.Id, true, 'Strategic logo.');
        }

        Assert.areEqual('Approved', SalesLabTestFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void reject_requiresAComment_thenRejectsAndCreatesAFollowUpTask() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 15);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);

        System.runAs(persona(SalesLabTestFactory.MANAGER)) {
            try {
                SalesQuoteApprovalService.decide(request.Id, false, 'No.');
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('at least 10'), e.getMessage());
            }
            SalesQuoteApprovalService.decide(request.Id, false, 'Discount too deep for this segment.');
        }

        Assert.areEqual('Rejected', SalesLabTestFactory.requery(quote.Id).Status__c);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM Task WHERE WhatId = :quote.Id AND OwnerId = :quote.OwnerId AND Subject LIKE 'Revise%'],
            'Rejection follow-up flow'
        );
    }

    @IsTest
    static void decide_byAnyoneButTheAssignedApprover_isRefused() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 15);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);

        System.runAs(persona(SalesLabTestFactory.DIRECTOR)) {
            try {
                SalesQuoteApprovalService.decide(request.Id, true, 'I outrank the manager.');
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('assigned approver'), e.getMessage());
            }
        }
        Assert.areEqual('Pending Approval', SalesLabTestFactory.requery(quote.Id).Status__c);
    }

    @IsTest
    static void recall_byOwner_returnsToDraft_byOthers_isRefused() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 15);

        System.runAs(persona(SalesLabTestFactory.MANAGER)) {
            try {
                SalesQuoteApprovalService.recall(quote.Id);
                Assert.fail('Expected SalesLabException');
            } catch (SalesLabException e) {
                Assert.isTrue(e.getMessage().contains('Only the quote owner'));
            }
        }
        System.runAs(persona(SalesLabTestFactory.REP)) {
            SalesQuoteApprovalService.recall(quote.Id);
        }

        Assert.areEqual('Draft', SalesLabTestFactory.requery(quote.Id).Status__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Sales_Approval_Request__c WHERE Status__c = 'Recalled']);
    }

    @IsTest
    static void submit_byManagerWhoCanSeeButDoesNotOwnTheQuote_isRefused() {
        SalesLabTestFactory.installRouting();
        Quote_Configuration__c quote;
        System.runAs(persona(SalesLabTestFactory.REP)) {
            quote = SalesLabTestFactory.quoteWithLine(SalesLabTestFactory.catalog().software, 5, 15);
        }

        SalesQuoteApprovalService.SubmissionResult result;
        System.runAs(persona(SalesLabTestFactory.MANAGER)) {
            result = SalesQuoteApprovalService.submit(quote.Id);
        }

        Assert.isFalse(result.success);
        Assert.isTrue(result.message.contains('Only the quote owner'), result.message);
    }

    @IsTest
    static void approvalRequests_cannotBeEditedOutsideTheService() {
        Quote_Configuration__c quote = submittedQuote(SalesLabTestFactory.catalog().software, 5, 15);
        Sales_Approval_Request__c request = pendingRequest(quote.Id);

        Database.SaveResult forged = Database.update(
            new Sales_Approval_Request__c(Id = request.Id, Status__c = 'Approved'),
            false
        );
        Database.DeleteResult deleted = Database.delete(request.Id, false);

        Assert.isFalse(forged.isSuccess(), 'Even an administrator cannot forge a decision');
        Assert.isFalse(deleted.isSuccess(), 'The audit trail cannot be deleted');
    }

    @IsTest
    static void submit_fiftyQuotes_usesConstantQueries() {
        SalesLabTestFactory.installRouting();
        Product2 software = SalesLabTestFactory.catalog().software;
        Set<Id> quoteIds = new Set<Id>();
        System.runAs(persona(SalesLabTestFactory.REP)) {
            Id opportunityId = SalesLabTestFactory.opportunity().Id;
            List<Quote_Configuration__c> quotes = new List<Quote_Configuration__c>();
            for (Integer i = 0; i < 50; i++) {
                quotes.add(new Quote_Configuration__c(Opportunity__c = opportunityId));
            }
            insert quotes;
            List<Quote_Configuration_Line__c> lines = new List<Quote_Configuration_Line__c>();
            for (Quote_Configuration__c quote : quotes) {
                lines.add(SalesLabTestFactory.line(quote.Id, software, 2, 15));
                quoteIds.add(quote.Id);
            }
            insert lines;

            Test.startTest();
            Map<Id, SalesQuoteApprovalService.SubmissionResult> results = SalesQuoteApprovalService.submit(quoteIds);
            Integer queries = Limits.getQueries();
            Test.stopTest();

            Assert.areEqual(50, results.size());
            Assert.isTrue(queries < 15, 'Submission must not query per quote; used ' + queries);
        }
        Assert.areEqual(50, [SELECT COUNT() FROM Sales_Approval_Request__c WHERE Status__c = 'Pending']);
    }
}
