# Phase 3 — Customer Finance & Accounts Receivable

**Status:** Audit and migration plan only. No Phase 3 schema, route, or migration was implemented, and no database changes were applied. The authoritative Phase 1/2 schema and live Supabase connection are unavailable, so creating operational finance tables or RPCs now would risk duplicate receivables, cross-organization access, and inconsistent sales/payment records.

## Audit report

### Repository and database evidence

The `wholesale-erp` repository has no SQL migration files, `supabase/migrations` directory, Prisma schema, generated Supabase `Database` types, database integration tests, or schema documentation. `lib/supabase/` contains only browser/server/proxy client setup. Git history has one initial starter-template commit and no other branches containing migrations. Other workspace projects have their own SQL/Prisma files; none is established as this ERP's database schema and none was reused.

This audit inspected the repository structure, `package.json`, README, `.env.example` variable names, sales page, protected layout, Supabase client/server/proxy, Phase 2 planning document, and the existing supplier form. Secret environment values were not inspected or included.

### What is known from application code (not verified database definitions)

- The existing, untracked `app/sales/page.tsx` loads `memberships(user_id, org_id)` and `organizations(id, name)` and reads product/stock data from `stock_balances`.
- Its `create_sale` call passes `p_org_id`, one or more `{ product_id, quantity }` items, `p_customer_id`, and `p_payment_method`. The current page always sends `p_customer_id: null`; the UI offers `cash`, `credit`, and `other` payment method values.
- The UI does not reveal whether the RPC creates invoice rows, records payment amounts, computes credit sales, assigns due dates, or writes any customer ledger/payment record. It does not demonstrate actual authorization/RLS or transaction guarantees.
- No customer list/detail or customer-payment routes, invoice detail route, payment allocation UI, ledger, or finance service is present in the repository. No Phase 2 supplier/purchase/payment implementation is present either; only the earlier Phase 2 planning document and an isolated supplier form exist.

Therefore the following cannot be identified or safely assumed: customer table/key/organization columns; sales invoice and item table/key/status/amount fields; invoice due-date semantics; returns/credit notes; existing customer payment or allocation tables; accounting journals/ledger; membership roles/helper; stock/sales RPC grants, owners, and `search_path`; timestamp and business-timezone rules; payment methods; and number-generation conventions.

## Required schema inspection before migration

Obtain the Phase 1 and Phase 2 migrations/schema, or inspect these objects in a non-production database:

1. Organization/membership tables, membership status and permission fields, helper functions, RLS policies, grants, and organization-aware keys.
2. Customer and sales invoice/item tables, their constraints and indexes, invoice totals/discount/tax/rounding rules, statuses, payment fields, due-date fields, and all sale/post/void/refund RPC definitions.
3. Existing customer payments, allocations, credits/advances, credit notes, adjustments, reversals, ledgers/journals, and their posting/immutability behavior.
4. Existing finance/payment method tables and cash/bank integration; determine how customer collections post into finance without creating a second cash receipt or duplicate accounting entry.
5. Supabase Auth user identity and role checks; business timezone configuration and ID/receipt-number allocation mechanism.
6. Phase 2 supplier/purchase/receipt/payment structures and tests, if Phase 2 was implemented outside the currently available repository.

A schema-only, sanitized dump is sufficient for inspection. Do not provide service-role secrets in chat.

## Proposed additive design (conditional on schema reconciliation)

Do not create a second customer, invoice, payment, or ledger model if an equivalent already exists. Prefer extending the current customer record with a one-to-one organization-scoped credit profile only if customer columns or an equivalent profile do not already support these fields. Proposed profile data: `credit_limit`, `credit_terms_days`, `credit_enabled`, optional overdue restriction settings, and audit timestamps/actors. Enforce non-negative limits/terms and organization consistency in PostgreSQL.

Continue using the existing posted sales invoice as the receivable source. Do not copy invoice totals into an independently editable AR balance. Compute invoice outstanding from valid posted invoice amount, posted payment allocations, authorized credit notes/adjustments, and reversals. A voided invoice contributes no active receivable; preserve its audit trail and any required reversal records.

Create `customer_payments` and `customer_payment_allocations` only if inspection proves there is no equivalent. Candidate fields (names/types are provisional):

