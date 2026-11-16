-- ==============================================================================
-- Migration: 0022_marketing_rpcs.sql
-- Description: Server-side approval, scheduling, publishing, budget, and lead RPCs.
-- ==============================================================================

create or replace function public.mkt_notify(
  p_org_id uuid,
  p_workspace_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_entity_type text default null,
  p_entity_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.marketing_notifications (
    workspace_id, organization_id, notification_type, title, body, entity_type, entity_id
  )
  values (p_workspace_id, p_org_id, p_type, p_title, p_body, p_entity_type, p_entity_id);
end;
$$;

create or replace function public.submit_marketing_content_for_review(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.has_org_membership(v_row.organization_id) then
    raise exception 'Access denied';
  end if;
  if v_row.status not in ('draft', 'rejected') then
    raise exception 'Only draft or rejected content can be submitted for review';
  end if;
  if length(btrim(v_row.caption)) < 8 then
    raise exception 'Caption is required before review';
  end if;

  update public.marketing_contents
    set status = 'pending_review', rejection_reason = null, updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'submitted', auth.uid(), 'draft', 'pending_review'
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'pending_approval',
    'Content awaiting approval',
    v_row.title || ' is ready for review.',
    'marketing_contents',
    v_row.id
  );

  return v_row;
end;
$$;

create or replace function public.approve_marketing_content(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may approve content';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Content must be pending review to approve';
  end if;

  update public.marketing_contents
    set status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        rejection_reason = null,
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'approved', auth.uid(), 'pending_review', 'approved'
  );

  return v_row;
end;
$$;

create or replace function public.reject_marketing_content(p_content_id uuid, p_reason text)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'Rejection reason is required';
  end if;

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may reject content';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Content must be pending review to reject';
  end if;

  update public.marketing_contents
    set status = 'rejected',
        rejection_reason = btrim(p_reason),
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status, reason
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'rejected', auth.uid(), 'pending_review', 'rejected', btrim(p_reason)
  );

  return v_row;
end;
$$;

create or replace function public.schedule_marketing_content(p_content_id uuid, p_scheduled_for timestamptz)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_scheduled_for is null then
    raise exception 'Scheduled time is required';
  end if;

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may schedule content';
  end if;
  if v_row.status not in ('approved', 'scheduled') then
    raise exception 'Only approved content can be scheduled';
  end if;

  update public.marketing_contents
    set status = 'scheduled',
        scheduled_for = p_scheduled_for,
        updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'scheduled', auth.uid(), 'approved', 'scheduled'
  );

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  )
  values (
    v_row.workspace_id,
    v_row.organization_id,
    v_row.id,
    v_row.id::text || ':' || p_scheduled_for::text,
    'queued',
    p_scheduled_for
  )
  on conflict (idempotency_key) do update
    set next_attempt_at = excluded.next_attempt_at,
        status = case
          when public.publishing_jobs.status in ('succeeded', 'processing') then public.publishing_jobs.status
          else 'queued'
        end,
        updated_at = now();

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'upcoming_scheduled',
    'Post scheduled',
    v_row.title || ' is scheduled for publishing.',
    'marketing_contents',
    v_row.id
  );

  return v_row;
end;
$$;

-- Enqueue immediate publish. Approval is re-checked server-side.
create or replace function public.enqueue_marketing_publish(p_content_id uuid)
returns public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
  v_job public.publishing_jobs;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then
    raise exception 'Content not found';
  end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may publish content';
  end if;
  if v_row.status not in ('approved', 'scheduled') then
    raise exception 'Unapproved content cannot be published';
  end if;
  if exists (
    select 1 from public.publishing_jobs
    where content_id = p_content_id and status in ('processing', 'succeeded')
  ) then
    raise exception 'A publish job is already in progress or completed for this content';
  end if;

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  )
  values (
    v_row.workspace_id,
    v_row.organization_id,
    v_row.id,
    v_row.id::text || ':immediate:' || extract(epoch from now())::bigint::text,
    'queued',
    now()
  )
  returning * into v_job;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (v_row.workspace_id, v_row.organization_id, v_job.id, v_row.id, 'enqueued', jsonb_build_object('by', auth.uid()));

  return v_job;
end;
$$;

