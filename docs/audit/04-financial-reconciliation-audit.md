# Financial reporting and reconciliation audit

**Audit date:** 2026-11-18  
**Method:** static review of report views, source ledgers, and workflow RPCs. No fixture was inserted into a database and no financial report was compared with live transaction totals.

## Findings

### F-01 — Reports are not independently reconciled to transaction fixtures

- **Severity:** Critical
- **Affected:** `0009_reporting_views.sql`, `0032_plan_dependent_report_views.sql`, `0041_advanced_permission_read_enforcement.sql`, `ReportsPage.tsx`, SQL test suite
- **Evidence:** The views derive daily/monthly sales, gross profit, supplier/customer balances, and cash flow from source tables. Existing SQL tests contain only a marketing RPC existence check and a tenant-isolation script; no active database test independently totals receipts, sales, payments, stock, and report rows. No database test was executed in this audit.
- **Business impact:** A page can render while omitting, double-counting, or misclassifying a transaction. Owners could make purchasing/pricing decisions from untrusted figures.
- **Recommended correction:** Add deterministic seeded fixture tests and compute expected values independently from source records. Include rejected/voided/reversed entries and cross-tenant rows.
- **Verification:** Compare independently calculated source totals to each report for daily/monthly sales, stock quantity/value, customer balances, supplier balances, gross profit, and cash/bank movement.

### F-02 — Customer balance summary uses payments rather than invoice allocations

- **Severity:** High
- **Affected:** [customer_balances_summary in 0009_reporting_views.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0009_reporting_views.sql:7), `payment_allocations`, sale reversal workflow
- **Evidence:** The summary subtracts the sum of every posted payment by customer from confirmed sales; it does not base invoice outstanding on the allocation table. Sale reversal removes the invoice from confirmed sales but leaves posted payment/allocation rows unchanged.
- **Business impact:** Unallocated advances may reduce invoice outstanding without being allocated to an invoice, and reversing a collected sale can leave the customer account in credit without a refund/reversal transaction.
- **Recommended correction:** Define customer account balance and invoice outstanding separately; use allocation/reversal records for invoice-level due and explicit advance-credit balances for unapplied cash.
- **Verification:** Fixtures for unapplied advance, partial allocation, over-allocation rejection, refund, and reversed sale; compare account balance and invoice outstanding independently.

### F-03 — Supplier payable summary conflates payments with invoice settlement

- **Severity:** High
- **Affected:** [supplier_balances_summary in 0009_reporting_views.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0009_reporting_views.sql:37), `supplier_payments`, `purchases`
- **Evidence:** The view computes received purchase totals less all supplier payments. The schema has no supplier invoice/GRNI record or payment-to-invoice allocation table. The receiving RPC can record an upfront payment but does not cap it to liability.
- **Business impact:** Advances, payable settlement, and overpayments are indistinguishable, so the reported supplier liability may not match invoices owed.
- **Recommended correction:** Report recognized supplier invoices and allocations separately from supplier advances; add reversal and adjustment entries that preserve history.
- **Verification:** Reconcile a sequence of order, partial receipts, supplier invoice, advance, partial payment, payment reversal, and final settlement against the payable schedule.

### F-04 — Cash flow cannot reconcile cash separately from bank/mobile methods

- **Severity:** High
- **Affected:** [cash_flow_performance in 0041_advanced_permission_read_enforcement.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0041_advanced_permission_read_enforcement.sql:84), `confirm_sale`, `payments`, `supplier_payments`
- **Evidence:** The view aggregates payment amounts by organization and month without grouping by `payment_method` or account. Walk-in sale paid amounts are counted from `sales`, but the sales schema does not persist a tender method for those transactions. There is no bank/cash account ledger, opening balance, or bank reconciliation source in the active schema.
- **Business impact:** Owners cannot answer how much cash should be in the drawer or how much should appear in each bank/mobile wallet. The “cash flow” total cannot be tied to actual cash or bank statements.
- **Recommended correction:** Record tender rows with payment method/account and transaction/reversal links; introduce reconciled cash/bank accounts and opening balances before presenting cash/bank balances as trusted.
- **Verification:** Reconcile each method to an independent statement/drawer fixture, including mixed tender, refunds, supplier payment, and expense transactions.

### F-05 — Gross profit is based on values accepted from the client workflow

- **Severity:** Critical
- **Affected:** `confirm_sale`, `sales`, `sale_items`, `product_sales_performance`, `daily_sales_performance`
- **Evidence:** `confirm_sale` computes COGS from product average cost, but relies on persisted sale header totals and sale-item prices created by the browser. Report views sum those values. There is no verified server-side repricing or reconciliation assertion.
- **Business impact:** A manipulated or stale price/total changes revenue and reported gross profit while the stock movement still posts.
- **Recommended correction:** Calculate/validate invoice revenue server-side during sale confirmation and reject mismatch between all line totals and the invoice total.
- **Verification:** Post normal and intentionally tampered fixtures; verify rejected transactions create no confirmed sale, payment, stock movement, or report amount.

### F-06 — Business date boundaries are not explicitly Asia/Yangon for core sales/payment dates

- **Severity:** High
- **Affected:** `sales.sale_date`, `payments.payment_date` in `0006_sales_and_receivables.sql`; `receive_purchase` and payment RPC defaults; daily reports and cron summaries
- **Evidence:** Core sales/payment date columns default to PostgreSQL `current_date`; report views group by those date values. The core SQL does not set database/session timezone or convert timestamps through the organization timezone. Several marketing functions explicitly use `timezone('Asia/Yangon', now())`, while the core sales path does not.
- **Business impact:** If hosted PostgreSQL sessions use UTC (the usual Supabase default), a transaction during 00:00–06:29 Myanmar time can receive the prior UTC date and appear in the wrong daily close/month boundary.
- **Recommended correction:** Make business-date assignment explicit using the organization timezone or require a validated business date from the client and store a timestamp separately. Define month/day close rules once.
- **Verification:** Test transactions around 23:59/00:00 UTC and Asia/Yangon boundaries; compare daily/monthly reports to the shop's local business date.

## Reconciliation formulas to establish in staging

- **Stock:** opening + accepted receipts + customer returns + positive adjustments/transfers-in − sales − supplier returns − negative adjustments/transfers-out, by product and branch.
- **Customer account:** opening balance + valid confirmed invoices − allocated valid payments − valid credits/refunds, with unapplied advances shown separately.
- **Supplier account:** opening balance + recognized supplier invoices/receipts − allocated payments ± valid credits/reversals, with advances shown separately.
- **Gross profit:** validated posted revenue − frozen cost of goods sold, adjusted by explicit sale/return/reversal entries.
- **Cash/bank:** opening account balance + tenders and receipts − supplier payments/refunds/expenses ± transfers, reconciled by payment account.

None of these formulas has a passing database reconciliation suite in the available environment.
