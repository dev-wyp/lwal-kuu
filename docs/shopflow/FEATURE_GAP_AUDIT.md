# ShopFlow V1.0 Feature Gap Audit

**Audit date:** 2026-11-19  
**Scope:** Checked-in application, migrations `0001`–`0042`, schema snapshot, routes, representative module workflows, tests, and existing audit/architecture documents. This is a local source audit only; production state, effective production grants, migration history, and production data were not queried.  
**Overall classification:** PARTIAL / NOT READY. The repository contains substantial ERP workflows, but it does not yet provide a complete double-entry accounting, returns, cash/bank reconciliation, and verified transaction/tenant contract.

This gap matrix records the implementation before migration `0043`. P0 local changes are tracked in [P0_SECURITY_AND_TRANSACTION_FIXES.md](P0_SECURITY_AND_TRANSACTION_FIXES.md); they remain unverified until SQL replay and integration tests pass.

## Executive summary

The app has real modules and database support for catalog, customers/suppliers, purchases/receiving, POS/sales, payments, expenses, stock ledger, branches/transfers, reporting, subscriptions, marketing, support, audit, and tenant backup/restore. The existence of a screen or migration does not establish that the business invariant is fully enforced.

The highest-risk source findings are reproducible from the checked-in SQL:

1. `confirm_sale()` checks the idempotency key globally before checking the requested sale's organization, trusts persisted/client totals and line prices, and needs stronger branch/product/quantity/payment validation and stock locking.
2. `record_customer_payment_and_allocate()` inserts the caller's customer, silently skips invalid/unconfirmed sale IDs, and does not bind customer to invoice or cap allocations against payment and invoice outstanding.
3. `receive_purchase()` processes purchase items by purchase ID without checking item/product tenant ownership, updates product by ID alone, and overwrites received quantity rather than supporting remaining quantities.
4. The core tenant relationships generally use single-column foreign keys, not organization-aware composite foreign keys.
5. Migration source creates broad `organization_settings` read access and migration `0015` promotes every existing profile. Effective production status is unverified.
6. `schema_unified.sql` is a historical concatenation of all migrations, not a flattened final schema: functions and policies may appear repeatedly. The active migration chain and migration ledger are the implementation contract to validate.
7. `database.types.ts` is incomplete versus the migration schema, yet application modules use `as any` for branch/marketing entities and RPCs.

## Feature matrix

