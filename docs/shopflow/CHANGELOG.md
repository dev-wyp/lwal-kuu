# ShopFlow Implementation Changelog

## 2026-11-19 — Audit, roadmap and first local P0 patch

- Added `FEATURE_GAP_AUDIT.md` with source-linked classifications for all 22 requested business/platform areas.
- Added `IMPLEMENTATION_ROADMAP.md` with ordered phase gates and a P0 task matrix.
- Added design/verification documents for transaction workflows, accounting, inventory, tests, and production readiness.
- Added migration `0043_p0_transaction_integrity.sql`:
  - organization-aware composite FKs for core required transaction relationships (`NOT VALID` for safe legacy-data rollout);
  - organization-scoped sales/payment idempotency keys;
  - server-side sale total/discount/payment validation, branch-scoped stock locks and stable retry payload;
  - customer/invoice ownership and allocation-bound validation with unallocated advance support;
  - tenant/role-checked purchase receiving and branch stock movement;
  - organization-scoped organization-settings SELECT policy;
  - explicit client revocation for global cron workers.
- Updated POS to retain an uncertain confirmation key/request and display database-returned totals; updated payments UI to retain retry keys and explain unallocated advance balances.
- Added SQL integration regression script `p0_transaction_integrity.test.sql`.
- Added migration `0044_supplier_payment_workflow.sql` for idempotent partial supplier payments, purchase allocations and advances; added a supplier payment dialog and corresponding SQL regression assertions.
- Operator-provided production push errors show that `public.supplier_payment_allocations` already exists with a schema missing `organization_id` and `supplier_payment_id`. Migration `0044` now checks compatibility before changing the database and stops safely; `docs/audit/production-read-only-security-queries.sql` includes a catalog-only schema inspection. No duplicate allocation table or production mutation was performed by this work.
- Regenerated `supabase/schema_unified.sql` from the 44 numbered local migrations; this remains a source snapshot, not evidence of a deployed schema.
- Local checks: `npm run build`, `npm run lint`, and `npm test` passed (5 E2E tests). SQL tests and migration replay were not run; no production database was accessed.
- Still open: partial GRNs, later allocation/refund of supplier advances, financial returns/credits, legacy tenant-row remediation/constraint validation, live admin allowlist and effective production verification.

