# Phase 2 database audit and proposal — NOT APPLIED

**Status:** Planning artifact only. No SQL from this document has been applied to Supabase. The Phase 1 database contract is not present in the workspace, so the proposed names and definitions below are requirements for review, not claims about the live database.

## Audit result

The `wholesale-erp` repository has no `supabase/` directory, migration SQL, Prisma schema, generated Supabase `Database` type, database tests, or database documentation describing Phase 1. Its only Supabase directory is `lib/supabase/`, containing client/session setup. Git contains one initial commit and no hidden branches or earlier schema/migration paths. The workspace contains SQL/Prisma migrations for other, separate applications, but none identifies itself as the wholesale ERP's Supabase schema; reusing one would be unsafe.

The existing, untracked `app/sales/page.tsx` is the only concrete Phase 1 database contract found in this project. It queries:

- `memberships(user_id, org_id)` and `organizations(id, name)` to list a user's organizations.
- `stock_balances(product_id, org_id, sku, name, unit, sale_price, stock_on_hand)` for products and stock.
- `create_sale(p_org_id, p_items, p_customer_id, p_payment_method)`, with each item containing `product_id` and `quantity`.

Those references establish the names the UI expects; they do **not** establish actual column types, ownership/foreign-key constraints, RLS policies, stock-movement representation, or the implementation/security of `create_sale`.

## Exact Phase 1 contract still required

Before an additive Phase 2 migration can safely reference the existing schema, provide or verify:

1. **Organizations and memberships:** table definitions, primary keys, organization/user foreign keys, membership status and role/permission fields, membership lookup/indexes, RLS, and any helper function used to authorize organization access.
2. **Products:** canonical table and primary key, organization ownership column/constraint, SKU/name/unit fields, active/archive representation, quantity precision, and RLS. Confirm whether product identifiers are globally unique or unique only per organization.
3. **Inventory:** stock movement table and every required column/type (movement ID, organization/product foreign keys, movement type, quantity sign convention, reference/idempotency key, actor, timestamp); stock balance view/table definition; triggers or RPCs that maintain them; locking/concurrency strategy; grants and RLS. The existing UI's `stock_balances` view does not show how stock changes are recorded.
4. **Sales baseline:** full `create_sale` signature/body, grants, `SECURITY DEFINER` owner and `search_path` (if applicable), organization-membership checks, product ownership checks, and the sales tables/constraints it writes. Phase 2 must not regress or bypass this path.
5. **Customers/auth and database conventions:** auth user FK convention, ID-generation convention, timestamp/timezone policy, business timezone source, existing audit columns, and any existing returns, cash/bank, journal, or finance tables that supplier payments must reuse.

## Phase 2 entities and minimum database contract to review

Names below are provisional. Every business table must include `org_id`, and cross-organization links must be prevented by composite foreign keys (for example, referenced rows expose `UNIQUE (org_id, id)`) or equivalent database constraints/triggers. Prefer `numeric` for currency/quantity, never floating point. Exact precision must match Phase 1 product units and MMK policy.

- **suppliers:** `id`, `org_id`, `name`, normalized `code`, `phone`, `address`, `contact_person`, `notes`, `is_active`, `created_at`, `updated_at`, `created_by`, `updated_by`; unique `(org_id, normalized_code)` when code is non-empty.
- **purchases:** `id`, `org_id`, `supplier_id`, generated `purchase_number`, document kind (order/direct invoice), status, order/document date, expected date, supplier invoice number/date (nullable until supplied), currency, discount/additional charges, total, notes, actor/timestamps, and idempotency/audit metadata. Unique `(org_id, purchase_number)`; supplier link must be organization-consistent. A draft/order alone creates neither stock nor payable.
- **purchase_items:** `id`, `org_id`, `purchase_id`, `product_id`, ordered quantity, received/accepted/rejected/damaged quantity (or totals derived from receipt items), unit cost, discount, charges, line total, timestamps. Enforce organization-consistent purchase/product FKs and non-negative values; keep ordered and received quantities distinct.
- **goods_receipts / goods_receipt_items:** receipt header linked to purchase and supplier with unique organization-scoped receipt number and idempotency key; item rows reference purchase item and product, record newly received, accepted, rejected/damaged quantities, and cost snapshot. A posted receipt is immutable except through an explicit reversal/correction operation. Each posted accepted quantity creates exactly one corresponding stock movement inside the receipt transaction.
- **supplier_payments / supplier_payment_allocations:** organization/supplier-scoped payment with date, positive amount, method, reference, notes, idempotency key, actor/timestamps; allocation rows link payment to the applicable purchase/invoice and amount. Prevent allocation beyond payment amount or the invoice's recognized outstanding amount under concurrent submissions. Advance payment representation and refunds need explicit rules if required.

Use checks for positive amounts/quantities, valid states, and quantity relationships; indexes for org/date/status, supplier/date, purchase/item, receipt/purchase, payment/supplier, and allocation invoice/payment lookup. No supplier balance column is authoritative: balance is derived from accepted goods that are invoice-eligible under the chosen accounting rule, less valid allocations and explicit adjustments/reversals.

## Required transactional database functions and access controls

