-- GENERATED FILE. Do not edit this snapshot directly.
-- Source of truth: supabase/migrations/*.sql in numeric order.
-- Regenerate with: node scripts/generate-schema-unified.mjs
-- Included migrations: 44

-- >>> BEGIN 0001_core_and_tenancy.sql
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
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'organizations'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'organizations' and column_name = 'slug'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;
end $$;

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
-- <<< END 0001_core_and_tenancy.sql

-- >>> BEGIN 0002_product_catalog.sql
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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0002_product_catalog.sql

-- >>> BEGIN 0003_customers_and_suppliers.sql
-- ==============================================================================
-- Migration: 0003_customers_and_suppliers.sql
-- Description: Customers and Suppliers directories with credit limits and balances.
-- ==============================================================================

-- Ensure organizations table is authoritative with slug, currency, timezone, is_active
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'organizations'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'organizations' and column_name = 'slug'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;
end $$;

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

alter table if exists public.organizations 
  add column if not exists slug text,
  add column if not exists is_active boolean not null default true,
  add column if not exists currency text not null default 'MMK',
  add column if not exists timezone text not null default 'Asia/Yangon',
  add column if not exists tax_id text;

alter table public.organizations enable row level security;

drop policy if exists "Members can view own organization" on public.organizations;
create policy "Members can view own organization"
  on public.organizations for select
  using (
    id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    ) or public.is_platform_admin()
  );

drop policy if exists "Authenticated users can create organization" on public.organizations;
create policy "Authenticated users can create organization"
  on public.organizations for insert
  with check (auth.role() = 'authenticated');

drop policy if exists "Admins and owners can update organization" on public.organizations;
create policy "Admins and owners can update organization"
  on public.organizations for update
  using (public.is_org_admin_or_owner(id) or public.is_platform_admin());

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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'suppliers'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'suppliers' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0003_customers_and_suppliers.sql

-- >>> BEGIN 0004_inventory_and_costing.sql
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
-- <<< END 0004_inventory_and_costing.sql

-- >>> BEGIN 0005_purchasing_and_payables.sql
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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'purchase_items'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'purchase_items' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'supplier_payments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'supplier_payments' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0005_purchasing_and_payables.sql

-- >>> BEGIN 0006_sales_and_receivables.sql
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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'sale_items'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'sale_items' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payments'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payments' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'payment_allocations'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'payment_allocations' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0006_sales_and_receivables.sql

-- >>> BEGIN 0007_expenses_and_finance.sql
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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
  end if;

  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'expenses'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'expenses' and column_name = 'organization_id'
  ) then
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0007_expenses_and_finance.sql

-- >>> BEGIN 0008_subscriptions_and_limits.sql
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
    raise exception 'Refusing destructive legacy schema replacement; migrate existing business data before applying this schema.';
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
-- <<< END 0008_subscriptions_and_limits.sql

-- >>> BEGIN 0009_reporting_views.sql
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
-- <<< END 0009_reporting_views.sql

-- >>> BEGIN 0010_automation_cron_jobs.sql
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
-- <<< END 0010_automation_cron_jobs.sql

-- >>> BEGIN 0011_add_slug_to_organizations.sql
-- ==============================================================================
-- Migration: 0011_add_slug_to_organizations.sql
-- Description: Ensure organizations table has slug, currency, timezone, is_active.
-- ==============================================================================

alter table public.organizations 
  add column if not exists slug text,
  add column if not exists currency text not null default 'MMK',
  add column if not exists timezone text not null default 'Asia/Yangon',
  add column if not exists tax_id text,
  add column if not exists is_active boolean not null default true;

-- Ensure unique constraint on slug if not exists
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'organizations_slug_key'
  ) then
    alter table public.organizations add constraint organizations_slug_key unique (slug);
  end if;
end $$;

-- Enable RLS and insert policy for authenticated users
alter table public.organizations enable row level security;

drop policy if exists "Authenticated users can create organization" on public.organizations;
drop policy if exists "Authenticated users can create organizations" on public.organizations;
create policy "Authenticated users can create organization"
  on public.organizations for insert
  with check (auth.role() = 'authenticated');

drop policy if exists "Members can view own organization" on public.organizations;
drop policy if exists "Members can view their organizations" on public.organizations;
create policy "Members can view own organization"
  on public.organizations for select
  using (
    id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    )
    or public.is_platform_admin()
    or auth.role() = 'authenticated'
  );

drop policy if exists "Admins and owners can update organization" on public.organizations;
drop policy if exists "Owners and Admins can update organization" on public.organizations;
create policy "Admins and owners can update organization"
  on public.organizations for update
  using (public.is_org_admin_or_owner(id) or public.is_platform_admin());

-- Atomic Onboarding RPC: create_organization_with_owner
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text,
  p_plan_id text default 'starter',
  p_phone text default null,
  p_address text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_org_id uuid;
  v_org record;
begin
  if v_user_id is null then
    raise exception 'Unauthorized: user must be authenticated';
  end if;

  -- 1. Create organization
  insert into public.organizations (name, slug, currency, timezone, is_active)
  values (btrim(p_name), btrim(p_slug), 'MMK', 'Asia/Yangon', true)
  returning id into v_org_id;

  -- 2. Add creator as owner
  insert into public.organization_members (organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'owner', true);

  -- 3. Create settings
  insert into public.organization_settings (
    organization_id, currency_code, currency_symbol, timezone, phone, address, costing_method, low_stock_threshold_default
  )
  values (
    v_org_id, 'MMK', 'Ks', 'Asia/Yangon', p_phone, p_address, 'weighted_average', 5
  )
  on conflict (organization_id) do nothing;

  -- 4. Initialize trial
  begin
    perform public.initialize_organization_trial(v_org_id, p_plan_id);
  exception when others then
    null;
  end;

  -- 5. Seed default units
  insert into public.units (organization_id, code, name, precision)
  values
    (v_org_id, 'pcs', 'Pieces (ခု)', 0),
    (v_org_id, 'box', 'Box (ဖာ)', 0),
    (v_org_id, 'pack', 'Packet (ထုပ်)', 0),
    (v_org_id, 'dozen', 'Dozen (ဒါဇင်)', 0)
  on conflict do nothing;

  select id, name, slug, currency, timezone, is_active into v_org
  from public.organizations where id = v_org_id;

  return to_jsonb(v_org);
end;
$$;

-- Force PostgREST schema cache reload
notify pgrst, 'reload schema';
-- <<< END 0011_add_slug_to_organizations.sql

-- >>> BEGIN 0012_create_organization_rpc.sql
-- ==============================================================================
-- Migration: 0012_create_organization_rpc.sql
-- Description: Atomic onboarding RPC and select policy for organizations.
-- ==============================================================================

-- Allow authenticated users to view newly created organizations during onboarding
drop policy if exists "Members can view own organization" on public.organizations;
drop policy if exists "Members can view their organizations" on public.organizations;
create policy "Members can view own organization"
  on public.organizations for select
  using (
    id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    )
    or public.is_platform_admin()
    or auth.role() = 'authenticated'
  );

-- Atomic Onboarding RPC: create_organization_with_owner
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text,
  p_plan_id text default 'starter',
  p_phone text default null,
  p_address text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_org_id uuid;
  v_org record;
begin
  if v_user_id is null then
    raise exception 'Unauthorized: user must be authenticated';
  end if;

  -- 1. Create organization
  insert into public.organizations (name, slug, currency, timezone, is_active)
  values (btrim(p_name), btrim(p_slug), 'MMK', 'Asia/Yangon', true)
  returning id into v_org_id;

  -- 2. Add creator as owner
  insert into public.organization_members (organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'owner', true);

  -- 3. Create settings
  insert into public.organization_settings (
    organization_id, currency_code, currency_symbol, timezone, phone, address, costing_method, low_stock_threshold_default
  )
  values (
    v_org_id, 'MMK', 'Ks', 'Asia/Yangon', p_phone, p_address, 'weighted_average', 5
  )
  on conflict (organization_id) do nothing;

  -- 4. Initialize trial
  begin
    perform public.initialize_organization_trial(v_org_id, p_plan_id);
  exception when others then
    null;
  end;

  -- 5. Seed default units
  insert into public.units (organization_id, code, name, precision)
  values
    (v_org_id, 'pcs', 'Pieces (ခု)', 0),
    (v_org_id, 'box', 'Box (ဖာ)', 0),
    (v_org_id, 'pack', 'Packet (ထုပ်)', 0),
    (v_org_id, 'dozen', 'Dozen (ဒါဇင်)', 0)
  on conflict do nothing;

  select id, name, slug, currency, timezone, is_active into v_org
  from public.organizations where id = v_org_id;

  return to_jsonb(v_org);
end;
$$;

-- Force PostgREST schema cache reload
notify pgrst, 'reload schema';
-- <<< END 0012_create_organization_rpc.sql

-- >>> BEGIN 0013_fix_member_select_policy.sql
-- ==============================================================================
-- Migration: 0013_fix_member_select_policy.sql
-- Description: Allow users to view their own memberships in organization_members.
-- ==============================================================================

drop policy if exists "Members can view members of their organization" on public.organization_members;
create policy "Members can view members of their organization"
  on public.organization_members for select
  using (
    user_id = auth.uid()
    or public.has_org_membership(organization_id)
    or public.is_platform_admin()
  );

drop policy if exists "Members can view organization settings" on public.organization_settings;
create policy "Members can view organization settings"
  on public.organization_settings for select
  using (
    organization_id in (
      select organization_id from public.organization_members
      where user_id = auth.uid() and is_active = true
    )
    or public.is_platform_admin()
    or auth.role() = 'authenticated'
  );

-- Reload schema cache
notify pgrst, 'reload schema';
-- <<< END 0013_fix_member_select_policy.sql

-- >>> BEGIN 0014_backfill_profiles_and_fix_rpc.sql
-- ==============================================================================
-- Migration: 0014_backfill_profiles_and_fix_rpc.sql
-- Description: Backfill profiles for existing auth.users and ensure profile existence in onboarding RPC.
-- ==============================================================================

-- 1. Backfill all existing auth.users into public.profiles
insert into public.profiles (id, full_name, email, phone_number)
select
  id,
  coalesce(raw_user_meta_data->>'full_name', split_part(email, '@', 1), 'User'),
  email,
  raw_user_meta_data->>'phone_number'
from auth.users
on conflict (id) do update
set email = coalesce(excluded.email, public.profiles.email);

-- 2. Update create_organization_with_owner to auto-create profile if missing
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text,
  p_plan_id text default 'starter',
  p_phone text default null,
  p_address text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_user_email text;
  v_user_name text;
  v_org_id uuid;
  v_org record;
begin
  if v_user_id is null then
    raise exception 'Unauthorized: user must be authenticated';
  end if;

  -- Ensure profile exists for this user
  select email, coalesce(raw_user_meta_data->>'full_name', split_part(email, '@', 1), 'Owner')
  into v_user_email, v_user_name
  from auth.users where id = v_user_id;

  insert into public.profiles (id, full_name, email)
  values (v_user_id, coalesce(v_user_name, 'Owner'), v_user_email)
  on conflict (id) do update
  set email = coalesce(excluded.email, public.profiles.email);

  -- 1. Create organization
  insert into public.organizations (name, slug, currency, timezone, is_active)
  values (btrim(p_name), btrim(p_slug), 'MMK', 'Asia/Yangon', true)
  returning id into v_org_id;

  -- 2. Add creator as owner
  insert into public.organization_members (organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'owner', true);

  -- 3. Create settings
  insert into public.organization_settings (
    organization_id, currency_code, currency_symbol, timezone, phone, address, costing_method, low_stock_threshold_default
  )
  values (
    v_org_id, 'MMK', 'Ks', 'Asia/Yangon', p_phone, p_address, 'weighted_average', 5
  )
  on conflict (organization_id) do nothing;

  -- 4. Initialize trial
  begin
    perform public.initialize_organization_trial(v_org_id, p_plan_id);
  exception when others then
    null;
  end;

  -- 5. Seed default units
  insert into public.units (organization_id, code, name, precision)
  values
    (v_org_id, 'pcs', 'Pieces (ခု)', 0),
    (v_org_id, 'box', 'Box (ဖာ)', 0),
    (v_org_id, 'pack', 'Packet (ထုပ်)', 0),
    (v_org_id, 'dozen', 'Dozen (ဒါဇင်)', 0)
  on conflict do nothing;

  select id, name, slug, currency, timezone, is_active into v_org
  from public.organizations where id = v_org_id;

  return to_jsonb(v_org);
end;
$$;

-- Force PostgREST schema cache reload
notify pgrst, 'reload schema';
-- <<< END 0014_backfill_profiles_and_fix_rpc.sql

-- >>> BEGIN 0015_grant_superadmin_and_tenant_management.sql
-- ==============================================================================
-- Migration: 0015_grant_superadmin_and_tenant_management.sql
-- Description: Grant superadmin privileges and add tenant management RPCs.
-- ==============================================================================

-- 1. Grant platform super-admin to all existing users (or first user) in development/launch phase
update public.profiles
set is_platform_admin = true
where id in (select id from auth.users);

-- 2. Allow superadmins to toggle organization status (suspend / activate tenant)
create or replace function public.admin_toggle_organization_status(
  p_org_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Unauthorized: Only platform super-admins can toggle organization status';
  end if;

  update public.organizations
  set is_active = p_is_active,
      updated_at = now()
  where id = p_org_id;

  -- Record audit log
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, payload)
  values (
    p_org_id,
    auth.uid(),
    case when p_is_active then 'tenant_activated' else 'tenant_suspended' end,
    'organization',
    p_org_id,
    jsonb_build_object('is_active', p_is_active)
  );
end;
$$;

-- 3. Superadmin view of all organizations with member counts and metrics
create or replace function public.admin_get_platform_metrics()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total_orgs integer;
  v_active_orgs integer;
  v_suspended_orgs integer;
  v_total_users integer;
  v_total_sales_count bigint;
begin
  if not public.is_platform_admin() then
    raise exception 'Unauthorized: Only platform super-admins can view platform metrics';
  end if;

  select count(*) into v_total_orgs from public.organizations;
  select count(*) into v_active_orgs from public.organizations where is_active = true;
  select count(*) into v_suspended_orgs from public.organizations where is_active = false;
  select count(*) into v_total_users from public.profiles;
  select count(*) into v_total_sales_count from public.sales;

  return jsonb_build_object(
    'total_organizations', coalesce(v_total_orgs, 0),
    'active_organizations', coalesce(v_active_orgs, 0),
    'suspended_organizations', coalesce(v_suspended_orgs, 0),
    'total_users', coalesce(v_total_users, 0),
    'total_sales_count', coalesce(v_total_sales_count, 0)
  );
end;
$$;

-- Reload schema cache
notify pgrst, 'reload schema';
-- <<< END 0015_grant_superadmin_and_tenant_management.sql

-- >>> BEGIN 0016_fix_subscription_plan_change.sql
-- ==============================================================================
-- Migration: 0016_fix_subscription_plan_change.sql
-- Description: Fix plan updating on payment verification and add admin plan modification.
-- ==============================================================================

-- 1. Add plan_id and billing_cycle columns to subscription_events if missing
alter table public.subscription_events
  add column if not exists plan_id text references public.plans(id),
  add column if not exists billing_cycle text default 'monthly';

-- 2. Update submit_subscription_payment to save plan_id and billing_cycle
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
  v_sub public.subscriptions%rowtype;
  v_plan public.plans%rowtype;
  v_amount numeric(12, 2);
begin
  if not (public.is_org_admin_or_owner(p_org_id) or public.is_platform_admin()) then
    raise exception 'Unauthorized to submit subscription payment';
  end if;

  select * into v_sub from public.subscriptions where organization_id = p_org_id;
  if not found then
    raise exception 'Subscription record not found for this organization';
  end if;

  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Invalid plan identifier: %', p_plan_id;
  end if;

  v_amount := case when p_billing_cycle = 'yearly' then v_plan.yearly_price_mmk else v_plan.monthly_price_mmk end;

  insert into public.subscription_events (
    subscription_id, organization_id, event_type, amount,
    payment_method, payment_reference, admin_notes, plan_id, billing_cycle
  )
  values (
    v_sub.id, p_org_id, 'payment_submitted', v_amount,
    p_payment_method, p_reference_number, p_notes, p_plan_id, coalesce(p_billing_cycle, 'monthly')
  );

  return jsonb_build_object(
    'success', true,
    'message', 'Payment submitted for platform admin verification',
    'plan_id', p_plan_id,
    'amount', v_amount
  );
end;
$$;

-- 3. Update verify_subscription_payment to update plan_id, billing_cycle and usage_limits
create or replace function public.verify_subscription_payment(
  p_sub_id uuid,
  p_event_id uuid,
  p_approve boolean,
  p_admin_notes text default null,
  p_target_plan_id text default null
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
  v_target_plan_id text;
  v_target_cycle text;
  v_duration interval;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform super-admin privileges required';
  end if;

  select * into v_sub from public.subscriptions where id = p_sub_id;
  if not found then
    raise exception 'Subscription not found: %', p_sub_id;
  end if;

  select * into v_event from public.subscription_events where id = p_event_id;
  if not found then
    raise exception 'Subscription event not found: %', p_event_id;
  end if;

  if p_approve then
    -- Determine target plan: priority is explicit admin override, then event plan_id, then current plan
    v_target_plan_id := coalesce(p_target_plan_id, v_event.plan_id, v_sub.plan_id);
    v_target_cycle := coalesce(v_event.billing_cycle, v_sub.billing_cycle, 'monthly');

    select * into v_plan from public.plans where id = v_target_plan_id;
    if not found then
      raise exception 'Plan % not found', v_target_plan_id;
    end if;

    v_duration := case when v_target_cycle = 'yearly' then interval '1 year' else interval '1 month' end;

    -- Update subscription record with the new plan and renewed period
    update public.subscriptions
    set plan_id = v_target_plan_id,
        billing_cycle = v_target_cycle,
        status = 'active',
        current_period_start = now(),
        current_period_end = now() + v_duration,
        starts_at = coalesce(starts_at, now()),
        expires_at = now() + v_duration,
        updated_at = now()
    where id = p_sub_id;

    -- Update organization usage limits to match new plan's quotas
    update public.usage_limits
    set limit_value = v_plan.max_products, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'product_count';

    update public.usage_limits
    set limit_value = v_plan.max_users, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'user_count';

    update public.usage_limits
    set limit_value = v_plan.max_monthly_sales, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'monthly_sales_count';

    -- Record approval event with activated plan
    insert into public.subscription_events (
      subscription_id, organization_id, event_type, amount, admin_notes, plan_id, billing_cycle
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_approved', v_event.amount, p_admin_notes, v_target_plan_id, v_target_cycle
    );

    -- Log audit trail
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, payload)
    values (
      v_sub.organization_id,
      auth.uid(),
      'subscription_activated',
      'subscription',
      p_sub_id,
      jsonb_build_object('plan_id', v_target_plan_id, 'billing_cycle', v_target_cycle, 'amount', v_event.amount)
    );

    return jsonb_build_object(
      'success', true,
      'status', 'active',
      'plan_id', v_target_plan_id,
      'current_period_end', (now() + v_duration)
    );
  else
    insert into public.subscription_events (
      subscription_id, organization_id, event_type, admin_notes, plan_id
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_rejected', p_admin_notes, v_event.plan_id
    );

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

-- 4. Admin RPC to directly change or grant any plan to an organization
create or replace function public.admin_change_organization_plan(
  p_org_id uuid,
  p_plan_id text,
  p_status text default 'active',
  p_duration_months integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.plans%rowtype;
  v_sub_id uuid;
  v_duration interval;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform super-admin privileges required';
  end if;

  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Plan % not found', p_plan_id;
  end if;

  v_duration := (p_duration_months || ' months')::interval;

  -- Upsert subscription
  insert into public.subscriptions (
    organization_id, plan_id, status, billing_cycle,
    current_period_start, current_period_end, starts_at, expires_at
  )
  values (
    p_org_id, p_plan_id, p_status, 'monthly',
    now(), now() + v_duration, now(), now() + v_duration
  )
  on conflict (organization_id) do update
  set plan_id = p_plan_id,
      status = p_status,
      current_period_start = now(),
      current_period_end = now() + v_duration,
      expires_at = now() + v_duration,
      updated_at = now()
  returning id into v_sub_id;

  -- Update usage limits
  insert into public.usage_limits (organization_id, metric, period_key, current_value, limit_value)
  values
    (p_org_id, 'product_count', 'lifetime', 0, v_plan.max_products),
    (p_org_id, 'user_count', 'lifetime', 1, v_plan.max_users),
    (p_org_id, 'monthly_sales_count', to_char(now(), 'YYYY-MM'), 0, v_plan.max_monthly_sales)
  on conflict (organization_id, metric, period_key) do update
  set limit_value = excluded.limit_value, updated_at = now();

  -- Record event
  insert into public.subscription_events (
    subscription_id, organization_id, event_type, admin_notes, plan_id
  )
  values (
    v_sub_id, p_org_id, 'admin_plan_override', 'Plan modified directly by super-admin to ' || v_plan.name, p_plan_id
  );

  return jsonb_build_object(
    'success', true,
    'organization_id', p_org_id,
    'plan_id', p_plan_id,
    'plan_name', v_plan.name,
    'status', p_status
  );
end;
$$;

-- Reload schema cache
notify pgrst, 'reload schema';
-- <<< END 0016_fix_subscription_plan_change.sql

-- >>> BEGIN 0017_transition_subscription_events.sql
-- ==============================================================================
-- Migration: 0017_transition_subscription_events.sql
-- Description: Transition payment_submitted event status to approved/rejected and disable duplicate actions.
-- ==============================================================================

-- 1. Update verify_subscription_payment to update existing event directly
create or replace function public.verify_subscription_payment(
  p_sub_id uuid,
  p_event_id uuid,
  p_approve boolean,
  p_admin_notes text default null,
  p_target_plan_id text default null
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
  v_target_plan_id text;
  v_target_cycle text;
  v_duration interval;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform super-admin privileges required';
  end if;

  select * into v_sub from public.subscriptions where id = p_sub_id;
  if not found then
    raise exception 'Subscription not found: %', p_sub_id;
  end if;

  select * into v_event from public.subscription_events where id = p_event_id;
  if not found then
    raise exception 'Subscription event not found: %', p_event_id;
  end if;

  if v_event.event_type not in ('payment_submitted', 'payment_pending') then
    raise exception 'This payment event has already been processed (current status: %)', v_event.event_type;
  end if;

  if p_approve then
    -- Determine target plan: priority is explicit admin override, then event plan_id, then current plan
    v_target_plan_id := coalesce(p_target_plan_id, v_event.plan_id, v_sub.plan_id);
    v_target_cycle := coalesce(v_event.billing_cycle, v_sub.billing_cycle, 'monthly');

    select * into v_plan from public.plans where id = v_target_plan_id;
    if not found then
      raise exception 'Plan % not found', v_target_plan_id;
    end if;

    v_duration := case when v_target_cycle = 'yearly' then interval '1 year' else interval '1 month' end;

    -- Update subscription record
    update public.subscriptions
    set plan_id = v_target_plan_id,
        billing_cycle = v_target_cycle,
        status = 'active',
        current_period_start = now(),
        current_period_end = now() + v_duration,
        starts_at = coalesce(starts_at, now()),
        expires_at = now() + v_duration,
        updated_at = now()
    where id = p_sub_id;

    -- Update organization usage limits to match new plan's quotas
    update public.usage_limits
    set limit_value = v_plan.max_products, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'product_count';

    update public.usage_limits
    set limit_value = v_plan.max_users, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'user_count';

    update public.usage_limits
    set limit_value = v_plan.max_monthly_sales, updated_at = now()
    where organization_id = v_sub.organization_id and metric = 'monthly_sales_count';

    -- Mark the submitted event as approved directly
    update public.subscription_events
    set event_type = 'payment_approved',
        admin_notes = coalesce(p_admin_notes, admin_notes),
        plan_id = v_target_plan_id,
        billing_cycle = v_target_cycle
    where id = p_event_id;

    -- Log audit trail
    insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, payload)
    values (
      v_sub.organization_id,
      auth.uid(),
      'subscription_activated',
      'subscription',
      p_sub_id,
      jsonb_build_object('plan_id', v_target_plan_id, 'billing_cycle', v_target_cycle, 'amount', v_event.amount)
    );

    return jsonb_build_object(
      'success', true,
      'status', 'active',
      'plan_id', v_target_plan_id,
      'current_period_end', (now() + v_duration)
    );
  else
    -- Mark the submitted event as rejected directly
    update public.subscription_events
    set event_type = 'payment_rejected',
        admin_notes = coalesce(p_admin_notes, admin_notes)
    where id = p_event_id;

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

-- 2. Cleanup any orphaned duplicate payment_submitted events where payment_approved already exists for the same amount
update public.subscription_events se1
set event_type = 'payment_approved'
where se1.event_type = 'payment_submitted'
  and exists (
    select 1 from public.subscription_events se2
    where se2.subscription_id = se1.subscription_id
      and se2.event_type = 'payment_approved'
      and se2.created_at >= se1.created_at
  );

-- Reload schema cache
notify pgrst, 'reload schema';
-- <<< END 0017_transition_subscription_events.sql

-- >>> BEGIN 0018_complete_automation_layers.sql
-- ==============================================================================
-- Migration: 0018_complete_automation_layers.sql
-- Description: Complete 4-layer automation schema (Low Stock, Renewal Reminders, Plan Limits, MRR, Weekly Summaries).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- LAYER 2: Business Automation - Low Stock Alerts Outbox
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_low_stock_alerts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_owner_email text;
  v_low_items jsonb;
  v_queued integer := 0;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    -- Collect products where stock <= low_stock_threshold
    select jsonb_agg(
      jsonb_build_object(
        'name', name,
        'sku', sku,
        'stock_on_hand', stock_on_hand,
        'threshold', low_stock_threshold,
        'unit', unit_code
      )
    ) into v_low_items
    from public.product_stock_balances
    where organization_id = v_org.id and is_low_stock = true;

    if v_low_items is not null and jsonb_array_length(v_low_items) > 0 then
      select u.email into v_owner_email
      from public.organization_members om
      join auth.users u on u.id = om.user_id
      where om.organization_id = v_org.id and om.role = 'owner' and om.is_active = true
      limit 1;

      if v_owner_email is not null then
        insert into public.notification_outbox (
          organization_id, notification_type, recipient_email, subject, payload
        )
        values (
          v_org.id,
          'low_stock',
          v_owner_email,
          'ShopFlow: Low Stock Warning (' || jsonb_array_length(v_low_items) || ' items) - ' || v_org.name,
          jsonb_build_object(
            'item_count', jsonb_array_length(v_low_items),
            'items', v_low_items,
            'alert_time', now()
          )
        );
        v_queued := v_queued + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('queued_low_stock_alerts', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- LAYER 3: SaaS Automation - Subscription Renewal Reminders
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_subscription_renewal_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub record;
  v_owner_email text;
  v_queued integer := 0;
  v_days_left integer;
begin
  for v_sub in
    select s.id, s.organization_id, s.status, s.current_period_end, o.name as org_name, p.name as plan_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    join public.plans p on p.id = s.plan_id
    where s.status in ('active', 'trialing')
      and s.current_period_end between now() and (now() + interval '3 days')
  loop
    v_days_left := greatest(0, extract(day from (v_sub.current_period_end - now()))::integer);

    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_sub.organization_id and om.role = 'owner' and om.is_active = true
    limit 1;

    if v_owner_email is not null then
      -- Avoid queueing duplicate reminder within same 24 hours
      if not exists (
        select 1 from public.notification_outbox
        where organization_id = v_sub.organization_id
          and notification_type = 'subscription_renewal_reminder'
          and created_at > (now() - interval '24 hours')
      ) then
        insert into public.notification_outbox (
          organization_id, notification_type, recipient_email, subject, payload
        )
        values (
          v_sub.organization_id,
          'subscription_renewal_reminder',
          v_owner_email,
          'ShopFlow: Subscription Renewal Notice (' || v_days_left || ' days left) - ' || v_sub.org_name,
          jsonb_build_object(
            'plan_name', v_sub.plan_name,
            'days_left', v_days_left,
            'expires_at', v_sub.current_period_end
          )
        );
        v_queued := v_queued + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('queued_renewal_reminders', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- LAYER 3: SaaS Automation - Plan Limit Enforcement on Product Creation
-- ------------------------------------------------------------------------------
create or replace function public.enforce_product_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer;
  v_current_count integer;
begin
  select limit_value into v_limit
  from public.usage_limits
  where organization_id = new.organization_id and metric = 'product_count';

  if v_limit is not null and v_limit > 0 then
    select count(*) into v_current_count
    from public.products
    where organization_id = new.organization_id and is_active = true;

    if v_current_count >= v_limit then
      raise exception 'Plan limit exceeded: Your organization has reached the maximum of % products allowed on your current plan. Please upgrade to add more products.', v_limit;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit
  before insert on public.products
  for each row execute function public.enforce_product_plan_limit();

-- ------------------------------------------------------------------------------
-- LAYER 4: Business Owner Automation - New Customer Notification Trigger
-- ------------------------------------------------------------------------------
create or replace function public.on_customer_created_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, payload)
  values (
    new.organization_id,
    auth.uid(),
    'customer_created',
    'customer',
    new.id,
    jsonb_build_object('name', new.name, 'phone', new.phone, 'credit_limit', new.credit_limit)
  );
  return new;
end;
$$;

drop trigger if exists trg_customer_created_audit on public.customers;
create trigger trg_customer_created_audit
  after insert on public.customers
  for each row execute function public.on_customer_created_audit();

-- ------------------------------------------------------------------------------
-- LAYER 4: Business Owner Automation - Weekly Business Summary Outbox
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_weekly_business_summary()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_owner_email text;
  v_weekly_sales numeric;
  v_weekly_profit numeric;
  v_invoice_count integer;
  v_queued integer := 0;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    select
      coalesce(sum(total_amount), 0.00),
      coalesce(sum(total_amount - total_cost), 0.00),
      count(id)
    into v_weekly_sales, v_weekly_profit, v_invoice_count
    from public.sales
    where organization_id = v_org.id
      and status = 'confirmed'
      and sale_date >= (current_date - interval '7 days');

    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_org.id and om.role = 'owner' and om.is_active = true
    limit 1;

    if v_owner_email is not null and v_invoice_count > 0 then
      insert into public.notification_outbox (
        organization_id, notification_type, recipient_email, subject, payload
      )
      values (
        v_org.id,
        'weekly_summary',
        v_owner_email,
        'ShopFlow: Weekly Performance Summary - ' || v_org.name,
        jsonb_build_object(
          'invoices_count', v_invoice_count,
          'weekly_revenue', v_weekly_sales,
          'weekly_gross_profit', v_weekly_profit,
          'start_date', current_date - interval '7 days',
          'end_date', current_date
        )
      );
      v_queued := v_queued + 1;
    end if;
  end loop;

  return jsonb_build_object('queued_weekly_summaries', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- MASTER AUTOMATION RUNNER: Executes all cron checks in one atomic invocation
-- ------------------------------------------------------------------------------
create or replace function public.cron_run_all_automations()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expired jsonb;
  v_daily jsonb;
  v_low_stock jsonb;
  v_renewals jsonb;
  v_weekly jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform super-admin privileges required to trigger automation runner';
  end if;

  v_expired := public.cron_check_expired_subscriptions();
  v_daily := public.cron_queue_daily_sales_summaries();
  v_low_stock := public.cron_queue_low_stock_alerts();
  v_renewals := public.cron_queue_subscription_renewal_reminders();
  v_weekly := public.cron_queue_weekly_business_summary();

  return jsonb_build_object(
    'executed_at', now(),
    'subscriptions_checked', v_expired,
    'daily_summaries', v_daily,
    'low_stock_alerts', v_low_stock,
    'renewal_reminders', v_renewals,
    'weekly_summaries', v_weekly
  );
end;
$$;

-- Reload schema cache
notify pgrst, 'reload schema';
-- <<< END 0018_complete_automation_layers.sql

-- >>> BEGIN 0019_plan_feature_system.sql
-- ==============================================================================
-- Migration: 0019_plan_feature_system.sql
-- Description: Normalized plan-feature tables, subscription_payments,
--              subscription_usage, subscription_audit_logs, org overrides.
-- ==============================================================================

-- -------------------------------------------------------------------------
-- A. Extend existing plans table (keep text PK)
-- -------------------------------------------------------------------------
alter table public.plans
  add column if not exists slug text unique,
  add column if not exists description text,
  add column if not exists currency text not null default 'MMK',
  add column if not exists is_public boolean not null default true,
  add column if not exists display_order integer not null default 0,
  add column if not exists max_customers integer not null default 100,
  add column if not exists max_suppliers integer not null default 20,
  add column if not exists max_branches integer not null default 1,
  add column if not exists updated_at timestamptz not null default now();

-- Back-fill slug
update public.plans set slug = id where slug is null;

-- Correct limits to match spec
update public.plans set
  name             = 'Starter',
  description      = 'Perfect for small retail shops getting started.',
  slug             = 'starter',
  display_order    = 1,
  monthly_price_mmk = 15000.00,
  yearly_price_mmk  = 150000.00,
  max_users        = 1,
  max_products     = 100,
  max_customers    = 100,
  max_suppliers    = 20,
  max_branches     = 1,
  is_active        = true,
  is_public        = true
where id = 'starter';

update public.plans set
  name             = 'Business',
  description      = 'For wholesale shops and businesses selling on credit.',
  slug             = 'business',
  display_order    = 2,
  monthly_price_mmk = 30000.00,
  yearly_price_mmk  = 300000.00,
  max_users        = 3,
  max_products     = 2000,
  max_customers    = -1,
  max_suppliers    = -1,
  max_branches     = 2,
  is_active        = true,
  is_public        = true
where id = 'business';

update public.plans set
  name             = 'Pro',
  description      = 'For growing businesses with multiple branches and employees.',
  slug             = 'pro',
  display_order    = 3,
  monthly_price_mmk = 60000.00,
  yearly_price_mmk  = 600000.00,
  max_users        = 10,
  max_products     = -1,
  max_customers    = -1,
  max_suppliers    = -1,
  max_branches     = 5,
  is_active        = true,
  is_public        = true
where id = 'pro';

-- -------------------------------------------------------------------------
-- B. features — master feature list
-- -------------------------------------------------------------------------
create table if not exists public.features (
  id           uuid primary key default gen_random_uuid(),
  feature_key  text not null unique,
  name         text not null,
  description  text,
  category     text not null default 'general',
  feature_type text not null default 'boolean'
                check (feature_type in ('boolean', 'limit', 'numeric', 'text')),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- C. plan_features — which features each plan includes
-- -------------------------------------------------------------------------
create table if not exists public.plan_features (
  id         uuid primary key default gen_random_uuid(),
  plan_id    text not null references public.plans(id) on delete cascade,
  feature_id uuid not null references public.features(id) on delete cascade,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (plan_id, feature_id)
);

-- -------------------------------------------------------------------------
-- D. plan_feature_limits — numeric limits per plan per feature
-- -------------------------------------------------------------------------
create table if not exists public.plan_feature_limits (
  id          uuid primary key default gen_random_uuid(),
  plan_id     text not null references public.plans(id) on delete cascade,
  feature_id  uuid not null references public.features(id) on delete cascade,
  limit_value integer not null default -1,   -- -1 = unlimited
  limit_unit  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (plan_id, feature_id)
);

-- -------------------------------------------------------------------------
-- E. organization_feature_overrides — per-org superadmin adjustments
-- -------------------------------------------------------------------------
create table if not exists public.organization_feature_overrides (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_id      uuid not null references public.features(id) on delete cascade,
  is_enabled      boolean,
  limit_override  integer,
  starts_at       timestamptz not null default now(),
  expires_at      timestamptz,
  reason          text,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- F. subscription_payments — payment history (separate from events)
-- -------------------------------------------------------------------------
create table if not exists public.subscription_payments (
  id                    uuid primary key default gen_random_uuid(),
  subscription_id       uuid not null references public.subscriptions(id) on delete cascade,
  organization_id       uuid not null references public.organizations(id) on delete cascade,
  amount                numeric(14, 2) not null,
  currency              text not null default 'MMK',
  payment_method        text,
  transaction_reference text,
  payment_status        text not null default 'pending'
                          check (payment_status in ('pending','paid','failed','refunded')),
  paid_at               timestamptz,
  notes                 text,
  reviewed_by           uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- G. subscription_usage — resource usage per org per feature_key
-- -------------------------------------------------------------------------
create table if not exists public.subscription_usage (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_key     text not null,
  current_usage   integer not null default 0,
  period_start    date not null default current_date,
  period_end      date,
  updated_at      timestamptz not null default now(),
  unique (organization_id, feature_key, period_start)
);

-- -------------------------------------------------------------------------
-- H. subscription_audit_logs — immutable change log
-- -------------------------------------------------------------------------
create table if not exists public.subscription_audit_logs (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete set null,
  subscription_id uuid references public.subscriptions(id) on delete set null,
  action          text not null,
  old_value       jsonb,
  new_value       jsonb,
  performed_by    uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now()
);

-- -------------------------------------------------------------------------
-- Indexes
-- -------------------------------------------------------------------------
create index if not exists idx_plan_features_plan on public.plan_features (plan_id);
create index if not exists idx_plan_feature_limits_plan on public.plan_feature_limits (plan_id);
create index if not exists idx_org_feature_overrides_org on public.organization_feature_overrides (organization_id);
create index if not exists idx_org_feature_overrides_expires on public.organization_feature_overrides (expires_at);
create index if not exists idx_subscription_payments_org on public.subscription_payments (organization_id);
create index if not exists idx_subscription_payments_status on public.subscription_payments (payment_status);
create index if not exists idx_subscription_usage_org on public.subscription_usage (organization_id);
create index if not exists idx_subscription_audit_org on public.subscription_audit_logs (organization_id);
create index if not exists idx_subscription_audit_created on public.subscription_audit_logs (created_at desc);

-- -------------------------------------------------------------------------
-- RLS
-- -------------------------------------------------------------------------
alter table public.features enable row level security;
alter table public.plan_features enable row level security;
alter table public.plan_feature_limits enable row level security;
alter table public.organization_feature_overrides enable row level security;
alter table public.subscription_payments enable row level security;
alter table public.subscription_usage enable row level security;
alter table public.subscription_audit_logs enable row level security;

-- features: public read
create policy "features_read_all"
  on public.features for select using (true);
create policy "features_write_admin"
  on public.features for all using (public.is_platform_admin());

-- plan_features: public read
create policy "plan_features_read_all"
  on public.plan_features for select using (true);
create policy "plan_features_write_admin"
  on public.plan_features for all using (public.is_platform_admin());

-- plan_feature_limits: public read
create policy "plan_feature_limits_read_all"
  on public.plan_feature_limits for select using (true);
create policy "plan_feature_limits_write_admin"
  on public.plan_feature_limits for all using (public.is_platform_admin());

-- organization_feature_overrides
create policy "org_overrides_read_member"
  on public.organization_feature_overrides for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "org_overrides_write_admin"
  on public.organization_feature_overrides for all
  using (public.is_platform_admin());

-- subscription_payments
create policy "sub_payments_read_member"
  on public.subscription_payments for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "sub_payments_write_admin"
  on public.subscription_payments for all
  using (public.is_platform_admin());

-- subscription_usage
create policy "sub_usage_read_member"
  on public.subscription_usage for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "sub_usage_write_admin"
  on public.subscription_usage for all
  using (public.is_platform_admin());

-- subscription_audit_logs: platform admin only
create policy "audit_logs_admin_only"
  on public.subscription_audit_logs for all
  using (public.is_platform_admin());

-- -------------------------------------------------------------------------
-- I. Seed features master list
-- -------------------------------------------------------------------------
insert into public.features (feature_key, name, description, category, feature_type) values
  -- Core
  ('product_management',      'Product Management',       'Manage products and catalog',               'core',      'boolean'),
  ('category_management',     'Category Management',      'Manage product categories',                 'core',      'boolean'),
  ('customer_management',     'Customer Management',      'Manage customers',                          'core',      'boolean'),
  ('supplier_management',     'Supplier Management',      'Manage suppliers',                          'core',      'boolean'),
  ('purchase_management',     'Purchase Management',      'Create and manage purchase orders',         'core',      'boolean'),
  ('sales_management',        'Sales Management',         'Create and manage sales',                   'core',      'boolean'),
  ('cash_sales',              'Cash Sales',               'Sell with immediate cash payment',          'core',      'boolean'),
  -- Finance
  ('credit_sales',            'Credit Sales',             'Sell on credit (accounts receivable)',      'finance',   'boolean'),
  ('partial_payments',        'Partial Payments',         'Accept partial payments on invoices',       'finance',   'boolean'),
  ('customer_ledger',         'Customer Ledger',          'Track customer balances and history',       'finance',   'boolean'),
  ('customer_debt_tracking',  'Customer Debt Tracking',   'Track outstanding customer debts',          'finance',   'boolean'),
  ('supplier_payables',       'Supplier Payables',        'Track supplier payments and balances',      'finance',   'boolean'),
  ('payment_receipt_mgmt',    'Payment & Receipt Mgmt',   'Manage payments and receipts',              'finance',   'boolean'),
  ('expense_management',      'Expense Management',       'Track and manage business expenses',        'finance',   'boolean'),
  -- Inventory
  ('inventory_management',    'Inventory Management',     'Basic stock tracking',                      'inventory', 'boolean'),
  ('stock_adjustment',        'Stock Adjustment',         'Manually adjust stock levels',              'inventory', 'boolean'),
  ('stock_transfer',          'Stock Transfer',           'Transfer stock between branches',           'inventory', 'boolean'),
  ('low_stock_alerts',        'Low Stock Alerts',         'Get notified when stock is low',            'inventory', 'boolean'),
  ('advanced_inventory',      'Advanced Inventory',       'Advanced inventory management features',    'inventory', 'boolean'),
  ('barcode_support',         'Barcode Support',          'Barcode scanning support',                  'inventory', 'boolean'),
  ('qr_support',              'QR Support',               'QR code scanning support',                  'inventory', 'boolean'),
  -- Branch & Multi-org
  ('multi_branch',            'Multi-Branch',             'Manage multiple branches',                  'org',       'boolean'),
  -- Reports
  ('daily_sales_report',      'Daily Sales Report',       'View daily sales summary',                  'reports',   'boolean'),
  ('basic_product_report',    'Basic Product Report',     'Basic product performance report',          'reports',   'boolean'),
  ('monthly_yearly_reports',  'Monthly & Yearly Reports', 'Monthly and yearly financial reports',      'reports',   'boolean'),
  ('customer_statement_pdf',  'Customer Statement PDF',   'Generate PDF customer statements',          'reports',   'boolean'),
  ('supplier_statement_pdf',  'Supplier Statement PDF',   'Generate PDF supplier statements',          'reports',   'boolean'),
  ('sales_analytics',         'Sales Analytics',          'Advanced sales analytics and charts',       'reports',   'boolean'),
  ('purchase_analytics',      'Purchase Analytics',       'Advanced purchase analytics',               'reports',   'boolean'),
  ('branch_reports',          'Branch Reports',           'Per-branch performance reports',            'reports',   'boolean'),
  ('profit_loss_report',      'Profit & Loss Report',     'Full profit and loss statement',            'reports',   'boolean'),
  ('cash_flow_report',        'Cash Flow Report',         'Cash flow summary report',                  'reports',   'boolean'),
  ('profit_estimation',       'Profit Estimation',        'Estimate profit margins on sales',          'reports',   'boolean'),
  -- Automation
  ('automated_reports',       'Automated Reports',        'Automatically generated daily/weekly reports','automation','boolean'),
  ('debt_reminders',          'Debt Reminders',           'Automated debt reminder notifications',     'automation','boolean'),
  -- Export
  ('manual_data_export',      'Manual Data Export',       'Export data manually (CSV/basic)',          'export',    'boolean'),
  ('excel_export',            'Excel Export',             'Export reports to Excel format',            'export',    'boolean'),
  -- Access & Security
  ('basic_permissions',       'Basic User Permissions',   'Basic role-based user permissions',         'security',  'boolean'),
  ('advanced_permissions',    'Advanced Permissions',     'Advanced role-based access control',        'security',  'boolean'),
  ('audit_logs',              'Audit Logs',               'Full audit trail of all changes',           'security',  'boolean'),
  ('backup_restore',          'Backup & Restore',         'Backup and restore data support',           'security',  'boolean'),
  -- Support
  ('priority_support',        'Priority Support',         'Priority customer support access',          'support',   'boolean'),
  -- Limits (feature_type = limit)
  ('max_users',               'User Limit',               'Maximum number of active users',            'limits',    'limit'),
  ('max_products',            'Product Limit',            'Maximum number of active products',         'limits',    'limit'),
  ('max_customers',           'Customer Limit',           'Maximum number of active customers',        'limits',    'limit'),
  ('max_suppliers',           'Supplier Limit',           'Maximum number of active suppliers',        'limits',    'limit'),
  ('max_branches',            'Branch Limit',             'Maximum number of branches',                'limits',    'limit')
on conflict (feature_key) do update set
  name        = excluded.name,
  description = excluded.description,
  category    = excluded.category,
  feature_type = excluded.feature_type,
  updated_at  = now();

-- -------------------------------------------------------------------------
-- J. Seed plan_features (which features each plan has enabled)
-- -------------------------------------------------------------------------
-- Helper: seed for a plan using feature_key list
do $$
declare
  v_starter_features  text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','inventory_management','stock_adjustment',
    'daily_sales_report','basic_product_report','manual_data_export',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_business_features text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','credit_sales','partial_payments','customer_ledger',
    'customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
    'expense_management','inventory_management','stock_adjustment',
    'stock_transfer','low_stock_alerts','multi_branch',
    'daily_sales_report','basic_product_report','monthly_yearly_reports',
    'profit_estimation','excel_export','basic_permissions',
    'manual_data_export',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_pro_features text[] := array[
    'product_management','category_management','customer_management',
    'supplier_management','purchase_management','sales_management',
    'cash_sales','credit_sales','partial_payments','customer_ledger',
    'customer_debt_tracking','supplier_payables','payment_receipt_mgmt',
    'expense_management','inventory_management','stock_adjustment',
    'stock_transfer','low_stock_alerts','multi_branch',
    'advanced_inventory','barcode_support','qr_support',
    'daily_sales_report','basic_product_report','monthly_yearly_reports',
    'customer_statement_pdf','supplier_statement_pdf','sales_analytics',
    'purchase_analytics','branch_reports','profit_loss_report',
    'cash_flow_report','profit_estimation','automated_reports',
    'debt_reminders','excel_export','manual_data_export',
    'basic_permissions','advanced_permissions','audit_logs','backup_restore',
    'priority_support',
    'max_users','max_products','max_customers','max_suppliers','max_branches'
  ];
  v_key text;
  v_fid uuid;
begin
  -- Starter
  foreach v_key in array v_starter_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('starter', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;

  -- Business (all business features enabled)
  foreach v_key in array v_business_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('business', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;

  -- Pro (all pro features enabled)
  foreach v_key in array v_pro_features loop
    select id into v_fid from public.features where feature_key = v_key;
    if found then
      insert into public.plan_features (plan_id, feature_id, is_enabled)
      values ('pro', v_fid, true)
      on conflict (plan_id, feature_id) do update set is_enabled = true, updated_at = now();
    end if;
  end loop;
end $$;

-- -------------------------------------------------------------------------
-- K. Seed plan_feature_limits
-- -------------------------------------------------------------------------
do $$
declare
  v_limits record;
  v_fid    uuid;
begin
  for v_limits in
    select * from (values
      -- (plan_id, feature_key, limit_value, limit_unit)
      ('starter',  'max_users',     1,    'users'),
      ('starter',  'max_products',  100,  'products'),
      ('starter',  'max_customers', 100,  'customers'),
      ('starter',  'max_suppliers', 20,   'suppliers'),
      ('starter',  'max_branches',  1,    'branches'),
      ('business', 'max_users',     3,    'users'),
      ('business', 'max_products',  2000, 'products'),
      ('business', 'max_customers', -1,   'customers'),
      ('business', 'max_suppliers', -1,   'suppliers'),
      ('business', 'max_branches',  2,    'branches'),
      ('pro',      'max_users',     10,   'users'),
      ('pro',      'max_products',  -1,   'products'),
      ('pro',      'max_customers', -1,   'customers'),
      ('pro',      'max_suppliers', -1,   'suppliers'),
      ('pro',      'max_branches',  5,    'branches')
    ) as t(plan_id, feature_key, limit_value, limit_unit)
  loop
    select id into v_fid from public.features where feature_key = v_limits.feature_key;
    if found then
      insert into public.plan_feature_limits (plan_id, feature_id, limit_value, limit_unit)
      values (v_limits.plan_id, v_fid, v_limits.limit_value, v_limits.limit_unit)
      on conflict (plan_id, feature_id) do update
        set limit_value = excluded.limit_value,
            limit_unit  = excluded.limit_unit,
            updated_at  = now();
    end if;
  end loop;
end $$;
-- <<< END 0019_plan_feature_system.sql

-- >>> BEGIN 0020_entitlement_rpcs.sql
-- ==============================================================================
-- Migration: 0020_entitlement_rpcs.sql
-- Description: Backend RPCs for feature-access resolution (entitlements).
-- Priority order: org override → plan_features → deny
-- ==============================================================================

-- -------------------------------------------------------------------------
-- 1. get_organization_subscription
-- -------------------------------------------------------------------------
create or replace function public.get_organization_subscription(
  p_org_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub   public.subscriptions%rowtype;
  v_plan  public.plans%rowtype;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then
    raise exception 'Access denied';
  end if;

  select * into v_sub from public.subscriptions where organization_id = p_org_id;
  if not found then
    return jsonb_build_object('found', false);
  end if;

  select * into v_plan from public.plans where id = v_sub.plan_id;

  return jsonb_build_object(
    'found',                true,
    'subscription_id',      v_sub.id,
    'organization_id',      v_sub.organization_id,
    'plan_id',              v_sub.plan_id,
    'plan_name',            v_plan.name,
    'plan_slug',            v_plan.slug,
    'monthly_price',        v_plan.monthly_price_mmk,
    'yearly_price',         v_plan.yearly_price_mmk,
    'status',               v_sub.status,
    'billing_cycle',        v_sub.billing_cycle,
    'starts_at',            v_sub.starts_at,
    'trial_ends_at',        v_sub.trial_ends_at,
    'current_period_start', v_sub.current_period_start,
    'current_period_end',   v_sub.current_period_end,
    'cancel_at_period_end', v_sub.cancel_at_period_end,
    'expires_at',           v_sub.expires_at
  );
end;
$$;

grant execute on function public.get_organization_subscription(uuid) to authenticated;

-- -------------------------------------------------------------------------
-- Helper: resolve effective subscription status
--   returns: 'active' | 'trialing' | 'expired' | 'past_due' | 'canceled' | 'none'
-- -------------------------------------------------------------------------
create or replace function public._resolve_subscription_status(
  p_org_id uuid,
  out v_status text,
  out v_plan_id text
)
returns record
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub public.subscriptions%rowtype;
begin
  v_status  := 'none';
  v_plan_id := null;

  select * into v_sub from public.subscriptions where organization_id = p_org_id;
  if not found then
    return;
  end if;

  v_plan_id := v_sub.plan_id;

  case v_sub.status
    when 'trialing' then
      v_status := case when v_sub.trial_ends_at > now() then 'trialing' else 'expired' end;
    when 'active' then
      v_status := case when v_sub.current_period_end > now() then 'active' else 'past_due' end;
    when 'past_due' then
      v_status := 'past_due';
    when 'canceled' then
      -- retain access until end of paid period
      v_status := case when v_sub.cancel_at_period_end and v_sub.current_period_end > now()
                       then 'active' else 'canceled' end;
    else
      v_status := v_sub.status;
  end case;
end;
$$;

-- -------------------------------------------------------------------------
-- 2. check_organization_feature
-- -------------------------------------------------------------------------
create or replace function public.check_organization_feature(
  p_org_id     uuid,
  p_feature_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status    text;
  v_plan_id   text;
  v_feature   public.features%rowtype;
  v_override  public.organization_feature_overrides%rowtype;
  v_pf_row    public.plan_features%rowtype;
  v_is_allowed boolean := false;
  v_reason    text;
begin
  -- Resolve subscription status
  select * into v_status, v_plan_id from public._resolve_subscription_status(p_org_id);

  -- Lookup feature
  select * into v_feature from public.features where feature_key = p_feature_key;
  if not found then
    return jsonb_build_object(
      'is_allowed', false,
      'feature_key', p_feature_key,
      'reason', 'Feature not found',
      'subscription_status', v_status
    );
  end if;

  -- Priority 1: active org override
  select * into v_override
  from public.organization_feature_overrides
  where organization_id = p_org_id
    and feature_id = v_feature.id
    and starts_at <= now()
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'is_allowed', coalesce(v_override.is_enabled, false),
      'feature_key', p_feature_key,
      'reason', 'Organization override',
      'subscription_status', v_status
    );
  end if;

  -- Priority 2: plan features (requires valid subscription)
  if v_status not in ('active','trialing') then
    return jsonb_build_object(
      'is_allowed', false,
      'feature_key', p_feature_key,
      'reason', case v_status
                  when 'expired'   then 'Subscription expired'
                  when 'past_due'  then 'Payment past due'
                  when 'canceled'  then 'Subscription cancelled'
                  else 'No active subscription'
                end,
      'subscription_status', v_status
    );
  end if;

  select pf.* into v_pf_row
  from public.plan_features pf
  where pf.plan_id = v_plan_id
    and pf.feature_id = v_feature.id;

  if found and v_pf_row.is_enabled then
    v_is_allowed := true;
    v_reason := 'Included in ' || v_plan_id || ' plan';
  else
    v_is_allowed := false;
    v_reason := 'Feature not included in ' || coalesce(v_plan_id, 'current') || ' plan';
  end if;

  return jsonb_build_object(
    'is_allowed', v_is_allowed,
    'feature_key', p_feature_key,
    'reason', v_reason,
    'subscription_status', v_status
  );
end;
$$;

grant execute on function public.check_organization_feature(uuid, text) to authenticated;

-- -------------------------------------------------------------------------
-- 3. get_organization_feature_limit
-- -------------------------------------------------------------------------
create or replace function public.get_organization_feature_limit(
  p_org_id      uuid,
  p_feature_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status       text;
  v_plan_id      text;
  v_feature      public.features%rowtype;
  v_override     public.organization_feature_overrides%rowtype;
  v_pfl          public.plan_feature_limits%rowtype;
  v_limit_value  integer := -1;
  v_has_override boolean := false;
begin
  select * into v_status, v_plan_id from public._resolve_subscription_status(p_org_id);

  select * into v_feature from public.features where feature_key = p_feature_key;
  if not found then
    return jsonb_build_object('limit_value', 0, 'has_override', false, 'feature_key', p_feature_key);
  end if;

  -- Check org override with limit_override
  select * into v_override
  from public.organization_feature_overrides
  where organization_id = p_org_id
    and feature_id = v_feature.id
    and limit_override is not null
    and starts_at <= now()
    and (expires_at is null or expires_at > now())
  order by created_at desc
  limit 1;

  if found then
    return jsonb_build_object(
      'limit_value',  v_override.limit_override,
      'has_override', true,
      'feature_key',  p_feature_key
    );
  end if;

  -- Plan limit
  if v_plan_id is not null then
    select pfl.* into v_pfl
    from public.plan_feature_limits pfl
    where pfl.plan_id = v_plan_id
      and pfl.feature_id = v_feature.id;
    if found then
      v_limit_value := v_pfl.limit_value;
    end if;
  end if;

  return jsonb_build_object(
    'limit_value',  v_limit_value,
    'has_override', false,
    'feature_key',  p_feature_key
  );
end;
$$;

grant execute on function public.get_organization_feature_limit(uuid, text) to authenticated;

-- -------------------------------------------------------------------------
-- 4. get_organization_usage — compute from real records
-- -------------------------------------------------------------------------
create or replace function public.get_organization_usage(
  p_org_id      uuid,
  p_feature_key text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
begin
  case p_feature_key
    when 'max_users' then
      select count(*) into v_count
      from public.organization_members
      where organization_id = p_org_id and is_active = true;

    when 'max_products' then
      select count(*) into v_count
      from public.products
      where organization_id = p_org_id and is_active = true;

    when 'max_customers' then
      select count(*) into v_count
      from public.customers
      where organization_id = p_org_id;

    when 'max_suppliers' then
      select count(*) into v_count
      from public.suppliers
      where organization_id = p_org_id;

    when 'max_branches' then
      if exists (
        select 1 from information_schema.tables
        where table_schema = 'public' and table_name = 'branches'
      ) then
        execute format(
          'select count(*) from public.branches where organization_id = %L and is_active = true',
          p_org_id
        ) into v_count;
      else
        v_count := 1;
      end if;

    else
      v_count := 0;
  end case;

  return v_count;
end;
$$;

grant execute on function public.get_organization_usage(uuid, text) to authenticated;

-- -------------------------------------------------------------------------
-- 5. check_organization_limit
-- -------------------------------------------------------------------------
create or replace function public.check_organization_limit(
  p_org_id      uuid,
  p_feature_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit_info  jsonb;
  v_limit_value integer;
  v_current     integer;
  v_remaining   integer;
  v_is_allowed  boolean;
  v_reason      text;
  v_status      text;
  v_plan_id     text;
begin
  select * into v_status, v_plan_id from public._resolve_subscription_status(p_org_id);

  v_limit_info  := public.get_organization_feature_limit(p_org_id, p_feature_key);
  v_limit_value := (v_limit_info->>'limit_value')::integer;
  v_current     := public.get_organization_usage(p_org_id, p_feature_key);

  if v_limit_value = -1 then
    v_is_allowed := true;
    v_remaining  := -1;
    v_reason     := 'Unlimited';
  elsif v_current < v_limit_value then
    v_is_allowed := true;
    v_remaining  := v_limit_value - v_current;
    v_reason     := 'Within limit';
  else
    v_is_allowed := false;
    v_remaining  := 0;
    v_reason     := 'Limit reached (' || v_current || '/' || v_limit_value || ')';
  end if;

  return jsonb_build_object(
    'is_allowed',         v_is_allowed,
    'feature_key',        p_feature_key,
    'current_usage',      v_current,
    'limit_value',        v_limit_value,
    'remaining_usage',    v_remaining,
    'subscription_status', v_status,
    'reason',             v_reason
  );
end;
$$;

grant execute on function public.check_organization_limit(uuid, text) to authenticated;

-- -------------------------------------------------------------------------
-- 6. get_organization_entitlements — all features in one call
-- -------------------------------------------------------------------------
create or replace function public.get_organization_entitlements(
  p_org_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_status    text;
  v_plan_id   text;
  v_result    jsonb := '[]'::jsonb;
  v_feature   record;
  v_access    jsonb;
  v_limit_info jsonb;
  v_usage     integer;
  v_limit_val integer;
  v_remaining integer;
  v_override  public.organization_feature_overrides%rowtype;
  v_pf_enabled boolean;
  v_is_allowed boolean;
  v_reason    text;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then
    raise exception 'Access denied';
  end if;

  select * into v_status, v_plan_id from public._resolve_subscription_status(p_org_id);

  for v_feature in
    select * from public.features where is_active = true order by category, name
  loop
    -- Resolve access
    v_is_allowed := false;
    v_reason     := 'No active subscription';

    -- Check org override
    select * into v_override
    from public.organization_feature_overrides
    where organization_id = p_org_id
      and feature_id = v_feature.id
      and starts_at <= now()
      and (expires_at is null or expires_at > now())
    order by created_at desc
    limit 1;

    if found then
      v_is_allowed := coalesce(v_override.is_enabled, false);
      v_reason     := 'Organization override';
    elsif v_status in ('active', 'trialing') and v_plan_id is not null then
      select pf.is_enabled into v_pf_enabled
      from public.plan_features pf
      where pf.plan_id = v_plan_id and pf.feature_id = v_feature.id;

      if found and v_pf_enabled then
        v_is_allowed := true;
        v_reason     := 'Plan: ' || v_plan_id;
      else
        v_is_allowed := false;
        v_reason     := 'Not in plan';
      end if;
    else
      v_reason := case v_status
        when 'expired'  then 'Subscription expired'
        when 'past_due' then 'Payment past due'
        when 'canceled' then 'Subscription cancelled'
        else 'No active subscription'
      end;
    end if;

    -- Resolve limit and usage for 'limit' type features
    v_limit_val := null;
    v_usage     := null;
    v_remaining := null;

    if v_feature.feature_type = 'limit' then
      v_limit_info := public.get_organization_feature_limit(p_org_id, v_feature.feature_key);
      v_limit_val  := (v_limit_info->>'limit_value')::integer;
      v_usage      := public.get_organization_usage(p_org_id, v_feature.feature_key);
      v_remaining  := case when v_limit_val = -1 then -1 else greatest(0, v_limit_val - v_usage) end;
    end if;

    v_result := v_result || jsonb_build_object(
      'feature_key',        v_feature.feature_key,
      'feature_name',       v_feature.name,
      'feature_type',       v_feature.feature_type,
      'category',           v_feature.category,
      'is_allowed',         v_is_allowed,
      'reason',             v_reason,
      'current_usage',      v_usage,
      'limit_value',        v_limit_val,
      'remaining_usage',    v_remaining,
      'subscription_status', v_status
    );
  end loop;

  return v_result;
end;
$$;

grant execute on function public.get_organization_entitlements(uuid) to authenticated;

-- -------------------------------------------------------------------------
-- 7. Update product limit trigger to use plan_feature_limits
-- -------------------------------------------------------------------------
create or replace function public.enforce_product_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit_check jsonb;
begin
  v_limit_check := public.check_organization_limit(new.organization_id, 'max_products');
  if not (v_limit_check->>'is_allowed')::boolean then
    raise exception 'Product limit reached for your plan. %', v_limit_check->>'reason';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit
  before insert on public.products
  for each row execute function public.enforce_product_plan_limit();

-- -------------------------------------------------------------------------
-- 8. User limit trigger on organization_members
-- -------------------------------------------------------------------------
create or replace function public.enforce_user_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit_check jsonb;
begin
  v_limit_check := public.check_organization_limit(new.organization_id, 'max_users');
  if not (v_limit_check->>'is_allowed')::boolean then
    raise exception 'User limit reached for your plan. %', v_limit_check->>'reason';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_user_plan_limit on public.organization_members;
create trigger trg_enforce_user_plan_limit
  before insert on public.organization_members
  for each row execute function public.enforce_user_plan_limit();

-- -------------------------------------------------------------------------
-- 9. admin_grant_feature_override RPC (superadmin)
-- -------------------------------------------------------------------------
create or replace function public.admin_grant_feature_override(
  p_org_id       uuid,
  p_feature_key  text,
  p_is_enabled   boolean default null,
  p_limit_override integer default null,
  p_expires_at   timestamptz default null,
  p_reason       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_feature_id uuid;
  v_override_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform admin privileges required';
  end if;

  select id into v_feature_id from public.features where feature_key = p_feature_key;
  if not found then
    raise exception 'Feature not found: %', p_feature_key;
  end if;

  insert into public.organization_feature_overrides (
    organization_id, feature_id, is_enabled, limit_override,
    expires_at, reason, created_by
  )
  values (
    p_org_id, v_feature_id, p_is_enabled, p_limit_override,
    p_expires_at, p_reason, auth.uid()
  )
  returning id into v_override_id;

  -- Audit log
  insert into public.subscription_audit_logs (
    organization_id, action, new_value, performed_by
  )
  values (
    p_org_id,
    'feature_override_granted',
    jsonb_build_object(
      'feature_key', p_feature_key,
      'is_enabled', p_is_enabled,
      'limit_override', p_limit_override,
      'expires_at', p_expires_at,
      'reason', p_reason
    ),
    auth.uid()
  );

  return jsonb_build_object('success', true, 'override_id', v_override_id);
end;
$$;

grant execute on function public.admin_grant_feature_override(uuid, text, boolean, integer, timestamptz, text) to authenticated;

-- -------------------------------------------------------------------------
-- 10. Update verify_subscription_payment to also insert subscription_payment row
-- -------------------------------------------------------------------------
create or replace function public.verify_subscription_payment(
  p_sub_id      uuid,
  p_event_id    uuid,
  p_approve     boolean,
  p_admin_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub     public.subscriptions%rowtype;
  v_event   public.subscription_events%rowtype;
  v_plan    public.plans%rowtype;
  v_duration interval;
  v_old_status text;
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

  -- Check already processed
  if v_event.event_type in ('payment_approved', 'payment_rejected') then
    raise exception 'Payment event already processed';
  end if;

  v_old_status := v_sub.status;

  if p_approve then
    select * into v_plan from public.plans where id = v_sub.plan_id;
    v_duration := case when v_sub.billing_cycle = 'yearly'
                       then interval '1 year'
                       else interval '1 month' end;

    update public.subscriptions
    set status               = 'active',
        current_period_start = now(),
        current_period_end   = now() + v_duration,
        updated_at           = now()
    where id = p_sub_id;

    -- Insert subscription_payment record as paid
    insert into public.subscription_payments (
      subscription_id, organization_id, amount, currency,
      payment_method, transaction_reference, payment_status, paid_at, notes, reviewed_by
    )
    values (
      p_sub_id, v_sub.organization_id,
      coalesce(v_event.amount, 0), 'MMK',
      v_event.payment_method, v_event.payment_reference,
      'paid', now(), p_admin_notes, auth.uid()
    );

    update public.subscription_events
    set event_type = 'payment_approved',
        admin_notes = p_admin_notes
    where id = p_event_id;

    -- Audit
    insert into public.subscription_audit_logs (
      organization_id, subscription_id, action, old_value, new_value, performed_by
    )
    values (
      v_sub.organization_id, p_sub_id, 'payment_approved',
      jsonb_build_object('status', v_old_status),
      jsonb_build_object('status', 'active', 'amount', v_event.amount),
      auth.uid()
    );

    return jsonb_build_object('success', true, 'status', 'active');
  else
    -- Insert subscription_payment record as failed
    insert into public.subscription_payments (
      subscription_id, organization_id, amount, currency,
      payment_method, transaction_reference, payment_status, notes, reviewed_by
    )
    values (
      p_sub_id, v_sub.organization_id,
      coalesce(v_event.amount, 0), 'MMK',
      v_event.payment_method, v_event.payment_reference,
      'failed', p_admin_notes, auth.uid()
    );

    update public.subscription_events
    set event_type = 'payment_rejected',
        admin_notes = p_admin_notes
    where id = p_event_id;

    -- Audit
    insert into public.subscription_audit_logs (
      organization_id, subscription_id, action, old_value, new_value, performed_by
    )
    values (
      v_sub.organization_id, p_sub_id, 'payment_rejected',
      jsonb_build_object('status', v_old_status),
      jsonb_build_object('admin_notes', p_admin_notes),
      auth.uid()
    );

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

grant execute on function public.verify_subscription_payment(uuid, uuid, boolean, text) to authenticated;
-- <<< END 0020_entitlement_rpcs.sql

-- >>> BEGIN 0021_marketing_automation_schema.sql
-- ==============================================================================
-- Migration: 0021_marketing_automation_schema.sql
-- Description: ShopFlow AI marketing automation tables, RLS, and workspace seed.
-- Incremental and non-destructive: does not drop or truncate existing ERP data.
-- ==============================================================================

create extension if not exists "pgcrypto";

create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.is_marketing_manager(target_org_id uuid)
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
      and role in ('owner', 'admin', 'manager')
      and is_active = true
  );
$$;

create or replace function public.can_approve_marketing(target_org_id uuid)
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
      and role in ('owner', 'admin', 'manager')
      and is_active = true
  );
$$;

-- 1. Workspaces (1:1 with organization)
create table if not exists public.marketing_workspaces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations(id) on delete cascade,
  brand_name text not null default 'ShopFlow',
  market text not null default 'Myanmar',
  primary_language text not null default 'Burmese',
  secondary_language text not null default 'English',
  target_audience text[] not null default array[
    'Wholesale shop owners',
    'Retail shop owners',
    'General merchandise stores',
    'Distribution businesses',
    'Small business owners'
  ],
  primary_goal text not null default 'Free trial registrations',
  secondary_goal text not null default 'Brand awareness',
  platforms text[] not null default array['facebook', 'tiktok'],
  approval_mode text not null default 'manual_review' check (approval_mode = 'manual_review'),
  monthly_ad_budget_mmk numeric(14,2) not null default 50000 check (monthly_ad_budget_mmk >= 0),
  facebook_budget_mmk numeric(14,2) not null default 30000 check (facebook_budget_mmk >= 0),
  tiktok_budget_mmk numeric(14,2) not null default 20000 check (tiktok_budget_mmk >= 0),
  currency text not null default 'MMK',
  timezone text not null default 'Asia/Yangon',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_workspace_budget_alloc_chk
    check (facebook_budget_mmk + tiktok_budget_mmk <= monthly_ad_budget_mmk)
);

create table if not exists public.marketing_settings (
  workspace_id uuid primary key references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  brand_tone text not null default 'professional_friendly',
  default_cta text not null default 'Start 14-day free trial',
  ai_provider text not null default 'openai',
  ai_model text not null default 'gpt-4o-mini',
  auto_generate_weekly_ideas boolean not null default true,
  auto_generate_drafts boolean not null default false,
  notify_on_pending_approval boolean not null default true,
  budget_alert_threshold_pct numeric(5,2) not null default 80 check (budget_alert_threshold_pct between 1 and 100),
  content_pillars jsonb not null default jsonb_build_array(
    jsonb_build_object('key', 'business_problems', 'label', 'Business Problems', 'weight', 35),
    jsonb_build_object('key', 'product_demonstrations', 'label', 'Product Demonstrations', 'weight', 30),
    jsonb_build_object('key', 'educational', 'label', 'Educational Content', 'weight', 20),
    jsonb_build_object('key', 'promotion_conversion', 'label', 'Product Promotion and Conversion', 'weight', 15)
  ),
  prompt_overrides jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.social_accounts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  provider text not null check (provider in ('facebook', 'tiktok', 'metricool')),
  display_name text,
  external_account_id text,
  page_id text,
  username text,
  connection_status text not null default 'disconnected'
    check (connection_status in ('disconnected', 'pending', 'connected', 'expired', 'restricted', 'missing_permissions')),
  granted_permissions text[] not null default '{}',
  missing_permissions text[] not null default '{}',
  token_expires_at timestamptz,
  last_error text,
  last_synced_at timestamptz,
  setup_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_social_accounts_external
  on public.social_accounts (workspace_id, provider, external_account_id)
  where external_account_id is not null;

create unique index if not exists uq_social_accounts_placeholder
  on public.social_accounts (workspace_id, provider)
  where external_account_id is null;

create table if not exists public.social_account_secrets (
  social_account_id uuid primary key references public.social_accounts(id) on delete cascade,
  access_token_encrypted text not null,
  refresh_token_encrypted text,
  token_type text,
  scopes text,
  updated_at timestamptz not null default now()
);

create table if not exists public.marketing_oauth_states (
  id uuid primary key default gen_random_uuid(),
  state_nonce text not null unique,
  provider text not null check (provider in ('facebook', 'tiktok', 'metricool')),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  redirect_to text not null default '/marketing/social-accounts',
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.content_campaigns (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  objective text not null default 'Free trial registrations',
  platform text not null check (platform in ('facebook', 'tiktok', 'both')),
  status text not null default 'draft' check (status in ('draft', 'active', 'paused', 'completed', 'archived')),
  start_date date,
  end_date date,
  planned_budget_mmk numeric(14,2) not null default 0 check (planned_budget_mmk >= 0),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_ideas (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  topic text not null,
  target_audience text,
  pain_point text,
  hook text,
  content_angle text,
  caption_concept text,
  cta text,
  recommended_platform text check (recommended_platform in ('facebook', 'tiktok', 'both')),
  recommended_format text,
  content_pillar text not null default 'educational',
  suggested_publish_at timestamptz,
  expected_objective text,
  status text not null default 'idea' check (status in ('idea', 'selected', 'converted', 'discarded')),
  generation_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketing_contents (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  idea_id uuid references public.content_ideas(id) on delete set null,
  title text not null,
  platform text not null check (platform in ('facebook', 'tiktok')),
  content_type text not null,
  content_pillar text not null,
  caption text not null default '',
  hook text,
  cta text,
  hashtags text[] not null default '{}',
  image_prompt text,
  video_script jsonb,
  production_brief text,
  ai_model text,
  generation_metadata jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in (
    'draft', 'pending_review', 'approved', 'rejected', 'scheduled',
    'publishing', 'published', 'failed', 'archived'
  )),
  scheduled_for timestamptz,
  published_at timestamptz,
  rejection_reason text,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  last_publish_error text,
  provider_post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_assets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid references public.marketing_contents(id) on delete set null,
  asset_type text not null check (asset_type in ('image', 'video', 'thumbnail', 'document', 'other')),
  file_url text,
  storage_path text,
  mime_type text,
  width integer,
  height integer,
  file_size_bytes bigint,
  prompt text,
  generation_provider text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_approvals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid not null references public.marketing_contents(id) on delete cascade,
  action text not null check (action in ('submitted', 'approved', 'rejected', 'edited', 'regenerated', 'scheduled')),
  actor_id uuid references public.profiles(id) on delete set null,
  from_status text,
  to_status text,
  reason text,
  created_at timestamptz not null default now()
);

create table if not exists public.publishing_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid not null references public.marketing_contents(id) on delete cascade,
  social_account_id uuid references public.social_accounts(id) on delete set null,
  idempotency_key text not null unique,
  status text not null default 'queued' check (status in (
    'queued', 'processing', 'succeeded', 'failed_retryable', 'failed_permanent', 'cancelled'
  )),
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  provider_post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.publishing_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  job_id uuid references public.publishing_jobs(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  event text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.social_analytics (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid references public.marketing_contents(id) on delete set null,
  social_account_id uuid references public.social_accounts(id) on delete set null,
  platform text not null check (platform in ('facebook', 'tiktok')),
  metric_date date not null,
  reach numeric(14,2),
  impressions numeric(14,2),
  reactions numeric(14,2),
  comments numeric(14,2),
  shares numeric(14,2),
  likes numeric(14,2),
  link_clicks numeric(14,2),
  video_views numeric(14,2),
  profile_views numeric(14,2),
  engagements numeric(14,2),
  metric_source text not null default 'unavailable' check (metric_source in ('platform', 'estimated', 'unavailable')),
  source_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_social_analytics_content_day
  on public.social_analytics (workspace_id, platform, metric_date, coalesce(content_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists public.marketing_leads (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references public.marketing_workspaces(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete set null,
  full_name text,
  email text,
  phone text,
  business_type text,
  source_platform text check (source_platform in ('facebook', 'tiktok', 'website', 'landing', 'manual', 'other')),
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  status text not null default 'new' check (status in (
    'new', 'contacted', 'interested', 'trial_registered', 'converted', 'not_interested'
  )),
  trial_signup_at timestamptz,
  converted_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trial_conversions (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references public.marketing_leads(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete cascade,
  workspace_id uuid references public.marketing_workspaces(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  attribution_confidence text not null default 'unknown' check (attribution_confidence in ('direct', 'utm', 'inferred', 'unknown')),
  converted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.ad_campaigns (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  platform text not null check (platform in ('facebook', 'tiktok')),
  name text not null,
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'active', 'paused', 'completed', 'rejected')),
  planned_spend_mmk numeric(14,2) not null default 0 check (planned_spend_mmk >= 0),
  approved_spend_mmk numeric(14,2) not null default 0 check (approved_spend_mmk >= 0),
  actual_spend_mmk numeric(14,2) not null default 0 check (actual_spend_mmk >= 0),
  owner_approved boolean not null default false,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ad_budget_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  ad_campaign_id uuid references public.ad_campaigns(id) on delete set null,
  period_month date not null,
  platform text check (platform in ('facebook', 'tiktok')),
  amount_mmk numeric(14,2) not null check (amount_mmk >= 0),
  entry_type text not null check (entry_type in ('planned', 'approved', 'actual', 'adjustment')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.ai_generation_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  purpose text not null,
  model text,
  prompt_name text,
  input_tokens integer,
  output_tokens integer,
  estimated_cost_usd numeric(12,6),
  status text not null default 'succeeded' check (status in ('succeeded', 'failed')),
  error text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.marketing_reports (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  report_type text not null check (report_type in ('weekly', 'monthly')),
  period_start date not null,
  period_end date not null,
  status text not null default 'ready' check (status in ('ready', 'failed', 'insufficient_data')),
  summary jsonb not null default '{}'::jsonb,
  generated_by text not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, report_type, period_start, period_end)
);

create table if not exists public.marketing_notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  notification_type text not null,
  title text not null,
  body text not null,
  entity_type text,
  entity_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_mkt_contents_org_status on public.marketing_contents (organization_id, status, created_at desc);
create index if not exists idx_mkt_contents_scheduled on public.marketing_contents (scheduled_for) where status = 'scheduled';
create index if not exists idx_mkt_leads_org on public.marketing_leads (organization_id, created_at desc);
create index if not exists idx_mkt_jobs_queue on public.publishing_jobs (status, next_attempt_at) where status in ('queued', 'failed_retryable');
create index if not exists idx_mkt_notifications_unread on public.marketing_notifications (organization_id, is_read, created_at desc);
create index if not exists idx_mkt_analytics_org_date on public.social_analytics (organization_id, metric_date desc);
create index if not exists idx_mkt_oauth_nonce on public.marketing_oauth_states (state_nonce);

-- updated_at triggers
do $$
declare
  t text;
begin
  foreach t in array array[
    'marketing_workspaces', 'marketing_settings', 'social_accounts', 'content_campaigns',
    'content_ideas', 'marketing_contents', 'content_assets', 'publishing_jobs',
    'social_analytics', 'marketing_leads', 'ad_campaigns', 'marketing_reports'
  ]
  loop
    execute format('drop trigger if exists trg_%s_updated_at on public.%I', t, t);
    execute format(
      'create trigger trg_%s_updated_at before update on public.%I for each row execute function public.tg_set_updated_at()',
      t, t
    );
  end loop;
end $$;

-- Guard: clients cannot mark content approved/published directly
create or replace function public.tg_marketing_content_status_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  rpc_flag text;
begin
  rpc_flag := current_setting('shopflow.marketing_rpc', true);
  if tg_op = 'INSERT' then
    if new.status not in ('draft') and coalesce(rpc_flag, '') is distinct from '1' then
      raise exception 'New marketing content must start as draft';
    end if;
    return new;
  end if;

  if new.status is distinct from old.status
     and coalesce(rpc_flag, '') is distinct from '1' then
    if old.status in ('publishing', 'published') then
      raise exception 'Published content cannot be mutated from the client';
    end if;
    if new.status not in ('draft', 'pending_review', 'rejected', 'archived') then
      raise exception 'Status % must be applied through a server-side marketing RPC', new.status;
    end if;
    if new.status = 'pending_review' and old.status not in ('draft', 'rejected') then
      raise exception 'Only draft or rejected content can be submitted for review';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_marketing_contents_status_guard on public.marketing_contents;
create trigger trg_marketing_contents_status_guard
  before insert or update on public.marketing_contents
  for each row execute function public.tg_marketing_content_status_guard();

-- Ad campaigns cannot be activated from the client
create or replace function public.tg_ad_campaign_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('shopflow.marketing_rpc', true), '') is distinct from '1' then
    if tg_op = 'INSERT' and new.status not in ('proposed', 'rejected') then
      raise exception 'Ad campaigns must be created as proposed; owner approval is required to spend';
    end if;
    if tg_op = 'UPDATE' and new.status in ('active', 'approved') then
      raise exception 'Advertising spend requires an explicit owner-approval RPC';
    end if;
    if tg_op = 'UPDATE' and new.actual_spend_mmk is distinct from old.actual_spend_mmk then
      raise exception 'Actual ad spend can only be recorded through a server-side RPC';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ad_campaign_guard on public.ad_campaigns;
create trigger trg_ad_campaign_guard
  before insert or update on public.ad_campaigns
  for each row execute function public.tg_ad_campaign_guard();

-- Seed workspace for an organization
create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(p_org_id)
     and exists (
       select 1 from public.organization_members m
       where m.organization_id = p_org_id
     ) then
    raise exception 'Access denied';
  end if;

  insert into public.marketing_workspaces (organization_id)
  values (p_org_id)
  on conflict (organization_id) do update set updated_at = public.marketing_workspaces.updated_at
  returning id into v_id;

  insert into public.marketing_settings (workspace_id, organization_id)
  values (v_id, p_org_id)
  on conflict (workspace_id) do nothing;

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  select v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected',
    'Connect via Meta OAuth. pages_manage_posts and pages_read_engagement are required to publish and read insights.'
  where not exists (
    select 1 from public.social_accounts s
    where s.workspace_id = v_id and s.provider = 'facebook'
  );

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  select v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected',
    'Connect via TikTok Login Kit / Content Posting API. Video publish permissions are required.'
  where not exists (
    select 1 from public.social_accounts s
    where s.workspace_id = v_id and s.provider = 'tiktok'
  );

  return v_id;
end;
$$;

create or replace function public.tg_org_seed_marketing_workspace()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.ensure_marketing_workspace(new.id);
  return new;
exception when others then
  -- Do not block organization creation if marketing seed fails
  return new;
end;
$$;

drop trigger if exists trg_org_seed_marketing_workspace on public.organizations;
create trigger trg_org_seed_marketing_workspace
  after insert on public.organizations
  for each row execute function public.tg_org_seed_marketing_workspace();

-- Backfill workspaces for existing organizations
insert into public.marketing_workspaces (organization_id)
select id from public.organizations
on conflict (organization_id) do nothing;

insert into public.marketing_settings (workspace_id, organization_id)
select w.id, w.organization_id
from public.marketing_workspaces w
on conflict (workspace_id) do nothing;

insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
select w.id, w.organization_id, p.provider, p.display_name, 'disconnected', p.notes
from public.marketing_workspaces w
cross join (
  values
    ('facebook', 'Facebook Page', 'Connect via Meta OAuth. pages_manage_posts and pages_read_engagement are required to publish and read insights.'),
    ('tiktok', 'TikTok Business', 'Connect via TikTok Login Kit / Content Posting API. Video publish permissions are required.')
) as p(provider, display_name, notes)
where not exists (
  select 1 from public.social_accounts s
  where s.workspace_id = w.id and s.provider = p.provider
);

-- RLS
alter table public.marketing_workspaces enable row level security;
alter table public.marketing_settings enable row level security;
alter table public.social_accounts enable row level security;
alter table public.social_account_secrets enable row level security;
alter table public.marketing_oauth_states enable row level security;
alter table public.content_campaigns enable row level security;
alter table public.content_ideas enable row level security;
alter table public.marketing_contents enable row level security;
alter table public.content_assets enable row level security;
alter table public.content_approvals enable row level security;
alter table public.publishing_jobs enable row level security;
alter table public.publishing_logs enable row level security;
alter table public.social_analytics enable row level security;
alter table public.marketing_leads enable row level security;
alter table public.trial_conversions enable row level security;
alter table public.ad_campaigns enable row level security;
alter table public.ad_budget_logs enable row level security;
alter table public.ai_generation_logs enable row level security;
alter table public.marketing_reports enable row level security;
alter table public.marketing_notifications enable row level security;

-- Secrets: no client policies (service_role bypasses RLS)
revoke all on public.social_account_secrets from anon, authenticated;
revoke all on public.marketing_oauth_states from anon, authenticated;
grant all on public.social_account_secrets to service_role;
grant all on public.marketing_oauth_states to service_role;

create policy "mkt_workspaces_select" on public.marketing_workspaces for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_workspaces_update" on public.marketing_workspaces for update
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_settings_select" on public.marketing_settings for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_settings_update" on public.marketing_settings for update
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_social_select" on public.social_accounts for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_social_write" on public.social_accounts for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_campaigns_select" on public.content_campaigns for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_campaigns_write" on public.content_campaigns for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_ideas_select" on public.content_ideas for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_ideas_write" on public.content_ideas for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_contents_select" on public.marketing_contents for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_contents_insert" on public.marketing_contents for insert
  with check (public.has_org_membership(organization_id));
create policy "mkt_contents_update" on public.marketing_contents for update
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_assets_select" on public.content_assets for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_assets_write" on public.content_assets for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_approvals_select" on public.content_approvals for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_approvals_insert" on public.content_approvals for insert
  with check (public.has_org_membership(organization_id));

create policy "mkt_jobs_select" on public.publishing_jobs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_logs_select" on public.publishing_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_analytics_select" on public.social_analytics for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_analytics_write" on public.social_analytics for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_leads_select" on public.marketing_leads for select
  using (
    (organization_id is not null and public.has_org_membership(organization_id))
    or public.is_platform_admin()
  );
create policy "mkt_leads_write" on public.marketing_leads for all
  using (
    (organization_id is not null and public.has_org_membership(organization_id))
    or public.is_platform_admin()
  );

create policy "mkt_trials_select" on public.trial_conversions for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_ads_select" on public.ad_campaigns for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_ads_write" on public.ad_campaigns for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_budget_select" on public.ad_budget_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_budget_insert" on public.ad_budget_logs for insert
  with check (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_ai_logs_select" on public.ai_generation_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_reports_select" on public.marketing_reports for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_notif_select" on public.marketing_notifications for select
  using (
    public.has_org_membership(organization_id)
    and (user_id is null or user_id = auth.uid())
  );
create policy "mkt_notif_update" on public.marketing_notifications for update
  using (user_id = auth.uid() or public.is_org_admin_or_owner(organization_id));

-- Storage bucket (ignore if storage is unavailable)
do $$
begin
  insert into storage.buckets (id, name, public)
  values ('marketing-assets', 'marketing-assets', false)
  on conflict (id) do nothing;
exception when undefined_table then
  null;
when others then
  null;
end $$;

do $$
begin
  execute $pol$
    create policy "mkt_storage_select"
      on storage.objects for select
      using (
        bucket_id = 'marketing-assets'
        and public.has_org_membership((storage.foldername(name))[1]::uuid)
      )
  $pol$;
exception when duplicate_object then null;
when undefined_table then null;
when others then null;
end $$;

do $$
begin
  execute $pol$
    create policy "mkt_storage_insert"
      on storage.objects for insert
      with check (
        bucket_id = 'marketing-assets'
        and public.has_org_membership((storage.foldername(name))[1]::uuid)
      )
  $pol$;
exception when duplicate_object then null;
when undefined_table then null;
when others then null;
end $$;
-- <<< END 0021_marketing_automation_schema.sql

-- >>> BEGIN 0022_marketing_rpcs.sql
-- ==============================================================================
-- Migration: 0022_marketing_rpcs.sql
-- Description: Server-side approval, scheduling, publishing, budget, and lead RPCs.
-- ==============================================================================

create or replace function public.mkt_notify(
  p_org_id uuid,
  p_workspace_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_entity_type text default null,
  p_entity_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.marketing_notifications (
    workspace_id, organization_id, notification_type, title, body, entity_type, entity_id
  )
  values (p_workspace_id, p_org_id, p_type, p_title, p_body, p_entity_type, p_entity_id);
end;
$$;

create or replace function public.submit_marketing_content_for_review(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.has_org_membership(v_row.organization_id) then
    raise exception 'Access denied';
  end if;
  if v_row.status not in ('draft', 'rejected') then
    raise exception 'Only draft or rejected content can be submitted for review';
  end if;
  if length(btrim(v_row.caption)) < 8 then
    raise exception 'Caption is required before review';
  end if;

  update public.marketing_contents
    set status = 'pending_review', rejection_reason = null, updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'submitted', auth.uid(), 'draft', 'pending_review'
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'pending_approval',
    'Content awaiting approval',
    v_row.title || ' is ready for review.',
    'marketing_contents',
    v_row.id
  );

  return v_row;
end;
$$;

create or replace function public.approve_marketing_content(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may approve content';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Content must be pending review to approve';
  end if;

  update public.marketing_contents
    set status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        rejection_reason = null,
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'approved', auth.uid(), 'pending_review', 'approved'
  );

  return v_row;
end;
$$;

create or replace function public.reject_marketing_content(p_content_id uuid, p_reason text)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'Rejection reason is required';
  end if;

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may reject content';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Content must be pending review to reject';
  end if;

  update public.marketing_contents
    set status = 'rejected',
        rejection_reason = btrim(p_reason),
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status, reason
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'rejected', auth.uid(), 'pending_review', 'rejected', btrim(p_reason)
  );

  return v_row;
end;
$$;

create or replace function public.schedule_marketing_content(p_content_id uuid, p_scheduled_for timestamptz)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_scheduled_for is null then
    raise exception 'Scheduled time is required';
  end if;

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may schedule content';
  end if;
  if v_row.status not in ('approved', 'scheduled') then
    raise exception 'Only approved content can be scheduled';
  end if;

  update public.marketing_contents
    set status = 'scheduled',
        scheduled_for = p_scheduled_for,
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'scheduled', auth.uid(), 'approved', 'scheduled'
  );

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  )
  values (
    v_row.workspace_id,
    v_row.organization_id,
    v_row.id,
    v_row.id::text || ':' || p_scheduled_for::text,
    'queued',
    p_scheduled_for
  )
  on conflict (idempotency_key) do update
    set next_attempt_at = excluded.next_attempt_at,
        status = case
          when public.publishing_jobs.status in ('succeeded', 'processing') then public.publishing_jobs.status
          else 'queued'
        end,
        updated_at = now();

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'upcoming_scheduled',
    'Post scheduled',
    v_row.title || ' is scheduled for publishing.',
    'marketing_contents',
    v_row.id
  );

  return v_row;
end;
$$;

-- Enqueue immediate publish. Approval is re-checked server-side.
create or replace function public.enqueue_marketing_publish(p_content_id uuid)
returns public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
  v_job public.publishing_jobs;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may publish content';
  end if;
  if v_row.status not in ('approved', 'scheduled') then
    raise exception 'Unapproved content cannot be published';
  end if;
  if exists (
    select 1 from public.publishing_jobs
    where content_id = p_content_id and status in ('processing', 'succeeded')
  ) then
    raise exception 'A publish job is already in progress or completed for this content';
  end if;

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  )
  values (
    v_row.workspace_id,
    v_row.organization_id,
    v_row.id,
    v_row.id::text || ':immediate:' || extract(epoch from now())::bigint::text,
    'queued',
    now()
  )
  returning * into v_job;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (v_row.workspace_id, v_row.organization_id, v_job.id, v_row.id, 'enqueued', jsonb_build_object('by', auth.uid()));

  return v_job;
end;
$$;

create or replace function public.claim_due_publishing_jobs(p_limit integer default 10, p_worker text default 'edge')
returns setof public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  return query
  with due as (
    select j.id
    from public.publishing_jobs j
    join public.marketing_contents c on c.id = j.content_id
    where j.status in ('queued', 'failed_retryable')
      and j.next_attempt_at <= now()
      and j.attempt_count < j.max_attempts
      and (j.locked_at is null or j.locked_at < now() - interval '10 minutes')
      and c.status in ('approved', 'scheduled', 'failed')
    order by j.next_attempt_at
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update of j skip locked
  )
  update public.publishing_jobs j
     set status = 'processing',
         locked_at = now(),
         locked_by = p_worker,
         attempt_count = j.attempt_count + 1,
         updated_at = now()
    from due
   where j.id = due.id
   returning j.*;
end;
$$;

create or replace function public.complete_publishing_job(
  p_job_id uuid,
  p_success boolean,
  p_provider_post_id text default null,
  p_error text default null,
  p_retryable boolean default true
)
returns public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.publishing_jobs;
  v_status text;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_job from public.publishing_jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if p_success then
    update public.publishing_jobs
      set status = 'succeeded',
          provider_post_id = p_provider_post_id,
          last_error = null,
          locked_at = null,
          updated_at = now()
      where id = p_job_id
      returning * into v_job;

    update public.marketing_contents
      set status = 'published',
          published_at = now(),
          provider_post_id = p_provider_post_id,
          last_publish_error = null,
          updated_at = now()
      where id = v_job.content_id;

    perform public.mkt_notify(
      v_job.organization_id, v_job.workspace_id,
      'publish_success',
      'Content published',
      'A scheduled post published successfully.',
      'marketing_contents',
      v_job.content_id
    );
  else
    v_status := case
      when not p_retryable or v_job.attempt_count >= v_job.max_attempts then 'failed_permanent'
      else 'failed_retryable'
    end;

    update public.publishing_jobs
      set status = v_status,
          last_error = p_error,
          locked_at = null,
          next_attempt_at = case when v_status = 'failed_retryable'
            then now() + (interval '5 minutes' * v_job.attempt_count)
            else v_job.next_attempt_at end,
          updated_at = now()
      where id = p_job_id
      returning * into v_job;

    update public.marketing_contents
      set status = 'failed',
          last_publish_error = p_error,
          updated_at = now()
      where id = v_job.content_id;

    perform public.mkt_notify(
      v_job.organization_id, v_job.workspace_id,
      'publish_failure',
      'Publishing failed',
      coalesce(p_error, 'The social platform rejected the post.'),
      'marketing_contents',
      v_job.content_id
    );
  end if;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (
    v_job.workspace_id, v_job.organization_id, v_job.id, v_job.content_id,
    case when p_success then 'succeeded' else 'failed' end,
    jsonb_build_object('error', p_error, 'retryable', p_retryable, 'provider_post_id', p_provider_post_id)
  );

  return v_job;
end;
$$;

create or replace function public.month_ad_spend(p_workspace_id uuid, p_month date default (timezone('Asia/Yangon', now()))::date)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(amount_mmk), 0)
  from public.ad_budget_logs
  where workspace_id = p_workspace_id
    and entry_type = 'actual'
    and date_trunc('month', period_month) = date_trunc('month', p_month::timestamp);
$$;

create or replace function public.approve_ad_campaign(p_campaign_id uuid, p_approved_spend_mmk numeric)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception 'Ad campaign not found';
  end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may approve advertising spend';
  end if;
  if p_approved_spend_mmk is null or p_approved_spend_mmk <= 0 then
    raise exception 'Approved spend must be greater than zero';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);

  if v_spent + p_approved_spend_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Approved spend would exceed the monthly advertising budget of % MMK', v_ws.monthly_ad_budget_mmk;
  end if;

  if v_row.platform = 'facebook' and p_approved_spend_mmk > v_ws.facebook_budget_mmk then
    raise exception 'Approved spend exceeds the Facebook allocation of % MMK', v_ws.facebook_budget_mmk;
  end if;
  if v_row.platform = 'tiktok' and p_approved_spend_mmk > v_ws.tiktok_budget_mmk then
    raise exception 'Approved spend exceeds the TikTok allocation of % MMK', v_ws.tiktok_budget_mmk;
  end if;

  update public.ad_campaigns
    set status = 'approved',
        owner_approved = true,
        approved_spend_mmk = p_approved_spend_mmk,
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now()
    where id = p_campaign_id
    returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform, amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform, p_approved_spend_mmk, 'approved',
    'Owner-approved advertising ceiling', auth.uid()
  );

  return v_row;
end;
$$;

create or replace function public.record_ad_spend(p_campaign_id uuid, p_amount_mmk numeric, p_notes text default null)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception 'Ad campaign not found';
  end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may record advertising spend';
  end if;
  if not v_row.owner_approved or v_row.status not in ('approved', 'active') then
    raise exception 'Spend cannot be recorded until the owner approves this campaign';
  end if;
  if p_amount_mmk is null or p_amount_mmk <= 0 then
    raise exception 'Spend amount must be greater than zero';
  end if;
  if v_row.actual_spend_mmk + p_amount_mmk > v_row.approved_spend_mmk then
    raise exception 'Spend would exceed the owner-approved amount of % MMK', v_row.approved_spend_mmk;
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);
  if v_spent + p_amount_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Spend would exceed the monthly advertising budget';
  end if;

  update public.ad_campaigns
    set actual_spend_mmk = actual_spend_mmk + p_amount_mmk,
        status = 'active',
        updated_at = now()
    where id = p_campaign_id
    returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform, amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform, p_amount_mmk, 'actual', p_notes, auth.uid()
  );

  if public.month_ad_spend(v_row.workspace_id, v_month) >= v_ws.monthly_ad_budget_mmk * 0.8 then
    perform public.mkt_notify(
      v_row.organization_id, v_row.workspace_id,
      'budget_threshold',
      'Advertising budget threshold reached',
      'Monthly advertising spend is at or above 80% of the approved budget.',
      'ad_campaigns',
      v_row.id
    );
  end if;

  return v_row;
end;
$$;

create or replace function public.attribute_trial_signup(
  p_org_id uuid,
  p_user_id uuid,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_utm_content text default null,
  p_email text default null,
  p_full_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ws_id uuid;
  v_lead_id uuid;
  v_content_id uuid;
  v_campaign_id uuid;
  v_confidence text := 'unknown';
  v_platform text := 'website';
begin
  if auth.uid() is distinct from p_user_id
     and not public.has_org_membership(p_org_id)
     and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;

  select id into v_ws_id from public.marketing_workspaces where organization_id = p_org_id;

  if p_utm_content is not null then
    select id, campaign_id into v_content_id, v_campaign_id
    from public.marketing_contents
    where id::text = p_utm_content
    limit 1;
  end if;

  if v_campaign_id is null and p_utm_campaign is not null then
    select id into v_campaign_id
    from public.content_campaigns
    where organization_id = p_org_id and name = p_utm_campaign
    limit 1;
  end if;

  if p_utm_source is not null then
    v_confidence := 'utm';
    if lower(p_utm_source) in ('facebook', 'tiktok') then
      v_platform := lower(p_utm_source);
    end if;
  end if;

  insert into public.marketing_leads (
    workspace_id, organization_id, full_name, email, source_platform,
    campaign_id, content_id, utm_source, utm_medium, utm_campaign, utm_content,
    status, trial_signup_at
  ) values (
    v_ws_id, p_org_id, p_full_name, p_email, v_platform,
    v_campaign_id, v_content_id, p_utm_source, p_utm_medium, p_utm_campaign, p_utm_content,
    'trial_registered', now()
  )
  returning id into v_lead_id;

  insert into public.trial_conversions (
    lead_id, organization_id, workspace_id, user_id, campaign_id, content_id, attribution_confidence
  ) values (
    v_lead_id, p_org_id, v_ws_id, p_user_id, v_campaign_id, v_content_id, v_confidence
  );

  return v_lead_id;
end;
$$;

grant execute on function public.ensure_marketing_workspace(uuid) to authenticated;
grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;
grant execute on function public.approve_marketing_content(uuid) to authenticated;
grant execute on function public.reject_marketing_content(uuid, text) to authenticated;
grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

revoke execute on function public.claim_due_publishing_jobs(integer, text) from public, anon, authenticated;
revoke execute on function public.complete_publishing_job(uuid, boolean, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.mkt_notify(uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.claim_due_publishing_jobs(integer, text) to service_role;
grant execute on function public.complete_publishing_job(uuid, boolean, text, text, boolean) to service_role;
-- <<< END 0022_marketing_rpcs.sql

-- >>> BEGIN 0023_marketing_jobs.sql
-- ==============================================================================
-- Migration: 0023_marketing_jobs.sql
-- Description: Idempotent cron entrypoints for marketing automation.
-- ==============================================================================

create or replace function public.cron_detect_expired_social_connections()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
begin
  update public.social_accounts
     set connection_status = 'expired',
         last_error = 'Access token expired',
         updated_at = now()
   where connection_status = 'connected'
     and token_expires_at is not null
     and token_expires_at < now();

  get diagnostics v_count = row_count;

  insert into public.marketing_notifications (
    workspace_id, organization_id, notification_type, title, body, entity_type, entity_id
  )
  select sa.workspace_id, sa.organization_id, 'expired_connection',
         'Social connection expired',
         coalesce(sa.display_name, sa.provider) || ' needs to be reconnected.',
         'social_accounts', sa.id
  from public.social_accounts sa
  where sa.connection_status = 'expired'
    and sa.updated_at > now() - interval '2 minutes'
    and not exists (
      select 1 from public.marketing_notifications n
      where n.entity_id = sa.id
        and n.notification_type = 'expired_connection'
        and n.created_at > now() - interval '1 day'
    );

  return jsonb_build_object('expired_connections', v_count);
end;
$$;

create or replace function public.cron_notify_upcoming_scheduled_posts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
  v_rec record;
begin
  for v_rec in
    select c.*
    from public.marketing_contents c
    where c.status = 'scheduled'
      and c.scheduled_for between now() and now() + interval '2 hours'
  loop
    if not exists (
      select 1 from public.marketing_notifications n
      where n.entity_id = v_rec.id
        and n.notification_type = 'upcoming_scheduled'
        and n.created_at > now() - interval '12 hours'
    ) then
      perform public.mkt_notify(
        v_rec.organization_id, v_rec.workspace_id,
        'upcoming_scheduled',
        'Scheduled post is due soon',
        v_rec.title || ' publishes within 2 hours.',
        'marketing_contents',
        v_rec.id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return jsonb_build_object('notified', v_count);
end;
$$;

-- Placeholder cron: actual AI generation and analytics sync run in Edge Functions.
-- These SQL jobs stay idempotent and safe if pg_cron is unavailable.
do $outer$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'shopflow-marketing-expired-social') then
      perform cron.unschedule('shopflow-marketing-expired-social');
    end if;
    perform cron.schedule(
      'shopflow-marketing-expired-social',
      '15 * * * *',
      'select public.cron_detect_expired_social_connections()'
    );

    if exists (select 1 from cron.job where jobname = 'shopflow-marketing-upcoming-posts') then
      perform cron.unschedule('shopflow-marketing-upcoming-posts');
    end if;
    perform cron.schedule(
      'shopflow-marketing-upcoming-posts',
      '*/30 * * * *',
      'select public.cron_notify_upcoming_scheduled_posts()'
    );
  end if;
