# Phase B Staging Verification Runbook

**Scope:** disposable local Supabase and a dedicated staging project only. Never use the production project as a test target. Do not run `supabase db reset --remote`.

## Gate 0: Resolve migration 0044 compatibility

1. Run `docs/audit/supplier-payment-allocation-read-only-diagnostic.sql` only in a disposable local database or explicitly approved isolated staging project, one section at a time. Production is forbidden for this Phase B investigation, including read-only queries.
2. Confirm the staging project ref in the Supabase Dashboard before reading catalogs. The SQL output cannot prove the project ref.
3. Review columns/types, FKs, unique constraints/indexes, RLS/policies, RPCs/ACLs, and aggregate data mismatch counts.
4. Compare the exact results with `docs/shopflow/MIGRATION_0044_ROOT_CAUSE_AND_PROPOSAL.md`.
5. Adapt migration `0044` only after the relationship mapping is evidenced. Preserve legacy rows/columns. If payment or purchase ownership cannot be proved, stop and create a reviewed remediation proposal.

The diagnostic is read-only. It does not apply the migration or verify that a migration history row matches the effective schema. Its output is not production verification.

## Gate 1: Clean local migration replay

Prerequisite: Docker Desktop is running. These commands target the local Supabase stack; `db reset --local` destroys only the local database and replays local migrations.

```bash
npx supabase start
npx supabase db reset --local
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/p0_transaction_integrity.test.sql
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/tenant_security.test.sql
```

The SQL scripts use transaction-scoped fixtures and `ROLLBACK`; verify psql exits successfully. Do not add production credentials to shell history or logs.

## Gate 2: Dedicated staging project upgrade

Prerequisites:

- A staging project ref distinct from production ref `lfajonwbfweflkymuvmx`.
- A reviewed staging snapshot/seed with no production customer or supplier PII.
- A successful local replay and completed Gate 0 schema mapping.
- A database backup/snapshot of staging before migration.

Use the approved staging ref explicitly. Do not relink to or target production.

```bash
export STAGING_PROJECT_REF='<approved-staging-project-ref>'
test "$STAGING_PROJECT_REF" != 'lfajonwbfweflkymuvmx' || { echo 'Refusing production target'; exit 1; }
npx supabase link --project-ref "$STAGING_PROJECT_REF"
npx supabase migration list --remote
npx supabase db push --dry-run --remote="$STAGING_PROJECT_REF"
```

Review both outputs and confirm they name only the staging project and only the reviewed pending migration(s). After the staging owner approves the concrete plan:

```bash
npx supabase db push --remote="$STAGING_PROJECT_REF"
npx supabase migration list --remote
```

Capture the successful migration list and the post-migration catalog diagnostic. A successful push alone does not prove RLS, grants, data mappings, or RPC behavior.

Run the SQL regression suites against a disposable database restored from staging or a dedicated staging test branch, not against production. Supply its PostgreSQL connection string from an approved secret manager without echoing it:

```bash
psql "$STAGING_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p0_transaction_integrity.test.sql
psql "$STAGING_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/tenant_security.test.sql
```

The scripts roll back their fixtures. For maximum isolation, prefer a separate disposable test branch/database rather than the long-lived shared staging database.

## Gate 3: Concurrent supplier payment test

Use two independent `psql` sessions against the disposable test database. Seed and commit one test organization, one supplier, and one received purchase with an outstanding payable of 100. Use a test account authorized for `purchases.update` and the supplier-payables entitlement. Never use real supplier/payment data.

Session A:

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '<test-user-uuid>', true);
select public.record_supplier_payment_and_allocate(
  '<org-uuid>', '<supplier-uuid>', 60, 'cash',
  '[{"purchase_id":"<purchase-uuid>","amount":60}]'::jsonb,
  null, 'concurrency test A', 'concurrency-test-request-a-0001'
);
-- Leave this transaction open while Session B invokes its call.
```

Session B, while A is still open:

```sql
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '<test-user-uuid>', true);
select public.record_supplier_payment_and_allocate(
  '<org-uuid>', '<supplier-uuid>', 60, 'cash',
  '[{"purchase_id":"<purchase-uuid>","amount":60}]'::jsonb,
  null, 'concurrency test B', 'concurrency-test-request-b-0001'
);
```

Expected: B waits for the supplier lock. Commit A. B must then fail because the remaining payable is only 40; it must not create a payment, allocation, audit success, or change `paid_amount`. Roll back B after recording the expected error. Query aggregate fixture counts and clean up only the disposable test tenant after collecting evidence.

## Gate 4: Reversal and audit acceptance criteria

Local migration `0044` currently has no supplier-payment reversal RPC or reversal status/ledger contract. Do not report reversal as implemented or passing. Before writing a reversal test, define the immutable source-payment link, reversal status/amount model, treatment of allocated versus unallocated advance, invoice balance restoration, stock/accounting impact, idempotency, permissions, and audit payload.

After the reversal contract/RPC is implemented, its SQL test must verify: only one reversal per payment; same-organization permission; a reversal cannot exceed the unreversed amount; purchase `paid_amount` and supplier payable are restored exactly once; allocations are reversed/compensated without deleting original rows; duplicate retries return the same reversal; audit history contains both original and reversal actor/reason; invalid requests leave all ledgers unchanged.

## Evidence and stop conditions

Record separately:

- Local clean replay: PASS/FAIL, CLI version, migration versions.
- P0 transaction suite: PASS/FAIL; tenant security suite: PASS/FAIL.
- Existing allocation schema and aggregate mismatch report: reviewed/unreviewed.
- Staging dry-run, migration apply and post-migration diagnostics.
- Concurrency result and reversal status.
- Production state: remains unverified until separately reviewed via read-only checks; no production deployment is authorized by this runbook.

Stop without adapting or applying migration `0044` if the diagnostic reveals unknown reference semantics, duplicate uniqueness keys, cross-tenant links, missing parent uniqueness, or a conflicting RLS/grant design. Document the exact remediation and require review before staging apply.

CLI behavior references: [Supabase `db reset`](https://supabase.com/docs/reference/cli/supabase-db-reset), [Supabase `db push`](https://supabase.com/docs/reference/cli/supabase-db-remote), and [database testing with pgTAP](https://supabase.com/docs/guides/local-development/cli/testing-and-linting).

