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

