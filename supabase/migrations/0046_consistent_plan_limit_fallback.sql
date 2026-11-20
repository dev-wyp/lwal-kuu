-- Keep runtime limit resolution aligned with both pricing screens: use a
-- normalized row first, then the matching legacy plan column. If neither is
-- configured, return zero rather than silently treating the limit as unlimited.
create or replace function public.get_organization_feature_limit(p_org_id uuid, p_feature_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  f public.features%rowtype;
  o public.organization_feature_overrides%rowtype;
  lim integer;
begin
  if not (public.has_org_membership(p_org_id) or public.is_platform_admin()) then
    raise exception 'Access denied';
  end if;

  select * into f from public.features
  where feature_key = p_feature_key and is_active and feature_type = 'limit';
  if not found then
    return jsonb_build_object(
      'limit_value', 0, 'has_override', false, 'is_configured', false,
      'feature_key', p_feature_key
    );
  end if;

  select * into o from public.organization_feature_overrides
  where organization_id = p_org_id and feature_id = f.id and limit_override is not null
    and starts_at <= now() and (expires_at is null or expires_at > now())
  order by created_at desc limit 1;
  if found then
    return jsonb_build_object(
      'limit_value', o.limit_override, 'has_override', true, 'is_configured', true,
      'feature_key', p_feature_key
    );
  end if;

  select pfl.limit_value into lim
  from public.subscriptions s
  join public.plan_feature_limits pfl on pfl.plan_id = s.plan_id
  where s.organization_id = p_org_id and pfl.feature_id = f.id;

  if not found then
    select case p_feature_key
      when 'max_users' then p.max_users
      when 'max_products' then p.max_products
      when 'max_customers' then p.max_customers
      when 'max_suppliers' then p.max_suppliers
      when 'max_branches' then p.max_branches
      else null
    end into lim
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    where s.organization_id = p_org_id;
  end if;

  if not found or lim is null then
    return jsonb_build_object(
      'limit_value', 0, 'has_override', false, 'is_configured', false,
      'feature_key', p_feature_key
    );
  end if;

  return jsonb_build_object(
    'limit_value', lim, 'has_override', false, 'is_configured', true,
    'source', case when exists (
      select 1 from public.subscriptions s
      join public.plan_feature_limits pfl on pfl.plan_id=s.plan_id
      where s.organization_id=p_org_id and pfl.feature_id=f.id
    ) then 'normalized' else 'legacy_plan_column' end,
    'feature_key', p_feature_key
  );
end;
$$;

revoke all on function public.get_organization_feature_limit(uuid,text) from public, anon;
grant execute on function public.get_organization_feature_limit(uuid,text) to authenticated;
