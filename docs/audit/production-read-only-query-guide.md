# Production read-only security query guide

**Target:** Supabase project `wholesale-erp` (`lfajonwbfweflkymuvmx`)  
**Prepared:** 2026-11-19  
**Status:** Query pack only. No production SQL was executed and no live finding is confirmed.

## Before running

1. Open Supabase SQL Editor for the approved production project and verify the project ref in the Dashboard is `lfajonwbfweflkymuvmx`. PostgreSQL itself does not expose that ref through the provided query.
2. Use an authorized database operator session with read access to the relevant catalogs and tables. Do not use or paste a service-role key, database password, or access token into the query pack or report files.
3. Run statements individually and capture the timestamp, project ref, database role, and unmodified result. Keep profile email results in an approved restricted location.
4. Do not execute a statement if its prerequisite table/catalog is missing or inaccessible. Record it as **BLOCKED** and include the exact permission/schema error without secrets.
5. Do not add `SET`, `DO`, write statements, grant/revoke statements, or migration commands. Every query in the companion `.sql` file is intended to be a `SELECT` only.

The SQL pack is in [production-read-only-security-queries.sql](production-read-only-security-queries.sql). Results should be recorded in [production-security-results-template.md](production-security-results-template.md).

## Query map

| Section | Purpose | Tables/catalogs | Safe result | Unsafe result / limits |
| --- | --- | --- | --- | --- |
| 0 | Confirm current DB and SQL role context | `current_database`, `current_user`, `session_user`, setting | Approved production context; expected operator role | Wrong context or unexpectedly privileged role. Project ref must be confirmed in Dashboard. |
| 1 | List platform admins, auth emails/account creation times, and count | `public.profiles`, `auth.users` | IDs match an independently approved admin allowlist and count equals listed rows | An unrecognized ID is a potential security incident. `auth.users` access may be denied. No allowlist is supplied in this pack. Do not change accounts. |
| 2a | RLS enabled/forced flags and table owner | `pg_class`, `pg_namespace`, `pg_roles` | RLS enabled and bypass/owner behavior is understood | Disabled RLS or assuming FORCE applies to superuser/BYPASSRLS. |
| 2b–c | All policies and permissive SELECT/ALL policies | `pg_policies` | Every policy has understood, tenant-scoped conditions | A permissive broad condition can expose rows because permissive policies OR together. Review helper bodies and all policies, not just the focused list. |
| 2d | Effective table grants for common Supabase roles | `has_table_privilege` | Grants are intentional and reviewed with RLS | Unexpected grant expands access paths. Grants do not alone establish row visibility; table ownership, bypass roles, policies, and definer functions matter. |
| 3a | Function signatures, SECURITY DEFINER, owner, direct PUBLIC and effective role EXECUTE | `pg_proc`, `pg_namespace`, `pg_roles`, `aclexplode`, `acldefault`, `has_function_privilege` | Global mutating functions are limited to intended scheduler/service/admin paths | Client EXECUTE on unguarded global workers; unknown owner; function missing. Source review cannot prove effective production ACLs. |
| 3b | Direct EXECUTE ACL entries | Function catalogs and ACL functions | Direct grants align with intended paths | PUBLIC/anon/authenticated grants on unguarded jobs. Compare with effective inherited-role results in 3a. |
| 3c | Scheduled job commands and job owner | `cron.job` | Known jobs and approved owners | Unknown command/owner or unexpected active job. `cron.job` can be absent/hidden; external schedulers are not covered. |
| 4a | Expected FK definitions and composite organization-key coverage | `pg_constraint`, `pg_class`, `pg_attribute` | Tenant-owned relationships have validated composite keys or a documented equivalent control | ID-only FK, missing FK, or unvalidated FK. This is based on source-reviewed relationship names and must be checked against production schema. |
| 4b | All FKs on core tenant business tables | PostgreSQL catalogs | Every relationship has been reviewed | The inventory does not prove referenced rows have matching tenant IDs. |
| 4A | Purchase, supplier, product, and branch ownership mismatch counts | `purchases`, `purchase_items`, `suppliers`, `branches`, `products`, `supplier_payments` | All counts zero | Any positive count is a cross-tenant reference or supplier mismatch requiring investigation. Aggregate output only. |
| 4B | Sales, customers, payment allocations and invoice ownership | `sales`, `sale_items`, `customers`, `branches`, `products`, `payments`, `payment_allocations` | All counts zero | Any positive count may invalidate customer balances or expose/mutate another tenant's data. Aggregate output only. |
| 4C | Stock, branch, and transfer ownership | `stock_adjustments`, `stock_movements`, `stock_transfers`, `stock_transfer_items`, `products`, `branches` | All counts zero | Any positive count can corrupt stock valuation or branch balances. Polymorphic stock references are checked separately in 4E. |
| 4D | Product/category/unit/expense category ownership | `products`, `product_categories`, `units`, `expenses`, `expense_categories` | All counts zero | Any positive count indicates cross-tenant classification links. |
| 4E | Polymorphic stock movement reference ownership | `stock_movements`, `sales`, `purchases`, `stock_adjustments`, `stock_transfers` | All mismatch and unknown-type counts zero | A nonzero mismatch or unknown type requires review. Labels are based on local source; adapt only after checking deployed enum/text conventions. |
| 4F | Existing supplier allocation table columns, constraints, indexes, and RLS | `information_schema.columns`, PostgreSQL catalogs, `pg_policies` | Returned shape is known and matches a migration plan; no rows are changed | Missing or unexpected columns/constraints require schema-specific migration design. Do not create a second allocation table or guess legacy mappings. |
| 5a | Whether Supabase migration history is visible | `information_schema.tables` | History table is present and accessible | Missing/inaccessible table blocks this method; it does not prove no migrations ran. |
| 5b | Read remote migration versions and names | `supabase_migrations.schema_migrations` | Remote versions are manually reconciled with local `0001`–`0044` files | Missing, unexpected, or duplicate history needs investigation. Never repair history from this pack. Operator logs report 0043 applied and 0044 failed; verify remotely. |