| Feature | Existing Status | Required Action | Priority | Database | Backend | Frontend | Tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Organization and tenancy | NEEDS SECURITY FIX | Reconcile live policy state; tighten settings policy; enforce tenant-bound references and owner lifecycle | P0 | `0001`, `0011`, `0013`, `0042` | `has_org_membership`, onboarding RPC, permission helpers | `OrgContext`, `SettingsPage`, onboarding | Existing SQL tenant test; local DB unavailable |
| Authentication and membership | PARTIAL | Complete invitations, active-owner protection, secure membership changes; review admin escalation | P0/P1 | `0001`, `0015`, `0040` | Auth/context and permission RPCs | `AuthContext`, `SettingsPage` (invite currently only reports success per audit) | Auth E2E only; no membership lifecycle E2E |
| Product and category management | IMPLEMENTED / NEEDS TENANT VALIDATION | Validate related category/unit ownership; remove type escape hatches after generated contract | P1 | `0002` | CRUD via RLS | `ProductsPage`, `ProductModal`, `CategoriesPage` | Limited unit coverage; no CRUD E2E |
| Customers | IMPLEMENTED / PARTIAL | Enforce tenant references; clarify credit-limit behavior; improve ledger correctness | P1 | `0003`, `0006`, `0009` | RLS, ledger/report views | `CustomersPage`, `CustomerLedgerModal` | No customer workflow E2E |
| Suppliers | IMPLEMENTED / PARTIAL | Bind purchase/payment supplier ownership; validate balances/advances | P0/P1 | `0003`, `0005`, `0009` | RLS and receiving/payment paths | `SuppliersPage`, `SupplierStatementModal` | No supplier transaction integration test |
| Purchasing | PARTIAL | Add order lifecycle/cancellation, supplier invoice reference/reconciliation, partial receipt | P0/P1 | `0005` | `receive_purchase()` currently marks entire order received | `PurchasesPage` | No DB integration test |
| Goods receiving | NEEDS SECURITY FIX | Validate tenant and branch/product ownership; track received-to-date and reject duplicate quantities; weighted cost must use consistent ledger quantity/cost basis | P0 | `0004`, `0005`, `0036` | `receive_purchase()` | Receive dialog in `PurchasesPage` | No integration/concurrency coverage |
| Sales and POS | NEEDS SECURITY FIX | Server-recalculate all financial totals; validate branch/product/quantities/prices/payment; idempotency and stock lock | P0 | `0006`, `0036`, `0042` | `confirm_sale()` | `SalesPage`, receipt modal | Unit math only; no DB concurrency tests |
| Customer payments | NEEDS SECURITY FIX | Bind tenant/customer/invoice; cap allocations, deduplicate payment, support advances and reversals | P0 | `0006` | `record_customer_payment_and_allocate()` | `PaymentsPage` implements client-side FIFO but trusts DB for correctness | Existing pure FIFO unit test only |
| Supplier payments | PARTIAL | Validate supplier/purchase relationship, amount vs payable policy, idempotency, advances, and reversal | P0 | `0005` | No dedicated supplier payment RPC found; receiving path inserts payment directly | Receiving screen | No tests |
| Inventory | PARTIAL | Add physical counts/approval, stock aging, reorder suggestions, damaged/write-off workflows, unit conversion; all through ledger | P1 | `0004`, `0037` | Adjustment and branch balance logic | `InventoryPage` | No inventory ledger integration tests |
| Branches and stock transfers | PARTIAL | Verify all branch-scoped sales/purchase/adjustment paths and direct-write constraints; check transfer idempotency/permissions | P1 | `0036`, `0037` | `create_stock_transfer()` | `BranchesPage` | No branch E2E |
| Expenses | PARTIAL | Enforce expense category tenant ownership and payment account; add approval/reversal policy | P1 | `0007`, `0042` | RLS permission trigger | `ExpensesPage` | No tests |
| Cash and bank management | MISSING | Build financial accounts, transfers, cashbook, reconciliation; current payment method text fields are not account ledgers | P1 | New additive migrations required | New account/transfer/reconciliation RPCs | New financial account and cashbook UI | New unit, SQL integration, and E2E tests |
| Accounting | MISSING | Design double-entry chart, periods, journals, ledger, trial balance, and statements before implementation | P1 | New additive schema required | Balanced posting/reversal RPCs | New accounting module | New unit, DB, and reconciliation tests |
| Reports and analytics | PARTIAL | Add branch/date/timezone/export consistency and reconciliation; clarify cash vs accrual reports | P1 | `0009`, `0032`, `0036` | Views and report queries exist | `ReportsPage`, dashboard | Existing tests do not reconcile reports to source transactions |
| Subscription and billing | PARTIAL | Verify plan/usage enforcement, approvals, downgrade behavior and live grants; add reliable payment event lifecycle | P1 | `0008`, `0016`–`0020`, `0027`–`0032` | Entitlement/limit RPCs | `SubscriptionPage`, platform plan/subscription pages | Limited unit coverage; no subscription E2E |
| Marketing automation | IMPLEMENTED / NEEDS SECURITY VERIFICATION | Verify definer grants, retry/monitoring, token safety and tenant boundaries on deployed schema | P1/P2 | `0021`–`0026`, `0038` | Edge functions and publishing worker | `/admin/marketing/*` | Marketing logic unit tests; approval SQL test not run |
| Notifications | PARTIAL | Verify outbox delivery, idempotency, retries, dead-letter/monitoring and scheduler privileges | P1 | `0010`, `0018`, `0038` | Dispatcher/cron functions | Notification context/admin automation | No delivery integration test |
| Permissions and audit logs | NEEDS SECURITY VERIFICATION | Verify all definer functions/ACLs; ensure critical events immutable, scoped, complete | P0 | `0033`, `0040`–`0042` | `has_org_permission`, audit trigger, RPC policies | Settings and platform admin screens | `tenant_security.test.sql` exists but DB unavailable |
| Backup and restore | NEEDS SECURITY FIX | Restore must not overwrite posted immutable ledgers; versioned export, validation, preview and audit | P0/P1 | `0039` | Restore RPC uses conflict updates on business rows per source review | Platform/tenant backup flow | No restore safety tests |
| Platform administration | NEEDS SECURITY FIX | Review promoted admins against explicit allowlist; restrict global cron RPCs and verify grants | P0 | `0015`, `0018`, `0033`, `0040` | Admin RPCs and global jobs | `PlatformAdminPage`, admin modules | No allowlist-backed test; production unknown |
| Sales and purchase returns | MISSING | Add auditable return documents, partial quantities, stock disposition and credit/refund flows | P1 | New additive schema required | Atomic approval/post/reversal RPCs | New return workflows | New unit/DB/E2E coverage |
| POS cashier operations | PARTIAL | Add shift open/close, expected-vs-actual cash, split tenders and discount/price approval | P1 | New additive schema likely | Shift and payment RPCs | Extend `SalesPage` | No shift tests |
| TypeScript database contract | NEEDS SECURITY FIX | Generate from validated schema; reconcile/move marketing overlays; remove `any` only against generated output | P1 | All active schema objects | RPC signatures/types must agree | `database.types.ts`, `app-database.ts`, modules | `npm run build` only validates current handwritten contract |

