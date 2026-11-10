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
