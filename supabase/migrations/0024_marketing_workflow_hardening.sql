-- Harden marketing workspace access and keep one active publishing job per post.
-- Safe for existing installations: duplicate queued jobs are cancelled, never deleted.

create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.role() = 'anon' then
    raise exception 'Authentication required';
  end if;

  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(p_org_id) then
    raise exception 'Access denied';
  end if;

  insert into public.marketing_workspaces (organization_id)
  values (p_org_id)
  on conflict (organization_id) do update set updated_at = public.marketing_workspaces.updated_at
  returning id into v_id;

  insert into public.marketing_settings (workspace_id, organization_id)
  values (v_id, p_org_id)
  on conflict (workspace_id) do nothing;

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  values
    (v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected', 'Connect via Meta OAuth. Publishing requires the relevant Meta permissions.'),
    (v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected', 'Connect via TikTok OAuth. Publishing requires Content Posting API access.')
  on conflict do nothing;

  return v_id;
end;
$$;

-- An authenticated caller may only initialize their own workspace. The org creation
-- trigger and trusted backend continue to call this function as its owner.
revoke execute on function public.ensure_marketing_workspace(uuid) from public, anon;
grant execute on function public.ensure_marketing_workspace(uuid) to authenticated, service_role;

-- Other security-definer RPCs rely on internal authorization checks. Remove the
-- default PUBLIC execute grant so anonymous callers cannot reach them at all.
revoke execute on function public.submit_marketing_content_for_review(uuid) from public, anon;
revoke execute on function public.approve_marketing_content(uuid) from public, anon;
revoke execute on function public.reject_marketing_content(uuid, text) from public, anon;
revoke execute on function public.schedule_marketing_content(uuid, timestamptz) from public, anon;
revoke execute on function public.enqueue_marketing_publish(uuid) from public, anon;
revoke execute on function public.approve_ad_campaign(uuid, numeric) from public, anon;
revoke execute on function public.record_ad_spend(uuid, numeric, text) from public, anon;
revoke execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) from public, anon;
revoke execute on function public.month_ad_spend(uuid, date) from public, anon;

grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;
grant execute on function public.approve_marketing_content(uuid) to authenticated;
grant execute on function public.reject_marketing_content(uuid, text) to authenticated;
grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;

-- Editing copy after approval would invalidate the owner's review. Edits while
-- draft, rejected, or pending review remain available and must be reviewed again.
create or replace function public.tg_marketing_content_status_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  rpc_flag text;
  content_changed boolean;
begin
  rpc_flag := current_setting('shopflow.marketing_rpc', true);
  if tg_op = 'INSERT' then
    if new.status <> 'draft' and coalesce(rpc_flag, '') is distinct from '1' then
      raise exception 'New marketing content must start as draft';
    end if;
    return new;
  end if;

  content_changed := row(
    new.title, new.platform, new.content_type, new.content_pillar,
    new.caption, new.hook, new.cta, new.hashtags, new.image_prompt,
    new.video_script, new.production_brief
  ) is distinct from row(
    old.title, old.platform, old.content_type, old.content_pillar,
    old.caption, old.hook, old.cta, old.hashtags, old.image_prompt,
    old.video_script, old.production_brief
  );

  if content_changed and old.status in ('approved', 'scheduled', 'publishing', 'published') then
    raise exception 'Approved content cannot be edited. Return it to review before changing copy.';
  end if;
  if content_changed and old.status = 'pending_review'
     and coalesce(rpc_flag, '') is distinct from '1' then
    raise exception 'Content in review can only be edited through the approval center';
  end if;

  if new.status is distinct from old.status
     and coalesce(rpc_flag, '') is distinct from '1' then
    if old.status in ('publishing', 'published') then
      raise exception 'Published content cannot be mutated from the client';
    end if;
    if new.status not in ('draft', 'pending_review', 'rejected', 'archived') then
      raise exception 'Status % must be applied through a server-side marketing RPC', new.status;
    end if;
    if new.status = 'pending_review' and old.status not in ('draft', 'rejected') then
      raise exception 'Only draft or rejected content can be submitted for review';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_marketing_contents_status_guard on public.marketing_contents;
create trigger trg_marketing_contents_status_guard
  before insert or update on public.marketing_contents
  for each row execute function public.tg_marketing_content_status_guard();

create or replace function public.edit_marketing_review_content(
  p_content_id uuid,
  p_caption text,
  p_hashtags text[]
)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  if p_caption is null or length(btrim(p_caption)) < 8 then
    raise exception 'Caption must be at least 8 characters';
  end if;
  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then raise exception 'Content not found'; end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may edit copy in the approval center';
  end if;
  if v_row.status <> 'pending_review' then
    raise exception 'Only content pending review can be edited here';
  end if;

  perform set_config('shopflow.marketing_rpc', '1', true);
  update public.marketing_contents
  set caption = p_caption, hashtags = coalesce(p_hashtags, '{}'), updated_at = now()
  where id = p_content_id returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'edited', auth.uid(), 'pending_review', 'pending_review'
  );
  return v_row;
