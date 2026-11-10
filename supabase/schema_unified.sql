-- ==============================================================================
-- Migration: 0001_core_and_tenancy.sql
-- Description: Core multi-tenancy schema, profiles, memberships, settings, and RLS helpers.
-- ==============================================================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- 1. User Profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (length(btrim(full_name)) > 0),
  email text,
  phone_number text,
  avatar_url text,
  is_platform_admin boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Trigger to create profile when auth.users is created
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email, phone_number)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    new.email,
    new.raw_user_meta_data->>'phone_number'
  )
  on conflict (id) do update
  set full_name = coalesce(excluded.full_name, public.profiles.full_name),
      email = coalesce(excluded.email, public.profiles.email),
      updated_at = now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2. Organizations
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 160),
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  currency text not null default 'MMK',
  timezone text not null default 'Asia/Yangon',
  tax_id text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 3. Organization Members
create table if not exists public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'manager', 'staff')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create index if not exists idx_org_members_user_active on public.organization_members (user_id, organization_id) where is_active;

-- 4. Organization Settings
create table if not exists public.organization_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  currency_code text not null default 'MMK' check (currency_code ~ '^[A-Z]{3}$'),
  currency_symbol text not null default 'Ks',
  timezone text not null default 'Asia/Yangon',
  phone text,
  email text,
  address text,
  invoice_footer text,
  low_stock_threshold_default integer not null default 5 check (low_stock_threshold_default >= 0),
  costing_method text not null default 'weighted_average' check (costing_method in ('weighted_average', 'fifo')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 5. Audit Logs
create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid not null,
  payload jsonb default '{}'::jsonb,
  ip_address text,
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_logs_org_created on public.audit_logs (organization_id, created_at desc);

-- 6. Helper Security Functions (SECURITY DEFINER)
create or replace function public.has_org_membership(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.organization_members
    where organization_id = target_org_id
      and user_id = auth.uid()
      and is_active = true
  );
$$;

create or replace function public.get_user_org_role(target_org_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select role from public.organization_members
  where organization_id = target_org_id
    and user_id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.is_org_admin_or_owner(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.organization_members
    where organization_id = target_org_id
      and user_id = auth.uid()
      and role in ('owner', 'admin')
      and is_active = true
  );
$$;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select is_platform_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

-- 7. Document Counters for sequential document numbering per organization
create table if not exists public.document_counters (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_type text not null check (document_type in ('sale', 'purchase', 'goods_receipt', 'supplier_payment', 'customer_payment', 'stock_adjustment', 'expense')),
  next_value bigint not null default 1 check (next_value > 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, document_type)
);

create or replace function public.next_document_number(p_org_id uuid, p_doc_type text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefix text;
  v_num bigint;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Access denied for organization %', p_org_id;
  end if;

  v_prefix := case p_doc_type
    when 'sale' then 'INV'
    when 'purchase' then 'PO'
    when 'goods_receipt' then 'GRN'
    when 'supplier_payment' then 'SPAY'
    when 'customer_payment' then 'RCPT'
    when 'stock_adjustment' then 'ADJ'
    when 'expense' then 'EXP'
    else 'DOC'
  end;

  insert into public.document_counters (organization_id, document_type, next_value)
  values (p_org_id, p_doc_type, 2)
  on conflict (organization_id, document_type) do update
    set next_value = public.document_counters.next_value + 1,
        updated_at = now()
  returning next_value - 1 into v_num;

  return v_prefix || '-' || lpad(v_num::text, 6, '0');
end;
$$;

-- 8. Enable Row Level Security (RLS)
alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.organization_settings enable row level security;
alter table public.audit_logs enable row level security;
alter table public.document_counters enable row level security;

-- Profiles RLS
create policy "Users can view their own profile or platform admin view all"
  on public.profiles for select
  using (id = auth.uid() or public.is_platform_admin());

create policy "Users can update their own profile"
  on public.profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

-- Organizations RLS
create policy "Members can view their organizations"
  on public.organizations for select
  using (public.has_org_membership(id) or public.is_platform_admin());

create policy "Authenticated users can create organizations"
  on public.organizations for insert
  with check (auth.role() = 'authenticated');

create policy "Owners and Admins can update organization"
  on public.organizations for update
  using (public.is_org_admin_or_owner(id) or public.is_platform_admin());

-- Organization Members RLS
create policy "Members can view members of their organization"
  on public.organization_members for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Owners and Admins can manage members"
  on public.organization_members for all
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

-- Allow initial creator to insert themselves as owner during onboarding
create policy "User can insert themselves as owner"
  on public.organization_members for insert
  with check (user_id = auth.uid() and role = 'owner');

-- Organization Settings RLS
create policy "Members can view organization settings"
  on public.organization_settings for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Owners and Admins can update organization settings"
  on public.organization_settings for all
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

-- Audit Logs RLS
create policy "Members can view their organization audit logs"
  on public.audit_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "System and authenticated users can insert audit logs"
  on public.audit_logs for insert
  with check (public.has_org_membership(organization_id));

-- ==============================================================================
-- Migration: 0002_product_catalog.sql
-- Description: Product categories, measurement units, products master, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant products table if it pre-exists from old starter
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'products'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'products' and column_name = 'organization_id'
  ) then
    drop table public.products cascade;
  end if;
end $$;

-- 1. Product Categories
create table if not exists public.product_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 100),
  parent_id uuid references public.product_categories(id) on delete set null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create index if not exists idx_product_categories_org on public.product_categories (organization_id);

-- 2. Units of Measurement
create table if not exists public.units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null check (length(btrim(code)) between 1 and 20),
  name text not null check (length(btrim(name)) between 1 and 60),
  precision smallint not null default 0 check (precision between 0 and 4),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

create index if not exists idx_units_org on public.units (organization_id);

-- 3. Products Master
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null check (length(btrim(sku)) between 1 and 64),
  barcode text,
  name text not null check (length(btrim(name)) between 1 and 200),
  description text,
  category_id uuid references public.product_categories(id) on delete set null,
  unit_id uuid not null references public.units(id) on delete restrict,
  cost_price numeric(14, 2) not null default 0.00 check (cost_price >= 0),
  selling_price numeric(14, 2) not null default 0.00 check (selling_price >= 0),
  purchase_price numeric(14, 2) not null default 0.00 check (purchase_price >= 0),
  sale_price numeric(14, 2) not null default 0.00 check (sale_price >= 0),
  average_cost numeric(14, 4) not null default 0.0000 check (average_cost >= 0),
  low_stock_threshold numeric(12, 2) not null default 5.00 check (low_stock_threshold >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku)
);

