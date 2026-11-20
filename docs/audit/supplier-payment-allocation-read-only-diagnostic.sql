-- ShopFlow supplier-payment allocation compatibility diagnostic.
-- READ ONLY: run one section at a time against a disposable local database or
-- explicitly approved isolated staging project only. Production is forbidden
-- for this Phase B investigation, including read-only queries.
-- No customer/supplier names, emails, payment references, or row IDs are returned.

-- 1. Relation existence, columns, exact PostgreSQL types, nullability and defaults.
select n.nspname as schema_name,
       c.relname as relation_name,
       c.relkind,
       pg_get_userbyid(c.relowner) as relation_owner,
       c.relrowsecurity as rls_enabled,
       c.relforcerowsecurity as rls_forced,
       col.ordinal_position,
       col.column_name,
       col.data_type,
       col.udt_name,
       col.is_nullable,
       col.column_default
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
left join information_schema.columns col
  on col.table_schema=n.nspname and col.table_name=c.relname
where n.nspname='public' and c.relname='supplier_payment_allocations'
order by col.ordinal_position;

-- 2. Primary, foreign, unique, check, and exclusion constraint definitions.
select con.conname as constraint_name,
       case con.contype
         when 'p' then 'PRIMARY KEY'
         when 'f' then 'FOREIGN KEY'
         when 'u' then 'UNIQUE'
         when 'c' then 'CHECK'
         when 'x' then 'EXCLUSION'
         else con.contype::text
       end as constraint_type,
       con.convalidated as validated,
       con.condeferrable as deferrable,
       con.condeferred as initially_deferred,
       pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
where con.conrelid=to_regclass('public.supplier_payment_allocations')
order by con.contype, con.conname;

-- 2a. Parent-key prerequisites for the intended composite foreign keys.
-- Shows all constraints and indexes on both parent tables so the operator can
-- confirm a valid unique key on (organization_id,id) without assuming one exists.
select t.relname as parent_table,
       con.conname as constraint_name,
       case con.contype when 'p' then 'PRIMARY KEY' when 'u' then 'UNIQUE'
            when 'f' then 'FOREIGN KEY' else con.contype::text end as constraint_type,
       con.convalidated as validated,
       pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
join pg_class t on t.oid=con.conrelid
join pg_namespace n on n.oid=t.relnamespace
where n.nspname='public' and t.relname in ('supplier_payments','purchases')
order by t.relname, con.contype, con.conname;

select t.relname as parent_table,
       ix.relname as index_name,
       i.indisunique as is_unique,
       i.indisvalid as is_valid,
       i.indisready as is_ready,
       pg_get_indexdef(i.indexrelid) as index_definition
from pg_index i
join pg_class t on t.oid=i.indrelid
join pg_namespace n on n.oid=t.relnamespace
join pg_class ix on ix.oid=i.indexrelid
where n.nspname='public' and t.relname in ('supplier_payments','purchases')
order by t.relname, ix.relname;

-- 3. Index definitions and validity.
select idx.indexname, idx.indexdef, i.indisunique as is_unique,
       i.indisprimary as is_primary, i.indisvalid as is_valid
from pg_indexes idx
join pg_class t on t.oid=to_regclass(format('%I.%I',idx.schemaname,idx.tablename))
join pg_namespace n on n.oid=t.relnamespace and n.nspname=idx.schemaname
join pg_class ic on ic.relname=idx.indexname and ic.relnamespace=n.oid
join pg_index i on i.indexrelid=ic.oid
where idx.schemaname='public' and idx.tablename='supplier_payment_allocations'
order by idx.indexname;

-- 4. RLS policies and effective table privileges.
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname='public' and tablename='supplier_payment_allocations'
order by policyname;

select role_name,
       has_table_privilege(role_name,'public.supplier_payment_allocations','SELECT') as can_select,
       has_table_privilege(role_name,'public.supplier_payment_allocations','INSERT') as can_insert,
       has_table_privilege(role_name,'public.supplier_payment_allocations','UPDATE') as can_update,
       has_table_privilege(role_name,'public.supplier_payment_allocations','DELETE') as can_delete,
       has_table_privilege(role_name,'public.supplier_payment_allocations','TRUNCATE') as can_truncate,
       has_table_privilege(role_name,'public.supplier_payment_allocations','REFERENCES') as can_reference,
       has_table_privilege(role_name,'public.supplier_payment_allocations','TRIGGER') as can_create_trigger
from (values ('anon'),('authenticated'),('service_role')) as roles(role_name)
order by role_name;

