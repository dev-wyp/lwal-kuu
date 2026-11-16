-- ==============================================================================
-- Migration: 0023_marketing_jobs.sql
-- Description: Idempotent cron entrypoints for marketing automation.
-- ==============================================================================

create or replace function public.cron_detect_expired_social_connections()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
begin
  update public.social_accounts
     set connection_status = 'expired',
         last_error = 'Access token expired',
         updated_at = now()
   where connection_status = 'connected'
     and token_expires_at is not null
     and token_expires_at < now();

  get diagnostics v_count = row_count;

  insert into public.marketing_notifications (
    workspace_id, organization_id, notification_type, title, body, entity_type, entity_id
  )
  select sa.workspace_id, sa.organization_id, 'expired_connection',
         'Social connection expired',
         coalesce(sa.display_name, sa.provider) || ' needs to be reconnected.',
         'social_accounts', sa.id
  from public.social_accounts sa
  where sa.connection_status = 'expired'
    and sa.updated_at > now() - interval '2 minutes'
    and not exists (
      select 1 from public.marketing_notifications n
      where n.entity_id = sa.id
        and n.notification_type = 'expired_connection'
        and n.created_at > now() - interval '1 day'
    );

  return jsonb_build_object('expired_connections', v_count);
end;
$$;

create or replace function public.cron_notify_upcoming_scheduled_posts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count integer := 0;
  v_rec record;
begin
  for v_rec in
    select c.*
    from public.marketing_contents c
    where c.status = 'scheduled'
      and c.scheduled_for between now() and now() + interval '2 hours'
  loop
    if not exists (
      select 1 from public.marketing_notifications n
      where n.entity_id = v_rec.id
        and n.notification_type = 'upcoming_scheduled'
        and n.created_at > now() - interval '12 hours'
    ) then
      perform public.mkt_notify(
        v_rec.organization_id, v_rec.workspace_id,
        'upcoming_scheduled',
        'Scheduled post is due soon',
        v_rec.title || ' publishes within 2 hours.',
        'marketing_contents',
        v_rec.id
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return jsonb_build_object('notified', v_count);
end;
$$;

-- Placeholder cron: actual AI generation and analytics sync run in Edge Functions.
-- These SQL jobs stay idempotent and safe if pg_cron is unavailable.
do $outer$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'shopflow-marketing-expired-social') then
      perform cron.unschedule('shopflow-marketing-expired-social');
    end if;
    perform cron.schedule(
      'shopflow-marketing-expired-social',
      '15 * * * *',
      'select public.cron_detect_expired_social_connections()'
    );

    if exists (select 1 from cron.job where jobname = 'shopflow-marketing-upcoming-posts') then
      perform cron.unschedule('shopflow-marketing-upcoming-posts');
    end if;
    perform cron.schedule(
      'shopflow-marketing-upcoming-posts',
      '*/30 * * * *',
      'select public.cron_notify_upcoming_scheduled_posts()'
    );
  end if;
exception when others then
  null;
end $outer$;