Do not allow the browser to directly insert/update inventory movements or posted receipts/payments. Proposed RPC responsibilities (final names/signatures must follow the real schema):

1. Create/update a draft purchase after `auth.uid()` and active organization membership/permission checks; validate supplier and every product belong to that organization; allocate purchase numbers in the database under a unique constraint/sequence-safe mechanism.
2. Post a receipt using one transaction and row locks: validate auth/membership; lock purchase and relevant purchase-item/inventory rows in a stable order; verify item ownership, remaining quantities and idempotency; insert receipt/header/items; write accepted stock movements exactly once using the existing movement schema; update derived receipt state; commit or roll back all effects.
3. Record supplier payment and allocations atomically: validate organization/supplier/invoice, positive amounts and allowed method; lock the payment/invoice allocation targets; enforce total allocation/outstanding limits; reject duplicate idempotency keys; commit the payment and all allocations together.
4. Provide read-only, organization-scoped report queries/views for supplier statements, purchase/receipt detail, summaries, and outstanding balances. Use consistent half-open date ranges in the configured business timezone.

Every table needs RLS enabled and policies based on the authenticated user's membership in `org_id`; writes should be restricted to the intended RPCs/roles. For any `SECURITY DEFINER` routine, set a safe fixed `search_path`, qualify object names, validate `auth.uid()` and membership inside the function, revoke default/public execution, and grant execution only to the authenticated role. Never rely on client-supplied `org_id` alone.

## Accounting policy captured from confirmation

Confirmed: purchase orders do not affect stock; accepted physical receipts do; partial and multiple receipts are supported; payments/financial entries must not be duplicated. The payable must reflect received goods and the applicable supplier invoice, not ordered quantities.

Confirmed: when goods arrive before the supplier invoice, recognize a temporary goods-received-not-invoiced (GRNI) liability on accepted quantities, then reclassify it against the supplier invoice when entered. The implementation must reuse verified finance/journal tables if present; if none exist, the accounting ledger design still needs reconciliation with the Phase 1 database before migration.

## Safe apply/rollback procedure after schema verification

1. Obtain the Phase 1 SQL/schema dump and inspect live constraints, RLS, functions, grants, and stock movement semantics; reconcile every provisional name/type above.
2. Add a timestamped, additive migration under `supabase/migrations/` only after reconciliation. Include preflight assertions and a rollback note. Do not include destructive drops or data resets.
3. Apply first to a non-production Supabase branch/database; run the RLS, tenancy, receipt idempotency/concurrency, payment allocation, rollback, and Phase 1 regression checks listed in the implementation request.
4. Review the generated SQL diff and database changes. Back up production, obtain operator approval, then apply through the project's established migration process. Never apply this proposal directly.
5. Generate and commit Supabase TypeScript database types from the verified schema, then wire the UI to those types/RPCs.

## Phase 2 acceptance checklist — not yet executable

Run these against a disposable Supabase database after the migration and RPC names are reconciled with Phase 1. Use authenticated sessions for organization-isolation checks, never a service-role client. Record database state before and after each scenario. None of these checks has been run because no database schema or test connection is available.

1. Create organizations A and B with separate users and memberships. As A's user, verify supplier and purchase reads for B return no rows and writes referencing B are rejected by RLS/RPC.
2. Create a draft purchase for 100 units. Verify available stock and stock-movement count/quantity are unchanged.
3. Post a receipt accepting 80 units. Verify stock increases by exactly 80 and exactly one accepted-quantity movement is associated with that receipt.
4. Post a second receipt accepting the remaining 20 units. Verify stock increases by exactly 20 more and the purchase becomes fully received.
5. Retry the first receipt with the same idempotency key and payload. Verify the original result is returned (or a duplicate is clearly rejected) and stock/movement totals do not change. Retry the same key with a different payload and verify rejection.
6. Attempt zero, negative, malformed, and over-remaining quantities, plus unauthenticated and non-member receipt posts. Verify each request fails and does not change receipt, purchase, movement, or stock state.
7. Force a receipt transaction to fail after its initial write step in a disposable test database. Verify the entire transaction rolls back: no receipt/header/item, stock movement, stock change, or received-total change remains.
8. Receive invoice-eligible goods, allocate a partial supplier payment, and verify invoice outstanding equals recognized invoice amount minus valid allocations; verify supplier statement totals reconcile.
9. Attempt allocations exceeding payment amount and invoice outstanding, including two concurrent allocations against the same outstanding invoice. Verify no over-allocation is committed.
10. Cancel an unreceived purchase and verify stock/payables are unchanged. For posted receipt/payment reversal, use the explicit reversal path and verify the original audit records remain and the inverse stock/financial effects are exactly once.
11. Launch two concurrent receipts whose combined quantities exceed remaining order quantity. Verify no over-receipt occurs and only the valid transaction's movements are committed.
12. Run the existing Phase 1 sale and inventory RPC regression scenarios; verify sale totals, stock movements, and organization checks still behave as before.
13. Compare daily/monthly/yearly reports and supplier statements at business-timezone date boundaries with source records; verify date filters are consistent and exported CSV totals reconcile.