create or replace function public.claim_due_publishing_jobs(p_limit integer default 10, p_worker text default 'edge')
returns setof public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  return query
  with due as (
    select j.id
    from public.publishing_jobs j
    join public.marketing_contents c on c.id = j.content_id
    where j.status in ('queued', 'failed_retryable')
      and j.next_attempt_at <= now()
      and j.attempt_count < j.max_attempts
      and (j.locked_at is null or j.locked_at < now() - interval '10 minutes')
      and c.status in ('approved', 'scheduled', 'failed')
    order by j.next_attempt_at
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update of j skip locked
  )
  update public.publishing_jobs j
     set status = 'processing',
         locked_at = now(),
         locked_by = p_worker,
         attempt_count = j.attempt_count + 1,
         updated_at = now()
    from due
   where j.id = due.id
   returning j.*;
end;
$$;

create or replace function public.complete_publishing_job(
  p_job_id uuid,
  p_success boolean,
  p_provider_post_id text default null,
  p_error text default null,
  p_retryable boolean default true
)
returns public.publishing_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_job public.publishing_jobs;
  v_status text;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_job from public.publishing_jobs where id = p_job_id for update;
  if not found then
    raise exception 'Job not found';
  end if;

  if p_success then
    update public.publishing_jobs
      set status = 'succeeded',
          provider_post_id = p_provider_post_id,
          last_error = null,
          locked_at = null,
          updated_at = now()
      where id = p_job_id
      returning * into v_job;

    update public.marketing_contents
      set status = 'published',
          published_at = now(),
          provider_post_id = p_provider_post_id,
          last_publish_error = null,
          updated_at = now()
      where id = v_job.content_id;

    perform public.mkt_notify(
      v_job.organization_id, v_job.workspace_id,
      'publish_success',
      'Content published',
      'A scheduled post published successfully.',
      'marketing_contents',
      v_job.content_id
    );
  else
    v_status := case
      when not p_retryable or v_job.attempt_count >= v_job.max_attempts then 'failed_permanent'
      else 'failed_retryable'
    end;

    update public.publishing_jobs
      set status = v_status,
          last_error = p_error,
          locked_at = null,
          next_attempt_at = case when v_status = 'failed_retryable'
            then now() + (interval '5 minutes' * v_job.attempt_count)
            else v_job.next_attempt_at end,
          updated_at = now()
      where id = p_job_id
      returning * into v_job;

    update public.marketing_contents
      set status = 'failed',
          last_publish_error = p_error,
          updated_at = now()
      where id = v_job.content_id;

    perform public.mkt_notify(
      v_job.organization_id, v_job.workspace_id,
      'publish_failure',
      'Publishing failed',
      coalesce(p_error, 'The social platform rejected the post.'),
      'marketing_contents',
      v_job.content_id
    );
  end if;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (
    v_job.workspace_id, v_job.organization_id, v_job.id, v_job.content_id,
    case when p_success then 'succeeded' else 'failed' end,
    jsonb_build_object('error', p_error, 'retryable', p_retryable, 'provider_post_id', p_provider_post_id)
  );

  return v_job;
end;
$$;

create or replace function public.month_ad_spend(p_workspace_id uuid, p_month date default (timezone('Asia/Yangon', now()))::date)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(sum(amount_mmk), 0)
  from public.ad_budget_logs
  where workspace_id = p_workspace_id
    and entry_type = 'actual'
    and date_trunc('month', period_month) = date_trunc('month', p_month::timestamp);
$$;

create or replace function public.approve_ad_campaign(p_campaign_id uuid, p_approved_spend_mmk numeric)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception 'Ad campaign not found';
  end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may approve advertising spend';
  end if;
  if p_approved_spend_mmk is null or p_approved_spend_mmk <= 0 then
    raise exception 'Approved spend must be greater than zero';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);

  if v_spent + p_approved_spend_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Approved spend would exceed the monthly advertising budget of % MMK', v_ws.monthly_ad_budget_mmk;
  end if;

  if v_row.platform = 'facebook' and p_approved_spend_mmk > v_ws.facebook_budget_mmk then
    raise exception 'Approved spend exceeds the Facebook allocation of % MMK', v_ws.facebook_budget_mmk;
  end if;
  if v_row.platform = 'tiktok' and p_approved_spend_mmk > v_ws.tiktok_budget_mmk then
    raise exception 'Approved spend exceeds the TikTok allocation of % MMK', v_ws.tiktok_budget_mmk;
  end if;

  update public.ad_campaigns
    set status = 'approved',
        owner_approved = true,
        approved_spend_mmk = p_approved_spend_mmk,
        approved_by = auth.uid(),
        approved_at = now(),
        updated_at = now()
    where id = p_campaign_id
    returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform, amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform, p_approved_spend_mmk, 'approved',
    'Owner-approved advertising ceiling', auth.uid()
  );

  return v_row;
