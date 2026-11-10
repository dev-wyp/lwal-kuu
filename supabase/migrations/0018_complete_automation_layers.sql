-- ==============================================================================
-- Migration: 0018_complete_automation_layers.sql
-- Description: Complete 4-layer automation schema (Low Stock, Renewal Reminders, Plan Limits, MRR, Weekly Summaries).
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- LAYER 2: Business Automation - Low Stock Alerts Outbox
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_low_stock_alerts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_owner_email text;
  v_low_items jsonb;
  v_queued integer := 0;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    -- Collect products where stock <= low_stock_threshold
    select jsonb_agg(
      jsonb_build_object(
        'name', name,
        'sku', sku,
        'stock_on_hand', stock_on_hand,
        'threshold', low_stock_threshold,
        'unit', unit_code
      )
    ) into v_low_items
    from public.product_stock_balances
    where organization_id = v_org.id and is_low_stock = true;

    if v_low_items is not null and jsonb_array_length(v_low_items) > 0 then
      select u.email into v_owner_email
      from public.organization_members om
      join auth.users u on u.id = om.user_id
      where om.organization_id = v_org.id and om.role = 'owner' and om.is_active = true
      limit 1;

      if v_owner_email is not null then
        insert into public.notification_outbox (
          organization_id, notification_type, recipient_email, subject, payload
        )
        values (
          v_org.id,
          'low_stock',
          v_owner_email,
          'ShopFlow: Low Stock Warning (' || jsonb_array_length(v_low_items) || ' items) - ' || v_org.name,
          jsonb_build_object(
            'item_count', jsonb_array_length(v_low_items),
            'items', v_low_items,
            'alert_time', now()
          )
        );
        v_queued := v_queued + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('queued_low_stock_alerts', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- LAYER 3: SaaS Automation - Subscription Renewal Reminders
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_subscription_renewal_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sub record;
  v_owner_email text;
  v_queued integer := 0;
  v_days_left integer;
begin
  for v_sub in
    select s.id, s.organization_id, s.status, s.current_period_end, o.name as org_name, p.name as plan_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    join public.plans p on p.id = s.plan_id
    where s.status in ('active', 'trialing')
      and s.current_period_end between now() and (now() + interval '3 days')
  loop
    v_days_left := greatest(0, extract(day from (v_sub.current_period_end - now()))::integer);

    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_sub.organization_id and om.role = 'owner' and om.is_active = true
    limit 1;

    if v_owner_email is not null then
      -- Avoid queueing duplicate reminder within same 24 hours
      if not exists (
        select 1 from public.notification_outbox
        where organization_id = v_sub.organization_id
          and notification_type = 'subscription_renewal_reminder'
          and created_at > (now() - interval '24 hours')
      ) then
        insert into public.notification_outbox (
          organization_id, notification_type, recipient_email, subject, payload
        )
        values (
          v_sub.organization_id,
          'subscription_renewal_reminder',
          v_owner_email,
          'ShopFlow: Subscription Renewal Notice (' || v_days_left || ' days left) - ' || v_sub.org_name,
          jsonb_build_object(
            'plan_name', v_sub.plan_name,
            'days_left', v_days_left,
            'expires_at', v_sub.current_period_end
          )
        );
        v_queued := v_queued + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object('queued_renewal_reminders', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- LAYER 3: SaaS Automation - Plan Limit Enforcement on Product Creation
-- ------------------------------------------------------------------------------
create or replace function public.enforce_product_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer;
  v_current_count integer;
begin
  select limit_value into v_limit
  from public.usage_limits
  where organization_id = new.organization_id and metric = 'product_count';

  if v_limit is not null and v_limit > 0 then
    select count(*) into v_current_count
    from public.products
    where organization_id = new.organization_id and is_active = true;

    if v_current_count >= v_limit then
      raise exception 'Plan limit exceeded: Your organization has reached the maximum of % products allowed on your current plan. Please upgrade to add more products.', v_limit;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_product_plan_limit on public.products;
create trigger trg_enforce_product_plan_limit
  before insert on public.products
  for each row execute function public.enforce_product_plan_limit();

-- ------------------------------------------------------------------------------
-- LAYER 4: Business Owner Automation - New Customer Notification Trigger
-- ------------------------------------------------------------------------------
create or replace function public.on_customer_created_audit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.audit_logs (organization_id, user_id, action, entity_type, entity_id, payload)
  values (
    new.organization_id,
    auth.uid(),
    'customer_created',
    'customer',
    new.id,
    jsonb_build_object('name', new.name, 'phone', new.phone, 'credit_limit', new.credit_limit)
  );
  return new;
end;
$$;

drop trigger if exists trg_customer_created_audit on public.customers;
create trigger trg_customer_created_audit
  after insert on public.customers
  for each row execute function public.on_customer_created_audit();

-- ------------------------------------------------------------------------------
-- LAYER 4: Business Owner Automation - Weekly Business Summary Outbox
-- ------------------------------------------------------------------------------
create or replace function public.cron_queue_weekly_business_summary()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_owner_email text;
  v_weekly_sales numeric;
  v_weekly_profit numeric;
  v_invoice_count integer;
  v_queued integer := 0;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    select
      coalesce(sum(total_amount), 0.00),
      coalesce(sum(total_amount - total_cost), 0.00),
      count(id)
    into v_weekly_sales, v_weekly_profit, v_invoice_count
    from public.sales
    where organization_id = v_org.id
      and status = 'confirmed'
      and sale_date >= (current_date - interval '7 days');

    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_org.id and om.role = 'owner' and om.is_active = true
    limit 1;

    if v_owner_email is not null and v_invoice_count > 0 then
      insert into public.notification_outbox (
        organization_id, notification_type, recipient_email, subject, payload
      )
      values (
        v_org.id,
        'weekly_summary',
        v_owner_email,
        'ShopFlow: Weekly Performance Summary - ' || v_org.name,
        jsonb_build_object(
          'invoices_count', v_invoice_count,
          'weekly_revenue', v_weekly_sales,
          'weekly_gross_profit', v_weekly_profit,
          'start_date', current_date - interval '7 days',
          'end_date', current_date
        )
      );
      v_queued := v_queued + 1;
    end if;
  end loop;

  return jsonb_build_object('queued_weekly_summaries', v_queued);
end;
$$;

-- ------------------------------------------------------------------------------
-- MASTER AUTOMATION RUNNER: Executes all cron checks in one atomic invocation
-- ------------------------------------------------------------------------------
create or replace function public.cron_run_all_automations()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expired jsonb;
  v_daily jsonb;
  v_low_stock jsonb;
  v_renewals jsonb;
  v_weekly jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform super-admin privileges required to trigger automation runner';
  end if;

  v_expired := public.cron_check_expired_subscriptions();
  v_daily := public.cron_queue_daily_sales_summaries();
  v_low_stock := public.cron_queue_low_stock_alerts();
  v_renewals := public.cron_queue_subscription_renewal_reminders();
  v_weekly := public.cron_queue_weekly_business_summary();

  return jsonb_build_object(
    'executed_at', now(),
    'subscriptions_checked', v_expired,
    'daily_summaries', v_daily,
    'low_stock_alerts', v_low_stock,
    'renewal_reminders', v_renewals,
    'weekly_summaries', v_weekly
  );
end;
$$;

-- Reload schema cache
notify pgrst, 'reload schema';
