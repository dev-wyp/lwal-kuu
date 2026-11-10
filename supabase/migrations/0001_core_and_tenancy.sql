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
    drop table public.organizations cascade;
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

