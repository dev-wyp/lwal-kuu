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

