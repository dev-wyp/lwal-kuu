# Repository and migration audit

**Audit date:** 2026-11-18  
**Method:** read-only source inspection plus the commands recorded in [05-test-coverage-report.md](05-test-coverage-report.md). No source or SQL was changed during this audit.  
**Scope:** repository state in this workspace; this report does not certify the live database.

## Verified observations

- The repository contains 42 consecutively numbered migrations, `0001` through `0042`.
- The snapshot `supabase/schema_unified.sql` matches the output reconstructed in memory from `scripts/generate-schema-unified.mjs` and all 42 migration files byte-for-byte.
- The generator sorts numbered files and concatenates them, but it does not verify sequence gaps, duplicate versions, or a database migration ledger.
- Static parsing found 60 `public` table definitions. Each has an `ENABLE ROW LEVEL SECURITY` statement in the migration source. Some tables intentionally have no client policy and therefore default-deny browser access.
- Static parsing found 131 `SECURITY DEFINER` function definitions. Every inspected definition has a fixed `search_path`; that source check does not verify effective database grants or runtime behavior.
- The live database history could not be read. `supabase migration list --remote` identified the linked production target as `wholesale-erp (lfajonwbfweflkymuvmx)` but stopped because no Supabase access token is configured. No migration was applied.
- The local Docker daemon is unavailable and PostgreSQL is not listening on the local test port. SQL migration replay and SQL integration tests were not run.

## Findings

### R-01 — TypeScript database contract is materially incomplete

- **Severity:** High
- **Affected:** [database.types.ts](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/src/types/database.types.ts), migrations `0001`–`0042`
- **Evidence:** The migration source defines 60 tables; `Database.public.Tables` describes 25. Missing types include `branches`, `stock_transfers`, `support_tickets`, `organization_role_permissions`, notification/marketing tables, and subscription audit/payment tables. The `MovementType` union omits `stock_transfer_in` and `stock_transfer_out`. `profiles.Update` permits changing `is_platform_admin`, while migration `0042` revokes that column update from authenticated users. The type for `expenses.category_id` is non-null while the SQL column is nullable.
- **Business impact:** TypeScript cannot reliably catch invalid queries, stale fields, or missing permission paths. It can also suggest updates that PostgreSQL rejects.
- **Recommended correction:** Generate TypeScript types from the verified staging schema and make generation repeatable. Do not treat the current hand-maintained file as authoritative.
- **Verification:** Compare generated table/column/function/view definitions with the migration chain and compile every Supabase query against the generated type.

### R-02 — Migration history and production compatibility are unverified

- **Severity:** Critical
- **Affected:** `supabase/migrations/0001`–`0042`; linked production project `lfajonwbfweflkymuvmx`
- **Evidence:** Remote migration listing failed with `AccessTokenRequiredError`. There is no evidence in this workspace that production has applied all 42 migrations or that the live schema matches the generated snapshot. Migrations `0001`–`0008` and `0014` contain source changes from their original migration versions; already-applied remote versions will not automatically rerun to receive those source edits.
- **Business impact:** A source-only review can miss production drift, a partially applied migration, or differences in policy/function definitions that affect customer data.
- **Recommended correction:** Obtain a read-only migration listing and catalog/schema comparison for the linked project; compare every applied version with the source. Do this from an authorized operator session and do not push migrations during the comparison.
- **Verification:** Export migration history and schema definitions from the target, compare them with the 42-file chain, and record discrepancies before staging deployment.

### R-03 — Repository documentation includes competing schema assumptions

- **Severity:** Medium
- **Affected:** `docs/master-erp-audit-and-plan.md`, `docs/phase-2-schema-audit-and-proposal.md`, `docs/phase-3-ar-schema-audit-and-plan.md`, `docs/architecture/03-database-migration-plan.md`, `supabase/README.md`
- **Evidence:** Older documents describe `org_id`, `memberships`, `warehouses`, and `create_sale` contracts that do not match the active `organization_id`, `organization_members`, `branches`, and `confirm_sale` migration chain. Some architecture notes describe planned rather than implemented workflows. `supabase/README.md` also describes the literal local `project_id` as though it were the remote project reference; the linked production ref is separately available as `lfajonwbfweflkymuvmx`.
- **Business impact:** Operators or developers may run a migration or query against the wrong schema, or believe a proposed workflow exists in production.
- **Recommended correction:** Label historical proposals as archived and update active deployment documentation using verified staging and production facts. Distinguish the local Supabase `project_id` from the linked remote project ref.
- **Verification:** Search active docs for old table/RPC names and confirm every deployment command names its target explicitly.

