# Plan feature implementation audit

**Scope:** feature catalogue in `0019_plan_feature_system.sql`, tier assignments from `0019` and `0031`, tenant UI routes/components, and database functions/triggers/RLS policies in repository migrations. This is a source-code audit; it does not inspect a live Supabase database.

## Status key

- **✓ Implemented:** the included workflow exists in the tenant app and has supporting data operations.
- **~ Partial:** some relevant UI or backend exists, but the full feature named in the catalogue is missing or incomplete.
- **✗ Missing:** the plan includes the feature, but there is no corresponding tenant workflow.
- **— Not included:** intentionally not enabled in that tier.

## Boolean features by plan

| Category | Feature | Starter | Business | Pro | Implementation notes |
| --- | --- | :---: | :---: | :---: | --- |
| Core | Product Management | ✓ | ✓ | ✓ | Product catalogue, create/edit, CSV import, stock and product limits. |
| Core | Category Management | ✓ | ✓ | ✓ | Category CRUD route and entitlement checks. |
| Core | Customer Management | ✓ | ✓ | ✓ | Customer list and create flow, with plan limit enforcement. |
| Core | Supplier Management | ✓ | ✓ | ✓ | Supplier list and create flow, with plan limit enforcement. |
| Core | Purchase Management | ✓ | ✓ | ✓ | Purchase orders, receiving, supplier invoices/payments, and inventory posting. |
| Core | Sales Management | ✓ | ✓ | ✓ | POS, invoice confirmation, receipt, and server-side plan checks. |
| Core | Cash Sales | ✓ | ✓ | ✓ | Paid sales supported and checked by the sales entitlement trigger. |
| Finance | Credit Sales | — | ✓ | ✓ | Credit invoices, customer balances, and payment collection supported. |
| Finance | Partial Payments | — | ✓ | ✓ | Partial invoice payments supported in POS and enforced when confirming sales. |
| Finance | Customer Ledger | — | ✓ | ✓ | Customer transaction statement and receivables summary. Feature gating is primarily in tenant UI. |
| Finance | Customer Debt Tracking | — | ✓ | ✓ | Credit limits, balances, and receivables list are implemented. |
| Finance | Supplier Payables | — | ✓ | ✓ | Payables summary and supplier payments implemented. Feature gating is primarily in tenant UI. |
| Finance | Payment & Receipt Management | — | ✓ | ✓ | Customer payment entry and receipts implemented. |
| Finance | Expense Management | — | ✓ | ✓ | Expense categories, entry, and list implemented. |
| Inventory | Inventory Management | ✓ | ✓ | ✓ | Stock movement ledger, balances, purchase costing, and sales deduction. |
| Inventory | Stock Adjustment | ✓ | ✓ | ✓ | Adjustment UI and transactional stock adjustment RPC; UI and DB entitlement checks exist. |
| Inventory | Stock Transfer | — | ✓ | ✓ | Branch-to-branch transfer screen and atomic RPC validate source stock and post paired ledger movements. |
| Inventory | Low Stock Alerts | — | ~ | ~ | Plan-gated alerts are scheduled and queued; platform-admin outbox delivery uses Resend when configured and currently requires an operator to dispatch. |
| Inventory | Advanced Inventory | — | — | ✓ | Pro includes weighted-average valuation, low-stock thresholds, branch-level balances, transfer ledger, and stock movement history. |
| Inventory | Barcode Support | — | — | ✓ | Entitled barcode field and camera scanner are available; compatible hardware scanners and manual entry also work. |
| Inventory | QR Support | — | — | ✓ | Entitled QR field and camera scanner are available on browsers with BarcodeDetector support. |
| Organization | Multi-Branch | — | ✓ | ✓ | Branch CRUD and limits, branch selection in POS/purchasing/inventory, branch stock balances, and server-side branch stock checks are implemented. |
| Reports | Daily Sales Report | ✓ | ✓ | ✓ | Daily revenue, COGS, gross profit, and margin report exists. |
| Reports | Basic Product Report | ✓ | ✓ | ✓ | Product sales, units sold, invoice count, revenue, COGS, and gross profit report added. |
| Reports | Monthly & Yearly Reports | — | ✓ | ✓ | Monthly and yearly sales summaries added. |
| Reports | Customer Statement PDF | — | — | ✓ | Customer statement has a print flow; browsers can save the print output as PDF. |
| Reports | Supplier Statement PDF | — | — | ✓ | Supplier statement has a print flow; browsers can save the print output as PDF. |
| Reports | Sales Analytics | — | — | ✓ | Selected-range invoice, revenue, and gross-profit KPIs include a daily revenue trend chart. |
| Reports | Purchase Analytics | — | — | ✓ | Monthly purchase volume, supplier, paid amount, and outstanding amount report added. |
| Reports | Branch Reports | — | — | ✓ | Branch revenue, invoices, COGS, and gross profit are shown in Branches & Stock Transfers. |
| Reports | Profit & Loss Report | — | — | ✓ | Monthly operating P&L added from confirmed sales, COGS, and recorded expenses; it is not a full general-ledger statement. |
| Reports | Cash Flow Report | — | — | ✓ | Monthly cash movement summary added from posted customer receipts, paid walk-in sales, supplier payments, and recorded expenses; no bank reconciliation is modeled. |
| Reports | Profit Estimation | — | ✓ | ✓ | POS now estimates gross profit from current average cost and cart price before confirming the sale. |
| Automation | Automated Reports | — | — | ~ | Daily/weekly summaries are scheduled and plan-gated; outbox delivery can be dispatched by a platform admin when Resend is configured. |
| Automation | Debt Reminders | — | — | ~ | Overdue-customer reminders are scheduled, deduplicated, plan-gated, and queued for platform-admin email dispatch. |
| Export | Manual Data Export | ✓ | ✓ | ✓ | CSV download is available for the active daily sales, receivables, or payables report. |
| Export | Excel Export | — | ✓ | ✓ | Excel-readable `.xls` download is available for the active daily sales, receivables, or payables report. |
| Security | Basic User Permissions | — | ✓ | ✓ | Fixed team roles and membership management exist. |
| Security | Advanced Permissions | — | — | ✓ | Pro admins configure manager/staff view/create/update/delete rights by module; restrictive database policies, views, and write triggers enforce those rights for tenant operational data. |
| Security | Audit Logs | — | — | ✓ | Tenant Activity Log captures catalog, customer, supplier, sales, purchasing, payment, expense, stock, branch, settings, membership, permission, and support-ticket changes. |
| Security | Backup & Restore | — | — | ~ | Pro owners/admins can export tenant operational data as JSON and merge a same-organization backup; restore does not delete records or include auth users/subscription/payment configuration. |
| Support | Priority Support | — | — | ✓ | Pro tenant request form, platform-admin status triage and written replies are available; no response-time SLA is modeled. |

