-- ==============================================================================
-- Migration: 0008_subscriptions_and_limits.sql
-- Description: Plans, subscriptions, limits, payment verification, and RLS.
-- ==============================================================================

-- Drop legacy non-multitenant subscriptions table if it pre-exists
do $$
begin
  if exists (
    select 1 from information_schema.tables 
    where table_schema = 'public' and table_name = 'subscriptions'
  ) and not exists (
    select 1 from information_schema.columns 
    where table_schema = 'public' and table_name = 'subscriptions' and column_name = 'organization_id'
  ) then
    drop table public.subscriptions cascade;
  end if;
end $$;

-- 1. SaaS Plans Master
create table if not exists public.plans (
  id text primary key,
  name text not null,
  price numeric(12, 2) not null default 15000.00,
  billing_interval text not null default 'month',
  monthly_price_mmk numeric(12, 2) not null,
  yearly_price_mmk numeric(12, 2) not null,
  trial_days integer not null default 14,
  max_users integer not null default 2,
  max_products integer not null default 100,
  max_monthly_sales integer not null default 200,
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true
);

-- Seed Initial Suggested Plans (Section 11)
insert into public.plans (id, name, price, billing_interval, monthly_price_mmk, yearly_price_mmk, trial_days, max_users, max_products, max_monthly_sales, features)
values
  ('starter', 'Starter Plan', 15000.00, 'month', 15000.00, 150000.00, 14, 2, 200, 300, '{"multi_user": true, "inventory": true, "basic_reports": true}'::jsonb),
  ('business', 'Business Plan', 30000.00, 'month', 30000.00, 300000.00, 14, 5, 1000, 1500, '{"multi_user": true, "inventory": true, "gross_profit": true, "customer_ledgers": true}'::jsonb),
  ('pro', 'Pro Plan', 60000.00, 'month', 60000.00, 600000.00, 14, 15, 5000, 10000, '{"multi_user": true, "inventory": true, "unlimited_reports": true, "priority_support": true, "api_access": true}'::jsonb)
on conflict (id) do update set
  price = excluded.price,
  billing_interval = excluded.billing_interval,
  monthly_price_mmk = excluded.monthly_price_mmk,
  yearly_price_mmk = excluded.yearly_price_mmk,
  max_users = excluded.max_users,
  max_products = excluded.max_products,
  max_monthly_sales = excluded.max_monthly_sales;

-- 2. Organization Subscriptions
create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations(id) on delete cascade,
  plan_id text not null references public.plans(id) on delete restrict,
  status text not null check (status in ('trialing', 'active', 'past_due', 'expired', 'canceled')),
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly', 'yearly')),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null default (now() + interval '14 days'),
  trial_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.sync_subscription_dates()
returns trigger
language plpgsql
as $$
begin
  if new.starts_at is null then
    new.starts_at := new.current_period_start;
  else
    new.current_period_start := new.starts_at;
  end if;

  if new.expires_at is null then
    new.expires_at := new.current_period_end;
  else
    new.current_period_end := new.expires_at;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_subscription_dates on public.subscriptions;
create trigger trg_sync_subscription_dates
  before insert or update on public.subscriptions
  for each row execute function public.sync_subscription_dates();

create index if not exists idx_subscriptions_status on public.subscriptions (status);

-- 3. Subscription Events
create table if not exists public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_type text not null,
  amount numeric(12, 2),
  payment_method text,
  payment_reference text,
  admin_notes text,
  created_at timestamptz not null default now()
);

-- 4. Usage Limits
create table if not exists public.usage_limits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  metric text not null check (metric in ('user_count', 'product_count', 'monthly_sales_count')),
  period_key text not null,
  current_value integer not null default 0 check (current_value >= 0),
  limit_value integer not null,
  updated_at timestamptz not null default now(),
  unique (organization_id, metric, period_key)
);