### R-04 — Migration source has repeated function overrides

- **Severity:** Medium
- **Affected:** `0011`–`0014`, `0018`–`0028`, `0033`–`0042`
- **Evidence:** Functions such as `create_organization_with_owner`, `organization_has_plan_feature`, `has_org_permission`, `capture_tenant_audit_log`, and marketing RPCs are replaced in later migrations. The generator preserves every historical definition in a concatenated snapshot, so the final behavior depends on successful sequential execution and the actual remote migration ledger.
- **Business impact:** A skipped or partially applied migration can leave a valid-looking database with an older, weaker function body.
- **Recommended correction:** Keep immutable migration history, document final definitions and replacement versions, and run clean replay plus upgrade-from-current-staging tests.
- **Verification:** On disposable PostgreSQL/Supabase, apply the full chain from empty and upgrade a staging clone; compare `pg_get_functiondef`, policies, and grants after each path.

### R-05 — Local project configuration and remote linkage need clearer naming

- **Severity:** Low
- **Affected:** [config.toml](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/config.toml:1), `supabase/.temp/project-ref`
- **Evidence:** `config.toml` names the local project `myanmar-wholesale-erp`; the existing link file points to production project ref `lfajonwbfweflkymuvmx` / project `wholesale-erp`. The CLI confirmed that production link when the read-only migration-list command was attempted.
- **Business impact:** The two identifiers can be confused in operator instructions, although the local project name alone does not prove that the wrong remote project is linked.
- **Recommended correction:** Put the expected remote project name/ref in the release checklist and require operators to confirm the CLI target before any hosted command.
- **Verification:** Run a read-only target-info command in the approved operator environment and compare the ref to the release ticket.

### R-06 — Referential-index coverage needs staging query-plan review

- **Severity:** Medium
- **Affected:** `payment_allocations`, `supplier_payments`, and other tables with foreign-key columns
- **Evidence:** `payment_allocations` has indexes on `sale_id` and `(document_type, document_id)` but no declared index on `payment_id`; `supplier_payments` has an `(organization_id, supplier_id)` index but no declared `purchase_id` index. PostgreSQL does not automatically create indexes on referencing columns. Other indexes appear on several core query paths, but query plans were not available.
- **Business impact:** Parent-row cleanup, payment history joins, and invoice-level lookups may slow as transaction volume grows.
- **Recommended correction:** Capture actual staging query plans and add indexes only where query patterns/FK maintenance need them. Avoid speculative indexes without a plan and workload.
- **Verification:** Use representative tenant-sized fixtures with `EXPLAIN (ANALYZE, BUFFERS)` and validate write overhead plus query latency.

### R-07 — Active-owner lifecycle is not established

- **Severity:** Medium
- **Affected:** `organization_members`, onboarding RPC, Settings member-invitation UI
- **Evidence:** Membership rows permit owner/admin/manager/staff and enforce one row per user/organization, but do not enforce a single active owner or a transfer/last-owner invariant. The settings invitation handler currently displays a success message without creating an invitation or membership record.
- **Business impact:** Shops may be unable to add staff or safely transfer account ownership; future membership changes could strand a tenant without an authorized owner.
- **Recommended correction:** Define whether multiple owners are supported, implement server-authorized invitation/role/ownership transfer operations, and prevent removal/demotion of the last active owner.
- **Verification:** Test owner transfer, last-owner protection, invite acceptance, deactivation, and organization deletion/retention behavior in staging.

## Overall repository conclusion

The generated SQL snapshot is synchronized with source, but the repository is not a verified database contract until production history/schema are compared and staging replay succeeds. The TypeScript DB types are incomplete and must not be used as a full schema inventory.