-- Trigger to keep cost_price / purchase_price and selling_price / sale_price in sync
create or replace function public.sync_product_pricing()
returns trigger
language plpgsql
as $$
begin
  if new.cost_price = 0 and new.purchase_price > 0 then
    new.cost_price := new.purchase_price;
  elsif new.purchase_price = 0 and new.cost_price > 0 then
    new.purchase_price := new.cost_price;
  end if;

  if new.selling_price = 0 and new.sale_price > 0 then
    new.selling_price := new.sale_price;
  elsif new.sale_price = 0 and new.selling_price > 0 then
    new.sale_price := new.selling_price;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_sync_product_pricing on public.products;
create trigger trg_sync_product_pricing
  before insert or update on public.products
  for each row execute function public.sync_product_pricing();

create index if not exists idx_products_org_name on public.products (organization_id, name);
create index if not exists idx_products_org_sku on public.products (organization_id, sku);
create index if not exists idx_products_org_barcode on public.products (organization_id, barcode) where barcode is not null;

-- 4. Enable RLS
alter table public.product_categories enable row level security;
alter table public.units enable row level security;
alter table public.products enable row level security;

-- Policies for product_categories
create policy "Members can view categories"
  on public.product_categories for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage categories"
  on public.product_categories for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- Policies for units
create policy "Members can view units"
  on public.units for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage units"
  on public.units for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- Policies for products
create policy "Members can view products"
  on public.products for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can insert and update products"
  on public.products for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- ==============================================================================
-- Migration: 0003_customers_and_suppliers.sql
-- Description: Customers and Suppliers directories with credit limits and balances.
-- ==============================================================================

-- Ensure organizations & organization_members have required columns even if pre-existing
alter table if exists public.organizations 
  add column if not exists is_active boolean not null default true,
  add column if not exists currency text not null default 'MMK',
  add column if not exists timezone text not null default 'Asia/Yangon',
  add column if not exists tax_id text;

alter table if exists public.organization_members
  add column if not exists is_active boolean not null default true;

alter table if exists public.profiles
  add column if not exists email text;

-- Reload PostgREST schema cache
notify pgrst, 'reload schema';

-- Drop legacy non-multitenant customers and suppliers tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'customers'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'customers' and column_name = 'organization_id'
  ) then
    drop table public.customers cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'suppliers'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'suppliers' and column_name = 'organization_id'
  ) then
    drop table public.suppliers cascade;
  end if;
end $$;

-- 1. Customers
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  phone text,
  email text,
  address text,
  credit_limit numeric(14, 2) not null default 0.00 check (credit_limit >= 0),
  opening_balance numeric(14, 2) not null default 0.00,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_customers_org_name on public.customers (organization_id, name);
create index if not exists idx_customers_org_phone on public.customers (organization_id, phone) where phone is not null;

-- 2. Suppliers
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  contact_person text,
  phone text,
  email text,
  address text,
  opening_balance numeric(14, 2) not null default 0.00,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_suppliers_org_name on public.suppliers (organization_id, name);

-- 3. Enable RLS
alter table public.customers enable row level security;
alter table public.suppliers enable row level security;

-- Policies for customers
create policy "Members can view customers"
  on public.customers for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage customers"
  on public.customers for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- Policies for suppliers
create policy "Members can view suppliers"
  on public.suppliers for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can manage suppliers"
  on public.suppliers for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

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
    drop table public.stock_movements cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'stock_adjustments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'stock_adjustments' and column_name = 'organization_id'
  ) then
    drop table public.stock_adjustments cascade;
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

-- ==============================================================================
-- Migration: 0005_purchasing_and_payables.sql
-- Description: Purchases, purchase items, supplier payments, receiving RPC, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant purchasing tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'purchases'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'purchases' and column_name = 'organization_id'
  ) then
    drop table public.purchases cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'purchase_items'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'purchase_items' and column_name = 'organization_id'
  ) then
    drop table public.purchase_items cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'supplier_payments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'supplier_payments' and column_name = 'organization_id'
  ) then
    drop table public.supplier_payments cascade;
  end if;
end $$;

-- 1. Purchases
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_number text not null,
  purchase_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft', 'ordered', 'received', 'voided')),
  subtotal numeric(14, 2) not null default 0.00 check (subtotal >= 0),
  tax_amount numeric(14, 2) not null default 0.00 check (tax_amount >= 0),
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  total numeric(14, 2) not null default 0.00 check (total >= 0),
  total_amount numeric(14, 2) not null default 0.00 check (total_amount >= 0),
  paid_amount numeric(14, 2) not null default 0.00 check (paid_amount >= 0),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, purchase_number)
);

create or replace function public.sync_purchase_totals()
returns trigger
language plpgsql
as $$
begin
  if new.total = 0 and new.total_amount > 0 then
    new.total := new.total_amount;
  elsif new.total_amount = 0 and new.total > 0 then
    new.total_amount := new.total;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_purchase_totals on public.purchases;
create trigger trg_sync_purchase_totals
  before insert or update on public.purchases
  for each row execute function public.sync_purchase_totals();

create index if not exists idx_purchases_org_supp on public.purchases (organization_id, supplier_id);
create index if not exists idx_purchases_org_date on public.purchases (organization_id, purchase_date desc);