exception when others then
  null;
end $outer$;
-- <<< END 0023_marketing_jobs.sql

-- >>> BEGIN 0024_marketing_workflow_hardening.sql
-- Harden marketing workspace access and keep one active publishing job per post.
-- Safe for existing installations: duplicate queued jobs are cancelled, never deleted.

create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.role() = 'anon' then
    raise exception 'Authentication required';
  end if;

  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(p_org_id) then
    raise exception 'Access denied';
  end if;

  insert into public.marketing_workspaces (organization_id)
  values (p_org_id)
  on conflict (organization_id) do update set updated_at = public.marketing_workspaces.updated_at
  returning id into v_id;

  insert into public.marketing_settings (workspace_id, organization_id)
  values (v_id, p_org_id)
  on conflict (workspace_id) do nothing;

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  values
    (v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected', 'Connect via Meta OAuth. Publishing requires the relevant Meta permissions.'),
    (v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected', 'Connect via TikTok OAuth. Publishing requires Content Posting API access.')
  on conflict do nothing;

  return v_id;
end;
$$;

-- An authenticated caller may only initialize their own workspace. The org creation
-- trigger and trusted backend continue to call this function as its owner.
revoke execute on function public.ensure_marketing_workspace(uuid) from public, anon;
grant execute on function public.ensure_marketing_workspace(uuid) to authenticated, service_role;

-- Other security-definer RPCs rely on internal authorization checks. Remove the
-- default PUBLIC execute grant so anonymous callers cannot reach them at all.
revoke execute on function public.submit_marketing_content_for_review(uuid) from public, anon;
revoke execute on function public.approve_marketing_content(uuid) from public, anon;
revoke execute on function public.reject_marketing_content(uuid, text) from public, anon;
revoke execute on function public.schedule_marketing_content(uuid, timestamptz) from public, anon;
revoke execute on function public.enqueue_marketing_publish(uuid) from public, anon;
revoke execute on function public.approve_ad_campaign(uuid, numeric) from public, anon;
revoke execute on function public.record_ad_spend(uuid, numeric, text) from public, anon;
revoke execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) from public, anon;
revoke execute on function public.month_ad_spend(uuid, date) from public, anon;

grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;
grant execute on function public.approve_marketing_content(uuid) to authenticated;
grant execute on function public.reject_marketing_content(uuid, text) to authenticated;
grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;

-- Editing copy after approval would invalidate the owner's review. Edits while
-- draft, rejected, or pending review remain available and must be reviewed again.
create or replace function public.tg_marketing_content_status_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  rpc_flag text;
  content_changed boolean;
begin
  rpc_flag := current_setting('shopflow.marketing_rpc', true);
  if tg_op = 'INSERT' then
    if new.status <> 'draft' and coalesce(rpc_flag, '') is distinct from '1' then
      raise exception 'New marketing content must start as draft';
    end if;
    return new;
  end if;

  content_changed := row(
    new.title, new.platform, new.content_type, new.content_pillar,
    new.caption, new.hook, new.cta, new.hashtags, new.image_prompt,
    new.video_script, new.production_brief
  ) is distinct from row(
    old.title, old.platform, old.content_type, old.content_pillar,
    old.caption, old.hook, old.cta, old.hashtags, old.image_prompt,
    old.video_script, old.production_brief
  );

  if content_changed and old.status in ('approved', 'scheduled', 'publishing', 'published') then
    raise exception 'Approved content cannot be edited. Return it to review before changing copy.';
  end if;
  if content_changed and old.status = 'pending_review'
     and coalesce(rpc_flag, '') is distinct from '1' then
    raise exception 'Content in review can only be edited through the approval center';
  end if;

  if new.status is distinct from old.status
     and coalesce(rpc_flag, '') is distinct from '1' then
    if old.status in ('publishing', 'published') then
      raise exception 'Published content cannot be mutated from the client';
    end if;
    if new.status not in ('draft', 'pending_review', 'rejected', 'archived') then
      raise exception 'Status % must be applied through a server-side marketing RPC', new.status;
    end if;
    if new.status = 'pending_review' and old.status not in ('draft', 'rejected') then
      raise exception 'Only draft or rejected content can be submitted for review';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_marketing_contents_status_guard on public.marketing_contents;
create trigger trg_marketing_contents_status_guard
  before insert or update on public.marketing_contents
  for each row execute function public.tg_marketing_content_status_guard();

create or replace function public.edit_marketing_review_content(
  p_content_id uuid,
  p_caption text,
  p_hashtags text[]
)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  if p_caption is null or length(btrim(p_caption)) < 8 then
    raise exception 'Caption must be at least 8 characters';
  end if;
  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then raise exception 'Content not found'; end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may edit copy in the approval center';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Only content pending review can be edited here';
  end if;

  perform set_config('shopflow.marketing_rpc', '1', true);
  update public.marketing_contents
  set caption = p_caption, hashtags = coalesce(p_hashtags, '{}'), updated_at = now()
  where id = p_content_id returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'edited', auth.uid(), 'pending_review', 'pending_review'
  );
  return v_row;
