-- ==============================================================================
-- Migration: 0002_product_catalog.sql
-- Description: Product categories, measurement units, products master, and RLS.
-- ==============================================================================

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

