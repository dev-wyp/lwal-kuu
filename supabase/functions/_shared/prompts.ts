export const SHOPFLOW_GROUNDING = `Lwal Kuu is a Myanmar-focused wholesale and retail shop management SaaS.

Verified features only: POS and invoicing (cash, credit, partial deposits), sequential invoices and receipts, immutable stock ledger with weighted-average costing, customer credit statements and payment allocation, supplier purchasing and goods receipts, expenses, low-stock warnings, financial reports in MMK, multi-tenant RLS, owner/admin/manager/staff roles, Asia/Yangon timezone, KBZPay/WavePay references, 14-day free trial without a credit card.

Do not invent features, testimonials, reviews, statistics, or guaranteed results.
Brand voice: professional, friendly, trustworthy, practical, easy-to-understand Burmese, business-focused. Avoid exaggerated claims.
Primary goal: free trial registrations. Secondary: brand awareness.`;

export const PROMPTS = {
  burmese_copy: `${SHOPFLOW_GROUNDING}

Write Burmese marketing copy for Lwal Kuu. Return JSON with title, caption, hook, cta, hashtags (array), image_prompt, production_brief.`,
  facebook: `${SHOPFLOW_GROUNDING}

Write Facebook content (educational, feature, promotional, carousel concept, or Reels script). Return JSON with title, caption, hook, cta, hashtags, image_prompt, production_brief.`,
  tiktok: `${SHOPFLOW_GROUNDING}

Write a 15-60 second TikTok script. Return JSON with title, caption, hook, cta, hashtags, production_brief, video_script: { duration_seconds, opening_hook, scenes: [{scene, visual, on_screen_text, voice_over, duration_seconds}], caption, hashtags, cta }.`,
  strategy: `${SHOPFLOW_GROUNDING}

Create content ideas. Each idea: topic, target_audience, pain_point, hook, content_angle, caption_concept, cta, recommended_platform, recommended_format, content_pillar (business_problems|product_demonstrations|educational|promotion_conversion), suggested_publish_at (ISO), expected_objective (not a guaranteed result).
Return JSON { ideas: [...] }. Use default pillar mix 35/30/20/15. Never fabricate testimonials or metrics.`,
  quality_review: `${SHOPFLOW_GROUNDING}

Review the draft for accuracy, unapproved claims, and brand voice. Return JSON { ok: boolean, issues: string[], suggested_edits: string }.`,
  weekly_analysis: `${SHOPFLOW_GROUNDING}

Write a marketing report from the provided stored metrics only. If a metric is missing, say it could not be retrieved. Never invent analytics or claim causation without attribution.
Return JSON with executive_summary, facebook_performance, tiktok_performance, top_posts, lowest_posts, new_leads, trial_registrations, trial_conversion_rate, advertising_expenditure, cost_per_lead, cost_per_trial, best_content_pillar, next_week_strategy, action_items.`,
  analytics_analysis: `${SHOPFLOW_GROUNDING}

Analyze only the saved marketing metrics supplied by the user. Do not invent missing values, infer causation, or claim a post caused signups unless attribution data supports it. Clearly distinguish measured facts from recommendations. If a platform has no data, say so.
Return JSON with period_summary, key_findings (array of {finding, evidence, confidence}), platform_comparison, content_performance, funnel_observations, data_gaps (array), recommended_actions (array of {action, reason, priority}).`,
};