-- 2. Purchase Items
create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12, 2) not null check (quantity > 0),
  unit_cost numeric(14, 2) not null check (unit_cost >= 0),
  total_cost numeric(14, 2) not null check (total_cost >= 0),
  received_quantity numeric(12, 2) not null default 0.00 check (received_quantity >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_purch_items_purchase on public.purchase_items (purchase_id);

-- 3. Supplier Payments
create table if not exists public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_id uuid references public.purchases(id) on delete set null,
  payment_number text not null,
  payment_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  reference_number text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, payment_number)
);

create index if not exists idx_supp_payments_org_supp on public.supplier_payments (organization_id, supplier_id);

-- 4. Atomic RPC: Receive Purchase Order
create or replace function public.receive_purchase(
  p_org_id uuid,
  p_purchase_id uuid,
  p_amount_paid numeric default 0.00,
  p_payment_method text default 'cash'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_purchase public.purchases%rowtype;
  v_item record;
  v_current_stock numeric(12, 2);
  v_new_avg_cost numeric(14, 4);
  v_payment_number text;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  select * into v_purchase
  from public.purchases
  where id = p_purchase_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Purchase order not found';
  end if;

  if v_purchase.status = 'received' then
    raise exception 'Purchase is already marked received';
  end if;

  if v_purchase.status = 'voided' then
    raise exception 'Cannot receive a voided purchase order';
  end if;

  -- Process line items
  for v_item in
    select pi.*, p.average_cost as prod_avg_cost
    from public.purchase_items pi
    join public.products p on p.id = pi.product_id
    where pi.purchase_id = p_purchase_id
  loop
    -- Calculate current stock from ledger
    select coalesce(sum(quantity), 0.00) into v_current_stock
    from public.stock_movements
    where organization_id = p_org_id and product_id = v_item.product_id;

    -- Calculate weighted average cost
    if (v_current_stock + v_item.quantity) > 0 then
      if v_current_stock <= 0 then
        v_new_avg_cost := v_item.unit_cost;
      else
        v_new_avg_cost := ((v_current_stock * v_item.prod_avg_cost) + (v_item.quantity * v_item.unit_cost)) / (v_current_stock + v_item.quantity);
      end if;
    else
      v_new_avg_cost := v_item.unit_cost;
    end if;

    -- Update product average cost and purchase price
    update public.products
    set average_cost = v_new_avg_cost,
        purchase_price = v_item.unit_cost,
        updated_at = now()
    where id = v_item.product_id;

    -- Record stock movement ledger entry
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, created_by
    )
    values (
      p_org_id, v_item.product_id, 'purchase_in', v_item.quantity,
      v_item.unit_cost, 'purchase', p_purchase_id, v_user_id
    );

    -- Update received quantity on purchase item
    update public.purchase_items
    set received_quantity = quantity
    where id = v_item.id;
  end loop;

  -- Record payment if paid upfront
  if p_amount_paid > 0 then
    v_payment_number := public.next_document_number(p_org_id, 'supplier_payment');
    insert into public.supplier_payments (
      organization_id, supplier_id, purchase_id, payment_number,
      payment_date, amount, payment_method, created_by
    )
    values (
      p_org_id, v_purchase.supplier_id, p_purchase_id, v_payment_number,
      current_date, p_amount_paid, p_payment_method, v_user_id
    );
  end if;

  -- Mark purchase received
  update public.purchases
  set status = 'received',
      paid_amount = coalesce(paid_amount, 0) + coalesce(p_amount_paid, 0),
      updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object(
    'success', true,
    'purchase_id', p_purchase_id,
    'status', 'received'
  );
end;
$$;

-- 5. Enable RLS
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.supplier_payments enable row level security;

create policy "Members can view purchases"
  on public.purchases for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can manage purchases"
  on public.purchases for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view purchase items"
  on public.purchase_items for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can manage purchase items"
  on public.purchase_items for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view supplier payments"
  on public.supplier_payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Managers+ can record supplier payments"
  on public.supplier_payments for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- ==============================================================================
-- Migration: 0006_sales_and_receivables.sql
-- Description: Sales, sale items, payments, allocations, confirm sale RPC, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant sales and payment tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'sales'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'sales' and column_name = 'organization_id'
  ) then
    drop table public.sales cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'sale_items'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'sale_items' and column_name = 'organization_id'
  ) then
    drop table public.sale_items cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payments' and column_name = 'organization_id'
  ) then
    drop table public.payments cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payment_allocations'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payment_allocations' and column_name = 'organization_id'
  ) then
    drop table public.payment_allocations cascade;
  end if;
end $$;

-- 1. Sales
create table if not exists public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete restrict,
  invoice_number text not null,
  invoice_no text,
  sale_date date not null default current_date,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'voided', 'reversed')),
  subtotal numeric(14, 2) not null default 0.00 check (subtotal >= 0),
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  tax_amount numeric(14, 2) not null default 0.00 check (tax_amount >= 0),
  total numeric(14, 2) not null default 0.00 check (total >= 0),
  total_amount numeric(14, 2) not null default 0.00 check (total_amount >= 0),
  total_cost numeric(14, 2) not null default 0.00 check (total_cost >= 0),
  paid_amount numeric(14, 2) not null default 0.00 check (paid_amount >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'partial', 'paid')),
  due_date date,
  notes text,
  idempotency_key text unique,
  voided_at timestamptz,
  void_reason text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, invoice_number)
);

create or replace function public.sync_sale_fields()
returns trigger
language plpgsql
as $$
begin
  if new.invoice_no is null or new.invoice_no = '' then
    new.invoice_no := new.invoice_number;
  elsif new.invoice_number is null or new.invoice_number = '' then
    new.invoice_number := new.invoice_no;
  end if;

  if new.total = 0 and new.total_amount > 0 then
    new.total := new.total_amount;
  elsif new.total_amount = 0 and new.total > 0 then
    new.total_amount := new.total;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_sale_fields on public.sales;
