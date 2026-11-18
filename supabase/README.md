# Supabase database contract and operations

## Source of truth

The numbered files in `supabase/migrations/` are the repository's only editable database contract. Apply them in numeric order. `supabase/schema_unified.sql` is a generated snapshot; regenerate it with `node scripts/generate-schema-unified.mjs` and do not edit it directly.

The current checked-in chain uses `organization_id`, `organization_members`, and tenant-scoped tables defined by migrations `0001` through `0042`. The older files in `supabase/legacy-tests/` and older planning documents target a different `org_id`/`memberships`/`warehouses` contract; they are retained for reference and are not active tests or migrations.

This describes the repository contract only. It does not prove the schema currently deployed to Supabase. The local `project_id` and the production project ref previously reported in the CLI output differ. Verify the intended project and compare migration history before deployment; do not push this chain to production based on this document alone.

## Tenant security checks

`tests/tenant_security.test.sql` checks two-organization read isolation, membership checks, staff role permissions, cross-tenant writes, protected ledger grants, and platform-admin profile protection. Run it only against a disposable database after applying the complete migration chain.

The test suite has not been executed in this workspace: PostgreSQL is not listening locally and Docker is unavailable. Passing source review is not a substitute for an RLS integration run. Before production use, restore a verified backup, deploy to a staging project, run the RLS and financial workflow suites, inspect migration history, then obtain a reviewed deployment decision.

## Local workflow

1. Confirm Docker is available with `docker info` and use the Supabase CLI for this repository.
2. Start a disposable local stack with `supabase start`.
3. Apply migrations only to that disposable stack with `supabase db reset` (this resets local data).
4. Run database assertions with `supabase test db` and review the output.
5. Generate schema snapshots and types only from the database state you intend to use.
6. For hosted environments, create and verify a backup, apply to staging first, run tenant isolation and purchase-to-payment reconciliation checks, and compare `supabase migration list --remote` with the checked-in chain before considering production.

There are no automatic down migrations for populated business tables. Any rollback for a persistent database must preserve financial and inventory history.
