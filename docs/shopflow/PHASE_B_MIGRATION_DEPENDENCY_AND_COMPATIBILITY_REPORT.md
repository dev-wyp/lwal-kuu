# Phase B Migration Dependency and Compatibility Report

**Review date:** 2026-11-20  
**Scope:** Local source review of migrations `0043`–`0047` and related supplier/customer payment contracts. No database was queried, reset, or migrated for this report.  
**Production decision:** Do not deploy. Production remains **UNVERIFIED**; migration `0044` remains **BLOCKED** on actual schema evidence.

`supabase/schema_unified.sql` was regenerated with the repository's established command, `node scripts/generate-schema-unified.mjs`; the generator reports 47 numbered migrations. It is a source concatenation/snapshot only and does not represent or verify the effective remote schema.

## Evidence boundary

Operator-provided CLI output previously reported that `0043` applied and `0044` failed because an existing `public.supplier_payment_allocations` relation lacked columns expected by the local migration. Later output reported missing `supplier_payment_id`. These are reported logs, not independently verified remote history or catalog results. No table mapping is inferred from them.

The current local migration `0044` has a preflight check for required columns/types and additional required columns without defaults. If the existing table is incompatible, the transaction raises before its schema-changing statements. The guard is useful fail-fast behavior, but it is not a compatibility adapter, and it cannot prove that matching names have the intended semantics.

## Dependency map

| Migration | Local contract / key dependencies | Downstream dependency and status |
| --- | --- | --- |
| `0043_p0_transaction_integrity.sql` | Core tables and RPCs from `0001`–`0007`; permission/entitlement helpers from `0019`–`0020`, `0027`, `0040`–`0042`; tenant parent tables and relation columns. Adds organization-scoped idempotency indexes, parent `(organization_id,id)` indexes, composite FKs, and replaces sale, customer-payment, and receiving RPCs. | Required by `0044` parent keys and hardened transaction call paths. Local-source dependency only; remote migration history/effective result are unverified. |
| `0044_supplier_payment_workflow.sql` | `supplier_payments` / `purchases` from `0005`; `suppliers`, `purchase_items`, `audit_logs`, membership/permission/plan helpers, and document numbering. Expects allocation columns `id uuid`, `organization_id uuid`, `supplier_payment_id uuid`, `purchase_id uuid`, `amount numeric`; expects parent unique `(organization_id,id)` keys. | Blocks `0045` supplier balance/read gate and `0047` is unrelated to this table. Existing relation's actual schema, indexes, constraints, policies, data, and migration history have not been supplied. Do not adapt or retry based on column-name guesses. |
| `0045_plan_gated_customer_and_supplier_ledgers.sql` | Customer/supplier summary views and source ledgers; report views from `0009`/`0032`; branch views/tables from `0036`; entitlement helper from `0019`/`0020`/`0027`; permission helpers from `0040`–`0042`. Supplier ledger read gate presumes `supplier_payments` and the intended allocation workflow. | Depends on a coherent prior schema including the 0044 supplier relation contract. Local SQL assertions exist but were not executed. |
| `0046_consistent_plan_limit_fallback.sql` | Plans, subscriptions, feature definitions/overrides, normalized limit rows and legacy plan limit columns established in `0008`, `0019`–`0020`, `0027`–`0028`. Replaces `get_organization_feature_limit`. | Independent of allocation table structure in local source; still part of the pending migration chain and untested against PostgreSQL. |
| `0047_customer_payment_idempotency_fingerprint.sql` | Customer `payments`, `payment_allocations`, sales/customer fields from `0003`/`0006`; hardened payment RPC from `0043`; permission helper from `0042`. Adds fingerprint and replaces customer-payment RPC. | Independent of supplier allocations, but full-chain replay is blocked until 0044 can be safely resolved. SQL assertions were not executed. |

The dependency table describes checked-in SQL references, not an assertion that a hosted database has applied these versions in this order.

## Compatibility findings