-- Direct table ACL entries, including the pseudo-role PUBLIC (shown as null
-- grantee). Effective role checks above show inherited PUBLIC privileges.
select r.rolname as grantee,
       x.privilege_type,
       x.is_grantable
from pg_class c
cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) x
left join pg_roles r on r.oid=x.grantee
where c.oid=to_regclass('public.supplier_payment_allocations')
order by grantee nulls first, x.privilege_type;

-- 4a. Effective grants on sequences owned by the allocation table, if any.
-- Zero rows means no owned sequence was discovered for this relation.
with owned_sequences as (
  select seq.oid as sequence_oid,
         ns.nspname as sequence_schema,
         seq.relname as sequence_name,
         a.attname as owning_column,
         pg_get_userbyid(seq.relowner) as sequence_owner
  from pg_class seq
  join pg_namespace ns on ns.oid=seq.relnamespace
  join pg_depend d on d.classid='pg_class'::regclass
    and d.objid=seq.oid and d.refclassid='pg_class'::regclass
    and d.refobjid=to_regclass('public.supplier_payment_allocations')
    and d.refobjsubid>0 and d.deptype in ('a','i')
  join pg_attribute a on a.attrelid=d.refobjid and a.attnum=d.refobjsubid
  where seq.relkind='S'
)
select s.sequence_schema, s.sequence_name, s.owning_column, s.sequence_owner,
       role_name,
       has_sequence_privilege(role_name,s.sequence_oid,'USAGE') as can_use,
       has_sequence_privilege(role_name,s.sequence_oid,'SELECT') as can_select,
       has_sequence_privilege(role_name,s.sequence_oid,'UPDATE') as can_update
from owned_sequences s
cross join (values ('anon'),('authenticated'),('service_role')) roles(role_name)
order by s.sequence_schema,s.sequence_name,role_name;

-- Direct sequence ACL entries, including PUBLIC as a null grantee.
with owned_sequences as (
  select seq.oid as sequence_oid, ns.nspname as sequence_schema,
         seq.relname as sequence_name, pg_get_userbyid(seq.relowner) as sequence_owner
  from pg_class seq
  join pg_namespace ns on ns.oid=seq.relnamespace
  join pg_depend d on d.classid='pg_class'::regclass and d.objid=seq.oid
    and d.refclassid='pg_class'::regclass
    and d.refobjid=to_regclass('public.supplier_payment_allocations')
    and d.refobjsubid>0 and d.deptype in ('a','i')
  where seq.relkind='S'
)
select s.sequence_schema,s.sequence_name,s.sequence_owner,
       r.rolname as grantee,x.privilege_type,x.is_grantable
from owned_sequences s
join pg_class c on c.oid=s.sequence_oid
cross join lateral aclexplode(coalesce(c.relacl,acldefault('S',c.relowner))) x
left join pg_roles r on r.oid=x.grantee
order by s.sequence_schema,s.sequence_name,grantee nulls first,x.privilege_type;

-- 4b. Non-internal triggers and their function security context.
select tg.tgname as trigger_name,
       case tg.tgenabled when 'O' then 'enabled' when 'D' then 'disabled'
            when 'R' then 'replica' when 'A' then 'always' end as trigger_state,
       pg_get_triggerdef(tg.oid,true) as trigger_definition,
       p.oid::regprocedure as trigger_function,
       pg_get_userbyid(p.proowner) as function_owner,
       p.prosecdef as function_is_security_definer,
       p.proconfig as function_settings
from pg_trigger tg
join pg_proc p on p.oid=tg.tgfoid
where tg.tgrelid=to_regclass('public.supplier_payment_allocations')
  and not tg.tgisinternal
order by tg.tgname;

-- 5. Supplier-payment RPC definitions, owners, SECURITY DEFINER setting,
-- search_path, direct ACL entries, and effective EXECUTE checks.
select p.oid::regprocedure as function_signature,
       pg_get_userbyid(p.proowner) as function_owner,
       p.prosecdef as security_definer,
       p.proconfig as function_settings,
       pg_get_functiondef(p.oid) as function_definition
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in ('receive_purchase','record_supplier_payment_and_allocate')
order by p.proname, p.oid::regprocedure::text;

select p.oid::regprocedure as function_signature,
       r.rolname as grantee,
       x.privilege_type as direct_privilege,
       x.is_grantable
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x
left join pg_roles r on r.oid=x.grantee
where n.nspname='public'
  and p.proname in ('receive_purchase','record_supplier_payment_and_allocate')
