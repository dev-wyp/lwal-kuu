-- ShopFlow production read-only security verification pack
-- Target to confirm manually before running: wholesale-erp / lfajonwbfweflkymuvmx
-- Execute one section at a time in Supabase SQL Editor using an authorized read-only
-- operator session. This file contains SELECT statements only. It has not been run.
-- Do not paste credentials or service-role keys into query text or result files.

-- ============================================================================
-- 0. Target context (operator confirms the SQL Editor project before execution)
-- Purpose: show current database and role context; it does not independently prove
-- the Supabase project ref, which must be checked in the Dashboard.
-- Catalogs: current_database(), current_user, session_user.
-- Safe: expected database/role are the approved production context and a read-only
-- operator role. Unsafe: wrong project/database or unexpectedly privileged session.
-- Limits: Supabase project ref is not exposed by PostgreSQL catalogs.
select current_database() as database_name,
       current_user as current_role,
       session_user as session_role,
       current_setting('transaction_read_only') as transaction_read_only;


-- ============================================================================
-- 1. Platform administrator accounts
-- Purpose: list admin profile IDs, associated auth email/account creation date,
-- profile creation date if present, plus a separate total count.
-- Tables: public.profiles, auth.users.
-- Safe: only IDs on the separately approved allowlist appear; count agrees.
-- Unsafe: any unrecognized admin ID is a potential security incident. Do not
-- modify accounts from this investigation.
-- Limits: auth.users may be inaccessible to the SQL Editor role. Email is personal
-- information; retain results only in an approved restricted location. No allowlist
-- is embedded in this pack.
select p.id as profile_user_id,
       u.email,
       u.created_at as account_created_at,
       p.created_at as profile_created_at
from public.profiles as p
left join auth.users as u on u.id = p.id
where p.is_platform_admin is true
order by p.id;

-- Purpose: total enabled platform-admin profiles.
-- Tables: public.profiles.
-- Safe: count equals the number of rows in the preceding list and each is allowlisted.
-- Unsafe: a nonzero count without an approved, independently maintained allowlist
-- cannot be declared safe.
-- Limits: a count does not identify which accounts are authorized.
select count(*) as platform_admin_count
from public.profiles
where is_platform_admin is true;


-- ============================================================================
-- 2. organization_settings: RLS, policies, permissive reads, and table grants
-- Purpose: inspect table RLS flags and owner.
-- Catalogs: pg_class, pg_namespace, pg_roles.
-- Safe: RLS enabled; forced status reviewed in context of table owner and privileged
-- access paths. Unsafe: RLS disabled, or assumptions that FORCE protects owners,
-- superusers, or BYPASSRLS roles.
-- Limits: catalog visibility depends on operator privileges.
select n.nspname as schema_name,
       c.relname as table_name,
       pg_get_userbyid(c.relowner) as table_owner,
       c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced
from pg_class as c
join pg_namespace as n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'organization_settings';

-- Purpose: inspect every effective policy definition recorded for the table.
-- Catalog: pg_policies.
-- Safe: every SELECT/ALL policy is limited to authorized organization members and
-- intended platform administrators; roles and USING expressions are understood.
-- Unsafe: any broad authenticated condition, unqualified TRUE, or unexpected policy.
-- Limits: permissive policies combine with OR; restrictive policies combine with
-- AND against permissive policies. Review all rows and role inheritance together.
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'organization_settings'
order by cmd, policyname;

-- Purpose: isolate permissive SELECT and ALL policies for focused review.
-- Catalog: pg_policies.
-- Safe: no permissive condition admits arbitrary authenticated users across tenants.
-- Unsafe: any broad policy can make another permissive policy ineffective as a limit.
-- Limits: textual heuristic is not an authorization proof; inspect the full policy
-- list above, helper-function definitions, grants, and actual role behavior.
select policyname, roles, cmd, qual
from pg_policies
where schemaname = 'public'
  and tablename = 'organization_settings'
  and permissive = 'PERMISSIVE'
  and cmd in ('SELECT', 'ALL')
order by policyname;

