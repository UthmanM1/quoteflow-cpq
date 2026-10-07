# Sample ERP payloads (fictional "Atlas ERP")

Request and response shapes for `SalesERPIntegrationService`. The ERP and every value are fictional; the
contract is an assumed design, not a vendor API. The request body matches `ErpOrderRequest` as serialised by
`JSON.serialize(payload, true)` (nulls suppressed). Headers sent with every call:

```
POST callout:Sales_ERP/api/v2/orders
Content-Type: application/json
Accept: application/json
X-Correlation-Id: <UUID per attempt, also in the body>
Idempotency-Key: sf-order-<Salesforce Order Id>
```

| File | HTTP | Classification in Apex |
|---|---|---|
| `erp-order-request.json` | - | request body |
| `erp-order-response-201-created.json` | 201 | success: order Synced, ERP order number stored |
| `erp-order-response-409-duplicate.json` | 409 | success: idempotent replay of an order the ERP already has |
| `erp-order-response-422-validation.json` | 422 | permanent failure: order Failed, needs a person |
| `erp-order-response-503-unavailable.json` | 503 | retryable: order stays Pending, next retry scheduled with back-off |