end;
$$;

revoke execute on function public.edit_marketing_review_content(uuid, text, text[]) from public, anon;
grant execute on function public.edit_marketing_review_content(uuid, text, text[]) to authenticated;

-- Serialize spend approvals and actual entries on the workspace row so
-- concurrent campaigns cannot collectively pass the monthly ceiling.
create or replace function public.approve_ad_campaign(p_campaign_id uuid, p_approved_spend_mmk numeric)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_committed numeric;
  v_platform_committed numeric;
  v_platform_limit numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Ad campaign not found'; end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may approve advertising spend';
  end if;
  if p_approved_spend_mmk is null or p_approved_spend_mmk <= 0 then
    raise exception 'Approved spend must be greater than zero';
  end if;
  if v_row.owner_approved then
    raise exception 'This campaign already has an approved spend limit';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and owner_approved = true
    and status in ('approved', 'active');
  v_committed := v_committed + public.month_ad_spend(v_row.workspace_id, v_month);

  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_platform_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and owner_approved = true and status in ('approved', 'active');
  select v_platform_committed + coalesce(sum(amount_mmk), 0)
    into v_platform_committed
  from public.ad_budget_logs
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and entry_type = 'actual'
    and date_trunc('month', period_month) = date_trunc('month', v_month::timestamp);

  if v_committed + p_approved_spend_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Approved spend would exceed the remaining monthly budget';
  end if;
  v_platform_limit := case when v_row.platform = 'facebook'
    then v_ws.facebook_budget_mmk else v_ws.tiktok_budget_mmk end;
  if v_platform_committed + p_approved_spend_mmk > v_platform_limit then
    raise exception 'Approved spend would exceed the remaining platform allocation';
  end if;

  update public.ad_campaigns
  set status = 'approved', owner_approved = true,
      approved_spend_mmk = p_approved_spend_mmk,
      approved_by = auth.uid(), approved_at = now(), updated_at = now()
  where id = p_campaign_id returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_approved_spend_mmk, 'approved', 'Owner-approved advertising ceiling', auth.uid()
  );
  return v_row;
