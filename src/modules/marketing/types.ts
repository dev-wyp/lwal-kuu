export type ContentStatus =
  | 'draft'
  | 'pending_review'
  | 'approved'
  | 'rejected'
  | 'scheduled'
  | 'publishing'
  | 'published'
  | 'failed'
  | 'archived';

export type SocialPlatform = 'facebook' | 'tiktok';
export type MetricSource = 'platform' | 'estimated' | 'unavailable';
export type LeadStatus =
  | 'new'
  | 'contacted'
  | 'interested'
  | 'trial_registered'
  | 'converted'
  | 'not_interested';

export type ConnectionStatus =
  | 'disconnected'
  | 'pending'
  | 'connected'
  | 'expired'
  | 'restricted'
  | 'missing_permissions';

export interface MarketingWorkspace {
  id: string;
  organization_id: string;
  brand_name: string;
  market: string;
  primary_language: string;
  secondary_language: string;
  target_audience: string[];
  primary_goal: string;
  secondary_goal: string;
  platforms: string[];
  approval_mode: 'manual_review';
  monthly_ad_budget_mmk: number;
  facebook_budget_mmk: number;
  tiktok_budget_mmk: number;
  currency: string;
  timezone: string;
}

export interface MarketingSettings {
  workspace_id: string;
  organization_id: string;
  brand_tone: string;
  default_cta: string;
  ai_provider: string;
  ai_model: string;
  auto_generate_weekly_ideas: boolean;
  auto_generate_drafts: boolean;
  notify_on_pending_approval: boolean;
  budget_alert_threshold_pct: number;
  content_pillars: ContentPillar[];
  prompt_overrides: Record<string, string>;
}

export interface ContentPillar {
  key: string;
  label: string;
  weight: number;
}

export interface SocialAccount {
  id: string;
  workspace_id: string;
  organization_id: string;
  provider: SocialPlatform | 'metricool';
  display_name: string | null;
  external_account_id: string | null;
  page_id: string | null;
  username: string | null;
  connection_status: ConnectionStatus;
  granted_permissions: string[];
  missing_permissions: string[];
  token_expires_at: string | null;
  last_error: string | null;
  last_synced_at: string | null;
  setup_notes: string | null;
}

export interface ContentCampaign {
  id: string;
  workspace_id: string;
  organization_id: string;
  name: string;
  objective: string;
  platform: SocialPlatform | 'both';
  status: string;
  start_date: string | null;
  end_date: string | null;
  planned_budget_mmk: number;
  notes: string | null;
}

export interface ContentIdea {
  id: string;
  workspace_id: string;
  campaign_id: string | null;
  topic: string;
  target_audience: string | null;
  pain_point: string | null;
  hook: string | null;
  content_angle: string | null;
  caption_concept: string | null;
  cta: string | null;
  recommended_platform: SocialPlatform | 'both' | null;
  recommended_format: string | null;
  content_pillar: string;
  suggested_publish_at: string | null;
  expected_objective: string | null;
  status: string;
}

export interface TikTokScript {
  duration_seconds: number;
  opening_hook: string;
  scenes: Array<{
    scene: number;
    visual: string;
    on_screen_text: string;
    voice_over: string;
    duration_seconds: number;
  }>;
  caption: string;
  hashtags: string[];
  cta: string;
}

export interface MarketingContent {
  id: string;
  workspace_id: string;
  organization_id: string;
  campaign_id: string | null;
  idea_id: string | null;
  title: string;
  platform: SocialPlatform;
  content_type: string;
  content_pillar: string;
  caption: string;
  hook: string | null;
  cta: string | null;
  hashtags: string[];
  image_prompt: string | null;
  video_script: TikTokScript | null;
  production_brief: string | null;
  ai_model: string | null;
  generation_metadata: Record<string, unknown>;
  status: ContentStatus;
  scheduled_for: string | null;
  published_at: string | null;
  rejection_reason: string | null;
  approved_at: string | null;
  approved_by: string | null;
  created_by: string | null;
  last_publish_error: string | null;
  provider_post_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface ContentAsset {
  id: string;
  content_id: string | null;
  asset_type: string;
  file_url: string | null;
  storage_path: string | null;
  mime_type: string | null;
  width: number | null;
  height: number | null;
  file_size_bytes: number | null;
  prompt: string | null;
  generation_provider: string | null;
  created_at: string;
}

export interface ContentApproval {
  id: string;
  content_id: string;
  action: string;
  actor_id: string | null;
  from_status: string | null;
  to_status: string | null;
  reason: string | null;
  created_at: string;
}

export interface MarketingLead {
  id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  business_type: string | null;
  source_platform: string | null;
  campaign_id: string | null;
  content_id: string | null;
  utm_source: string | null;
  utm_medium: string | null;
  utm_campaign: string | null;
  status: LeadStatus;
  trial_signup_at: string | null;
  converted_at: string | null;
  created_at: string;
}

export interface SocialAnalyticsRow {
  id: string;
  content_id: string | null;
  platform: SocialPlatform;
  metric_date: string;
  reach: number | null;
  impressions: number | null;
  reactions: number | null;
  comments: number | null;
  shares: number | null;
  likes: number | null;
  link_clicks: number | null;
  video_views: number | null;
  profile_views: number | null;
  engagements: number | null;
  metric_source: MetricSource;
  source_note: string | null;
}

export interface AdCampaign {
  id: string;
  platform: SocialPlatform;
  name: string;
  status: string;
  planned_spend_mmk: number;
  approved_spend_mmk: number;
  actual_spend_mmk: number;
  owner_approved: boolean;
  notes: string | null;
}

export interface MarketingReport {
  id: string;
  report_type: 'weekly' | 'monthly';
  period_start: string;
  period_end: string;
  status: string;
  summary: Record<string, unknown>;
  generated_by: string;
  created_at: string;
}

export interface MarketingNotification {
  id: string;
  notification_type: string;
  title: string;
  body: string;
  is_read: boolean;
  created_at: string;
  entity_type: string | null;
  entity_id: string | null;
}

export interface PublishingJob {
  id: string;
  content_id: string;
  status: string;
  attempt_count: number;
  last_error: string | null;
  provider_post_id: string | null;
  next_attempt_at: string;
}
