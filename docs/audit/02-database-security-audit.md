# Database and tenant security audit

**Audit date:** 2026-11-18  
**Method:** static inspection of table definitions, policies, grants, helper functions, triggers, and RPCs. No two-tenant SQL test was executed because no disposable database was available. Findings below are source-level evidence; effective production privileges remain unverified.

## Findings

### S-01 — Migration promotes every existing account to platform administrator

- **Severity:** Critical
- **Affected:** [0015_grant_superadmin_and_tenant_management.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0015_grant_superadmin_and_tenant_management.sql:6)
- **Evidence:** The migration sets `profiles.is_platform_admin = true` for every profile whose ID exists in `auth.users` (lines 6–9). No later migration resets non-designated users.
- **Business impact:** If this migration ran while customer accounts existed, those accounts gained platform-wide access and can pass `is_platform_admin()` checks. That can expose or modify all tenants, plans, support, and platform settings.
- **Recommended correction:** Treat this as a production incident check. Review the effective production flag values and audit history. Replace broad bootstrap logic with a controlled, explicitly identified initial admin and a separately reviewed promotion process.
- **Verification:** Read-only query of `profiles` admin IDs joined to `auth.users`; compare to an approved allowlist and review audit/admin activity. Test an ordinary user cannot access platform routes or cross-tenant rows.

### S-02 — Organization settings are readable by any authenticated user

- **Severity:** High
- **Affected:** [0013_fix_member_select_policy.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0013_fix_member_select_policy.sql:15)
- **Evidence:** The `organization_settings` SELECT policy allows a row when `auth.role() = 'authenticated'` (line 24), in addition to membership/admin checks. Migration `0042` replaces the broad organization-table read policy but does not replace this settings policy.
- **Business impact:** Any signed-in tenant user can query other organizations' settings such as phone, email, address, invoice footer, and operational preferences.
- **Recommended correction:** Remove the blanket authenticated condition and require active organization membership or platform-admin authorization. Confirm the corrected policy is applied in staging and production before treating tenant isolation as established.
- **Verification:** With authenticated users from two organizations, query settings without a client organization filter and assert each can see only its own row; check the catalog policy expression.

### S-03 — Tenant relationships are not protected by organization-aware foreign keys

- **Severity:** Critical
- **Affected:** `0004_inventory_and_costing.sql`, `0005_purchasing_and_payables.sql`, `0006_sales_and_receivables.sql`, `0036_branches_and_stock_transfers.sql`; relationships among products, sales, purchases, customers, suppliers, and stock
- **Evidence:** The tenant tables have single-column foreign keys (for example, `purchase_items.product_id -> products.id`, `sales.customer_id -> customers.id`, and `sale_items.product_id -> products.id`) and a separate `organization_id`; the migration chain contains no composite foreign key tying those references to the same organization. In `receive_purchase`, lines 160–163 join by product ID only and lines 182–186 update the referenced product by ID without an organization predicate. `confirm_sale` similarly joins sale items to products by ID only.
- **Business impact:** A tenant with write access to its purchase/sale rows can construct a child row referencing another tenant's product/customer/supplier. A security-definer receipt can then update another tenant's product cost; mismatched customer/product references can contaminate balances and expose limited data through errors/reports.
- **Recommended correction:** Enforce tenant-consistent references using composite unique keys/FKs or strict server-side validation in every write path. Add validation for organization, branch, customer/supplier, sale/purchase, and product relationships before any privileged mutation.
- **Verification:** In disposable two-tenant SQL tests, attempt cross-tenant references in every transaction table and assert constraints/RPCs reject them without changing either tenant's records.

### S-04 — Customer payment RPC does not enforce allocation bounds or customer ownership

- **Severity:** Critical
- **Affected:** [0006_sales_and_receivables.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0006_sales_and_receivables.sql:428)
- **Evidence:** The RPC checks membership and positive payment amount (lines 453–459), inserts the payment with caller-supplied `customer_id` (463–473), locks each sale (482), and increments `paid_amount` by the supplied allocation (490–497). It does not verify that the customer belongs to the organization, that each invoice belongs to that customer, that allocation totals stay within payment amount, or that allocation stays within invoice outstanding. The table checks only `allocated_amount >= 0`, not `allocated_amount <= amount`.
- **Business impact:** A privileged RPC can attach a payment to another tenant's customer, allocate one customer's money to another customer's invoice, overpay invoices, or create a payment whose allocated amount exceeds its amount. Customer balances and collections become unreliable.
- **Recommended correction:** Validate same-tenant customer/invoice ownership, cap total allocations at payment amount and current invoice outstanding while holding row locks, make retries return the original result, and add database constraints where compatible with legitimate advances.
- **Verification:** Test zero, negative, excessive, cross-customer, cross-tenant, duplicate, and concurrent allocation attempts; verify rejected calls leave payments, allocations, and balances unchanged.