-- Purpose: report effective table privileges for common Supabase roles.
-- Catalog/function: pg_class via has_table_privilege.
-- Safe: table privileges align with intended authenticated access, with RLS providing
-- row filtering; anon has no unnecessary access.
-- Unsafe: an unexpected grant can broaden access; grants alone do not bypass RLS,
-- but owners, BYPASSRLS roles, security-definer functions, and policies matter.
-- Limits: role existence/permission to inspect may differ. This evaluates privileges
-- for the named role, not every inherited/custom role.
with target_roles(role_name) as (
  values ('anon'), ('authenticated'), ('service_role')
)
select role_name,
       has_table_privilege(role_name, 'public.organization_settings', 'SELECT') as can_select,
       has_table_privilege(role_name, 'public.organization_settings', 'INSERT') as can_insert,
       has_table_privilege(role_name, 'public.organization_settings', 'UPDATE') as can_update,
       has_table_privilege(role_name, 'public.organization_settings', 'DELETE') as can_delete,
       has_table_privilege(role_name, 'public.organization_settings', 'TRUNCATE') as can_truncate,
       has_table_privilege(role_name, 'public.organization_settings', 'REFERENCES') as can_reference,
       has_table_privilege(role_name, 'public.organization_settings', 'TRIGGER') as can_trigger
from target_roles
order by role_name;


-- ============================================================================
-- 3. Global scheduled SECURITY DEFINER function privileges
-- Purpose: list source-identified cron/worker RPCs, identity signatures, definer
-- status, owner, direct ACL grants including PUBLIC, effective EXECUTE for common
-- Supabase roles, and matching pg_cron jobs/owners where available.
-- Catalogs/functions: pg_proc, pg_namespace, pg_roles, aclexplode, acldefault,
-- has_function_privilege; cron.job when installed and visible.
-- Safe: global mutating SECURITY DEFINER jobs cannot be invoked by unauthorized
-- client roles; only approved scheduler/service/admin paths are executable.
-- Unsafe: PUBLIC/anon/authenticated EXECUTE on an unguarded global worker; any
-- unexpected owner/job owner; unknown or unmatched scheduled command.
-- Limits: PUBLIC ACL is reported from the function ACL (including PostgreSQL
-- default grants). pg_cron may be absent or hidden. Matching job command text is
-- heuristic; inspect each command manually. This does not test function body guards.
with expected(schema_name, function_name) as (
  values
    ('public','cron_check_expired_subscriptions'),
    ('public','cron_queue_daily_sales_summaries'),
    ('public','cron_queue_low_stock_alerts'),
    ('public','cron_queue_subscription_renewal_reminders'),
    ('public','cron_queue_weekly_business_summary'),
    ('public','cron_run_all_automations'),
    ('public','cron_detect_expired_social_connections'),
    ('public','cron_notify_upcoming_scheduled_posts'),
    ('public','cron_queue_debt_reminders'),
    ('public','claim_due_publishing_jobs'),
    ('public','complete_publishing_job')
), funcs as (
  select e.schema_name as expected_schema,
         e.function_name as expected_function,
         p.oid, n.nspname, p.proname, p.proowner, p.proacl, p.prosecdef,
         pg_get_function_identity_arguments(p.oid) as identity_arguments,
         pg_get_function_identity_arguments(p.oid) as identity_signature_args
  from expected e
  left join pg_namespace n on n.nspname = e.schema_name
  left join pg_proc p on p.pronamespace = n.oid and p.proname = e.function_name
)
select f.expected_schema as function_schema,
       f.expected_function as function_name,
       f.identity_arguments as signature_arguments,
       f.prosecdef as security_definer,
       case when f.oid is not null then pg_get_userbyid(f.proowner) end as function_owner,
       coalesce((select bool_or(x.grantee = 0 and x.privilege_type = 'EXECUTE')
                 from aclexplode(coalesce(f.proacl, acldefault('f', f.proowner))) x), false)
         as public_has_execute,
       case when f.oid is not null then has_function_privilege('anon', f.oid, 'EXECUTE') end as anon_effective_execute,
       case when f.oid is not null then has_function_privilege('authenticated', f.oid, 'EXECUTE') end as authenticated_effective_execute,
       case when f.oid is not null then has_function_privilege('service_role', f.oid, 'EXECUTE') end as service_role_effective_execute,
       case when f.oid is null then 'FUNCTION NOT FOUND' else 'FOUND' end as catalog_status
