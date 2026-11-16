# ShopFlow Marketing Automation

AI-assisted Facebook and TikTok marketing for ShopFlow, available only in the platform superadmin dashboard. Platform superadmins review and approve every post. The system never publishes unapproved content and never launches ads on its own.

## Apply schema

Incremental migrations (do not reset production data):

- `supabase/migrations/0021_marketing_automation_schema.sql`
- `supabase/migrations/0022_marketing_rpcs.sql`
- `supabase/migrations/0023_marketing_jobs.sql`
- `supabase/migrations/0024_marketing_workflow_hardening.sql`
- `supabase/migrations/0025_marketing_platform_admin_only.sql`
- `supabase/migrations/0026_platform_ai_credentials.sql`

Apply to staging first. Tokens live in `social_account_secrets` with no client RLS policies.

If marketing table/RPC requests return `404` (`PGRST205`/`PGRST202`), the marketing migrations have not been applied to the Supabase project configured by `VITE_SUPABASE_URL`. If Edge Function requests return `404` / `NOT_FOUND`, deploy the named functions to that same project. The frontend already calls the local function and RPC names listed here.

Deploy against the staging project ref first, then confirm the linked ref before applying the same release to production:

```sh
supabase login
supabase link --project-ref <staging-project-ref>
supabase db push
supabase functions deploy marketing-ai
supabase functions deploy marketing-oauth
supabase functions deploy marketing-publish
supabase functions deploy marketing-jobs
```

`db push` applies every local migration not yet present on the linked project, in order. Review its pending migration list before confirming. Once deployed, verify the new `marketing_*` tables and RPCs exist, then reload the dashboard. Configure OAuth and cron secrets separately. Superadmins can add their own Gemini or OpenAI API key in **Admin → ShopFlow Marketing → AI settings**. Keys are encrypted by the `marketing-ai` Edge Function and are never readable from the browser. Stored-key encryption uses `MARKETING_TOKEN_SECRET` (or the service role key as a fallback); keep that secret stable. Edge Function provider keys remain supported as a fallback.

## Edge Functions

Deploy:

- `marketing-ai`
- `marketing-oauth`
- `marketing-publish`
- `marketing-jobs`

## Environment variables

Frontend (Vite):

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

Edge Function secrets (never in the browser or a Vite `.env` file):

- `GEMINI_API_KEY` — optional server-side fallback. Default model: `gemini-flash-latest`.
- `OPENAI_API_KEY` — optional server-side fallback. Default model: `gpt-4o-mini`.
- Anthropic is not wired yet; no Anthropic secret is needed.
- `META_APP_ID`, `META_APP_SECRET`, `META_OAUTH_REDIRECT_URL`
- `TIKTOK_CLIENT_KEY`, `TIKTOK_CLIENT_SECRET`, `TIKTOK_OAUTH_REDIRECT_URL`
- `MARKETING_TOKEN_SECRET` — AES key for stored social tokens
- `MARKETING_CRON_SECRET` — header `x-cron-secret` for `marketing-jobs` and publish worker
- `SITE_URL` — used after OAuth callbacks (example `https://app.shopflow.example`)
- `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` — provided by Supabase

Set provider keys as Supabase Edge Function secrets, for example `supabase secrets set GEMINI_API_KEY="$GEMINI_API_KEY" --project-ref <project-ref>`. Do not paste keys into frontend environment variables or commit them.

## External setup

### Meta / Facebook

1. Create a Meta app with Facebook Login for Business.
2. Request `pages_show_list`, `pages_read_engagement`, and `pages_manage_posts`.
3. Set the OAuth redirect to the `marketing-oauth` function URL.
4. Until App Review grants publish access, export approved captions from **Approvals** and post manually.

### TikTok

1. Create a TikTok developer app and request Content Posting API scopes (`video.publish`, `video.list`).
2. Point the redirect URI at `marketing-oauth`.
3. If video publish is unavailable, use the generated production brief and uploaded asset.

TikTok analytics synchronization is not enabled yet. The analytics screen reports it as unavailable rather than storing unverified values.

### Cron

Call `marketing-jobs` on a schedule with `x-cron-secret`. Suggested jobs: `publish`, `expired`, `upcoming`, `analytics`. SQL cron helpers also exist when `pg_cron` is enabled.
The planner and report generator currently run when requested in the dashboard; weekly idea generation is not an active background job.

## Product rules

- Marketing is a platform-admin-only feature; marketing data remains linked to organization IDs internally for existing database relationships.
- Approval mode is always manual review.
- Default monthly ad budget: 50,000 MMK (Facebook 30,000, TikTok 20,000). These are ceilings, not spend authorization.
- Analytics labeled **Platform data**, **Estimated**, or **Unavailable**. Missing data is not shown as zero success.
- Trial signups capture `utm_source`, `utm_medium`, `utm_campaign`, and `utm_content` from `/` and `/register`.
