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
- Added `MIGRATION_0044_ROOT_CAUSE_AND_PROPOSAL.md`, a focused read-only diagnostic SQL pack, and a staging verification runbook. The production table's complete schema is still unknown, so no production-specific migration was invented.
- Expanded the disposable P0 supplier-payment assertions for multiple invoice allocations, full settlement, changed-payload retries, over-allocation rollback, cross-tenant supplier/purchase rejection, and audit counts. Concurrency is a two-session staging test; reversal remains blocked because its RPC and accounting contract are not implemented.
- Regenerated `supabase/schema_unified.sql` from the 44 numbered local migrations; this remains a source snapshot, not evidence of a deployed schema.
- Local checks: latest `npm run build`, `npm run lint`, and `npm run test:unit` passed. SQL tests and migration replay were not run; this work did not access or modify production.
- Still open: partial GRNs, later allocation/refund of supplier advances, financial returns/credits, legacy tenant-row remediation/constraint validation, live admin allowlist and effective production verification.

## 2026-11-19 — Pricing consistency and direct ledger entitlement patch

- Shared plan comparison rules across public pricing and signed-in subscription screens. Lower-tier inclusion is displayed only when the current tier actually includes every feature from the previous displayed tier; non-cumulative plans show their complete enabled feature list.
- Matched normalized limit-row fallback to legacy plan columns on both screens, displayed configured trial duration from the plan record, and calculated yearly savings from stored monthly/yearly prices. No price values were changed.
- Registration now shows the selected plan's configured trial duration; onboarding success text no longer hard-codes a 14-day term.
- Removed the unsupported two-hour payment review promise and clarified that payment verification is manual and gateway activation is not available.
- Added migration `0045_plan_gated_customer_and_supplier_ledgers.sql` to gate balance summary views and supplier payment reads by plan, and to enforce plan entitlement, membership, and same-organization customer ownership in the customer statement RPC.
- Regenerated `supabase/schema_unified.sql` from all 46 numbered migrations so the local schema snapshot remains aligned.
- Added public pricing Playwright assertions and disposable SQL assertions for Business allow, Starter direct-call denial, and cross-organization customer rejection. Tests have not been executed.
- Added `supabase/tests/plan_feature_matrix.test.sql` to verify all 42 standard-plan boolean assignments and the five normalized/legacy usage limits.
- Added `tests/unit/plan-presentation.test.mjs` for cumulative feature lists, non-cumulative custom plans, limit fallback, and savings calculations. `npm run test:unit` passed.
- Local checks: `npm run build`, targeted ESLint, and `git diff --check` passed. SQL and Playwright suites were not run. Production was not queried or modified. Migration 0045 remains unapplied and is blocked behind the unresolved 0044 schema mismatch.
- Added migration `0046_consistent_plan_limit_fallback.sql` so runtime limit resolution matches both pricing screens: normalized row, then legacy plan column, then zero/unconfigured if neither exists; explicit `-1` still means unlimited.
- Expanded the plan matrix SQL suite to compare runtime feature RPCs for all standard tiers, verify current usage and limits, prove custom-plan assignments do not inherit standard features, deny expired subscriptions, and reject an over-limit Starter membership insert. These SQL assertions are not executed; migration 0046 is also pending behind 0044.
- Follow-up security review found that `get_customer_statement` is `SECURITY DEFINER`; migration 0045 now also enforces the caller's `customers:view` role permission. Added a disposable Pro-staff regression assertion that a denied role cannot read the customer statement. SQL remains unexecuted.
- Migration 0045 now also restricts direct authenticated reads of customer payments and allocations to entitled plans and roles, closing a base-table path around the customer ledger UI. Tenant-security SQL now checks Business access and Starter denial; it has not been executed.

## 2026-11-20 — Preserve Starter customer and cash-sale workflows

- Decoupled customer identity listings from the plan-gated customer balance view. Customer management and POS now read tenant-scoped customer records for all eligible plans and request ledger totals only when customer ledger/debt entitlement is active.
- The POS customer selector shows balance text only for ledger-enabled plans. The dashboard hides the receivable KPI and skips its ledger query when the plan does not include ledger access.
- Migration 0045 now embeds matching entitlement checks in direct reporting and branch view reads; the SQL matrix suite asserts the predicates are present.
- Local build, unit tests, lint, and whitespace checks passed. SQL and Playwright verification were not run; migrations remain unapplied.

## 2026-11-20 — P0 customer payment retry integrity

- Added migration `0047_customer_payment_idempotency_fingerprint.sql`. It checks the existing payment/allocation column contract before changing the schema. Customer payment retries now compare a canonical fingerprint of organization, customer, amount, method, reference, notes, and sorted invoice allocations. Reusing a key with a changed payload is rejected; equivalent retries serialize on a transaction advisory lock and return the original result.
- Existing rows are preserved. Legacy rows without a fingerprint are checked against their stored payment fields and allocation rows before a retry is accepted. Added regression assertions for equivalent retry, changed allocations, changed notes, and duplicate ledger effects.
- This P0 item is implemented in local source but not complete: SQL integration tests could not run because Docker is unavailable and sandbox policy blocks PostgreSQL shared memory (`shmget`) for a scratch server. `supabase status` confirmed the linked project is production, so no remote database command or E2E suite was run.

## 2026-11-20 — Phase B compatibility evidence pack (source-only)

- Reviewed the Phase B attachment and current migrations `0043`–`0047`, related SQL tests, and the existing 0044 runbook. This review performed no database connections or SQL execution.
- Expanded the read-only supplier-allocation diagnostic with parent composite-key/index prerequisites, effective table privilege checks (including TRUNCATE/REFERENCES/TRIGGER), owned sequence grants, and non-internal trigger/function security details.
- Added a sanitized, blank diagnostic results template and a migration dependency/compatibility report. They distinguish operator-reported CLI errors from independently verified database state.
- Migration `0044` remains blocked. No legacy schema mapping, corrected migration, reversal implementation, staging result, or production verification is claimed because no diagnostic output or approved isolated database was provided.
- SQL suites and migrations `0043`–`0047` were not executed. Later-phase verification and reversal design remain deferred; no production database was queried or modified.