create trigger trg_sync_sale_fields
  before insert or update on public.sales
  for each row execute function public.sync_sale_fields();

create index if not exists idx_sales_org_customer on public.sales (organization_id, customer_id);
create index if not exists idx_sales_org_date on public.sales (organization_id, sale_date desc);
create index if not exists idx_sales_status on public.sales (organization_id, status);

-- 2. Sale Items
create table if not exists public.sale_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(12, 2) not null check (quantity > 0),
  unit_price numeric(14, 2) not null check (unit_price >= 0),
  unit_cost numeric(14, 4) not null default 0.0000,
  discount_amount numeric(14, 2) not null default 0.00 check (discount_amount >= 0),
  total_amount numeric(14, 2) not null check (total_amount >= 0),
  created_at timestamptz not null default now()
);

create index if not exists idx_sale_items_sale on public.sale_items (sale_id);

-- 3. Customer & Unified Payments
create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete restrict,
  payment_type text not null default 'customer_payment' check (payment_type in ('customer_payment', 'supplier_payment', 'other')),
  payment_number text not null,
  payment_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  allocated_amount numeric(14, 2) not null default 0.00 check (allocated_amount >= 0),
  payment_method text not null default 'cash' check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  method text,
  reference_number text,
  notes text,
  status text not null default 'posted' check (status in ('posted', 'voided')),
  idempotency_key text unique,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, payment_number)
);

create or replace function public.sync_payment_fields()
returns trigger
language plpgsql
as $$
begin
  if new.method is null or new.method = '' then
    new.method := new.payment_method;
  elsif new.payment_method is null or new.payment_method = '' then
    new.payment_method := new.method;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_payment_fields on public.payments;
create trigger trg_sync_payment_fields
  before insert or update on public.payments
  for each row execute function public.sync_payment_fields();

create index if not exists idx_payments_org_customer on public.payments (organization_id, customer_id);

-- 4. Payment Allocations
create table if not exists public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_id uuid not null references public.payments(id) on delete cascade,
  sale_id uuid references public.sales(id) on delete cascade,
  document_type text not null default 'sale',
  document_id uuid,
  amount numeric(14, 2) not null default 0.00,
  allocated_amount numeric(14, 2) not null default 0.00 check (allocated_amount >= 0),
  created_at timestamptz not null default now()
);

create or replace function public.sync_payment_alloc_fields()
returns trigger
language plpgsql
as $$
begin
  if new.document_id is null and new.sale_id is not null then
    new.document_id := new.sale_id;
  elsif new.sale_id is null and new.document_id is not null and new.document_type = 'sale' then
    new.sale_id := new.document_id;
  end if;

  if new.amount = 0 and new.allocated_amount > 0 then
    new.amount := new.allocated_amount;
  elsif new.allocated_amount = 0 and new.amount > 0 then
    new.allocated_amount := new.amount;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_payment_alloc_fields on public.payment_allocations;
create trigger trg_sync_payment_alloc_fields
  before insert or update on public.payment_allocations
  for each row execute function public.sync_payment_alloc_fields();

create index if not exists idx_payment_alloc_sale on public.payment_allocations (sale_id);
create index if not exists idx_payment_alloc_doc on public.payment_allocations (document_type, document_id);

-- 5. Atomic RPC: Confirm Sale
create or replace function public.confirm_sale(
  p_org_id uuid,
  p_sale_id uuid,
  p_payment_method text default 'cash',
  p_amount_paid numeric default 0.00,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
  v_current_stock numeric(12, 2);
  v_total_cost numeric(14, 2) := 0.00;
  v_paid numeric(14, 2) := coalesce(p_amount_paid, 0.00);
  v_pay_status text;
  v_payment_id uuid;
  v_payment_num text;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  -- Check idempotency
  if p_idempotency_key is not null then
    select * into v_sale from public.sales where idempotency_key = p_idempotency_key;
    if found and v_sale.status = 'confirmed' then
      return jsonb_build_object('success', true, 'sale_id', v_sale.id, 'invoice_number', v_sale.invoice_number);
    end if;
  end if;

  -- Lock sale row
  select * into v_sale
  from public.sales
  where id = p_sale_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;

  if v_sale.status = 'confirmed' then
    raise exception 'Sale is already confirmed';
  end if;

  if v_sale.status in ('voided', 'reversed') then
    raise exception 'Cannot confirm a voided or reversed sale';
  end if;

  -- Stock check & Ledger movements
  for v_item in
    select si.*, p.sku, p.name as prod_name, p.average_cost as current_avg_cost
    from public.sale_items si
    join public.products p on p.id = si.product_id
    where si.sale_id = p_sale_id
  loop
    select coalesce(sum(quantity), 0.00) into v_current_stock
    from public.stock_movements
    where organization_id = p_org_id and product_id = v_item.product_id;

    if v_current_stock < v_item.quantity then
      raise exception 'Insufficient stock for product % (Available: %, Requested: %)',
        v_item.prod_name, v_current_stock, v_item.quantity;
    end if;

    -- Freeze unit cost at time of sale
    update public.sale_items
    set unit_cost = v_item.current_avg_cost
    where id = v_item.id;

    v_total_cost := v_total_cost + (v_item.quantity * v_item.current_avg_cost);

    -- Insert sales_out movement
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, created_by
    )
    values (
      p_org_id, v_item.product_id, 'sales_out', -v_item.quantity,
      v_item.current_avg_cost, 'sale', p_sale_id, v_user_id
    );
  end loop;

  -- Payment status calculation
  if v_paid >= v_sale.total_amount then
    v_pay_status := 'paid';
  elsif v_paid > 0 then
    v_pay_status := 'partial';
  else
    v_pay_status := 'unpaid';
  end if;

  -- Update sale
  update public.sales
  set status = 'confirmed',
      total_cost = v_total_cost,
      paid_amount = v_paid,
      payment_status = v_pay_status,
      idempotency_key = p_idempotency_key,
      updated_at = now()
  where id = p_sale_id;

  -- Record upfront payment if any
  if v_paid > 0 and v_sale.customer_id is not null then
    v_payment_num := public.next_document_number(p_org_id, 'customer_payment');
    insert into public.payments (
      organization_id, customer_id, payment_number, payment_date,
      amount, allocated_amount, payment_method, status, created_by
    )
    values (
      p_org_id, v_sale.customer_id, v_payment_num, current_date,
      v_paid, v_paid, p_payment_method, 'posted', v_user_id
    )
    returning id into v_payment_id;

    insert into public.payment_allocations (
      organization_id, payment_id, sale_id, allocated_amount
    )
    values (
      p_org_id, v_payment_id, p_sale_id, v_paid
    );
  end if;

  -- Log audit
  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id, payload
  )
  values (
    p_org_id, v_user_id, 'sale.confirm', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number, 'total', v_sale.total_amount, 'paid', v_paid)
  );

  return jsonb_build_object(
    'success', true,
    'sale_id', p_sale_id,
    'invoice_number', v_sale.invoice_number,
    'payment_status', v_pay_status
  );
