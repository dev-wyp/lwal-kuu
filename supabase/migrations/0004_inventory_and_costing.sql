-- ==============================================================================
-- Migration: 0004_inventory_and_costing.sql
-- Description: Stock movements ledger, adjustments, stock balance view, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant inventory tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'stock_movements'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'stock_movements' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'stock_adjustments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'stock_adjustments' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;
end $$;

-- 1. Stock Movements (Immutable Ledger)
create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  movement_type text not null check (movement_type in (
    'opening', 'purchase_in', 'sales_out', 'customer_return',
    'supplier_return', 'adjustment_in', 'adjustment_out', 'sale_reversal'
  )),
  quantity numeric(12, 2) not null,
  unit_cost numeric(14, 4) not null default 0.0000,
  reference_type text not null check (reference_type in ('purchase', 'sale', 'adjustment', 'opening')),
  reference_id uuid not null,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_stock_movements_org_prod on public.stock_movements (organization_id, product_id);
create index if not exists idx_stock_movements_ref on public.stock_movements (reference_type, reference_id);

-- 2. Stock Adjustments
create table if not exists public.stock_adjustments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  adjustment_number text not null,
  adjustment_date date not null default current_date,
  product_id uuid not null references public.products(id) on delete restrict,
  reason text not null check (reason in ('damaged', 'expired', 'count_correction', 'loss', 'other')),
  quantity_delta numeric(12, 2) not null,
  unit_cost numeric(14, 4) not null default 0.0000,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, adjustment_number)
);

create index if not exists idx_stock_adj_org_prod on public.stock_adjustments (organization_id, product_id);

-- 3. Product Stock Balances View (Reconcilable with Ledger)
create or replace view public.product_stock_balances as
select
  p.id as product_id,
  p.organization_id,
  p.sku,
  p.name,
  p.unit_id,
  u.code as unit_code,
  u.name as unit_name,
  p.sale_price,
  p.average_cost,
  p.low_stock_threshold,
  coalesce(sum(sm.quantity), 0.00) as stock_on_hand,
  coalesce(sum(sm.quantity), 0.00) * p.average_cost as stock_value,
  case
    when coalesce(sum(sm.quantity), 0.00) <= p.low_stock_threshold then true
    else false
  end as is_low_stock
from public.products p
join public.units u on u.id = p.unit_id
left join public.stock_movements sm on sm.product_id = p.id and sm.organization_id = p.organization_id
where p.is_active = true
group by p.id, p.organization_id, p.sku, p.name, p.unit_id, u.code, u.name, p.sale_price, p.average_cost, p.low_stock_threshold;

-- 4. Atomic RPC: Create Stock Adjustment
create or replace function public.create_stock_adjustment(
  p_org_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_adj_num text;
  v_product public.products%rowtype;
  v_adj_id uuid;
  v_mov_type text;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id and organization_id = p_org_id;

  if not found then
    raise exception 'Product not found';
  end if;

  if p_quantity_delta = 0 then
    raise exception 'Quantity delta cannot be zero';
  end if;

  v_adj_num := public.next_document_number(p_org_id, 'stock_adjustment');

  insert into public.stock_adjustments (
    organization_id, adjustment_number, product_id, reason,
    quantity_delta, unit_cost, notes, created_by
  )
  values (
    p_org_id, v_adj_num, p_product_id, p_reason,
    p_quantity_delta, v_product.average_cost, p_notes, v_user_id
  )
  returning id into v_adj_id;

  v_mov_type := case when p_quantity_delta > 0 then 'adjustment_in' else 'adjustment_out' end;

  insert into public.stock_movements (
    organization_id, product_id, movement_type, quantity,
    unit_cost, reference_type, reference_id, notes, created_by
  )
  values (
    p_org_id, p_product_id, v_mov_type, p_quantity_delta,
    v_product.average_cost, 'adjustment', v_adj_id, p_notes, v_user_id
  );

  return jsonb_build_object(
    'success', true,
    'adjustment_id', v_adj_id,
    'adjustment_number', v_adj_num
  );
end;
$$;

-- 5. Enable RLS
alter table public.stock_movements enable row level security;
alter table public.stock_adjustments enable row level security;

-- Policies for stock_movements
create policy "Members can view stock movements"
  on public.stock_movements for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can insert stock movements"
  on public.stock_movements for insert
  with check (public.has_org_membership(organization_id) or public.is_platform_admin());

-- Never allow update or delete on stock_movements!
-- (Immutable audit ledger requirement)

-- Policies for stock_adjustments
create policy "Members can view adjustments"
  on public.stock_adjustments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can create adjustments"
  on public.stock_adjustments for insert
  with check (public.has_org_membership(organization_id) or public.is_platform_admin());