## Interpretation notes

### Platform administrator allowlist

The list query includes profile ID, matching `auth.users.email`, account `created_at`, and profile `created_at`; the count is separate so it can be reconciled to the list. Compare IDs—not names/emails—to the approved allowlist maintained outside this pack. No allowlist was supplied with the query-pack request. If the account join is denied, record IDs/count and mark the associated-account detail blocked. Do not modify any account as part of this process.

### Organization settings

Review all rows from `pg_policies`, including `ALL`, role membership, policy command, `USING`, and `WITH CHECK`. PostgreSQL's permissive policies combine with OR. A single permissive broad SELECT policy may expose rows even if another policy is tenant-scoped. RLS flags are not a full effective-access proof: table owners, superusers, BYPASSRLS roles, inherited grants, security-definer functions, and views must also be considered. The pack inspects table grants and policy text but does not execute two-tenant behavioral tests.

### Cron functions

The inventory comes from the existing source review: `cron_check_expired_subscriptions()`, `cron_queue_daily_sales_summaries()`, `cron_queue_low_stock_alerts()`, `cron_queue_subscription_renewal_reminders()`, `cron_queue_weekly_business_summary()`, `cron_run_all_automations()`, `cron_detect_expired_social_connections()`, `cron_notify_upcoming_scheduled_posts()`, `cron_queue_debt_reminders()`, and worker functions `claim_due_publishing_jobs(integer,text)` and `complete_publishing_job(uuid,boolean,text,text,boolean)`.

The query uses `aclexplode` to display the PUBLIC ACL entry and `has_function_privilege` for `anon`, `authenticated`, and `service_role`, accounting for inherited privileges. `pg_cron` records a database username for jobs; this may not be `service_role`. Match actual scheduled commands and owners. A function can also be invoked by Supabase Edge Functions or another external scheduler, so absence from `cron.job` is not proof of non-use. Function privileges do not establish whether its body has a safe authorization guard.

### Cross-tenant foreign keys and mismatch counts

The FK inventory checks source-identified business relationships, including product category/unit, purchase/supplier/branch/item/product, supplier payments, sales/customer/branch/line/product, payment/customer/allocation/sale, adjustments/movements/transfers/branches/products, expenses/categories, and transfer items. The aggregate mismatch sections should be run only after confirming that the required tables and columns exist in production. If a statement errors because the production schema differs, mark that section blocked and document the exact missing object; do not silently alter assumptions or skip affected relationships.

Mismatch count `0` means only that the particular join found no current mismatch. It does not prove the FK is composite, prevent future bad writes, or verify transaction RPC authorization. Zero counts must be paired with FK and RPC review. The stock movement reference query assumes source labels `sale`, `purchase`, `stock_adjustment`, and `stock_transfer`; include any other deployed labels in an operator-reviewed adaptation and record the change.

### Migration history

The initial audit found 42 migration files, numbered `0001` through `0042`. Operator-provided `db push` logs report migration `0043_p0_transaction_integrity.sql` applied and `0044_supplier_payment_workflow.sql` failing; remote history has not been independently inspected. Query 5 reads the remote version/name history only; compare its ordered versions manually with the current local filenames `0001` through `0044` and inspect content/checksums using the project's approved process. SQL Editor cannot read local files, and a migration history row does not prove that the resulting schema state remains unchanged. If the history table is not visible, the remote history comparison remains blocked until an authorized operator supplies another read-only method.

## Verification limits

This pack does not test writes, simulate two tenants, inspect every function body, inspect secrets, verify backup restoration, or prove that every policy/grant path has been captured. It is an evidence collection step. Do not mark production secure or a finding fixed solely because a query returned no rows or zero counts; use the results template to state the evidence and limitations.