end;
$$;

revoke execute on function public.edit_marketing_review_content(uuid, text, text[]) from public, anon;
grant execute on function public.edit_marketing_review_content(uuid, text, text[]) to authenticated;

-- Serialize spend approvals and actual entries on the workspace row so
-- concurrent campaigns cannot collectively pass the monthly ceiling.
create or replace function public.approve_ad_campaign(p_campaign_id uuid, p_approved_spend_mmk numeric)
returns public.ad_campaigns
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.ad_campaigns;
  v_ws public.marketing_workspaces;
  v_committed numeric;
  v_platform_committed numeric;
  v_platform_limit numeric;
  v_month date := date_trunc('month', timezone('Asia/Yangon', now()))::date;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.ad_campaigns where id = p_campaign_id for update;
  if not found then raise exception 'Ad campaign not found'; end if;
  if not public.is_org_admin_or_owner(v_row.organization_id) then
    raise exception 'Only owners or admins may approve advertising spend';
  end if;
  if p_approved_spend_mmk is null or p_approved_spend_mmk <= 0 then
    raise exception 'Approved spend must be greater than zero';
  end if;
  if v_row.owner_approved then
    raise exception 'This campaign already has an approved spend limit';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and owner_approved = true
    and status in ('approved', 'active');
  v_committed := v_committed + public.month_ad_spend(v_row.workspace_id, v_month);

  select coalesce(sum(greatest(approved_spend_mmk - actual_spend_mmk, 0)), 0)
    into v_platform_committed
  from public.ad_campaigns
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and owner_approved = true and status in ('approved', 'active');
  select v_platform_committed + coalesce(sum(amount_mmk), 0)
    into v_platform_committed
  from public.ad_budget_logs
  where workspace_id = v_row.workspace_id and platform = v_row.platform
    and entry_type = 'actual'
    and date_trunc('month', period_month) = date_trunc('month', v_month::timestamp);

  if v_committed + p_approved_spend_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Approved spend would exceed the remaining monthly budget';
  end if;
  v_platform_limit := case when v_row.platform = 'facebook'
    then v_ws.facebook_budget_mmk else v_ws.tiktok_budget_mmk end;
  if v_platform_committed + p_approved_spend_mmk > v_platform_limit then
    raise exception 'Approved spend would exceed the remaining platform allocation';
  end if;

  update public.ad_campaigns
  set status = 'approved', owner_approved = true,
      approved_spend_mmk = p_approved_spend_mmk,
      approved_by = auth.uid(), approved_at = now(), updated_at = now()
  where id = p_campaign_id returning * into v_row;

  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_approved_spend_mmk, 'approved', 'Owner-approved advertising ceiling', auth.uid()
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
  if not found then raise exception 'Ad campaign not found'; end if;
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
    raise exception 'Spend would exceed the owner-approved campaign amount';
  end if;

  select * into v_ws from public.marketing_workspaces where id = v_row.workspace_id for update;
  v_spent := public.month_ad_spend(v_row.workspace_id, v_month);
  if v_spent + p_amount_mmk > v_ws.monthly_ad_budget_mmk then
    raise exception 'Spend would exceed the monthly advertising budget';
  end if;

  update public.ad_campaigns
  set actual_spend_mmk = actual_spend_mmk + p_amount_mmk, status = 'active', updated_at = now()
  where id = p_campaign_id returning * into v_row;
  insert into public.ad_budget_logs (
    workspace_id, organization_id, ad_campaign_id, period_month, platform,
    amount_mmk, entry_type, notes, created_by
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, v_month, v_row.platform,
    p_amount_mmk, 'actual', p_notes, auth.uid()
  );

  if public.month_ad_spend(v_row.workspace_id, v_month) >= v_ws.monthly_ad_budget_mmk * 0.8 then
    perform public.mkt_notify(
      v_row.organization_id, v_row.workspace_id, 'budget_threshold',
      'Advertising budget threshold reached',
      'Monthly advertising spend is at or above 80% of the approved budget.',
      'ad_campaigns', v_row.id
    );
  end if;
  return v_row;