-- 5. Atomic RPC: Initialize Trial for New Organization
create or replace function public.initialize_organization_trial(
  p_org_id uuid,
  p_plan_id text default 'starter'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_plan public.plans%rowtype;
  v_sub_id uuid;
  v_period_end timestamptz;
begin
  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    select * into v_plan from public.plans where id = 'starter';
  end if;

  v_period_end := now() + (v_plan.trial_days || ' days')::interval;

  insert into public.subscriptions (
    organization_id, plan_id, status, billing_cycle,
    current_period_start, current_period_end, trial_ends_at
  )
  values (
    p_org_id, v_plan.id, 'trialing', 'monthly',
    now(), v_period_end, v_period_end
  )
  on conflict (organization_id) do update
  set updated_at = now()
  returning id into v_sub_id;

  -- Initialize Usage Limits
  insert into public.usage_limits (organization_id, metric, period_key, current_value, limit_value)
  values
    (p_org_id, 'product_count', 'lifetime', 0, v_plan.max_products),
    (p_org_id, 'user_count', 'lifetime', 1, v_plan.max_users),
    (p_org_id, 'monthly_sales_count', to_char(now(), 'YYYY-MM'), 0, v_plan.max_monthly_sales)
  on conflict (organization_id, metric, period_key) do nothing;

  -- Record event
  insert into public.subscription_events (
    subscription_id, organization_id, event_type, admin_notes
  )
  values (
    v_sub_id, p_org_id, 'trial_started', '14-day free trial initialized'
  );

  return v_sub_id;
end;
$$;

-- 6. Atomic RPC: Submit Manual Subscription Payment
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
  v_user_id uuid := auth.uid();
  v_sub public.subscriptions%rowtype;
  v_plan public.plans%rowtype;
  v_amount numeric(12, 2);
begin
  if not public.is_org_admin_or_owner(p_org_id) then
    raise exception 'Unauthorized';
  end if;

  select * into v_sub from public.subscriptions where organization_id = p_org_id;
  if not found then
    raise exception 'Subscription record not found';
  end if;

  select * into v_plan from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Invalid plan';
  end if;

  v_amount := case when p_billing_cycle = 'yearly' then v_plan.yearly_price_mmk else v_plan.monthly_price_mmk end;

  insert into public.subscription_events (
    subscription_id, organization_id, event_type, amount,
    payment_method, payment_reference, admin_notes
  )
  values (
    v_sub.id, p_org_id, 'payment_submitted', v_amount,
    p_payment_method, p_reference_number, p_notes
  );

  return jsonb_build_object(
    'success', true,
    'message', 'Payment submitted for platform admin verification'
  );
end;
$$;

-- 7. Platform Admin RPC: Verify and Activate Subscription
create or replace function public.verify_subscription_payment(
  p_sub_id uuid,
  p_event_id uuid,
  p_approve boolean,
  p_admin_notes text default null
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
  v_duration interval;
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

  if p_approve then
    select * into v_plan from public.plans where id = v_sub.plan_id;
    v_duration := case when v_sub.billing_cycle = 'yearly' then interval '1 year' else interval '1 month' end;

    update public.subscriptions
    set status = 'active',
        current_period_start = now(),
        current_period_end = now() + v_duration,
        updated_at = now()
    where id = p_sub_id;

    insert into public.subscription_events (
      subscription_id, organization_id, event_type, amount, admin_notes
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_approved', v_event.amount, p_admin_notes
    );

    return jsonb_build_object('success', true, 'status', 'active');
  else
    insert into public.subscription_events (
      subscription_id, organization_id, event_type, admin_notes
    )
    values (
      p_sub_id, v_sub.organization_id, 'payment_rejected', p_admin_notes
    );

    return jsonb_build_object('success', true, 'status', 'rejected');
  end if;
end;
$$;

-- 8. Enable RLS
alter table public.plans enable row level security;
alter table public.subscriptions enable row level security;
alter table public.subscription_events enable row level security;
alter table public.usage_limits enable row level security;

-- Plans are public readable
create policy "Plans readable by all"
  on public.plans for select
  using (true);

-- Subscriptions RLS
create policy "Members view their subscription"
  on public.subscriptions for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Platform admin manage subscriptions"
  on public.subscriptions for all
  using (public.is_platform_admin());

-- Subscription Events RLS
create policy "Members view subscription events"
  on public.subscription_events for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "Platform admin manage subscription events"
  on public.subscription_events for all
  using (public.is_platform_admin());

-- Usage Limits RLS
create policy "Members view usage limits"
  on public.usage_limits for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

