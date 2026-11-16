-- ==============================================================================
-- Migration: 0021_marketing_automation_schema.sql
-- Description: ShopFlow AI marketing automation tables, RLS, and workspace seed.
-- Incremental and non-destructive: does not drop or truncate existing ERP data.
-- ==============================================================================

create extension if not exists "pgcrypto";

create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.is_marketing_manager(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.organization_members
    where organization_id = target_org_id
      and user_id = auth.uid()
      and role in ('owner', 'admin', 'manager')
      and is_active = true
  );
$$;

create or replace function public.can_approve_marketing(target_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.organization_members
    where organization_id = target_org_id
      and user_id = auth.uid()
      and role in ('owner', 'admin', 'manager')
      and is_active = true
  );
$$;

-- 1. Workspaces (1:1 with organization)
create table if not exists public.marketing_workspaces (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations(id) on delete cascade,
  brand_name text not null default 'ShopFlow',
  market text not null default 'Myanmar',
  primary_language text not null default 'Burmese',
  secondary_language text not null default 'English',
  target_audience text[] not null default array[
    'Wholesale shop owners',
    'Retail shop owners',
    'General merchandise stores',
    'Distribution businesses',
    'Small business owners'
  ],
  primary_goal text not null default 'Free trial registrations',
  secondary_goal text not null default 'Brand awareness',
  platforms text[] not null default array['facebook', 'tiktok'],
  approval_mode text not null default 'manual_review' check (approval_mode = 'manual_review'),
  monthly_ad_budget_mmk numeric(14,2) not null default 50000 check (monthly_ad_budget_mmk >= 0),
  facebook_budget_mmk numeric(14,2) not null default 30000 check (facebook_budget_mmk >= 0),
  tiktok_budget_mmk numeric(14,2) not null default 20000 check (tiktok_budget_mmk >= 0),
  currency text not null default 'MMK',
  timezone text not null default 'Asia/Yangon',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_workspace_budget_alloc_chk
    check (facebook_budget_mmk + tiktok_budget_mmk <= monthly_ad_budget_mmk)
);