end;
$$;

create or replace function public.record_ad_spend(p_campaign_id uuid, p_amount_mmk numeric, p_notes text default null)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Ad campaign not found'; end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may record advertising spend';
  end if;
  if not v_row.owner_approved or v_row.status not in ('approved', 'active') then
    raise exception 'Spend cannot be recorded until the owner approves this campaign';
  end if;
  if p_amount_mmk is null or p_amount_mmk <= 0 then
    raise exception 'Spend amount must be greater than zero';
  end if;
  if v_row.actual_spend_mmk + p_amount_mmk > v_row.approved_spend_mmk then
    raise exception 'Spend would exceed the owner-approved campaign amount';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);
  if v_spent + p_amount_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Spend would exceed the monthly advertising budget';
  end if;

  update public.ad_campaigns
  set actual_spend_mmk = actual_spend_mmk + p_amount_mmk, status = 'active', updated_at = now()
  where id = p_campaign_id returning * into v_row;
  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_amount_mmk, 'actual', p_notes, auth.uid()
  );

  if public.month_ad_spend(v_row.workspace_id, v_month) >= v_ws.monthly_ad_budget_mmk * 0.8 then
    perform public.mkt_notify(
      v_row.organization_id, v_row.workspace_id, 'budget_threshold',
      'Advertising budget threshold reached',
      'Monthly advertising spend is at or above 80% of the approved budget.',
      'ad_campaigns', v_row.id
    );
  end if;
  return v_row;
end;
$$;

