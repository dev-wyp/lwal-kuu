# Sales and Purchase Workflows

**Status:** Target behavior and local P0 changes documented. Returns and full partial-GRN workflows remain unimplemented.

## Sales

### Draft and confirm

1. Cashier selects an active organization branch, customer when the sale is credit/partial, and catalog products.
2. A draft may be edited only by an authorized organization role. Draft header/line totals are presentation data and are never trusted for posting.
3. `confirm_sale()` rechecks organization permission, branch/customer/product ownership and status. It uses catalog price until a permissioned price-override flow exists, recomputes line/header totals, rejects unsupported tax, validates payment, locks stock, and atomically posts sale/payment/allocation/stock movement/audit rows.
4. Retry uses the same organization-scoped key and returns the same invoice result. The frontend now retains a pending draft/key across uncertain retries in the same page session.
5. Confirmed invoices are immutable business records. Correct them through return, credit/refund, or reversal documents with compensating ledger entries.

### Customer payments

- Validate the customer belongs to the organization and each invoice is confirmed, belongs to that same customer, and remains outstanding.
- Lock invoices in deterministic order and cap allocation by both payment amount and invoice due.
- The remainder is an unallocated customer advance; later allocation needs an explicit workflow.
- Payment retries use the same scoped idempotency key and return existing payment metadata.
- Refund/reversal requires a separately auditable refund/credit-note model; the current source does not complete this lifecycle.

## Purchasing

### Purchase order and receipt

- Keep current purchase creation and line editing. Validate same-organization supplier, branch and products before posting.
- The compatible `receive_purchase()` currently receives all remaining quantities in a single request, posts stock movements, updates weighted-average cost, records an optional linked supplier payment, and marks the purchase received.
- Partial receiving needs a receipt header and receipt lines (GRN), per-line `received_quantity`, remaining-quantity calculations, idempotent receipt key, and purchase status `ordered`/`partially_received`/`received`. Each receipt must be append-only and trace the supplier invoice/reference.
- Do not add a partial receive UI until the database supports line-level quantity and replay protection.

### Supplier payment

- Use a dedicated atomic supplier-payment RPC; validate organization/supplier/purchase ownership, amount, method, payable remaining, and idempotency.
- Permit an explicit unapplied supplier advance, then allocate it to purchases with row locks and amount caps.
- Do not use purchase receipt as the only supplier payment path. Reversal/refund must be a compensating transaction, not deletion.

## Returns (planned)

### Sales return

- Return document references original confirmed sale and customer.
- Return lines cap cumulative accepted returned quantity at sold quantity minus prior returns.
- Record condition and disposition (`restock`, `damaged`, `quarantine/write-off`); stock changes only through compensating movements.
- Approval and refund/customer-credit choice are explicit. Credit notes and cash refunds reconcile to payment/receivable ledgers.
- Unique request keys and row locks prevent duplicate/concurrent over-return.

### Purchase return

- Return document references a received purchase and supplier; quantities cannot exceed received less earlier returns.
- Stock-out movement, supplier credit/refund and payable adjustment post atomically with reason, approval, and audit trail.

## Required acceptance checks

- Same-tenant references only; new composite FKs plus RPC checks.
- Duplicate confirmation, receipt, payment, or return retries produce no duplicate ledger rows.
- Concurrent sale/receipt/payment/return operations preserve stock and balance limits.
- Rejected calls roll back every mutation.
- Reversal retains source rows and creates traceable compensating records.
- UI totals reconcile to the database response and receipt.