create table if not exists public.marketing_settings (
  workspace_id uuid primary key references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  brand_tone text not null default 'professional_friendly',
  default_cta text not null default 'Start 14-day free trial',
  ai_provider text not null default 'openai',
  ai_model text not null default 'gpt-4o-mini',
  auto_generate_weekly_ideas boolean not null default true,
  auto_generate_drafts boolean not null default false,
  notify_on_pending_approval boolean not null default true,
  budget_alert_threshold_pct numeric(5,2) not null default 80 check (budget_alert_threshold_pct between 1 and 100),
  content_pillars jsonb not null default jsonb_build_array(
    jsonb_build_object('key', 'business_problems', 'label', 'Business Problems', 'weight', 35),
    jsonb_build_object('key', 'product_demonstrations', 'label', 'Product Demonstrations', 'weight', 30),
    jsonb_build_object('key', 'educational', 'label', 'Educational Content', 'weight', 20),
    jsonb_build_object('key', 'promotion_conversion', 'label', 'Product Promotion and Conversion', 'weight', 15)
  ),
  prompt_overrides jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.social_accounts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  provider text not null check (provider in ('facebook', 'tiktok', 'metricool')),
  display_name text,
  external_account_id text,
  page_id text,
  username text,
  connection_status text not null default 'disconnected'
    check (connection_status in ('disconnected', 'pending', 'connected', 'expired', 'restricted', 'missing_permissions')),
  granted_permissions text[] not null default '{}',
  missing_permissions text[] not null default '{}',
  token_expires_at timestamptz,
  last_error text,
  last_synced_at timestamptz,
  setup_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_social_accounts_external
  on public.social_accounts (workspace_id, provider, external_account_id)
  where external_account_id is not null;

create unique index if not exists uq_social_accounts_placeholder
  on public.social_accounts (workspace_id, provider)
  where external_account_id is null;

create table if not exists public.social_account_secrets (
  social_account_id uuid primary key references public.social_accounts(id) on delete cascade,
  access_token_encrypted text not null,
  refresh_token_encrypted text,
  token_type text,
  scopes text,
  updated_at timestamptz not null default now()
);

create table if not exists public.marketing_oauth_states (
  id uuid primary key default gen_random_uuid(),
  state_nonce text not null unique,
  provider text not null check (provider in ('facebook', 'tiktok', 'metricool')),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  redirect_to text not null default '/marketing/social-accounts',
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.content_campaigns (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  objective text not null default 'Free trial registrations',
  platform text not null check (platform in ('facebook', 'tiktok', 'both')),
  status text not null default 'draft' check (status in ('draft', 'active', 'paused', 'completed', 'archived')),
  start_date date,
  end_date date,
  planned_budget_mmk numeric(14,2) not null default 0 check (planned_budget_mmk >= 0),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_ideas (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  topic text not null,
  target_audience text,
  pain_point text,
  hook text,
  content_angle text,
  caption_concept text,
  cta text,
  recommended_platform text check (recommended_platform in ('facebook', 'tiktok', 'both')),
  recommended_format text,
  content_pillar text not null default 'educational',
  suggested_publish_at timestamptz,
  expected_objective text,
  status text not null default 'idea' check (status in ('idea', 'selected', 'converted', 'discarded')),
  generation_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.marketing_contents (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  idea_id uuid references public.content_ideas(id) on delete set null,
  title text not null,
  platform text not null check (platform in ('facebook', 'tiktok')),
  content_type text not null,
  content_pillar text not null,
  caption text not null default '',
  hook text,
  cta text,
  hashtags text[] not null default '{}',
  image_prompt text,
  video_script jsonb,
  production_brief text,
  ai_model text,
  generation_metadata jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in (
    'draft', 'pending_review', 'approved', 'rejected', 'scheduled',
    'publishing', 'published', 'failed', 'archived'
  )),
  scheduled_for timestamptz,
  published_at timestamptz,
  rejection_reason text,
  approved_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  last_publish_error text,
  provider_post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_assets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid references public.marketing_contents(id) on delete set null,
  asset_type text not null check (asset_type in ('image', 'video', 'thumbnail', 'document', 'other')),
  file_url text,
  storage_path text,
  mime_type text,
  width integer,
  height integer,
  file_size_bytes bigint,
  prompt text,
  generation_provider text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.content_approvals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid not null references public.marketing_contents(id) on delete cascade,
  action text not null check (action in ('submitted', 'approved', 'rejected', 'edited', 'regenerated', 'scheduled')),
  actor_id uuid references public.profiles(id) on delete set null,
  from_status text,
  to_status text,
  reason text,
  created_at timestamptz not null default now()
);

create table if not exists public.publishing_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid not null references public.marketing_contents(id) on delete cascade,
  social_account_id uuid references public.social_accounts(id) on delete set null,
  idempotency_key text not null unique,
  status text not null default 'queued' check (status in (
    'queued', 'processing', 'succeeded', 'failed_retryable', 'failed_permanent', 'cancelled'
  )),
  attempt_count integer not null default 0,
  max_attempts integer not null default 5,
  next_attempt_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  provider_post_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.publishing_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  job_id uuid references public.publishing_jobs(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  event text not null,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.social_analytics (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  content_id uuid references public.marketing_contents(id) on delete set null,
  social_account_id uuid references public.social_accounts(id) on delete set null,
  platform text not null check (platform in ('facebook', 'tiktok')),
  metric_date date not null,
  reach numeric(14,2),
  impressions numeric(14,2),
  reactions numeric(14,2),
  comments numeric(14,2),
  shares numeric(14,2),
  likes numeric(14,2),
  link_clicks numeric(14,2),
  video_views numeric(14,2),
  profile_views numeric(14,2),
  engagements numeric(14,2),
  metric_source text not null default 'unavailable' check (metric_source in ('platform', 'estimated', 'unavailable')),
  source_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_social_analytics_content_day
  on public.social_analytics (workspace_id, platform, metric_date, coalesce(content_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists public.marketing_leads (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references public.marketing_workspaces(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete set null,
  full_name text,
  email text,
  phone text,
  business_type text,
  source_platform text check (source_platform in ('facebook', 'tiktok', 'website', 'landing', 'manual', 'other')),
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  status text not null default 'new' check (status in (
    'new', 'contacted', 'interested', 'trial_registered', 'converted', 'not_interested'
  )),
  trial_signup_at timestamptz,
  converted_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trial_conversions (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references public.marketing_leads(id) on delete set null,
  organization_id uuid references public.organizations(id) on delete cascade,
  workspace_id uuid references public.marketing_workspaces(id) on delete set null,
  user_id uuid references public.profiles(id) on delete set null,
  campaign_id uuid references public.content_campaigns(id) on delete set null,
  content_id uuid references public.marketing_contents(id) on delete set null,
  attribution_confidence text not null default 'unknown' check (attribution_confidence in ('direct', 'utm', 'inferred', 'unknown')),
  converted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table if not exists public.ad_campaigns (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  platform text not null check (platform in ('facebook', 'tiktok')),
  name text not null,
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'active', 'paused', 'completed', 'rejected')),
  planned_spend_mmk numeric(14,2) not null default 0 check (planned_spend_mmk >= 0),
  approved_spend_mmk numeric(14,2) not null default 0 check (approved_spend_mmk >= 0),
  actual_spend_mmk numeric(14,2) not null default 0 check (actual_spend_mmk >= 0),
  owner_approved boolean not null default false,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ad_budget_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  ad_campaign_id uuid references public.ad_campaigns(id) on delete set null,
  period_month date not null,
  platform text check (platform in ('facebook', 'tiktok')),
  amount_mmk numeric(14,2) not null check (amount_mmk >= 0),
  entry_type text not null check (entry_type in ('planned', 'approved', 'actual', 'adjustment')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.ai_generation_logs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  purpose text not null,
  model text,
  prompt_name text,
  input_tokens integer,
  output_tokens integer,
  estimated_cost_usd numeric(12,6),
  status text not null default 'succeeded' check (status in ('succeeded', 'failed')),
  error text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.marketing_reports (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  report_type text not null check (report_type in ('weekly', 'monthly')),
  period_start date not null,
  period_end date not null,
  status text not null default 'ready' check (status in ('ready', 'failed', 'insufficient_data')),
  summary jsonb not null default '{}'::jsonb,
  generated_by text not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, report_type, period_start, period_end)
);

create table if not exists public.marketing_notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.marketing_workspaces(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  notification_type text not null,
  title text not null,
  body text not null,
  entity_type text,
  entity_id uuid,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

-- Indexes
create index if not exists idx_mkt_contents_org_status on public.marketing_contents (organization_id, status, created_at desc);
create index if not exists idx_mkt_contents_scheduled on public.marketing_contents (scheduled_for) where status = 'scheduled';
create index if not exists idx_mkt_leads_org on public.marketing_leads (organization_id, created_at desc);
create index if not exists idx_mkt_jobs_queue on public.publishing_jobs (status, next_attempt_at) where status in ('queued', 'failed_retryable');
create index if not exists idx_mkt_notifications_unread on public.marketing_notifications (organization_id, is_read, created_at desc);
create index if not exists idx_mkt_analytics_org_date on public.social_analytics (organization_id, metric_date desc);
create index if not exists idx_mkt_oauth_nonce on public.marketing_oauth_states (state_nonce);

-- updated_at triggers
do $$
declare
  t text;
begin
  foreach t in array array[
    'marketing_workspaces', 'marketing_settings', 'social_accounts', 'content_campaigns',
    'content_ideas', 'marketing_contents', 'content_assets', 'publishing_jobs',
    'social_analytics', 'marketing_leads', 'ad_campaigns', 'marketing_reports'
  ]
  loop
    execute format('drop trigger if exists trg_%s_updated_at on public.%I', t, t);
    execute format(
      'create trigger trg_%s_updated_at before update on public.%I for each row execute function public.tg_set_updated_at()',
      t, t
    );
  end loop;
end $$;

-- Guard: clients cannot mark content approved/published directly
create or replace function public.tg_marketing_content_status_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  rpc_flag text;
begin
  rpc_flag := current_setting('shopflow.marketing_rpc', true);
  if tg_op = 'INSERT' then
    if new.status not in ('draft') and coalesce(rpc_flag, '') is distinct from '1' then
      raise exception 'New marketing content must start as draft';
    end if;
    return new;
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

-- Ad campaigns cannot be activated from the client
create or replace function public.tg_ad_campaign_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if coalesce(current_setting('shopflow.marketing_rpc', true), '') is distinct from '1' then
    if tg_op = 'INSERT' and new.status not in ('proposed', 'rejected') then
      raise exception 'Ad campaigns must be created as proposed; owner approval is required to spend';
    end if;
    if tg_op = 'UPDATE' and new.status in ('active', 'approved') then
      raise exception 'Advertising spend requires an explicit owner-approval RPC';
    end if;
    if tg_op = 'UPDATE' and new.actual_spend_mmk is distinct from old.actual_spend_mmk then
      raise exception 'Actual ad spend can only be recorded through a server-side RPC';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_ad_campaign_guard on public.ad_campaigns;
create trigger trg_ad_campaign_guard
  before insert or update on public.ad_campaigns
  for each row execute function public.tg_ad_campaign_guard();

-- Seed workspace for an organization
create or replace function public.ensure_marketing_workspace(p_org_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if auth.uid() is not null
     and not public.is_platform_admin()
     and not public.has_org_membership(p_org_id)
     and exists (
       select 1 from public.organization_members m
       where m.organization_id = p_org_id
     ) then
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
  select v_id, p_org_id, 'facebook', 'Facebook Page', 'disconnected',
    'Connect via Meta OAuth. pages_manage_posts and pages_read_engagement are required to publish and read insights.'
  where not exists (
    select 1 from public.social_accounts s
    where s.workspace_id = v_id and s.provider = 'facebook'
  );

  insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
  select v_id, p_org_id, 'tiktok', 'TikTok Business', 'disconnected',
    'Connect via TikTok Login Kit / Content Posting API. Video publish permissions are required.'
  where not exists (
    select 1 from public.social_accounts s
    where s.workspace_id = v_id and s.provider = 'tiktok'
  );

  return v_id;
end;
$$;

create or replace function public.tg_org_seed_marketing_workspace()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.ensure_marketing_workspace(new.id);
  return new;
exception when others then
  -- Do not block organization creation if marketing seed fails
  return new;
end;
$$;

drop trigger if exists trg_org_seed_marketing_workspace on public.organizations;
create trigger trg_org_seed_marketing_workspace
  after insert on public.organizations
  for each row execute function public.tg_org_seed_marketing_workspace();

-- Backfill workspaces for existing organizations
insert into public.marketing_workspaces (organization_id)
select id from public.organizations
on conflict (organization_id) do nothing;

insert into public.marketing_settings (workspace_id, organization_id)
select w.id, w.organization_id
from public.marketing_workspaces w
on conflict (workspace_id) do nothing;

insert into public.social_accounts (workspace_id, organization_id, provider, display_name, connection_status, setup_notes)
select w.id, w.organization_id, p.provider, p.display_name, 'disconnected', p.notes
from public.marketing_workspaces w
cross join (
  values
    ('facebook', 'Facebook Page', 'Connect via Meta OAuth. pages_manage_posts and pages_read_engagement are required to publish and read insights.'),
    ('tiktok', 'TikTok Business', 'Connect via TikTok Login Kit / Content Posting API. Video publish permissions are required.')
) as p(provider, display_name, notes)
where not exists (
  select 1 from public.social_accounts s
  where s.workspace_id = w.id and s.provider = p.provider
);

-- RLS
alter table public.marketing_workspaces enable row level security;
alter table public.marketing_settings enable row level security;
alter table public.social_accounts enable row level security;
alter table public.social_account_secrets enable row level security;
alter table public.marketing_oauth_states enable row level security;
alter table public.content_campaigns enable row level security;
alter table public.content_ideas enable row level security;
alter table public.marketing_contents enable row level security;
alter table public.content_assets enable row level security;
alter table public.content_approvals enable row level security;
alter table public.publishing_jobs enable row level security;
alter table public.publishing_logs enable row level security;
alter table public.social_analytics enable row level security;
alter table public.marketing_leads enable row level security;
alter table public.trial_conversions enable row level security;
alter table public.ad_campaigns enable row level security;
alter table public.ad_budget_logs enable row level security;
alter table public.ai_generation_logs enable row level security;
alter table public.marketing_reports enable row level security;
alter table public.marketing_notifications enable row level security;

-- Secrets: no client policies (service_role bypasses RLS)
revoke all on public.social_account_secrets from anon, authenticated;
revoke all on public.marketing_oauth_states from anon, authenticated;
grant all on public.social_account_secrets to service_role;
grant all on public.marketing_oauth_states to service_role;

create policy "mkt_workspaces_select" on public.marketing_workspaces for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_workspaces_update" on public.marketing_workspaces for update
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_settings_select" on public.marketing_settings for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_settings_update" on public.marketing_settings for update
  using (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_social_select" on public.social_accounts for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_social_write" on public.social_accounts for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_campaigns_select" on public.content_campaigns for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_campaigns_write" on public.content_campaigns for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_ideas_select" on public.content_ideas for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_ideas_write" on public.content_ideas for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_contents_select" on public.marketing_contents for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_contents_insert" on public.marketing_contents for insert
  with check (public.has_org_membership(organization_id));
create policy "mkt_contents_update" on public.marketing_contents for update
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_assets_select" on public.content_assets for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_assets_write" on public.content_assets for all
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_approvals_select" on public.content_approvals for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_approvals_insert" on public.content_approvals for insert
  with check (public.has_org_membership(organization_id));

create policy "mkt_jobs_select" on public.publishing_jobs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_logs_select" on public.publishing_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_analytics_select" on public.social_analytics for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_analytics_write" on public.social_analytics for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_leads_select" on public.marketing_leads for select
  using (
    (organization_id is not null and public.has_org_membership(organization_id))
    or public.is_platform_admin()
  );
create policy "mkt_leads_write" on public.marketing_leads for all
  using (
    (organization_id is not null and public.has_org_membership(organization_id))
    or public.is_platform_admin()
  );

create policy "mkt_trials_select" on public.trial_conversions for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_ads_select" on public.ad_campaigns for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_ads_write" on public.ad_campaigns for all
  using (public.is_marketing_manager(organization_id) or public.is_platform_admin());

create policy "mkt_budget_select" on public.ad_budget_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());
create policy "mkt_budget_insert" on public.ad_budget_logs for insert
  with check (public.is_org_admin_or_owner(organization_id) or public.is_platform_admin());

create policy "mkt_ai_logs_select" on public.ai_generation_logs for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_reports_select" on public.marketing_reports for select
  using (public.has_org_membership(organization_id) or public.is_platform_admin());

create policy "mkt_notif_select" on public.marketing_notifications for select
  using (
    public.has_org_membership(organization_id)
    and (user_id is null or user_id = auth.uid())
  );
create policy "mkt_notif_update" on public.marketing_notifications for update
  using (user_id = auth.uid() or public.is_org_admin_or_owner(organization_id));

-- Storage bucket (ignore if storage is unavailable)
do $$
begin
  insert into storage.buckets (id, name, public)
  values ('marketing-assets', 'marketing-assets', false)
  on conflict (id) do nothing;
exception when undefined_table then
  null;
when others then
  null;
end $$;

do $$
begin
  execute $pol$
    create policy "mkt_storage_select"
      on storage.objects for select
      using (
        bucket_id = 'marketing-assets'
        and public.has_org_membership((storage.foldername(name))[1]::uuid)
      )
  $pol$;
exception when duplicate_object then null;
when undefined_table then null;
when others then null;
end $$;

do $$
begin
  execute $pol$
    create policy "mkt_storage_insert"
      on storage.objects for insert
      with check (
        bucket_id = 'marketing-assets'
        and public.has_org_membership((storage.foldername(name))[1]::uuid)
      )
  $pol$;
exception when duplicate_object then null;
when undefined_table then null;
when others then null;
end $$;
