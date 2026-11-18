-- Prevent shared automation jobs from queuing tenant reports/alerts for plans
-- that do not include those features.
create or replace function public.enforce_notification_plan_entitlement()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  feature_key text;
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
  return new;
end;
$$;

drop trigger if exists trg_notification_plan_entitlement on public.notification_outbox;
create trigger trg_notification_plan_entitlement
  before insert on public.notification_outbox
  for each row execute function public.enforce_notification_plan_entitlement();

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
    where s.status = 'confirmed'
      and s.due_date < current_date
      and s.payment_status in ('unpaid','partial')
      and c.is_active
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
      insert into public.notification_outbox(
        organization_id, notification_type, recipient_email, subject, payload
      ) values (
        debt_record.organization_id,
        'debt_reminder',
        debt_record.email,
        'Lwal Kuu: Outstanding balance reminder',
        jsonb_build_object(
          'customer_id', debt_record.customer_id,
          'customer_name', debt_record.name,
          'overdue_invoice_count', debt_record.overdue_invoice_count,
          'overdue_amount', debt_record.overdue_amount
        )
      );
      queued_count := queued_count + 1;
    end if;
  end loop;
  return jsonb_build_object('queued_debt_reminders', queued_count);
end;
$$;

revoke all on function public.cron_queue_debt_reminders() from public, anon;
grant execute on function public.cron_queue_debt_reminders() to authenticated;
