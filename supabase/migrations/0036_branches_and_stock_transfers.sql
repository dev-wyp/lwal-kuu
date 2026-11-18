-- Some deployments may already have unrelated legacy tables with these names.
-- Preserve any incompatible table instead of letting IF NOT EXISTS silently
-- keep its old shape and fail later in the branch/transfer setup.
do $$
declare
  item record;
  legacy_name text;
  relation_kind "char";
begin
  for item in select * from (values
    ('branches', array['id','organization_id','code','name','is_default','is_active']::text[]),
    ('stock_transfers', array['id','organization_id','transfer_number','source_branch_id','destination_branch_id','status','notes','created_by','created_at']::text[]),
    ('stock_transfer_items', array['id','organization_id','transfer_id','product_id','quantity','unit_cost']::text[])
  ) as tenant_tables(table_name, required_columns) loop
    if to_regclass(format('public.%I', item.table_name)) is not null
       and exists (
         select 1 from unnest(item.required_columns) as required_columns(required_column)
         where not exists (
           select 1 from information_schema.columns
           where table_schema='public' and table_name=item.table_name and column_name=required_column
         )
       ) then
      legacy_name := item.table_name || '_legacy_before_plan_feature';
      if to_regclass(format('public.%I', legacy_name)) is not null then
        raise exception 'Legacy public.% does not have the required columns and public.% is already present; archive the legacy table before retrying', item.table_name, legacy_name;
      end if;
      select c.relkind into relation_kind
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=item.table_name;
      if relation_kind='v' then
        execute format('alter view public.%I rename to %I', item.table_name, legacy_name);
      elsif relation_kind='m' then
        execute format('alter materialized view public.%I rename to %I', item.table_name, legacy_name);
      else
        execute format('alter table public.%I rename to %I', item.table_name, legacy_name);
      end if;
    end if;
  end loop;
end;
$$;

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  address text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);
create unique index if not exists branches_org_default_uidx_v2
  on public.branches(organization_id) where is_default;
create index if not exists branches_org_active_idx_v2 on public.branches(organization_id, is_active);

alter table public.sales add column if not exists branch_id uuid;
alter table public.purchases add column if not exists branch_id uuid;
alter table public.stock_adjustments add column if not exists branch_id uuid;
alter table public.stock_movements add column if not exists branch_id uuid;

insert into public.branches(organization_id, code, name, is_default)
select o.id, 'MAIN', coalesce(nullif(o.name, ''), 'Shop') || ' Main Branch', true
from public.organizations o
where not exists (select 1 from public.branches b where b.organization_id = o.id);

