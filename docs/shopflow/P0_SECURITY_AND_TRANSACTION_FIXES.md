# P0 Security and Transaction Fixes

**Status:** Local implementation created; database execution and end-to-end SQL verification are pending.  
**Migrations:** `supabase/migrations/0043_p0_transaction_integrity.sql`, `0044_supplier_payment_workflow.sql`  
**Regression test:** `supabase/tests/p0_transaction_integrity.test.sql`  
**Production:** Not modified. No production query or migration was executed.

Operator-provided `db push` output reports migration `0043` applied and `0044` failed against an existing `supplier_payment_allocations` relation. The error output is not an independent verification of remote migration history. The local `0044` now stops before schema changes when required allocation columns are absent; inspect production using the read-only query pack before designing a compatible migration.

## Work included

### Sale confirmation

- Requires authenticated organization sales-create permission and a bounded idempotency key.
- Scopes retries to `(organization_id, idempotency_key)` and rejects a key bound to a different sale.
- Requires a draft sale with an active same-organization branch and, when present, an active same-organization customer.
- Rejects nonzero tax until tax rules are configured server-side; current product catalog price is authoritative because no price-override approval flow exists.
- Recomputes line totals, subtotal, discount, total, paid amount, payment status, and cost snapshot from database rows.
- Locks products in stable order, takes the same organization/branch/product advisory lock used by the nonnegative stock trigger, checks branch stock, and atomically writes stock, payment, allocation, audit, and sale state.
- Returns a stable invoice object and items on both first execution and idempotent retry.

### Customer payment allocation

- Requires authenticated customer-update permission and an active same-organization customer.
- Requires positive amount, valid payment method, a JSON array, and a valid organization-scoped idempotency key.
- Rejects duplicate invoice entries, nonpositive allocations, total allocations above payment amount, nonconfirmed/foreign invoices, invoices belonging to another customer, and amounts above invoice outstanding.
- Locks invoice rows in stable UUID order and performs payment, allocation, balance, and audit writes atomically.
- Allows unallocated remainder as a customer advance and returns that amount for UI feedback.
- Frontend retains the same idempotency key and request for an uncertain retry; it blocks changing the request until the prior result is resolved.

### Purchase receipt

- Requires authenticated purchase-update permission, same-organization supplier/product/branch references, valid payment method/amount, and an outstanding receivable quantity.
- Recomputes purchase subtotal/total from stored line quantities and costs, rejects nonzero tax until a server tax rule exists, and checks the optional upfront payment against the recomputed outstanding amount.
- Receives the outstanding remainder once, updates product cost only with an organization predicate, records the stock movement in the selected branch, and logs an audit event.
- Rejects a completed/voided receipt replay and caps a linked upfront supplier payment at purchase outstanding.
- The existing API remains a one-shot “receive all remaining quantities” action. Per-line partial receiving and GRN history are still required and are not claimed complete.

### Supplier payments

- Adds an authorized, plan-gated RPC for partial supplier payments, organization-scoped idempotency, purchase allocation limits, and supplier advances.
- Locks supplier and invoice rows in a stable order and serializes supplier-level payments to guard against concurrent overpayment.
- Adds a tenant-scoped allocation ledger for new payments. Production has an existing `supplier_payment_allocations` table whose schema is incompatible with the expected RPC contract; migration `0044` now stops before changes until an operator inspects its columns and constraints. No parallel allocation table is created, and legacy `supplier_payments.purchase_id` rows are not converted into allocation rows.
- Revokes direct authenticated supplier-payment writes and adds a tenant-scoped purchase FK. Starter can still record a purchase paid in full at receipt; partial settlement and later supplier-payables workflows require the Business entitlement.
- Adds a supplier payment dialog with FIFO allocation, manual invoice amounts, and advance remainder display.

### Tenant and scheduled-function controls

- Adds unique `(organization_id,id)` indexes and NOT VALID composite tenant FKs for core purchase, sale, payment, stock, and branch relationships. NOT VALID constraints protect new writes but do not validate pre-existing records; existing mismatches still require a reviewed remediation and later validation step.
- Changes the organization settings SELECT policy to active membership/platform administrator only.
- Revokes client EXECUTE from global cron workers and grants service-role execution. Retains authenticated execution only for global RPCs intended for guarded platform-admin operations.
- Replaces globally unique idempotency keys with organization-scoped partial unique indexes. Existing data was not available for live compatibility verification; review before deployment.

## Explicitly incomplete / release blockers

- Effective production admin accounts have not been compared with an approved allowlist. Migration `0015` may have set all existing profiles to platform admin. This migration does not promote or demote accounts.
- Production grants, policy state, migration history, existing cross-tenant rows, and idempotency key values were not queried.
- The existing production allocation relation's complete schema and legacy data mappings remain unknown; do not retry migration `0044` until its columns, constraints, indexes, and policies are inspected.
- Existing rows are not validated by the new composite FKs. Query mismatch aggregates and plan remediation before validating them in staging.
- The migration has not been replayed on PostgreSQL. The local Docker/PostgreSQL runtime was unavailable in the prior audit. SQL syntax and runtime behavior remain unverified.
- The SQL regression test is checked in but has not been run. It requires a disposable Supabase/PostgreSQL database after migrations `0001`–`0044`.
- Sale reversal still needs customer refund/credit-note accounting; do not treat stock reversal alone as a complete financial reversal.
- Existing supplier advances are reflected in supplier balances but do not yet have a later invoice-allocation workflow; supplier refunds/reversals remain open.
- Sales with nonzero tax are deliberately rejected until an organization tax policy and server-side calculation exist.
- Sales price overrides are deliberately rejected until a permissioned approval workflow exists.
- Direct browser draft creation is still a two-step UI workflow. If item insertion fails after draft creation, the draft may require operator cleanup; moving draft creation/items into one database RPC is a follow-up.
- Full permission matrix tests, two-tenant direct table writes, branch-level authorization, concurrent checkout and restore immutability remain to be completed.

## Verification completed

- `npm run build`: PASS after local UI changes.
- `npm run lint`: PASS.
- `npm run test:unit`: PASS (existing business and marketing suites).
- `npm run test:e2e`: Previously 5/5 passed after the UI edits; the latest rerun was blocked because this environment denied Vite binding to `0.0.0.0:3000` (`EPERM`).
- SQL migration/test: NOT RUN. No production database was touched.

## Required next steps

1. Provision or identify a disposable local Supabase/PostgreSQL database; apply migrations from an empty database and upgrade from the approved staging snapshot.
2. Run `p0_transaction_integrity.test.sql` and existing SQL tests; fix any migration or SQL assertion failures before proceeding.
3. Extend SQL tests for concurrent stock deduction, invalid product price, cross-tenant customer/branch, payment idempotency replay, active role checks, and branch stock accounting.
4. Implement partial GRNs, later allocation of existing supplier advances, supplier payment refunds/reversals, and sales refund/credit notes.
5. Perform a read-only staging data mismatch report before validating composite FKs. Production requires separate authorized review and approval.

