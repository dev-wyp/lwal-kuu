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