create or replace function public.month_ad_spend(
  p_workspace_id uuid,
  p_month date default (timezone('Asia/Yangon', now()))::date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.marketing_workspaces where id = p_workspace_id;
  if v_org_id is null then raise exception 'Marketing workspace not found'; end if;
  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(v_org_id) then
    raise exception 'Access denied';
  end if;
  return (
    select coalesce(sum(amount_mmk), 0)
    from public.ad_budget_logs
    where workspace_id = p_workspace_id and entry_type = 'actual'
      and date_trunc('month', period_month) = date_trunc('month', p_month::timestamp)
  );
end;
$$;

revoke execute on function public.approve_ad_campaign(uuid, numeric) from public, anon;
revoke execute on function public.record_ad_spend(uuid, numeric, text) from public, anon;
revoke execute on function public.month_ad_spend(uuid, date) from public, anon;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

create or replace function public.attribute_trial_signup(
  p_org_id uuid,
  p_user_id uuid,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_utm_content text default null,
  p_email text default null,
  p_full_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ws_id uuid;
  v_lead_id uuid;
  v_content_id uuid;
  v_campaign_id uuid;
  v_confidence text := 'unknown';
  v_platform text := 'website';
begin
  if auth.role() = 'anon' or auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if auth.uid() is distinct from p_user_id
     and not public.is_org_admin_or_owner(p_org_id)
     and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;
  if not public.has_org_membership(p_org_id) and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;

  select id into v_ws_id from public.marketing_workspaces where organization_id = p_org_id;
  if v_ws_id is null then raise exception 'Marketing workspace not found'; end if;

  if p_utm_content is not null then
    select id, campaign_id into v_content_id, v_campaign_id
    from public.marketing_contents
    where id::text = p_utm_content and organization_id = p_org_id
    limit 1;
  end if;

  if v_campaign_id is null and p_utm_campaign is not null then
    select id into v_campaign_id
    from public.content_campaigns
    where organization_id = p_org_id and name = p_utm_campaign
    limit 1;
  end if;

  if p_utm_source is not null then
    v_confidence := 'utm';
    if lower(p_utm_source) in ('facebook', 'tiktok') then
      v_platform := lower(p_utm_source);
    end if;
  end if;

  insert into public.marketing_leads (
    workspace_id, organization_id, full_name, email, source_platform,
    campaign_id, content_id, utm_source, utm_medium, utm_campaign, utm_content,
    status, trial_signup_at
  ) values (
    v_ws_id, p_org_id, nullif(btrim(p_full_name), ''), nullif(btrim(p_email), ''), v_platform,
    v_campaign_id, v_content_id, p_utm_source, p_utm_medium, p_utm_campaign, p_utm_content,
    'trial_registered', now()
  ) returning id into v_lead_id;

  insert into public.trial_conversions (
    lead_id, organization_id, workspace_id, user_id, campaign_id, content_id, attribution_confidence
  ) values (
    v_lead_id, p_org_id, v_ws_id, p_user_id, v_campaign_id, v_content_id, v_confidence
  );
  return v_lead_id;
end;
$$;

revoke execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;

create or replace function public.enqueue_marketing_publish(p_content_id uuid)
returns public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
  v_job public.publishing_jobs;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then raise exception 'Content not found'; end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may publish content';
  end if;
  if v_row.status not in ('approved', 'scheduled', 'failed') or v_row.approved_at is null then
    raise exception 'Content must be approved before publishing';
  end if;
  if exists (
    select 1 from public.publishing_jobs
    where content_id = p_content_id and status in ('queued', 'processing', 'succeeded', 'failed_retryable')
  ) then
    raise exception 'A publish job is already queued, in progress, or completed for this content';
  end if;

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id,
    v_row.id::text || ':immediate:' || gen_random_uuid()::text, 'queued', now()
  ) returning * into v_job;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (
    v_row.workspace_id, v_row.organization_id, v_job.id, v_row.id,
    'enqueued', jsonb_build_object('by', auth.uid(), 'retry', v_row.status = 'failed')
  );
  return v_job;
end;
$$;

revoke execute on function public.enqueue_marketing_publish(uuid) from public, anon;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;

-- Validate the workspace/organization pair and every marketing relationship.
-- Separate foreign keys alone would allow a member of one org to attach that
-- org's row to another org's workspace or content and confuse background jobs.
create or replace function public.tg_marketing_tenant_integrity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_workspace_id uuid := nullif(v_row ->> 'workspace_id', '')::uuid;
  v_org_id uuid := nullif(v_row ->> 'organization_id', '')::uuid;
  v_related_org uuid;
  v_related_workspace uuid;
  v_related_id uuid;
  v_target text;
  v_fk text;
begin
  if tg_op = 'UPDATE' and (
    nullif(to_jsonb(old) ->> 'workspace_id', '') is distinct from v_row ->> 'workspace_id'
    or nullif(to_jsonb(old) ->> 'organization_id', '') is distinct from v_row ->> 'organization_id'
  ) then
    raise exception 'Marketing records cannot be moved between workspaces';
  end if;

  if v_workspace_id is null or v_org_id is null then
    if tg_table_name <> 'marketing_leads' or (v_workspace_id is not null or v_org_id is not null) then
      raise exception 'Workspace and organization are required';
    end if;
  else
    select organization_id into v_related_org
    from public.marketing_workspaces where id = v_workspace_id;
    if v_related_org is distinct from v_org_id then
      raise exception 'Workspace does not belong to this organization';
    end if;
  end if;

  v_fk := case tg_table_name
    when 'content_ideas' then 'campaign_id'
    when 'marketing_contents' then 'campaign_id'
    when 'marketing_leads' then 'campaign_id'
    when 'content_assets' then 'content_id'
    when 'content_approvals' then 'content_id'
    when 'publishing_jobs' then 'content_id'
    when 'publishing_logs' then 'content_id'
    when 'social_analytics' then 'content_id'
    when 'ad_budget_logs' then 'ad_campaign_id'
    else null
  end;

  if tg_table_name = 'marketing_contents' and nullif(v_row ->> 'idea_id', '') is not null then
    v_related_id := (v_row ->> 'idea_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.content_ideas where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Content idea belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'marketing_leads' and nullif(v_row ->> 'content_id', '') is not null then
    v_related_id := (v_row ->> 'content_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.marketing_contents where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Attributed content belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'content_assets'
     and nullif(v_row ->> 'storage_path', '') is not null
     and split_part(v_row ->> 'storage_path', '/', 1) <> v_org_id::text then
    raise exception 'Asset path must be inside this organization folder';
  end if;

  if tg_table_name in ('publishing_jobs', 'social_analytics')
     and nullif(v_row ->> 'social_account_id', '') is not null then
    v_related_id := (v_row ->> 'social_account_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.social_accounts where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Social account belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'trial_conversions' and nullif(v_row ->> 'lead_id', '') is not null then
    v_related_id := (v_row ->> 'lead_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.marketing_leads where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Lead belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'trial_conversions' then
    foreach v_fk in array array['campaign_id', 'content_id'] loop
      if nullif(v_row ->> v_fk, '') is not null then
        v_related_id := (v_row ->> v_fk)::uuid;
        v_target := case v_fk when 'campaign_id' then 'content_campaigns' else 'marketing_contents' end;
        execute format('select organization_id, workspace_id from public.%I where id = $1', v_target)
          into v_related_org, v_related_workspace using v_related_id;
        if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
          raise exception 'Trial attribution points to another workspace';
        end if;
      end if;
    end loop;
  end if;

  if tg_table_name = 'publishing_logs' and nullif(v_row ->> 'job_id', '') is not null then
    v_related_id := (v_row ->> 'job_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.publishing_jobs where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Publishing job belongs to another workspace';
    end if;
  end if;

  if v_fk is not null and nullif(v_row ->> v_fk, '') is not null then
    v_related_id := (v_row ->> v_fk)::uuid;
    v_target := case v_fk
      when 'campaign_id' then 'content_campaigns'
      when 'content_id' then 'marketing_contents'
      when 'ad_campaign_id' then 'ad_campaigns'
    end;
    execute format('select organization_id, workspace_id from public.%I where id = $1', v_target)
      into v_related_org, v_related_workspace using v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Related marketing record belongs to another workspace';
    end if;
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'marketing_settings', 'social_accounts', 'content_campaigns', 'content_ideas',
    'marketing_contents', 'content_assets', 'content_approvals',
    'publishing_jobs', 'publishing_logs', 'social_analytics', 'marketing_leads',
    'trial_conversions', 'ad_campaigns', 'ad_budget_logs', 'marketing_notifications',
    'ai_generation_logs', 'marketing_reports'
  ] loop
    execute format('drop trigger if exists trg_%I_tenant_integrity on public.%I', t, t);
    execute format(
      'create trigger trg_%I_tenant_integrity before insert or update on public.%I for each row execute function public.tg_marketing_tenant_integrity()',
      t, t
    );
  end loop;
end $$;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

-- Retain one active job per content before adding the future uniqueness guard.
with ranked_active_jobs as (
  select id,
         row_number() over (
           partition by content_id
           order by case when status = 'processing' then 0 else 1 end,
                    next_attempt_at desc, created_at desc, id desc
         ) as position
  from public.publishing_jobs
  where status in ('queued', 'processing', 'failed_retryable')
)
update public.publishing_jobs j
set status = case when j.status = 'processing' then 'failed_permanent' else 'cancelled' end,
    last_error = 'Superseded by a newer schedule',
    locked_at = null,
    updated_at = now()
from ranked_active_jobs r
where j.id = r.id and r.position > 1;

create unique index if not exists uq_publishing_jobs_one_active_per_content
  on public.publishing_jobs (content_id)
  where status in ('queued', 'processing', 'failed_retryable');

create or replace function public.schedule_marketing_content(p_content_id uuid, p_scheduled_for timestamptz)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
  v_active_job public.publishing_jobs;
  v_from_status text;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_scheduled_for is null or p_scheduled_for <= now() then
    raise exception 'Choose a future scheduled time';
  end if;

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may schedule content';
  end if;
  if v_row.status not in ('approved', 'scheduled') then
    raise exception 'Only approved content can be scheduled';
  end if;
  v_from_status := v_row.status;

  select * into v_active_job
  from public.publishing_jobs
  where content_id = p_content_id
    and status in ('processing', 'succeeded')
  order by created_at desc
  limit 1
  for update;
  if found then
    raise exception 'Content is already publishing or has already been published';
  end if;

  update public.publishing_jobs
  set status = 'cancelled',
      last_error = 'Superseded by a newer schedule',
      updated_at = now()
  where content_id = p_content_id
    and status in ('queued', 'failed_retryable');

  update public.marketing_contents
    set status = 'scheduled', scheduled_for = p_scheduled_for, updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'scheduled', auth.uid(), v_from_status, 'scheduled'
  );

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id,
    v_row.id::text || ':' || p_scheduled_for::text, 'queued', p_scheduled_for
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'upcoming_scheduled', 'Post scheduled',
    v_row.title || ' is scheduled for publishing.',
    'marketing_contents', v_row.id
  );

  return v_row;
end;
$$;

grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;

-- Also recover jobs whose worker exited while holding a stale processing lock.
create or replace function public.claim_due_publishing_jobs(p_limit integer default 10, p_worker text default 'edge')
returns setof public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  return query
  with due as (
    select j.id
    from public.publishing_jobs j
    join public.marketing_contents c on c.id = j.content_id
    where j.status in ('queued', 'failed_retryable', 'processing')
      and j.next_attempt_at <= now()
      and j.attempt_count < j.max_attempts
      and (j.locked_at is null or j.locked_at < now() - interval '10 minutes')
      and c.status in ('approved', 'scheduled', 'failed')
      and c.approved_at is not null
      and c.approved_by is not null
    order by j.next_attempt_at
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update of j skip locked
  )
  update public.publishing_jobs j
     set status = 'processing', locked_at = now(), locked_by = p_worker,
         attempt_count = j.attempt_count + 1, updated_at = now()
    from due
   where j.id = due.id
   returning j.*;
end;
$$;

revoke execute on function public.claim_due_publishing_jobs(integer, text) from public, anon, authenticated;
grant execute on function public.claim_due_publishing_jobs(integer, text) to service_role;
-- <<< END 0024_marketing_workflow_hardening.sql

-- >>> BEGIN 0025_marketing_platform_admin_only.sql
-- ShopFlow's marketing automation is a platform-admin feature, not a tenant feature.
-- Keep existing rows and their organization association, but remove tenant access.

create or replace function public.is_marketing_manager(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_platform_admin();
$$;

create or replace function public.can_approve_marketing(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_platform_admin();
$$;

-- Stop automatically creating a marketing workspace for every new shop.
drop trigger if exists trg_org_seed_marketing_workspace on public.organizations;

-- Replace tenant membership policies with one platform-admin-only policy on
-- every client-facing marketing table. Secrets and OAuth state remain service-only.
do $$
declare
  v_table_name text;
  v_policy_name text;
  marketing_tables text[] := array[
    'marketing_workspaces', 'marketing_settings', 'social_accounts',
    'content_campaigns', 'content_ideas', 'marketing_contents', 'content_assets',
    'content_approvals', 'publishing_jobs', 'publishing_logs', 'social_analytics',
    'marketing_leads', 'trial_conversions', 'ad_campaigns', 'ad_budget_logs',
    'ai_generation_logs', 'marketing_reports', 'marketing_notifications'
  ];
begin
  foreach v_table_name in array marketing_tables loop
    execute format('drop policy if exists mkt_platform_admin_only on public.%I', v_table_name);
    for v_policy_name in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = v_table_name
    loop
      execute format('drop policy %I on public.%I', v_policy_name, v_table_name);
    end loop;
    execute format(
      'create policy mkt_platform_admin_only on public.%I for all using (public.is_platform_admin()) with check (public.is_platform_admin())',
      v_table_name
    );
  end loop;
end;
$$;

-- Workspace initialization is now a platform-only operation.
create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  insert into public.marketing_workspaces (organization_id)
  values (p_org_id)
  on conflict (organization_id) do update set updated_at = public.marketing_workspaces.updated_at
  returning id into v_id;

  insert into public.marketing_settings (workspace_id, organization_id)
  values (v_id, p_org_id)
  on conflict (workspace_id) do nothing;

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  values
    (v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected', 'Connect via Meta OAuth.'),
    (v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected', 'Connect via TikTok OAuth.')
  on conflict do nothing;

  return v_id;
end;
$$;

revoke execute on function public.ensure_marketing_workspace(uuid) from public, anon;
grant execute on function public.ensure_marketing_workspace(uuid) to authenticated, service_role;

create or replace function public.submit_marketing_content_for_review(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then raise exception 'Content not found'; end if;
  if v_row.status not in ('draft', 'rejected') then
    raise exception 'Only draft or rejected content can be submitted for review';
  end if;
  if length(btrim(v_row.caption)) < 8 then
    raise exception 'Caption is required before review';
  end if;

  update public.marketing_contents
  set status = 'pending_review', rejection_reason = null, updated_at = now()
  where id = p_content_id returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'submitted', auth.uid(), 'draft', 'pending_review'
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id, 'pending_approval',
    'Content awaiting approval', v_row.title || ' is ready for review.',
    'marketing_contents', v_row.id
  );

  return v_row;
end;
$$;

revoke execute on function public.submit_marketing_content_for_review(uuid) from public, anon;
grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;

-- Keep spend approval RPCs platform-admin-only as SECURITY DEFINER functions.
create or replace function public.approve_ad_campaign(p_campaign_id uuid, p_approved_spend_mmk numeric)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_committed numeric;
  v_platform_committed numeric;
  v_platform_limit numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Ad campaign not found'; end if;
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;
  if p_approved_spend_mmk is null or p_approved_spend_mmk <= 0 then
    raise exception 'Approved spend must be greater than zero';
  end if;
  if v_row.owner_approved then
    raise exception 'This campaign already has an approved spend limit';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and owner_approved = true
    and status in ('approved', 'active');
  v_committed := v_committed + public.month_ad_spend(v_row.workspace_id, v_month);

  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_platform_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and owner_approved = true and status in ('approved', 'active');
  select v_platform_committed + coalesce(sum(amount_mmk), 0)
    into v_platform_committed
  from public.ad_budget_logs
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and entry_type = 'actual'
    and date_trunc('month', period_month) = date_trunc('month', v_month::timestamp);

  if v_committed + p_approved_spend_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Approved spend would exceed the remaining monthly budget';
  end if;
  v_platform_limit := case when v_row.platform = 'facebook'
    then v_ws.facebook_budget_mmk else v_ws.tiktok_budget_mmk end;
  if v_platform_committed + p_approved_spend_mmk > v_platform_limit then
    raise exception 'Approved spend would exceed the remaining platform allocation';
  end if;

  update public.ad_campaigns
  set status = 'approved', owner_approved = true,
      approved_spend_mmk = p_approved_spend_mmk,
      approved_by = auth.uid(), approved_at = now(), updated_at = now()
  where id = p_campaign_id returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_approved_spend_mmk, 'approved', 'Owner-approved advertising ceiling', auth.uid()
  );
  return v_row;
end;
$$;

create or replace function public.record_ad_spend(p_campaign_id uuid, p_amount_mmk numeric, p_notes text default null)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Ad campaign not found'; end if;
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;
  if not v_row.owner_approved or v_row.status not in ('approved', 'active') then
    raise exception 'Spend cannot be recorded until the owner approves this campaign';
  end if;
  if p_amount_mmk is null or p_amount_mmk <= 0 then
    raise exception 'Spend amount must be greater than zero';
  end if;
  if v_row.actual_spend_mmk + p_amount_mmk > v_row.approved_spend_mmk then
    raise exception 'Spend would exceed the owner-approved campaign amount';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);
  if v_spent + p_amount_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Spend would exceed the monthly advertising budget';
  end if;

  update public.ad_campaigns
  set actual_spend_mmk = actual_spend_mmk + p_amount_mmk, status = 'active', updated_at = now()
  where id = p_campaign_id returning * into v_row;
  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_amount_mmk, 'actual', p_notes, auth.uid()
  );

  if public.month_ad_spend(v_row.workspace_id, v_month) >= v_ws.monthly_ad_budget_mmk * 0.8 then
    perform public.mkt_notify(
      v_row.organization_id, v_row.workspace_id, 'budget_threshold',
      'Advertising budget threshold reached',
      'Monthly advertising spend is at or above 80% of the approved budget.',
      'ad_campaigns', v_row.id
    );
  end if;
  return v_row;
end;
$$;
-- <<< END 0025_marketing_platform_admin_only.sql

-- >>> BEGIN 0026_platform_ai_credentials.sql
-- Store user supplied AI provider keys encrypted for platform marketing only.
create table if not exists public.platform_ai_credentials (
  provider text primary key check (provider in ('openai', 'gemini')),
  api_key_encrypted text not null,
  configured_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.platform_ai_credentials enable row level security;
revoke all on public.platform_ai_credentials from anon, authenticated;
grant all on public.platform_ai_credentials to service_role;
-- <<< END 0026_platform_ai_credentials.sql

-- >>> BEGIN 0027_subscription_flow_hardening.sql
-- Harden the existing subscription flow without replacing its tables or data.
alter table public.subscriptions
  add column if not exists grace_period_ends_at timestamptz;

alter table public.subscriptions drop constraint if exists subscriptions_status_check;
alter table public.subscriptions add constraint subscriptions_status_check
  check (status in ('trialing', 'active', 'past_due', 'expired', 'canceled', 'suspended'));

alter table public.subscription_payments
  add column if not exists subscription_event_id uuid references public.subscription_events(id) on delete set null;
create unique index if not exists subscription_payments_event_unique
  on public.subscription_payments(subscription_event_id) where subscription_event_id is not null;

-- Existing pending payment events become pending payment records, preserving history.
insert into public.subscription_payments (
  subscription_id, organization_id, amount, currency, payment_method,
  transaction_reference, payment_status, notes, subscription_event_id, created_at
)
select e.subscription_id, e.organization_id, coalesce(e.amount, 0), 'MMK',
       e.payment_method, e.payment_reference, 'pending', e.admin_notes, e.id, e.created_at
from public.subscription_events e
where e.event_type = 'payment_submitted'
on conflict (subscription_event_id) where subscription_event_id is not null do nothing;

create or replace function public._resolve_subscription_status(p_org_id uuid, out v_status text, out v_plan_id text)
returns record language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype;
begin
  v_status := 'none'; v_plan_id := null;
  select * into s from public.subscriptions where organization_id = p_org_id;
  if not found then return; end if;
  v_plan_id := s.plan_id;
  case s.status
    when 'trialing' then v_status := case when s.trial_ends_at > now() then 'trialing' else 'expired' end;
    when 'active' then
      if s.current_period_end > now() then v_status := 'active';
      elsif s.grace_period_ends_at > now() then v_status := 'past_due';
      else v_status := 'expired'; end if;
    when 'past_due' then v_status := case when s.grace_period_ends_at > now() then 'past_due' else 'expired' end;
    when 'canceled' then v_status := case when s.cancel_at_period_end and s.current_period_end > now() then 'active' else 'canceled' end;
    else v_status := s.status;
  end case;
end $$;
revoke all on function public._resolve_subscription_status(uuid) from public, anon, authenticated;

create or replace function public.get_organization_subscription(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; p public.plans%rowtype; resolved text; plan_id text;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id;
  if not found then return jsonb_build_object('found',false,'status','none'); end if;
  select * into p from public.plans where id=s.plan_id;
  select * into resolved,plan_id from public._resolve_subscription_status(p_org_id);
  return jsonb_build_object('found',true,'subscription_id',s.id,'organization_id',s.organization_id,'plan_id',s.plan_id,
    'plan_name',p.name,'plan_slug',p.slug,'monthly_price',p.monthly_price_mmk,'yearly_price',p.yearly_price_mmk,
    'status',resolved,'stored_status',s.status,'billing_cycle',s.billing_cycle,'starts_at',s.starts_at,
    'trial_ends_at',s.trial_ends_at,'current_period_start',s.current_period_start,'current_period_end',s.current_period_end,
    'grace_period_ends_at',s.grace_period_ends_at,'cancel_at_period_end',s.cancel_at_period_end,'expires_at',s.expires_at);
end $$;
revoke all on function public.get_organization_subscription(uuid) from public, anon;
grant execute on function public.get_organization_subscription(uuid) to authenticated;

create or replace function public.get_organization_feature_limit(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare f public.features%rowtype; o public.organization_feature_overrides%rowtype; lim integer;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into f from public.features where feature_key = p_feature_key and is_active;
  if not found then return jsonb_build_object('limit_value', 0, 'has_override', false, 'feature_key', p_feature_key); end if;
  select * into o from public.organization_feature_overrides
   where organization_id = p_org_id and feature_id = f.id and limit_override is not null
     and starts_at <= now() and (expires_at is null or expires_at > now())
   order by created_at desc limit 1;
  if found then return jsonb_build_object('limit_value', o.limit_override, 'has_override', true, 'feature_key', p_feature_key); end if;
  select pfl.limit_value into lim from public.subscriptions s join public.plan_feature_limits pfl on pfl.plan_id = s.plan_id
   where s.organization_id = p_org_id and pfl.feature_id = f.id;
  return jsonb_build_object('limit_value', coalesce(lim, -1), 'has_override', false, 'feature_key', p_feature_key);
end $$;
revoke all on function public.get_organization_feature_limit(uuid,text) from public, anon;
grant execute on function public.get_organization_feature_limit(uuid,text) to authenticated;

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
    when 'max_branches' then n := 1;
    else n := 0;
  end case;
  return n;
end $$;
revoke all on function public.get_organization_usage(uuid,text) from public, anon;
grant execute on function public.get_organization_usage(uuid,text) to authenticated;

create or replace function public.check_organization_feature(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare st text; pid text; f public.features%rowtype; o public.organization_feature_overrides%rowtype; enabled boolean;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into st, pid from public._resolve_subscription_status(p_org_id);
  select * into f from public.features where feature_key=p_feature_key and is_active;
  if not found then return jsonb_build_object('is_allowed',false,'feature_key',p_feature_key,'reason','Feature not found','subscription_status',st); end if;
  select * into o from public.organization_feature_overrides where organization_id=p_org_id and feature_id=f.id
    and starts_at<=now() and (expires_at is null or expires_at>now()) order by created_at desc limit 1;
  if found and o.is_enabled is not null then
    return jsonb_build_object('is_allowed',o.is_enabled,'feature_key',p_feature_key,'reason','Organization override','subscription_status',st);
  end if;
  if st not in ('active','trialing') then
    return jsonb_build_object('is_allowed',false,'feature_key',p_feature_key,'reason','Subscription '||st,'subscription_status',st);
  end if;
  select is_enabled into enabled from public.plan_features where plan_id=pid and feature_id=f.id;
  return jsonb_build_object('is_allowed',coalesce(enabled,false),'feature_key',p_feature_key,
    'reason',case when enabled then 'Included in '||pid||' plan' else 'Not included in plan' end,'subscription_status',st);
end $$;
revoke all on function public.check_organization_feature(uuid,text) from public, anon;
grant execute on function public.check_organization_feature(uuid,text) to authenticated;

create or replace function public.check_organization_limit(p_org_id uuid, p_feature_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare st text; pid text; li jsonb; feature_access jsonb; lim int; used int; allowed boolean; feature_key text;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  select * into st, pid from public._resolve_subscription_status(p_org_id);
  feature_key := case p_feature_key when 'max_users' then 'max_users' when 'max_products' then 'product_management'
    when 'max_customers' then 'customer_management' when 'max_suppliers' then 'supplier_management' else p_feature_key end;
  li := public.get_organization_feature_limit(p_org_id,p_feature_key);
  feature_access := public.check_organization_feature(p_org_id,feature_key);
  lim := coalesce((li->>'limit_value')::int, -1);
  used := public.get_organization_usage(p_org_id,p_feature_key);
  allowed := coalesce((feature_access->>'is_allowed')::boolean,false) and (lim=-1 or used<lim);
  return jsonb_build_object('is_allowed',allowed,'feature_key',p_feature_key,'current_usage',used,'limit_value',lim,
    'remaining_usage',case when lim=-1 then -1 else greatest(0,lim-used) end,'subscription_status',st,
    'reason',case when st not in ('active','trialing') then 'Subscription '||st when allowed then 'Within limit' else 'Limit reached' end);
end $$;
revoke all on function public.check_organization_limit(uuid,text) from public, anon;
grant execute on function public.check_organization_limit(uuid,text) to authenticated;

create or replace function public.get_organization_entitlements(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb := '[]'::jsonb; f record; access jsonb; lim jsonb; used int; limit_value int;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then raise exception 'Access denied'; end if;
  for f in select feature_key,name,feature_type,category from public.features where is_active order by category,name loop
    access := public.check_organization_feature(p_org_id,f.feature_key);
    limit_value := null; used := null;
    if f.feature_type='limit' then
      lim := public.get_organization_feature_limit(p_org_id,f.feature_key);
      limit_value := (lim->>'limit_value')::int;
      used := public.get_organization_usage(p_org_id,f.feature_key);
    end if;
    result := result || jsonb_build_object('feature_key',f.feature_key,'feature_name',f.name,'feature_type',f.feature_type,
      'category',f.category,'is_allowed',(access->>'is_allowed')::boolean,'reason',access->>'reason',
      'current_usage',used,'limit_value',limit_value,'remaining_usage',case when limit_value is null then null when limit_value=-1 then -1 else greatest(0,limit_value-used) end,
      'subscription_status',access->>'subscription_status');
  end loop;
  return result;
end $$;
revoke all on function public.get_organization_entitlements(uuid) from public, anon;
grant execute on function public.get_organization_entitlements(uuid) to authenticated;

create or replace function public.enforce_plan_entitlements()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare org_id uuid; key text; feature_key text; usage_key text; check_result jsonb; is_new boolean;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  key := tg_argv[0]; usage_key := tg_argv[1];
  is_new := tg_op='INSERT' or (tg_op='UPDATE' and coalesce(old.is_active,true)=false and coalesce(new.is_active,true));
  if not is_new then return new; end if;
  -- The initial owner is inserted before the trial row by organization bootstrap.
  if usage_key='max_users' and not exists(select 1 from public.subscriptions where organization_id=org_id)
     and not exists(select 1 from public.organization_members where organization_id=org_id and is_active)
     and new.user_id=auth.uid() and new.role='owner' then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(org_id::text||':'||usage_key,0));
  feature_key := case usage_key when 'max_products' then 'product_management' when 'max_users' then 'max_users'
    when 'max_customers' then 'customer_management' when 'max_suppliers' then 'supplier_management' else key end;
  check_result := public.check_organization_feature(org_id,feature_key);
  if not coalesce((check_result->>'is_allowed')::boolean,false) then raise exception 'This feature is not available: %', check_result->>'reason'; end if;
  if usage_key is not null then
    check_result := public.check_organization_limit(org_id,usage_key);
    if not coalesce((check_result->>'is_allowed')::boolean,false) then raise exception 'Plan limit reached: %',check_result->>'reason'; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit before insert or update of is_active on public.products
for each row execute function public.enforce_plan_entitlements('product_management','max_products');
drop trigger if exists trg_enforce_user_plan_limit on public.organization_members;
create trigger trg_enforce_user_plan_limit before insert or update of is_active on public.organization_members
for each row execute function public.enforce_plan_entitlements('user_management','max_users');
drop trigger if exists trg_enforce_customer_plan_limit on public.customers;
create trigger trg_enforce_customer_plan_limit before insert or update of is_active on public.customers
for each row execute function public.enforce_plan_entitlements('customer_management','max_customers');
drop trigger if exists trg_enforce_supplier_plan_limit on public.suppliers;
create trigger trg_enforce_supplier_plan_limit before insert or update of is_active on public.suppliers
for each row execute function public.enforce_plan_entitlements('supplier_management','max_suppliers');

create or replace function public.enforce_feature_access_on_write()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare org_id uuid; feature_key text; result jsonb;
begin
  org_id := new.organization_id;
  feature_key := tg_argv[0];
  result := public.check_organization_feature(org_id,feature_key);
  if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This feature is not available: %',result->>'reason'; end if;
  if tg_table_name='sales' and tg_op='UPDATE' and new.status='confirmed' and old.status is distinct from 'confirmed' then
    feature_key := case new.payment_status when 'paid' then 'cash_sales' when 'partial' then 'partial_payments' else 'credit_sales' end;
    result := public.check_organization_feature(org_id,feature_key);
    if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This sale type is not available on the current plan: %',feature_key; end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_sales_plan_feature on public.sales;
create trigger trg_sales_plan_feature before insert or update of status on public.sales
for each row execute function public.enforce_feature_access_on_write('sales_management');
drop trigger if exists trg_purchases_plan_feature on public.purchases;
create trigger trg_purchases_plan_feature before insert on public.purchases
for each row execute function public.enforce_feature_access_on_write('purchase_management');
drop trigger if exists trg_categories_plan_feature on public.product_categories;
create trigger trg_categories_plan_feature before insert or update on public.product_categories
for each row execute function public.enforce_feature_access_on_write('category_management');
drop trigger if exists trg_units_plan_feature on public.units;
create trigger trg_units_plan_feature before insert or update on public.units
for each row execute function public.enforce_feature_access_on_write('product_management');
drop trigger if exists trg_expenses_plan_feature on public.expenses;
create trigger trg_expenses_plan_feature before insert on public.expenses
for each row execute function public.enforce_feature_access_on_write('expense_management');
drop trigger if exists trg_stock_adjustments_plan_feature on public.stock_adjustments;
create trigger trg_stock_adjustments_plan_feature before insert on public.stock_adjustments
for each row execute function public.enforce_feature_access_on_write('stock_adjustment');

create or replace function public.enforce_stock_movement_plan_feature()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare required_feature text; result jsonb;
begin
  required_feature := case new.movement_type
    when 'adjustment_in' then 'stock_adjustment'
    when 'adjustment_out' then 'stock_adjustment'
    when 'customer_return' then 'sales_management'
    when 'supplier_return' then 'supplier_payables'
    else null
  end;
  if required_feature is not null then
    result := public.check_organization_feature(new.organization_id,required_feature);
    if not coalesce((result->>'is_allowed')::boolean,false) then raise exception 'This stock operation is not available on the current plan: %',required_feature; end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_stock_movement_plan_feature on public.stock_movements;
create trigger trg_stock_movement_plan_feature before insert on public.stock_movements
for each row execute function public.enforce_stock_movement_plan_feature();

-- Payment request and approval are linked to the existing event history and are idempotent.
create or replace function public.submit_subscription_payment(p_org_id uuid,p_plan_id text,p_billing_cycle text,p_payment_method text,p_reference_number text,p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; p public.plans%rowtype; amount_due numeric(12,2); event_id uuid;
begin
  if not (public.is_org_admin_or_owner(p_org_id) or public.is_platform_admin()) then raise exception 'Unauthorized to submit subscription payment'; end if;
  if p_billing_cycle not in ('monthly','yearly') or nullif(trim(p_reference_number),'') is null then raise exception 'Valid billing cycle and payment reference are required'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id for update;
  if not found then raise exception 'Subscription record not found'; end if;
  select * into p from public.plans where id=p_plan_id and is_active and is_public;
  if not found then raise exception 'Plan is unavailable'; end if;
  if exists(select 1 from public.subscription_events where organization_id=p_org_id and event_type='payment_submitted' and payment_reference=trim(p_reference_number)) then raise exception 'Payment reference already submitted'; end if;
  amount_due := case when p_billing_cycle='yearly' then p.yearly_price_mmk else p.monthly_price_mmk end;
  insert into public.subscription_events(subscription_id,organization_id,event_type,amount,payment_method,payment_reference,admin_notes,plan_id,billing_cycle)
  values(s.id,p_org_id,'payment_submitted',amount_due,p_payment_method,trim(p_reference_number),p_notes,p_plan_id,p_billing_cycle) returning id into event_id;
  insert into public.subscription_payments(subscription_id,organization_id,amount,currency,payment_method,transaction_reference,payment_status,notes,subscription_event_id)
  values(s.id,p_org_id,amount_due,p.currency,p_payment_method,trim(p_reference_number),'pending',p_notes,event_id);
  return jsonb_build_object('success',true,'event_id',event_id,'amount',amount_due,'plan_id',p_plan_id,'billing_cycle',p_billing_cycle);
end $$;
revoke all on function public.submit_subscription_payment(uuid,text,text,text,text,text) from public, anon;
grant execute on function public.submit_subscription_payment(uuid,text,text,text,text,text) to authenticated;

create or replace function public.initialize_organization_trial(p_org_id uuid,p_plan_id text default 'starter')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.plans%rowtype; s public.subscriptions%rowtype; sub_id uuid; period_end timestamptz;
begin
  if not (public.is_org_admin_or_owner(p_org_id) or public.is_platform_admin()) then raise exception 'Unauthorized to initialize organization trial'; end if;
  select * into s from public.subscriptions where organization_id=p_org_id for update;
  if found then return s.id; end if;
  select * into p from public.plans where id=p_plan_id and is_active and is_public;
  if not found then raise exception 'Selected plan is unavailable'; end if;
  period_end := now() + make_interval(days => p.trial_days);
  insert into public.subscriptions(organization_id,plan_id,status,billing_cycle,starts_at,current_period_start,current_period_end,expires_at,trial_ends_at)
    values(p_org_id,p.id,'trialing','monthly',now(),now(),period_end,period_end,period_end) returning id into sub_id;
  insert into public.usage_limits(organization_id,metric,period_key,current_value,limit_value) values
    (p_org_id,'product_count','lifetime',0,p.max_products),
    (p_org_id,'user_count','lifetime',1,p.max_users),
    (p_org_id,'monthly_sales_count',to_char(now(),'YYYY-MM'),0,p.max_monthly_sales)
    on conflict(organization_id,metric,period_key) do nothing;
  insert into public.subscription_events(subscription_id,organization_id,event_type,admin_notes)
    values(sub_id,p_org_id,'trial_started','Trial started for '||p.trial_days||' days');
  insert into public.subscription_audit_logs(organization_id,subscription_id,action,new_value,performed_by)
    values(p_org_id,sub_id,'trial_started',jsonb_build_object('plan_id',p.id,'trial_ends_at',period_end),auth.uid());
  return sub_id;
end $$;
revoke all on function public.initialize_organization_trial(uuid,text) from public, anon;
grant execute on function public.initialize_organization_trial(uuid,text) to authenticated;

drop function if exists public.verify_subscription_payment(uuid,uuid,boolean,text);
create or replace function public.verify_subscription_payment(p_sub_id uuid,p_event_id uuid,p_approve boolean,p_admin_notes text default null,p_target_plan_id text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.subscriptions%rowtype; e public.subscription_events%rowtype; pay public.subscription_payments%rowtype; p public.plans%rowtype;
  target_id text; cycle text; duration interval; expected_amount numeric(14,2); old_value jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin privileges required'; end if;
  select * into s from public.subscriptions where id=p_sub_id for update;
  if not found then raise exception 'Subscription not found'; end if;
  select * into e from public.subscription_events where id=p_event_id and subscription_id=p_sub_id for update;
  if not found or e.event_type <> 'payment_submitted' then raise exception 'Pending payment event not found'; end if;
  select * into pay from public.subscription_payments where subscription_event_id=e.id for update;
  if not found or pay.payment_status <> 'pending' then raise exception 'Payment already processed or missing'; end if;
  if p_approve then
    target_id := coalesce(e.plan_id,s.plan_id);
    if p_target_plan_id is not null and p_target_plan_id <> target_id then raise exception 'Approval plan must match the submitted payment'; end if;
    cycle := coalesce(e.billing_cycle,s.billing_cycle,'monthly');
    select * into p from public.plans where id=target_id and is_active;
    if not found then raise exception 'Plan is unavailable'; end if;
    expected_amount := case when cycle='yearly' then p.yearly_price_mmk else p.monthly_price_mmk end;
    if pay.amount <> expected_amount then raise exception 'Payment amount does not match the selected plan'; end if;
    duration := case when cycle='yearly' then interval '1 year' else interval '1 month' end;
    old_value := jsonb_build_object('plan_id',s.plan_id,'status',s.status,'billing_cycle',s.billing_cycle,'period_end',s.current_period_end);
    update public.subscriptions set plan_id=target_id,billing_cycle=cycle,status='active',starts_at=now(),current_period_start=now(),
      current_period_end=now()+duration,expires_at=now()+duration,trial_ends_at=null,grace_period_ends_at=null,updated_at=now() where id=s.id;
    update public.subscription_payments set payment_status='paid',paid_at=now(),reviewed_by=auth.uid(),notes=coalesce(p_admin_notes,notes) where id=pay.id;
    update public.subscription_events set event_type='payment_approved',admin_notes=p_admin_notes where id=e.id;
    insert into public.subscription_audit_logs(organization_id,subscription_id,action,old_value,new_value,performed_by)
      values(s.organization_id,s.id,'payment_approved',old_value,jsonb_build_object('plan_id',target_id,'status','active','billing_cycle',cycle,'amount',pay.amount),auth.uid());
    return jsonb_build_object('success',true,'status','active','plan_id',target_id,'current_period_end',now()+duration);
  end if;
  update public.subscription_payments set payment_status='failed',reviewed_by=auth.uid(),notes=coalesce(p_admin_notes,notes) where id=pay.id;
  update public.subscription_events set event_type='payment_rejected',admin_notes=p_admin_notes where id=e.id;
  insert into public.subscription_audit_logs(organization_id,subscription_id,action,old_value,new_value,performed_by)
    values(s.organization_id,s.id,'payment_rejected',jsonb_build_object('status',s.status),jsonb_build_object('notes',p_admin_notes),auth.uid());
  return jsonb_build_object('success',true,'status','rejected');
end $$;
revoke all on function public.verify_subscription_payment(uuid,uuid,boolean,text,text) from public, anon;
grant execute on function public.verify_subscription_payment(uuid,uuid,boolean,text,text) to authenticated;

-- Restrict direct configuration writes to platform admins; clients use audited RPCs.
drop policy if exists "Plans readable by all" on public.plans;
create policy "Public plans and admin plan visibility" on public.plans for select
  using ((is_active and is_public) or public.is_platform_admin());
drop policy if exists "features_write_admin" on public.features;
create policy "features_write_admin" on public.features for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "plan_features_write_admin" on public.plan_features;
create policy "plan_features_write_admin" on public.plan_features for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "plan_feature_limits_write_admin" on public.plan_feature_limits;
create policy "plan_feature_limits_write_admin" on public.plan_feature_limits for all using (public.is_platform_admin()) with check (public.is_platform_admin());
drop policy if exists "sub_payments_write_admin" on public.subscription_payments;
create policy "sub_payments_write_admin" on public.subscription_payments for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create or replace function public.admin_update_plan_configuration(p_plan jsonb,p_features jsonb)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare pid text; entry jsonb; fid uuid; old_plan jsonb;
begin
  if not public.is_platform_admin() then raise exception 'Platform admin privileges required'; end if;
  pid := p_plan->>'id';
  select to_jsonb(p) into old_plan from public.plans p where p.id=pid for update;
  if old_plan is null then
    insert into public.plans(id,name,description,slug,price,billing_interval,monthly_price_mmk,yearly_price_mmk,trial_days,
      max_users,max_products,max_monthly_sales,features,is_active,is_public,display_order,currency,max_customers,max_suppliers,max_branches)
    values(pid,p_plan->>'name',p_plan->>'description',p_plan->>'slug',(p_plan->>'monthly_price_mmk')::numeric,'month',
      (p_plan->>'monthly_price_mmk')::numeric,(p_plan->>'yearly_price_mmk')::numeric,14,
      coalesce((p_plan->>'max_users')::integer,1),coalesce((p_plan->>'max_products')::integer,100),-1,'{}'::jsonb,
      coalesce((p_plan->>'is_active')::boolean,false),coalesce((p_plan->>'is_public')::boolean,false),coalesce((p_plan->>'display_order')::integer,0),
      coalesce(p_plan->>'currency','MMK'),coalesce((p_plan->>'max_customers')::integer,100),coalesce((p_plan->>'max_suppliers')::integer,20),coalesce((p_plan->>'max_branches')::integer,1));
  else
    update public.plans set name=p_plan->>'name',description=p_plan->>'description',slug=p_plan->>'slug',
      monthly_price_mmk=(p_plan->>'monthly_price_mmk')::numeric,yearly_price_mmk=(p_plan->>'yearly_price_mmk')::numeric,
      price=(p_plan->>'monthly_price_mmk')::numeric,
      max_users=coalesce((p_plan->>'max_users')::integer,max_users),max_products=coalesce((p_plan->>'max_products')::integer,max_products),
      max_customers=coalesce((p_plan->>'max_customers')::integer,max_customers),max_suppliers=coalesce((p_plan->>'max_suppliers')::integer,max_suppliers),
      max_branches=coalesce((p_plan->>'max_branches')::integer,max_branches),is_active=(p_plan->>'is_active')::boolean,
      is_public=(p_plan->>'is_public')::boolean,display_order=(p_plan->>'display_order')::integer,updated_at=now()
      where id=pid;
  end if;
  for entry in select value from jsonb_array_elements(coalesce(p_features,'[]'::jsonb)) loop
    select id into fid from public.features where feature_key=entry->>'feature_key';
    if fid is null then raise exception 'Unknown feature %',entry->>'feature_key'; end if;
    insert into public.plan_features(plan_id,feature_id,is_enabled) values(pid,fid,coalesce((entry->>'is_enabled')::boolean,false))
      on conflict(plan_id,feature_id) do update set is_enabled=excluded.is_enabled,updated_at=now();
    if entry ? 'limit_value' then
      insert into public.plan_feature_limits(plan_id,feature_id,limit_value,limit_unit) values(pid,fid,(entry->>'limit_value')::integer,entry->>'limit_unit')
        on conflict(plan_id,feature_id) do update set limit_value=excluded.limit_value,limit_unit=excluded.limit_unit,updated_at=now();
      update public.plans set
        max_users=case when entry->>'feature_key'='max_users' then (entry->>'limit_value')::integer else max_users end,
        max_products=case when entry->>'feature_key'='max_products' then (entry->>'limit_value')::integer else max_products end,
        max_customers=case when entry->>'feature_key'='max_customers' then (entry->>'limit_value')::integer else max_customers end,
        max_suppliers=case when entry->>'feature_key'='max_suppliers' then (entry->>'limit_value')::integer else max_suppliers end,
        max_branches=case when entry->>'feature_key'='max_branches' then (entry->>'limit_value')::integer else max_branches end
        where id=pid;
    end if;
  end loop;
  insert into public.subscription_audit_logs(action,old_value,new_value,performed_by)
    values('plan_configuration_updated',old_plan,p_plan,auth.uid());
  return jsonb_build_object('success',true,'plan_id',pid);
end $$;
grant execute on function public.admin_update_plan_configuration(jsonb,jsonb) to authenticated;
revoke all on function public.admin_update_plan_configuration(jsonb,jsonb) from public, anon;

revoke all on function public.get_organization_subscription(uuid) from public, anon;
grant execute on function public.get_organization_subscription(uuid) to authenticated;
revoke all on function public.admin_change_organization_plan(uuid,text,text,integer) from public, anon;
grant execute on function public.admin_change_organization_plan(uuid,text,text,integer) to authenticated;
revoke all on function public.admin_grant_feature_override(uuid,text,boolean,integer,timestamptz,text) from public, anon;
grant execute on function public.admin_grant_feature_override(uuid,text,boolean,integer,timestamptz,text) to authenticated;

-- Plan entitlements also constrain direct table reads, not only React routes.
create or replace function public.organization_has_plan_feature(p_org_id uuid,p_feature_key text)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare decision jsonb;
begin
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id,p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean,false);
end $$;
revoke all on function public.organization_has_plan_feature(uuid,text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid,text) to authenticated;

drop policy if exists plan_entitlement_select on public.products;
create policy plan_entitlement_select on public.products as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'product_management'));
drop policy if exists plan_entitlement_select on public.product_categories;
create policy plan_entitlement_select on public.product_categories as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'category_management'));
drop policy if exists plan_entitlement_select on public.units;
create policy plan_entitlement_select on public.units as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'product_management'));
drop policy if exists plan_entitlement_select on public.customers;
create policy plan_entitlement_select on public.customers as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'customer_management'));
drop policy if exists plan_entitlement_select on public.suppliers;
create policy plan_entitlement_select on public.suppliers as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'supplier_management'));
drop policy if exists plan_entitlement_select on public.sales;
create policy plan_entitlement_select on public.sales as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'sales_management'));
drop policy if exists plan_entitlement_select on public.purchases;
create policy plan_entitlement_select on public.purchases as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'purchase_management'));
drop policy if exists plan_entitlement_select on public.expenses;
create policy plan_entitlement_select on public.expenses as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'expense_management'));
drop policy if exists plan_entitlement_select on public.stock_movements;
create policy plan_entitlement_select on public.stock_movements as restrictive for select
  using (public.organization_has_plan_feature(organization_id,'inventory_management'));