## Usage limits by plan

| Limit | Starter | Business | Pro | Implementation notes |
| --- | ---: | ---: | ---: | --- |
| Active users | 1 · ✓ | 3 · ✓ | 10 · ✓ | Membership trigger checks entitlement and active-user count. |
| Active products | 100 · ✓ | 2,000 · ✓ | Unlimited · ✓ | Product trigger checks the plan limit. |
| Active customers | 100 · ✓ | Unlimited · ✓ | Unlimited · ✓ | Customer trigger checks the plan limit. |
| Active suppliers | 20 · ✓ | Unlimited · ✓ | Unlimited · ✓ | Supplier trigger checks the plan limit. |
| Branches | 1 · ✓ | 2 · ✓ | 5 · ✓ | Active branch counts are measured and enforced by the database; default branch is seeded for every organization. |

## Findings that apply across plans

1. Business/Pro and Pro still include features with partial or missing workflows, as shown above.
2. A number of sub-features are gated in React only. The primary module tables have plan-aware RLS/triggers, but not every add-on feature has equivalent server-side enforcement.
3. Migration 0031 is already recorded as applied in the production migration history, based on the `db push` output skipping it. The production plan assignments were not queried directly.
4. Production `db push` output confirms migrations 0033–0035 applied. Migration 0036 is still failing against pre-existing legacy branch/transfer tables and an RPC with a conflicting return type; migrations 0037–0041 are therefore still pending. Their code is present in the checkout but is not live yet.
5. Remaining limits: low-stock and automated/debt notifications are scheduled into the outbox, then a platform administrator dispatches them through Resend; backup restore merges organization records and does not replace the database or include auth users, subscription, and payment configuration. CSV/Excel exports cover the active sales, receivables, or payables report.