1. Migrations `0001`–`0043` do not define `supplier_payment_allocations` in the checked-in migration source. Local `0044` is the first checked-in definition. A relation that predates or differs from that migration is outside the tracked schema contract.
2. `CREATE TABLE IF NOT EXISTS` will not reconcile an existing relation. Subsequent index, foreign-key, policy, grant, and RPC statements need the expected columns and relationships.
3. The current preflight only checks required column presence/types and extra required columns without defaults. It does not validate the meaning of legacy references, the parent uniqueness prerequisite, current grants/triggers, or historical row integrity.
4. The diagnostic script now includes column/type, PK/FK/unique/check, index, parent-key, policy, effective table and owned-sequence grants, non-internal trigger metadata, RPC definitions/ACLs, and aggregate compatibility counts. It remains unexecuted.
5. Aggregate compatibility requires verified semantics for the candidate reference/tenant/amount columns. Alias matching is a convenience for candidate inspection, not an approved data mapping.
6. No safe additive production-specific migration can be proposed until the actual schema and aggregate results are provided. No corrected migration is included in this phase.

## Required operator evidence

Complete `MIGRATION_0044_DIAGNOSTIC_RESULTS_TEMPLATE.md` with sanitized output from an approved isolated test/staging target. It must include:

- Exact allocation column names, PostgreSQL types, nullability and defaults.
- PK, unique, FK, check, exclusion constraints; referenced schemas/tables/columns; validation status.
- All index definitions and validity/readiness, including parent `(organization_id,id)` uniqueness on both parent tables.
- RLS enabled/forced state, every policy and effective table privileges.
- Owned sequences and effective USAGE/SELECT/UPDATE grants; triggers and trigger function owner/security settings.
- Supplier payment RPC definitions, owner, `SECURITY DEFINER`, search-path settings and effective execute grants.
- Aggregate null, invalid amount, orphan, cross-tenant, cross-supplier, duplicate, payment-overallocation, and purchase-overallocation counts.
- Target provenance and migration history for versions `0043`–`0047` where available.

Do not send customer/supplier PII, payment references, credentials, tokens, or raw row IDs. If the database or role cannot read one of these catalogs, record the exact query/permission limitation rather than substituting assumptions.

## Verification status

| Verification | Status | Evidence |
| --- | --- | --- |
| Local migration source review `0043`–`0047` | REVIEWED | Current checked-in files; see dependency map. |
| Read-only diagnostic completeness review | UPDATED, NOT EXECUTED | `docs/audit/supplier-payment-allocation-read-only-diagnostic.sql` |
| Lint / build / unit | PASS | `npm run lint`, `npm run build`, and `npm run test:unit` completed locally on 2026-11-20. |
| Whitespace check | PASS | `git diff --check` completed after the final document/diagnostic changes. |
| Actual allocation table schema / data | BLOCKED | No diagnostic result supplied; production expressly prohibited as test target. |
| Migration `0044` corrected for legacy schema | NOT PROPOSED | Requires verified mapping and reviewed counts. |
| Local clean migration replay | NOT RUN | Supabase local Docker runtime unavailable in this workspace; prior native PostgreSQL attempt was denied shared memory (`shmget`). |
| P0, tenant, and plan SQL suites | NOT RUN | No disposable database target available; no production fallback used. |
| Staging migration/test | NOT RUN | No approved isolated staging target was provided. |
| Production migration history/effective schema | UNVERIFIED | No production access or queries performed for this task. |

After the user authorized Supabase DB use, a read-only identity query was attempted with explicit target `lfajonwbfweflkymuvmx`. The CLI resolved it to project `wholesale-erp` / production, then stopped before connecting because no Supabase access token was configured (`DbQueryLoginRequiredError`). No database SQL ran. The earlier task restrictions still prohibit a production connection; obtain an isolated staging target for compatibility investigation, or have an authorized operator provide sanitized historical diagnostic output under their own approved process.

## Decision

Keep `0044` blocked. Preserve the current migration's fail-fast guard. Do not add compatibility columns, rename fields, backfill ownership, create a second allocation relation, or modify the migration until evidence establishes the legacy contract and all old rows are accounted for. After review, prepare a new additive migration proposal and verify it against a disposable local database and dedicated staging before any production change request.