update public.sales s set branch_id = b.id
from public.branches b where b.organization_id = s.organization_id and b.is_default and s.branch_id is null;
update public.purchases p set branch_id = b.id
from public.branches b where b.organization_id = p.organization_id and b.is_default and p.branch_id is null;
update public.stock_adjustments a set branch_id = b.id
from public.branches b where b.organization_id = a.organization_id and b.is_default and a.branch_id is null;
update public.stock_movements m set branch_id = b.id
from public.branches b where b.organization_id = m.organization_id and b.is_default and m.branch_id is null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sales_branch_id_fkey') then
    alter table public.sales add constraint sales_branch_id_fkey foreign key (branch_id) references public.branches(id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'purchases_branch_id_fkey') then
    alter table public.purchases add constraint purchases_branch_id_fkey foreign key (branch_id) references public.branches(id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_adjustments_branch_id_fkey') then
    alter table public.stock_adjustments add constraint stock_adjustments_branch_id_fkey foreign key (branch_id) references public.branches(id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'stock_movements_branch_id_fkey') then
    alter table public.stock_movements add constraint stock_movements_branch_id_fkey foreign key (branch_id) references public.branches(id);
  end if;
end $$;

create or replace function public.seed_default_branch_for_organization()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.branches(organization_id, code, name, is_default)
  values (new.id, 'MAIN', coalesce(nullif(new.name, ''), 'Shop') || ' Main Branch', true)
  on conflict (organization_id, code) do nothing;
  return new;
end;
$$;
drop trigger if exists trg_seed_default_branch on public.organizations;
create trigger trg_seed_default_branch after insert on public.organizations
for each row execute function public.seed_default_branch_for_organization();

create or replace function public.assign_transaction_branch()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare default_branch uuid;
begin
  if new.branch_id is null then
    select id into default_branch from public.branches
    where organization_id = new.organization_id and is_default and is_active;
    if default_branch is null then raise exception 'Organization has no active default branch'; end if;
    new.branch_id := default_branch;
  end if;
  if not exists (select 1 from public.branches where id = new.branch_id and organization_id = new.organization_id and is_active) then
    raise exception 'Branch is not active or does not belong to this organization';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_assign_sales_branch on public.sales;
create trigger trg_assign_sales_branch before insert or update of branch_id on public.sales
for each row execute function public.assign_transaction_branch();
drop trigger if exists trg_assign_purchases_branch on public.purchases;
create trigger trg_assign_purchases_branch before insert or update of branch_id on public.purchases
for each row execute function public.assign_transaction_branch();
drop trigger if exists trg_assign_stock_adjustment_branch on public.stock_adjustments;
create trigger trg_assign_stock_adjustment_branch before insert or update of branch_id on public.stock_adjustments
for each row execute function public.assign_transaction_branch();

create or replace function public.assign_movement_branch()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.branch_id is null then
    if new.reference_type = 'sale' then
      select branch_id into new.branch_id from public.sales where id = new.reference_id and organization_id = new.organization_id;
    elsif new.reference_type = 'purchase' then
      select branch_id into new.branch_id from public.purchases where id = new.reference_id and organization_id = new.organization_id;
    elsif new.reference_type = 'adjustment' then
      select branch_id into new.branch_id from public.stock_adjustments where id = new.reference_id and organization_id = new.organization_id;
    end if;
  end if;
  if new.branch_id is null then
    select id into new.branch_id from public.branches where organization_id = new.organization_id and is_default and is_active;
  end if;
  if not exists (select 1 from public.branches where id = new.branch_id and organization_id = new.organization_id and is_active) then
    raise exception 'Stock movement branch is not active or belongs to another organization';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_assign_stock_movement_branch on public.stock_movements;
create trigger trg_assign_stock_movement_branch before insert or update of branch_id on public.stock_movements
for each row execute function public.assign_movement_branch();

create or replace function public.enforce_branch_plan_limit()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare access_result jsonb; limit_result jsonb;
begin
  if new.is_default then
    if tg_op = 'INSERT' and not public.is_platform_admin()
       and exists (select 1 from public.branches where organization_id = new.organization_id and is_default)
       and not exists (select 1 from public.branches where id = new.id and organization_id = new.organization_id and is_default) then
      raise exception 'Only the organization default branch may be seeded';
    end if;
    return new;
  end if;
  access_result := public.check_organization_feature(new.organization_id, 'multi_branch');
  if not coalesce((access_result->>'is_allowed')::boolean, false) then
    raise exception 'Multi-branch is not available on the current plan';
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and not old.is_active and new.is_active) then
    perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':max_branches', 0));
    limit_result := public.check_organization_limit(new.organization_id, 'max_branches');
    if not coalesce((limit_result->>'is_allowed')::boolean, false) then raise exception 'Plan branch limit reached'; end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_enforce_branch_plan_limit on public.branches;
create trigger trg_enforce_branch_plan_limit before insert or update of is_active, is_default on public.branches
for each row execute function public.enforce_branch_plan_limit();

create or replace function public.get_organization_usage(p_org_id uuid, p_feature_key text)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer := 0;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  case p_feature_key
    when 'max_users' then select count(*)::int into n from public.organization_members where organization_id=p_org_id and is_active;
    when 'max_products' then select count(*)::int into n from public.products where organization_id=p_org_id and is_active;
    when 'max_customers' then select count(*)::int into n from public.customers where organization_id=p_org_id and is_active;
    when 'max_suppliers' then select count(*)::int into n from public.suppliers where organization_id=p_org_id and is_active;
    when 'max_branches' then select count(*)::int into n from public.branches where organization_id=p_org_id and is_active;
    else n := 0;
  end case;
  return n;
end;
$$;

alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check (movement_type in ('opening','purchase_in','sales_out','customer_return','supplier_return','adjustment_in','adjustment_out','sale_reversal','stock_transfer_out','stock_transfer_in'));
alter table public.stock_movements drop constraint if exists stock_movements_reference_type_check;
alter table public.stock_movements add constraint stock_movements_reference_type_check
  check (reference_type in ('purchase','sale','adjustment','opening','stock_transfer'));

create table if not exists public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transfer_number text not null,
  source_branch_id uuid not null references public.branches(id),
  destination_branch_id uuid not null references public.branches(id),
  status text not null default 'posted' check (status in ('posted','reversed')),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, transfer_number),
  check (source_branch_id <> destination_branch_id)
);
create table if not exists public.stock_transfer_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric(12,2) not null check (quantity > 0),
  unit_cost numeric(14,4) not null default 0
);
alter table public.stock_transfers enable row level security;
alter table public.stock_transfer_items enable row level security;
drop policy if exists stock_transfers_read_members on public.stock_transfers;
create policy stock_transfers_read_members on public.stock_transfers for select using (public.has_org_membership(organization_id));
drop policy if exists stock_transfer_items_read_members on public.stock_transfer_items;
create policy stock_transfer_items_read_members on public.stock_transfer_items for select using (public.has_org_membership(organization_id));

create or replace view public.branch_stock_balances as
select b.organization_id, b.id as branch_id, b.name as branch_name,
       p.id as product_id, p.sku, p.name, p.name as product_name, u.code as unit_code, u.name as unit_name, p.sale_price,
       coalesce(sum(m.quantity), 0)::numeric as stock_on_hand,
       p.average_cost,
       (coalesce(sum(m.quantity), 0) * p.average_cost)::numeric as stock_value,
       p.low_stock_threshold,
       (coalesce(sum(m.quantity), 0) <= p.low_stock_threshold) as is_low_stock
from public.branches b
join public.products p on p.organization_id = b.organization_id and p.is_active
join public.units u on u.id = p.unit_id
left join public.stock_movements m on m.branch_id = b.id and m.product_id = p.id and m.organization_id = p.organization_id
where b.is_active and public.has_org_membership(b.organization_id)
group by b.organization_id, b.id, b.name, p.id, p.sku, p.name, u.code, u.name, p.sale_price, p.average_cost, p.low_stock_threshold;
grant select on public.branch_stock_balances to authenticated;

create or replace view public.branch_sales_performance as
select s.organization_id, s.branch_id, b.name as branch_name,
       count(*)::integer as invoice_count, sum(s.total_amount) as revenue,
       sum(s.total_cost) as cost_of_goods, sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
join public.branches b on b.id=s.branch_id and b.organization_id=s.organization_id
where s.status='confirmed'
  and public.has_org_membership(s.organization_id)
  and public.organization_has_plan_feature(s.organization_id,'branch_reports')
group by s.organization_id,s.branch_id,b.name;
grant select on public.branch_sales_performance to authenticated;

-- Preserve any older RPC with the same argument signature but a different
-- return type; PostgreSQL cannot replace its return type in place.
do $$
begin
  if to_regprocedure('public.create_stock_transfer(uuid,uuid,uuid,jsonb,text)') is not null then
    if to_regprocedure('public.create_stock_transfer_legacy_before_plan_feature(uuid,uuid,uuid,jsonb,text)') is not null then
      raise exception 'Legacy create_stock_transfer signature still exists and its legacy alias is already present';
    end if;
    alter function public.create_stock_transfer(uuid,uuid,uuid,jsonb,text)
      rename to create_stock_transfer_legacy_before_plan_feature;
    revoke all on function public.create_stock_transfer_legacy_before_plan_feature(uuid,uuid,uuid,jsonb,text) from public, anon, authenticated;
  end if;
end;
$$;