-- <<< END 0027_subscription_flow_hardening.sql

-- >>> BEGIN 0028_fix_plan_limit_triggers.sql
-- Separate organization member bootstrap fields from the generic tenant limit trigger.
-- PostgreSQL evaluates NEW against the trigger's table row, so a shared trigger
-- must never access fields that do not exist on every attached table.

create or replace function public.enforce_plan_entitlements()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  feature_key text;
  usage_key text;
  check_result jsonb;
  should_enforce boolean;
begin
  org_id := new.organization_id;
  feature_key := tg_argv[0];
  usage_key := tg_argv[1];
  should_enforce := tg_op = 'INSERT'
    or (tg_op = 'UPDATE' and coalesce(old.is_active, true) = false and coalesce(new.is_active, true));

  if not should_enforce then return new; end if;

  perform pg_advisory_xact_lock(hashtextextended(org_id::text || ':' || usage_key, 0));
  check_result := public.check_organization_feature(org_id, feature_key);
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'This feature is not available: %', check_result->>'reason';
  end if;

  check_result := public.check_organization_limit(org_id, usage_key);
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'Plan limit reached: %', check_result->>'reason';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_user_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  check_result jsonb;
begin
  org_id := new.organization_id;

  -- Organization creation inserts its owner before initializing the trial.
  if tg_op = 'INSERT'
     and not exists (select 1 from public.subscriptions where organization_id = org_id)
     and not exists (select 1 from public.organization_members where organization_id = org_id and is_active)
     and new.user_id = auth.uid()
     and new.role = 'owner' then
    return new;
  end if;

  if tg_op = 'UPDATE' and (coalesce(old.is_active, true) or not coalesce(new.is_active, false)) then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(org_id::text || ':max_users', 0));
  check_result := public.check_organization_feature(org_id, 'max_users');
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'User feature is not available: %', check_result->>'reason';
  end if;
  check_result := public.check_organization_limit(org_id, 'max_users');
  if not coalesce((check_result->>'is_allowed')::boolean, false) then
    raise exception 'User limit reached: %', check_result->>'reason';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit
  before insert or update of is_active on public.products
  for each row execute function public.enforce_plan_entitlements('product_management', 'max_products');

drop trigger if exists trg_enforce_user_plan_limit on public.organization_members;
create trigger trg_enforce_user_plan_limit
  before insert or update of is_active on public.organization_members
  for each row execute function public.enforce_user_plan_limit();

drop trigger if exists trg_enforce_customer_plan_limit on public.customers;
create trigger trg_enforce_customer_plan_limit
  before insert or update of is_active on public.customers
  for each row execute function public.enforce_plan_entitlements('customer_management', 'max_customers');

drop trigger if exists trg_enforce_supplier_plan_limit on public.suppliers;
create trigger trg_enforce_supplier_plan_limit
  before insert or update of is_active on public.suppliers
  for each row execute function public.enforce_plan_entitlements('supplier_management', 'max_suppliers');
-- <<< END 0028_fix_plan_limit_triggers.sql

-- >>> BEGIN 0029_lwal_kuu_branding.sql
-- Rename user-facing ShopFlow branding while preserving internal identifiers.
alter table public.marketing_workspaces
  alter column brand_name set default 'Lwal Kuu';

update public.marketing_workspaces
set brand_name = 'Lwal Kuu'
where brand_name = 'ShopFlow';

update public.notification_outbox
set subject = replace(subject, 'ShopFlow:', 'Lwal Kuu:')
where subject like 'ShopFlow:%';

-- Update existing automation function bodies so future email subjects use the new brand.
do $$
declare
  fn record;
  fn_definition text;
begin
  for fn in
    select p.oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosrc like '%ShopFlow%'
  loop
    fn_definition := pg_get_functiondef(fn.oid);
    execute replace(fn_definition, 'ShopFlow', 'Lwal Kuu');
  end loop;
end;
$$;
-- <<< END 0029_lwal_kuu_branding.sql

-- >>> BEGIN 0030_enforce_barcode_entitlement.sql
create or replace function public.enforce_barcode_plan_feature()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  access_result jsonb;
begin
  if nullif(btrim(new.barcode), '') is null
     or (tg_op = 'UPDATE' and new.barcode is not distinct from old.barcode) then
    return new;
  end if;

  access_result := public.check_organization_feature(new.organization_id, 'barcode_support');
  if not coalesce((access_result->>'is_allowed')::boolean, false) then
    raise exception 'Barcode support is not available on the current plan';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_products_barcode_plan_feature on public.products;
create trigger trg_products_barcode_plan_feature
  before insert or update of barcode on public.products
  for each row execute function public.enforce_barcode_plan_feature();
-- <<< END 0030_enforce_barcode_entitlement.sql

-- >>> BEGIN 0031_complete_plan_feature_matrix.sql
-- Make every existing plan matrix explicit for every active feature.
-- Existing assignments (including platform-admin customizations) are preserved.
-- Missing assignments are filled from the original tier definitions in 0019.
with plan_defaults(plan_id, enabled_features) as (
  values
    ('starter', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'inventory_management','stock_adjustment','daily_sales_report',
      'basic_product_report','manual_data_export','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[]),
    ('business', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'credit_sales','partial_payments','customer_ledger','customer_debt_tracking',
      'supplier_payables','payment_receipt_mgmt','expense_management',
      'inventory_management','stock_adjustment','stock_transfer','low_stock_alerts',
      'multi_branch','daily_sales_report','basic_product_report',
      'monthly_yearly_reports','profit_estimation','excel_export',
      'basic_permissions','manual_data_export','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[]),
    ('pro', array[
      'product_management','category_management','customer_management',
      'supplier_management','purchase_management','sales_management','cash_sales',
      'credit_sales','partial_payments','customer_ledger','customer_debt_tracking',
      'supplier_payables','payment_receipt_mgmt','expense_management',
      'inventory_management','stock_adjustment','stock_transfer','low_stock_alerts',
      'multi_branch','advanced_inventory','barcode_support','qr_support',
      'daily_sales_report','basic_product_report','monthly_yearly_reports',
      'customer_statement_pdf','supplier_statement_pdf','sales_analytics',
      'purchase_analytics','branch_reports','profit_loss_report','cash_flow_report',
      'profit_estimation','automated_reports','debt_reminders','excel_export',
      'manual_data_export','basic_permissions','advanced_permissions','audit_logs',
      'backup_restore','priority_support','max_users','max_products',
      'max_customers','max_suppliers','max_branches'
    ]::text[])
),
custom_plan_defaults as (
  select p.id as plan_id, array[]::text[] as enabled_features
  from public.plans p
  where p.id not in ('starter', 'business', 'pro')
),
plan_feature_matrix as (
  select p.id as plan_id, f.id as feature_id,
         f.feature_key = any(d.enabled_features) as is_enabled
  from (
    select * from plan_defaults
    union all
    select * from custom_plan_defaults
  ) d
  join public.plans p on p.id = d.plan_id
  cross join public.features f
  where f.is_active
)
insert into public.plan_features(plan_id, feature_id, is_enabled)
select plan_id, feature_id, is_enabled
from plan_feature_matrix
on conflict (plan_id, feature_id) do nothing;

-- Numeric feature limits are stored separately from Boolean plan features.
-- Backfill any missing limit rows from the plan's existing limit columns.
insert into public.plan_feature_limits(plan_id, feature_id, limit_value, limit_unit)
select p.id,
       f.id,
       case f.feature_key
         when 'max_users' then p.max_users
         when 'max_products' then p.max_products
         when 'max_customers' then p.max_customers
         when 'max_suppliers' then p.max_suppliers
         when 'max_branches' then p.max_branches
       end,
       case f.feature_key
         when 'max_users' then 'users'
         when 'max_products' then 'products'
         when 'max_customers' then 'customers'
         when 'max_suppliers' then 'suppliers'
         when 'max_branches' then 'branches'
       end
from public.plans p
cross join public.features f
where f.is_active
  and f.feature_type = 'limit'
on conflict (plan_id, feature_id) do nothing;
-- <<< END 0031_complete_plan_feature_matrix.sql

-- >>> BEGIN 0032_plan_dependent_report_views.sql
-- Tenant-facing reports included by Business and Pro plans.
-- Every view filters by the caller's active organization membership.

create or replace view public.product_sales_performance as
select
  s.organization_id,
  p.id as product_id,
  p.sku,
  p.name as product_name,
  count(distinct s.id)::integer as invoice_count,
  sum(si.quantity) as units_sold,
  sum(si.total_amount) as revenue,
  sum(si.quantity * si.unit_cost) as cost_of_goods,
  sum(si.total_amount - (si.quantity * si.unit_cost)) as gross_profit
from public.sales s
join public.sale_items si on si.sale_id = s.id and si.organization_id = s.organization_id
join public.products p on p.id = si.product_id and p.organization_id = s.organization_id
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, p.id, p.sku, p.name;

create or replace view public.monthly_sales_performance as
select
  s.organization_id,
  date_trunc('month', s.sale_date)::date as period_start,
  count(*)::integer as invoice_count,
  sum(s.total_amount) as revenue,
  sum(s.total_cost) as cost_of_goods,
  sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, date_trunc('month', s.sale_date)::date;

create or replace view public.yearly_sales_performance as
select
  s.organization_id,
  date_trunc('year', s.sale_date)::date as period_start,
  count(*)::integer as invoice_count,
  sum(s.total_amount) as revenue,
  sum(s.total_cost) as cost_of_goods,
  sum(s.total_amount - s.total_cost) as gross_profit
from public.sales s
where s.status = 'confirmed'
  and public.has_org_membership(s.organization_id)
group by s.organization_id, date_trunc('year', s.sale_date)::date;

create or replace view public.purchase_analytics as
select
  p.organization_id,
  date_trunc('month', p.purchase_date)::date as period_start,
  p.supplier_id,
  s.name as supplier_name,
  count(p.id)::integer as purchase_count,
  sum(p.total_amount) as purchase_amount,
  sum(p.paid_amount) as paid_amount,
  sum(p.total_amount - p.paid_amount) as outstanding_amount
from public.purchases p
join public.suppliers s on s.id = p.supplier_id and s.organization_id = p.organization_id
where p.status = 'received'
  and public.has_org_membership(p.organization_id)
group by p.organization_id, date_trunc('month', p.purchase_date)::date, p.supplier_id, s.name;

create or replace view public.profit_loss_performance as
with sales_monthly as (
  select organization_id, date_trunc('month', sale_date)::date as period_start,
         sum(total_amount) as revenue, sum(total_cost) as cost_of_goods
  from public.sales
  where status = 'confirmed' and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', sale_date)::date
), expenses_monthly as (
  select organization_id, date_trunc('month', expense_date)::date as period_start, sum(amount) as expenses
  from public.expenses
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', expense_date)::date
), periods as (
  select organization_id, period_start from sales_monthly
  union
  select organization_id, period_start from expenses_monthly
)
select periods.organization_id, periods.period_start,
       coalesce(sales_monthly.revenue, 0)::numeric as revenue,
       coalesce(sales_monthly.cost_of_goods, 0)::numeric as cost_of_goods,
       (coalesce(sales_monthly.revenue, 0) - coalesce(sales_monthly.cost_of_goods, 0))::numeric as gross_profit,
       coalesce(expenses_monthly.expenses, 0)::numeric as operating_expenses,
       (coalesce(sales_monthly.revenue, 0) - coalesce(sales_monthly.cost_of_goods, 0)
        - coalesce(expenses_monthly.expenses, 0))::numeric as net_operating_profit
from periods
left join sales_monthly using (organization_id, period_start)
left join expenses_monthly using (organization_id, period_start);

create or replace view public.cash_flow_performance as
with inflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.payments
  where status = 'posted' and payment_type in ('customer_payment','other')
    and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  -- Walk-in sales have no customer payment row; count their paid amount here.
  select organization_id, date_trunc('month', sale_date)::date, sum(paid_amount)
  from public.sales
  where status = 'confirmed' and customer_id is null and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', sale_date)::date
), outflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.supplier_payments
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', expense_date)::date, sum(amount)
  from public.expenses
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', expense_date)::date
), all_periods as (
  select organization_id, period_start from inflows
  union
  select organization_id, period_start from outflows
), inflow_totals as (
  select organization_id, period_start, sum(amount) as cash_in from inflows group by organization_id, period_start
), outflow_totals as (
  select organization_id, period_start, sum(amount) as cash_out from outflows group by organization_id, period_start
)
select all_periods.organization_id, all_periods.period_start,
       coalesce(inflow_totals.cash_in, 0)::numeric as cash_in,
       coalesce(outflow_totals.cash_out, 0)::numeric as cash_out,
       (coalesce(inflow_totals.cash_in, 0) - coalesce(outflow_totals.cash_out, 0))::numeric as net_cash_flow
from all_periods
left join inflow_totals using (organization_id, period_start)
left join outflow_totals using (organization_id, period_start);

grant select on public.product_sales_performance, public.monthly_sales_performance,
  public.yearly_sales_performance, public.purchase_analytics,
  public.profit_loss_performance, public.cash_flow_performance to authenticated;
-- <<< END 0032_plan_dependent_report_views.sql

-- >>> BEGIN 0033_tenant_audit_and_priority_support.sql
-- Tenant audit coverage for common operational records.
-- Keep this migration self-contained for databases that have the entitlement
-- RPCs but are missing the convenience boolean wrapper added in migration 0027.
create or replace function public.organization_has_plan_feature(p_org_id uuid, p_feature_key text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  decision jsonb;
begin
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id, p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean, false);
end;
$$;
revoke all on function public.organization_has_plan_feature(uuid, text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid, text) to authenticated;

create or replace function public.capture_tenant_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  entity_id uuid;
  before_row jsonb;
  after_row jsonb;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  entity_id := coalesce(new.id, old.id);
  before_row := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  after_row := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else null end;
  if tg_op = 'UPDATE' and before_row = after_row then return new; end if;

  insert into public.audit_logs(organization_id, user_id, action, entity_type, entity_id, payload)
  values (
    org_id,
    auth.uid(),
    lower(tg_op) || ':' || tg_table_name,
    tg_table_name,
    entity_id,
    jsonb_build_object('before', before_row, 'after', after_row)
  );

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'products','product_categories','customers','suppliers','sales','sale_items',
    'purchases','purchase_items','payments','supplier_payments','expenses','stock_adjustments'
  ] loop
    execute format('drop trigger if exists trg_audit_%I on public.%I', table_name, table_name);
    execute format(
      'create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.capture_tenant_audit_log()',
      table_name, table_name
    );
  end loop;
end;
$$;

-- A tenant can create and view its priority support requests only while entitled.
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  subject text not null check (length(btrim(subject)) between 1 and 180),
  description text not null check (length(btrim(description)) between 1 and 10000),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  priority text not null default 'priority' check (priority in ('normal','priority')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_support_tickets_org_created
  on public.support_tickets(organization_id, created_at desc);
alter table public.support_tickets enable row level security;
drop policy if exists support_tickets_tenant_read on public.support_tickets;
create policy support_tickets_tenant_read on public.support_tickets for select
  using (public.has_org_membership(organization_id) and public.organization_has_plan_feature(organization_id, 'priority_support'));
drop policy if exists support_tickets_tenant_create on public.support_tickets;
create policy support_tickets_tenant_create on public.support_tickets for insert
  with check (
    public.has_org_membership(organization_id)
    and created_by = auth.uid()
    and public.organization_has_plan_feature(organization_id, 'priority_support')
  );
drop policy if exists support_tickets_platform_admin on public.support_tickets;
create policy support_tickets_platform_admin on public.support_tickets for all
  using (public.is_platform_admin()) with check (public.is_platform_admin());
revoke all on public.support_tickets from anon;
grant select, insert, update on public.support_tickets to authenticated;
-- <<< END 0033_tenant_audit_and_priority_support.sql

-- >>> BEGIN 0034_qr_code_support.sql
alter table public.products add column if not exists qr_code text;

create or replace function public.enforce_product_code_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  field_name text := tg_argv[1];
  feature_key text := tg_argv[0];
  current_value text;
  old_value text;
  access_result jsonb;
begin
  current_value := nullif(btrim(to_jsonb(new)->>field_name), '');
  if tg_op = 'UPDATE' then
    old_value := nullif(btrim(to_jsonb(old)->>field_name), '');
    if current_value is not distinct from old_value then return new; end if;
  end if;
  if current_value is null then return new; end if;

  access_result := public.check_organization_feature(new.organization_id, feature_key);
  if not coalesce((access_result->>'is_allowed')::boolean, false) then
    raise exception '% is not available on the current plan', feature_key;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_products_qr_plan_feature on public.products;
create trigger trg_products_qr_plan_feature
  before insert or update of qr_code on public.products
  for each row execute function public.enforce_product_code_entitlement('qr_support','qr_code');
-- <<< END 0034_qr_code_support.sql

-- >>> BEGIN 0035_plan_gated_automation_and_debt_reminders.sql
-- Prevent shared automation jobs from queuing tenant reports/alerts for plans
-- that do not include those features.
create or replace function public.enforce_notification_plan_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  feature_key text;
begin
  feature_key := case new.notification_type
    when 'low_stock' then 'low_stock_alerts'
    when 'daily_summary' then 'automated_reports'
    when 'weekly_summary' then 'automated_reports'
    when 'debt_reminder' then 'debt_reminders'
    else null
  end;
  if feature_key is null or new.organization_id is null then return new; end if;
  if not public.organization_has_plan_feature(new.organization_id, feature_key) then return null; end if;
  return new;
end;
$$;

drop trigger if exists trg_notification_plan_entitlement on public.notification_outbox;
create trigger trg_notification_plan_entitlement
  before insert on public.notification_outbox
  for each row execute function public.enforce_notification_plan_entitlement();

create or replace function public.cron_queue_debt_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  debt_record record;
  queued_count integer := 0;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Platform administrator privileges required';
  end if;

  for debt_record in
    select s.organization_id, s.customer_id, c.email, c.name,
           count(*)::integer as overdue_invoice_count,
           sum(greatest(s.total_amount - s.paid_amount, 0))::numeric as overdue_amount
    from public.sales s
    join public.customers c on c.id = s.customer_id and c.organization_id = s.organization_id
    where s.status = 'confirmed'
      and s.due_date < current_date
      and s.payment_status in ('unpaid','partial')
      and c.is_active
      and nullif(btrim(c.email), '') is not null
      and public.organization_has_plan_feature(s.organization_id, 'debt_reminders')
    group by s.organization_id, s.customer_id, c.email, c.name
  loop
    if not exists (
      select 1 from public.notification_outbox n
      where n.organization_id = debt_record.organization_id
        and n.notification_type = 'debt_reminder'
        and n.payload->>'customer_id' = debt_record.customer_id::text
        and n.created_at > now() - interval '7 days'
    ) then
      insert into public.notification_outbox(
        organization_id, notification_type, recipient_email, subject, payload
      ) values (
        debt_record.organization_id,
        'debt_reminder',
        debt_record.email,
        'Lwal Kuu: Outstanding balance reminder',
        jsonb_build_object(
          'customer_id', debt_record.customer_id,
          'customer_name', debt_record.name,
          'overdue_invoice_count', debt_record.overdue_invoice_count,
          'overdue_amount', debt_record.overdue_amount
        )
      );
      queued_count := queued_count + 1;
    end if;
  end loop;
  return jsonb_build_object('queued_debt_reminders', queued_count);
end;
$$;

revoke all on function public.cron_queue_debt_reminders() from public, anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated;
-- <<< END 0035_plan_gated_automation_and_debt_reminders.sql

-- >>> BEGIN 0036_branches_and_stock_transfers.sql
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
-- <<< END 0036_branches_and_stock_transfers.sql

-- >>> BEGIN 0037_branch_scoped_stock_controls.sql
-- Preserve stock availability independently for each branch and allow branch-specific adjustments.
create or replace function public.enforce_branch_stock_nonnegative()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare branch_balance numeric;
begin
  if new.movement_type <> 'sales_out' then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text || ':' || new.branch_id::text || ':' || new.product_id::text, 0));
  select coalesce(sum(quantity), 0) into branch_balance
  from public.stock_movements
  where organization_id = new.organization_id
    and branch_id = new.branch_id
    and product_id = new.product_id;
  if branch_balance + new.quantity < 0 then
    raise exception 'Insufficient stock in the selected branch';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_enforce_branch_stock_nonnegative on public.stock_movements;
create trigger trg_enforce_branch_stock_nonnegative
before insert on public.stock_movements
for each row execute function public.enforce_branch_stock_nonnegative();

create or replace function public.create_stock_adjustment_at_branch(
  p_org_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_notes text,
  p_branch_id uuid
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
  v_branch_id uuid;
begin
  if not public.has_org_membership(p_org_id) then raise exception 'Unauthorized'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'stock_adjustment') then raise exception 'Stock adjustment is not available on the current plan'; end if;
  select id into v_branch_id from public.branches
    where organization_id = p_org_id and id = p_branch_id and is_active;
  if v_branch_id is null then raise exception 'Choose an active branch in this organization'; end if;
  select * into v_product from public.products where id = p_product_id and organization_id = p_org_id and is_active;
  if not found then raise exception 'Product not found'; end if;
  if p_quantity_delta = 0 then raise exception 'Quantity delta cannot be zero'; end if;
  if p_quantity_delta < 0 then
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || v_branch_id::text || ':' || p_product_id::text, 0));
    if (select coalesce(sum(quantity), 0) from public.stock_movements where organization_id=p_org_id and branch_id=v_branch_id and product_id=p_product_id) + p_quantity_delta < 0 then
      raise exception 'Adjustment would make branch stock negative';
    end if;
  end if;
  v_adj_num := public.next_document_number(p_org_id, 'stock_adjustment');
  insert into public.stock_adjustments(organization_id, branch_id, adjustment_number, product_id, reason, quantity_delta, unit_cost, notes, created_by)
  values(p_org_id, v_branch_id, v_adj_num, p_product_id, p_reason, p_quantity_delta, v_product.average_cost, p_notes, v_user_id)
  returning id into v_adj_id;
  v_mov_type := case when p_quantity_delta > 0 then 'adjustment_in' else 'adjustment_out' end;
  insert into public.stock_movements(organization_id, branch_id, product_id, movement_type, quantity, unit_cost, reference_type, reference_id, notes, created_by)
  values(p_org_id, v_branch_id, p_product_id, v_mov_type, p_quantity_delta, v_product.average_cost, 'adjustment', v_adj_id, p_notes, v_user_id);
  return jsonb_build_object('success', true, 'adjustment_id', v_adj_id, 'adjustment_number', v_adj_num, 'branch_id', v_branch_id);
end;
$$;
revoke all on function public.create_stock_adjustment_at_branch(uuid,uuid,numeric,text,text,uuid) from public, anon;
grant execute on function public.create_stock_adjustment_at_branch(uuid,uuid,numeric,text,text,uuid) to authenticated;
-- <<< END 0037_branch_scoped_stock_controls.sql

-- >>> BEGIN 0038_automated_notification_delivery.sql
-- Keep outbox generation idempotent when cron jobs are retried or run manually.
-- Scheduled SECURITY DEFINER jobs run without auth.uid(); allow those trusted
-- database calls to evaluate plan assignments while still requiring membership
-- for authenticated API users.
create or replace function public.organization_has_plan_feature(p_org_id uuid, p_feature_key text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  decision jsonb;
  subscription_status text;
  resolved_plan_id text;
  resolved_feature_id uuid;
  override_enabled boolean;
  plan_enabled boolean;
begin
  if auth.uid() is null then
    select * into subscription_status, resolved_plan_id from public._resolve_subscription_status(p_org_id);
    select id into resolved_feature_id from public.features where feature_key=p_feature_key and is_active;
    if resolved_feature_id is null then return false; end if;
    select is_enabled into override_enabled from public.organization_feature_overrides
      where organization_id=p_org_id and feature_id=resolved_feature_id and starts_at<=now()
        and (expires_at is null or expires_at>now()) order by created_at desc limit 1;
    if found and override_enabled is not null then return override_enabled; end if;
    if subscription_status not in ('active','trialing') then return false; end if;
    select is_enabled into plan_enabled from public.plan_features where plan_id=resolved_plan_id and feature_id=resolved_feature_id;
    return coalesce(plan_enabled,false);
  end if;
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id, p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean, false);
end;
$$;
revoke all on function public.organization_has_plan_feature(uuid, text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid, text) to authenticated, service_role;

create or replace function public.enforce_notification_plan_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  feature_key text;
  duplicate_window interval;
begin
  feature_key := case new.notification_type
    when 'low_stock' then 'low_stock_alerts'
    when 'daily_summary' then 'automated_reports'
    when 'weekly_summary' then 'automated_reports'
    when 'debt_reminder' then 'debt_reminders'
    else null
  end;
  if feature_key is null or new.organization_id is null then return new; end if;
  if not public.organization_has_plan_feature(new.organization_id, feature_key) then return null; end if;
  duplicate_window := case new.notification_type
    when 'low_stock' then interval '1 day'
    when 'daily_summary' then interval '1 day'
    when 'weekly_summary' then interval '7 days'
    else null
  end;
  if duplicate_window is not null and exists (
    select 1 from public.notification_outbox n
    where n.organization_id = new.organization_id
      and n.notification_type = new.notification_type
      and n.created_at >= now() - duplicate_window
      and n.status in ('pending','processing','sent')
  ) then return null; end if;
  return new;
end;
$$;

-- Allow the trusted database scheduler to run debt reminder generation. Authenticated
-- callers still must be platform administrators; scheduled SQL has no user identity.
create or replace function public.cron_queue_debt_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  debt_record record;
  queued_count integer := 0;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Platform administrator privileges required';
  end if;
  for debt_record in
    select s.organization_id, s.customer_id, c.email, c.name,
           count(*)::integer as overdue_invoice_count,
           sum(greatest(s.total_amount - s.paid_amount, 0))::numeric as overdue_amount
    from public.sales s
    join public.customers c on c.id = s.customer_id and c.organization_id = s.organization_id
    where s.status = 'confirmed' and s.due_date < current_date
      and s.payment_status in ('unpaid','partial') and c.is_active
      and nullif(btrim(c.email), '') is not null
      and public.organization_has_plan_feature(s.organization_id, 'debt_reminders')
    group by s.organization_id, s.customer_id, c.email, c.name
  loop
    if not exists (
      select 1 from public.notification_outbox n
      where n.organization_id = debt_record.organization_id
        and n.notification_type = 'debt_reminder'
        and n.payload->>'customer_id' = debt_record.customer_id::text
        and n.created_at > now() - interval '7 days'
    ) then
      insert into public.notification_outbox(organization_id, notification_type, recipient_email, subject, payload)
      values (
        debt_record.organization_id, 'debt_reminder', debt_record.email,
        'Lwal Kuu: Outstanding balance reminder',
        jsonb_build_object('customer_id', debt_record.customer_id, 'customer_name', debt_record.name,
          'overdue_invoice_count', debt_record.overdue_invoice_count, 'overdue_amount', debt_record.overdue_amount)
      );
      queued_count := queued_count + 1;
    end if;
  end loop;
  return jsonb_build_object('queued_debt_reminders', queued_count);
end;
$$;
revoke all on function public.cron_queue_debt_reminders() from public, anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated, service_role;

-- Schedule plan-gated report, stock alert, and debt reminder generation when pg_cron is available.
do $outer$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-daily-sales-reports') then perform cron.unschedule('lwal-kuu-daily-sales-reports'); end if;
    perform cron.schedule('lwal-kuu-daily-sales-reports', '5 0 * * *', 'select public.cron_queue_daily_sales_summaries()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-low-stock-alerts') then perform cron.unschedule('lwal-kuu-low-stock-alerts'); end if;
    perform cron.schedule('lwal-kuu-low-stock-alerts', '15 0 * * *', 'select public.cron_queue_low_stock_alerts()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-weekly-reports') then perform cron.unschedule('lwal-kuu-weekly-reports'); end if;
    perform cron.schedule('lwal-kuu-weekly-reports', '30 0 * * 1', 'select public.cron_queue_weekly_business_summary()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-debt-reminders') then perform cron.unschedule('lwal-kuu-debt-reminders'); end if;
    perform cron.schedule('lwal-kuu-debt-reminders', '45 0 * * *', 'select public.cron_queue_debt_reminders()');
  end if;
exception when others then
  raise notice 'Could not schedule Lwal Kuu automation jobs: %', sqlerrm;
end $outer$;

alter table public.support_tickets add column if not exists response text;
alter table public.support_tickets add column if not exists responded_at timestamptz;
-- <<< END 0038_automated_notification_delivery.sql

-- >>> BEGIN 0039_tenant_backup_restore.sql
create or replace function public.export_organization_backup(p_org_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  table_name text;
  rows_json jsonb;
  backup_data jsonb := jsonb_build_object('format_version', 1, 'organization_id', p_org_id, 'created_at', now(), 'tables', '{}'::jsonb);
  table_names text[] := array[
    'branches','product_categories','units','expense_categories','products','customers','suppliers',
    'purchases','purchase_items','supplier_payments','sales','sale_items','payments','payment_allocations',
    'expenses','stock_adjustments','stock_transfers','stock_transfer_items','stock_movements'
  ];
begin
  if not public.is_org_admin_or_owner(p_org_id) then raise exception 'Organization administrator access required'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'backup_restore') then raise exception 'Backup and restore is not available on the current plan'; end if;
  foreach table_name in array table_names loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at), ''[]''::jsonb) from public.%I t where t.organization_id = $1', table_name)
      into rows_json using p_org_id;
    backup_data := jsonb_set(backup_data, array['tables', table_name], rows_json, true);
  end loop;
  return backup_data;