end;
$$;

create or replace function public.month_ad_spend(
  p_workspace_id uuid,
  p_month date default (timezone('Asia/Yangon', now()))::date
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_org_id uuid;
begin
  select organization_id into v_org_id from public.marketing_workspaces where id = p_workspace_id;
  if v_org_id is null then raise exception 'Marketing workspace not found'; end if;
  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(v_org_id) then
    raise exception 'Access denied';
  end if;
  return (
    select coalesce(sum(amount_mmk), 0)
    from public.ad_budget_logs
    where workspace_id = p_workspace_id and entry_type = 'actual'
      and date_trunc('month', period_month) = date_trunc('month', p_month::timestamp)
  );
end;
$$;

revoke execute on function public.approve_ad_campaign(uuid, numeric) from public, anon;
revoke execute on function public.record_ad_spend(uuid, numeric, text) from public, anon;
revoke execute on function public.month_ad_spend(uuid, date) from public, anon;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

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
  if auth.role() = 'anon' or auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if auth.uid() is distinct from p_user_id
     and not public.is_org_admin_or_owner(p_org_id)
     and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;
  if not public.has_org_membership(p_org_id) and not public.is_platform_admin() then
    raise exception 'Access denied';
  end if;

  select id into v_ws_id from public.marketing_workspaces where organization_id = p_org_id;
  if v_ws_id is null then raise exception 'Marketing workspace not found'; end if;

  if p_utm_content is not null then
    select id, campaign_id into v_content_id, v_campaign_id
    from public.marketing_contents
    where id::text = p_utm_content and organization_id = p_org_id
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
    v_ws_id, p_org_id, nullif(btrim(p_full_name), ''), nullif(btrim(p_email), ''), v_platform,
    v_campaign_id, v_content_id, p_utm_source, p_utm_medium, p_utm_campaign, p_utm_content,
    'trial_registered', now()
  ) returning id into v_lead_id;

  insert into public.trial_conversions (
    lead_id, organization_id, workspace_id, user_id, campaign_id, content_id, attribution_confidence
  ) values (
    v_lead_id, p_org_id, v_ws_id, p_user_id, v_campaign_id, v_content_id, v_confidence
  );
  return v_lead_id;
end;
$$;

revoke execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;

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
  if not found then raise exception 'Content not found'; end if;
  if not public.can_approve_marketing(v_row.organization_id) then
    raise exception 'Only owners or marketing managers may publish content';
  end if;
  if v_row.status not in ('approved', 'scheduled', 'failed') or v_row.approved_at is null then
    raise exception 'Content must be approved before publishing';
  end if;
  if exists (
    select 1 from public.publishing_jobs
    where content_id = p_content_id and status in ('queued', 'processing', 'succeeded', 'failed_retryable')
  ) then
    raise exception 'A publish job is already queued, in progress, or completed for this content';
  end if;

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id,
    v_row.id::text || ':immediate:' || gen_random_uuid()::text, 'queued', now()
  ) returning * into v_job;

  insert into public.publishing_logs (workspace_id, organization_id, job_id, content_id, event, detail)
  values (
    v_row.workspace_id, v_row.organization_id, v_job.id, v_row.id,
    'enqueued', jsonb_build_object('by', auth.uid(), 'retry', v_row.status = 'failed')
  );
  return v_job;
end;
$$;

revoke execute on function public.enqueue_marketing_publish(uuid) from public, anon;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;

-- Validate the workspace/organization pair and every marketing relationship.
-- Separate foreign keys alone would allow a member of one org to attach that
-- org's row to another org's workspace or content and confuse background jobs.
create or replace function public.tg_marketing_tenant_integrity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_workspace_id uuid := nullif(v_row ->> 'workspace_id', '')::uuid;
  v_org_id uuid := nullif(v_row ->> 'organization_id', '')::uuid;
  v_related_org uuid;
  v_related_workspace uuid;
  v_related_id uuid;
  v_target text;
  v_fk text;