### S-05 — Cron/security-definer entry points lack explicit client execution revocation

- **Severity:** Critical pending effective-grant verification
- **Affected:** [0010_automation_cron_jobs.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0010_automation_cron_jobs.sql:33), [0018_complete_automation_layers.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0018_complete_automation_layers.sql:9), [0023_marketing_jobs.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0023_marketing_jobs.sql:6)
- **Evidence:** Global `SECURITY DEFINER` jobs expire subscriptions, queue organization-wide sales/low-stock/reminder notifications, or update social-account status. These definitions have no caller authorization guard and these files do not revoke execution from `PUBLIC`, `anon`, or `authenticated`. PostgreSQL commonly grants new functions to `PUBLIC` by default; effective production grants could not be queried. `cron_run_all_automations` has a platform-admin guard, but its child functions do not.
- **Business impact:** If default execution remains, an unauthenticated or ordinary user may trigger global subscription state changes, inspect aggregate execution results, or spam customer/owner notification queues across tenants.
- **Recommended correction:** Revoke client execution on every scheduled job and grant only to the intended database scheduler/service role. Keep a separate guarded admin RPC only if operators need manual invocation.
- **Verification:** Query `has_function_privilege` for `anon`, `authenticated`, and `service_role` for every cron function; attempt calls as anon and ordinary tenant users in staging.

### S-06 — Backup restore can upsert posted business ledgers

- **Severity:** High
- **Affected:** [0039_tenant_backup_restore.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0039_tenant_backup_restore.sql:31)
- **Evidence:** Restore is a `SECURITY DEFINER` owner/admin RPC. It validates several references, then dynamically inserts every supplied row and executes `ON CONFLICT (id) DO UPDATE` for tables including sales, payments, allocations, supplier payments, stock adjustments, stock transfers, and stock movements (lines 133–149).
- **Business impact:** A same-organization backup payload can rewrite or create posted transaction/ledger rows through a privileged merge path. This can alter historical balances/stock without the normal correction or reversal workflows.
- **Recommended correction:** Do not update immutable posted rows during restore. Define restore semantics by table, validate all row contents and balances, preserve original transaction IDs/history, and route business corrections through auditable compensating entries.
- **Verification:** In a disposable database, restore a modified backup over existing posted records and verify either rejection or append-only compensating behavior, with a complete audit trail.

### S-07 — The final role policy migration is not runtime verified

- **Severity:** High
- **Affected:** [0042_tenant_security_baseline.sql](/Users/waiyanphyo/Desktop/BlueDragonVN/lwal-kuu/supabase/migrations/0042_tenant_security_baseline.sql)
- **Evidence:** The source adds restrictive role policies, trigger checks, ledger DML revocations, organization read policy replacement, and profile-column grants. The corresponding `tenant_security.test.sql` was not run, and remote migration history was not available. The open `organization_settings` policy in S-02 is not corrected by this migration.
- **Business impact:** Source intent cannot prove applied production policies or prevent other broad policies from remaining permissive.
- **Recommended correction:** Reconcile effective production policies and privileges, correct all identified leaks, apply only to staging after backup, and run two-tenant tests before production review.
- **Verification:** Catalog dump for RLS flags/policies/grants plus two-user/two-organization tests. Include read, insert, update, delete, security-definer RPC, and profile-admin escalation cases.

## Positive controls observed

- All 60 statically identified tables have an RLS enable statement in source.
- `0042` explicitly revokes authenticated direct writes to posted inventory/financial ledgers and protects updates to `profiles.is_platform_admin` at the SQL privilege level.
- The inspected `SECURITY DEFINER` function definitions set a fixed `search_path`.
- The current `tenant_security.test.sql` uses the `authenticated` role and two organizations rather than using service-role access to simulate tenant users; it remains unexecuted.
