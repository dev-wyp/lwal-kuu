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