order by p.proname, p.oid::regprocedure::text, grantee nulls first;

select p.oid::regprocedure as function_signature,
       role_name,
       has_function_privilege(role_name,p.oid,'EXECUTE') as can_execute
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
       cross join (values ('anon'),('authenticated'),('service_role')) roles(role_name)
where n.nspname='public'
  and p.proname in ('receive_purchase','record_supplier_payment_and_allocate')
order by p.proname, p.oid::regprocedure::text, role_name;

-- 6. Aggregate compatibility and integrity counts only.
-- Candidate aliases let this query run without assuming the legacy relation's exact
-- column names. Review section 1 before interpreting any count. Counts are not proof
-- that a field with a similar name has the intended business meaning.
with raw_rows as (
  select to_jsonb(a) as j
  from public.supplier_payment_allocations a
), normalized as (
  select coalesce(j->>'supplier_payment_id',j->>'payment_id',j->>'supplier_payment_ref') as payment_ref,
         coalesce(j->>'purchase_id',j->>'purchase_order_id',j->>'purchase_ref') as purchase_ref,
         coalesce(j->>'organization_id',j->>'org_id',j->>'tenant_id') as organization_ref,
         coalesce(j->>'amount',j->>'allocated_amount',j->>'allocation_amount') as amount_text
  from raw_rows
), joined as (
  select n.*,
         sp.id as matched_payment_id,
         sp.organization_id as payment_org,
         sp.supplier_id as payment_supplier,
         sp.amount as payment_amount,
         pu.id as matched_purchase_id,
         pu.organization_id as purchase_org,
         pu.supplier_id as purchase_supplier,
         pu.total_amount as purchase_total
  from normalized n
  left join public.supplier_payments sp on sp.id::text=n.payment_ref
  left join public.purchases pu on pu.id::text=n.purchase_ref
), pair_totals as (
  select payment_ref,purchase_ref,count(*) as row_count
  from normalized
  where payment_ref is not null and purchase_ref is not null
  group by payment_ref,purchase_ref
), payment_totals as (
  select payment_ref,
         sum(case when amount_text ~ '^-?[0-9]+([.][0-9]+)?$' then amount_text::numeric else 0 end) as allocated_total
  from normalized where payment_ref is not null group by payment_ref
), purchase_totals as (
  select purchase_ref,
         sum(case when amount_text ~ '^-?[0-9]+([.][0-9]+)?$' then amount_text::numeric else 0 end) as allocated_total
  from normalized where purchase_ref is not null group by purchase_ref
)
select (select count(*) from raw_rows) as row_count,
       count(*) filter (where j.payment_ref is null) as missing_payment_reference_count,
       count(*) filter (where j.purchase_ref is null) as missing_purchase_reference_count,
       count(*) filter (where j.organization_ref is null) as missing_tenant_reference_count,
       count(*) filter (where j.amount_text is null or j.amount_text !~ '^[0-9]+([.][0-9]+)?$'
          or case when j.amount_text ~ '^[0-9]+([.][0-9]+)?$' then j.amount_text::numeric<=0 else false end) as invalid_amount_count,
       count(*) filter (where j.payment_ref is not null and j.matched_payment_id is null) as orphan_payment_reference_count,
       count(*) filter (where j.purchase_ref is not null and j.matched_purchase_id is null) as orphan_purchase_reference_count,
       count(*) filter (where j.matched_payment_id is not null and j.organization_ref is not null
          and j.payment_org::text<>j.organization_ref) as payment_tenant_mismatch_count,
       count(*) filter (where j.matched_purchase_id is not null and j.organization_ref is not null
          and j.purchase_org::text<>j.organization_ref) as purchase_tenant_mismatch_count,
       count(*) filter (where j.matched_payment_id is not null and j.matched_purchase_id is not null
          and j.payment_org<>j.purchase_org) as linked_documents_tenant_mismatch_count,
       count(*) filter (where j.matched_payment_id is not null and j.matched_purchase_id is not null
          and j.payment_supplier<>j.purchase_supplier) as supplier_mismatch_count,
       (select count(*) from pair_totals where row_count>1) as duplicate_payment_purchase_pair_count,
       (select count(*) from payment_totals pt join public.supplier_payments sp on sp.id::text=pt.payment_ref
          where pt.allocated_total>sp.amount) as payment_overallocation_count,
       (select count(*) from purchase_totals qt join public.purchases pu on pu.id::text=qt.purchase_ref
          where qt.allocated_total>pu.total_amount) as allocations_above_purchase_total_count
from joined j;

