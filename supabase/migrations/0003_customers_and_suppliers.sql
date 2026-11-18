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