from funcs f
order by f.expected_function, f.identity_arguments;

-- Purpose: show direct function ACL entries for the same inventory, including role
-- names and grant options. Use alongside effective-role results above.
-- Catalogs: pg_proc, pg_namespace, pg_roles, aclexplode, acldefault.
-- Safe: direct grants are intentional and consistent with the approved execution path.
-- Unsafe: PUBLIC/anon/authenticated can execute a global worker without a guard.
-- Limits: absence of an explicit ACL uses PostgreSQL defaults; effective inherited
-- rights are shown in the previous query. Missing functions return no ACL rows.
with expected(function_name) as (
  values ('cron_check_expired_subscriptions'),('cron_queue_daily_sales_summaries'),
    ('cron_queue_low_stock_alerts'),('cron_queue_subscription_renewal_reminders'),
    ('cron_queue_weekly_business_summary'),('cron_run_all_automations'),
    ('cron_detect_expired_social_connections'),('cron_notify_upcoming_scheduled_posts'),
    ('cron_queue_debt_reminders'),('claim_due_publishing_jobs'),('complete_publishing_job')
)
select n.nspname as function_schema, p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as signature_arguments,
       case when a.grantee = 0 then 'PUBLIC' else coalesce(r.rolname, a.grantee::text) end as grantee,
       a.privilege_type, a.is_grantable
from expected e
join pg_namespace n on n.nspname = 'public'
join pg_proc p on p.pronamespace = n.oid and p.proname = e.function_name
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
left join pg_roles r on r.oid = a.grantee
where a.privilege_type = 'EXECUTE'
order by p.proname, signature_arguments, grantee;

-- Purpose: check whether the pg_cron job catalog is visible before querying it.
-- Catalog: information_schema.tables.
-- Safe: table is visible, so inspect its actual columns/permissions before the next query.
-- Limits: no row can mean pg_cron is absent or the current role cannot see it.
select table_schema, table_name
from information_schema.tables
where table_schema = 'cron' and table_name = 'job';

-- Run the following query only if cron.job exists and its listed columns are visible.
-- Purpose: inspect cron jobs and the database role recorded as each job owner.
-- Catalog: cron.job.
-- Safe: scheduled global jobs have known commands and approved owners.
-- Unsafe: unknown command, owner, or active duplicate; a job owner with excessive
-- privileges can increase impact.
-- Limits: run only if cron.job exists and is visible. The project may use an external
-- scheduler; no rows does not prove no scheduled invocation exists.
select j.jobid, j.jobname, j.schedule, j.command, j.username as job_owner,
       j.active, j.database
from cron.job as j
where j.command ilike '%cron_check_expired_subscriptions%'
   or j.command ilike '%cron_queue_daily_sales_summaries%'
   or j.command ilike '%cron_queue_low_stock_alerts%'
   or j.command ilike '%cron_queue_subscription_renewal_reminders%'
   or j.command ilike '%cron_queue_weekly_business_summary%'
   or j.command ilike '%cron_run_all_automations%'
   or j.command ilike '%cron_detect_expired_social_connections%'
   or j.command ilike '%cron_notify_upcoming_scheduled_posts%'
   or j.command ilike '%cron_queue_debt_reminders%'
order by j.jobid;


