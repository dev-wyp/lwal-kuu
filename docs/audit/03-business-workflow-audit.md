# Business workflow audit

**Audit date:** 2026-11-18  
**Method:** static comparison of React workflows with PostgreSQL tables/RPCs. No transactional database workflow was executed. Findings describe code paths, not production behavior.

## Purchasing: order → receipt → invoice → payment

### W-01 — Partial goods receiving and GRNI/supplier invoice workflow are absent

- **Severity:** Critical
- **Affected:** [0005_purchasing_and_payables.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0005_purchasing_and_payables.sql:118), `purchases`, `purchase_items`, `supplier_payments`, [PurchasesPage.tsx](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/src/modules/purchases/PurchasesPage.tsx)
- **Evidence:** The schema has one purchase `status` of draft/ordered/received/voided and a `received_quantity` field. `receive_purchase` accepts only organization, purchase ID, total upfront payment, and method; it processes each entire ordered quantity, sets `received_quantity = quantity`, and marks the whole purchase received. There are no goods-receipt header/item or GRNI/supplier-invoice tables in the active migration chain. A second receipt is rejected once status is received.
- **Business impact:** Shops cannot accurately record split deliveries, reject/damaged quantities, receipt-specific costs, or supplier invoices that arrive after receiving. Stock and supplier balances can diverge from paperwork.
- **Recommended correction:** Model receipt documents and accepted quantities, support partial and repeated receipts with receipt-level idempotency, and recognize payable/invoice state separately from purchase order and cash payment.
- **Verification:** Submit two partial receipts, repeat each request, complete the remaining quantities, and reconcile receipt ledger, accepted stock, GRNI, invoice, and payable totals.

### W-02 — Purchase header and lines are separate client writes; receipt trusts client-supplied values

- **Severity:** High
- **Affected:** [PurchasesPage.tsx](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/src/modules/purchases/PurchasesPage.tsx), `receive_purchase`
- **Evidence:** The UI inserts a purchase row and then inserts purchase items in a second request. The receiving RPC uses stored `purchase_items.quantity` and `unit_cost`; it does not recalculate the purchase total or validate `p_amount_paid` against the outstanding payable. `p_amount_paid` is only written when positive, then added to `purchases.paid_amount`.
- **Business impact:** A failed item insert can leave an incomplete order. Invalid or overlarge payment amounts and client-entered totals can overstate cost, inventory valuation, or supplier settlement.
- **Recommended correction:** Create the order and all lines atomically through a validated RPC; derive totals on the server and validate payment against the recognized liability.
- **Verification:** Inject failure between header and line creation; try mismatched totals, excessive payment, and retry. Ensure no partial header survives and source totals agree.

## Sales: product → POS → confirmation → stock → payment

### W-03 — Sale amount and line prices are client-controlled

- **Severity:** Critical
- **Affected:** [SalesPage.tsx](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/src/modules/sales/SalesPage.tsx), [0006_sales_and_receivables.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0006_sales_and_receivables.sql:260)
- **Evidence:** The UI creates a draft sale and sale-item rows directly from browser cart prices. `confirm_sale` calculates COGS from current product average cost, but the inspected RPC does not recompute selling prices, line totals, discounts, tax, or header total from trusted product/discount rules before confirming. It trusts `sales.total_amount` and `sale_items` values.
- **Business impact:** A modified or stale client can post a confirmed invoice with manipulated revenue, paid status, or gross profit while still producing valid stock movements.
- **Recommended correction:** Validate/reprice all sale lines server-side and calculate header total, tax, discounts, and payment state in the same confirmation transaction. Reject payment above the invoice total.
- **Verification:** Call the RPC with altered line/header totals, altered product IDs, negative/zero quantities, and paid amounts above total; confirm no invalid sale or stock movement is committed.

### W-04 — Sale preparation is multi-request and UI retries do not reuse idempotency keys

- **Severity:** High
- **Affected:** [SalesPage.tsx](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/src/modules/sales/SalesPage.tsx), `confirm_sale`
- **Evidence:** The UI obtains a number, inserts a draft, inserts its lines, then calls `confirm_sale`. It generates a new `crypto.randomUUID()` within each confirmation attempt. A browser retry after a timeout can therefore create a new draft and key even if the earlier confirmation committed. The RPC's existing idempotency lookup also searches only by key and not by `p_org_id` before returning the sale ID/number.
- **Business impact:** Retry after a lost response can create a second confirmed sale; an idempotency key from another tenant can be used to query the other sale's identifier/number if obtained.
- **Recommended correction:** Use a stable request key from the start of checkout, scope the unique key and lookup by organization, and create/confirm the sale atomically or persist a retryable draft keyed by that request.
- **Verification:** Simulate timeout after database commit and retry with the same client request; assert one sale, one payment, and one stock deduction. Test cross-organization key reuse.

