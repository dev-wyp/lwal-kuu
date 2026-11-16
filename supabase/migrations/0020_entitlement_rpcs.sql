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