-- ============================================================================
-- 4. Foreign-key catalog inventory and composite-tenant-key coverage
-- Purpose: list tenant business FK definitions and whether the FK includes both
-- child organization_id and referenced parent organization_id paired with the
-- referenced business key. This inventory is driven by known relationships from
-- cross-tenant-reference-review.md.
-- Catalogs: pg_constraint, pg_class, pg_namespace, pg_attribute.
-- Safe: validated tenant-bound composite FKs exist for each applicable relationship,
-- or documented equivalent trigger/RPC checks cover the relationship.
-- Unsafe: only an ID FK exists for a tenant-owned relationship, or FK is unvalidated.
-- Limits: polymorphic stock_movements.reference_type/reference_id cannot be a normal
-- FK. Review actual catalog output; the expected list is source-review scope, not a
-- claim that production schema matches it.
with expected(child_table, child_key, parent_table, parent_key) as (
  values
    ('products','category_id','product_categories','id'),
    ('products','unit_id','units','id'),
    ('product_categories','parent_id','product_categories','id'),
    ('expenses','category_id','expense_categories','id'),
    ('purchases','supplier_id','suppliers','id'),('purchases','branch_id','branches','id'),
    ('purchase_items','purchase_id','purchases','id'),('purchase_items','product_id','products','id'),
    ('supplier_payments','supplier_id','suppliers','id'),('supplier_payments','purchase_id','purchases','id'),
    ('sales','customer_id','customers','id'),('sales','branch_id','branches','id'),
    ('sale_items','sale_id','sales','id'),('sale_items','product_id','products','id'),
    ('payments','customer_id','customers','id'),
    ('payment_allocations','payment_id','payments','id'),('payment_allocations','sale_id','sales','id'),
    ('stock_adjustments','product_id','products','id'),('stock_adjustments','branch_id','branches','id'),
    ('stock_movements','product_id','products','id'),('stock_movements','branch_id','branches','id'),
    ('stock_transfers','source_branch_id','branches','id'),
    ('stock_transfers','destination_branch_id','branches','id'),
    ('stock_transfer_items','transfer_id','stock_transfers','id'),
    ('stock_transfer_items','product_id','products','id')
)
select e.child_table, e.child_key, e.parent_table, e.parent_key,
       c.conname as fk_name, c.convalidated,
       pg_get_constraintdef(c.oid, true) as fk_definition,
       case when c.oid is null then 'MISSING FK'
            when exists (
              select 1
              from unnest(c.conkey) with ordinality ck(attnum, ord)
              join unnest(c.confkey) with ordinality pk(attnum, ord) using (ord)
              join pg_attribute ca on ca.attrelid = c.conrelid and ca.attnum = ck.attnum
              join pg_attribute pa on pa.attrelid = c.confrelid and pa.attnum = pk.attnum
              where ca.attname = 'organization_id' and pa.attname = 'organization_id'
            ) then 'COMPOSITE TENANT FK PRESENT'
            else 'NO ORGANIZATION-ID PAIR IN FK' end as tenant_fk_status
from expected e
left join pg_class cc on cc.relnamespace = 'public'::regnamespace and cc.relname = e.child_table
left join pg_class pc on pc.relnamespace = 'public'::regnamespace and pc.relname = e.parent_table
left join pg_attribute cka on cka.attrelid = cc.oid and cka.attname = e.child_key and not cka.attisdropped
left join pg_attribute pka on pka.attrelid = pc.oid and pka.attname = e.parent_key and not pka.attisdropped
left join pg_constraint c on c.contype = 'f' and c.conrelid = cc.oid and c.confrelid = pc.oid
  and cka.attnum = any(c.conkey) and pka.attnum = any(c.confkey)
order by e.child_table, e.child_key, e.parent_table;

-- Purpose: show every FK on public tenant business tables, including definitions
-- outside the expected relationship list above.
-- Catalogs: pg_constraint, pg_class, pg_namespace.
-- Safe: all tenant references are understood, validated, and tenant-bound where needed.
-- Unsafe: unexplained single-column FK or unvalidated constraint on tenant data.
-- Limits: catalog inventory alone does not prove row ownership or RPC safety.
select cn.nspname as child_schema, ch.relname as child_table, c.conname as constraint_name,
       pn.nspname as parent_schema, pa.relname as parent_table,
       c.convalidated, pg_get_constraintdef(c.oid, true) as definition