create or replace function public.create_stock_transfer(
  p_org_id uuid, p_source_branch_id uuid, p_destination_branch_id uuid,
  p_items jsonb, p_notes text default null
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  transfer_id uuid := gen_random_uuid();
  transfer_number text;
  item jsonb;
  v_product_id uuid;
  quantity numeric(12,2);
  unit_cost numeric(14,4);
  available numeric;
  access_result jsonb;
begin
  if not public.has_org_membership(p_org_id) then raise exception 'Unauthorized'; end if;
  access_result := public.check_organization_feature(p_org_id, 'stock_transfer');
  if not coalesce((access_result->>'is_allowed')::boolean, false) then raise exception 'Stock transfer is not available on the current plan'; end if;
  if p_source_branch_id = p_destination_branch_id then raise exception 'Choose two different branches'; end if;
  if not exists (select 1 from public.branches where id=p_source_branch_id and organization_id=p_org_id and is_active)
     or not exists (select 1 from public.branches where id=p_destination_branch_id and organization_id=p_org_id and is_active) then
    raise exception 'Both branches must be active in this organization';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Transfer requires at least one item'; end if;

  transfer_number := public.next_document_number(p_org_id, 'stock_transfer');
  insert into public.stock_transfers( id, organization_id, transfer_number, source_branch_id, destination_branch_id, notes, created_by)
  values (transfer_id, p_org_id, transfer_number, p_source_branch_id, p_destination_branch_id, p_notes, auth.uid());

  for item in select value from jsonb_array_elements(p_items) loop
    v_product_id := (item->>'product_id')::uuid;
    quantity := (item->>'quantity')::numeric;
    if quantity <= 0 then raise exception 'Transfer quantities must be positive'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || p_source_branch_id::text || ':' || v_product_id::text, 0));
    select coalesce(sum(sm.quantity),0) into available from public.stock_movements sm
      where sm.organization_id=p_org_id and sm.branch_id=p_source_branch_id and sm.product_id=v_product_id;
    if available < quantity then raise exception 'Insufficient source branch stock'; end if;
    select average_cost into unit_cost from public.products where id=v_product_id and organization_id=p_org_id and is_active;
    if not found then raise exception 'Product not found'; end if;
    insert into public.stock_transfer_items(organization_id,transfer_id,product_id,quantity,unit_cost)
      values(p_org_id,transfer_id,v_product_id,quantity,unit_cost);
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,quantity,unit_cost,reference_type,reference_id,notes,created_by)
      values(p_org_id,p_source_branch_id,v_product_id,'stock_transfer_out',-quantity,unit_cost,'stock_transfer',transfer_id,p_notes,auth.uid());
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,quantity,unit_cost,reference_type,reference_id,notes,created_by)
      values(p_org_id,p_destination_branch_id,v_product_id,'stock_transfer_in',quantity,unit_cost,'stock_transfer',transfer_id,p_notes,auth.uid());
  end loop;
  return jsonb_build_object('success',true,'transfer_id',transfer_id,'transfer_number',transfer_number);
end;
$$;
revoke all on function public.create_stock_transfer(uuid,uuid,uuid,jsonb,text) from public, anon;
grant execute on function public.create_stock_transfer(uuid,uuid,uuid,jsonb,text) to authenticated;

-- Restrict branch visibility/mutations to tenant members with the feature.
alter table public.branches enable row level security;
drop policy if exists branches_read_members on public.branches;
create policy branches_read_members on public.branches for select
  using (public.has_org_membership(organization_id) and (is_default or public.organization_has_plan_feature(organization_id,'multi_branch')));
drop policy if exists branches_insert_admin on public.branches;
create policy branches_insert_admin on public.branches for insert
  with check (public.is_org_admin_or_owner(organization_id) and not is_default and public.organization_has_plan_feature(organization_id,'multi_branch'));
drop policy if exists branches_update_admin on public.branches;
create policy branches_update_admin on public.branches for update
  using (public.is_org_admin_or_owner(organization_id) and not is_default)
  with check (public.is_org_admin_or_owner(organization_id) and not is_default and public.organization_has_plan_feature(organization_id,'multi_branch'));

-- Include branch mutations and transfer records in the tenant audit log.
do $$
declare table_name text;
begin
  foreach table_name in array array['branches','stock_transfers','stock_transfer_items'] loop
    execute format('drop trigger if exists trg_audit_%I on public.%I', table_name, table_name);
    execute format('create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.capture_tenant_audit_log()', table_name, table_name);
  end loop;
end;
$$;
