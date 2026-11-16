-- ShopFlow's marketing automation is a platform-admin feature, not a tenant feature.
-- Keep existing rows and their organization association, but remove tenant access.

create or replace function public.is_marketing_manager(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_platform_admin();
$$;

create or replace function public.can_approve_marketing(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_platform_admin();
$$;

-- Stop automatically creating a marketing workspace for every new shop.
drop trigger if exists trg_org_seed_marketing_workspace on public.organizations;

-- Replace tenant membership policies with one platform-admin-only policy on
-- every client-facing marketing table. Secrets and OAuth state remain service-only.
do $$
declare
  v_table_name text;
  v_policy_name text;
  marketing_tables text[] := array[
    'marketing_workspaces', 'marketing_settings', 'social_accounts',
    'content_campaigns', 'content_ideas', 'marketing_contents', 'content_assets',
    'content_approvals', 'publishing_jobs', 'publishing_logs', 'social_analytics',
    'marketing_leads', 'trial_conversions', 'ad_campaigns', 'ad_budget_logs',
    'ai_generation_logs', 'marketing_reports', 'marketing_notifications'
  ];
begin
  foreach v_table_name in array marketing_tables loop
    execute format('drop policy if exists mkt_platform_admin_only on public.%I', v_table_name);
    for v_policy_name in
      select policyname from pg_policies
      where schemaname = 'public' and tablename = v_table_name
    loop
      execute format('drop policy %I on public.%I', v_policy_name, v_table_name);
    end loop;
    execute format(
      'create policy mkt_platform_admin_only on public.%I for all using (public.is_platform_admin()) with check (public.is_platform_admin())',
      v_table_name
    );
  end loop;
end;
$$;

-- Workspace initialization is now a platform-only operation.
create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
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
    (v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected', 'Connect via Meta OAuth.'),
    (v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected', 'Connect via TikTok OAuth.')
  on conflict do nothing;

  return v_id;
end;
$$;

revoke execute on function public.ensure_marketing_workspace(uuid) from public, anon;
grant execute on function public.ensure_marketing_workspace(uuid) to authenticated, service_role;

create or replace function public.submit_marketing_content_for_review(p_content_id uuid)
returns public.marketing_contents
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.marketing_contents;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  perform set_config('shopflow.marketing_rpc', '1', true);
  select * into v_row from public.marketing_contents where id = p_content_id for update;
  if not found then raise exception 'Content not found'; end if;
  if v_row.status not in ('draft', 'rejected') then
    raise exception 'Only draft or rejected content can be submitted for review';
  end if;
  if length(btrim(v_row.caption)) < 8 then
    raise exception 'Caption is required before review';
  end if;

  update public.marketing_contents
  set status = 'pending_review', rejection_reason = null, updated_at = now()
  where id = p_content_id returning * into v_row;

  insert into public.content_approvals (
    workspace_id, organization_id, content_id, action, actor_id, from_status, to_status
  ) values (
    v_row.workspace_id, v_row.organization_id, v_row.id, 'submitted', auth.uid(), 'draft', 'pending_review'
  );

  perform public.mkt_notify(
    v_row.organization_id, v_row.workspace_id, 'pending_approval',
    'Content awaiting approval', v_row.title || ' is ready for review.',
    'marketing_contents', v_row.id
  );

  return v_row;
end;
$$;

revoke execute on function public.submit_marketing_content_for_review(uuid) from public, anon;
grant execute on function public.submit_marketing_content_for_review(uuid) to authenticated;

-- Keep spend approval RPCs platform-admin-only as SECURITY DEFINER functions.
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
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
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
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
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

