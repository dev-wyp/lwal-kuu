-- Keep outbox generation idempotent when cron jobs are retried or run manually.
-- Scheduled SECURITY DEFINER jobs run without auth.uid(); allow those trusted
-- database calls to evaluate plan assignments while still requiring membership
-- for authenticated API users.
create or replace function public.organization_has_plan_feature(p_org_id uuid, p_feature_key text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  decision jsonb;
  subscription_status text;
  resolved_plan_id text;
  resolved_feature_id uuid;
  override_enabled boolean;
  plan_enabled boolean;
begin
  if auth.uid() is null then
    select * into subscription_status, resolved_plan_id from public._resolve_subscription_status(p_org_id);
    select id into resolved_feature_id from public.features where feature_key=p_feature_key and is_active;
    if resolved_feature_id is null then return false; end if;
    select is_enabled into override_enabled from public.organization_feature_overrides
      where organization_id=p_org_id and feature_id=resolved_feature_id and starts_at<=now()
        and (expires_at is null or expires_at>now()) order by created_at desc limit 1;
    if found and override_enabled is not null then return override_enabled; end if;
    if subscription_status not in ('active','trialing') then return false; end if;
    select is_enabled into plan_enabled from public.plan_features where plan_id=resolved_plan_id and feature_id=resolved_feature_id;
    return coalesce(plan_enabled,false);
  end if;
  if public.is_platform_admin() then return true; end if;
  if not public.has_org_membership(p_org_id) then return false; end if;
  decision := public.check_organization_feature(p_org_id, p_feature_key);
  return coalesce((decision->>'is_allowed')::boolean, false);
end;
$$;
revoke all on function public.organization_has_plan_feature(uuid, text) from public, anon;
grant execute on function public.organization_has_plan_feature(uuid, text) to authenticated, service_role;

create or replace function public.enforce_notification_plan_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  feature_key text;
  duplicate_window interval;
begin
  feature_key := case new.notification_type
    when 'low_stock' then 'low_stock_alerts'
    when 'daily_summary' then 'automated_reports'
    when 'weekly_summary' then 'automated_reports'
    when 'debt_reminder' then 'debt_reminders'
    else null
  end;
  if feature_key is null or new.organization_id is null then return new; end if;
  if not public.organization_has_plan_feature(new.organization_id, feature_key) then return null; end if;
  duplicate_window := case new.notification_type
    when 'low_stock' then interval '1 day'
    when 'daily_summary' then interval '1 day'
    when 'weekly_summary' then interval '7 days'
    else null
  end;
  if duplicate_window is not null and exists (
    select 1 from public.notification_outbox n
    where n.organization_id = new.organization_id
      and n.notification_type = new.notification_type
      and n.created_at >= now() - duplicate_window
      and n.status in ('pending','processing','sent')
  ) then return null; end if;
  return new;
end;
$$;

-- Allow the trusted database scheduler to run debt reminder generation. Authenticated
-- callers still must be platform administrators; scheduled SQL has no user identity.
create or replace function public.cron_queue_debt_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  debt_record record;
  queued_count integer := 0;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Platform administrator privileges required';
  end if;
  for debt_record in
    select s.organization_id, s.customer_id, c.email, c.name,
           count(*)::integer as overdue_invoice_count,
           sum(greatest(s.total_amount - s.paid_amount, 0))::numeric as overdue_amount
    from public.sales s
    join public.customers c on c.id = s.customer_id and c.organization_id = s.organization_id
    where s.status = 'confirmed' and s.due_date < current_date
      and s.payment_status in ('unpaid','partial') and c.is_active
      and nullif(btrim(c.email), '') is not null
      and public.organization_has_plan_feature(s.organization_id, 'debt_reminders')
    group by s.organization_id, s.customer_id, c.email, c.name
  loop
    if not exists (
      select 1 from public.notification_outbox n
      where n.organization_id = debt_record.organization_id
        and n.notification_type = 'debt_reminder'
        and n.payload->>'customer_id' = debt_record.customer_id::text
        and n.created_at > now() - interval '7 days'
    ) then
      insert into public.notification_outbox(organization_id, notification_type, recipient_email, subject, payload)
      values (
        debt_record.organization_id, 'debt_reminder', debt_record.email,
        'Lwal Kuu: Outstanding balance reminder',
        jsonb_build_object('customer_id', debt_record.customer_id, 'customer_name', debt_record.name,
          'overdue_invoice_count', debt_record.overdue_invoice_count, 'overdue_amount', debt_record.overdue_amount)
      );
      queued_count := queued_count + 1;
    end if;
  end loop;
  return jsonb_build_object('queued_debt_reminders', queued_count);
end;
$$;
revoke all on function public.cron_queue_debt_reminders() from public, anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated, service_role;

-- Schedule plan-gated report, stock alert, and debt reminder generation when pg_cron is available.
do $outer$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-daily-sales-reports') then perform cron.unschedule('lwal-kuu-daily-sales-reports'); end if;
    perform cron.schedule('lwal-kuu-daily-sales-reports', '5 0 * * *', 'select public.cron_queue_daily_sales_summaries()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-low-stock-alerts') then perform cron.unschedule('lwal-kuu-low-stock-alerts'); end if;
    perform cron.schedule('lwal-kuu-low-stock-alerts', '15 0 * * *', 'select public.cron_queue_low_stock_alerts()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-weekly-reports') then perform cron.unschedule('lwal-kuu-weekly-reports'); end if;
    perform cron.schedule('lwal-kuu-weekly-reports', '30 0 * * 1', 'select public.cron_queue_weekly_business_summary()');
    if exists (select 1 from cron.job where jobname = 'lwal-kuu-debt-reminders') then perform cron.unschedule('lwal-kuu-debt-reminders'); end if;
    perform cron.schedule('lwal-kuu-debt-reminders', '45 0 * * *', 'select public.cron_queue_debt_reminders()');
  end if;
exception when others then
  raise notice 'Could not schedule Lwal Kuu automation jobs: %', sqlerrm;
end $outer$;

alter table public.support_tickets add column if not exists response text;
alter table public.support_tickets add column if not exists responded_at timestamptz;