end;
$$;

-- 6. Atomic RPC: Void / Reverse Sale
create or replace function public.void_or_reverse_sale(
  p_org_id uuid,
  p_sale_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
begin
  if not public.is_org_admin_or_owner(p_org_id) then
    raise exception 'Only Admins and Owners can void or reverse sales';
  end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id and organization_id = p_org_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;

  if v_sale.status in ('voided', 'reversed') then
    raise exception 'Sale is already voided or reversed';
  end if;

  -- If draft, simply mark voided
  if v_sale.status = 'draft' then
    update public.sales
    set status = 'voided', voided_at = now(), void_reason = p_reason, updated_at = now()
    where id = p_sale_id;

    return jsonb_build_object('success', true, 'status', 'voided');
  end if;

  -- If confirmed, perform compensatory stock reversal
  for v_item in select * from public.sale_items where sale_id = p_sale_id loop
    insert into public.stock_movements (
      organization_id, product_id, movement_type, quantity,
      unit_cost, reference_type, reference_id, notes, created_by
    )
    values (
      p_org_id, v_item.product_id, 'sale_reversal', v_item.quantity,
      v_item.unit_cost, 'sale', p_sale_id, 'Reversal: ' || coalesce(p_reason, 'No reason'), v_user_id
    );
  end loop;

  -- Mark status reversed
  update public.sales
  set status = 'reversed',
      voided_at = now(),
      void_reason = p_reason,
      updated_at = now()
  where id = p_sale_id;

  -- Log audit
  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id, payload
  )
  values (
    p_org_id, v_user_id, 'sale.reverse', 'sale', p_sale_id,
    jsonb_build_object('invoice_number', v_sale.invoice_number, 'reason', p_reason)
  );

  return jsonb_build_object('success', true, 'status', 'reversed');
end;
$$;

-- 7. Atomic RPC: Record Customer Payment and Allocate
create or replace function public.record_customer_payment_and_allocate(
  p_org_id uuid,
  p_customer_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_allocations jsonb,
  p_reference_number text default null,
  p_notes text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_payment_num text;
  v_payment_id uuid;
  v_total_allocated numeric(14, 2) := 0.00;
  v_alloc jsonb;
  v_sale_id uuid;
  v_alloc_amt numeric(14, 2);
  v_sale public.sales%rowtype;
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  if p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  v_payment_num := public.next_document_number(p_org_id, 'customer_payment');

  insert into public.payments (
    organization_id, customer_id, payment_number, payment_date,
    amount, allocated_amount, payment_method, reference_number,
    notes, status, idempotency_key, created_by
  )
  values (
    p_org_id, p_customer_id, v_payment_num, current_date,
    p_amount, 0.00, p_payment_method, p_reference_number,
    p_notes, 'posted', p_idempotency_key, v_user_id
  )
  returning id into v_payment_id;

  -- Process allocations
  if p_allocations is not null and jsonb_array_length(p_allocations) > 0 then
    for v_alloc in select * from jsonb_array_elements(p_allocations) loop
      v_sale_id := (v_alloc->>'sale_id')::uuid;
      v_alloc_amt := (v_alloc->>'amount')::numeric;

      if v_alloc_amt > 0 then
        select * into v_sale from public.sales where id = v_sale_id and organization_id = p_org_id for update;

        if found and v_sale.status = 'confirmed' then
          insert into public.payment_allocations (organization_id, payment_id, sale_id, allocated_amount)
          values (p_org_id, v_payment_id, v_sale_id, v_alloc_amt);

          v_total_allocated := v_total_allocated + v_alloc_amt;

          update public.sales
          set paid_amount = paid_amount + v_alloc_amt,
              payment_status = case
                when (paid_amount + v_alloc_amt) >= total_amount then 'paid'
                else 'partial'
              end,
              updated_at = now()
          where id = v_sale_id;
        end if;
      end if;
    end loop;
  end if;

  -- Update payment allocated amount
  update public.payments
  set allocated_amount = v_total_allocated
  where id = v_payment_id;

  return jsonb_build_object(
    'success', true,
    'payment_id', v_payment_id,
    'payment_number', v_payment_num,
    'allocated_amount', v_total_allocated
  );
end;
$$;

-- 8. Enable RLS
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;

create policy "Members can view sales"
  on public.sales for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage sales"
  on public.sales for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view sale items"
  on public.sale_items for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage sale items"
  on public.sale_items for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view payments"
  on public.payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can create payments"
  on public.payments for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view payment allocations"
  on public.payment_allocations for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can create allocations"
  on public.payment_allocations for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- ==============================================================================
-- Migration: 0007_expenses_and_finance.sql
-- Description: Operational expenses, expense categories, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant expense tables if they pre-exist
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'expense_categories'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'expense_categories' and column_name = 'organization_id'
  ) then
    drop table public.expense_categories cascade;
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'expenses'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'expenses' and column_name = 'organization_id'
  ) then
    drop table public.expenses cascade;
  end if;