## Evidence and affected files

| Finding | Evidence | Affected files / objects | Risk |
| --- | --- | --- | --- |
| Sale confirmation trust boundary | `0006_sales_and_receivables.sql` defines globally unique `sales.idempotency_key`; `confirm_sale()` looks up key without `organization_id`. Function consumes sale item values and stock without a sufficient server contract. | `supabase/migrations/0006_sales_and_receivables.sql`; `src/modules/sales/SalesPage.tsx` | Duplicate/foreign result disclosure, incorrect invoices, overselling, and ledger inconsistency |
| Payment allocations | RPC in `0006` accepts `p_customer_id`, inserts payment, adds allocations to confirmed sales without same-customer check or amount ceilings; nonmatching rows may be skipped | `supabase/migrations/0006_sales_and_receivables.sql`; `src/modules/payments/PaymentsPage.tsx` | Corrupt receivables and customer balances |
| Purchase receipt | RPC in `0005` joins purchase items/products by ID, uses purchase item quantity rather than a validated incremental receipt, and updates product by ID; no supplier payment RPC was found in migrations | `supabase/migrations/0005_purchasing_and_payables.sql`; `src/modules/purchases/PurchasesPage.tsx` | Cross-tenant product cost changes, duplicate/partial receipt errors |
| Tenant referential integrity | Core tables store `organization_id` but references commonly use single IDs; source audit enumerates mappings | `0002`–`0007`, `0036`; `cross-tenant-reference-review.md` | A valid FK can still link records from different organizations |
| Settings RLS | `0013_fix_member_select_policy.sql` includes blanket authenticated SELECT allowance; `0042` does not replace settings policy | migrations `0013`, `0042`; `organization_settings` | Cross-tenant configuration/contact data exposure if active |
| Platform admin bootstrap | `0015_grant_superadmin_and_tenant_management.sql` promotes all existing profiles matching auth users | migration `0015`; `profiles.is_platform_admin` | Platform-wide tenant exposure/control |
| Broad scheduled functions | Several global SECURITY DEFINER jobs lack consistent explicit revokes in source; effective grants not queried | `0010`, `0018`, `0023`, `0024`, `0035`, `0038` | Global subscription, notification, and social mutations may be callable by client roles |
| Backup restore | `0039_tenant_backup_restore.sql` dynamically upserts imported rows with `ON CONFLICT DO UPDATE`, including ledgers per existing audit | migration `0039`; backup RPC | Historical posted financial/stock records can be rewritten through restore |
| Reporting/accounting gap | Report views/pages exist, but no chart of accounts, journal entries, accounting periods, or balanced posting model found in the active schema | `0001`–`0042`; `src/modules/reports/ReportsPage.tsx` | Summary reports cannot substitute for accrual accounting/reconciled ledger |
| Incomplete database types | Static inventory documents 60 source tables vs 25 declared in `database.types.ts`; branches/marketing code uses `as any` | `src/types/database.types.ts`, `src/types/app-database.ts`, `src/modules/inventory/BranchesPage.tsx` | Schema drift and unchecked client contracts |
| Workflow tests too shallow | Unit scripts test a few pure calculations; E2E covers public routes, auth validation, pricing and responsive public pages; SQL integration scripts exist but require PostgreSQL/Supabase | `tests/unit/*`, `tests/e2e/lwal-kuu.spec.ts`, `supabase/tests/*` | Critical transaction behavior is not regression-tested |
| Invitations incomplete | Existing audit and settings handler inspection find invitation action only reports success; no invitation/member creation call | `src/modules/settings/SettingsPage.tsx` | Owners cannot reliably onboard staff from the UI |

## Baseline verification (before implementation)

- `npm run test:unit`: PASS (business calculation and marketing logic scripts).
- `npm run test:e2e`: PASS, 5 Playwright tests. The first sandboxed launch could not bind local port 3000; rerun with local server permission passed.
- `npm run build`: PASS (`tsc -b` and Vite production build).
- `npm run lint`: PASS (no ESLint output/errors).
- SQL integration tests: NOT RUN. The local Docker/PostgreSQL availability limitation recorded in prior audit remains; no production SQL was run.
- Live migration history, production policies/grants/data, and authorized admin allowlist: UNVERIFIED/BLOCKED.

## Classification convention

- **IMPLEMENTED:** source path exists for the described basic function; this does not mean production is verified.
- **PARTIAL:** basic workflow exists but required invariants/capabilities are missing.
- **MISSING:** no corresponding module/schema implementation was found.
- **NEEDS SECURITY FIX:** source contains a security or transaction-integrity weakness.
- **NEEDS TESTING:** source behavior lacks adequate automated verification.
- **DUPLICATE:** not found as an active blocker; historical migration definitions repeat intentionally as migration history.
- **NOT REQUIRED:** not used to dismiss requested ERP requirements.