begin
  if tg_op = 'UPDATE' and (
    nullif(to_jsonb(old) ->> 'workspace_id', '') is distinct from v_row ->> 'workspace_id'
    or nullif(to_jsonb(old) ->> 'organization_id', '') is distinct from v_row ->> 'organization_id'
  ) then
    raise exception 'Marketing records cannot be moved between workspaces';
  end if;

  if v_workspace_id is null or v_org_id is null then
    if tg_table_name <> 'marketing_leads' or (v_workspace_id is not null or v_org_id is not null) then
      raise exception 'Workspace and organization are required';
    end if;
  else
    select organization_id into v_related_org
    from public.marketing_workspaces where id = v_workspace_id;
    if v_related_org is distinct from v_org_id then
      raise exception 'Workspace does not belong to this organization';
    end if;
  end if;

  v_fk := case tg_table_name
    when 'content_ideas' then 'campaign_id'
    when 'marketing_contents' then 'campaign_id'
    when 'marketing_leads' then 'campaign_id'
    when 'content_assets' then 'content_id'
    when 'content_approvals' then 'content_id'
    when 'publishing_jobs' then 'content_id'
    when 'publishing_logs' then 'content_id'
    when 'social_analytics' then 'content_id'
    when 'ad_budget_logs' then 'ad_campaign_id'
    else null
  end;

  if tg_table_name = 'marketing_contents' and nullif(v_row ->> 'idea_id', '') is not null then
    v_related_id := (v_row ->> 'idea_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.content_ideas where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Content idea belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'marketing_leads' and nullif(v_row ->> 'content_id', '') is not null then
    v_related_id := (v_row ->> 'content_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.marketing_contents where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Attributed content belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'content_assets'
     and nullif(v_row ->> 'storage_path', '') is not null
     and split_part(v_row ->> 'storage_path', '/', 1) <> v_org_id::text then
    raise exception 'Asset path must be inside this organization folder';
  end if;

  if tg_table_name in ('publishing_jobs', 'social_analytics')
     and nullif(v_row ->> 'social_account_id', '') is not null then
    v_related_id := (v_row ->> 'social_account_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.social_accounts where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Social account belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'trial_conversions' and nullif(v_row ->> 'lead_id', '') is not null then
    v_related_id := (v_row ->> 'lead_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.marketing_leads where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Lead belongs to another workspace';
    end if;
  end if;

  if tg_table_name = 'trial_conversions' then
    foreach v_fk in array array['campaign_id', 'content_id'] loop
      if nullif(v_row ->> v_fk, '') is not null then
        v_related_id := (v_row ->> v_fk)::uuid;
        v_target := case v_fk when 'campaign_id' then 'content_campaigns' else 'marketing_contents' end;
        execute format('select organization_id, workspace_id from public.%I where id = $1', v_target)
          into v_related_org, v_related_workspace using v_related_id;
        if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
          raise exception 'Trial attribution points to another workspace';
        end if;
      end if;
    end loop;
  end if;

  if tg_table_name = 'publishing_logs' and nullif(v_row ->> 'job_id', '') is not null then
    v_related_id := (v_row ->> 'job_id')::uuid;
    select organization_id, workspace_id into v_related_org, v_related_workspace
    from public.publishing_jobs where id = v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Publishing job belongs to another workspace';
    end if;
  end if;

  if v_fk is not null and nullif(v_row ->> v_fk, '') is not null then
    v_related_id := (v_row ->> v_fk)::uuid;
    v_target := case v_fk
      when 'campaign_id' then 'content_campaigns'
      when 'content_id' then 'marketing_contents'
      when 'ad_campaign_id' then 'ad_campaigns'
    end;
    execute format('select organization_id, workspace_id from public.%I where id = $1', v_target)
      into v_related_org, v_related_workspace using v_related_id;
    if v_related_org is distinct from v_org_id or v_related_workspace is distinct from v_workspace_id then
      raise exception 'Related marketing record belongs to another workspace';
    end if;
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'marketing_settings', 'social_accounts', 'content_campaigns', 'content_ideas',
    'marketing_contents', 'content_assets', 'content_approvals',
    'publishing_jobs', 'publishing_logs', 'social_analytics', 'marketing_leads',
    'trial_conversions', 'ad_campaigns', 'ad_budget_logs', 'marketing_notifications',
    'ai_generation_logs', 'marketing_reports'
  ] loop
    execute format('drop trigger if exists trg_%I_tenant_integrity on public.%I', t, t);
    execute format(
      'create trigger trg_%I_tenant_integrity before insert or update on public.%I for each row execute function public.tg_marketing_tenant_integrity()',
      t, t
    );
  end loop;
end $$;
grant execute on function public.enqueue_marketing_publish(uuid) to authenticated;
grant execute on function public.approve_ad_campaign(uuid, numeric) to authenticated;
grant execute on function public.record_ad_spend(uuid, numeric, text) to authenticated;
grant execute on function public.attribute_trial_signup(uuid, uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.month_ad_spend(uuid, date) to authenticated;

-- Retain one active job per content before adding the future uniqueness guard.
with ranked_active_jobs as (
  select id,
         row_number() over (
           partition by content_id
           order by case when status = 'processing' then 0 else 1 end,
                    next_attempt_at desc, created_at desc, id desc
         ) as position
  from public.publishing_jobs
  where status in ('queued', 'processing', 'failed_retryable')
)
update public.publishing_jobs j
set status = case when j.status = 'processing' then 'failed_permanent' else 'cancelled' end,
    last_error = 'Superseded by a newer schedule',
    locked_at = null,
    updated_at = now()
from ranked_active_jobs r
where j.id = r.id and r.position > 1;

create unique index if not exists uq_publishing_jobs_one_active_per_content
  on public.publishing_jobs (content_id)
  where status in ('queued', 'processing', 'failed_retryable');

create or replace function public.schedule_marketing_content(p_content_id uuid, p_scheduled_for timestamptz)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
  v_active_job public.publishing_jobs;
  v_from_status text;
begin
  perform set_config('shopflow.marketing_rpc', '1', true);

  if p_scheduled_for is null or p_scheduled_for <= now() then
    raise exception 'Choose a future scheduled time';
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
  v_from_status := v_row.status;

  select * into v_active_job
  from public.publishing_jobs
  where content_id = p_content_id
    and status in ('processing', 'succeeded')
  order by created_at desc
  limit 1
  for update;
  if found then
    raise exception 'Content is already publishing or has already been published';
  end if;

  update public.publishing_jobs
  set status = 'cancelled',
      last_error = 'Superseded by a newer schedule',
      updated_at = now()
  where content_id = p_content_id
    and status in ('queued', 'failed_retryable');

  update public.marketing_contents
    set status = 'scheduled', scheduled_for = p_scheduled_for, updated_at = now()
    where id = p_content_id
    returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'scheduled', auth.uid(), v_from_status, 'scheduled'
  );

  insert into public.publishing_jobs (
    workspace_id, organization_id, content_id, idempotency_key, status, next_attempt_at
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id,
    v_row.id::text || ':' || p_scheduled_for::text, 'queued', p_scheduled_for
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id,
    'upcoming_scheduled', 'Post scheduled',
    v_row.title || ' is scheduled for publishing.',
    'marketing_contents', v_row.id
  );

  return v_row;
end;
$$;

grant execute on function public.schedule_marketing_content(uuid, timestamptz) to authenticated;

-- Also recover jobs whose worker exited while holding a stale processing lock.
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
    where j.status in ('queued', 'failed_retryable', 'processing')
      and j.next_attempt_at <= now()
      and j.attempt_count < j.max_attempts
      and (j.locked_at is null or j.locked_at < now() - interval '10 minutes')
      and c.status in ('approved', 'scheduled', 'failed')
      and c.approved_at is not null
      and c.approved_by is not null
    order by j.next_attempt_at
    limit greatest(1, least(coalesce(p_limit, 10), 50))
    for update of j skip locked
  )
  update public.publishing_jobs j
     set status = 'processing', locked_at = now(), locked_by = p_worker,
         attempt_count = j.attempt_count + 1, updated_at = now()
    from due
   where j.id = due.id
   returning j.*;
end;
$$;

revoke execute on function public.claim_due_publishing_jobs(integer, text) from public, anon, authenticated;
grant execute on function public.claim_due_publishing_jobs(integer, text) to service_role;