end;
$$;
alter table public.stock_transfer_items add column if not exists created_at timestamptz not null default now();
revoke all on function public.export_organization_backup(uuid) from public, anon;
grant execute on function public.export_organization_backup(uuid) to authenticated;

create or replace function public.restore_organization_backup(p_org_id uuid, p_backup jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  table_name text;
  column_updates text;
  restored_count integer := 0;
  table_count integer;
  table_names text[] := array[
    'branches','product_categories','units','expense_categories','products','customers','suppliers',
    'purchases','purchase_items','supplier_payments','sales','sale_items','payments','payment_allocations',
    'expenses','stock_adjustments','stock_transfers','stock_transfer_items','stock_movements'
  ];
begin
  if not public.is_org_admin_or_owner(p_org_id) then raise exception 'Organization administrator access required'; end if;
  if not public.organization_has_plan_feature(p_org_id, 'backup_restore') then raise exception 'Backup and restore is not available on the current plan'; end if;
  if coalesce(jsonb_typeof(p_backup) <> 'object', true)
     or coalesce((p_backup->>'format_version')::integer, 0) <> 1
     or coalesce((p_backup->>'organization_id')::uuid <> p_org_id, true)
     or coalesce(jsonb_typeof(p_backup->'tables') <> 'object', true) then
    raise exception 'Backup file is invalid or belongs to another organization';
  end if;

  -- Validate all cross-table references against records in this tenant or this backup.
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') r where r->>'unit_id' is not null
      and not exists (select 1 from public.units u where u.id=(r->>'unit_id')::uuid and u.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'units') u where u->>'id'=r->>'unit_id')) then raise exception 'Backup contains a product with an unknown unit'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') r where r->>'category_id' is not null
      and not exists (select 1 from public.product_categories c where c.id=(r->>'category_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') c where c->>'id'=r->>'category_id')) then raise exception 'Backup contains a product with an unknown category'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') r where r->>'parent_id' is not null
      and not exists (select 1 from public.product_categories c where c.id=(r->>'parent_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'product_categories') c where c->>'id'=r->>'parent_id')) then raise exception 'Backup contains a category with an unknown parent'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') r where not exists (select 1 from public.suppliers s where s.id=(r->>'supplier_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'suppliers') s where s->>'id'=r->>'supplier_id')) then raise exception 'Backup contains a purchase with an unknown supplier'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a purchase with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') r where r->>'customer_id' is not null
      and not exists (select 1 from public.customers c where c.id=(r->>'customer_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'customers') c where c->>'id'=r->>'customer_id')) then raise exception 'Backup contains a sale with an unknown customer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a sale with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') r where not exists (select 1 from public.purchases p where p.id=(r->>'purchase_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'purchase_id')) then raise exception 'Backup contains an item with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a purchase item with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sale_items') r where not exists (select 1 from public.sales s where s.id=(r->>'sale_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'sale_id')) then raise exception 'Backup contains an item with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sale_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a sale item with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'supplier_payments') r where not exists (select 1 from public.suppliers s where s.id=(r->>'supplier_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'suppliers') s where s->>'id'=r->>'supplier_id')) then raise exception 'Backup contains a supplier payment with an unknown supplier'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'supplier_payments') r where r->>'purchase_id' is not null
      and not exists (select 1 from public.purchases p where p.id=(r->>'purchase_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'purchase_id')) then raise exception 'Backup contains a supplier payment with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payments') r where r->>'customer_id' is not null
      and not exists (select 1 from public.customers c where c.id=(r->>'customer_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'customers') c where c->>'id'=r->>'customer_id')) then raise exception 'Backup contains a payment with an unknown customer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payment_allocations') r where not exists (select 1 from public.payments p where p.id=(r->>'payment_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p where p->>'id'=r->>'payment_id')) then raise exception 'Backup contains an allocation with an unknown payment'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payment_allocations') r where r->>'sale_id' is not null
      and not exists (select 1 from public.sales s where s.id=(r->>'sale_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'sale_id')) then raise exception 'Backup contains an allocation with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'expenses') r where r->>'category_id' is not null
      and not exists (select 1 from public.expense_categories c where c.id=(r->>'category_id')::uuid and c.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'expense_categories') c where c->>'id'=r->>'category_id')) then raise exception 'Backup contains an expense with an unknown category'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains an adjustment with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains an adjustment with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a stock movement with an unknown product'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'branch_id' is not null
      and not exists (select 1 from public.branches b where b.id=(r->>'branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'branch_id')) then raise exception 'Backup contains a stock movement with an unknown branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='sale'
      and not exists (select 1 from public.sales s where s.id=(r->>'reference_id')::uuid and s.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales') s where s->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown sale'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='purchase'
      and not exists (select 1 from public.purchases p where p.id=(r->>'reference_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchases') p where p->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown purchase'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='adjustment'
      and not exists (select 1 from public.stock_adjustments a where a.id=(r->>'reference_id')::uuid and a.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_adjustments') a where a->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown adjustment'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') r where r->>'reference_type'='stock_transfer'
      and not exists (select 1 from public.stock_transfers t where t.id=(r->>'reference_id')::uuid and t.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') t where t->>'id'=r->>'reference_id')) then raise exception 'Backup contains a stock movement with an unknown transfer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') r where not exists (select 1 from public.branches b where b.id=(r->>'source_branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'source_branch_id')) then raise exception 'Backup contains a transfer with an unknown source branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') r where not exists (select 1 from public.branches b where b.id=(r->>'destination_branch_id')::uuid and b.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'branches') b where b->>'id'=r->>'destination_branch_id')) then raise exception 'Backup contains a transfer with an unknown destination branch'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfer_items') r where not exists (select 1 from public.stock_transfers t where t.id=(r->>'transfer_id')::uuid and t.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfers') t where t->>'id'=r->>'transfer_id')) then raise exception 'Backup contains a transfer item with an unknown transfer'; end if;
  if exists (select 1 from jsonb_array_elements(p_backup->'tables'->'stock_transfer_items') r where not exists (select 1 from public.products p where p.id=(r->>'product_id')::uuid and p.organization_id=p_org_id)
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p where p->>'id'=r->>'product_id')) then raise exception 'Backup contains a transfer item with an unknown product'; end if;

  foreach table_name in array table_names loop
    if p_backup->'tables' ? table_name then
      if jsonb_typeof(p_backup->'tables'->table_name) <> 'array' then raise exception 'Backup table % is malformed', table_name; end if;
      select string_agg(format('%I = excluded.%I', a.attname, a.attname), ', ' order by a.attnum)
      into column_updates
      from pg_attribute a
      where a.attrelid = format('public.%I', table_name)::regclass
        and a.attnum > 0 and not a.attisdropped and a.attname <> 'id';
      execute format(
        'insert into public.%1$I select (r).* from jsonb_populate_recordset(null::public.%1$I, $1) r where r.organization_id = $2 on conflict (id) do update set %2$s',
        table_name, column_updates
      ) using p_backup->'tables'->table_name, p_org_id;
      get diagnostics table_count = row_count;
      restored_count := restored_count + table_count;
    end if;
  end loop;
  return jsonb_build_object('success', true, 'rows_merged', restored_count, 'mode', 'merge');
end;
$$;
revoke all on function public.restore_organization_backup(uuid,jsonb) from public, anon;
grant execute on function public.restore_organization_backup(uuid,jsonb) to authenticated;
-- <<< END 0039_tenant_backup_restore.sql

-- >>> BEGIN 0040_advanced_role_permissions.sql
create table if not exists public.organization_role_permissions (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  role text not null check (role in ('manager','staff')),
  permission_key text not null check (permission_key in ('products','customers','suppliers','sales','purchases','inventory','expenses')),
  can_view boolean not null default true,
  can_create boolean not null default true,
  can_update boolean not null default true,
  can_delete boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (organization_id, role, permission_key)
);
alter table public.organization_role_permissions enable row level security;
drop policy if exists organization_role_permissions_admin_access on public.organization_role_permissions;
create policy organization_role_permissions_admin_access on public.organization_role_permissions for all
  using (public.is_org_admin_or_owner(organization_id) and public.organization_has_plan_feature(organization_id,'advanced_permissions'))
  with check (public.is_org_admin_or_owner(organization_id) and public.organization_has_plan_feature(organization_id,'advanced_permissions'));
grant select, insert, update, delete on public.organization_role_permissions to authenticated;

create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  configured boolean;
  allowed boolean;
begin
  if auth.uid() is null or public.is_platform_admin() then return true; end if;
  select role into member_role from public.organization_members
    where organization_id=p_org_id and user_id=auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;
  if not public.organization_has_plan_feature(p_org_id,'advanced_permissions') then return true; end if;
  select case p_action when 'view' then can_view when 'create' then can_create when 'update' then can_update when 'delete' then can_delete else false end
    into allowed from public.organization_role_permissions
    where organization_id=p_org_id and role=member_role and permission_key=p_permission;
  if found then return coalesce(allowed,false); end if;
  if member_role='staff' then return p_permission in ('sales','customers') and p_action in ('view','create','update'); end if;
  if member_role='manager' then return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses') and p_action <> 'delete'; end if;
  return false;
end;
$$;
revoke all on function public.has_org_permission(uuid,text,text) from public, anon;
grant execute on function public.has_org_permission(uuid,text,text) to authenticated;

create or replace function public.enforce_advanced_role_permission()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  permission_key text;
  action_key text;
  org_id uuid;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  permission_key := case tg_table_name
    when 'products' then 'products' when 'product_categories' then 'products'
    when 'customers' then 'customers' when 'suppliers' then 'suppliers'
    when 'sales' then 'sales' when 'sale_items' then 'sales' when 'payments' then 'sales'
    when 'purchases' then 'purchases' when 'purchase_items' then 'purchases' when 'supplier_payments' then 'purchases'
    when 'stock_adjustments' then 'inventory' when 'stock_movements' then 'inventory'
    when 'expenses' then 'expenses' else null end;
  if permission_key is null or not public.organization_has_plan_feature(org_id,'advanced_permissions') then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  action_key := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' when 'DELETE' then 'delete' else 'view' end;
  if not public.has_org_permission(org_id,permission_key,action_key) then raise exception 'Your organization role does not allow this action'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
do $$
declare table_name text;
begin
  foreach table_name in array array['products','product_categories','customers','suppliers','sales','sale_items','payments','purchases','purchase_items','supplier_payments','stock_adjustments','stock_movements','expenses'] loop
    execute format('drop trigger if exists trg_advanced_role_permission on public.%I',table_name);
    execute format('create trigger trg_advanced_role_permission before insert or update or delete on public.%I for each row execute function public.enforce_advanced_role_permission()',table_name);
  end loop;
end;
$$;
-- <<< END 0040_advanced_role_permissions.sql

-- >>> BEGIN 0041_advanced_permission_read_enforcement.sql
create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  allowed boolean;
begin
  if auth.uid() is null or public.is_platform_admin() then return true; end if;
  select role into member_role from public.organization_members where organization_id=p_org_id and user_id=auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;
  if not public.organization_has_plan_feature(p_org_id,'advanced_permissions') then return true; end if;
  select case p_action when 'view' then can_view when 'create' then can_create when 'update' then can_update when 'delete' then can_delete else false end
    into allowed from public.organization_role_permissions where organization_id=p_org_id and role=member_role and permission_key=p_permission;
  if found then return coalesce(allowed,false); end if;
  if member_role='staff' then
    if p_action='view' then return p_permission in ('products','customers','sales','inventory'); end if;
    return p_permission in ('sales','customers') and p_action in ('create','update');
  end if;
  if member_role='manager' then return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses') and p_action <> 'delete'; end if;
  return false;
end;
$$;

create or replace function public.capture_tenant_audit_log()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  org_id uuid;
  entity_id uuid;
  before_row jsonb;
  after_row jsonb;
begin
  org_id := coalesce((to_jsonb(new)->>'organization_id')::uuid, (to_jsonb(old)->>'organization_id')::uuid);
  entity_id := coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid, gen_random_uuid());
  before_row := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  after_row := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  if tg_op='UPDATE' and before_row=after_row then return new; end if;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(org_id,auth.uid(),lower(tg_op)||':'||tg_table_name,tg_table_name,entity_id,jsonb_build_object('before',before_row,'after',after_row));
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare item record;
begin
  for item in select * from (values
    ('products','products'),('product_categories','products'),('customers','customers'),('suppliers','suppliers'),
    ('sales','sales'),('sale_items','sales'),('payments','sales'),('purchases','purchases'),('purchase_items','purchases'),
    ('supplier_payments','purchases'),('stock_adjustments','inventory'),('stock_movements','inventory'),('expenses','expenses'),('branches','inventory'),
    ('stock_transfers','inventory'),('stock_transfer_items','inventory')
  ) as permissions(table_name,permission_key) loop
    execute format('drop policy if exists advanced_role_read_permission on public.%I',item.table_name);
    execute format('create policy advanced_role_read_permission on public.%I as restrictive for select to authenticated using (public.has_org_permission(organization_id,%L,''view''))',item.table_name,item.permission_key);
  end loop;
end;
$$;

drop trigger if exists trg_audit_organization_role_permissions on public.organization_role_permissions;
create trigger trg_audit_organization_role_permissions after insert or update or delete on public.organization_role_permissions
for each row execute function public.capture_tenant_audit_log();

do $$
declare table_name text;
begin
  foreach table_name in array array['organization_settings','organization_members','support_tickets'] loop
    execute format('drop trigger if exists trg_audit_%I on public.%I',table_name,table_name);
    execute format('create trigger trg_audit_%I after insert or update or delete on public.%I for each row execute function public.capture_tenant_audit_log()',table_name,table_name);
  end loop;
end;
$$;

-- Keep supplier payments out of operating cash inflows; those are recorded in
-- supplier_payments and included on the outflow side of this report.
create or replace view public.cash_flow_performance as
with inflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.payments
  where status='posted' and payment_type in ('customer_payment','other') and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', sale_date)::date, sum(paid_amount)
  from public.sales
  where status='confirmed' and customer_id is null and public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', sale_date)::date
), outflows as (
  select organization_id, date_trunc('month', payment_date)::date as period_start, sum(amount) as amount
  from public.supplier_payments
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', payment_date)::date
  union all
  select organization_id, date_trunc('month', expense_date)::date, sum(amount)
  from public.expenses
  where public.has_org_membership(organization_id)
  group by organization_id, date_trunc('month', expense_date)::date
), all_periods as (
  select organization_id, period_start from inflows
  union
  select organization_id, period_start from outflows
), inflow_totals as (
  select organization_id, period_start, sum(amount) as cash_in from inflows group by organization_id, period_start
), outflow_totals as (
  select organization_id, period_start, sum(amount) as cash_out from outflows group by organization_id, period_start
)
select all_periods.organization_id, all_periods.period_start,
       coalesce(inflow_totals.cash_in, 0)::numeric as cash_in,
       coalesce(outflow_totals.cash_out, 0)::numeric as cash_out,
       (coalesce(inflow_totals.cash_in, 0)-coalesce(outflow_totals.cash_out, 0))::numeric as net_cash_flow
from all_periods
left join inflow_totals using (organization_id, period_start)
left join outflow_totals using (organization_id, period_start);

-- Views use the caller's RLS policies, so role-level read restrictions also cover report queries.
do $$
declare view_name text;
begin
  foreach view_name in array array[
    'product_sales_performance','monthly_sales_performance','yearly_sales_performance','purchase_analytics',
    'profit_loss_performance','cash_flow_performance','branch_stock_balances','branch_sales_performance',
    'product_stock_balances','customer_balances_summary','supplier_balances_summary','daily_sales_performance'
  ] loop
    execute format('alter view public.%I set (security_invoker = true)',view_name);
  end loop;
end;
$$;
-- <<< END 0041_advanced_permission_read_enforcement.sql

-- >>> BEGIN 0042_tenant_security_baseline.sql
-- Close tenant write paths and make role permissions apply on every plan.
-- Business entities remain writable through RLS; posted ledgers are RPC-only.

create or replace function public.has_org_permission(p_org_id uuid, p_permission text, p_action text default 'view')
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  member_role text;
  allowed boolean;
begin
  if auth.role() = 'service_role' then return true; end if;
  if auth.uid() is null then return false; end if;
  if public.is_platform_admin() then return true; end if;
  if p_action not in ('view','create','update','delete') then return false; end if;

  select role into member_role
  from public.organization_members
  where organization_id = p_org_id and user_id = auth.uid() and is_active;
  if member_role is null then return false; end if;
  if member_role in ('owner','admin') then return true; end if;

  -- Custom permissions only apply when the organization's plan includes them.
  if public.organization_has_plan_feature(p_org_id, 'advanced_permissions') then
    select case p_action
      when 'view' then can_view
      when 'create' then can_create
      when 'update' then can_update
      when 'delete' then can_delete
    end into allowed
    from public.organization_role_permissions
    where organization_id = p_org_id and role = member_role and permission_key = p_permission;
    if found then return coalesce(allowed, false); end if;
  end if;

  -- Safe baseline permissions also apply to plans without custom role settings.
  if member_role = 'staff' then
    if p_action = 'view' then return p_permission in ('products','customers','sales','inventory'); end if;
    return p_permission in ('sales','customers') and p_action in ('create','update');
  end if;
  if member_role = 'manager' then
    return p_permission in ('products','customers','suppliers','sales','purchases','inventory','expenses')
      and p_action <> 'delete';
  end if;
  return false;
end;
$$;
revoke all on function public.has_org_permission(uuid,text,text) from public, anon;
grant execute on function public.has_org_permission(uuid,text,text) to authenticated, service_role;

-- SECURITY DEFINER RPCs bypass table grants and RLS, so retain role checks in
-- triggers for every operational write path as well.
create or replace function public.enforce_advanced_role_permission()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  permission_key text;
  action_key text;
  org_id uuid;
begin
  org_id := coalesce(new.organization_id, old.organization_id);
  permission_key := case tg_table_name
    when 'products' then 'products' when 'product_categories' then 'products'
    when 'customers' then 'customers' when 'suppliers' then 'suppliers'
    when 'sales' then 'sales' when 'sale_items' then 'sales' when 'payments' then 'sales' when 'payment_allocations' then 'sales'
    when 'purchases' then 'purchases' when 'purchase_items' then 'purchases' when 'supplier_payments' then 'purchases'
    when 'stock_adjustments' then 'inventory' when 'stock_movements' then 'inventory'
    when 'branches' then 'inventory' when 'stock_transfers' then 'inventory' when 'stock_transfer_items' then 'inventory'
    when 'expenses' then 'expenses' when 'expense_categories' then 'expenses'
    else null end;
  if tg_table_name = 'stock_movements' then
    permission_key := case new.movement_type
      when 'sales_out' then 'sales' when 'sale_reversal' then 'sales' when 'customer_return' then 'sales'
      when 'purchase_in' then 'purchases' when 'supplier_return' then 'purchases'
      else 'inventory' end;
  end if;
  if permission_key is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  action_key := case tg_op when 'INSERT' then 'create' when 'UPDATE' then 'update' when 'DELETE' then 'delete' else 'view' end;
  if not public.has_org_permission(org_id, permission_key, action_key) then
    raise exception 'Your organization role does not allow this action';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'products','product_categories','customers','suppliers','sales','sale_items','payments','payment_allocations',
    'purchases','purchase_items','supplier_payments','stock_adjustments','stock_movements','expenses','expense_categories',
    'branches','stock_transfers','stock_transfer_items'
  ] loop
    execute format('drop trigger if exists trg_advanced_role_permission on public.%I', table_name);
    execute format('create trigger trg_advanced_role_permission before insert or update or delete on public.%I for each row execute function public.enforce_advanced_role_permission()', table_name);
  end loop;
end;
$$;

-- Restrictive policies compose with the existing tenant membership policies.
do $$
declare item record;
begin
  for item in select * from (values
    ('products','products'),('product_categories','products'),('customers','customers'),('suppliers','suppliers'),
    ('sales','sales'),('sale_items','sales'),('purchases','purchases'),('purchase_items','purchases'),
    ('expenses','expenses'),('expense_categories','expenses'),('stock_adjustments','inventory'),('stock_movements','inventory'),
    ('branches','inventory'),('stock_transfers','inventory'),('stock_transfer_items','inventory')
  ) as scoped(table_name, permission_key) loop
    execute format('drop policy if exists tenant_role_insert on public.%I', item.table_name);
    execute format('drop policy if exists tenant_role_update on public.%I', item.table_name);
    execute format('drop policy if exists tenant_role_delete on public.%I', item.table_name);
    execute format(
      'create policy tenant_role_insert on public.%I as restrictive for insert to authenticated with check (public.has_org_permission(organization_id,%L,''create''))',
      item.table_name, item.permission_key);
    execute format(
      'create policy tenant_role_update on public.%I as restrictive for update to authenticated using (public.has_org_permission(organization_id,%L,''update'')) with check (public.has_org_permission(organization_id,%L,''update''))',
      item.table_name, item.permission_key, item.permission_key);
    execute format(
      'create policy tenant_role_delete on public.%I as restrictive for delete to authenticated using (public.has_org_permission(organization_id,%L,''delete''))',
      item.table_name, item.permission_key);
  end loop;
end;
$$;

-- Membership changes and organization provisioning must remain atomic and owner-controlled.
drop policy if exists "User can insert themselves as owner" on public.organization_members;
drop policy if exists "Owners and Admins can manage members" on public.organization_members;
create policy organization_members_admin_write on public.organization_members for all to authenticated
  using (public.is_org_admin_or_owner(organization_id))
  with check (public.is_org_admin_or_owner(organization_id));
revoke insert, update, delete on public.organization_members from anon, authenticated;

-- The SECURITY DEFINER onboarding RPC is the only client path that provisions a tenant.
drop policy if exists "Authenticated users can create organizations" on public.organizations;
drop policy if exists "Authenticated users can create organization" on public.organizations;
revoke insert on public.organizations from anon, authenticated;
revoke all on function public.create_organization_with_owner(text,text,text,text,text) from public, anon;
grant execute on function public.create_organization_with_owner(text,text,text,text,text) to authenticated;

-- Migration 0012 accidentally allowed every authenticated user to list every tenant.
drop policy if exists "Members can view own organization" on public.organizations;
drop policy if exists "Members can view their organizations" on public.organizations;
create policy organizations_member_read on public.organizations for select to authenticated
  using (public.has_org_membership(id) or public.is_platform_admin());

-- Keep provisioning atomic: a failed trial/subscription setup must roll back the tenant.
create or replace function public.create_organization_with_owner(
  p_name text,
  p_slug text,
  p_plan_id text default 'starter',
  p_phone text default null,
  p_address text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_org_id uuid;
  v_org record;
begin
  if v_user_id is null then raise exception 'Unauthorized: user must be authenticated'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 160 then raise exception 'Organization name is invalid'; end if;
  if p_slug is null or p_slug !~ '^[a-z0-9-]{2,80}$' then raise exception 'Organization identifier is invalid'; end if;

  insert into public.organizations (name, slug, currency, timezone, is_active)
  values (btrim(p_name), btrim(p_slug), 'MMK', 'Asia/Yangon', true)
  returning id into v_org_id;
  insert into public.organization_members (organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'owner', true);
  insert into public.organization_settings (
    organization_id, currency_code, currency_symbol, timezone, phone, address, costing_method, low_stock_threshold_default
  ) values (v_org_id, 'MMK', 'Ks', 'Asia/Yangon', p_phone, p_address, 'weighted_average', 5);
  perform public.initialize_organization_trial(v_org_id, p_plan_id);
  insert into public.units (organization_id, code, name, precision)
  values
    (v_org_id, 'pcs', 'Pieces (ခု)', 0),
    (v_org_id, 'box', 'Box (ဖာ)', 0),
    (v_org_id, 'pack', 'Packet (ထုပ်)', 0),
    (v_org_id, 'dozen', 'Dozen (ဒါဇင်)', 0)
  on conflict do nothing;
  select id, name, slug, currency, timezone, is_active into v_org
  from public.organizations where id = v_org_id;
  return to_jsonb(v_org);
end;
$$;
revoke all on function public.create_organization_with_owner(text,text,text,text,text) from public, anon;
grant execute on function public.create_organization_with_owner(text,text,text,text,text) to authenticated;

-- Never allow a user to grant themselves platform administrator status.
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone_number, avatar_url) on public.profiles to authenticated;

-- These tables are immutable financial/inventory ledgers. Mutations go through validated RPCs.
revoke insert, update, delete on public.stock_movements, public.stock_adjustments,
  public.payments, public.payment_allocations, public.supplier_payments, public.audit_logs
  from anon, authenticated;

-- RPCs used by the client after direct ledger writes are revoked.
revoke all on function public.next_document_number(uuid,text) from public, anon;
grant execute on function public.next_document_number(uuid,text) to authenticated;
revoke all on function public.create_stock_adjustment(uuid,uuid,numeric,text,text) from public, anon;
grant execute on function public.create_stock_adjustment(uuid,uuid,numeric,text,text) to authenticated;
revoke all on function public.receive_purchase(uuid,uuid,numeric,text) from public, anon;
grant execute on function public.receive_purchase(uuid,uuid,numeric,text) to authenticated;
revoke all on function public.confirm_sale(uuid,uuid,text,numeric,text) from public, anon;
grant execute on function public.confirm_sale(uuid,uuid,text,numeric,text) to authenticated;
revoke all on function public.void_or_reverse_sale(uuid,uuid,text) from public, anon;
grant execute on function public.void_or_reverse_sale(uuid,uuid,text) to authenticated;
revoke all on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public, anon;
grant execute on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;

notify pgrst, 'reload schema';
-- <<< END 0042_tenant_security_baseline.sql

-- >>> BEGIN 0043_p0_transaction_integrity.sql
-- P0 transaction and tenant-integrity hardening.
-- This migration is incremental and does not modify production by itself.
-- Composite FKs are added NOT VALID: new writes are protected immediately while
-- existing rows remain unvalidated until an operator reviews mismatch counts.

begin;

-- A globally unique id also makes (organization_id,id) unique. These indexes are
-- referenced by tenant-aware composite foreign keys below.
create unique index if not exists products_org_id_uidx on public.products(organization_id,id);
create unique index if not exists product_categories_org_id_uidx on public.product_categories(organization_id,id);
create unique index if not exists units_org_id_uidx on public.units(organization_id,id);
create unique index if not exists suppliers_org_id_uidx on public.suppliers(organization_id,id);
create unique index if not exists branches_org_id_uidx on public.branches(organization_id,id);
create unique index if not exists purchases_org_id_uidx on public.purchases(organization_id,id);
create unique index if not exists sales_org_id_uidx on public.sales(organization_id,id);
create unique index if not exists customers_org_id_uidx on public.customers(organization_id,id);
create unique index if not exists payments_org_id_uidx on public.payments(organization_id,id);
create unique index if not exists stock_transfers_org_id_uidx on public.stock_transfers(organization_id,id);

-- Preserve legacy cross-tenant rows for remediation while enforcing ownership on
-- all future insert/update operations. Optional references that need column-specific
-- SET NULL semantics remain validated by the RPCs until an explicit migration plan.
do $$
declare
  rel record;
  child_oid regclass;
  parent_oid regclass;
begin
  for rel in
    select * from (values
      ('products','unit_id','units','id','products_org_unit_fk'),
      ('purchases','supplier_id','suppliers','id','purchases_org_supplier_fk'),
      ('purchases','branch_id','branches','id','purchases_org_branch_fk'),
      ('purchase_items','purchase_id','purchases','id','purchase_items_org_purchase_fk'),
      ('purchase_items','product_id','products','id','purchase_items_org_product_fk'),
      ('supplier_payments','supplier_id','suppliers','id','supplier_payments_org_supplier_fk'),
      ('sales','customer_id','customers','id','sales_org_customer_fk'),
      ('sales','branch_id','branches','id','sales_org_branch_fk'),
      ('sale_items','sale_id','sales','id','sale_items_org_sale_fk'),
      ('sale_items','product_id','products','id','sale_items_org_product_fk'),
      ('payments','customer_id','customers','id','payments_org_customer_fk'),
      ('payment_allocations','payment_id','payments','id','payment_allocations_org_payment_fk'),
      ('payment_allocations','sale_id','sales','id','payment_allocations_org_sale_fk'),
      ('stock_adjustments','product_id','products','id','stock_adjustments_org_product_fk'),
      ('stock_adjustments','branch_id','branches','id','stock_adjustments_org_branch_fk'),
      ('stock_movements','product_id','products','id','stock_movements_org_product_fk'),
      ('stock_movements','branch_id','branches','id','stock_movements_org_branch_fk'),
      ('stock_transfers','source_branch_id','branches','id','stock_transfers_org_source_branch_fk'),
      ('stock_transfers','destination_branch_id','branches','id','stock_transfers_org_destination_branch_fk'),
      ('stock_transfer_items','transfer_id','stock_transfers','id','stock_transfer_items_org_transfer_fk'),
      ('stock_transfer_items','product_id','products','id','stock_transfer_items_org_product_fk')
    ) as relationships(child_table, child_key, parent_table, parent_key, constraint_name)
  loop
    child_oid := to_regclass(format('public.%I', rel.child_table));
    parent_oid := to_regclass(format('public.%I', rel.parent_table));
    if child_oid is null or parent_oid is null then
      raise exception 'Required table for tenant FK %.% -> %.% is missing', rel.child_table, rel.child_key, rel.parent_table, rel.parent_key;
    end if;
    if not exists (select 1 from pg_constraint where conrelid=child_oid and conname=rel.constraint_name) then
      execute format(
        'alter table %s add constraint %I foreign key (organization_id,%I) references %s (organization_id,%I) not valid',
        child_oid, rel.constraint_name, rel.child_key, parent_oid, rel.parent_key
      );
    end if;
  end loop;
end;
$$;

-- Replace unsafe globally unique request-key constraints with organization-scoped
-- uniqueness. Existing values cannot collide across organizations while the old
-- global constraint exists; a pre-deployment catalog/data check is still required.
create unique index if not exists sales_org_idempotency_key_uidx
  on public.sales(organization_id,idempotency_key) where idempotency_key is not null;
create unique index if not exists payments_org_idempotency_key_uidx
  on public.payments(organization_id,idempotency_key) where idempotency_key is not null;
alter table public.sales drop constraint if exists sales_idempotency_key_key;
alter table public.payments drop constraint if exists payments_idempotency_key_key;

