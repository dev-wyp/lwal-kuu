# ShopFlow — Production Deployment Guide

## 1. Prerequisites & Infrastructure Requirements

ShopFlow is architected as a modular monolith frontend (SPA on Vite + React + MUI) communicating with a managed Supabase backend (PostgreSQL 15+, Auth, Storage, Edge Functions).

### Recommended Hosting:
- **Frontend SPA:** Cloudflare Pages, Vercel, or Netlify with automatic HTTPS and edge CDN caching.
- **Backend & Database:** Supabase Cloud Project (Pro tier recommended for point-in-time recovery and `pg_cron` jobs).
- **Transactional Emails:** Resend account with verified domain DNS records (SPF, DKIM, DMARC).
- **Error Tracking & Analytics:** Sentry DSN and PostHog project API key.

---

## 2. Supabase Database Deployment

Execute migrations in numerical order against your Supabase project:

```bash
# 1. Install Supabase CLI
npm install -g supabase

# 2. Login and link project
supabase login
supabase link --project-ref your-supabase-project-id

# 3. Apply all ordered migrations
supabase db push
```

The migrations establish:
- `0001_core_and_tenancy.sql`: Multi-tenancy, memberships, RLS helper functions.
- `0002_product_catalog.sql`: Product categories, measurement units, products master.
- `0003_customers_and_suppliers.sql`: Customer credit ledgers & supplier directories.
- `0004_inventory_and_costing.sql`: Immutable stock movements ledger & balance view.
- `0005_purchasing_and_payables.sql`: Purchase orders & atomic `receive_purchase` RPC.
- `0006_sales_and_receivables.sql`: Sales orders, atomic `confirm_sale` RPC, and reversals.
- `0007_expenses_and_finance.sql`: Operational expenses & expense classifications.
- `0008_subscriptions_and_limits.sql`: SaaS pricing plans, trial RPCs, usage limit meters.
- `0009_reporting_views.sql`: Dynamic ledger statements & gross profit reporting views.
- `0010_automation_cron_jobs.sql`: Scheduled jobs & async notification outbox pattern.

---

## 3. Environment Variables Configuration

Copy `.env.example` to your production hosting environment:

```ini
# Supabase Configuration
VITE_SUPABASE_URL=https://your-project.supabase.co
VITE_SUPABASE_ANON_KEY=your-supabase-anon-publishable-key

# Product Analytics & Telemetry (Optional)
VITE_POSTHOG_KEY=phc_...
VITE_POSTHOG_HOST=https://app.posthog.com

# Error Monitoring (Optional)
VITE_SENTRY_DSN=https://...@sentry.io/...
```

> **Security Rule:** Never expose `SUPABASE_SERVICE_ROLE_KEY` to Vite or frontend environments. Service role keys must only exist within Supabase Edge Functions or backend secrets.

---

## 4. Frontend Build & CI/CD Pipeline

Build production bundle locally or in CI:

```bash
# Type check and build
npm run build

# Output bundle located in /dist
```

### GitHub Actions CI/CD Configuration (`.github/workflows/ci.yml`):
```yaml
name: ShopFlow CI/CD
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: 'npm'
      - run: npm ci
      - run: npm run lint
      - run: npm run build
```

---

## 5. Supabase Edge Functions Deployment

Deploy external integration edge functions:

```bash
# Deploy send-email function
supabase functions deploy send-email --no-verify-jwt
supabase secrets set RESEND_API_KEY=re_...

# Deploy payment webhook processor
supabase functions deploy process-webhook --no-verify-jwt
supabase secrets set PAYMENT_WEBHOOK_SECRET=whsec_...
```