end;
$$;

create or replace function public.record_ad_spend(p_campaign_id uuid, p_amount_mmk numeric, p_notes text default null)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_spent numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception 'Ad campaign not found';
  end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may record advertising spend';
  end if;
  if not v_row.owner_approved or v_row.status not in ('approved', 'active') then
    raise exception 'Spend cannot be recorded until the owner approves this campaign';
  end if;
  if p_amount_mmk is null or p_amount_mmk <= 0 then
    raise exception 'Spend amount must be greater than zero';
  end if;
  if v_row.actual_spend_mmk + p_amount_mmk > v_row.approved_spend_mmk then
    raise exception 'Spend would exceed the owner-approved amount of % MMK', v_row.approved_spend_mmk;
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);
  if v_spent + p_amount_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Spend would exceed the monthly advertising budget';
  end if;

  update public.ad_campaigns
    set actual_spend_mmk = actual_spend_mmk + p_amount_mmk,
        status = 'active',
        updated_at = now()
    where id = p_campaign_id
    returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform, amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform, p_amount_mmk, 'actual', p_notes, auth.uid()
  );

  if public.month_ad_spend(v_row.workspace_id, v_month) >= v_ws.monthly_ad_budget_mmk * 0.8 then
    perform public.mkt_notify(
      v_row.organization_id, v_row.workspace_id,
      'budget_threshold',
      'Advertising budget threshold reached',
      'Monthly advertising spend is at or above 80% of the approved budget.',
      'ad_campaigns',
      v_row.id
    );
  end if;

  return v_row;
end;
$$;

create or replace function public.attribute_trial_signup(
  p_org_id uuid,
  p_user_id uuid,
  p_utm_source text default null,
  p_utm_medium text default null,
  p_utm_campaign text default null,
  p_utm_content text default null,
  p_email text default null,
  p_full_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ws_id uuid;
  v_lead_id uuid;
  v_content_id uuid;
  v_campaign_id uuid;
  v_confidence text := 'unknown';
  v_platform text := 'website';
begin
  if auth.uid() is distinct from p_user_id
     and not public.has_org_membership(p_org_id)
     and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;

  select id into v_ws_id from public.marketing_workspaces where organization_id = p_org_id;

  if p_utm_content is not null then
    select id, campaign_id into v_content_id, v_campaign_id
    from public.marketing_contents
    where id::text = p_utm_content
    limit 1;
  end if;

  if v_campaign_id is null and p_utm_campaign is not null then
    select id into v_campaign_id
    from public.content_campaigns
    where organization_id = p_org_id and name = p_utm_campaign
    limit 1;
  end if;

  if p_utm_source is not null then
    v_confidence := 'utm';
    if lower(p_utm_source) in ('facebook', 'tiktok') then
      v_platform := lower(p_utm_source);
    end if;
  end if;

  insert into public.marketing_leads (
    workspace_id, organization_id, full_name, email, source_platform,
    campaign_id, content_id, utm_source, utm_medium, utm_campaign, utm_content,
    status, trial_signup_at
  ) values (
    v_ws_id, p_org_id, p_full_name, p_email, v_platform,
    v_campaign_id, v_content_id, p_utm_source, p_utm_medium, p_utm_campaign, p_utm_content,
    'trial_registered', now()
  )
  returning id into v_lead_id;

  insert into public.trial_conversions (
    lead_id, organization_id, workspace_id, user_id, campaign_id, content_id, attribution_confidence
  ) values (
    v_lead_id, p_org_id, v_ws_id, p_user_id, v_campaign_id, v_content_id, v_confidence
  );

  return v_lead_id;
end;
$$;

grant execute on function public.ensure_marketing_workspace(uuid) to authenticated;
grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;
grant execute on function public.approve_marketing_content(uuid) to authenticated;
grant execute on function public.reject_marketing_content(uuid, text) to authenticated;
grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

revoke execute on function public.claim_due_publishing_jobs(integer, text) from public, anon, authenticated;
revoke execute on function public.complete_publishing_job(uuid, boolean, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.mkt_notify(uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.claim_due_publishing_jobs(integer, text) to service_role;
grant execute on function public.complete_publishing_job(uuid, boolean, text, text, boolean) to service_role;