-- Remove the blanket authenticated SELECT allowance from organization settings.
drop policy if exists "Members can view organization settings" on public.organization_settings;
create policy "Members can view organization settings"
  on public.organization_settings for select to authenticated
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

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
  v_product public.products%rowtype;
  v_item record;
  v_requested numeric(14,2);
  v_available numeric(14,2);
  v_subtotal numeric(14,2) := 0;
  v_line_discount numeric(14,2) := 0;
  v_total numeric(14,2) := 0;
  v_total_cost numeric(14,2) := 0;
  v_paid numeric(14,2) := coalesce(p_amount_paid,0);
  v_pay_status text;
  v_payment_id uuid;
  v_payment_num text;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'sales','create') then raise exception 'Unauthorized'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;
  if v_paid < 0 then raise exception 'Payment amount cannot be negative'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then
    raise exception 'Unsupported payment method';
  end if;

  -- Retries are scoped to this organization and must refer to this exact sale.
  select * into v_sale from public.sales
  where organization_id=p_org_id and idempotency_key=p_idempotency_key;
  if found then
    if v_sale.id <> p_sale_id then raise exception 'Idempotency key was already used for another sale'; end if;
    if v_sale.status = 'confirmed' then
      return jsonb_build_object('success',true,'sale_id',v_sale.id,'invoice_number',v_sale.invoice_number,
        'payment_status',v_sale.payment_status,'sale',to_jsonb(v_sale),
        'items',(select coalesce(jsonb_agg(to_jsonb(si) order by si.created_at,si.id),'[]'::jsonb)
                 from public.sale_items si where si.organization_id=p_org_id and si.sale_id=v_sale.id));
    end if;
  end if;

  select * into v_sale from public.sales
  where id=p_sale_id and organization_id=p_org_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if v_sale.status <> 'draft' then raise exception 'Only draft sales can be confirmed'; end if;
  if v_sale.branch_id is null or not exists (
    select 1 from public.branches b where b.id=v_sale.branch_id and b.organization_id=p_org_id and b.is_active
  ) then raise exception 'Sale must use an active branch in this organization'; end if;
  if v_sale.customer_id is not null and not exists (
    select 1 from public.customers c where c.id=v_sale.customer_id and c.organization_id=p_org_id and c.is_active
  ) then raise exception 'Sale customer does not belong to this organization or is inactive'; end if;
  if coalesce(v_sale.tax_amount,0) <> 0 then
    raise exception 'Tax cannot be posted until an organization tax rule is configured';
  end if;

  if not exists (select 1 from public.sale_items si where si.sale_id=p_sale_id and si.organization_id=p_org_id) then
    raise exception 'Sale requires at least one item';
  end if;
  if exists (select 1 from public.sale_items si where si.sale_id=p_sale_id and si.organization_id<>p_org_id) then
    raise exception 'Sale contains a line from another organization';
  end if;

  -- Lock product rows in a stable order before checking branch stock. The same
  -- organization/branch/product advisory key is used by the branch stock trigger.
  for v_item in
    select si.product_id, sum(si.quantity)::numeric(14,2) as requested_quantity
    from public.sale_items si
    where si.sale_id=p_sale_id and si.organization_id=p_org_id
    group by si.product_id order by si.product_id
  loop
    select * into v_product from public.products p
    where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active
    for update;
    if not found then raise exception 'Sale product is missing, inactive, or belongs to another organization'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || v_sale.branch_id::text || ':' || v_product.id::text,0));
    select coalesce(sum(sm.quantity),0) into v_available from public.stock_movements sm
    where sm.organization_id=p_org_id and sm.branch_id=v_sale.branch_id and sm.product_id=v_product.id;
    if v_available < v_item.requested_quantity then
      raise exception 'Insufficient stock for product % (available %, requested %)',v_product.name,v_available,v_item.requested_quantity;
    end if;
  end loop;

  -- Catalog price is authoritative in the current POS (which has no price override
  -- approval flow). Recompute every line and the header instead of trusting totals.
  for v_item in
    select si.* from public.sale_items si
    where si.sale_id=p_sale_id and si.organization_id=p_org_id order by si.product_id,si.id
    for update
  loop
    select * into v_product from public.products p
    where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active;
    if not found then raise exception 'Sale product is missing, inactive, or belongs to another organization'; end if;
    if v_item.quantity <= 0 then raise exception 'Sale quantity must be positive'; end if;
    if v_item.unit_price <> v_product.sale_price then raise exception 'Sale price differs from the current approved product price'; end if;
    if v_item.discount_amount < 0 or v_item.discount_amount > (v_item.quantity * v_item.unit_price) then
      raise exception 'Sale line discount is outside the allowed range';
    end if;
    update public.sale_items set unit_cost=v_product.average_cost,
      total_amount=round(v_item.quantity*v_item.unit_price-v_item.discount_amount,2)
    where id=v_item.id and organization_id=p_org_id;
    v_subtotal := v_subtotal + round(v_item.quantity*v_item.unit_price,2);
    v_line_discount := v_line_discount + v_item.discount_amount;
    v_total_cost := v_total_cost + (v_item.quantity*v_product.average_cost);
  end loop;

  if v_sale.discount_amount < 0 or v_sale.discount_amount + v_line_discount > v_subtotal then
    raise exception 'Sale discount exceeds the item subtotal';
  end if;
  v_total := round(v_subtotal-v_line_discount-v_sale.discount_amount,2);
  if v_paid > v_total then raise exception 'Received payment cannot exceed the sale total'; end if;
  if v_sale.customer_id is null and v_paid < v_total then
    raise exception 'A customer is required for a credit or partially paid sale';
  end if;
  v_pay_status := case when v_paid >= v_total then 'paid' when v_paid > 0 then 'partial' else 'unpaid' end;

  update public.sales set subtotal=v_subtotal,total=v_total,total_amount=v_total,
    status='confirmed',total_cost=round(v_total_cost,2),paid_amount=v_paid,
    payment_status=v_pay_status,idempotency_key=p_idempotency_key,updated_at=now()
  where id=p_sale_id and organization_id=p_org_id;

  if v_paid > 0 then
    v_payment_num := public.next_document_number(p_org_id,'customer_payment');
    insert into public.payments(organization_id,customer_id,payment_number,payment_date,
      amount,allocated_amount,payment_method,status,idempotency_key,created_by)
    values(p_org_id,v_sale.customer_id,v_payment_num,current_date,v_paid,v_paid,p_payment_method,
      'posted','sale:'||p_idempotency_key,v_user_id)
    returning id into v_payment_id;
    insert into public.payment_allocations(organization_id,payment_id,sale_id,allocated_amount)
    values(p_org_id,v_payment_id,p_sale_id,v_paid);
  end if;

  for v_item in
    select si.product_id, sum(si.quantity)::numeric(14,2) as quantity,
      max(si.unit_cost)::numeric(14,4) as unit_cost
    from public.sale_items si where si.sale_id=p_sale_id and si.organization_id=p_org_id
    group by si.product_id order by si.product_id
  loop
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,
      quantity,unit_cost,reference_type,reference_id,created_by)
    values(p_org_id,v_sale.branch_id,v_item.product_id,'sales_out',-v_item.quantity,
      v_item.unit_cost,'sale',p_sale_id,v_user_id);
  end loop;

  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'sale.confirm','sale',p_sale_id,
    jsonb_build_object('invoice_number',v_sale.invoice_number,'total',v_total,'paid',v_paid,'idempotency_key',p_idempotency_key));
  select * into v_sale from public.sales where id=p_sale_id and organization_id=p_org_id;
  return jsonb_build_object('success',true,'sale_id',p_sale_id,'invoice_number',v_sale.invoice_number,
    'payment_status',v_pay_status,'sale',to_jsonb(v_sale),
    'items',(select coalesce(jsonb_agg(to_jsonb(si) order by si.created_at,si.id),'[]'::jsonb)
             from public.sale_items si where si.organization_id=p_org_id and si.sale_id=p_sale_id));
end;
$$;

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
  v_payment public.payments%rowtype;
  v_sale public.sales%rowtype;
  v_alloc jsonb;
  v_sale_id uuid;
  v_alloc_amt numeric(14,2);
  v_total_allocated numeric(14,2) := 0;
  v_amount numeric(14,2);
  v_payment_num text;
  v_payment_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'customers','update') then raise exception 'Unauthorized'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  v_amount := round(p_amount,2);
  if v_amount<=0 then raise exception 'Payment amount is below the supported currency precision'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then raise exception 'Unsupported payment method'; end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then raise exception 'A valid idempotency key is required'; end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then raise exception 'Allocations must be a JSON array'; end if;
  if not exists(select 1 from public.customers c where c.id=p_customer_id and c.organization_id=p_org_id and c.is_active) then
    raise exception 'Customer does not belong to this organization or is inactive';
  end if;

  select * into v_payment from public.payments p
  where p.organization_id=p_org_id and p.idempotency_key=p_idempotency_key for update;
  if found then
    if v_payment.customer_id is distinct from p_customer_id or v_payment.amount<>v_amount or v_payment.payment_method<>p_payment_method then
      raise exception 'Idempotency key was already used for a different payment';
    end if;
    return jsonb_build_object('success',true,'payment_id',v_payment.id,'payment_number',v_payment.payment_number,
      'allocated_amount',v_payment.allocated_amount,'unallocated_amount',v_payment.amount-v_payment.allocated_amount);
  end if;

  if exists(select 1 from jsonb_array_elements(p_allocations) x(value)
    group by value->>'sale_id' having count(*)>1) then raise exception 'Duplicate invoice allocation'; end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'sale_id' loop
    if jsonb_typeof(v_alloc)<>'object' or nullif(v_alloc->>'sale_id','') is null or nullif(v_alloc->>'amount','') is null then
      raise exception 'Each allocation needs a sale_id and amount';
    end if;
    v_alloc_amt := (v_alloc->>'amount')::numeric(14,2);
    if v_alloc_amt<=0 then raise exception 'Allocation amount must be greater than zero at supported currency precision'; end if;
    v_total_allocated := v_total_allocated+v_alloc_amt;
  end loop;
  if v_total_allocated>v_amount then raise exception 'Allocations cannot exceed the payment amount'; end if;

  v_payment_num := public.next_document_number(p_org_id,'customer_payment');
  insert into public.payments(organization_id,customer_id,payment_number,payment_date,amount,
    allocated_amount,payment_method,reference_number,notes,status,idempotency_key,created_by)
  values(p_org_id,p_customer_id,v_payment_num,current_date,v_amount,0,p_payment_method,
    p_reference_number,p_notes,'posted',p_idempotency_key,v_user_id)
  returning id into v_payment_id;

  -- UUID lexical order gives every concurrent multi-invoice payment the same lock order.
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'sale_id')::uuid loop
    v_sale_id := (v_alloc->>'sale_id')::uuid;
    v_alloc_amt := (v_alloc->>'amount')::numeric(14,2);
    select * into v_sale from public.sales s
      where s.id=v_sale_id and s.organization_id=p_org_id for update;
    if not found then raise exception 'Invoice does not belong to this organization'; end if;
    if v_sale.status<>'confirmed' then raise exception 'Only confirmed invoices can receive allocations'; end if;
    if v_sale.customer_id is distinct from p_customer_id then raise exception 'Invoice belongs to another customer'; end if;
    if v_alloc_amt>greatest(v_sale.total_amount-v_sale.paid_amount,0) then raise exception 'Allocation exceeds invoice outstanding balance'; end if;
    insert into public.payment_allocations(organization_id,payment_id,sale_id,allocated_amount)
      values(p_org_id,v_payment_id,v_sale_id,v_alloc_amt);
    update public.sales set paid_amount=paid_amount+v_alloc_amt,
      payment_status=case when paid_amount+v_alloc_amt>=total_amount then 'paid' else 'partial' end,
      updated_at=now()
      where id=v_sale_id and organization_id=p_org_id;
  end loop;
  update public.payments set allocated_amount=v_total_allocated where id=v_payment_id and organization_id=p_org_id;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'customer_payment.create','payment',v_payment_id,
    jsonb_build_object('payment_number',v_payment_num,'amount',p_amount,'allocated_amount',v_total_allocated,'idempotency_key',p_idempotency_key));
  return jsonb_build_object('success',true,'payment_id',v_payment_id,'payment_number',v_payment_num,
    'allocated_amount',v_total_allocated,'unallocated_amount',v_amount-v_total_allocated);
end;
$$;

-- Secure the existing one-shot receiving API. This preserves its signature for
-- current clients, but now receives only the unreceived remainder of each line and
-- rejects replay once the purchase is fully received. A separate partial-GRN UI/API
-- is a planned follow-on; callers of this compatible RPC receive all remaining units.
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
  v_product public.products%rowtype;
  v_item record;
  v_remaining numeric(14,2);
  v_stock numeric(14,2);
  v_new_avg_cost numeric(14,4);
  v_paid numeric(14,2) := coalesce(p_amount_paid,0);
  v_payment_number text;
  v_outstanding numeric(14,2);
  v_subtotal numeric(14,2);
  v_total numeric(14,2);
  v_supplier_id uuid;
  v_receipt_count integer := 0;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'purchases','update') then raise exception 'Unauthorized'; end if;
  if v_paid<0 then raise exception 'Payment amount cannot be negative'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then raise exception 'Unsupported payment method'; end if;

  select supplier_id into v_supplier_id from public.purchases
    where id=p_purchase_id and organization_id=p_org_id;
  if not found then raise exception 'Purchase order not found'; end if;
  perform 1 from public.suppliers s
    where s.id=v_supplier_id and s.organization_id=p_org_id for update;
  if not found then raise exception 'Purchase supplier does not belong to this organization'; end if;
  select * into v_purchase from public.purchases
    where id=p_purchase_id and organization_id=p_org_id for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if v_purchase.supplier_id<>v_supplier_id then raise exception 'Purchase supplier changed during receiving; retry the operation'; end if;
  if v_purchase.status in ('received','voided') then raise exception 'Purchase cannot be received in its current status'; end if;
  if not exists(select 1 from public.suppliers s where s.id=v_purchase.supplier_id and s.organization_id=p_org_id and s.is_active) then
    raise exception 'Purchase supplier does not belong to this organization or is inactive';
  end if;
  if v_purchase.branch_id is null or not exists(select 1 from public.branches b where b.id=v_purchase.branch_id and b.organization_id=p_org_id and b.is_active) then
    raise exception 'Purchase must use an active branch in this organization';
  end if;
  if not exists(select 1 from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id and pi.quantity>pi.received_quantity) then
    raise exception 'Purchase has no outstanding quantities to receive';
  end if;
  if exists(select 1 from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id<>p_org_id) then
    raise exception 'Purchase contains a line from another organization';
  end if;
  if coalesce(v_purchase.tax_amount,0)<>0 then raise exception 'Purchase tax cannot be posted until an organization tax rule is configured'; end if;
  select coalesce(sum(round(pi.quantity*pi.unit_cost,2)),0)::numeric(14,2)
    into v_subtotal from public.purchase_items pi
    where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id;
  if v_purchase.discount_amount<0 or v_purchase.discount_amount>v_subtotal then raise exception 'Purchase discount exceeds item subtotal'; end if;
  v_total := round(v_subtotal-v_purchase.discount_amount,2);
  update public.purchases set subtotal=v_subtotal,total=v_total,total_amount=v_total
    where id=p_purchase_id and organization_id=p_org_id;

  v_outstanding := greatest(v_total-coalesce(v_purchase.paid_amount,0),0);
  if v_paid>v_outstanding then raise exception 'Supplier payment exceeds purchase outstanding balance'; end if;
  -- Starter supports cash purchases. Supplier-payables is required only when
  -- receipt leaves an amount outstanding that must be tracked and paid later.
  if v_paid>0 and v_paid<v_outstanding
      and not public.organization_has_plan_feature(p_org_id,'supplier_payables') then
    raise exception 'Partial supplier payments are not available on the current plan';
  end if;

  for v_item in select pi.id,pi.product_id,pi.quantity,pi.received_quantity,pi.unit_cost
    from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id=p_org_id
      and pi.quantity>pi.received_quantity order by pi.product_id,pi.id for update
  loop
    select * into v_product from public.products p
      where p.id=v_item.product_id and p.organization_id=p_org_id and p.is_active for update;
    if not found then raise exception 'Purchase product is missing, inactive, or belongs to another organization'; end if;
    v_remaining := v_item.quantity-v_item.received_quantity;
    if v_remaining<=0 or v_item.unit_cost<0 then raise exception 'Purchase line has invalid outstanding quantity or cost'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_org_id::text||':'||v_purchase.branch_id::text||':'||v_product.id::text,0));
    select coalesce(sum(sm.quantity),0) into v_stock from public.stock_movements sm
      where sm.organization_id=p_org_id and sm.product_id=v_product.id;
    if v_stock>0 then
      v_new_avg_cost := ((v_stock*v_product.average_cost)+(v_remaining*v_item.unit_cost))/(v_stock+v_remaining);
    else
      v_new_avg_cost := v_item.unit_cost;
    end if;
    update public.products set average_cost=v_new_avg_cost,purchase_price=v_item.unit_cost,updated_at=now()
      where id=v_product.id and organization_id=p_org_id;
    insert into public.stock_movements(organization_id,branch_id,product_id,movement_type,quantity,
      unit_cost,reference_type,reference_id,created_by)
      values(p_org_id,v_purchase.branch_id,v_product.id,'purchase_in',v_remaining,v_item.unit_cost,'purchase',p_purchase_id,v_user_id);
    update public.purchase_items set received_quantity=quantity,total_cost=round(quantity*unit_cost,2)
      where id=v_item.id and organization_id=p_org_id;
    v_receipt_count := v_receipt_count+1;
  end loop;

  if v_paid>0 then
    v_payment_number := public.next_document_number(p_org_id,'supplier_payment');
    insert into public.supplier_payments(organization_id,supplier_id,purchase_id,payment_number,
      payment_date,amount,payment_method,created_by)
      values(p_org_id,v_purchase.supplier_id,p_purchase_id,v_payment_number,current_date,v_paid,p_payment_method,v_user_id);
  end if;
  update public.purchases set status='received',paid_amount=coalesce(paid_amount,0)+v_paid,updated_at=now()
    where id=p_purchase_id and organization_id=p_org_id;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
    values(p_org_id,v_user_id,'purchase.receive','purchase',p_purchase_id,
      jsonb_build_object('receipt_line_count',v_receipt_count,'payment_amount',v_paid));
  return jsonb_build_object('success',true,'purchase_id',p_purchase_id,'status','received','received_line_count',v_receipt_count);
end;
$$;

-- Revoke direct client execution of global worker jobs. Guarded platform-admin
-- actions retain authenticated access; scheduled jobs and edge workers use service_role.
revoke all on function public.cron_check_expired_subscriptions() from public,anon,authenticated;
revoke all on function public.cron_queue_daily_sales_summaries() from public,anon,authenticated;
revoke all on function public.cron_queue_low_stock_alerts() from public,anon,authenticated;
revoke all on function public.cron_queue_subscription_renewal_reminders() from public,anon,authenticated;
revoke all on function public.cron_queue_weekly_business_summary() from public,anon,authenticated;
revoke all on function public.cron_detect_expired_social_connections() from public,anon,authenticated;
revoke all on function public.cron_notify_upcoming_scheduled_posts() from public,anon,authenticated;
grant execute on function public.cron_check_expired_subscriptions() to service_role;
grant execute on function public.cron_queue_daily_sales_summaries() to service_role;
grant execute on function public.cron_queue_low_stock_alerts() to service_role;
grant execute on function public.cron_queue_subscription_renewal_reminders() to service_role;
grant execute on function public.cron_queue_weekly_business_summary() to service_role;
grant execute on function public.cron_detect_expired_social_connections() to service_role;
grant execute on function public.cron_notify_upcoming_scheduled_posts() to service_role;

revoke all on function public.cron_run_all_automations() from public,anon;
grant execute on function public.cron_run_all_automations() to authenticated,service_role;
revoke all on function public.cron_queue_debt_reminders() from public,anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated,service_role;

revoke all on function public.confirm_sale(uuid,uuid,text,numeric,text) from public,anon;
grant execute on function public.confirm_sale(uuid,uuid,text,numeric,text) to authenticated;
revoke all on function public.receive_purchase(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.receive_purchase(uuid,uuid,numeric,text) to authenticated;
revoke all on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public,anon;
grant execute on function public.record_customer_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;

notify pgrst,'reload schema';
commit;
-- <<< END 0043_p0_transaction_integrity.sql

-- >>> BEGIN 0044_supplier_payment_workflow.sql
-- Supplier payment workflow: scoped request keys, allocations and advances.
-- Additive migration: preserve prior supplier payment rows and balances.
begin;

-- Stop before changing anything if an installation has an allocation table whose
-- shape differs from this migration's contract. Inspect its columns and constraints
-- first; never create a parallel ledger or guess how legacy references map.
do $$
declare missing_columns text[];
begin
  if to_regclass('public.supplier_payment_allocations') is not null then
    select array_agg(required.column_name order by required.column_name)
      into missing_columns
      from (values
        ('id'),('organization_id'),('supplier_payment_id'),('purchase_id'),('amount')
      ) as required(column_name)
      where not exists (
        select 1 from information_schema.columns c
        where c.table_schema='public'
          and c.table_name='supplier_payment_allocations'
          and c.column_name=required.column_name
      );
    if missing_columns is not null then
      raise exception 'Existing public.supplier_payment_allocations has an incompatible schema; missing columns: %. Run the read-only schema inspection query and adapt migration 0044 before retrying.', array_to_string(missing_columns, ', ');
    end if;
  end if;
end;
$$;

alter table public.supplier_payments
  add column if not exists idempotency_key text,
  add column if not exists request_fingerprint text;
create unique index if not exists supplier_payments_org_idempotency_uidx
  on public.supplier_payments(organization_id,idempotency_key)
  where idempotency_key is not null;
create unique index if not exists supplier_payments_org_id_uidx
  on public.supplier_payments(organization_id,id);

create table if not exists public.supplier_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  supplier_payment_id uuid not null references public.supplier_payments(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete restrict,
  amount numeric(14,2) not null check(amount>0),
  created_at timestamptz not null default now(),
  unique(organization_id,supplier_payment_id,purchase_id)
);
create index if not exists supplier_payment_allocations_org_purchase_idx
  on public.supplier_payment_allocations(organization_id,purchase_id);
create unique index if not exists supplier_payment_allocations_org_id_uidx
  on public.supplier_payment_allocations(organization_id,id);

do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payment_allocations'::regclass and conname='supplier_allocations_org_payment_fk') then
    alter table public.supplier_payment_allocations add constraint supplier_allocations_org_payment_fk
      foreign key(organization_id,supplier_payment_id) references public.supplier_payments(organization_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payment_allocations'::regclass and conname='supplier_allocations_org_purchase_fk') then
    alter table public.supplier_payment_allocations add constraint supplier_allocations_org_purchase_fk
      foreign key(organization_id,purchase_id) references public.purchases(organization_id,id) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.supplier_payments'::regclass and conname='supplier_payments_org_purchase_fk') then
    alter table public.supplier_payments add constraint supplier_payments_org_purchase_fk
      foreign key(organization_id,purchase_id) references public.purchases(organization_id,id)
      on delete set null (purchase_id) not valid;
  end if;
end;
$$;

-- Existing supplier_payments.purchase_id remains authoritative for legacy rows.
-- Do not backfill allocation rows here: legacy cross-tenant references require a
-- separate read-only mismatch review before creating child rows under NOT VALID FKs.

alter table public.supplier_payment_allocations enable row level security;
drop policy if exists supplier_payment_allocations_read_members on public.supplier_payment_allocations;
create policy supplier_payment_allocations_read_members on public.supplier_payment_allocations
  for select to authenticated using(public.has_org_membership(organization_id) or public.is_platform_admin());
revoke all on public.supplier_payment_allocations from public,anon,authenticated;
grant select on public.supplier_payment_allocations to authenticated,service_role;

-- Supplier payments affect balances and must only be written through validated,
-- transactional RPCs such as receive_purchase and record_supplier_payment_and_allocate.
revoke insert,update,delete on public.supplier_payments from public,anon,authenticated;
grant select on public.supplier_payments to authenticated;

create or replace function public.record_supplier_payment_and_allocate(
  p_org_id uuid,
  p_supplier_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_allocations jsonb default '[]'::jsonb,
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
  v_payment public.supplier_payments%rowtype;
  v_purchase public.purchases%rowtype;
  v_alloc jsonb;
  v_purchase_id uuid;
  v_alloc_amount numeric(14,2);
  v_total_allocated numeric(14,2) := 0;
  v_amount numeric(14,2);
  v_subtotal numeric(14,2);
  v_purchase_total numeric(14,2);
  v_payment_number text;
  v_fingerprint text;
  v_payment_id uuid;
  v_single_purchase uuid;
  v_supplier_opening numeric(14,2);
  v_supplier_due numeric(14,2);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not public.has_org_permission(p_org_id,'purchases','update') then raise exception 'Unauthorized'; end if;
  if not public.organization_has_plan_feature(p_org_id,'supplier_payables') then raise exception 'Supplier payments are not available on the current plan'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
  v_amount := round(p_amount,2);
  if v_amount<=0 then raise exception 'Payment amount is below supported currency precision'; end if;
  if p_payment_method is null or p_payment_method not in ('cash','bank_transfer','mobile_money','kbz_pay','wave_pay','other') then
    raise exception 'Unsupported payment method';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 200 then
    raise exception 'A valid idempotency key is required';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations)<>'array' then raise exception 'Allocations must be a JSON array'; end if;
  if not exists(select 1 from public.suppliers s where s.id=p_supplier_id and s.organization_id=p_org_id and s.is_active) then
    raise exception 'Supplier does not belong to this organization or is inactive';
  end if;

  if exists(select 1 from jsonb_array_elements(p_allocations) x(value)
      group by value->>'purchase_id' having count(*)>1) then raise exception 'Duplicate purchase allocation'; end if;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'purchase_id' loop
    if jsonb_typeof(v_alloc)<>'object' or nullif(v_alloc->>'purchase_id','') is null or nullif(v_alloc->>'amount','') is null then
      raise exception 'Each allocation needs a purchase_id and amount';
    end if;
    v_alloc_amount := (v_alloc->>'amount')::numeric(14,2);
    if v_alloc_amount<=0 then raise exception 'Allocation amount must be positive'; end if;
    v_total_allocated := v_total_allocated+v_alloc_amount;
  end loop;
  if v_total_allocated>v_amount then raise exception 'Allocations cannot exceed the payment amount'; end if;
  if jsonb_array_length(p_allocations)=1 then v_single_purchase := (p_allocations->0->>'purchase_id')::uuid; end if;
  select md5(jsonb_build_object(
    'organization_id',p_org_id,'supplier_id',p_supplier_id,'amount',v_amount,
    'payment_method',p_payment_method,'reference_number',p_reference_number,'notes',p_notes,
    'allocations',(select coalesce(jsonb_agg(value order by value->>'purchase_id'),'[]'::jsonb)
      from jsonb_array_elements(p_allocations))
  )::text) into v_fingerprint;

  select * into v_payment from public.supplier_payments sp
    where sp.organization_id=p_org_id and sp.idempotency_key=p_idempotency_key for update;
  if found then
    if v_payment.request_fingerprint is distinct from v_fingerprint then
      raise exception 'Idempotency key was already used for a different supplier payment';
    end if;
    return jsonb_build_object('success',true,'payment_id',v_payment.id,
      'payment_number',v_payment.payment_number,'amount',v_payment.amount,
      'allocated_amount',coalesce((select sum(a.amount) from public.supplier_payment_allocations a
        where a.organization_id=p_org_id and a.supplier_payment_id=v_payment.id),0),
      'unallocated_amount',v_payment.amount-coalesce((select sum(a.amount) from public.supplier_payment_allocations a
        where a.organization_id=p_org_id and a.supplier_payment_id=v_payment.id),0));
  end if;

  -- Serialize all new payments for a supplier so concurrent invoice payments
  -- cannot exceed the supplier's organization-wide payable. Unallocated amounts
  -- are allowed as advances; only allocated portions must fit current payable.
  select s.opening_balance into v_supplier_opening from public.suppliers s
    where s.id=p_supplier_id and s.organization_id=p_org_id for update;
  select greatest(coalesce(v_supplier_opening,0)
      + coalesce((select sum(p.total_amount) from public.purchases p
        where p.organization_id=p_org_id and p.supplier_id=p_supplier_id and p.status='received'),0)
      - coalesce((select sum(sp.amount) from public.supplier_payments sp
        where sp.organization_id=p_org_id and sp.supplier_id=p_supplier_id),0),0)
    into v_supplier_due;
  if v_total_allocated>v_supplier_due then raise exception 'Allocated payment exceeds supplier payable balance after existing advances'; end if;

  -- Stable invoice lock order prevents concurrent payments exceeding a payable.
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'purchase_id')::uuid loop
    v_purchase_id := (v_alloc->>'purchase_id')::uuid;
    v_alloc_amount := (v_alloc->>'amount')::numeric(14,2);
    select * into v_purchase from public.purchases p
      where p.id=v_purchase_id and p.organization_id=p_org_id for update;
    if not found then raise exception 'Purchase does not belong to this organization'; end if;
    if v_purchase.supplier_id<>p_supplier_id then raise exception 'Purchase belongs to another supplier'; end if;
    if v_purchase.status<>'received' then raise exception 'Only received purchases can be allocated for payment'; end if;
    if coalesce(v_purchase.tax_amount,0)<>0 then raise exception 'Purchase tax requires an organization tax rule before payment'; end if;
    select coalesce(sum(round(pi.quantity*pi.unit_cost,2)),0)::numeric(14,2) into v_subtotal
      from public.purchase_items pi where pi.purchase_id=v_purchase_id and pi.organization_id=p_org_id;
    if v_purchase.discount_amount<0 or v_purchase.discount_amount>v_subtotal then raise exception 'Purchase discount exceeds item subtotal'; end if;
    v_purchase_total := round(v_subtotal-v_purchase.discount_amount,2);
    if v_alloc_amount>greatest(v_purchase_total-coalesce(v_purchase.paid_amount,0),0) then
      raise exception 'Allocation exceeds purchase payable balance';
    end if;
    update public.purchases set subtotal=v_subtotal,total=v_purchase_total,total_amount=v_purchase_total,
      paid_amount=coalesce(paid_amount,0)+v_alloc_amount,updated_at=now()
      where id=v_purchase_id and organization_id=p_org_id;
  end loop;

  v_payment_number := public.next_document_number(p_org_id,'supplier_payment');
  insert into public.supplier_payments(organization_id,supplier_id,purchase_id,payment_number,payment_date,
    amount,payment_method,reference_number,notes,created_by,idempotency_key,request_fingerprint)
  values(p_org_id,p_supplier_id,v_single_purchase,v_payment_number,current_date,v_amount,p_payment_method,
    p_reference_number,p_notes,v_user_id,p_idempotency_key,v_fingerprint)
  returning id into v_payment_id;
  for v_alloc in select value from jsonb_array_elements(p_allocations) order by (value->>'purchase_id')::uuid loop
    insert into public.supplier_payment_allocations(organization_id,supplier_payment_id,purchase_id,amount)
    values(p_org_id,v_payment_id,(v_alloc->>'purchase_id')::uuid,(v_alloc->>'amount')::numeric(14,2));
  end loop;
  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,payload)
  values(p_org_id,v_user_id,'supplier_payment.create','supplier_payment',v_payment_id,
    jsonb_build_object('payment_number',v_payment_number,'amount',v_amount,
      'allocated_amount',v_total_allocated,'supplier_id',p_supplier_id,'idempotency_key',p_idempotency_key));
  return jsonb_build_object('success',true,'payment_id',v_payment_id,'payment_number',v_payment_number,
    'amount',v_amount,'allocated_amount',v_total_allocated,'unallocated_amount',v_amount-v_total_allocated);
end;
$$;

revoke all on function public.record_supplier_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) from public,anon;
grant execute on function public.record_supplier_payment_and_allocate(uuid,uuid,numeric,text,jsonb,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
-- <<< END 0044_supplier_payment_workflow.sql