from pg_constraint c
join pg_class ch on ch.oid = c.conrelid
join pg_namespace cn on cn.oid = ch.relnamespace
join pg_class pa on pa.oid = c.confrelid
join pg_namespace pn on pn.oid = pa.relnamespace
where c.contype = 'f' and cn.nspname = 'public'
  and ch.relname in ('products','product_categories','expenses','purchases','purchase_items',
    'supplier_payments','sales','sale_items','payments','payment_allocations',
    'stock_adjustments','stock_movements','stock_transfers','stock_transfer_items')
order by ch.relname, c.conname;


-- 4A. PURCHASE mismatch counts (aggregate only; no customer or supplier PII returned)
-- Purpose: count cross-organization supplier/branch, purchase-line, product, supplier
-- payment and linked purchase/supplier mismatches.
-- Tables: purchases, suppliers, branches, purchase_items, products, supplier_payments.
-- Safe: every count is zero. Unsafe: any nonzero count indicates a cross-tenant link.
-- Limits: run only if schema preflight confirms all referenced tables/columns exist.
select 'purchases.supplier_id -> suppliers' as relationship, count(*) as mismatch_count
from public.purchases c join public.suppliers p on p.id=c.supplier_id where c.organization_id<>p.organization_id
union all
select 'purchases.branch_id -> branches', count(*) from public.purchases c join public.branches p on p.id=c.branch_id where c.branch_id is not null and c.organization_id<>p.organization_id
union all
select 'purchase_items.purchase_id -> purchases', count(*) from public.purchase_items c join public.purchases p on p.id=c.purchase_id where c.organization_id<>p.organization_id
union all
select 'purchase_items.product_id -> products', count(*) from public.purchase_items c join public.products p on p.id=c.product_id where c.organization_id<>p.organization_id
union all
select 'supplier_payments.supplier_id -> suppliers', count(*) from public.supplier_payments c join public.suppliers p on p.id=c.supplier_id where c.organization_id<>p.organization_id
union all
select 'supplier_payments.purchase_id -> purchases', count(*) from public.supplier_payments c join public.purchases p on p.id=c.purchase_id where c.purchase_id is not null and c.organization_id<>p.organization_id
union all
select 'supplier_payments supplier differs from linked purchase supplier', count(*) from public.supplier_payments c join public.purchases p on p.id=c.purchase_id where c.purchase_id is not null and c.supplier_id<>p.supplier_id;

-- 4B. SALES AND CUSTOMER PAYMENT mismatch counts (aggregate only)
-- Purpose: count tenant/customer/branch/invoice/payment-allocation ownership mismatches.
-- Tables: sales, customers, branches, sale_items, products, payments,
-- payment_allocations.
-- Safe: every count is zero. Unsafe: any nonzero count signals an invalid ownership
-- link or cross-customer financial allocation requiring incident review.
-- Limits: run only if schema preflight confirms all referenced tables/columns exist.
select 'sales.customer_id -> customers' as relationship, count(*) as mismatch_count
from public.sales c join public.customers p on p.id=c.customer_id where c.customer_id is not null and c.organization_id<>p.organization_id
union all
select 'sales.branch_id -> branches', count(*) from public.sales c join public.branches p on p.id=c.branch_id where c.branch_id is not null and c.organization_id<>p.organization_id
union all
select 'sale_items.sale_id -> sales', count(*) from public.sale_items c join public.sales p on p.id=c.sale_id where c.organization_id<>p.organization_id
union all
select 'sale_items.product_id -> products', count(*) from public.sale_items c join public.products p on p.id=c.product_id where c.organization_id<>p.organization_id
union all
select 'payments.customer_id -> customers', count(*) from public.payments c join public.customers p on p.id=c.customer_id where c.customer_id is not null and c.organization_id<>p.organization_id
union all
select 'payment_allocations.payment_id -> payments', count(*) from public.payment_allocations c join public.payments p on p.id=c.payment_id where c.organization_id<>p.organization_id
union all
select 'payment_allocations.sale_id -> sales', count(*) from public.payment_allocations c join public.sales p on p.id=c.sale_id where c.sale_id is not null and c.organization_id<>p.organization_id
union all
select 'payment allocation customer differs from sale customer', count(*) from public.payment_allocations a join public.payments p on p.id=a.payment_id join public.sales s on s.id=a.sale_id where a.sale_id is not null and p.customer_id is distinct from s.customer_id;