end $$;

-- 1. Expense Categories
create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 100),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);

create index if not exists idx_exp_cat_org on public.expense_categories (organization_id);

-- 2. Expenses
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category text not null default 'General',
  category_id uuid references public.expense_categories(id) on delete set null,
  expense_date date not null default current_date,
  amount numeric(14, 2) not null check (amount > 0),
  payment_method text not null default 'cash' check (payment_method in ('cash', 'bank_transfer', 'mobile_money', 'kbz_pay', 'wave_pay', 'other')),
  title text not null check (length(btrim(title)) between 1 and 200),
  notes text,
  receipt_url text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Trigger to auto-sync category text from category_id if provided
create or replace function public.sync_expense_category_name()
returns trigger
language plpgsql
as $$
begin
  if new.category_id is not null and (new.category is null or new.category = 'General') then
    select name into new.category from public.expense_categories where id = new.category_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_expense_category_name on public.expenses;
create trigger trg_sync_expense_category_name
  before insert or update on public.expenses
  for each row execute function public.sync_expense_category_name();

create index if not exists idx_expenses_org_date on public.expenses (organization_id, expense_date desc);

-- 3. Enable RLS
alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;

create policy "Members can view expense categories"
  on public.expense_categories for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage expense categories"
  on public.expense_categories for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Members can view expenses"
  on public.expenses for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Staff+ can manage expenses"
  on public.expenses for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- ==============================================================================
-- Migration: 0008_subscriptions_and_limits.sql
-- Description: Plans, subscriptions, limits, payment verification, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant subscriptions table if it pre-exists
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'subscriptions'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'subscriptions' and column_name = 'organization_id'
  ) then
    drop table public.subscriptions cascade;
  end if;
end $$;

-- 1. SaaS Plans Master
create table if not exists public.plans (
  id text primary key,
  name text not null,
  price numeric(12, 2) not null default 15000.00,
  billing_interval text not null default 'month',
  monthly_price_mmk numeric(12, 2) not null,
  yearly_price_mmk numeric(12, 2) not null,
  trial_days integer not null default 14,
  max_users integer not null default 2,
  max_products integer not null default 100,
  max_monthly_sales integer not null default 200,
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true
);

-- Seed Initial Suggested Plans (Section 11)
insert into public.plans (id, name, price, billing_interval, monthly_price_mmk, yearly_price_mmk, trial_days, max_users, max_products, max_monthly_sales, features)
values
  ('starter', 'Starter Plan', 15000.00, 'month', 15000.00, 150000.00, 14, 2, 200, 300, '{"multi_user": true, "inventory": true, "basic_reports": true}'::jsonb),
  ('business', 'Business Plan', 30000.00, 'month', 30000.00, 300000.00, 14, 5, 1000, 1500, '{"multi_user": true, "inventory": true, "gross_profit": true, "customer_ledgers": true}'::jsonb),
  ('pro', 'Pro Plan', 60000.00, 'month', 60000.00, 600000.00, 14, 15, 5000, 10000, '{"multi_user": true, "inventory": true, "unlimited_reports": true, "priority_support": true, "api_access": true}'::jsonb)
on conflict (id) do update set
  price = excluded.price,
  billing_interval = excluded.billing_interval,
  monthly_price_mmk = excluded.monthly_price_mmk,
  yearly_price_mmk = excluded.yearly_price_mmk,
  max_users = excluded.max_users,
  max_products = excluded.max_products,
  max_monthly_sales = excluded.max_monthly_sales;

-- 2. Organization Subscriptions
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations(id) on delete cascade,
  plan_id text not null references public.plans(id) on delete restrict,
  status text not null check (status in ('trialing', 'active', 'past_due', 'expired', 'canceled')),
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly', 'yearly')),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null default (now() + interval '14 days'),
  trial_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.sync_subscription_dates()
returns trigger
language plpgsql
as $$
begin
  if new.starts_at is null then
    new.starts_at := new.current_period_start;
  else
    new.current_period_start := new.starts_at;
  end if;

  if new.expires_at is null then
    new.expires_at := new.current_period_end;
  else
    new.current_period_end := new.expires_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_subscription_dates on public.subscriptions;
create trigger trg_sync_subscription_dates
  before insert or update on public.subscriptions
  for each row execute function public.sync_subscription_dates();

create index if not exists idx_subscriptions_status on public.subscriptions (status);

-- 3. Subscription Events
create table if not exists public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_type text not null,
  amount numeric(12, 2),
  payment_method text,
  payment_reference text,
  admin_notes text,
  created_at timestamptz not null default now()
);

-- 4. Usage Limits
create table if not exists public.usage_limits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  metric text not null check (metric in ('user_count', 'product_count', 'monthly_sales_count')),
  period_key text not null,
  current_value integer not null default 0 check (current_value >= 0),
  limit_value integer not null,
  updated_at timestamptz not null default now(),
  unique (organization_id, metric, period_key)
);