### W-05 — Walk-in payment method is not persisted as a transaction

- **Severity:** High
- **Affected:** `sales` schema, `confirm_sale`, `cash_flow_performance`, `SalesPage.tsx`
- **Evidence:** `SalesPage` passes `p_payment_method` to `confirm_sale`; for a sale with no customer, the RPC does not create a `payments` row. The `sales` table has no payment-method column. Cash-flow views count the walk-in `paid_amount`, but do not retain or separate cash vs bank/mobile methods for that sale.
- **Business impact:** A shop cannot reconcile cash drawer, bank transfer, KBZPay, or WavePay totals for walk-in POS sales.
- **Recommended correction:** Record every tender as a payment/tender row linked to the sale, preserving method, account, amount, timestamp, and reversal references.
- **Verification:** Post walk-in sales using each tender method and reconcile each method to its payment ledger and cash/bank movement report.

### W-06 — Sale reversal reverses stock but not receipt/allocation history

- **Severity:** Critical
- **Affected:** [void_or_reverse_sale in 0006_sales_and_receivables.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0006_sales_and_receivables.sql:353), `payments`, `payment_allocations`, customer reports
- **Evidence:** For a confirmed sale, the RPC inserts compensating stock movements and changes sale status to reversed. It does not reverse/void the associated posted payments or allocations and does not create a refund/reversal transaction.
- **Business impact:** Stock is restored but cash and customer balances continue to include the original collection. Reversed invoices can produce negative customer balances and inflated cash flow.
- **Recommended correction:** Add auditable payment refund/void and allocation reversal entries in the same compensating workflow; do not delete posted financial records.
- **Verification:** Reverse fully paid, partially paid, and unpaid sales; reconcile stock, payment ledger, allocation ledger, customer balance, and cash/bank movement.

## Customer payments

### W-07 — Payment allocation allows over-allocation and has no reversal workflow

- **Severity:** Critical
- **Affected:** [record_customer_payment_and_allocate in 0006_sales_and_receivables.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0006_sales_and_receivables.sql:428), `PaymentsPage.tsx`
- **Evidence:** The RPC locks an invoice row but adds the requested allocation directly to `paid_amount`; it never checks outstanding balance or cumulative allocation against payment amount. A missing/non-confirmed invoice is silently skipped while the payment is still recorded. The active schema exposes no customer-payment reversal RPC.
- **Business impact:** Concurrent or malformed requests can overpay invoices; users may see a payment recorded while some requested allocations were dropped. Corrections lack a preserved reversal trail.
- **Recommended correction:** Validate every allocation and reject the whole transaction on any invalid item, cap allocations within both payment and invoice balances under row locks, and implement append-only payment/allocation reversals.
- **Verification:** Concurrently allocate to one invoice, allocate more than payment/invoice due, reference an invalid sale, and reverse a payment; compare source rows and balances after each case.

## Supplier payments and corrections

### W-08 — Supplier payments are not invoice allocations and can exceed payable

- **Severity:** High
- **Affected:** `supplier_payments`, `receive_purchase`, `supplier_balances_summary`
- **Evidence:** Supplier payment rows reference an optional purchase but there is no supplier-payment allocation table or supplier invoice/GRNI ledger. The receiving RPC accepts any positive `p_amount_paid` without checking the purchase total or remaining amount. Supplier payable summary subtracts all supplier payments from received purchases.
- **Business impact:** Supplier advances, invoice settlement, and overpayments are conflated; owners cannot distinguish money paid in advance from an invoice being settled.
- **Recommended correction:** Add recognized supplier invoices and payment allocations with balance locks; represent supplier advances separately and use audited compensating reversals.
- **Verification:** Test advance, partial invoice settlement, overpayment rejection, duplicate payment, payment reversal, and multi-invoice allocation.

## Workflow conclusion

The source contains useful POS, receipt, stock, and customer-payment paths, but it does not implement the requested purchase-to-invoice-to-payment workflow end to end. Critical server-side pricing, tenant-reference, allocation, and reversal behavior must be corrected and verified before real shop transactions are trusted.