-- 4C. STOCK AND BRANCH mismatch counts (aggregate only)
-- Purpose: count stock product/branch ownership mismatch and branch-to-organization
-- mismatch for stock adjustments, movements, transfers, and transfer items.
-- Tables: stock_adjustments, stock_movements, stock_transfers, stock_transfer_items,
-- products, branches.
-- Safe: every count is zero. Unsafe: any nonzero result could cause incorrect stock
-- valuation or allow one tenant/branch to affect another.
-- Limits: stock_movements polymorphic reference_type/reference_id needs a separate
-- per-reference-type investigation; this block does not validate those references.
-- Run only if schema preflight confirms the referenced tables/columns exist.
select 'stock_adjustments.product_id -> products' as relationship, count(*) as mismatch_count
from public.stock_adjustments c join public.products p on p.id=c.product_id where c.organization_id<>p.organization_id
union all
select 'stock_adjustments.branch_id -> branches', count(*) from public.stock_adjustments c join public.branches p on p.id=c.branch_id where c.branch_id is not null and c.organization_id<>p.organization_id
union all
select 'stock_movements.product_id -> products', count(*) from public.stock_movements c join public.products p on p.id=c.product_id where c.organization_id<>p.organization_id
union all
select 'stock_movements.branch_id -> branches', count(*) from public.stock_movements c join public.branches p on p.id=c.branch_id where c.branch_id is not null and c.organization_id<>p.organization_id
union all
select 'stock_transfers.source_branch_id -> branches', count(*) from public.stock_transfers c join public.branches p on p.id=c.source_branch_id where c.organization_id<>p.organization_id
union all
select 'stock_transfers.destination_branch_id -> branches', count(*) from public.stock_transfers c join public.branches p on p.id=c.destination_branch_id where c.organization_id<>p.organization_id
union all
select 'stock_transfer_items.transfer_id -> stock_transfers', count(*) from public.stock_transfer_items c join public.stock_transfers p on p.id=c.transfer_id where c.organization_id<>p.organization_id
union all
select 'stock_transfer_items.product_id -> products', count(*) from public.stock_transfer_items c join public.products p on p.id=c.product_id where c.organization_id<>p.organization_id;

-- 4D. Other tenant reference mismatch counts (aggregate only)
-- Purpose: count category/unit/parent-category/expense-category cross-organization links.
-- Tables: products, product_categories, units, expenses, expense_categories.
-- Safe: all counts are zero. Unsafe: any nonzero count indicates category/unit data
-- crossing tenant boundaries.
-- Limits: run only if schema preflight confirms all referenced tables/columns exist.
select 'products.category_id -> product_categories' as relationship, count(*) as mismatch_count
from public.products c join public.product_categories p on p.id=c.category_id where c.category_id is not null and c.organization_id<>p.organization_id
union all
select 'products.unit_id -> units', count(*) from public.products c join public.units p on p.id=c.unit_id where c.unit_id is not null and c.organization_id<>p.organization_id
union all
select 'product_categories.parent_id -> product_categories', count(*) from public.product_categories c join public.product_categories p on p.id=c.parent_id where c.parent_id is not null and c.organization_id<>p.organization_id
union all
select 'expenses.category_id -> expense_categories', count(*) from public.expenses c join public.expense_categories p on p.id=c.category_id where c.category_id is not null and c.organization_id<>p.organization_id;