-- 5. Atomic RPC: Initialize Trial for New Organization
create or replace function public.initialize_organization_trial(
  p_org_id uuid,
  p_plan_id text default 'starter'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.plans%rowtype;
  v_sub_id uuid;
  v_period_end timestamptz;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    select * into v_plan from public.plans where id = 'starter';
  end if;

  v_period_end := now() + (v_plan.trial_days || ' days')::interval;

  insert into public.subscriptions (
    organization_id, plan_id, status, billing_cycle,
    current_period_start, current_period_end, trial_ends_at
  )
  values (
    p_org_id, v_plan.id, 'trialing', 'monthly',
    now(), v_period_end, v_period_end
  )
  on conflict (organization_id) do update
  set updated_at = now()
  returning id into v_sub_id;

  -- Initialize Usage Limits
  insert into public.usage_limits (organization_id, metric, period_key, current_value, limit_value)
  values
    (p_org_id, 'product_count', 'lifetime', 0, v_plan.max_products),
    (p_org_id, 'user_count', 'lifetime', 1, v_plan.max_users),
    (p_org_id, 'monthly_sales_count', to_char(now(), 'YYYY-MM'), 0, v_plan.max_monthly_sales)
  on conflict (organization_id, metric, period_key) do nothing;

  -- Record event
  insert into public.subscription_events (
    subscription_id, organization_id, event_type, admin_notes
  )
  values (
    v_sub_id, p_org_id, 'trial_started', '14-day free trial initialized'
  );

  return v_sub_id;
end;
$$;

-- 6. Atomic RPC: Submit Manual Subscription Payment
create or replace function public.submit_subscription_payment(
  p_org_id uuid,
  p_plan_id text,
  p_billing_cycle text,
  p_payment_method text,
  p_reference_number text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_sub public.subscriptions%rowtype;
  v_plan public.plans%rowtype;
  v_amount numeric(12, 2);
begin
  if not public.is_org_admin_or_owner(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  select * into v_sub from public.subscriptions where organization_id = p_org_id;
  if not found then
    raise exception 'Subscription record not found';
  end if;

  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Invalid plan';
  end if;

  v_amount := case when p_billing_cycle = 'yearly' then v_plan.yearly_price_mmk else v_plan.monthly_price_mmk end;

  insert into public.subscription_events (
    subscription_id, organization_id, event_type, amount,
    payment_method, payment_reference, admin_notes
  )
  values (
    v_sub.id, p_org_id, 'payment_submitted', v_amount,
    p_payment_method, p_reference_number, p_notes
  );

  return jsonb_build_object(
    'success', true,
    'message', 'Payment submitted for platform admin verification'
  );
end;
$$;

-- 7. Platform Admin RPC: Verify and Activate Subscription
create or replace function public.verify_subscription_payment(
  p_sub_id uuid,
  p_event_id uuid,
  p_approve boolean,
  p_admin_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub public.subscriptions%rowtype;
  v_event public.subscription_events%rowtype;
  v_plan public.plans%rowtype;
  v_duration interval;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform admin privileges required';
  end if;

  select * into v_sub from public.subscriptions where id = p_sub_id;
  if not found then
    raise exception 'Subscription not found';
  end if;

  select * into v_event from public.subscription_events where id = p_event_id;
  if not found then
    raise exception 'Event not found';
  end if;

  if p_approve then
    select * into v_plan from public.plans where id = v_sub.plan_id;
    v_duration := case when v_sub.billing_cycle = 'yearly' then interval '1 year' else interval '1 month' end;

    update public.subscriptions
    set status = 'active',
        current_period_start = now(),
        current_period_end = now() + v_duration,
        updated_at = now()
    where id = p_sub_id;

    insert into public.subscription_events (
      subscription_id, organization_id, event_type, amount, admin_notes
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_approved', v_event.amount, p_admin_notes
    );

    return jsonb_build_object('success', true, 'status', 'active');
  else
    insert into public.subscription_events (
      subscription_id, organization_id, event_type, admin_notes
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_rejected', p_admin_notes
    );

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

-- 8. Enable RLS
alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.subscription_events enable row level security;
alter table public.usage_limits enable row level security;

-- Plans are public readable
create policy "Plans readable by all"
  on public.plans for select
  using (true);

-- Subscriptions RLS
create policy "Members view their subscription"
  on public.subscriptions for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Platform admin manage subscriptions"
  on public.subscriptions for all
  using (public.is_platform_admin());

-- Subscription Events RLS
create policy "Members view subscription events"
  on public.subscription_events for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Platform admin manage subscription events"
  on public.subscription_events for all
  using (public.is_platform_admin());

-- Usage Limits RLS
create policy "Members view usage limits"
  on public.usage_limits for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

-- ==============================================================================
-- Migration: 0009_reporting_views.sql
-- Description: Financial views for Customer Ledger, Supplier Ledger, Gross Profit, and Sales Summaries.
-- ==============================================================================

-- 1. Customer Outstanding Balance & Ledger Summary View
create or replace view public.customer_balances_summary as
select
  c.id as customer_id,
  c.organization_id,
  c.name as customer_name,
  c.phone,
  c.credit_limit,
  c.opening_balance,
  coalesce(sales_agg.total_sales, 0.00) as total_confirmed_sales,
  coalesce(pay_agg.total_payments, 0.00) as total_payments_received,
  (c.opening_balance + coalesce(sales_agg.total_sales, 0.00) - coalesce(pay_agg.total_payments, 0.00)) as current_balance
from public.customers c
left join (
  select customer_id, organization_id, sum(total_amount) as total_sales
  from public.sales
  where status = 'confirmed'
  group by customer_id, organization_id
) sales_agg on sales_agg.customer_id = c.id and sales_agg.organization_id = c.organization_id
left join (
  select customer_id, organization_id, sum(amount) as total_payments
  from public.payments
  where status = 'posted'
  group by customer_id, organization_id
) pay_agg on pay_agg.customer_id = c.id and pay_agg.organization_id = c.organization_id
where c.is_active = true;

-- 2. Supplier Outstanding Payable Summary View
create or replace view public.supplier_balances_summary as
select
  s.id as supplier_id,
  s.organization_id,
  s.name as supplier_name,
  s.phone,
  s.opening_balance,
  coalesce(purch_agg.total_purchases, 0.00) as total_received_purchases,
  coalesce(pay_agg.total_paid, 0.00) as total_payments_made,
  (s.opening_balance + coalesce(purch_agg.total_purchases, 0.00) - coalesce(pay_agg.total_paid, 0.00)) as current_payable
from public.suppliers s
left join (
  select supplier_id, organization_id, sum(total_amount) as total_purchases
  from public.purchases
  where status = 'received'
  group by supplier_id, organization_id
) purch_agg on purch_agg.supplier_id = s.id and purch_agg.organization_id = s.organization_id
left join (
  select supplier_id, organization_id, sum(amount) as total_paid
  from public.supplier_payments
  group by supplier_id, organization_id
) pay_agg on pay_agg.supplier_id = s.id and pay_agg.organization_id = s.organization_id
where s.is_active = true;

-- 3. Daily Sales & Gross Profit View
create or replace view public.daily_sales_performance as
select
  organization_id,
  sale_date,
  count(id) as total_invoices,
  sum(total_amount) as total_revenue,
  sum(total_cost) as total_cogs,
  sum(total_amount - total_cost) as gross_profit,
  case
    when sum(total_amount) > 0 then round(((sum(total_amount - total_cost) / sum(total_amount)) * 100), 2)
    else 0.00
  end as gross_margin_percentage
from public.sales
where status = 'confirmed'
group by organization_id, sale_date;

-- 4. Customer Detailed Transaction Ledger RPC
-- Dynamically returns chronological entries (opening, sales, payments, reversals)
create or replace function public.get_customer_statement(
  p_org_id uuid,
  p_customer_id uuid,
  p_start_date date default null,
  p_end_date date default null
)
returns table (
  transaction_date date,
  transaction_type text,
  reference_number text,
  description text,
  debit numeric(14, 2),
  credit numeric(14, 2),
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.has_org_membership(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  return query
  -- Sales (Debits - increases receivable)
  select
    s.sale_date as transaction_date,
    'Sale Invoice'::text as transaction_type,
    s.invoice_number as reference_number,
    'Confirmed Sale'::text as description,
    s.total_amount as debit,
    0.00::numeric(14, 2) as credit,
    s.created_at
  from public.sales s
  where s.organization_id = p_org_id
    and s.customer_id = p_customer_id
    and s.status = 'confirmed'
    and (p_start_date is null or s.sale_date >= p_start_date)
    and (p_end_date is null or s.sale_date <= p_end_date)

  union all

  -- Payments (Credits - decreases receivable)
  select
    p.payment_date as transaction_date,
    'Customer Payment'::text as transaction_type,
    p.payment_number as reference_number,
    coalesce(p.payment_method, 'Payment Received') as description,
    0.00::numeric(14, 2) as debit,
    p.amount as credit,
    p.created_at
  from public.payments p
  where p.organization_id = p_org_id
    and p.customer_id = p_customer_id
    and p.status = 'posted'
    and (p_start_date is null or p.payment_date >= p_start_date)
    and (p_end_date is null or p.payment_date <= p_end_date)

  order by transaction_date asc, created_at asc;
end;
$$;

-- ==============================================================================
-- Migration: 0010_automation_cron_jobs.sql
-- Description: Notification outbox, subscription expiration cron, and daily summaries.
-- ==============================================================================

-- 1. Notification Outbox Table (Outbox Pattern for Reliable Async Dispatch)
create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  notification_type text not null, -- 'trial_expiring', 'subscription_expired', 'daily_summary', 'low_stock'
  recipient_email text not null,
  subject text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed')),
  retry_count integer not null default 0,
  last_error text,
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notification_outbox_pending
  on public.notification_outbox (status, scheduled_at)
  where status = 'pending';

-- Enable RLS
alter table public.notification_outbox enable row level security;
create policy "Platform admin can manage outbox"
  on public.notification_outbox for all
  using (public.is_platform_admin());

-- 2. Stored Procedure: Check and Expire Subscriptions (Idempotent Daily Job)
create or replace function public.cron_check_expired_subscriptions()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expired_count integer := 0;
  v_rec record;
begin
  -- Find trialing subscriptions whose trial has ended
  for v_rec in
    select s.id, s.organization_id, o.name as org_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    where s.status = 'trialing'
      and s.trial_ends_at < now()
  loop
    update public.subscriptions
    set status = 'expired', updated_at = now()
    where id = v_rec.id;

    insert into public.subscription_events (
      subscription_id, organization_id, event_type, admin_notes
    )
    values (
      v_rec.id, v_rec.organization_id, 'expired', '14-day free trial expired automatically by cron'
    );

    v_expired_count := v_expired_count + 1;
  end loop;

  -- Find active subscriptions whose period has ended without renewal
  for v_rec in
    select s.id, s.organization_id, o.name as org_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    where s.status = 'active'
      and s.current_period_end < now()
  loop
    update public.subscriptions
    set status = 'past_due', updated_at = now()
    where id = v_rec.id;

    v_expired_count := v_expired_count + 1;
  end loop;

  return jsonb_build_object(
    'success', true,
    'expired_or_past_due_count', v_expired_count,
    'executed_at', now()
  );
end;
$$;

-- 3. Stored Procedure: Queue Daily Sales Outbox Notification
create or replace function public.cron_queue_daily_sales_summaries()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_summary record;
  v_queued_count integer := 0;
  v_owner_email text;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    -- Get today's sales
    select
      coalesce(count(id), 0) as total_sales,
      coalesce(sum(total_amount), 0.00) as revenue,
      coalesce(sum(total_amount - total_cost), 0.00) as profit
    into v_summary
    from public.sales
    where organization_id = v_org.id
      and status = 'confirmed'
      and sale_date = current_date;

    -- Find organization owner email
    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_org.id
      and om.role = 'owner'
      and om.is_active = true
    limit 1;

    if v_owner_email is not null and v_summary.total_sales > 0 then
      insert into public.notification_outbox (
        organization_id, notification_type, recipient_email, subject, payload
      )
      values (
        v_org.id,
        'daily_summary',
        v_owner_email,
        'ShopFlow: Daily Sales Report - ' || v_org.name,
        jsonb_build_object(
          'invoices_count', v_summary.total_sales,
          'revenue', v_summary.revenue,
          'profit', v_summary.profit,
          'date', current_date
        )
      );
      v_queued_count := v_queued_count + 1;
    end if;
  end loop;

  return jsonb_build_object('queued_summaries', v_queued_count);
end;
$$;

-- Notify PostgREST to reload schema cache
notify pgrst, 'reload schema';

