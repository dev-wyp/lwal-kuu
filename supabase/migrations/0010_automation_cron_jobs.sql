-- ==============================================================================
-- Migration: 0010_automation_cron_jobs.sql
-- Description: Notification outbox, subscription expiration cron, and daily summaries.
-- ==============================================================================

-- 1. Notification Outbox Table (Outbox Pattern for Reliable Async Dispatch)
create table if not exists public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete cascade,
  notification_type text not null, -- 'trial_expiring', 'subscription_expired', 'daily_summary', 'low_stock'
  recipient_email text not null,
  subject text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed')),
  retry_count integer not null default 0,
  last_error text,
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notification_outbox_pending
  on public.notification_outbox (status, scheduled_at)
  where status = 'pending';

-- Enable RLS
alter table public.notification_outbox enable row level security;
create policy "Platform admin can manage outbox"
  on public.notification_outbox for all
  using (public.is_platform_admin());

-- 2. Stored Procedure: Check and Expire Subscriptions (Idempotent Daily Job)
create or replace function public.cron_check_expired_subscriptions()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_expired_count integer := 0;
  v_rec record;
begin
  -- Find trialing subscriptions whose trial has ended
  for v_rec in
    select s.id, s.organization_id, o.name as org_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    where s.status = 'trialing'
      and s.trial_ends_at < now()
  loop
    update public.subscriptions
    set status = 'expired', updated_at = now()
    where id = v_rec.id;

    insert into public.subscription_events (
      subscription_id, organization_id, event_type, admin_notes
    )
    values (
      v_rec.id, v_rec.organization_id, 'expired', '14-day free trial expired automatically by cron'
    );

    v_expired_count := v_expired_count + 1;
  end loop;

  -- Find active subscriptions whose period has ended without renewal
  for v_rec in
    select s.id, s.organization_id, o.name as org_name
    from public.subscriptions s
    join public.organizations o on o.id = s.organization_id
    where s.status = 'active'
      and s.current_period_end < now()
  loop
    update public.subscriptions
    set status = 'past_due', updated_at = now()
    where id = v_rec.id;

    v_expired_count := v_expired_count + 1;
  end loop;

  return jsonb_build_object(
    'success', true,
    'expired_or_past_due_count', v_expired_count,
    'executed_at', now()
  );
end;
$$;

-- 3. Stored Procedure: Queue Daily Sales Outbox Notification
create or replace function public.cron_queue_daily_sales_summaries()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_org record;
  v_summary record;
  v_queued_count integer := 0;
  v_owner_email text;
begin
  for v_org in select id, name from public.organizations where is_active = true loop
    -- Get today's sales
    select
      coalesce(count(id), 0) as total_sales,
      coalesce(sum(total_amount), 0.00) as revenue,
      coalesce(sum(total_amount - total_cost), 0.00) as profit
    into v_summary
    from public.sales
    where organization_id = v_org.id
      and status = 'confirmed'
      and sale_date = current_date;

    -- Find organization owner email
    select u.email into v_owner_email
    from public.organization_members om
    join auth.users u on u.id = om.user_id
    where om.organization_id = v_org.id
      and om.role = 'owner'
      and om.is_active = true
    limit 1;

    if v_owner_email is not null and v_summary.total_sales > 0 then
      insert into public.notification_outbox (
        organization_id, notification_type, recipient_email, subject, payload
      )
      values (
        v_org.id,
        'daily_summary',
        v_owner_email,
        'ShopFlow: Daily Sales Report - ' || v_org.name,
        jsonb_build_object(
          'invoices_count', v_summary.total_sales,
          'revenue', v_summary.revenue,
          'profit', v_summary.profit,
          'date', current_date
        )
      );
      v_queued_count := v_queued_count + 1;
    end if;
  end loop;

  return jsonb_build_object('queued_summaries', v_queued_count);
end;
$$;