-- 4E. Polymorphic stock movement references
-- Purpose: count tenant mismatches for recognized reference types, without row details.
-- Tables: stock_movements, sales, purchases, stock_adjustments, stock_transfers.
-- Safe: each count is zero; unknown types are separately counted and explained.
-- Unsafe: nonzero mismatch count or unexplained reference types.
-- Limits: source may use different reference_type labels; first inspect distinct labels
-- only if allowed by internal policy (labels are not customer data), then adapt this
-- aggregate query. This query assumes labels sale, purchase, stock_adjustment,
-- stock_transfer as identified in local source.
select 'stock_movements -> sales' as relationship, count(*) as mismatch_count
from public.stock_movements m join public.sales p on p.id=m.reference_id where m.reference_type='sale' and m.organization_id<>p.organization_id
union all
select 'stock_movements -> purchases', count(*) from public.stock_movements m join public.purchases p on p.id=m.reference_id where m.reference_type='purchase' and m.organization_id<>p.organization_id
union all
select 'stock_movements -> stock_adjustments', count(*) from public.stock_movements m join public.stock_adjustments p on p.id=m.reference_id where m.reference_type='stock_adjustment' and m.organization_id<>p.organization_id
union all
select 'stock_movements -> stock_transfers', count(*) from public.stock_movements m join public.stock_transfers p on p.id=m.reference_id where m.reference_type='stock_transfer' and m.organization_id<>p.organization_id
union all
select 'stock_movements with unrecognized/null reference type', count(*) from public.stock_movements where reference_id is not null and coalesce(reference_type,'') not in ('sale','purchase','stock_adjustment','stock_transfer');


-- 4F. Existing supplier allocation table shape (diagnostic only)
-- Purpose: discover the exact deployed columns, foreign keys, indexes, RLS flags,
-- and policies before adapting migration 0044. No row-level business data is read.
-- Catalogs: information_schema.columns, pg_constraint, pg_class, pg_namespace,
-- pg_indexes, pg_policies.
-- Safe: use the result to compare the existing relation with the expected contract;
-- no schema/data changes are performed.
-- Unsafe: this query does not certify the table's data or tenant isolation. Do not
-- infer aliases or backfill mappings from column names alone.
-- Limits: catalog visibility depends on SQL Editor role privileges. If the table is
-- missing or inaccessible, record that explicitly; never create a parallel table to
-- bypass an unknown schema.
select ordinal_position, column_name, data_type, udt_name, is_nullable, column_default
from information_schema.columns
where table_schema='public' and table_name='supplier_payment_allocations'
order by ordinal_position;

select con.conname as constraint_name,
       con.contype as constraint_type,
       con.convalidated as is_validated,
       pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
where con.conrelid=to_regclass('public.supplier_payment_allocations')
order by con.contype, con.conname;

select indexname, indexdef
from pg_indexes
where schemaname='public' and tablename='supplier_payment_allocations'
order by indexname;

select c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced,
       p.policyname, p.permissive, p.roles, p.cmd, p.qual, p.with_check
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
left join pg_policies p on p.schemaname=n.nspname and p.tablename=c.relname
where n.nspname='public' and c.relname='supplier_payment_allocations'
order by p.policyname;


-- ============================================================================
-- 5. Migration history (read-only)
-- Purpose: inspect whether Supabase migration history table exists, and then read
-- version/name rows if visible. The existence preflight is separate because querying
-- a missing table would error.
-- Catalogs: information_schema.tables, supabase_migrations.schema_migrations.
-- Safe: remote applied versions can be compared manually with local migrations 0001–0044.
-- Unsafe: missing, duplicate, unexpected, or out-of-order versions require operator
-- investigation; do not insert or repair history rows from this pack.
-- Limits: SQL Editor cannot inspect local files. The operator must compare result rows
-- against the checked-out local migration filenames. Operator logs report 0043 applied
-- and 0044 failed; independently verify that state from this history query. Supabase may use another history
-- table/schema or hide it from the current role.
select table_schema, table_name
from information_schema.tables
where table_schema = 'supabase_migrations'
  and table_name = 'schema_migrations';

-- Run this query only if the preflight above returns the table and SELECT access is
-- permitted. Purpose: read remote applied migration versions and names.
-- Catalog/table: supabase_migrations.schema_migrations.
-- Safe: ordered versions are explainable against local source migration files 0001–0044.
-- Unsafe: missing or unexpected versions, or local files absent remotely, need review.
-- Limits: this is a remote snapshot; compare manually. No migration history is changed.
select version, name
from supabase_migrations.schema_migrations
order by version;