- Payment: `id`, `org_id`, `customer_id`, receipt number, payment date, positive `numeric` amount, configured method, reference, notes, status (`draft`/`posted`/`reversed` or equivalent existing enum), idempotency key, created/posted/reversed actor and timestamps, and reversal reference.
- Allocation: `id`, `org_id`, payment ID, invoice ID, positive `numeric` amount, creation/audit fields. Composite organization-aware FKs must ensure payment, customer, and invoice belong to the same organization and customer. Unique constraints/indexes must support retries, invoice balance lookups, and receipt-number uniqueness.

A posted payment may allocate across multiple invoices; an invoice may have multiple payments. Unallocated portions represent customer credits only if the existing finance model supports that explicitly. Do not silently apply an advance to invoices or reduce an invoice balance merely because a customer has an unallocated payment. Generate receipt numbers in a database transaction with a uniqueness guarantee; never trust client-supplied receipt number or balance.

### Transactional operations

Provide database RPCs (final names/signatures depend on the actual schema) that:

- Check `auth.uid()`, active organization membership, and permission in the database on every sensitive operation.
- Post a payment and its allocations atomically, validate customer/invoice ownership, positive amounts, payment total, invoice outstanding, and idempotency key; lock affected invoice/allocation rows in a stable order to prevent concurrent over-allocation.
- Reverse posted payments by immutable compensating records/entries, never deleting posted financial history; make reversal retries idempotent.
- Create/adjust customer credit profile under role checks, and enforce any configured credit block/override at the trusted sales RPC—not only in the UI. Overrides require permission and an audit record.
- Reuse the established finance/journal operation for cash/bank receipt posting. Do not post both through existing sales payment handling and a new AR receipt path for the same money.

Use safe fixed `search_path`, qualified names, explicit function ownership and least-privilege grants for `SECURITY DEFINER`; revoke default/public execute and grant only required roles. Enable/preserve RLS for every organization-owned table. Reads and writes must be scoped using verified membership authorization. Use composite foreign keys or equivalent database validation to block cross-org and cross-customer links.

### Ledger, credit, and report rules to implement

- Ledger convention proposal: invoices and debit adjustments increase customer receivable (debit); payments, credit notes, and credit adjustments reduce it (credit); reversals post equal-and-opposite entries. Opening balance + debits − credits = closing receivable. Reconcile the result to invoice outstanding totals.
- Credit exposure proposal: sum active invoice outstanding amounts less valid, explicitly unapplied customer credits; floor exposure at zero. Available credit is `max(credit_limit - exposure, 0)`. Apply overdue restrictions separately from the limit rule. Confirm this against any accounting policy already in use.
- Aging must be calculated from each invoice due date against the user-selected as-of date in the configured business timezone; not-yet-due, 1–30, 31–60, 61–90, and over 90 day buckets must not classify an invoice overdue before its due date.
- Report queries should use organization filters and half-open timezone-aware date ranges; CSV exports must match filtered totals. Paginate large result sets.

## Migration and delivery plan after schema verification

1. Inventory and document existing customer/invoice/payment/ledger objects, constraints, policies, grants, RPCs, and finance integration. Map the Phase 3 requirements to existing structures and explicitly identify gaps.
2. Propose a timestamped, additive migration only for missing profile/payment/allocation structures, constraints, indexes, RLS, and policies. Include rollback notes; do not drop/reset existing objects or data.
3. Implement server-side transactional posting/reversal and credit enforcement using the verified schema. Generate strict TypeScript database types from that schema.
4. Implement customer credit profile, payment/allocation, statement, outstanding, aging, collection, and utilization pages using current routes/components/conventions after the RPC/type contract is established.
5. Add automated database/RLS/concurrency tests, then run Phase 1 and Phase 2 regressions in a disposable Supabase project before production deployment.

## Acceptance checks (not run)

After implementation, verify: full and partial invoice settlement; split allocation across invoices; multiple receipts against one invoice; unallocated advances leave invoice balances unchanged; duplicate payment retry is idempotent; concurrent requests cannot over-allocate; invalid/cross-customer/cross-org attempts fail; reversal restores the correct receivable without deleting audit history; aging honors due dates and the chosen as-of date; ledger reconciles to invoices/allocations; and existing sales/inventory plus supplier purchasing/receiving/payments still pass regression tests.

## Current blocker and safe next step

The repository does not contain the database contract and the available Supabase configuration is a browser publishable key, not database/schema access. No Phase 3 migration or finance UI should be wired against guessed columns/RPCs. Supply the Phase 1/2 schema and function/RLS definitions or enable an authenticated database-inspection connection; then complete step 1 and review the actual mapping before proposing executable SQL.
