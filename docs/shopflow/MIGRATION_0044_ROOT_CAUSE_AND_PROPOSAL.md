# Migration 0044 Root Cause and Compatibility Proposal

**Decision:** Do not retry migration `0044` against production until the read-only diagnostic output has been reviewed and the migration has been adapted to the verified relation. No production query or write was executed while preparing this report.

## Root cause

Local operator-provided `supabase db push` output reports two successive failures in `0044_supplier_payment_workflow.sql`:

1. An index on `supplier_payment_allocations(organization_id, purchase_id)` failed because the existing relation did not have `organization_id`.
2. After a local migration revision, adding the composite FK failed because the existing relation did not have `supplier_payment_id`.

These logs show that a production relation named `public.supplier_payment_allocations` exists with a schema different from the schema assumed by `0044`. They do not establish its full column types, constraints, policies, indexes, or row contents. Remote migration history and effective schema have not been independently inspected. Use [the read-only diagnostic](../audit/supplier-payment-allocation-read-only-diagnostic.sql) before proposing a data mapping.

The migration uses `CREATE TABLE IF NOT EXISTS` with the expected schema. PostgreSQL skips table creation when a relation with that name already exists; it does not reconcile the existing columns. Later statements then assume the expected shape. That is the direct compatibility defect.

## Local source findings

| Source | Finding |
| --- | --- |
| `0005_purchasing_and_payables.sql` | Creates `supplier_payments` with `id`, `organization_id`, `supplier_id`, nullable `purchase_id`, payment number/date/amount/method/reference/notes/actor/timestamp. It creates no supplier allocation table. `receive_purchase()` records an optional payment directly against a purchase. |
| `0006_sales_and_receivables.sql` | Creates customer `payment_allocations` linking `payments` to `sales`; this is a different ledger and does not define `supplier_payment_allocations`. |
| `0043_p0_transaction_integrity.sql` | Adds the `supplier_payments(organization_id,supplier_id)` composite relationship. It does not define the supplier allocation relation. |
| `0044_supplier_payment_workflow.sql` | Assumes allocation columns `id uuid`, `organization_id uuid`, `supplier_payment_id uuid`, `purchase_id uuid`, `amount numeric`, `created_at timestamptz`; assumes unique `(organization_id,supplier_payment_id,purchase_id)`, composite FKs to supplier payments and purchases, member-read RLS, and RPC access to the same columns. |
| Frontend/types | Supplier UI calls `record_supplier_payment_and_allocate`; local generated/manual database types do not establish the deployed allocation schema. No other local application code reads the allocation table directly. |

Repository search found no definition of `supplier_payment_allocations` in migrations `0001`–`0043`. The first local definition is in `0044`. The existing production relation is therefore outside the checked-in migration contract or was created by an untracked deployment path.

## Dependencies and compatibility conditions

The intended allocation relation depends on:

- `organizations(id)` for tenant ownership.
- `supplier_payments(id)` and `purchases(id)` for the two linked documents.
- Unique parent keys `(organization_id,id)` on `supplier_payments` and `purchases`; local `0043`/`0044` create these indexes.
- `has_org_membership()` and `is_platform_admin()` for member-read RLS.
- `record_supplier_payment_and_allocate()` for all new allocation writes; direct client writes are revoked.
- `receive_purchase()` for upfront receipt payments, which continue to use `supplier_payments.purchase_id` rather than allocation rows.

Before adding constraints or adapting the RPC, operators must identify the existing payment-reference column and type, purchase-reference column and type, tenant column if any, amount column and type, primary key, unique keys, foreign keys, triggers, RLS policies, grants, and all existing aggregate mismatches. Preserve every existing row. An existing payment reference must be proven to identify a row in `supplier_payments`, not inferred from a similar column name.

## Can the existing table be extended safely?

**Not yet determined.** The operator logs reveal missing expected columns but not whether equivalent columns exist under another name, whether they reference the correct parent tables, or whether existing rows can be assigned to a tenant without ambiguity. Adding columns/backfilling now would invent a mapping. Creating a second table would duplicate a business ledger and is also rejected.

## Migration proposal after diagnostic review

1. Compare the full column/type/constraint/policy results with the expected contract above.
2. If equivalent references exist, document the exact mapping. Preserve original columns and values; do not rename/drop them.
3. Produce aggregate counts for null/orphan/cross-tenant references, duplicate payment/purchase pairs, invalid amounts, and allocations above payment or invoice limits. Do not return customer/supplier PII.
4. If tenant ownership can be derived unambiguously from both linked documents, add a nullable tenant column and backfill only rows where both parents agree. Keep ambiguous/orphan rows unchanged and stop before enforcing `NOT NULL` or validating FKs.
5. Add tenant composite FKs as `NOT VALID` only after type and parent uniqueness are confirmed. New writes must be checked immediately; validate historical rows only after a reviewed remediation plan.
6. Add the organization-scoped allocation uniqueness rule only after duplicate counts are zero or duplicates are remediated under an approved plan.
7. Adapt the RPC to the verified names and types. Keep authorization, idempotency fingerprint, supplier/invoice locks, allocation ceilings, audit writes, and atomic rollback.
8. Design payment reversal as an audited compensating operation. No reversal RPC currently exists in local migrations; do not silently delete or mutate posted payment/allocation rows.
9. Run the clean replay and upgrade tests on disposable local/staging databases before any production change review.

## Current status

- Production schema: **UNVERIFIED**.
- Migration `0043`: operator logs report success; migration history is not independently confirmed.
- Migration `0044`: operator logs report failure; local migration now has an early compatibility guard but is not a corrected production migration.
- Supplier payment SQL tests: prepared locally, not executed against PostgreSQL.
- Production deployment: explicitly out of scope.

