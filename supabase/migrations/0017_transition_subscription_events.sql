-- ==============================================================================
-- Migration: 0017_transition_subscription_events.sql
-- Description: Transition payment_submitted event status to approved/rejected and disable duplicate actions.
-- ==============================================================================

-- 1. Update verify_subscription_payment to update existing event directly
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

  if v_event.event_type not in ('payment_submitted', 'payment_pending') then
    raise exception 'This payment event has already been processed (current status: %)', v_event.event_type;
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

    -- Update subscription record
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

    -- Mark the submitted event as approved directly
    update public.subscription_events
    set event_type = 'payment_approved',
        admin_notes = coalesce(p_admin_notes, admin_notes),
        plan_id = v_target_plan_id,
        billing_cycle = v_target_cycle
    where id = p_event_id;

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
    -- Mark the submitted event as rejected directly
    update public.subscription_events
    set event_type = 'payment_rejected',
        admin_notes = coalesce(p_admin_notes, admin_notes)
    where id = p_event_id;

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

-- 2. Cleanup any orphaned duplicate payment_submitted events where payment_approved already exists for the same amount
update public.subscription_events se1
set event_type = 'payment_approved'
where se1.event_type = 'payment_submitted'
  and exists (
    select 1 from public.subscription_events se2
    where se2.subscription_id = se1.subscription_id
      and se2.event_type = 'payment_approved'
      and se2.created_at >= se1.created_at
  );

-- Reload schema cache
notify pgrst, 'reload schema';
